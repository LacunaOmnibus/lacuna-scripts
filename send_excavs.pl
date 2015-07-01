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
GetOptions( \%opts, 'planets=s', 'config=s', 'use_glyph_data',
                    'data=s',    'glyphs=s', 'empire=s',
                    'sleep=f');

$opts{config}    ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets}   ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}       ||= join('/', $opts{empire}, 'log/send_excavs.log');
$opts{excav_map} ||= join('/', $opts{empire}, 'data/excav_map.json');
$opts{sleep}     ||= 1.333; # 45 per minute, new default is 50 rpc/min
#warn Dumper(\%opts);

# open log
open(my $Log,'>', $opts{log}) or die "Unable to log excav sends to $opts{log}: $!";
print $Log "\n==========\nStarting glyph search at: ", scalar(localtime), "\n";


# open excav map
open(my $map_fh, '<', $opts{excav_map}) or die "Unable to read map: $!";

my $map = {};
{
    local $/;
    my $json_text = <$map_fh>;
    $map          = decode_json( $json_text );
}

# read list of planets
open(my $planets_fh, '<', $opts{planets})
    or die "Unable to read planet list from $opts{planets}: $!";

my $planets = [];
{
    local $/;
    my $json_text = <$planets_fh>;
    $planets      = decode_json( $json_text );
}

my @prefered = qw(p34 p31 p39 p25 p28 p20 p13 p6 p9 p35);

# now the real work
my $GLC = Games::Lacuna::Client->new(
    cfg_file       => $opts{config} || "$FindBin::Bin/../lacuna.yml",
    rpc_sleep      => $opts{sleep}, 
);
my $empire = $GLC->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planet_data = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};


# for each planet
foreach my $planet_name (@{$planets}) {
    say $Log "Checking excavs for $planet_name";
    
    # get archmin
    my $planet = $GLC->body( id => $planet_data{$planet_name} );
    my $status = $planet->get_status();
    
    # next excavs needed
    my $excavs_to_send = check_arch_min($planet);
    
    # determine prefered planet types & counts for current planet excavs
    my %wanted = (p34 => 5, p31 => 1, p39 => 1, total => 7);
    
    # go through excavs map, by targeted type(s), and sort planets by distance
    # up to max distance (by default 4 hour trip for max excav?)
    my %dist_by_type = ();
    SEND_EXCAV: foreach my $type (@prefered) {
        
        foreach my $id (keys %{$map->{$type}}) {
            my $data = $map->{$type}{$id};
            my $dist = distance_to_target([$status->{body}{x}, $status->{body}{y}],
                                          [$data->{x},         $data->{y}]);
            
            $dist_by_type{$type}{$id}       = $data;
            $dist_by_type{$type}{$id}{dist} = $dist;
        }
        
        my $these = $dist_by_type{$type};
        foreach my $id ( sort {$these->{$a}{dist} <=> $these->{$b}{dist}} keys %{$these} ) {
            warn "== $type($id): $these->{$id}{dist}\n";
            
            # check if we already have an excav on id
            
            # send one if not
            
            # if error (out of excavs, etc), next planet
            
            # remove planet from %dist_by_type && $map (either we sent one or it already had one)
            delete($these->{$id});
            delete($map->{$type}{$id});
            
            # last if --$max_wanted{$type} == 0; # or something
            last SEND_EXCAV unless --$wanted{total};
            last unless --$wanted{$type};
        }
    }
    
    # If all wanted types processed and we still need to send excavs, try again with inf max
    
    # got through planets in type & distance order and send excavs until max(type) found
    # removing planets from list _and map_ if already have an excav, then go to next type.
    # if all targeted type / counts can't be met, go back through planets in type
    # preference order and send more excavs until planet has max excavs out
}


say $Log "$GLC->{total_calls} api calls made.";
say $Log "You have made $GLC->{rpc_count} calls today\n";    


sub check_arch_min {
    
}


sub distance_to_target {
    my $s = shift; # source [x, y]
    my $t = shift; # target [x, y]
    
    my $x_dist = abs($s->[0] - $t->[0]);
    my $y_dist = abs($s->[1] - $t->[1]);
    
    $x_dist = $x_dist > 3000 / 2 ? abs($x_dist - 3000) : $x_dist;
    $y_dist = $y_dist > 3000 / 2 ? abs($y_dist - 3000) : $y_dist;
    
    my $dist = sqrt($x_dist**2 + $y_dist**2) * 100;
    
    return $dist;
}

exit;
