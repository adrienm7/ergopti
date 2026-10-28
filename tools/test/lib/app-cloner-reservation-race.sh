#!/bin/zsh
# tools/test/lib/app-cloner-reservation-race.sh
# Arguments: production reservation library, exact owned probe directory.
set -euo pipefail
helper="$1"
probe_root="$2"
probe_library="$(cd "$(dirname "$0")" && pwd -P)"
export ERGOPTI_RESERVATION_PROBE_ROOT="$probe_root"
export ERGOPTI_RESERVATION_TARGET="$probe_root/Contended.app"
export ERGOPTI_RESERVATION_BARRIER_SECONDS=5
export PERL5LIB="$probe_library"
export PERL5OPT=-MAppClonerMkdirBarrier
source "$helper"

owner_pid=""
retire_owner() {
	local owner_status=0
	if [[ -n "$owner_pid" ]]; then
		if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
		owner_pid=""
	fi
	return "$owner_status"
}
cleanup_probe() {
	local primary_status=$? owner_status=0
	trap - EXIT
	retire_owner || owner_status=$?
	if [[ "$primary_status" != "0" ]]; then return "$primary_status"; fi
	return "$owner_status"
}
trap cleanup_probe EXIT

wait_for_owned_marker() {
	local marker="$1" barrier_deadline=$((SECONDS + ERGOPTI_RESERVATION_BARRIER_SECONDS))
	while [[ ! -f "$marker" ]]; do
		if (( SECONDS >= barrier_deadline )); then
			echo "Error: owned reservation barrier deadline expired: $marker" >&2
			return 1
		fi
		sleep 0.01
	done
}

# The old shell implementation is held at the same boundary as the new Perl
# implementation. Both invoke a real mkdir; only the return is delayed.
mkdir -p "$probe_root/bin"
cat > "$probe_root/bin/mkdir" <<'MKDIR'
#!/bin/sh
/usr/bin/mkdir "$@"
mkdir_status=$?
if [ "$mkdir_status" -ne 0 ] && [ "$1" = "$ERGOPTI_RESERVATION_TARGET" ]; then
	touch "$ERGOPTI_RESERVATION_PROBE_ROOT/contender-failed"
	/usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,sleep -e '
		my $deadline = clock_gettime(CLOCK_MONOTONIC) + $ENV{ERGOPTI_RESERVATION_BARRIER_SECONDS};
		while (!-f "$ENV{ERGOPTI_RESERVATION_PROBE_ROOT}/owner-retired") {
			die "Owned shell mkdir barrier deadline expired\n" if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
			sleep(0.01);
		}
	' || exit 99
fi
exit "$mkdir_status"
MKDIR
chmod +x "$probe_root/bin/mkdir"
export PATH="$probe_root/bin:$PATH"

(
	owned="$(reserve_bundle_directory "$ERGOPTI_RESERVATION_TARGET")"
	touch "$probe_root/owner-ready"
	wait_for_owned_marker "$probe_root/contender-failed"
	rmdir "$owned"
	touch "$probe_root/owner-retired"
) &
owner_pid=$!
# zsh ERR_EXIT from a function return can bypass EXIT traps. Convert this
# ordinary failure to a top-level exit so exact child retirement always runs.
if wait_for_owned_marker "$probe_root/owner-ready"; then
	:
else
	marker_status=$?
	exit "$marker_status"
fi
if destination="$(reserve_bundle_directory "$ERGOPTI_RESERVATION_TARGET")"; then
	contender_status=0
else
	contender_status=$?
fi
if retire_owner; then owner_status=0; else owner_status=$?; fi
if [[ "$contender_status" == "0" ]]; then contender_status="$owner_status"; fi
printf '%s\0' "$destination"
exit "$contender_status"
