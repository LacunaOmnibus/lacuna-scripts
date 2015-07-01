#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);

use Data::Dumper;

use Getopt::Long qw( GetOptions );
use List::Util   qw( first );
use Try::Tiny;
use JSON;
use POSIX ":sys_wait_h";

use FindBin qw($Bin);
use lib "$Bin/../../Games-Lacuna-Client/lib";
use Games::Lacuna::Client ();


my $help;
my $sleep = 1;
my $stations = "$Bin/../data/stations.js";
my $empires  = "$Bin/../data/av-empires.js";
my $logfile  = "$Bin/../log/av.log";
my $debug    = 0;
my $do_list  = [ ];

GetOptions(
    'help|h'     => \$help,
    'debug|v'    => \$debug,
    'sleep=i'    => \$sleep,
    'stations=s' => \$stations,
    'empires=s'  => \$empires,
    'logfile=s'  => \$logfile,
    'do_list=s@' => $do_list,
);

usage() if $help;


my @skip_list = qw(
    Leader
    Member
    Evict
    BFG
    Repeal
    Declaration
    nopush
);


my $Empires = {};
{
    # read in empires file to get config file names
    open(my $empires_fh, '<', $empires)
        or die "Unable to read planet list from $empires: $!";

    local $/;
    my $json_text = <$empires_fh>;
    $Empires      = decode_json( $json_text );

    close $empires_fh;
}


my $cfg_file = $Empires->{Toftberg}{config};

my $client = Games::Lacuna::Client->new(
    cfg_file  => $cfg_file,
    rpc_sleep => $sleep,
);


# logging
if ($logfile) {
    open(my $log_fh, '>>', "$logfile") or die "Can't write log: $!";
    select $log_fh;
    $| = 1;
}


# Load the bodies
my $empire = $client->empire->get_status->{empire};

my $rpc_cnt_beg = $client->{rpc_count};
say "RPC Count of $rpc_cnt_beg";


# reverse hash, to key by name instead of id
my %planets = reverse %{ $empire->{planets} };


my $station_list = $do_list;

# if no stations were specified, do them all
if (! @{$station_list}) {
    # load list of station names
    open(my $stations_fh, '<', $stations)
        or die "Unable to read planet list from $stations: $!";

    local $/;
    my $json_text = <$stations_fh>;
    $station_list = decode_json( $json_text );

    close $stations_fh;
}

my %stations = map { $_ => 1 } @{$station_list};


SS: for my $name ( sort keys %planets ) {
    next unless exists $stations{$name};
    say "Space Station: $name";

    my $planet = $client->body( id => $planets{$name} );
    say "\tGot body" if $debug;

    my $buildings = $planet->get_buildings->{buildings};
    say "\tGot buildings" if $debug;

    my $parliament_id = first {
            $buildings->{$_}->{url} eq '/parliament'
        } keys %$buildings;

    next if ! defined $parliament_id;

    say "\tFound parliament" if $debug;

    my $parliament = $client->building( id => $parliament_id, type => 'Parliament' );

    my $propositions;

    try {
        $propositions = $parliament->view_propositions->{propositions};
    }
    catch {
        warn "$_\n\n";
        no warnings 'exiting';
        next SS;
    };

    my @good_props = ();
    my @prop_names = ();
    foreach my $prop (@$propositions) {
        say "Checking: " . $prop->{name} if $debug;
        next if grep { $prop->{name} =~ /$_/i } @skip_list;
        push(@good_props, $prop);
        push(@prop_names, $prop->{name});

        printf("\tKept - Yes votes: %s, Needed: %s\n",
                $prop->{votes_yes}, $prop->{votes_needed}
             ) if $debug;
    }


    if ( ! @good_props ) {
        say "No propositions" if $debug;
        next SS;
    }

    say "Will vote on:\n\t", join("\n\t", @prop_names);

    # Could we fork-loop here so all members vote simultaneously? If each
    # client counts RPC's only against its user, why not?
    my %children = ();
    MEMBER: foreach my $member (keys %{$Empires}) {
        # Don't flood the server or we hit a race condition
        # Time::HiRes usleep doesn't appear to work on my server :/
        select(undef, undef, undef, 0.3);

        $children{$member} = fork();
        die "fork() failed!" unless defined $children{$member};

        # parent will fork for each child, recording pids
        next if $children{$member};

        # child loops over votes than exits
        my $glc = get_client($member);
        exit unless $glc;

        my $parl = $glc->building( id => $parliament_id, type => 'Parliament' );

        say "Voting for $member";

        foreach my $prop ( @good_props ) {
            try {
                say "$member: Casting vote on $prop->{name}..." if $debug;
                $parl->cast_vote( $prop->{id}, 1 );
                $prop->{votes_yes}++;
            }
            catch {
                no warnings 'exiting';

                if (/You have already voted/) {
                    say "\t$member already voted on $prop->{name}" if $debug;
                    next;
                }
                elsif (/This proposition has already Passed/) {
                    say "\t$prop->{name} already passed" if $debug;
                    next;
                }
                elsif (/RPC Error (1006): Session expired/) {
                    say "Session expired - refreshing client";
                    delete($Empires->{$empire}{client});
                    $glc = get_client($member);
                }

                # maybe member error? Are there prop errors?
                die "ERROR: $_";
            };

        }
        exit;
    }

    # parent waits for children to finish voting before going to the next SS
    foreach my $member (keys %children) {
        my $timer = 0;

        while (1) {
            my $res = waitpid($children{$member}, WNOHANG);

            if ($res == -1) {
                say "Some error occurred ", $? >> 8;
                delete($Empires->  {$member});
                last;
            }
            if ($res) {
                say "$member child $res ended with ", $? >> 8;
                last;
            }
            if ($timer >= 50) {
                # child has wandered off?
                say "$member process $children{$member} passed timer";
                kill(9, $children{$member});
            }


            sleep(1);
            $timer++;
        }
    }

    print "\n";
}

my $rpc_cnt_end = $client->{rpc_count};
say "RPC Count of $rpc_cnt_end";

exit;


sub get_client {
    my $empire = shift;
    return $Empires->{$empire}{client} if exists $Empires->{$empire}{client};

    my $cfg_file = $Empires->{$empire}{config};

    $Empires->{$empire}{client} = Games::Lacuna::Client->new(
        cfg_file  => $cfg_file,
        rpc_sleep => $sleep,
    );

    return $Empires->{$empire}{client};
}


sub usage {
    die <<"END_USAGE";

END_USAGE

}
