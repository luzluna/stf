use strict;
use Test::More;
use Proc::Guard;
use STF::Context;
use STF::Worker::Drone;
use File::Temp qw(tempdir);

my $sbdir = tempdir( CLEANUP => 1 );
my $drone_guard = Proc::Guard->new(code => sub {
    my $ctxt  = STF::Context->bootstrap(config => "t/config.pl");
    my $drone = STF::Worker::Drone->new(
        context => $ctxt,
        interval => 5,
        %{ $ctxt->container->get('config')->{'Worker::Drone'} },
        scoreboard_dir => $sbdir,
        workers => {
            Replicate     => 0,
            DeleteBucket  => 0,
            DeleteObject  => 0,
            ObjectHealth  => 0,
            RepairObject  => 0,
            RecoverCrash  => 0,
            RetireStorage => 0,
        },
    );
    $drone->run;
} );

subtest 'sanity' => sub {
    my $sb = Parallel::Scoreboard->new(
        base_dir => $sbdir
    );

    local $SIG{ALRM} = sub {
        die "TiMeOuT!";
    };
    eval { 
        alarm(10);
        while (1) {
            my $stats = $sb->read_all;
            if ( grep { $_ eq 'ReloadConfig' } values %$stats ) {
                last;
            }
            sleep 1;
        };
    };
    ok !$@, "no errors";
    alarm(0);

    # Make sure that the worker has been registered
    my $ctxt  = STF::Context->bootstrap(config => "t/config.pl");

    my $dbh   = $ctxt->container->get('DB::Master');
    my $list  = $dbh->selectall_arrayref( <<EOM, { Slice => {} } );
        SELECT * FROM worker
EOM

    ok @$list; # XXX BAD TEST

    # Set the config value
    $dbh->do( <<EOM, undef, "stf.worker.1.Replicate.instances", 1 );
        REPLACE INTO config (varname, varvalue) VALUES (?, ?)
EOM

    my $queue_api = $ctxt->container->get('API::Queue');
    $queue_api->enqueue( reload_config => $list->[0]->{id} );

    local $SIG{ALRM} = sub {
        die "TiMeOuT!";
    };
    eval { 
        alarm(10);
        while (1) {
            my $stats = $sb->read_all;
            my @matched = grep { /^(?:Replicate|ReloadConfig)$/ } values %$stats;
            if (@matched == 2) {
                last;
            }
            sleep 1;
        };
    };
    ok !$@, "no errors";
    alarm(0);
};

done_testing;