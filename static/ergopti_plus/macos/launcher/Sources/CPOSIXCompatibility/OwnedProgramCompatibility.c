// Sources/CPOSIXCompatibility/OwnedProgramCompatibility.c
// Retains an unreaped exact leader until its original private group is non-live.

#include "OwnedProgramCompatibility.h"
#include "CPOSIXCompatibility.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// Foundation Process starts its child as a process-group leader. Such a child
// cannot call setsid directly. Join only the exact current parent's group in
// the same session before creating a new private session; no payload exists yet.
int ergopti_owned_program_create_private_session(void) {
	pid_t identifier = getpid();
	if (identifier <= 0) { return EPROTO; }
	if (setsid() != identifier) {
		int failure = errno == 0 ? EIO : errno;
		if (failure != EPERM || getpgid(0) != identifier || getsid(0) == identifier) { return failure; }
		pid_t parent = getppid();
		pid_t session = getsid(0);
		pid_t parent_group = getpgid(parent);
		if (parent <= 1 || session <= 0 || parent_group <= 0 || parent_group == identifier
			|| getsid(parent) != session || getppid() != parent
			|| getpgid(parent) != parent_group || getsid(parent) != session) { return ESTALE; }
		if (setpgid(0, parent_group) != 0 || setsid() != identifier) { return errno == 0 ? EIO : errno; }
	}
	return getpgid(0) == identifier && getsid(0) == identifier ? 0 : EPROTO;
}

typedef struct {
	pid_t identifier;
	uint64_t start_seconds;
	uint64_t start_microseconds;
} program_identity;

struct ergopti_owned_program {
	pid_t leader;
	program_identity identity;
	bool identity_valid;
	int monitor;
	bool active;
	bool cancelled;
	bool term_sent;
	bool kill_sent;
	bool leader_exited;
	bool retired;
	bool status_valid;
	int exit_status;
	int error_code;
	struct timespec term_time;
	struct stat executable_identity;
	char *executable;
	size_t census_capacity;
	pid_t *first_pids;
	pid_t *second_pids;
	program_identity *first_identities;
};

// Observation grace only; it never changes the physical settlement predicate.
static const long program_term_grace_nanoseconds = 50000000;

static ergopti_owned_program_receipt program_receipt(ergopti_owned_program *owner) {
	if (owner == NULL) {
		return (ergopti_owned_program_receipt) { .error_code = EINVAL };
	}
	return (ergopti_owned_program_receipt) {
		.error_code = owner->error_code,
		.active = owner->active,
		.cancelled = owner->cancelled,
		.leader_exited = owner->leader_exited,
		.retired = owner->retired,
		.status_valid = owner->status_valid,
		.exit_status = owner->exit_status
	};
}

static int program_bsd_info(pid_t identifier, struct proc_bsdinfo *info) {
	memset(info, 0, sizeof(*info));
	errno = 0;
	// arg=1 explicitly includes zombies. The default arg=0 hides held leaders.
	int bytes = proc_pidinfo(identifier, PROC_PIDTBSDINFO, 1, info, sizeof(*info));
	if (bytes != sizeof(*info)) {
		return errno == 0 ? EIO : errno;
	}
	if (info->pbi_pid != (uint32_t)identifier) { return EPROTO; }
	return 0;
}

static program_identity program_identity_from_info(struct proc_bsdinfo *info) {
	return (program_identity) {
		.identifier = (pid_t)info->pbi_pid,
		.start_seconds = info->pbi_start_tvsec,
		.start_microseconds = info->pbi_start_tvusec
	};
}

ergopti_owned_program_observation ergopti_owned_program_observe(pid_t identifier) {
	struct proc_bsdinfo info;
	int error = program_bsd_info(identifier, &info);
	if (error != 0) { return (ergopti_owned_program_observation) { .error_code = error }; }
	return (ergopti_owned_program_observation) {
		.process_id = identifier,
		.process_group_id = (pid_t)info.pbi_pgid,
		.start_seconds = info.pbi_start_tvsec,
		.start_microseconds = info.pbi_start_tvusec,
		.nonlive = info.pbi_status == SZOMB
	};
}

static bool program_identity_equal(program_identity first, program_identity second) {
	return first.identifier == second.identifier
		&& first.start_seconds == second.start_seconds
		&& first.start_microseconds == second.start_microseconds;
}

// The returned identity is an observation of the retained suspended owner;
// it cannot create ownership or authorize activation on its own.
ergopti_owned_program_observation ergopti_owned_program_prepared_identity(ergopti_owned_program *owner) {
	if (owner == NULL || owner->active || owner->cancelled || owner->retired
		|| owner->leader_exited || owner->error_code != 0 || owner->monitor < 0
		|| !owner->identity_valid || owner->leader <= 0) {
		return (ergopti_owned_program_observation) { .error_code = EINVAL };
	}
	struct proc_bsdinfo info;
	int error = program_bsd_info(owner->leader, &info);
	if (error == 0 && (!program_identity_equal(owner->identity, program_identity_from_info(&info))
		|| info.pbi_status != SSTOP || info.pbi_ppid != (uint32_t)getpid()
		|| info.pbi_pgid != (uint32_t)owner->leader || getsid(owner->leader) != getpid()
		|| info.pbi_uid != geteuid() || info.pbi_ruid != getuid()
		|| info.pbi_start_tvusec >= 1000000)) { error = ESTALE; }
	if (error != 0) { return (ergopti_owned_program_observation) { .error_code = error }; }
	return (ergopti_owned_program_observation) {
		.process_id = owner->leader, .process_group_id = (pid_t)info.pbi_pgid,
		.start_seconds = info.pbi_start_tvsec, .start_microseconds = info.pbi_start_tvusec,
		.nonlive = false
	};
}

static int program_pid_compare(const void *first, const void *second) {
	pid_t left = *(const pid_t *)first;
	pid_t right = *(const pid_t *)second;
	return (left > right) - (left < right);
}

static int program_group_list(ergopti_owned_program *owner, pid_t *pids, size_t *count) {
	int capacity_bytes = (int)(owner->census_capacity * sizeof(pid_t));
	errno = 0;
	int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)owner->leader, pids, capacity_bytes);
	if (bytes < 0 || (bytes == 0 && errno != 0)) { return errno == 0 ? EIO : errno; }
	if (bytes >= capacity_bytes || bytes % sizeof(pid_t) != 0) { return EOVERFLOW; }
	*count = (size_t)bytes / sizeof(pid_t);
	qsort(pids, *count, sizeof(pid_t), program_pid_compare);
	for (size_t index = 0; index < *count; index++) {
		if (pids[index] <= 0 || (index != 0 && pids[index] == pids[index - 1])) {
			return EPROTO;
		}
	}
	return 0;
}

// An all-zombie first snapshot cannot fork later. A matching complete second
// snapshot excludes a new live member hidden by a parent exiting during census.
static int program_group_nonlive(ergopti_owned_program *owner, bool *nonlive) {
	*nonlive = false;
	size_t first_count = 0;
	int error = program_group_list(owner, owner->first_pids, &first_count);
	if (error != 0) { return error; }
	for (size_t index = 0; index < first_count; index++) {
		struct proc_bsdinfo info;
		error = program_bsd_info(owner->first_pids[index], &info);
		if (error != 0) { return error; }
		if (info.pbi_pgid != (uint32_t)owner->leader) { return EAGAIN; }
		if (info.pbi_status != SZOMB) { return 0; }
		owner->first_identities[index] = program_identity_from_info(&info);
	}
	size_t second_count = 0;
	error = program_group_list(owner, owner->second_pids, &second_count);
	if (error != 0) { return error; }
	if (first_count != second_count) { return EAGAIN; }
	for (size_t index = 0; index < second_count; index++) {
		if (owner->first_pids[index] != owner->second_pids[index]) { return EAGAIN; }
		struct proc_bsdinfo info;
		error = program_bsd_info(owner->second_pids[index], &info);
		if (error != 0) { return error; }
		if (info.pbi_pgid != (uint32_t)owner->leader || info.pbi_status != SZOMB
			|| !program_identity_equal(owner->first_identities[index], program_identity_from_info(&info))) {
			return EAGAIN;
		}
	}
	*nonlive = true;
	return 0;
}

static int program_send_group(ergopti_owned_program *owner, int signal_number) {
	if (owner->retired) { return EINVAL; }
	if (killpg(owner->leader, signal_number) == 0) { return 0; }
	int error = errno;
	// ESRCH means absent, not an accepted signal. Census still owns settlement.
	return error == ESRCH ? 0 : error;
}

static bool program_term_grace_elapsed(ergopti_owned_program *owner) {
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { return true; }
	long long elapsed = (long long)(now.tv_sec - owner->term_time.tv_sec) * 1000000000LL
		+ now.tv_nsec - owner->term_time.tv_nsec;
	return elapsed >= program_term_grace_nanoseconds;
}

static void program_release_storage(ergopti_owned_program *owner) {
	if (owner->monitor >= 0) { close(owner->monitor); }
	free(owner->executable);
	free(owner->first_pids);
	free(owner->second_pids);
	free(owner->first_identities);
	free(owner);
}

static int program_prepare(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int tty_descriptor,
	int source_descriptor,
	ergopti_owned_program **owner_out
) {
	if (owner_out == NULL || *owner_out != NULL || executable == NULL
		|| executable[0] != '/' || arguments == NULL || arguments[0] == NULL || environment == NULL) {
		return EINVAL;
	}
	// The signed guardian must already own a new session, outside the payload group.
	if (getsid(0) != getpid()) { return EPERM; }
	ergopti_owned_program *owner = calloc(1, sizeof(*owner));
	if (owner == NULL) { return ENOMEM; }
	owner->monitor = -1;
	owner->executable = strdup(executable);
	int max_processes = 0;
	size_t limit_size = sizeof(max_processes);
	int error = 0;
	if (owner->executable == NULL) { error = ENOMEM; }
	else if (stat(executable, &owner->executable_identity) != 0) { error = errno; }
	else if (!S_ISREG(owner->executable_identity.st_mode)) { error = EINVAL; }
	else if (sysctlbyname("kern.maxproc", &max_processes, &limit_size, NULL, 0) != 0) { error = errno; }
	else if (limit_size != sizeof(max_processes) || max_processes <= 0
		|| (size_t)max_processes > (INT_MAX / sizeof(pid_t)) - 20) { error = EOVERFLOW; }
	if (error == 0) {
		owner->census_capacity = (size_t)max_processes + 20;
		owner->first_pids = calloc(owner->census_capacity, sizeof(pid_t));
		owner->second_pids = calloc(owner->census_capacity, sizeof(pid_t));
		owner->first_identities = calloc(owner->census_capacity, sizeof(program_identity));
		if (owner->first_pids == NULL || owner->second_pids == NULL || owner->first_identities == NULL) {
			error = ENOMEM;
		}
	}
	if (error != 0) { program_release_storage(owner); return error; }

	posix_spawnattr_t attributes;
	posix_spawn_file_actions_t actions;
	error = posix_spawnattr_init(&attributes);
	if (error != 0) { program_release_storage(owner); return error; }
	error = posix_spawn_file_actions_init(&actions);
	if (error != 0) {
		posix_spawnattr_destroy(&attributes);
		program_release_storage(owner);
		return error;
	}
	sigset_t default_signals;
	sigset_t empty_mask;
	sigfillset(&default_signals);
	sigdelset(&default_signals, SIGKILL);
	sigdelset(&default_signals, SIGSTOP);
	sigemptyset(&empty_mask);
	short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED
		| POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
	if ((error = posix_spawnattr_setflags(&attributes, flags)) == 0
		&& (error = posix_spawnattr_setpgroup(&attributes, 0)) == 0
		&& (error = posix_spawnattr_setsigdefault(&attributes, &default_signals)) == 0
		&& (error = posix_spawnattr_setsigmask(&attributes, &empty_mask)) == 0) {
		for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; descriptor++) {
			error = tty_descriptor < 0
				? posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
				: posix_spawn_file_actions_adddup2(&actions, tty_descriptor, descriptor);
			if (error != 0) { break; }
		}
	}
	if (error == 0 && source_descriptor >= 0) {
		error = posix_spawn_file_actions_adddup2(&actions, source_descriptor, STDERR_FILENO + 1);
	}
	if (error == 0) {
		error = posix_spawn(&owner->leader, executable, &actions, &attributes, arguments, environment);
	}
	posix_spawn_file_actions_destroy(&actions);
	posix_spawnattr_destroy(&attributes);
	if (error != 0) { program_release_storage(owner); return error; }
	// Publication precedes every post-spawn check: failures retain real cleanup debt.
	*owner_out = owner;
	struct proc_bsdinfo info;
	error = program_bsd_info(owner->leader, &info);
	if (error == 0) {
		owner->identity = program_identity_from_info(&info);
		owner->identity_valid = true;
		if (info.pbi_ppid != (uint32_t)getpid() || info.pbi_pgid != (uint32_t)owner->leader
			|| getsid(owner->leader) != getpid()) { error = EPROTO; }
	}
	if (error == 0) { owner->monitor = ergopti_process_exit_monitor_open(owner->leader, &error); }
	owner->error_code = error;
	if (error != 0) { ergopti_owned_program_cancel(owner); }
	return error;
}

int ergopti_owned_program_prepare(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	ergopti_owned_program **owner_out
) {
	return program_prepare(executable, arguments, environment, -1, -1, owner_out);
}

int ergopti_owned_program_prepare_with_tty(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int tty_descriptor,
	ergopti_owned_program **owner_out
) {
	// The caller retains this borrowed descriptor. Only the child's three
	// explicitly duplicated standard streams cross the CLOEXEC-default spawn.
	if (tty_descriptor <= STDERR_FILENO || isatty(tty_descriptor) != 1) { return EINVAL; }
	return program_prepare(executable, arguments, environment, tty_descriptor, -1, owner_out);
}

int ergopti_owned_program_prepare_with_tty_source(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int tty_descriptor,
	int source_descriptor,
	ergopti_owned_program **owner_out
) {
	struct stat source;
	if (tty_descriptor <= STDERR_FILENO + 1 || isatty(tty_descriptor) != 1
		|| source_descriptor <= STDERR_FILENO + 1 || fstat(source_descriptor, &source) != 0
		|| !S_ISREG(source.st_mode)) { return EINVAL; }
	// Only fixed fd 3 carries the retained source; the child cannot inherit the
	// guardian's control socket, PTY master or unrelated cancellation authority.
	return program_prepare(executable, arguments, environment, tty_descriptor, source_descriptor, owner_out);
}

ergopti_owned_program_receipt ergopti_owned_program_activate(ergopti_owned_program *owner) {
	if (owner == NULL) { return program_receipt(owner); }
	if (owner->retired || owner->cancelled || owner->active || owner->error_code != 0
		|| owner->monitor < 0 || !owner->identity_valid) {
		owner->error_code = EINVAL;
		return program_receipt(owner);
	}
	struct stat current;
	struct proc_bsdinfo info;
	int error = program_bsd_info(owner->leader, &info);
	if (error == 0 && (!program_identity_equal(owner->identity, program_identity_from_info(&info))
		|| info.pbi_pgid != (uint32_t)owner->leader || info.pbi_status != SSTOP)) { error = EPROTO; }
	if (error == 0 && stat(owner->executable, &current) != 0) { error = errno; }
	if (error == 0 && (current.st_dev != owner->executable_identity.st_dev
		|| current.st_ino != owner->executable_identity.st_ino
		|| current.st_size != owner->executable_identity.st_size
		|| current.st_mtimespec.tv_sec != owner->executable_identity.st_mtimespec.tv_sec
		|| current.st_mtimespec.tv_nsec != owner->executable_identity.st_mtimespec.tv_nsec)) { error = ESTALE; }
	if (error == 0 && kill(owner->leader, SIGCONT) != 0) { error = errno; }
	if (error != 0) {
		owner->error_code = error;
		ergopti_owned_program_cancel(owner);
	} else {
		owner->active = true;
	}
	return program_receipt(owner);
}

ergopti_owned_program_receipt ergopti_owned_program_cancel(ergopti_owned_program *owner) {
	if (owner == NULL || owner->retired) { return program_receipt(owner); }
	owner->cancelled = true;
	if (!owner->term_sent) {
		int error = program_send_group(owner, owner->active ? SIGTERM : SIGKILL);
		if (error != 0) { owner->error_code = error; }
		owner->term_sent = true;
		owner->kill_sent = !owner->active;
		clock_gettime(CLOCK_MONOTONIC, &owner->term_time);
	}
	return program_receipt(owner);
}

ergopti_owned_program_receipt ergopti_owned_program_poll(ergopti_owned_program *owner) {
	if (owner == NULL || owner->retired) { return program_receipt(owner); }
	struct proc_bsdinfo leader_info;
	int error = program_bsd_info(owner->leader, &leader_info);
	if (error == 0 && owner->identity_valid
		&& !program_identity_equal(owner->identity, program_identity_from_info(&leader_info))) { error = ESTALE; }
	if (error != 0) { owner->error_code = error; return program_receipt(owner); }
	// The exact unreaped child is an identity reservation even after leaving PGID.
	if (!owner->identity_valid) {
		if (leader_info.pbi_ppid != (uint32_t)getpid()) { owner->error_code = ECHILD; return program_receipt(owner); }
		owner->identity = program_identity_from_info(&leader_info);
		owner->identity_valid = true;
	}
	// A successful exact observation clears prior transient observation errors.
	// It cannot undo the cancellation latch or permit activation of a failed owner.
	owner->error_code = 0;
	owner->leader_exited = leader_info.pbi_status == SZOMB;
	if (owner->cancelled) {
		if (program_term_grace_elapsed(owner)) {
			error = program_send_group(owner, SIGKILL);
			if (error != 0) { owner->error_code = error; }
			owner->kill_sent = true;
		}
		// A direct leader may itself leave its initial group. Its exact unreaped
		// child capability remains signalable; descendants leaving are out of scope.
		if (!owner->leader_exited && leader_info.pbi_pgid != (uint32_t)owner->leader) {
			int signal_number = owner->kill_sent ? SIGKILL : SIGTERM;
			if (kill(owner->leader, signal_number) != 0) { owner->error_code = errno; }
		}
	}
	if (!owner->leader_exited) { return program_receipt(owner); }
	bool nonlive = false;
	error = program_group_nonlive(owner, &nonlive);
	if (error == EAGAIN || error == ESRCH) {
		// Members may disappear between the locked list and BSD-info reads, or
		// between two snapshots. Retry without confusing this with user failure.
		return program_receipt(owner);
	}
	if (error != 0) { owner->error_code = error; return program_receipt(owner); }
	if (!nonlive) { return program_receipt(owner); }
	int status = 0;
	pid_t waited;
	do { waited = waitpid(owner->leader, &status, WNOHANG); } while (waited == -1 && errno == EINTR);
	if (waited != owner->leader) {
		owner->error_code = waited == -1 ? errno : EAGAIN;
		return program_receipt(owner);
	}
	// This exact successful reap is the last operation on the numeric group.
	owner->retired = true;
	owner->error_code = 0;
	if (WIFEXITED(status)) {
		owner->status_valid = true;
		owner->exit_status = WEXITSTATUS(status);
	} else if (WIFSIGNALED(status)) {
		owner->status_valid = true;
		owner->exit_status = 128 + WTERMSIG(status);
	} else {
		owner->error_code = EPROTO;
	}
	return program_receipt(owner);
}

bool ergopti_owned_program_destroy(ergopti_owned_program **owner) {
	if (owner == NULL || *owner == NULL) { return false; }
	if (!(*owner)->retired) { return false; }
	program_release_storage(*owner);
	*owner = NULL;
	return true;
}
