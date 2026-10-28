# tools/test/lib/AppClonerMkdirBarrier.pm
# Hold the actual mkdir result while its original owner retires the path.
package AppClonerMkdirBarrier;
use strict;
use warnings;
use Errno qw(EEXIST);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

BEGIN {
	*CORE::GLOBAL::mkdir = sub {
		die "Unexpected mkdir boundary arguments\n" unless @_ == 1 || @_ == 2;
		my ($path, $mode) = @_;
		my $created = @_ == 2 ? CORE::mkdir($path, $mode) : CORE::mkdir($path);
		my $error = 0 + $!;
		if (!$created && $error == EEXIST && $path eq $ENV{ERGOPTI_RESERVATION_TARGET}) {
			my $root = $ENV{ERGOPTI_RESERVATION_PROBE_ROOT};
			open my $marker, '>', "$root/contender-failed" or die "Cannot publish owned mkdir barrier: $!";
			close $marker or die "Cannot retire owned mkdir barrier: $!";
			my $deadline = clock_gettime(CLOCK_MONOTONIC) + $ENV{ERGOPTI_RESERVATION_BARRIER_SECONDS};
			while (!-f "$root/owner-retired") {
				die "Owned mkdir barrier deadline expired\n" if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
				sleep(0.01);
			}
		}
		# File and timing calls must not replace the original kernel errno.
		$! = $error;
		return $created;
	};
}
1;
