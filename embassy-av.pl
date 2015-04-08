#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);

use Data::Dumper;
use Clone qw(clone);

use Getopt::Long qw( GetOptions );
use List::Util qw( first );
use Try::Tiny;
use JSON;
use POSIX ":sys_wait_h";
use Time::HiRes qw(sleep);

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
    'sleep=f'    => \$sleep,
    'stations=s' => \$stations,
    'empires=s'  => \$empires,
    'logfile=s'  => \$logfile,
    'do_list=s@' => $do_list,
);

usage() if $help;


my @skip_list = (
    'Leader',
    'Expel',
    'Induct',
    'Evict',
    'BFG',
    'Repeal',
    'Declaration',
    'nopush',
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


my $embassy_client = Games::Lacuna::Client->new(
    cfg_file  => "Grimtooth/empire.yml",
    rpc_sleep => $sleep,
);


# logging
if ($logfile) {
    open(my $log_fh, '>>', "$logfile") or die "Can't write log: $!";
    select $log_fh;
    $| = 1;
}


my $embassy = $embassy_client->building(id => 4183265,
                                        type => 'Embassy' );

my $propositions = $embassy->view_propositions->{propositions};

unless (@{$propositions}) {
    say "No propositions to check, done";
    exit;
}

my %have_props = ();
foreach my $prop (@{$propositions}) {
    say "Checking: " . $prop->{name} if $debug;
    next if grep { $prop->{name} =~ /$_/i } @skip_list;
    
    push(@{ $have_props{$prop->{station}} }, $prop);
}

unless (keys %have_props) {
    say "No allowed propositions to vote on, done";
    exit;
}


my @inactives = qw(carbonhalo KC1 Toftberg); # Trudevil
push(@inactives, 'Lapis Land');
my $runner = $inactives[ int(rand(@inactives)) ];

my $cfg_file = $Empires->{$runner}{config};

my $client = Games::Lacuna::Client->new(
    cfg_file  => $cfg_file,
    rpc_sleep => $sleep,
);


# Load the bodies
my $empire = $client->empire->get_status->{empire};

my $rpc_cnt_beg = $client->{rpc_count};
say "RPC Count of $rpc_cnt_beg";
say "perl: $]";
say "Running station loop as $runner";


# reverse hash, to key by name instead of id
my %planets = reverse %{ $empire->{planets} };


my $station_list = $do_list;

# if no stations were specified, do them all
# XXX - is this even needed any more?!
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

my @children;

SS: for my $name ( sort keys %have_props ) {
    next unless exists $stations{$name};

    my $planet = $client->body( id => $planets{$name} );

    my $result = $planet->get_buildings;

    say "$$ - Space Station: ", $result->{status}{body}{name};

    my $buildings = $result->{buildings};

    my $parliament_id = first {
            $buildings->{$_}->{url} eq '/parliament'
        } keys %$buildings;

    next if ! defined $parliament_id;

    my $parliament = $client->building( id => $parliament_id, type => 'Parliament' );

    my @good_props = @{$have_props{$name}};
    my @prop_names = ();

    foreach my $prop (@good_props) {
        push(@prop_names, $prop->{name});

        printf("\tKept - Yes votes: %s, Needed: %s\n",
                $prop->{votes_yes}, $prop->{votes_needed}
             ) if $debug;
    }

    my $pid = fork();
    die 'fork() failed!' unless defined $pid;
    if ($pid) {
        say "Forked voting loop ($pid), parent getting next station";# if $debug;
        push(@children, $pid);
        sleep($sleep);
        next SS;
    }

    say "Will vote on:\n\t", join("\n\t", @prop_names);
    #my $emps = clone($Empires);

    MEMBER: foreach my $member (keys %{$Empires}) {
        last MEMBER unless @good_props;

        my $glc = get_client($member);
        next MEMBER unless $glc;

        my $parl = $glc->building( id => $parliament_id, type => 'Parliament' );

        say "\t$$ - $name: Voting for $member";

        my $i = 0;
        foreach my $prop ( @good_props ) {
            printf("\tName: %s, Yes votes: %s, Still needed: %s\n",
                   $prop->{name}, $prop->{votes_yes}, $prop->{votes_needed}
                ) if $debug;


            try {
                say "\tcasting vote..." if $debug;
                $parl->cast_vote( $prop->{id}, 1 );
                $prop->{votes_yes}++;
            }
            catch {
                no warnings 'exiting';

                if (/You have already voted/) {
                    next MEMBER;
                }
                elsif (/This proposition has already Passed/) {
                    # We shouldn't see this as we count votes as we go
                    say "ERROR: WTF? $_\n";
                    splice(@good_props, $i, 1);
                    next MEMBER;
                }

                # maybe member error? Are there prop errors?
                say "ERROR for $member: $_\n";
                delete($Empires->{$member});
                next MEMBER;
            };

            $prop->{votes_needed}--;
            if ($prop->{votes_needed} == 0) {
                # Prop should have passed, don't check it again next member
                splice(@good_props, $i, 1);
            }
            else { $i++ }
        }
    }

    say "Voting completed for $name; exiting normally" if $debug;
    #sleep(300);
    exit;
}

if (@children) {
    say 'Making sure children are all done...';
    foreach my $pid (@children) {
        say "Checking if $pid is done" if $debug;
        my $c = 0;

        while (1) {
            my $res = waitpid($pid, WNOHANG);

            if ($res == -1) {
                say "Some error occurred with child $pid", $? >> 8;
                last;
            }
            if ($res) {
                say "Child $res ended with ", $? >> 8;
                last;
            }
            if ($c >= 3000) { # 10 minutes
                warn "ERROR: Child $pid seems to be a zombie - it may need to be headshot\n\n";
                last;
            }


            # Time::HiRes usleep doesn't appear to work on my server :/
            #select(undef, undef, undef, 0.3);
            $c++;
            sleep(.2);
        }
    }
}


my $rpc_cnt_end = $client->{rpc_count};
say "RPC Count of $rpc_cnt_end\n";

exit;


sub get_client {
    my $empire  = shift;
    my $empires = shift || $Empires;
    #return $empires->{$empire}{client} if exists $empires->{$empire}{client};

    my $cfg_file = $empires->{$empire}{config};

    my $client = Games::Lacuna::Client->new(
        cfg_file  => $cfg_file,
        rpc_sleep => $sleep,
    );

    say "Returning client for $empire" if $debug;
    return $client;
}



sub usage {
    die <<"END_USAGE";

END_USAGE

}
