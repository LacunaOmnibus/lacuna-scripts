#!/usr/bin/env perl
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;
use Getopt::Long qw(GetOptions);
use List::Util   qw( first );
use Date::Parse;
use Date::Format;
use utf8;

my %opts = (
  low   => 7,
  high  => 30,
  sleep => 1,
);

my $ok = GetOptions(\%opts,
    'planet=s',
    'help|h',
    'datafile=s',
    'config=s',
    'make_plan=s@',
    'split_plan',
    'subsidize',
    'empire=s',
    'view',
    'log=s',
    'low=i',
    'high=i',
    'sleep=f',
);

$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{log}     ||= join('/', $opts{empire}, 'log/dillon_output.js');

unless ( $opts{config} and -e $opts{config} ) {
  $opts{config} = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  unless ( $opts{config} and -e $opts{config} ) {
    die "Did not provide a config file";
  }
}
usage() if ($opts{h});
if (!$opts{planet}) {
  print "Need planet with Dillon Forge set with --planet!\n";
  usage();
}

my $json = JSON->new->utf8(1);

my $params = {};
$opts{view} = 1 unless ( defined($opts{make_plan}) or
                         defined($opts{split_plan}) or
                         defined($opts{subsidize}) );
my $Log;
open($Log, ">", $opts{log}) || die "Could not create $opts{log}";

my $glc = Games::Lacuna::Client->new(
    cfg_file  => $opts{config},
    rpc_sleep => $opts{sleep},
  # debug    => 1,
);

my $data  = $glc->empire->view_species_stats();
my $ename = $data->{status}->{empire}->{name};
my $ststr = $data->{status}->{server}->{time};

# reverse hash, to key by name instead of id
my %planets = map { $data->{status}->{empire}->{planets}{$_}, $_ }
                keys %{ $data->{status}->{empire}->{planets} };

# Load planet data
my $body   = $glc->body( id => $planets{$opts{planet}} );

my $result = $body->get_buildings;

my ($x,$y) = @{$result->{status}->{body}}{'x','y'};
my $buildings = $result->{buildings};

# Find the forge
my $tdf_id = first {
      $buildings->{$_}->{url} eq '/thedillonforge'
} keys %$buildings;

die "No Forge on this planet\n"
    if !$tdf_id;

my $tdf =  $glc->building( id => $tdf_id, type => 'TheDillonForge' );

unless ($tdf) {
  print "No Forge!\n";
  exit;
}

my $tdf_out;
if ($opts{view}) {
  $tdf_out = $tdf->view();
}
elsif ($opts{make_plan}) {
    foreach my $name (@{$opts{make_plan}}) {
        foreach my $level ($opts{low} .. $opts{high}) {
            print "Making Level $level of $name. - ";
            $tdf_out = $tdf->make_plan("$name", $level);

            if ($opts{subsidize}) {
                sleep 1;
                print "sub - ";
                $tdf_out = $tdf->subsidize();
            }

            print "done\n";
        }
    }
}
#elsif ($opts{split_plan}) {
#    foreach my $name (@{$opts{make_plan}}) {
#
#        $tdf_out = $tdf->split_plan("Permanent::CitadelOfKnope", 19, 0);
##    $tdf_out = $tdf->subsidize();
#}
#else {
#  die "Nothing to do!\n";
#}

print $Log $json->pretty->canonical->encode($tdf_out->{tasks});
close($Log);

if ($opts{view}) {
  print $json->pretty->canonical->encode($tdf_out->{tasks});
}
else {
  print $json->pretty->canonical->encode($tdf_out->{tasks});
}

#  print "$glc->{total_calls} api calls made.\n";
#  print "You have made $glc->{rpc_count} calls today\n";
exit; 

sub usage {
  die <<"END_USAGE";
Usage: $0 CONFIG_FILE
       --planet         PLANET_NAME
       --CONFIG_FILE    defaults to lacuna.yml
       --logfile        Output file, default log/dillon_output.js
       --config         Lacuna Config, default lacuna.yml
       --make_plan      Make a Plan from Level 1 plans
       --split_plan     Split a Plan into glyphs
       --subsidize      Pay 2e to finish current work
       --view           View options

END_USAGE

}

sub plan_types {
    my @plan_types = qw(
        Energy::Singularity
        Espionage
        Food::Bread
        Food::Burger
        Food::Chip
        Food::Cider
        Food::CornMeal
        Food::Malcud
        Food::Pancake
        Food::Pie
        Food::Shake
        Food::Soup
        Food::Syrup
        Intelligence
        LCOTa
        LCOTb
        LCOTc
        LCOTd
        LCOTe
        LCOTf
        LCOTg
        LCOTh
        LCOTi
        Module::ArtMuseum
        Module::CulinaryInstitute
        Module::IBS
        Module::OperaHouse
        Module::Parliament
        Module::PoliceStation
        Module::StationCommand
        Module::Warehouse
        MunitionsLab
        Observatory
        Ore::Refinery
        Permanent::AlgaePond
        Permanent::AmalgusMeadow
        Permanent::Beach1
        Permanent::Beach10
        Permanent::Beach11
        Permanent::Beach12
        Permanent::Beach13
        Permanent::Beach2
        Permanent::Beach3
        Permanent::Beach4
        Permanent::Beach5
        Permanent::Beach6
        Permanent::Beach7
        Permanent::Beach8
        Permanent::Beach9
        Permanent::BeeldebanNest
        Permanent::BlackHoleGenerator
        Permanent::CitadelOfKnope
        Permanent::CrashedShipSite
        Permanent::Crater
        Permanent::DentonBrambles
        Permanent::GasGiantPlatform
        Permanent::GeoThermalVent
        Permanent::GratchsGauntlet
        Permanent::GreatBallOfJunk
        Permanent::Grove
        Permanent::HallsOfVrbansk
        Permanent::InterDimensionalRift
        Permanent::JunkHengeSculpture
        Permanent::KalavianRuins
        Permanent::Lagoon
        Permanent::Lake
        Permanent::LapisForest
        Permanent::LibraryOfJith
        Permanent::MalcudField
        Permanent::MetalJunkArches
        Permanent::NaturalSpring
        Permanent::OracleOfAnid
        Permanent::PantheonOfHagness
        Permanent::PyramidJunkSculpture
        Permanent::Ravine
        Permanent::RockyOutcrop
        Permanent::Sand
        Permanent::TempleOfTheDrajilites
        Permanent::TerraformingPlatform
        Permanent::Volcano
        PlanetaryCommand
        SAW
        Security
        Shipyard
        SpacePort
        Trade
        Waste::Digester
        Waste::Sequestration
        Water::AtmosphericEvaporator
        Water::Reclamation
    );

  return \@plan_types;
}
