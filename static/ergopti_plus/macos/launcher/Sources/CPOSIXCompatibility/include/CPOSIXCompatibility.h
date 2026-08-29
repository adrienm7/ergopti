// Sources/CPOSIXCompatibility/include/CPOSIXCompatibility.h

#ifndef ERGOPTI_C_POSIX_COMPATIBILITY_H
#define ERGOPTI_C_POSIX_COMPATIBILITY_H

#include <sys/types.h>

int ergopti_flock_compat(int descriptor, int operation);
int ergopti_process_exit_monitor_open(pid_t process_identifier, int *error_code);
int ergopti_process_exit_monitor_read(
	int descriptor,
	int *raw_wait_status,
	int *error_code
);

#endif
