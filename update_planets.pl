#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use Games::Lacuna::Client ();
use JSON;
use Data::Dumper;

my %opts;
$opts{data}   = "data/planets.js";
$opts{config} = 'lacuna.yml';

print "=== Starting\n";

GetOptions(\%opts, 'data=s', 'config=s', 'debug');

open( my $planets_fh, ">", "$opts{data}" )
    or die "Could not write to $opts{data}\n";

unless ( $opts{config} and -e $opts{config} ) {
    $opts{config} = eval {
        require File::HomeDir;
        require File::Spec;
        my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
        File::Spec->catfile( $dist, 'login.yml' ) if $dist;
    };
    unless ( $opts{config} and -e $opts{config} ) {
        die "Did not provide a config file";
    }
}

#print "Loading game client...\n";
my $glc = Games::Lacuna::Client->new(
    cfg_file  => $opts{config},
    rpc_sleep => 2,
    debug     => $opts{debug},
);
#print "\tLoaded\n";

# Load the planets
my $empire = $glc->empire->get_status->{empire};
#print "Have empire\n";

# reverse hash, to key by name instead of id
my %planets = map { $empire->{planets}{$_}, $_ } keys %{ $empire->{planets} };

# Scan each planet and sort out the UNSC starbases
my @planet_names  = ();#grep { ! /^(UNSC|SASS|ZASS)/ } sort keys %planets;
my @station_names = ();

for my $name ( sort keys %planets ) {
    print '.';
    my $planet = $glc->body( id => $planets{$name} );
    my $result = $planet->get_buildings;
    if ($result->{status}{body}{type} eq 'space station') {
        push(@station_names, $name);
    }
    else { push(@planet_names, $name); }
}
print "\n";


my $json = JSON->new->utf8(1);
$json = $json->pretty(    [1] );
$json = $json->canonical( [1] );

print $planets_fh $json->pretty->canonical->encode(\@planet_names);
close($planets_fh);

if ($opts{config} && $opts{config} =~ /Grimtooth/) {
    my $fn = $opts{data};
    $fn =~ s/planets/stations/;

    open( my $fh, '>', $fn ) or die "Could not write to $opts{data}\n";
    print $fh $json->pretty->canonical->encode(\@station_names);
    close($fh);
}


exit;
