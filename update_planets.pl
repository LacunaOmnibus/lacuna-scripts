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

GetOptions(\%opts, 'data=s', 'config=s', 'debug');

open( DUMP, ">", "$opts{data}" ) or die "Could not write to $opts{data}\n";

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

my $glc = Games::Lacuna::Client->new(
    cfg_file  => $opts{config},
    rpc_sleep => 2,
    debug     => $opts{debug},
);


# Load the planets
my $empire = $glc->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planets = map { $empire->{planets}{$_}, $_ } keys %{ $empire->{planets} };

# Scan each planet and sort out the UNSC starbases
my @planet_names = grep { ! /UNSC/ } sort keys %planets;


my $json = JSON->new->utf8(1);
$json = $json->pretty(    [1] );
$json = $json->canonical( [1] );

print DUMP $json->pretty->canonical->encode(\@planet_names);
close(DUMP);
exit;
