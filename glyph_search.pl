#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$FindBin::Bin/../lib";
use List::Util qw(first min max sum reduce);
use JSON;
use Getopt::Long qw(GetOptions);
use Games::Lacuna::Client ();

use Data::Dumper;


my %opts = ();
GetOptions( \%opts, 'planets=s', 'config=s', 'use_glyph_data',
                    'data=s',    'glyphs=s', 'empire=s');

$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets} ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}     ||= join('/', $opts{empire}, 'log/glyph_search.log');
$opts{glyphs}  ||= join('/', $opts{empire}, 'data/glyph_data.js');
#warn Dumper(\%opts);

# open log
open(my $Log,'>>', $opts{log}) or die "Unable to log glyph search to $opts{log}: $!";
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


# update log of glyphs for planets
unless ($opts{use_glyph_data}) {
    my @args = ();
    foreach my $planet (@{$planets}) {
        push(@args, ('-planet', qq{"$planet"}));
    }
    push(@args, ('-conf', $opts{config}));
    push(@args, ('-data', $opts{glyphs}));
    #push(@args, ());
    #system("$Bin/get_glyphs.pl", @args);
    #print $Log "$Bin/get_glyphs.pl @args";
    print $Log `$Bin/get_glyphs.pl @args`;
}

# read in glyph data
open(my $glyphs_fh, '<', $opts{glyphs})
    or die "Unable to read glyphs list from $opts{glyphs}: $!";

my $glyph_data = '';
{
    local $/;
    my $json_text = <$glyphs_fh>;
    $glyph_data   = decode_json( $json_text );
}

# count how many of each glyph type exist on the planets
print $Log "Calculating glyph search priority.\n";

my %glyph_count = (
    "goethite"     => 0, #A
    "gypsum"       => 0, #A
    "halite"       => 0, #A
    "trona"        => 0, #A
    "anthracite"   => 0, #B
    "bauxite"      => 0, #B
    "gold"         => 0, #B
    "uraninite"    => 0, #B
    "kerogen"      => 0, #C
    "methane"      => 0, #C
    "sulfur"       => 0, #C
    "zircon"       => 0, #C
    "beryl"        => 0, #D
    "fluorite"     => 0, #D
    "magnetite"    => 0, #D
    "monazite"     => 0, #D
    "chalcopyrite" => 0, #E
    "chromite"     => 0, #E
    "galena"       => 0, #E
    "rutile"       => 0, #E
);

foreach my $planet (keys %{$glyph_data}) {
    foreach my $glyphs (@{$glyph_data->{$planet}{glyphs}}) {
        $glyph_count{$glyphs->{type}} += $glyphs->{quantity};
    }
}



# determine prioritized list of glyphs to search for

my %recipes = (
    A => [qw/ goethite  halite      gypsum        trona     /],
    B => [qw/ gold      anthracite  uraninite     bauxite   /],
    C => [qw/ kerogen   methane     sulfur        zircon    /],
    D => [qw/ monazite  fluorite    beryl         magnetite /],
    E => [qw/ rutile    chromite    chalcopyrite  galena    /],
);

my %weighted_recipies = ();
foreach my $recipe (keys %recipes) {
    my $total = 0;
    my $min_type = '';
    foreach my $type (@{$recipes{$recipe}}) {
        $weighted_recipies{$recipe}{total} += $glyph_count{$type};
    }

    $weighted_recipies{$recipe}{glyphs} = [
                            sort { $glyph_count{$a} <=> $glyph_count{$b} }
                                @{$recipes{$recipe}}
                        ];

    # calculate recipe weight
    my $t1 = $weighted_recipies{$recipe}{glyphs}[0];
    my $t2 = $weighted_recipies{$recipe}{glyphs}[1];

    $weighted_recipies{$recipe}{weight} = $glyph_count{$t2} - $glyph_count{$t1};
    # XXX: is there a way, and is it worth, using total to nudge weight?
    # or perhaps by some factor of 3 & 4 to handle counts like 1,2,50,100
}

my @ordered_recipies = sort {
    $weighted_recipies{$b}{weight} <=> $weighted_recipies{$a}{weight} }
        keys %weighted_recipies;

my @glyph_need = sort { $glyph_count{$a} <=> $glyph_count{$b} } keys %glyph_count;

my @glyph_search_order = ();
my %done = ();
foreach my $recipe (@ordered_recipies) {
    my $type = $weighted_recipies{$recipe}{glyphs}[0];
    push(@glyph_search_order, $type);
    $done{$type} = 1;
}

foreach my $type (sort { $glyph_count{$a} <=> $glyph_count{$b} } keys %glyph_count) {
    push(@glyph_search_order, $type) unless $done{$type};
}

#print $Log "Recipe weights:\n", Dumper(\%weighted_recipies);
{
$Data::Dumper::Indent = 0;
print $Log "Using search order:\n", Dumper(\@glyph_search_order), "\n";
}

# now the real work
my $glc = Games::Lacuna::Client->new(
    cfg_file       => $opts{config} || "$FindBin::Bin/../lacuna.yml",
    rpc_sleep      => 1.333, # 45 per minute, new default is 50 rpc/min
);
my $empire = $glc->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planet_data = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

# go to each planet and search for the highest priority glyph possible
my $digging = {};

foreach my $planet_name (@{$planets}) {
    print $Log  "Inspecting $planet_name\n";

    my $planet    = $glc->body(id => $planet_data{$planet_name});
    my $result    = $planet->get_buildings;
    my $buildings = $result->{buildings};
    my %status    = ();
    my $available_ores = ();

    my ($arch, $level, $seconds_remaining) = find_arch_min($buildings, $glc);
    if ($arch) {
        print $Log "\tFound an archaeology ministry on $planet_name\n";
        if ($seconds_remaining) {
            print $Log  "\t-- Ministry is already on a dig.\n";
            next;
        }
        else {
            $available_ores =
                $arch->get_ores_available_for_processing->{ore};
            #print Dumper($available_ores);
        }
    } else {
        print $Log "\t-- No archaeology ministry on $planet_name\n";
        next;
    }

    #if ($opts{'min-arch'} and $status->{archlevel}{$planet} < $opts{'min-arch'}) {
    #    output("$planet is not above specified Archaeology Ministry level ($opts{'min-arch'}), skipping dig.\n");
    #    next;
    #}
    my $ore = determine_ore(
        $opts{'min-ore'} || 11_000,
        $opts{'preferred-ore'} || \@glyph_search_order || [],
        $available_ores,
    );

    if ($ore) {
        if ($opts{'dry-run'}) {
            print $Log "\tWould have started a dig for $ore on $planet_name.\n";
        }
        else {
            print $Log "\tStarting a dig for $ore on $planet_name...\n";
            my $ok = eval {
                $arch->search_for_glyph($ore);
                return 1;
            };
            unless ($ok) {
                my $e = $@;
                print $Log ("Error starting dig: $e\n");
            }
        }
    }
    else {
        print $Log "\t-- Not starting a dig on $planet_name; not enough of any type of ore.\n";
    }
}

sub find_arch_min {
    my ($buildings, $glc) = @_;

    # Find the Archaeology Ministry
    my $arch_id = first {
            $buildings->{$_}->{name} eq 'Archaeology Ministry'
    }
    grep { $buildings->{$_}->{level} > 0 and $buildings->{$_}->{efficiency} == 100 }
    keys %{$buildings};

    return if not $arch_id;

    my $building  = $glc->building(
        id   => $arch_id,
        type => 'Archaeology',
    );
    my $level     = $buildings->{$arch_id}{level};
    my $remaining = $buildings->{$arch_id}{work} ? $buildings->{$arch_id}{work}{seconds_remaining} : undef;

    return ($building, $level, $remaining);
}

sub determine_ore {
    my ($min, $preferred, $ore) = @_;

    foreach my $type (@{$preferred}) {
        #print "$type if $ore->{$type} && $ore->{$type} >= $min\n";
        return $type if $ore->{$type} && $ore->{$type} >= $min;
    }
}

# Destroy client object prior to global destruction to avoid GLC bug
undef $glc;

exit 0;
