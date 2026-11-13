/* Windows adapters remain inside the private PAC helper process. */
#ifndef ERGOPTI_WINDOWS_PAC_PLATFORM_H
#define ERGOPTI_WINDOWS_PAC_PLATFORM_H
#include "pac_runtime.h"
typedef struct {
	const ergopti_pac_limits *limits;
} ergopti_windows_pac_owner;
ergopti_pac_platform ergopti_windows_pac_platform(ergopti_windows_pac_owner *owner);
#endif
