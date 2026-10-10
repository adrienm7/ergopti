// Sources/CPOSIXCompatibility/include/OwnedProgramCompatibility.h

#ifndef ERGOPTI_OWNED_PROGRAM_COMPATIBILITY_H
#define ERGOPTI_OWNED_PROGRAM_COMPATIBILITY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// Establishes a new private native session before any child or secret exists.
// Nonzero returns refuse isolation, including an unprovable parent-group binding.
int ergopti_owned_program_create_private_session(void);

typedef struct ergopti_owned_program ergopti_owned_program;

// Observation is not ownership; callers compare start identity before using it.
typedef struct {
	int error_code;
	pid_t process_id;
	pid_t process_group_id;
	uint64_t start_seconds;
	uint64_t start_microseconds;
	bool nonlive;
} ergopti_owned_program_observation;
ergopti_owned_program_observation ergopti_owned_program_observe(pid_t process_id);

// Only an owned, unactivated, exact suspended child can supply this observation.
// Refusal does not cancel, transfer or release the caller's cleanup authority.
ergopti_owned_program_observation ergopti_owned_program_prepared_identity(ergopti_owned_program *owner);

typedef struct {
	int error_code;
	bool active;
	bool cancelled;
	bool leader_exited;
	bool retired;
	bool status_valid;
	int exit_status;
} ergopti_owned_program_receipt;

// Nonzero errors after spawn retain an owner for exact native cleanup.
int ergopti_owned_program_prepare(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	ergopti_owned_program **owner
);
// Borrowed tty capability; the caller closes it after preparation. Native
// ownership, leader reservation and retirement match the original API exactly.
int ergopti_owned_program_prepare_with_tty(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int tty_descriptor,
	ergopti_owned_program **owner
);
// Additionally borrows one regular source descriptor into the child's fixed fd
// 3. The caller retains both original descriptors until prepare has returned.
int ergopti_owned_program_prepare_with_tty_source(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int tty_descriptor,
	int source_descriptor,
	ergopti_owned_program **owner
);
// Query roles capture into caller-owned pipes; retirement uses the same native custody.
int ergopti_owned_query_prepare(
	const char *executable,
	char *const arguments[],
	char *const environment[],
	int output_descriptor,
	int error_descriptor,
	ergopti_owned_program **owner
);
ergopti_owned_program_receipt ergopti_owned_program_activate(ergopti_owned_program *owner);
ergopti_owned_program_receipt ergopti_owned_program_cancel(ergopti_owned_program *owner);
ergopti_owned_program_receipt ergopti_owned_program_poll(ergopti_owned_program *owner);
// A failed destruction leaves the pointer and cleanup capability intact.
bool ergopti_owned_program_destroy(ergopti_owned_program **owner);

ergopti_owned_program_observation ergopti_owned_program_active_identity(ergopti_owned_program *owner);
#endif
