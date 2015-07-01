#!/usr/bin/env perl

use strict;
use warnings;

use feature qw(say);

use FindBin qw($Bin);
use lib "$FindBin::Bin/../lib";
use List::Util qw(first); #  min max sum reduce
use JSON;
use Getopt::Long qw(GetOptions);
use Games::Lacuna::Client ();

use Data::Dumper;


my %opts = ();
GetOptions( \%opts, 'planets=s', 'config=s',   'use_glyph_data',
                    'data=s',    'glyphs=s',   'empire=s',
                    'sleep=f',   'excav_map=s');

$opts{config}    ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets}   ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}       ||= join('/', $opts{empire}, 'log/map_search.log');
$opts{stars}     ||= join('/', $opts{empire}, 'data/star_map.json');
$opts{excav_map} ||= join('/', $opts{empire}, 'data/excav_map.json');
$opts{sleep}     ||= 1.333; # 45 per minute, new default is 50 rpc/min
#warn Dumper(\%opts);

# open log
open(my $Log,'>', $opts{log}) or die "Unable to log map build to $opts{log}: $!";
print $Log "\n==========\nStarting glyph search at: ", scalar(localtime), "\n";

# read list of planets
open(my $planets_fh, '<', $opts{planets})
    or die "Unable to read planet list from $opts{planets}: $!";

my $planets = '';
{
    local $/;
    my $json_text = <$planets_fh>;
    $planets      = decode_json( $json_text );
}

# now the real work
my $GLC = Games::Lacuna::Client->new(
    cfg_file       => $opts{config} || "$FindBin::Bin/../lacuna.yml",
    rpc_sleep      => $opts{sleep}, 
);
my $empire = $GLC->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planet_data = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

my %planets_seen = ();
my %map          = ();
my %stations     = ();

foreach my $planet_name (@{$planets}) {
    if ($planets_seen{$planet_name}) {
        # TODO: Eventually make this a little more sophisticated in case a
        # planet was seen at the edge of the scan area
        say $Log "$planet_name area already mapped";
        next;
    }
    $planets_seen{$planet_name}++;
    
    my $planet    = $GLC->body(id => $planet_data{$planet_name});
    my $result    = $planet->get_buildings;
    #my ($x,$y)    = @{$result->{status}->{body}}{'x','y'};
    my $buildings = $result->{buildings};
    
    # Find the Oracle
    my $oracle_id = first {
          $buildings->{$_}->{url} eq '/oracleofanid'
    } keys %$buildings;
    
    unless ($oracle_id) {
        say $Log "No oracle on $planet_name";
        next;
    }
    say $Log "Mapping $planet_name area";

    my $oracle =  $GLC->building( id => $oracle_id, type => 'OracleOfAnid' );
    
    
    my (@stars, $page, $done);
    while (! $done) {
        my $param = {
          session_id  => $GLC->{session_id},
          building_id => $oracle_id,
          page_number => ++$page,
          page_size   => 200,
        };
        my $slist = $oracle->get_probed_stars($param);
        push @stars, @{$slist->{stars}};
        $done = 200 * $page >= $slist->{star_count};
    }
    
    
    foreach my $system (@stars) {
        foreach my $body (@{$system->{bodies}}) {
            $planets_seen{$body->{name}}++;
            my $type  = $body->{image};
            my $class = 'unknown';
            
            if ($type =~ s/([p]\d+)-\d/$1/) {
                $class = 'planet';
            }
            if ($type =~ s/([a]\d+)-\d/$1/) {
                $class = 'asteroid';
            }
            elsif ($type =~ s/pg(\d+)-\d/pg$1/) {
                $class = 'gas_giant';
            }
            elsif ($type =~ s/station-(\d)/ss$1/) {
                $class = 'space_station';
            }
            elsif ($type =~ s/debris(\d+)-\d/d$1/) {
                $class = 'debris';
            }
            
            $map{$class}{$body->{x}}{$body->{y}} = {
                name  => $body->{name},
                #image => $body->{image},
                id    => $body->{id},
                type  => $type,
            };
            
            if (exists $body->{station}) {
                my $ss_id = $body->{station}{id};
                
                $map{$class}{$body->{x}}{$body->{y}}{ss} = $ss_id;

                next if $stations{$ss_id};
                
                $stations{$ss_id} = {
                    name      => $body->{station}{name},
                    is_allied => check_station($ss_id),
                    x         => $body->{station}{x},
                    y         => $body->{station}{y},
                };
            }   
        }
    }
}


say $Log "Converting map to json";
my $json = JSON::to_json(\%map, {pretty => 1});


say $Log "Writing map file";
open(my $mapfile, '>', $opts{stars}) or die "Can't write map $opts{stars}: $!";

say $mapfile $json;

say $Log "$GLC->{total_calls} api calls made.";
say $Log "You have made $GLC->{rpc_count} calls today\n";    

say $Log "Making for_excavs file";

my %excav_map = ();
foreach my $x (keys %{$map{planet}}) {
    foreach my $y (keys %{$map{planet}{$x}}) {
        my $planet = $map{planet}{$x}{$y};
        
        # TODO: Actually check if is_allied
        # maybe move into primary map anyway?
        if (exists $planet->{ss}) {
            next unless $stations{ $planet->{ss} }{is_allied};
        }   
        
        $excav_map{ $planet->{type} }{ $planet->{id} } = {
            x => $x,
            y => $y,
        };
    }
}

my $e_json = JSON::to_json(\%excav_map, {pretty => 1});
open(my $excav_file, '>', $opts{excav_map}) or die "Can't write $opts{excav_map}: $!";

print $excav_file $e_json;


sub check_station {
    my $id = shift;
    my $ss = $GLC->body(id => $id);
    my $status = $ss->get_status();
    
    warn Dumper($status);
    
    my $is_allied = 0;
    
    exit;
    
    return $is_allied;
}

exit;

