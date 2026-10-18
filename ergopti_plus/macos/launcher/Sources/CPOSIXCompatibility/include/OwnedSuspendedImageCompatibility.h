// Sources/CPOSIXCompatibility/include/OwnedSuspendedImageCompatibility.h
#ifndef ERGOPTI_OWNED_SUSPENDED_IMAGE_COMPATIBILITY_H
#define ERGOPTI_OWNED_SUSPENDED_IMAGE_COMPATIBILITY_H

#include "OwnedProgramCompatibility.h"
#include "LoopbackListenerCompatibility.h"

// Borrows the retained readonly alias descriptor. A successful result proves an
// exact owned suspended child mapped that catalogue vnode; it does not resume,
// release, or transfer the owner, and supplies no socket/session authority.
int ergopti_owned_suspended_image_validate(ergopti_owned_program *owner,
	const char *executable, int alias_descriptor, uint64_t device, uint64_t inode,
	uint32_t remaining_ms, ergopti_listener_identity *identity);
int ergopti_owned_active_image_validate(ergopti_owned_program *owner,
 const char *executable, int alias_descriptor, uint64_t device, uint64_t inode,
 uint32_t remaining_ms, ergopti_listener_identity *identity);
#endif
