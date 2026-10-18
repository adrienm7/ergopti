// Sources/CPOSIXCompatibility/include/OwnedRuntimeLifecycleContract.h
// One native transport slot: no caller-selected descriptor, readiness bit or ownership receipt.
#ifndef ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CONTRACT_H
#define ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CONTRACT_H
#include <stdint.h>

enum { ERGOPTI_OWNED_RUNTIME_LIFECYCLE_CHILD_DESCRIPTOR = 198 };
#ifdef __cplusplus
extern "C" {
#endif
int32_t ergopti_owned_runtime_lifecycle_child_descriptor(void);
#ifdef __cplusplus
}
#endif
#endif
