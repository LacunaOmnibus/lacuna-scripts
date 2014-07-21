#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use JSON;



my %opts = (
    min     => 2, # should be ~1/2 your max excavs in use, rounded down, but not less than 2
);
GetOptions( \%opts,
           'planets=s',
           'config=s',
           'log=s',
           'min=i',
           'empire=s',
           'ships=s',
    );

$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets} ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}     ||= join('/', $opts{empire}, 'log/excavs-summary.log');
$opts{ships}   ||= join('/', $opts{empire}, 'data/docked_ships.js');


# open log
open(my $Log,'>>',$opts{log}) or die "Unable to log gather glyphs: $!";
print $Log "\n==========\nStarting excavator builds: ", scalar(localtime), "\n";

# read list of planets
open(my $planets_fh, '<', $opts{planets})
    or die "Unable to read planet list from $opts{planets}: $!";

my $planets = '';
{
    local $/;
    my $json_text = <$planets_fh>;
    $planets      = decode_json( $json_text );
}


# update the list of ships
system('Grimtooth/bin/docked_ships.pl', $opts{config},
       '-data', $opts{ships});

# read list of ships
open(my $ships_fh, '<', $opts{ships})
    or die "Unable to read planet list from $opts{ships}: $!";

my $ships = '';
{
    local $/;
    my $json_text = <$ships_fh>;
    $ships        = decode_json( $json_text );
}

my $shipyards = join('/', $opts{empire}, 'data/shipyards.js');
print $Log "Starting build run, using $shipyards\n";

foreach my $planet (@{$planets}) {
    print $Log "Checking excavator supply on $planet\n";

    my $count = 0;
    foreach my $ship (@{$ships->{$planet}}) {
        $count++ if $ship->{type} eq 'excavator';
    }

    print $Log "\tFound $count excavators\n";
    next unless $count < $opts{min};

    my $target = $opts{min} - $count;

    print $Log "\tBuilding $target excavators\n";

    print $Log "WTF command?!?\n", join(' ',(
            'Grimtooth/bin/build_ships.pl',
            '-planet', $planet,
            '-type',   'excav',
            '-number', $target,
            '-yards',  $shipyards,
            '-config', $opts{config},
    )), "\n";

    system('Grimtooth/bin/build_ships.pl',
            '-planet', $planet,
            '-type',   'excav',
            '-number', $target,
            '-yards',  $shipyards,
            '-config', $opts{config},
    );
}

print "Done $0\n";
