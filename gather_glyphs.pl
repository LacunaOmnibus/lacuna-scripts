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


my %opts = ( );
GetOptions( \%opts,
           'planets=s',
           'config=s',
           'log=s',
           'to=s',
           'empire=s',
           'ship=s',
    );
$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets} ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}     ||= join('/', $opts{empire}, 'log/glyphs.log');
#warn Dumper(\%opts);

# open log
open(my $Log,'>>',$opts{log}) or die "Unable to log gather glyphs: $!";
print $Log "\n==========\nStarting gather: ", scalar(localtime), "\n";

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
my $glc = Games::Lacuna::Client->new(
    cfg_file       => $opts{config} || "$FindBin::Bin/../lacuna.yml",
    rpc_sleep      => 1.333, # 45 per minute, new default is 50 rpc/min
);
my $empire = $glc->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planet_data = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

my $to_id = $planet_data{$opts{to}}
  or die "--to planet not found";




foreach my $from (@{$planets}) {
    next if $from eq $opts{to};
    print $Log  "Gathering from $from\n";

    # Load planet data
    my $body = $glc->body( id => $planet_data{$from} );
    my $buildings = $body->get_buildings->{buildings};

    # Find the TradeMin
    my $trade_min_id = first {
        $buildings->{$_}->{name} eq 'Trade Ministry';
    } keys %$buildings;
    warn "Trade Ministry $trade_min_id\n";
    unless ($trade_min_id) {
        print $Log  "No trade ministry found on $from\n";
        next;
    }
    my $trade_min = $glc->building( id => $trade_min_id, type => 'Trade' );


    my $glyphs_result = $trade_min->get_glyph_summary;
    my @glyphs        = @{ $glyphs_result->{glyphs} };


    if ( ! @glyphs ) {
        print $Log "No glyphs available to push\n";
        next;
    }

    my $ship_id;

    if ($opts{ship}) {
        my $ships = $trade_min->get_trade_ships->{ships};

        my ($ship) =
          grep { $_->{name} =~ /\Q$opts{ship}/i } @$ships;

        if ($ship) {
            my $cargo_each = $glyphs_result->{cargo_space_used_each};
            my $cargo_req  = 0;
            for my $plan (@glyphs) {
                $cargo_req += $plan->{quantity} * $cargo_each;
            }

            if ( $ship->{hold_size} < $cargo_req ) {
                my $count = floor( $ship->{hold_size} / $cargo_each );
                my $total = 0;
                for my $plan ( sort srtname@glyphs ) {
                    if ( ( $total + $plan->{quantity} ) > $count ) {
                        $plan->{quantity} = $count - $total;
                        $total = $count;
                    }
                    else {
                        $total += $plan->{quantity};
                    }
                }
                warn sprintf
                  "Specified ship cannot hold all plans - only pushing %d plans\n",
                  $count;
            }
            $ship_id = $ship->{id};
        }
        else {
            print $Log "\tNo ship matching '$opts{ship}' found\n";
            print $Log "\twill attempt to push without specifying a ship\n";
        }
    }

    my @items;
    my $shipping = 0;
    for my $glyph (@glyphs) {
        push @items,
          {
            type     => "glyph",
            name     => $glyph->{name},
            quantity => $glyph->{quantity},
          }
          if ( $glyph->{quantity} > 0 );
    }

    #print "Items\n";
    for my $item (@items) {
        #  print "$item->{type} $item->{name} $item->{quantity}\n";
        $shipping += $item->{quantity};
    }

    # XXX: Need to gracefully handle more stuff to ship then ship cargo available

    my $return =
      $trade_min->push_items( $to_id, \@items, $ship_id
        ? { ship_id => $ship_id }
        : () );

    printf $Log "Pushed %d glyphs\n", $shipping;
    printf $Log "Arriving %s\n",      $return->{ship}{date_arrives};

}

# Destroy client object prior to global destruction to avoid GLC bug
undef $glc;

exit 0;
