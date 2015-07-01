#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/../lib",
         '/home/squinlan/perl5/lib/perl5',
         '/home/squinlan/devel/lacuna/Games-Lacuna-Client/lib');
use Getopt::Long qw(GetOptions);
use JSON;
use Games::Lacuna::Client ();
use Games::Lacuna::Client::Types qw( building_type_from_label get_tags );
use List::Util   qw( first );

use Data::Dumper;

my %opts = (
);
GetOptions( \%opts,
           'planets=s@',
           'config=s',
           'log=s',
           'max=i',
           'empire=s',
           'blacklist=s@',
           'data=s',
           'sleep=f',
    );

$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{log}     ||= join('/', $opts{empire}, 'log/upgrades.log');
$opts{data}    ||= join('/', $opts{empire}, 'data/upgrades.js');

my @blacklist = $opts{blacklist} ? @{$opts{blacklist}} : ();

my %types = (
    spaceport => ['Space Port'],
    saw       => ['Shield Against Weapons'],
    ships     => [
                  'Shipyard',
                  'Propulsion System Factory',
                  'Pilot Training Facility',
                  'Cloaking Lab',
                  'Crashed Ship Site',
                 ],
    am        => ['Archaeology Ministry'],
    food      => [
                  'Apple Cider Bottler',
                  'Malcud Burger Packer',
                  'Algae Syrup Bottler',
                  'Wheat Farm',
                  'Potato Patch',
                  'Corn Plantation',
                  'Apple Orchard',
                  'Corn Meal Grinder',
                  'Potato Pancake Factory',
                  'Bread Bakery',
                  'Cheese Maker',
                  'Dairy Farm',
                  'Beeldeban Protein Shake Factory',
                  'Denton Root Chip Frier ',
                  'Park',
                  'Theme Park',
                  'Amalgus Bean Soup Cannery',
                  'Lapis Pie Bakery',
                  ],
    intel     => [
                  'Security Ministry',
                  'Espionage Ministry',
                  'Intelligence Ministry',
                  'Politics Training',
                  'Intel Training',
                  'Theft Training',
                  'Mayhem Training',
                 ],
    storage   => [
                  'Ore Storage Tanks',
                  'Energy Reserve',
                  'Water Storage Tank',
                  'Food Reserve',
                  'Distribution Center',
                  'Planetary Command Center',
                  'Stockpile',
                 ],
    shipping  => [
                  'Trade Ministry',
                  'Subspace Transporter',
                  'Shipyard',
                 ],
    happy     => [
                    'Park',
                    'Theme Park',
                    'Entertainment District',
                    'Luxury Housing',
                    'Network 19 Affiliate',
                    'Kalavian Ruins',
                 ],
    ss        => [ 'Space Station' ],
);


# open log
open(my $Log, '>>' ,$opts{log}) or die "Unable to log upgrades: $!";
#select($Log);
print "\n==========\nStarting building upgrades $opts{log}: ", scalar(localtime), "\n";

# get build conf
my $json = JSON->new->utf8(1);
$json = $json->pretty([1]);
$json = $json->canonical([1]);

# read list of planets
open(my $data_fh, '<', $opts{data})
    or die "Unable to read planet list from $opts{planets}: $!";

my $upgrade_data = '';
{
    local $/;
    my $json_text = <$data_fh>;
    $upgrade_data      = decode_json( $json_text );
}

unless ($upgrade_data) {
  die "Could not read $opts{data}\n";
}
   #"4667728" : {
   #   "efficiency" : "100",
   #   "image" : "spaceport5",
   #   "level" : "5",
   #   "name" : "Space Port",
   #   "pending_build" : {
   #      "end" : "21 08 2014 12:34:39 +0000",
   #      "seconds_remaining" : 3177,
   #      "start" : "21 08 2014 11:27:55 +0000"
   #   },
   #   "url" : "/spaceport",
   #   "x" : "3",
   #   "y" : "3"
   #}


my $glc = Games::Lacuna::Client->new(
    cfg_file       => $opts{config},
    prompt_captcha => 1,
    rpc_sleep      => $opts{sleep},
    # debug    => 1,
);

my $empire  = $glc->empire->get_status->{empire};
my %planets = reverse %{ $empire->{planets} };


# loop over planets
PLANET: foreach my $planet (sort keys %{$upgrade_data}) {
    # skip planet if blacklisted
    next if grep { $planet eq $_ } @blacklist;

    $opts{max} ||= $upgrade_data->{$planet}{max} || 30;

    print "$planet: Upgrading buildings of type(s): ",
               join(', ', @{$upgrade_data->{$planet}{types}}),
               " to max level $opts{max}\n";

    my @names = ();
    foreach my $type (@{$upgrade_data->{$planet}{types}}) {
        push(@names, @{$types{$type}});
    }

    # get buildings
    my $body      = $glc->body( id => $planets{$planet} );
    my $buildings = $body->get_buildings->{buildings};

    #waste_is($body);
    #exit;

    my $upgrades = 0;

    # loop over those, in current level order, ascending
    foreach my $id (
        sort { $buildings->{$a}{level} <=> $buildings->{$b}{level} }
            keys %$buildings)
    {
        last if $buildings->{$id}{level} >= $opts{max};
        next if exists $buildings->{$id}{pending_build};
        next unless grep { $buildings->{$id}{name} =~ /$_/ } @names;
        next if $buildings->{$id}{name} =~ /Junk/; # skip junk buildings - HACK

        # next planet if queue full

        # check waste room & waste alert!
        # next if not enough room in waste

        print "\t$buildings->{$id}{name} ($buildings->{$id}{level})\n";

        # try to upgrade the building
        my $building = '';
        my $type = building_type_from_label( $buildings->{$id}{name} );

        if ($buildings->{$id}{name} =~ /Potato Pancake Factory/) {
            print "$buildings->{$id}{name} returned $type, trying Pancake\n";
            $type = 'Pancake';
        }


        eval { $building = $glc->building( id => $id, type => $type ) };#, type => 'Intelligence'
        if ($@) {
            print "Unable to load building for orders: $@\n";
            next;
        }


        #print Dumper($building);
        my $res = '';

        eval { $res = $building->upgrade() };
        if ($@) {
            # log & next
            if ($@ =~ /1009/ && $@ =~ /build queue/) {
                print "\tBuild queue is full, $planet done for now.\n\n";
                next PLANET;
            }
            # $@ =~ /complete the pending build first/i
            print "Upgrade error: $@\n";
            next;
        }
        else {
            $upgrades++;
            #print "And? " . Dumper($res) . "\n";
        }


        # next planet if current complete time > x hours?

    }

    if ($upgrades) {
        print "\t$upgrades upgrades initiated\n\n"
    }
    else {
        print "\tNothing to do on $planet\n"
    }
}


sub waste_is {
    my $body = shift;

    my $result = $body->get_buildings;

    my ($x,$y) = @{$result->{status}->{body}}{'x','y'};
    my $buildings = $result->{buildings};

    # Find the trade min
    my $tm_id = first {
          $buildings->{$_}->{url} eq '/trade'
    } keys %$buildings;

    die "No trade ministry on this planet\n"
        if !$tm_id;

    my $tm =  $glc->building( id => $tm_id, type => 'Trade' );

    unless ($tm) {
      print "No Trade Ministry!\n";
      exit;
    }

    my $output;
    $result = $tm->view_waste_chains();

    my $curr_chain = $result->{waste_chain}->[0];
    my $curr_body = $result->{status};
    $result = $tm->get_waste_ships();
    my $curr_ships = $result->{ships};

    my $chain_id = $curr_chain->{id};
    my $bod_whour = $curr_body->{body}->{waste_hour};

    my $waste_hour = $curr_chain->{waste_hour};
    if ($curr_chain->{percent_transferred} < 100) {
      $waste_hour = int($waste_hour * $curr_chain->{percent_transferred}/100);
    }
    my $waste_prod = $bod_whour + $waste_hour;

    my @ships_chain = grep { $_->{task} eq 'Waste Chain' } @$curr_ships;
    my @ships_avail = grep { $_->{task} eq 'Docked'      } @$curr_ships;

    printf "%d waste produced, %d waste on current chain for %d/hour net\n",
            $waste_prod, $waste_hour, $bod_whour;
    printf "%d ships on waste chain, %d additional available\n",
            scalar @ships_chain, scalar @ships_avail;


    my $resources = $tm->get_stored_resources->{resources};
    #print "==== $resources->{waste}\n"

}
