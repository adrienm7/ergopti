/* tests/hardware/virtual_kernel_preload.c
 *
 * A kernel model for the Linux container proofs, loaded with LD_PRELOAD into
 * the unchanged daemon. A cloud container's kernel has no uinput and no evdev
 * nodes, so this shim answers, at the libc boundary, the calls the daemon's
 * production FFI backends make to those two kernel interfaces. Everything
 * above libc runs as shipped: the device finder, the evdev reader with its
 * native custody checks, the hook, the engines, the injector and the uinput
 * writer.
 *
 * WHAT IT KEEPS FROM THE KERNEL:
 * 1. /dev/input/eventN is a FIFO the harness writes kernel-format
 *    `struct input_event` records into; this shim opens it read-write so the
 *    reader never sees an end of file between two writes, and reports it to
 *    fstat/statx as the input character device 13:(64+N).
 * 2. EVIOCGBIT answers the capability bitmaps the harness chose (the same
 *    bitmaps it wrote into the bind-mounted /proc/bus/input/devices);
 *    EVIOCGKEY, EVIOCGLED, EVIOCGSW and EVIOCGSND answer an empty state;
 *    EVIOCGNAME, EVIOCGID and EVIOCGVERSION answer the device's identity.
 * 3. EVIOCGRAB is exclusive as in the kernel (EBUSY for a second grabber),
 *    and every grab and release is appended to ERGOPTI_VK_STATUS so the
 *    harness, like the kernel, delivers a physical event to the desktop only
 *    while no grab holds its device.
 * 4. /dev/uinput opens the FIFO named by ERGOPTI_VK_UINPUT, whose reader (the
 *    harness) decodes the records the writer emits, frame by frame at
 *    SYN_REPORT, as the kernel does before an X server or a compositor reads
 *    them. UI_* setup ioctls are acknowledged.
 *
 * WHAT IT CANNOT KEEP: kernel timing, SYN_DROPPED on a reader overflow, and
 * the udev publication of the created node. The CI Linux lane, whose runners
 * have uinput, keeps the real-kernel harnesses (run_grab_race.lua,
 * run_daemon_live.sh).
 *
 * Devices: ERGOPTI_VK_DEVICES="90,91" and, per device,
 * ERGOPTI_VK_DEVICE_<N>="<name>|<ev hex>|<key hex>|<rel hex>|<msc hex>",
 * each bitmap a little-endian byte string in hex.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/stat.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define MAX_FDS 4096
#define MAX_DEVICES 8
#define BITMAP_BYTES 96
#define INPUT_MAJOR 13
#define EVDEV_MINOR_BASE 64
#define UINPUT_MAJOR 10
#define UINPUT_MINOR 223

struct device {
    int event;
    char name[128];
    unsigned char bits[EV_MAX + 1][BITMAP_BYTES];
    int grabber;
};

static struct device devices[MAX_DEVICES];
static int device_count = -1;
/* Per descriptor: 0 not ours, 1 + index for an evdev node, -1 for uinput. */
static int fd_kind[MAX_FDS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static int (*real_open)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_close)(int);
static int (*real_ioctl)(int, unsigned long, ...);
static long (*real_syscall)(long, ...);
static int (*real_fstat)(int, struct stat *);

static void resolve(void) {
    if (real_open) return;
    real_open = dlsym(RTLD_NEXT, "open");
    real_openat = dlsym(RTLD_NEXT, "openat");
    real_close = dlsym(RTLD_NEXT, "close");
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_syscall = dlsym(RTLD_NEXT, "syscall");
    real_fstat = dlsym(RTLD_NEXT, "fstat");
}

/* The model stands for the kernel under the daemon process only: its helper
 * children (the AT-SPI focus worker, xkbcomp, shells) keep the real libc. */
__attribute__((constructor)) static void keep_to_this_process(void) {
    unsetenv("LD_PRELOAD");
}

static void parse_hex(const char *text, unsigned char *out) {
    for (int index = 0; index < BITMAP_BYTES && text[0] && text[1] && text[0] != '|'; index++, text += 2) {
        char pair[3] = {text[0], text[1], 0};
        out[index] = (unsigned char)strtoul(pair, NULL, 16);
    }
}

static void load_devices(void) {
    if (device_count >= 0) return;
    device_count = 0;
    const char *list = getenv("ERGOPTI_VK_DEVICES");
    if (!list) return;
    char copy[256];
    snprintf(copy, sizeof copy, "%s", list);
    for (char *save = NULL, *item = strtok_r(copy, ",", &save); item && device_count < MAX_DEVICES;
         item = strtok_r(NULL, ",", &save)) {
        char key[64];
        snprintf(key, sizeof key, "ERGOPTI_VK_DEVICE_%s", item);
        const char *spec = getenv(key);
        if (!spec) continue;
        struct device *device = &devices[device_count];
        memset(device, 0, sizeof *device);
        device->event = atoi(item);
        device->grabber = -1;
        const char *bar = strchr(spec, '|');
        if (!bar) continue;
        snprintf(device->name, sizeof device->name, "%.*s", (int)(bar - spec), spec);
        const int order[] = {0, EV_KEY, EV_REL, EV_MSC};
        for (int field = 0; field < 4 && bar; field++) {
            parse_hex(bar + 1, device->bits[order[field]]);
            bar = strchr(bar + 1, '|');
        }
        device_count++;
    }
}

static int model_device(const char *path) {
    int number;
    char tail;
    if (!path || sscanf(path, "/dev/input/event%d%c", &number, &tail) != 1) return -1;
    load_devices();
    for (int index = 0; index < device_count; index++)
        if (devices[index].event == number) return index;
    return -1;
}

static void note(const char *format, int event, int value) {
    const char *path = getenv("ERGOPTI_VK_STATUS");
    if (!path) return;
    FILE *file = fopen(path, "a");
    if (!file) return;
    fprintf(file, format, event, value);
    fclose(file);
}

static int track(int fd, int kind) {
    if (fd >= 0 && fd < MAX_FDS) fd_kind[fd] = kind;
    return fd;
}

static int open_model(const char *path, int flags, mode_t mode, int dirfd, int at) {
    resolve();
    if (path && strcmp(path, "/dev/uinput") == 0 && getenv("ERGOPTI_VK_UINPUT")) {
        int fd = real_open(getenv("ERGOPTI_VK_UINPUT"), O_RDWR | (flags & (O_CLOEXEC | O_NONBLOCK)));
        return track(fd, -1);
    }
    int index = model_device(path);
    if (index >= 0) {
        int fd = real_open(path, O_RDWR | (flags & (O_CLOEXEC | O_NONBLOCK)));
        return track(fd, 1 + index);
    }
    return at ? real_openat(dirfd, path, flags, mode) : real_open(path, flags, mode);
}

int open(const char *path, int flags, ...) {
    va_list args;
    va_start(args, flags);
    mode_t mode = (flags & (O_CREAT | O_TMPFILE)) ? va_arg(args, mode_t) : 0;
    va_end(args);
    return open_model(path, flags, mode, AT_FDCWD, 0);
}

int open64(const char *path, int flags, ...) __attribute__((alias("open")));

int openat(int dirfd, const char *path, int flags, ...) {
    va_list args;
    va_start(args, flags);
    mode_t mode = (flags & (O_CREAT | O_TMPFILE)) ? va_arg(args, mode_t) : 0;
    va_end(args);
    return open_model(path, flags, mode, dirfd, 1);
}

int openat64(int dirfd, const char *path, int flags, ...) __attribute__((alias("openat")));

/* Forgets a descriptor the process closes; a grab dies with its descriptor. */
static void forget(int fd) {
    if (fd >= 0 && fd < MAX_FDS && fd_kind[fd] > 0) {
        pthread_mutex_lock(&lock);
        struct device *device = &devices[fd_kind[fd] - 1];
        if (device->grabber == fd) {
            device->grabber = -1;
            note("GRAB event%d %d\n", device->event, 0);
        }
        pthread_mutex_unlock(&lock);
    }
    if (fd >= 0 && fd < MAX_FDS) fd_kind[fd] = 0;
}

int close(int fd) {
    resolve();
    forget(fd);
    return real_close(fd);
}

static void fill(void *out, const unsigned char *bits, unsigned int size) {
    unsigned int count = size < BITMAP_BYTES ? size : BITMAP_BYTES;
    memset(out, 0, size);
    if (bits) memcpy(out, bits, count);
}

static int evdev_ioctl(struct device *device, int fd, unsigned long request, void *arg) {
    unsigned int nr = _IOC_NR(request), size = _IOC_SIZE(request);
    if (_IOC_TYPE(request) != 'E') return 0;
    if (request == EVIOCGRAB) {
        int value = (int)(long)arg;
        pthread_mutex_lock(&lock);
        int busy = value && device->grabber >= 0 && device->grabber != fd;
        if (!busy) {
            int changed = value ? device->grabber != fd : device->grabber == fd;
            device->grabber = value ? fd : (device->grabber == fd ? -1 : device->grabber);
            if (changed) note("GRAB event%d %d\n", device->event, value ? 1 : 0);
        }
        pthread_mutex_unlock(&lock);
        if (busy) {
            errno = EBUSY;
            return -1;
        }
        return 0;
    }
    if (_IOC_DIR(request) & _IOC_READ) {
        if (nr >= 0x20 && nr < 0x20 + EV_MAX + 1) {
            fill(arg, device->bits[nr - 0x20], size);
            return (int)size;
        }
        if (nr == _IOC_NR(EVIOCGKEY(0)) || nr == _IOC_NR(EVIOCGLED(0)) || nr == _IOC_NR(EVIOCGSND(0)) ||
            nr == _IOC_NR(EVIOCGSW(0))) {
            fill(arg, NULL, size);
            return (int)size;
        }
        if (nr == _IOC_NR(EVIOCGNAME(0))) {
            snprintf(arg, size, "%s", device->name);
            return (int)strlen(device->name) + 1;
        }
        if (request == EVIOCGID) {
            struct input_id *id = arg;
            id->bustype = BUS_USB;
            id->vendor = 0xfeed;
            id->product = (unsigned short)device->event;
            id->version = 0x0111;
            return 0;
        }
        if (request == EVIOCGVERSION) {
            *(int *)arg = EV_VERSION;
            return 0;
        }
        fill(arg, NULL, size);
        return 0;
    }
    return 0;
}

int ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);
    resolve();
    if (fd >= 0 && fd < MAX_FDS && fd_kind[fd] > 0) return evdev_ioctl(&devices[fd_kind[fd] - 1], fd, request, arg);
    if (fd >= 0 && fd < MAX_FDS && fd_kind[fd] == -1) {
        /* UI_GET_SYSNAME: the kernel's name of the created node. */
        if (_IOC_TYPE(request) == 'U' && _IOC_NR(request) == 44 && (_IOC_DIR(request) & _IOC_READ)) {
            snprintf(arg, _IOC_SIZE(request), "input99");
            return 8;
        }
        return 0;
    }
    return real_ioctl(fd, request, arg);
}

static int model_rdev(int fd, unsigned int *major_out, unsigned int *minor_out) {
    if (fd < 0 || fd >= MAX_FDS || fd_kind[fd] == 0) return 0;
    if (fd_kind[fd] == -1) {
        *major_out = UINPUT_MAJOR;
        *minor_out = UINPUT_MINOR;
    } else {
        *major_out = INPUT_MAJOR;
        *minor_out = EVDEV_MINOR_BASE + (unsigned int)devices[fd_kind[fd] - 1].event;
    }
    return 1;
}

int fstat(int fd, struct stat *buffer) {
    resolve();
    int result = real_fstat(fd, buffer);
    unsigned int major_number, minor_number;
    if (result == 0 && model_rdev(fd, &major_number, &minor_number)) {
        buffer->st_mode = (buffer->st_mode & ~S_IFMT) | S_IFCHR;
        buffer->st_rdev = makedev(major_number, minor_number);
    }
    return result;
}

/* libuv reaches statx (fs_fstat, on an empty path) and close through syscall(2). */
long syscall(long number, ...) {
    va_list args;
    va_start(args, number);
    long a = va_arg(args, long), b = va_arg(args, long), c = va_arg(args, long), d = va_arg(args, long),
         e = va_arg(args, long), f = va_arg(args, long);
    va_end(args);
    resolve();
    if (number == SYS_close) forget((int)a);
    long result = real_syscall(number, a, b, c, d, e, f);
    unsigned int major_number, minor_number;
    if (number == SYS_statx && result == 0 && (c & AT_EMPTY_PATH) && model_rdev((int)a, &major_number, &minor_number)) {
        struct statx *buffer = (struct statx *)e;
        buffer->stx_mode = (unsigned short)((buffer->stx_mode & ~S_IFMT) | S_IFCHR);
        buffer->stx_rdev_major = major_number;
        buffer->stx_rdev_minor = minor_number;
    }
    return result;
}
