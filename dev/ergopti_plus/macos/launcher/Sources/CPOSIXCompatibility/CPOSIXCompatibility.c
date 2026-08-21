// Sources/CPOSIXCompatibility/CPOSIXCompatibility.c

#include "CPOSIXCompatibility.h"

#include <sys/file.h>

int ergopti_flock_compat(int descriptor, int operation) {
	return flock(descriptor, operation);
}
