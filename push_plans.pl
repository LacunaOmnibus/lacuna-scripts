#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util qw(first);
use Games::Lacuna::Client ();
use Getopt::Long qw(GetOptions);
use POSIX qw(floor);
use JSON;

use Data::Dumper;

my @from;
my $to;
my $ship_name;
my $match_plan;
my $max;
my $level_max;
my $no_halls;
my $cfg_file;
my @skip_list; # plans to not move

my %opts = ();
GetOptions(\%opts,
    'from=s@'     => \@from,
    'to=s'        => \$to,
    'ship=s'      => \$ship_name,
    'plan=s'      => \$match_plan,
    'max=i'       => \$max,
    'level_max=i' => \$level_max,
    'no_halls'    => \$no_halls,
    'config=s'    => \$cfg_file,
    'planet=s',
    'empire=s',
    'skip=s@'     => \@skip_list,
);
$cfg_file      ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets} ||= join('/', $opts{empire}, 'data/planets.js');
#$opts{log}     ||= join('/', $opts{empire}, 'log/glyph_search.log');
#$opts{glyphs}  ||= join('/', $opts{empire}, 'data/glyph_data.js');
#warn Dumper(\%opts);

usage() if !$to;

my $client = Games::Lacuna::Client->new(
    cfg_file  => $cfg_file,
    rpc_sleep => 1.333, # 45 per minute, new default is 50 rpc/min
    #debug    => 1,
);

# read list of planets
open(my $planets_fh, '<', $opts{planets})
    or die "Unable to read planet list from $opts{planets}: $!";

my $planet_list = '';
if (! @from) {
    local $/;
    my $json_text = <$planets_fh>;
    $planet_list  = decode_json( $json_text );
    @from         = @{$planet_list};
}

my $empire  = $client->empire->get_status->{empire};
my $planets = $empire->{planets};

# reverse hash, to key by name instead of id
my %planets_by_name = map { $planets->{$_}, $_ } keys %$planets;

my $to_id = $planets_by_name{$to}
  or die "--to planet not found";


foreach my $from (@from) {
    next if $from eq $to;
    print "Pushing from $from to $to\n";

    # Load planet data
    my $body = $client->body( id => $planets_by_name{$from} );
    my $buildings = $body->get_buildings->{buildings};

    # Find the TradeMin
    my $trade_min_id = first {
        $buildings->{$_}->{name} eq 'Trade Ministry';
    }
    keys %$buildings;

    my $trade_min = $client->building( id => $trade_min_id, type => 'Trade' );

    my $plans_result = $trade_min->get_plan_summary;
    my @plans        = @{ $plans_result->{plans} };

    if ($match_plan) {
        @plans =
          grep { $_->{name} =~ /$match_plan/i } @plans;
    }

    if ($no_halls) {
        print "\tFiltering out Halls\n";
        @plans = grep { $_->{name} !~ /Vrbansk/ } @plans;
    }
    if (@skip_list) {
        print "\tFiltering out skip list: @skip_list\n";
        foreach my $skip (@skip_list) {
            @plans = grep { $_->{name} !~ /$skip/ } @plans;
        }
    }
    

    if ($level_max) {
        @plans =
          grep { $_->{level} + $_->{extra_build_level} <= $level_max } @plans;
    }

    # if ( $max && @plans > $max ) {
    #     splice @plans, $max;
    # }
    if ($max) {
        my $total = 0;
        for my $plan ( sort srtname @plans ) {

            #    print $plan->{quantity}, ": ",
            #          $plan->{name}," ",
            #          $plan->{level},"+",
            #          $plan->{extra_build_level},"\n";
            if ( ( $total + $plan->{quantity} ) > $max ) {
                $plan->{quantity} = $max - $total;
                $total = $max;
            }
            else {
                $total += $plan->{quantity};
            }
        }
    }

    if ( !@plans ) {
        print "\tNo plans available to push\n";
        next;
    }

    my $ship_id;

    if ($ship_name) {
        my $ships = $trade_min->get_trade_ships->{ships};

        my ($ship) =
          grep { $_->{name} =~ /\Q$ship_name/i } @$ships;

        if ($ship) {
            my $cargo_each = $plans_result->{cargo_space_used_each};
            my $cargo_req  = 0;
            for my $plan (@plans) {
                $cargo_req += $plan->{quantity} * $cargo_each;
            }

            if ( $ship->{hold_size} < $cargo_req ) {
                my $count = floor( $ship->{hold_size} / $cargo_each );
                my $total = 0;
                for my $plan ( sort srtname@plans ) {
                    if ( ( $total + $plan->{quantity} ) > $count ) {
                        $plan->{quantity} = $count - $total;
                        $total = $count;
                    }
                    else {
                        $total += $plan->{quantity};
                    }
                }
                print sprintf
                  "Specified ship cannot hold all plans - only pushing %d plans\n",
                  $count;
            }
            $ship_id = $ship->{id};
        }
        else {
            print "\tNo ship matching '$ship_name' found\n";
            print "\twill attempt to push without specifying a ship\n";
        }
    }

    my @items;
    my $shipping = 0;
    for my $plan (@plans) {
        push @items,
          {
            type              => 'plan',
            plan_type         => $plan->{plan_type},
            level             => $plan->{level},
            extra_build_level => $plan->{extra_build_level},
            quantity          => $plan->{quantity},
          }
          if ( $plan->{quantity} > 0 );
    }

    #print "Items\n";
    for my $item (@items) {

      print "$item->{type} $item->{plan_type} $item->{level} $item->{extra_build_level} $item->{quantity}\n";
        $shipping += $item->{quantity};
    }

    my $return =
      $trade_min->push_items( $to_id, \@items, $ship_id
        ? { ship_id => $ship_id }
        : () );

    printf "\tPushed %d plans\n", $shipping;
    printf "\tArriving %s\n\n",     $return->{ship}{date_arrives};
}

exit;

sub srtname {
    my $abit = $a->{name};
    my $bbit = $b->{name};
    $abit =~ s/ //g;
    $bbit =~ s/ //g;
    my $aebl = ( $a->{extra_build_level} ) ? $a->{extra_build_level} : 0;
    my $bebl = ( $b->{extra_build_level} ) ? $b->{extra_build_level} : 0;
    $abit cmp $bbit
      || $a->{level} <=> $b->{level}
      || $aebl <=> $bebl;
}

sub usage {
    die <<END_USAGE;
Usage: $0 CONFIG_FILE
       --from      PLANET_NAME    (REQUIRED)
       --to        PLANET_NAME    (REQUIRED)
       --ship      SHIP NAME REGEX
       --plan      PLAN NAME REGEX
       --max       MAX No. PLANS TO PUSH
       --level_max Max level of plan (n+extra) to push
       --no_halls  Push everything (withing max & max_level) except halls

CONFIG_FILE  defaults to 'lacuna.yml'

Pushes plans between your own planets.

END_USAGE

}

