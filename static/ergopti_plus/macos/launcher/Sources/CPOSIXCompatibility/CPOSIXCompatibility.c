// Sources/CPOSIXCompatibility/CPOSIXCompatibility.c

#include "CPOSIXCompatibility.h"

#include <errno.h>
#include <stdint.h>
#include <sys/event.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

int ergopti_flock_compat(int descriptor, int operation) {
	return flock(descriptor, operation);
}

int ergopti_process_exit_monitor_open(pid_t process_identifier, int *error_code) {
	if (error_code != NULL) {
		*error_code = 0;
	}
	int descriptor = kqueue();
	if (descriptor < 0) {
		if (error_code != NULL) {
			*error_code = errno;
		}
		return -1;
	}

	struct kevent change;
	EV_SET(
		&change,
		(uintptr_t)process_identifier,
		EVFILT_PROC,
		EV_ADD | EV_ENABLE | EV_ONESHOT,
		NOTE_EXIT | NOTE_EXITSTATUS,
		0,
		NULL
	);
	if (kevent(descriptor, &change, 1, NULL, 0, NULL) != 0) {
		int registration_error = errno;
		close(descriptor);
		if (error_code != NULL) {
			*error_code = registration_error;
		}
		return -1;
	}
	return descriptor;
}

int ergopti_process_exit_monitor_read(
	int descriptor,
	int *raw_wait_status,
	int *error_code
) {
	if (raw_wait_status == NULL || error_code == NULL) {
		if (error_code != NULL) {
			*error_code = EINVAL;
		}
		return -1;
	}
	*raw_wait_status = 0;
	*error_code = 0;

	struct kevent event;
	struct timespec timeout = { .tv_sec = 0, .tv_nsec = 0 };
	int count = kevent(descriptor, NULL, 0, &event, 1, &timeout);
	if (count < 0) {
		*error_code = errno;
		return -1;
	}
	if (count == 0) {
		return 0;
	}
	if ((event.flags & EV_ERROR) != 0) {
		*error_code = event.data == 0 ? EIO : (int)event.data;
		return -1;
	}
	if ((event.fflags & NOTE_EXITSTATUS) == 0) {
		*error_code = EPROTO;
		return -1;
	}

	*raw_wait_status = (int)((uint32_t)event.data & NOTE_PDATAMASK);
	return 1;
}
