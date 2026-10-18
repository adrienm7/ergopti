// Sources/CPOSIXCompatibility/include/OwnedRuntimeSignatureCompatibility.h
// Bridge the actual SDK flag to Swift; a decoded flag alone grants no publisher authority.
#ifndef ERGOPTI_OWNED_RUNTIME_SIGNATURE_COMPATIBILITY_H
#define ERGOPTI_OWNED_RUNTIME_SIGNATURE_COMPATIBILITY_H
#if defined(__APPLE__)
#include <stdint.h>
#include <Security/SecCode.h>

static inline uint32_t ergopti_owned_runtime_signature_adhoc_flag(void) {
	return (uint32_t)kSecCodeSignatureAdhoc;
}
#endif
#endif
