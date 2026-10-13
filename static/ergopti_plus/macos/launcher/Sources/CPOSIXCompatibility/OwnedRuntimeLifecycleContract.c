// Sources/CPOSIXCompatibility/OwnedRuntimeLifecycleContract.c
// The shared native header defines the sole fixed inherited lifecycle descriptor.
#include "OwnedRuntimeLifecycleContract.h"

int32_t ergopti_owned_runtime_lifecycle_child_descriptor(void) {
	return ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR;
}
