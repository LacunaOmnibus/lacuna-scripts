#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long qw(GetOptions);
use JSON;
use List::Util            qw( first );
use Games::Lacuna::Client ();

use Data::Dumper;

my %opts = (
);
GetOptions( \%opts,
           'planets=s',
           'config=s',
           'log=s',
           'min=i',
           'empire=s',
           'sleep=f',
    );

$opts{config}  ||= join('/', $opts{empire}, 'empire.yml');
$opts{planets} ||= join('/', $opts{empire}, 'data/planets.js');
$opts{log}     ||= join('/', $opts{empire}, 'log/spies.log');


# open log
open(my $Log,'>>',$opts{log}) or die "Unable to log gather glyphs: $!";
print $Log "\n==========\nStarting training updates: ", scalar(localtime), "\n";

# read list of planets
open(my $planets_fh, '<', $opts{planets})
    or die "Unable to read planet list from $opts{planets}: $!";

my $planets = '';
{
    local $/;
    my $json_text = <$planets_fh>;
    $planets      = decode_json( $json_text );
}


my %trainhash = (
    theft     => 'Theft Training',
    intel     => 'Intel Training',
    politics  => 'Politics Training',
    mayhem    => 'Mayhem Training',
);


my $glc = Games::Lacuna::Client->new(
    cfg_file       => $opts{config},
    prompt_captcha => 1,
    rpc_sleep      => $opts{sleep},
    # debug    => 1,
);
my $json = JSON->new->utf8(1);

my $empire  = $glc->empire->get_status->{empire};
my %planets = reverse %{ $empire->{planets} };

foreach my $planet (@{$planets}) {
    #next unless $planet eq 'Agartha';
    #next if grep { $planet eq $_ } qw(Agartha Annwn Cockaigne Canibri Embla);
    print "Training spies on $planet\n";

    my $body      = $glc->body( id => $planets{$planet} );
    my $buildings = $body->get_buildings->{buildings};
    #print "Buildings: ", Dumper($buildings);


    my %schools = ();
    foreach my $type (keys %trainhash) {
        my $building_id = first {
          $buildings->{$_}->{url} eq "/${type}training"
        } keys %$buildings;

        next unless $building_id;

        $schools{$type}{id} = $building_id;

        $schools{$type}{building} = $glc->building( id   => $building_id,
                                                    type => $trainhash{$type} );

        my $capacity;
        my $ok = eval {
            my $view = $schools{$type}{building}->view();
            $capacity = $view->{spies};
        };
        #print "$type building: ", Dumper($capacity);

        next if $capacity->{in_training} >= 4;

        $schools{$type}{openings}   = 4 - $capacity->{in_training};
        $schools{$type}{max_points} = $capacity->{max_points};
    }


    my $building_id = first {
          $buildings->{$_}{name} eq 'Intelligence Ministry'
        } keys %$buildings;
    my $ministry = $glc->building( id => $building_id, type => 'Intelligence' );
    #print Dumper($ministry);

    my $spies = [];
    my $ok = eval {
        my $view = $ministry->view_all_spies();
        $spies = $view->{spies};
    };
    #print "Ministry: ", Dumper($spies);
    unless (@{$spies}) {
        print "No spies found for training on $planet\n";
        next;
    }

    my %spies = ();
    foreach my $spy (@{$spies}) {
        #print "$spy->{name} $spy->{assignment}\n";
        next unless $spy->{is_available};
        next unless $spy->{assigned_to}{name} eq $planet;

        my $name  = 'Agent ' . substr($planet,0,2);
        my @maxed = ();
        push(@maxed, 'I') if $spy->{intel} >= 2600;
        push(@maxed, 'P') if $spy->{politics} >= 2600;
        push(@maxed, 'M') if $spy->{mayhem} >= 2600;
        push(@maxed, 'T') if $spy->{theft} >= 2600;

        $name .= '-' . join('', @maxed) if @maxed;

        unless ($spy->{name} eq $name) {
            print "Renaming spy: $spy->{name} -> $name\n";
            $ministry->name_spy($spy->{id}, $name);
            $spy->{name} = $name;

            # if a spy that was training maxed out (got lettered), mark them as
            # available for re-assignment and make an opening at the school
            if ($spy->{assignment} =~ /(\w+) Training/) {
                my $lesson = lc($1);
                $spy->{assignment} = 'Idle';
                $schools{$lesson}{openings}++ if exists $schools{$lesson}{openings}
                                               && $schools{$lesson}{openings} < 4;
            }
        }

        if (@maxed == 4) {
            next if $spy->{assignment} eq 'Counter Espionage';
            my $result = $ministry->assign_spy($spy->{id}, 'Counter Espionage');
            print "$spy->{name} ($spy->{id}), Counter Espionage: $result->{mission}{result}\n";
        }
        next if $spy->{assignment} =~ / Training/;


        $spies{$spy->{id}} = {
            name       => $spy->{name},
            defense    => $spy->{defense_rating},
            offense    => $spy->{offense_rating},
            level      => $spy->{level},
            assignment => $spy->{assignment},
            intel      => $spy->{intel},
            politics   => $spy->{politics},
            mayhem     => $spy->{mayhem},
            theft      => $spy->{theft},
        }
    }

    unless (keys %spies) {
        print "No spies available for training on $planet\n";
        next;
    }


    #print "Spies available for training: ", Dumper(\%spies);
    #print "Schools in session: ", Dumper(\%schools);

    foreach my $lesson (qw(intel politics theft mayhem)) {
        next unless exists $schools{$lesson}{openings};
        next if $schools{$lesson}{openings} <= 0;

        # find the first spies who have not already maxed at the available
        # training for the type of lesson, and set them to training, sorted to
        # prefer partially trained spies
        # add subsort on total skill? or other way to prefer intel + politics, etc?
        my $i = 1;
        foreach my $id (sort { $spies{$b}{$lesson} <=> $spies{$a}{$lesson} } keys %spies) {
            my $spy = $spies{$id};
            next if $spy->{$lesson} >= $schools{$lesson}{max_points};

            #my ($test) = grep { $_->{id} eq $id } @{$spies};
            #print Dumper($test);

            my $result = $ministry->assign_spy($id, $trainhash{$lesson});
            #my $result = $schools{$lesson}{building}->train_spy($id);
            print "$spy->{name} ($id), $trainhash{$lesson}: $result->{mission}{result}\n";
            next if $result->{mission}{result} eq 'Failure';

            delete $spies{$id};
            last if $i++ == $schools{$lesson}{openings};
        }
    }

    # put all remaining spies on counter intelligence
    foreach my $id (keys %spies) {
        next if $spies{$id}{assignment} eq 'Counter Espionage';
        my $result = $ministry->assign_spy($id, 'Counter Espionage');
        print "$spies{$id}{name} ($id), Counter Espionage: $result->{mission}{result}\n";
    }
}