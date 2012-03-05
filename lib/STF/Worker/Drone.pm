package STF::Worker::Drone;
use strict;
use Class::Load ();
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long ();
use Parallel::Prefork;
use Parallel::Scoreboard;
use STF::Constants qw( STF_DEBUG );
use STF::Context;
use STF::SerialGenerator;
use Class::Accessor::Lite
    rw => [ qw(
        context
        generator
        id
        pid
        pid_file
        process_manager
        scoreboard
        scoreboard_dir
        spawn_interval
        workers
    ) ]
;

sub bootstrap {
    my $class = shift;

    my %opts;
    if (! Getopt::Long::GetOptions(\%opts, "config=s") ) {
        exit 1;
    }

    if ($opts{config}) {
        $ENV{ STF_CONFIG } = $opts{config};
    }
    my $context = STF::Context->bootstrap;
    $class->new(
        context => $context,
        interval => 5,
        %{ $context->get('config')->{ 'Worker::Drone' } },
    );
}

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        spawn_interval => 1,
        workers => {
            Replicate     => 8,
            DeleteBucket  => 4,
            DeleteObject  => 4,
            ObjectHealth  => 1,
            RepairObject  => 1,
            RecoverCrash  => 1,
            RetireStorage => 1,
        },
        %args,
        pid => $$,
    }, $class;

    if (! $self->id) {
        print STDERR "[    Drone] No worker ID specified. '1' will be used. Note that this MAY collide with other workers, and your config may be reloaded unexpectedly\n";
        $self->id( 1 );
    }

    # This generator is used to generate an instance-ID. We may share the
    # same worker ID (so we can reload configurations all at once) but we
    # have to have a unique ID for all instances
    if (! $self->generator) {
        $self->generator(
             STF::SerialGenerator->new( id => $self->id )
        );
    }

    # Backwards compatibility
    my %alias = (
        Usage => 'UpdateUsage',
        Retire => 'RetireStorage',
        Crash => 'RecoverCrash',
    );
    my $workers = $self->workers;
    while ( my ($k, $v) = each %alias ) {
        if (exists $workers->{$k}) {
            $workers->{$v} = delete $workers->{$k};
        }
    }

    # This MUST exist. Always
    $workers->{ReloadConfig} = 1;

    # This is for compatibility measure. If we had an old type worker that has 
    # the configuration in the config file, we want to send that over to
    # the server. But only do that when the equivalent setting does not exist
    # in the server's database
    # XXX We probably should eliminate this in the future
    $self->set_defaults_from_local_settings();

    return $self;
}

sub set_defaults_from_local_settings {
    my $self = shift;

    my $dbh = $self->context->container->get('DB::Master');
    my $workers = $self->workers;
    while ( my ($name, $instances) = each %$workers ) {
        my $key = sprintf "stf.worker.%s.%s.instances",
            $self->id,
            $name
        ;
        $dbh->do( <<EOSQL, undef, $key, $instances );
            INSERT IGNORE INTO config (varname, varvalue) VALUES (?, ?)
EOSQL
    }   
}

sub load_config {
    my $self = shift;

    my $dbh = $self->context->container->get('DB::Master');
    my $key = sprintf "stf.worker.%s.%%.instances", $self->id;
    my $config = $dbh->selectall_arrayref( <<EOM, { Slice => {} }, $key);
        SELECT * FROM config WHERE varname LIKE ?
EOM
    my $workers = $self->workers;
    foreach my $row ( @$config ) {
        my $klass = $row->{varname};
        if ( $klass =~ s/^stf\.worker\.[^\.]+\.([^\.]+)\.instances/$1/ ) {
            $workers->{$klass} = $row->{varvalue};
        }
    }
    # This MUST exist. Always
    $workers->{ReloadConfig} = 1;

    my $pp = $self->process_manager();
    $pp->max_workers( $self->max_workers );
}

sub max_workers {
    my $self = shift;
    my $workers = $self->workers;
    my $n = 0;
    for my $v ( values %$workers ) {
        $n += $v
    }
    $n;
}

sub cleanup {
    my $self = shift;

    $self->process_manager->wait_all_children();

    if ( my $scoreboard = $self->scoreboard ) {
        $scoreboard->cleanup;
    }

    if ( my $pid_file = $self->pid_file ) {
        unlink $pid_file or
            warn "Could not unlink PID file $pid_file: $!";
    }
}

sub prepare {
    my $self = shift;

    if (! $self->scoreboard ) {
        my $sbdir = $self->scoreboard_dir  || tempdir( CLEANUP => 1 );
        if (! -e $sbdir ) {
            if (! File::Path::make_path( $sbdir ) || ! -d $sbdir ) {
                Carp::confess("Failed to create score board dir $sbdir: $!");
            }
        }

        $self->scoreboard(
            Parallel::Scoreboard->new(
                base_dir => $sbdir
            )
        );
    }

    if (! $self->process_manager) {
        my $pp = Parallel::Prefork->new({
            max_workers     => $self->max_workers,
            spawn_interval  => $self->spawn_interval,
            after_fork      => sub { sleep 1 }, # XXX hmm?
            trap_signals    => {
                map { ($_ => 'TERM') } qw(TERM INT HUP)
            }
        });
        $self->process_manager( $pp );
    }

    if ( my $pid_file = $self->pid_file ) {
        open my $fh, '>', $pid_file or
            "Could not open PID file $pid_file for writing: $!";
        print $fh $$;
        close $fh;
    }
}

sub run {
    my $self = shift;

    $self->prepare;

    my $pp = $self->process_manager();
    while ( 1 ) {
        my $signal = $pp->signal_received;
        if ( $signal =~ /^(?:TERM|INT)$/ ) {
            # TERM or INT, then it's THE END
            last;
        }

        if ( $signal eq 'HUP' ) {
            # Tell everybody to restart
            if ( STF_DEBUG ) {
                print STDERR "[     Drone] Received HUP, going to stop child processes, and reload configuration\n";
            }

            $self->load_config();
            $pp->signal_all_children( "TERM" );
        }

        $pp->start(sub {
            eval {
                $self->start_worker( $self->get_worker );
            };
            if ($@) {
                warn "Failed to start worker ($$): $@";
            }
            print STDERR "Worker ($$) exit\n";
        });
    }

    $self->cleanup();
}

sub start_worker {
    my ($self, $klass) = @_;

    $0 = sprintf '%s [%s]', $0, $klass;
    if ($klass !~ s/^\+//) {
        $klass = "STF::Worker::$klass";
    }

    Class::Load::load_class($klass)
        if ! Class::Load::is_class_loaded($klass);

    if ( STF_DEBUG ) {
        print STDERR "[     Drone] Spawning $klass ($$)\n";
    }

    my ($config_key) = ($klass =~ /(Worker::[\w:]+)$/);
    my $container = $self->context->container;
    my $config    = $self->context->config->{ $config_key };

    my $worker = $klass->new(
        %$config,
        cache_expires => 30,
        container => $container,
        parent_pid => $self->pid,
        generator  => $self->generator,
    );
    $worker->work;
}

sub get_worker {
    my $self = shift;
    my $scoreboard = $self->scoreboard;

    my $stats = $scoreboard->read_all;
    my %running;
    for my $pid( keys %{$stats} ) {
        my $val = $stats->{$pid};
        $running{$val}++;
    }

    my $workers = $self->workers;
    for my $worker( keys %$workers ) {
        if ( $running{$worker} < $workers->{$worker} ) {
            $scoreboard->update( $worker );
            return $worker;
        }
    }

    die "Could not find a suitable worker!";
}

1;
