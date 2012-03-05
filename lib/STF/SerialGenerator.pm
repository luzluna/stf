package STF::SerialGenerator;
use strict;
use IPC::SysV qw(S_IRWXU S_IRUSR S_IWUSR IPC_CREAT IPC_NOWAIT SEM_UNDO);
use IPC::SharedMem;
use IPC::Semaphore;
use STF::Constants qw(
    :server
    HAVE_64BITINT
    STF_DEBUG
);
use Class::Accessor::Lite
    rw => [ qw(
        id
        mutex
        shared_mem
        shm_name
        sem_name
    )]
;

BEGIN {
    if (! HAVE_64BITINT) {
        if ( STF_DEBUG ) {
            print STDERR "[Generator] You don't have 64bit int. Emulating using Math::BigInt (This will be SLOW! Use 64bit-enabled Perls for STF!)\n";
        }
        require Math::BigInt;
        Math::BigInt->import;
    }
}

sub new {
    my ($class, @args) = @_;

    my $self = bless {
        @args,
        parent   => $$,
    }, $class;

    if (! $self->{id} ) {
        Carp::croak("No id specified! (MUST PROVIDE UNIQUE ID PER INSTANCE)");
    }

    $self->{sem_name} ||= File::Temp->new(UNLINK => 1);
    $self->{shm_name} ||= File::Temp->new(UNLINK => 1);

    my $semkey = IPC::SysV::ftok( $self->{sem_name}->filename );
    my $mutex  = IPC::Semaphore->new( $semkey, 1, S_IRUSR | S_IWUSR | IPC_CREAT );
    my $shmkey = IPC::SysV::ftok( $self->{shm_name}->filename );
    my $shm    = IPC::SharedMem->new( $shmkey, 24, S_IRWXU | IPC_CREAT );
    if (! $shm) {
        die "PANIC: Could not open shared memory: $!";
    }
    $mutex->setall(1);
    $shm->write( _pack_head( 0, 0 ), 0, 24 );

    $self->{mutex} = $mutex;
    $self->{shared_mem} = $shm;

    $self;
}

sub create_id {
    my $self    = shift;
    my $mutex   = $self->mutex;
    my $shm     = $self->shared_mem;
    my $host_id = $self->id;

    if ( STF_DEBUG > 1 ) {
        printf STDERR "[ Create ID] $$ ATTEMPT to LOCK\n";
    }

    my ($rc, $errno);
    my $acquire = 0;
    do {
        $acquire++;
        $rc = $mutex->op( 0, -1, SEM_UNDO | IPC_NOWAIT );
        $errno = $!;
        if ( $rc <= 0 ) {
            Time::HiRes::usleep( int( rand(5_000) ) );
        }
    } while ( $rc <= 0 && $acquire < 100);

    if ( $rc <= 0 ) {
        die sprintf
            "[ Create ID] SEMAPHORE: Process $$ failed to acquire mutex (tried %d times, \$! = %d, rc = %d, val = %d, zcnt = %d, ncnt = %d, id = %d)\n",
            $acquire,
            $errno,
            $rc,
            $mutex->getval(0),
            $mutex->getzcnt(0),
            $mutex->getncnt(0),
            $mutex->id
        ;
    }

    if ( STF_DEBUG > 1 ) {
        printf STDERR "[ Create ID] $$ SUCCESS LOCK mutex\n"
    }

    Guard::scope_guard {
        if ( STF_DEBUG > 1 ) {
            printf STDERR "[ Create ID] $$ UNLOCK mutex\n"
        }
        $mutex->op( 0, 1, SEM_UNDO );
    };

    my $host_id = (int($host_id + $$)) & 0xffff; # 16 bits
    my $time_id = time();

    my ($shm_time, $shm_serial) = _unpack_head( $shm->read(0, 24) );
    if ( $shm_time == $time_id ) {
        $shm_serial++;
    } else {
        $shm_serial = 1;
    }

    if ( $shm_serial >= (1 << SERIAL_BITS) - 1) {
        # Overflow :/ we received more than SERIAL_BITS
        die "serial bits overflowed";
    }
    $shm->write( _pack_head( $time_id, $shm_serial ), 0, 24 );

    my $time_bits = ($time_id - EPOCH_OFFSET) << TIME_SHIFT;
    my $serial_bits = $shm_serial << SERIAL_SHIFT;
    my $id = $time_bits | $serial_bits | $host_id;

    return $id;
}

sub _pack_head {
    my ($time, $serial) = @_;
    if ( HAVE_64BITINT ) {
        return pack( "ql", $time, $serial );
    } else {
        pack( "N2l", unpack( 'NN', $time ), $serial );
    }
}

sub _unpack_head {
    if ( HAVE_64BITINT ) {
        return unpack( "ql", shift() );
    } else {
        my $high = shift;
        my $low = shift;
        my $time = Math::BigInt->new(
            "0x" . unpack("H*", CORE::pack("N2", $high, $low)));
        my $serial = unpack( "l", shift() );
        return $time, $serial;
    }
}


sub cleanup {
    my $self = shift;

    if ( $self->{parent} != $$ ) {
        if ( STF_DEBUG ) {
            print STDERR "[ Create ID] Cleanup skipped (PID $$ != $self->{parent})\n";
        }
        return;
    }

    {
        local $@;
        if ( my $mutex = $self->{mutex} ) {
            eval {
                if ( STF_DEBUG ) {
                    printf STDERR "[ Create ID] Cleaning up semaphore (%s)\n",
                        $mutex->id
                }
                $mutex->remove;
            };
        }
        if ( my $shm = $self->{shared_mem} ) {
            eval {
                if ( STF_DEBUG ) {
                    printf STDERR "[ Create ID] Cleaning up shared memory (%s)\n",
                        $shm->id
                }
                $shm->remove
            };
        }
    }
}


1;
