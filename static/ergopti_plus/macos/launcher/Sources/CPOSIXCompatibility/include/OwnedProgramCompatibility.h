// Sources/CPOSIXCompatibility/include/OwnedProgramCompatibility.h

#ifndef ERGOPTI_OWNED_PROGRAM_COMPATIBILITY_H
#define ERGOPTI_OWNED_PROGRAM_COMPATIBILITY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

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
ergopti_owned_program_receipt ergopti_owned_program_activate(ergopti_owned_program *owner);
ergopti_owned_program_receipt ergopti_owned_program_cancel(ergopti_owned_program *owner);
ergopti_owned_program_receipt ergopti_owned_program_poll(ergopti_owned_program *owner);
// A failed destruction leaves the pointer and cleanup capability intact.
bool ergopti_owned_program_destroy(ergopti_owned_program **owner);

#endif
