// Sources/CPOSIXCompatibility/OwnedSuspendedImageCompatibility.c
// Binds the retained alias capability to the exact owned pre-execution mapping.

#include "OwnedSuspendedImageCompatibility.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int image_remaining(const struct timespec *started, uint32_t budget, uint32_t *remaining) {
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { return errno == 0 ? EIO : errno; }
	int64_t elapsed = ((int64_t)now.tv_sec - started->tv_sec) * 1000000000LL
		+ now.tv_nsec - started->tv_nsec;
	if (elapsed < 0 || elapsed >= (int64_t)budget * 1000000LL) { return ETIMEDOUT; }
	uint64_t used = ((uint64_t)elapsed + 999999) / 1000000;
	if (used >= budget) { return ETIMEDOUT; }
	*remaining = budget - (uint32_t)used;
	return 0;
}

static int image_descriptor(int descriptor, uint64_t device, uint64_t inode, struct stat *identity) {
	if (fstat(descriptor, identity) != 0) { return errno == 0 ? EIO : errno; }
	if (!S_ISREG(identity->st_mode) || identity->st_uid != geteuid()
		|| (identity->st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) != 0
		|| (identity->st_mode & S_IXUSR) == 0 || identity->st_size <= 0
		|| (uint64_t)(uint32_t)identity->st_dev != device || (uint64_t)identity->st_ino != inode) {
		return ESTALE;
	}
	int flags = fcntl(descriptor, F_GETFL);
	int descriptor_flags = fcntl(descriptor, F_GETFD);
	if (flags < 0 || descriptor_flags < 0) { return errno == 0 ? EIO : errno; }
	if ((flags & O_ACCMODE) != O_RDONLY || (descriptor_flags & FD_CLOEXEC) == 0) { return EPERM; }
	return 0;
}

int ergopti_owned_suspended_image_validate(ergopti_owned_program *owner,
	const char *executable, int alias_descriptor, uint64_t device, uint64_t inode,
	uint32_t remaining_ms, ergopti_listener_identity *identity) {
	if (identity == NULL) { return EINVAL; }
	*identity = (ergopti_listener_identity) {0};
	if (owner == NULL || executable == NULL || executable[0] != '/'
		|| alias_descriptor < 0 || inode == 0 || remaining_ms == 0 || remaining_ms > INT32_MAX) { return EINVAL; }
	struct timespec started;
	if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) { return errno == 0 ? EIO : errno; }
	struct stat before, after;
	int error = image_descriptor(alias_descriptor, device, inode, &before);
	if (error != 0) { return error; }
	ergopti_owned_program_observation owned = ergopti_owned_program_prepared_identity(owner);
	if (owned.error_code != 0) { return owned.error_code; }
	if (owned.nonlive || owned.process_id <= 0 || owned.process_group_id != owned.process_id
		|| owned.start_microseconds >= 1000000) { return ESTALE; }
	ergopti_listener_identity expected = { .pid = owned.process_id, .uid = geteuid(),
		.start_seconds = owned.start_seconds, .start_microseconds = owned.start_microseconds,
		.device = device, .inode = inode };
	uint32_t remaining = 0;
	if ((error = image_remaining(&started, remaining_ms, &remaining)) != 0) { return error; }
	ergopti_listener_identity mapped = {0};
	if ((error = ergopti_suspended_image_validate(executable, &expected, remaining, &mapped)) != 0) { return error; }
	if (mapped.pid != expected.pid || mapped.uid != expected.uid
		|| mapped.start_seconds != expected.start_seconds || mapped.start_microseconds != expected.start_microseconds
		|| mapped.device != device || mapped.inode != inode) { return ESTALE; }
	ergopti_owned_program_observation final = ergopti_owned_program_prepared_identity(owner);
	if (final.error_code != 0) { return final.error_code; }
	if (final.nonlive || final.process_id != owned.process_id || final.process_group_id != owned.process_group_id
		|| final.start_seconds != owned.start_seconds || final.start_microseconds != owned.start_microseconds) { return ESTALE; }
	if ((error = image_descriptor(alias_descriptor, device, inode, &after)) != 0) { return error; }
	if (before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_size != after.st_size
		|| before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
		|| before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) { return ESTALE; }
	if ((error = image_remaining(&started, remaining_ms, &remaining)) != 0) { return error; }
	*identity = mapped;
	return 0;
}
