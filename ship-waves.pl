#!/usr/bin/env perl

# http://www.timeanddate.com/time/zones/gmt

# perl ./ship-waves.pl -config Grimtooth/lacuna.yml -target 110,21 -count 800 \
#   -planet Gunnr -planet Ofrustaoir -planet Skyholme -fleet 400 -type sweeper,snark3 \
#   -timed

use strict;
use warnings;

use feature qw(say);

use Data::Dumper;
$Data::Dumper::Maxdepth = 3;

use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util qw(first);
use Getopt::Long qw(GetOptions);
use JSON;
use DateTime;
use Games::Lacuna::Client ();

my $ships_per_fleet = 600;
my $ship_name;
my $ship_type = 'sweeper';
my $count;
my $config;
my $dryrun;
my $sleep = 1;
my @planets = ();
my $planet_file;
my $waves = 1;
my $empire_name;
my $target;
my $shipyards;
my $timed;
my $debug = 0;
my $json;

# TODO:

# 2) Do rebuilds


GetOptions(
    'name=s'       => \$ship_name, # untested, conflicts with type?
    'type=s'       => \$ship_type,
    'count=i'      => \$count,
    'config=s'     => \$config,
    'dryrun'       => \$dryrun,
    'sleep=i'      => \$sleep,
    'planet=s@'    => \@planets,
    'planets=s'    => \$planet_file, # probably not useful here
    'waves=i'      => \$waves, # given captcha, may not work well :(
    'empire=s'     => \$empire_name,
    'target=s'     => \$target, # only x,y for now
    'fleet_size=i' => \$ships_per_fleet,
    'yard_file=s'  => \$shipyards,
    'timed'        => \$timed,
    'json=s'       => \$json,
);

# TODO check more required / conflicting args?
unless ($empire_name || $config) {
    die "Either the -empire or -config option must be provided\n";
}

unless ($target && $target =~ /^-?\d+,-?\d+/) {
    die "The -target option is required, and currently only the 'x,y' format is supported\n";
}

unless ($empire_name || @planets) {
    die "Unless using an -empire planets.js, one or more -planet options must be provided\n";
}


$waves = 1 if $dryrun;
$count //= $ships_per_fleet;

my ($x2, $y2) = split(/,/, $target);

$config      ||= join('/', $empire_name, 'empire.yml');
$planet_file ||= join('/', $empire_name, 'data/planets.js');
#$shipyards   ||= join('/', $empire_name, 'data/shipyards.js');


# read in planets if none provided
unless (@planets) {
    open(my $planets_fh, '<', $planet_file)
        or die "Unable to read planet list from $planet_file: $!";
    
    my $planets = '';
    {
        local $/;
        my $json_text = <$planets_fh>;
        @planets      = @{ decode_json( $json_text ) };
    }
}

# create client
my $GLC = Games::Lacuna::Client->new(
    cfg_file       => $config || "$FindBin::Bin/../lacuna.yml",
    rpc_sleep      => $sleep,
    prompt_captcha => 1,
);

my $empire = $GLC->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %Planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

my @types = split(/,/, $ship_type) unless $json;

my %inst = ();
if ($json) {
    %inst = %{ decode_json( $json ) };
    say "Instructions: ", Dumper(\%inst);
    @types = keys %{$inst{ships}};
}


WAVES: foreach my $i (1 .. $waves) {
    my %times  = ();
    my %ships  = ();
    my %bodies = ();
    my %dists  = ();
    my %counts = ();
    my $hit_time = '';
    
    if ($timed) {
        print "Target attack time for wave $i? ";
        chomp($hit_time = <STDIN>);
        
        if ($hit_time =~ /(\d\d\d\d)-(\d\d)-(\d\d)(?:T| )(\d\d):(\d\d)/) {
            $hit_time = DateTime->new(
                year      => $1,
                month     => $2,
                day       => $3,
                hour      => $4,
                minute    => $5,
                time_zone => 'GMT',
            );
        }
        else {
            say "Target time format is 'YYYY-MM-DD HH:MM'(seconds ignored)";
            # User should be able to just paste in ISO8601 format datetime string too (T)
            redo WAVES;
        }
        
        # turn $hit_time into a $dt
    }
    
    
    # get ships for planets (use list if provided?)
    foreach my $name (@planets) {
        say $name;
        
        $bodies{$name} = $GLC->body( id => $Planets{$name} );

        foreach my $type (@types) {
            if (! $json) {
                print "  How many ships of type $type to send? [$count] ";
                chomp($counts{$name}{$type} = <STDIN>);
                $counts{$name}{$type} ||= $count;
            }
            else {
                $counts{$name}{$type} = $inst{ships}{$type};
            }
            
            # XXX: If doing multiples, it may be more RPC (and latency) cost
            # efficient to filter mannually
            my $ships = get_ship_list($bodies{$name}, $type);
            next unless @{$ships};
            
            $ships{$name}{$type} = $ships;
            
            # calculate arrival time to target from each planet at $speed
            my $status = $bodies{$name}->get_status();
            
            my $dist = distance_to_target([$status->{body}{x}, $status->{body}{y}],
                                                    [$x2, $y2]);
            $dists{$name} = $dist;
            say "\t$type distaince to target: $dist";
            
            (my $slowest) = sort { $a->{speed} <=> $b->{speed} } @{$ships};
            say "\tUsing speed $slowest->{speed}";
            
            my $seconds = travel_time($dist, $slowest->{speed});
            say "\tSeconds to target: $seconds";
            
            $times{$name} = $seconds if ! $times{$name}
                                       || $times{$name} < $seconds;
        }
    }
    print "\n";
    
    
    # get the trip with the slowest time
    (my $use_time) = sort { $times{$b} <=> $times{$a} } keys %times;
    say "Longest trip time is from $use_time at $times{$use_time}";
    
    # If use_time is sooner than $dt, wait until $dt - use_time seconds
    # so fastest possible trip lands at (approx) $dt
    if ($timed) {
        my $now = DateTime->now(time_zone => 'GMT');
        say "GMT now is $now";
        $now->add(seconds => $times{$use_time});
        
        if ($hit_time < $now) {
            say "Ships selected can not arrive by $hit_time";
            redo WAVES;
        }
        
        my $dobj = $hit_time->subtract_datetime_absolute($now);
        my $wait = $dobj->seconds;
        my $clean = $wait % 60;
        say "$wait - $clean" if $debug;
        $wait -= $clean;
        
        say "Diff between $now and $hit_time is " . $dobj->seconds if $debug;
        say "Sleeping $wait seconds";
        sleep($wait);
    }
    
    
    my %num_sent = ();
    foreach my $name (@planets) {
        say $name;
        # TODO: Decrease time alittle each iteration to reduce per-planet gap due
        # command latency
        my $rate = int($dists{$name} / (($times{$use_time} - 300) / 3600));
        say " rate = $rate" if $debug;
    
        my $space_port = get_port($bodies{$name});
 
        foreach my $type (keys %{$ships{$name}}) {
            say "  ... $type";
            
            # just to be sure fuziness in math doesn't edge us a few
            # ticks over
            (my $slowest) = sort { $a->{speed} <=> $b->{speed} } @{$ships{$name}{$type}};
            my $speed = $slowest->{speed} < $rate ? $slowest->{speed} : $rate;
            say "\t using speed $speed (" . $slowest->{speed} . " < $rate)" if $debug;
            
            my @fleet = ();
            foreach my $ship (sort { $a->{speed} <=> $b->{speed} }
                              @{$ships{$name}{$type}})
            {
                push(@fleet, $ship);
                $num_sent{$name}{$type}++;
                
                my $finish = $num_sent{$name}{$type} == @{$ships{$name}{$type}}
                          || $num_sent{$name}{$type} == $counts{$name}{$type};
                                
                if (@fleet == $ships_per_fleet || $finish) {
                    say "\tSending fleet of ", scalar(@fleet),
                        " $type at speed $rate";# for arrival of $time";
                    
                    send_fleet(\@fleet, $space_port, $speed);
                    @fleet = ();
                }
                
                last if $finish;
            }
        }
    }
    
    my $total = 0;
    foreach my $p (keys %num_sent) {
        foreach my $t (keys %{$num_sent{$p}}) {
            $total += $num_sent{$p}{$t};
        }
    }
    say "Total ships sent: $total";
    
    #while ($total) {
    #    foreach my $name (@planets) {
    #        # loop over each planet and start rebuilding ships; use multiple shipyards if 3+ present (leaving one available)
    #        
    #        # when $count ships built by all planets, launch another wave
    #    }
    #}
    
    next WAVES if $dryrun;
    
    #foreach my $name (keys %num_sent) {
    #    foreach my $type (keys %{$num_sent{$name}}) {
    #        
    #        my @command = ('Grimtooth/bin/build_ships.pl',
    #                '-planet', $name,
    #                '-type',   $type,
    #                '-number', $num_sent{$name}{$type},
    #                '-yards',  $shipyards,
    #                '-config', $config,
    #        );
    #        
    #        say "Executing @command";
    #        system(@command);
    #    }
    #}
}


sub get_ship_list {
    my $planet = shift;
    my $type   = shift;
 

    my $filter;

    push(@{ $filter->{task} }, 'Docked');
    push(@{ $filter->{name} }, $ship_name) if $ship_name;
    push(@{ $filter->{type} }, $type) unless $ship_name;

    my $space_port = get_port($planet);
    
    my $ships = $space_port->view_all_ships(
        {
            no_paging => 1,
        },
        $filter ? $filter : (),
    )->{ships};

    return $ships;
}


my %ports = ();
sub get_port {
    my $planet = shift;
    
    return $ports{$planet->{id}} if $ports{$planet->{id}};
    
    my $result    = $planet->get_buildings;
    my $buildings = $result->{buildings};

    # Find the first Space Port
    my $space_port_id = List::Util::first {
            $buildings->{$_}->{name} eq 'Space Port'
        }
        grep { $buildings->{$_}->{level} > 0 and $buildings->{$_}->{efficiency} == 100 }
        keys %$buildings;

    my $space_port = $GLC->building( id   => $space_port_id,
                                     type => 'SpacePort' );

    return $space_port;
}


sub distance_to_target {
    my $s = shift; # [x, y]
    my $t = shift;
    
    my $x_dist = abs($s->[0] - $t->[0]);
    my $y_dist = abs($s->[1] - $t->[1]);
    
    $x_dist = $x_dist > 3000 / 2 ? abs($x_dist - 3000) : $x_dist;
    $y_dist = $y_dist > 3000 / 2 ? abs($y_dist - 3000) : $y_dist;
    
    my $dist = sqrt($x_dist**2 + $y_dist**2) * 100;
    
    return $dist;
}


sub travel_time {
    my $dist  = shift;
    my $speed = shift;
    
    my $hours = $dist / $speed;
    my $seconds = 60 * 60 * $hours;
    $seconds += 300; # game always adds 5 minutes
    
    return sprintf("%.0f", $seconds);
    
}


sub send_fleet {
    my $ships = shift;
    my $port  = shift;
    my $rate  = shift;
    
    #my $dt = DateTime->now();
    #$dt->add(seconds => $rate);
    
    return if $dryrun;
    
    my $return = $port->send_fleet(
            [ map { $_->{id} } @$ships ],
            { x => $x2, y => $y2 },
            $rate,
        );
    
#    print "Sent fleet to: $target_name\n";
#    print "Sent fleet to: $target_name from ",
#           $return->{fleet}->[0]->{ship}{from}{name},
#           " at speed: ", $return->{fleet}{fleet_speed}, "\n";
    
    for my $ship ( @{ $return->{fleet} } ) {
        printf(qq{\t%s "%s" arriving %s: %s:%s -> %s:%s at %d speed\n},
            $ship->{ship}{type_human},
            $ship->{ship}{name},
            $ship->{ship}{date_arrives},
            $ship->{ship}{from}{name},
            $ship->{ship}{from}{id},
            $ship->{ship}{to}{name},
            $ship->{ship}{to}{id},
            $ship->{ship}{fleet_speed}) if $debug;
    }
}
