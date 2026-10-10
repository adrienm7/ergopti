// Sources/CPOSIXCompatibility/OwnedImageAliasCompatibility.c
// A retained source vnode gains one exclusive, source-bound regular-file name.

#include "OwnedImageAliasCompatibility.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int close_local(ergopti_owned_image_alias *alias, int descriptor) {
	if (close(descriptor) == 0) { return 0; }
	int error = errno;
	if (alias->close_error == 0) { alias->close_error = error; }
	return error;
}
static int private_ancestor(ergopti_owned_image_alias *alias) {
	int current = fcntl(alias->directory_fd, F_DUPFD_CLOEXEC, 0);
	if (current < 0) { return errno; }
	while (1) {
		struct stat held, parent;
		if (fstat(current, &held) != 0) { int error = errno; (void)close_local(alias, current); return error; }
		if (!S_ISDIR(held.st_mode) || held.st_uid != geteuid() || (held.st_mode & 0022) != 0) { (void)close_local(alias, current); return EPERM; }
		if ((held.st_mode & 0777) == 0700) {
			alias->ancestor_fd = current;
			alias->ancestor_device = (uint64_t)(uint32_t)held.st_dev; alias->ancestor_inode = (uint64_t)held.st_ino;
			return 0;
		}
		int next = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (next < 0) { int error = errno; (void)close_local(alias, current); return error; }
		if (fstat(next, &parent) != 0) { int error = errno; (void)close_local(alias, current); (void)close_local(alias, next); return error; }
		int error = close_local(alias, current);
		if (error != 0) { (void)close_local(alias, next); return error; }
		if (held.st_dev == parent.st_dev && held.st_ino == parent.st_ino) { (void)close_local(alias, next); return EPERM; }
		current = next;
	}
}
static int initialize(const char *directory, const char *nonce, ergopti_owned_image_alias *alias) {
	if (alias == NULL) { return EINVAL; }
	memset(alias, 0, sizeof(*alias));
	alias->directory_fd = alias->lease_fd = alias->image_fd = alias->ancestor_fd = -1;
	if (directory == NULL || directory[0] != '/' || nonce == NULL || strlen(nonce) != 32) { return EINVAL; }
	for (size_t index = 0; index < 32; index++) {
		if (!((nonce[index] >= '0' && nonce[index] <= '9') || (nonce[index] >= 'a' && nonce[index] <= 'f'))) { return EINVAL; }
	}
	memcpy(alias->nonce, nonce, 33);
	char *physical = realpath(directory, NULL);
	if (physical == NULL) { return errno; }
	int count = snprintf(alias->executable, sizeof(alias->executable), "%s/.ergopti-image-%s", physical, nonce);
	free(physical);
	if (count < 0 || (size_t)count >= sizeof(alias->executable)) { return ENAMETOOLONG; }
	alias->directory_fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (alias->directory_fd < 0) { return errno; }
	struct stat held, named;
	if (fstat(alias->directory_fd, &held) != 0 || lstat(directory, &named) != 0) { return errno; }
	if (!S_ISDIR(held.st_mode) || held.st_uid != geteuid() || (held.st_mode & 0022) != 0
		|| held.st_dev != named.st_dev || held.st_ino != named.st_ino) { return ESTALE; }
	alias->directory_device = (uint64_t)(uint32_t)held.st_dev; alias->directory_inode = (uint64_t)held.st_ino;
	return private_ancestor(alias);
}
static void names(const ergopti_owned_image_alias *alias, char *lease, char *image) {
	(void)snprintf(lease, 64, ".ergopti-lease-%s", alias->nonce);
	(void)snprintf(image, 64, ".ergopti-image-%s", alias->nonce);
}
static int identity(int descriptor, struct stat *value, int directory) {
	if (descriptor < 0 || fstat(descriptor, value) != 0) { return descriptor < 0 ? EBADF : errno; }
	if (value->st_uid != geteuid() || (directory ? !S_ISDIR(value->st_mode) : !S_ISREG(value->st_mode))) { return EPERM; }
	if (directory && (value->st_mode & 0777) != 0700) { return EPERM; }
	return 0;
}
int ergopti_image_alias_create(int source, const char *directory, const char *nonce, ergopti_owned_image_alias *alias) {
	int error = initialize(directory, nonce, alias);
	if (error != 0) { return error; }
	struct stat original, named, linked;
	if ((error = identity(source, &original, 0)) != 0) { return error; }
	if (fstatat(alias->directory_fd, "ollama", &named, AT_SYMLINK_NOFOLLOW) != 0) { return errno; }
	if (!S_ISREG(named.st_mode) || original.st_dev != named.st_dev || original.st_ino != named.st_ino) { return ESTALE; }
	if ((fcntl(source, F_GETFL) & O_ACCMODE) != O_RDONLY || original.st_nlink != 1
		|| (original.st_mode & 0111) == 0) { return EPERM; }
	char lease[64], image[64]; names(alias, lease, image);
	if (mkdirat(alias->directory_fd, lease, 0700) != 0) { return errno; }
	alias->lease_created = 1;
	alias->lease_fd = openat(alias->directory_fd, lease, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	struct stat reserved;
	if ((error = identity(alias->lease_fd, &reserved, 1)) != 0) { return error; }
	alias->lease_device = (uint64_t)(uint32_t)reserved.st_dev; alias->lease_inode = (uint64_t)reserved.st_ino;
	if (linkat(alias->directory_fd, "ollama", alias->directory_fd, image, 0) != 0) { return errno; }
	alias->image_created = 1;
	alias->image_fd = openat(alias->directory_fd, image, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if ((error = identity(alias->image_fd, &linked, 0)) != 0) { return error; }
	alias->device = (uint64_t)(uint32_t)linked.st_dev; alias->inode = (uint64_t)linked.st_ino;
	if (linked.st_dev != original.st_dev || linked.st_ino != original.st_ino || linked.st_nlink != 2) { return ESTALE; }
	return 0;
}
int ergopti_image_alias_admit(const char *directory, const char *nonce, uint64_t directory_device,
	uint64_t directory_inode, uint64_t ancestor_device, uint64_t ancestor_inode, uint64_t lease_device, uint64_t lease_inode, uint64_t device,
	uint64_t inode, ergopti_owned_image_alias *alias) {
	int error = initialize(directory, nonce, alias);
	if (error != 0) { return error; }
	if (alias->directory_device != directory_device || alias->directory_inode != directory_inode) { return ESTALE; }
	if (alias->ancestor_device != ancestor_device || alias->ancestor_inode != ancestor_inode) { return ESTALE; }
	char lease[64], image[64]; names(alias, lease, image);
	alias->lease_fd = openat(alias->directory_fd, lease, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	struct stat reserved, linked;
	if ((error = identity(alias->lease_fd, &reserved, 1)) != 0) { return error; }
	alias->lease_device = (uint64_t)(uint32_t)reserved.st_dev; alias->lease_inode = (uint64_t)reserved.st_ino;
	if (alias->lease_device != lease_device || alias->lease_inode != lease_inode) { return ESTALE; }
	alias->image_fd = openat(alias->directory_fd, image, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if ((error = identity(alias->image_fd, &linked, 0)) != 0) { return error; }
	alias->device = (uint64_t)(uint32_t)linked.st_dev; alias->inode = (uint64_t)linked.st_ino;
	if (alias->device != device || alias->inode != inode || (linked.st_mode & 0111) == 0
		|| linked.st_nlink < 1 || linked.st_nlink > 2) { return ESTALE; }
	return 0;
}
int ergopti_image_alias_close(ergopti_owned_image_alias *alias) {
	if (alias == NULL) { return EINVAL; }
	int *descriptors[] = { &alias->image_fd, &alias->lease_fd, &alias->directory_fd, &alias->ancestor_fd };
	for (size_t index = 0; index < 4; index++) {
		if (*descriptors[index] >= 0) {
			int descriptor = *descriptors[index];
			*descriptors[index] = -1;
			if (close(descriptor) != 0 && alias->close_error == 0) { alias->close_error = errno; }
		}
	}
	return alias->close_error;
}
int ergopti_image_alias_retire(ergopti_owned_image_alias *alias) {
	if (alias == NULL) { return EINVAL; }
	if (!alias->lease_created && !alias->image_created) { return ergopti_image_alias_close(alias); }
	if (alias->directory_fd < 0 || (alias->lease_created && alias->lease_fd < 0)
		|| (alias->image_created && alias->image_fd < 0)) { return ESTALE; }
	char lease[64], image[64]; names(alias, lease, image);
	struct stat named, held;
	if (alias->image_created) {
		if (fstatat(alias->directory_fd, image, &named, AT_SYMLINK_NOFOLLOW) != 0 || fstat(alias->image_fd, &held) != 0) { return errno; }
		if (named.st_dev != held.st_dev || named.st_ino != held.st_ino) { return ESTALE; }
	}
	if (alias->lease_created) {
		if (fstatat(alias->directory_fd, lease, &named, AT_SYMLINK_NOFOLLOW) != 0 || fstat(alias->lease_fd, &held) != 0) { return errno; }
		if (named.st_dev != held.st_dev || named.st_ino != held.st_ino) { return ESTALE; }
		// Unknown files retain debt. A completed phase never needs to reopen
		// its name when the next unlink fails and this owner retries.
		if (unlinkat(alias->directory_fd, lease, AT_REMOVEDIR) != 0) { return errno; }
		alias->lease_created = 0;
	}
	if (alias->image_created) {
		if (unlinkat(alias->directory_fd, image, 0) != 0) { return errno; }
		alias->image_created = 0;
	}
	return ergopti_image_alias_close(alias);
}
