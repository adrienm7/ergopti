#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Official header facts, independent of the candidate's three typedefs. */
unsigned long ep_xi_type(unsigned int kind, unsigned int metric) {
#define TYPE(N, T) case N: return metric == 0 ? sizeof(T) : _Alignof(T)
    if (metric > 1) return ULONG_MAX;
    switch (kind) {
        TYPE(0, XGenericEventCookie);
        TYPE(1, XIPropertyEvent);
        TYPE(2, XIEventMask);
        TYPE(3, XEvent);
        default: return ULONG_MAX;
    }
#undef TYPE
}

unsigned long ep_xi_field(unsigned int kind, unsigned int field, unsigned int metric) {
#define FIELD(N, T, F) case N: return metric == 0 ? offsetof(T, F) : sizeof(((T *)0)->F)
    if (metric > 1) return ULONG_MAX;
    if (kind == 0) switch (field) {
        FIELD(0, XGenericEventCookie, type); FIELD(1, XGenericEventCookie, serial);
        FIELD(2, XGenericEventCookie, send_event); FIELD(3, XGenericEventCookie, display);
        FIELD(4, XGenericEventCookie, extension); FIELD(5, XGenericEventCookie, evtype);
        FIELD(6, XGenericEventCookie, cookie); FIELD(7, XGenericEventCookie, data);
        default: return ULONG_MAX;
    }
    if (kind == 1) switch (field) {
        FIELD(0, XIPropertyEvent, type); FIELD(1, XIPropertyEvent, serial);
        FIELD(2, XIPropertyEvent, send_event); FIELD(3, XIPropertyEvent, display);
        FIELD(4, XIPropertyEvent, extension); FIELD(5, XIPropertyEvent, evtype);
        FIELD(6, XIPropertyEvent, time); FIELD(7, XIPropertyEvent, deviceid);
        FIELD(8, XIPropertyEvent, property); FIELD(9, XIPropertyEvent, what);
        default: return ULONG_MAX;
    }
    if (kind == 2) switch (field) {
        FIELD(0, XIEventMask, deviceid); FIELD(1, XIEventMask, mask_len);
        FIELD(2, XIEventMask, mask);
        default: return ULONG_MAX;
    }
    return ULONG_MAX;
#undef FIELD
}

int ep_property_what(unsigned int phase) {
    switch (phase) {
        case 0: return XIPropertyCreated;
        case 1: return XIPropertyModified;
        case 2: return XIPropertyDeleted;
        default: return -1;
    }
}

int ep_symbol_matches(void *symbol, const char *expected) {
    Dl_info info;
    char actual[PATH_MAX], pinned[PATH_MAX];
    if (!symbol || !expected || !dladdr(symbol, &info) || !info.dli_fname) return 0;
    if (!realpath(info.dli_fname, actual) || !realpath(expected, pinned)) return 0;
    return strcmp(actual, pinned) == 0;
}

/* Observation only: own process FDs, exact already-owned Xvfb peer, no PID scan/kill. */
int ep_xvfb_peers(int expected_pid, unsigned int expected_uid) {
    if (expected_pid <= 0) return -1;
    DIR *directory = opendir("/proc/self/fd");
    if (!directory) return -1;
    int own_fd = dirfd(directory), count = 0, examined = 0, result = -1;
    struct dirent *entry;
    while (1) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { if (errno != 0) goto done; break; }
        if (++examined > 4096) goto done;
        char *end;
        long number = strtol(entry->d_name, &end, 10);
        if (!*entry->d_name || *end || number < 0 || number > INT_MAX || number == own_fd) continue;
        struct sockaddr_storage address;
        socklen_t length = sizeof(address);
        if (getpeername((int)number, (struct sockaddr *)&address, &length) != 0) continue;
        if (address.ss_family != AF_UNIX) continue;
        struct ucred peer;
        length = sizeof(peer);
        if (getsockopt((int)number, SOL_SOCKET, SO_PEERCRED, &peer, &length) != 0) goto done;
        if (length != sizeof(peer)) goto done;
        if (peer.pid == expected_pid && peer.uid == expected_uid) count++;
    }
    result = count;
done:
    if (closedir(directory) != 0) return -1;
    return result;
}
