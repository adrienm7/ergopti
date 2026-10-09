// Sources/CPOSIXCompatibility/include/OwnedImageAliasCompatibility.h
#ifndef ERGOPTI_OWNED_IMAGE_ALIAS_COMPATIBILITY_H
#define ERGOPTI_OWNED_IMAGE_ALIAS_COMPATIBILITY_H

#include <stdint.h>

typedef struct {
	int directory_fd;
	int lease_fd;
	int image_fd;
	int ancestor_fd;
	uint32_t lease_created;
	uint32_t image_created;
	int32_t close_error;
	uint64_t directory_device;
	uint64_t directory_inode;
	uint64_t ancestor_device;
	uint64_t ancestor_inode;
	uint64_t lease_device;
	uint64_t lease_inode;
	uint64_t device;
	uint64_t inode;
	char nonce[33];
	char executable[4096];
} ergopti_owned_image_alias;

// Acquire before source unlink. Darwin linkat has no AT_EMPTY_PATH; a raced
// source pathname is refused by comparing the actual link with the held FD.
int ergopti_image_alias_create(int retained_source, const char *runtime_directory,
	const char *nonce, ergopti_owned_image_alias *alias);
// Admit only a fixed nonce-derived alias and exclusive private lease in the
// exact source runtime directory, retaining all native descriptors until EOF.
int ergopti_image_alias_admit(const char *runtime_directory, const char *nonce,
	uint64_t directory_device, uint64_t directory_inode, uint64_t ancestor_device,
	uint64_t ancestor_inode, uint64_t lease_device,
	uint64_t lease_inode, uint64_t device, uint64_t inode, ergopti_owned_image_alias *alias);
// This must follow actual child retirement. Changed names retain cleanup debt.
int ergopti_image_alias_retire(ergopti_owned_image_alias *alias);
// A request borrows the lease; it closes descriptors without deleting owner state.
int ergopti_image_alias_close(ergopti_owned_image_alias *alias);
#endif
