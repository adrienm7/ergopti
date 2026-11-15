/* static/ergopti_plus/linux/tests/hardware/desktop/evdev_fifo_shim.c
 *
 * ==============================================================================
 * MODULE: Evdev ioctl shim for a FIFO keyboard node
 * DESCRIPTION:
 * The cloud kernel has neither evdev nor uinput, so no /dev/input/eventN node
 * can exist. run_linux_dev_mode.sh puts a FIFO at /dev/input/event0 in a
 * private mount namespace and preloads this shim into the daemon: on that FIFO
 * alone, the evdev query ioctls answer an idle keyboard (EV_SYN and EV_KEY,
 * no key or LED held) and EVIOCGRAB succeeds; every other descriptor reaches
 * the real ioctl. The daemon then starts its tray and reload paths, which are
 * what the developer-mode proof checks; real input stays a field check.
 * ==============================================================================
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <linux/input.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static const char NODE[] = "/dev/input/event0";

/* Whether fd is the FIFO standing for the keyboard node. */
static int is_fake_node(int fd) {
	char link[64], target[sizeof(NODE) + 1];
	snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
	ssize_t length = readlink(link, target, sizeof(target));
	return length == (ssize_t)(sizeof(NODE) - 1) && memcmp(target, NODE, sizeof(NODE) - 1) == 0;
}

int ioctl(int fd, unsigned long request, ...) {
	va_list args;
	va_start(args, request);
	void *argument = va_arg(args, void *);
	va_end(args);
	if (_IOC_TYPE(request) == 'E' && is_fake_node(fd)) {
		if (request == EVIOCGRAB) return 0;
		if (_IOC_DIR(request) & _IOC_READ) {
			unsigned size = _IOC_SIZE(request);
			memset(argument, 0, size);
			if (request == EVIOCGBIT(0, size) && size > 0) {
				((unsigned char *)argument)[0] = (1u << EV_SYN) | (1u << EV_KEY);
			}
			return (int)size;
		}
		return 0;
	}
	int (*real)(int, unsigned long, ...) = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
	return real(fd, request, argument);
}
