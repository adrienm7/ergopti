// Sources/CPOSIXCompatibility/include/OwnedChildReapingCompatibility.h
// Keep the native sigaction function and struct behind one unambiguous C boundary.
#ifndef ERGOPTI_OWNED_CHILD_REAPING_COMPATIBILITY_H
#define ERGOPTI_OWNED_CHILD_REAPING_COMPATIBILITY_H

#include <signal.h>
#include <stddef.h>

/// Restores exact waitpid ownership in the isolated child-owning worker.
static inline int ergopti_owned_child_reaping_restore(void) {
	struct sigaction disposition = { 0 };
	disposition.sa_handler = SIG_DFL;
	if (sigemptyset(&disposition.sa_mask) != 0) {
		return -1;
	}
	return sigaction(SIGCHLD, &disposition, NULL);
}

/// Returns one only for default handling without auto-reap, zero for refusal, or minus one on native error.
static inline int ergopti_owned_child_reaping_observe(void) {
	struct sigaction disposition = { 0 };
	if (sigaction(SIGCHLD, NULL, &disposition) != 0) {
		return -1;
	}
	return disposition.sa_handler == SIG_DFL && (disposition.sa_flags & SA_NOCLDWAIT) == 0;
}

/// Reads the complete original disposition for an isolated native test's exact restoration.
static inline int ergopti_owned_child_disposition_read(struct sigaction *disposition) {
	return sigaction(SIGCHLD, NULL, disposition);
}

/// Writes one complete disposition; callers must check the native result.
static inline int ergopti_owned_child_disposition_write(const struct sigaction *disposition) {
	return sigaction(SIGCHLD, disposition, NULL);
}

#endif
