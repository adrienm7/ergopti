/* tools/diagnostics/root_process_prerequisite.c
 * TEST ONLY: a fixed child and one inherited-PGID retirement prerequisite.
 * This program never creates credentials, signs code or installs a service.
 */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int deadline_shape(const char *value) {
    size_t length = strlen(value);
    if (length < 1 || length > 19 || value[0] < '1' || value[0] > '9') return 0;
    for (size_t i = 1; i < length; ++i) if (value[i] < '0' || value[i] > '9') return 0;
    return 1;
}

static int digest_shape(const char *value) {
    if (strlen(value) != 64) return 0;
    for (size_t i = 0; i < 64; ++i)
        if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f'))) return 0;
    return 1;
}

#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#include <libproc.h>
#include <dirent.h>
#include <poll.h>
#include <sys/acl.h>
#include <sys/wait.h>
#include <stddef.h>
_Static_assert(sizeof(siginfo_t) == 104, "Darwin siginfo ABI size");
_Static_assert(offsetof(siginfo_t, si_pid) == 12, "Darwin siginfo PID offset");
_Static_assert(offsetof(siginfo_t, si_status) == 20, "Darwin siginfo status offset");
_Static_assert(P_PID == 1 && WEXITED == 4 && WNOHANG == 1 && WNOWAIT == 32, "Darwin waitid constants");
_Static_assert(SIGCHLD == 20, "Darwin SIGCHLD constant");

_Static_assert(_Alignof(siginfo_t) == 8, "Darwin siginfo ABI alignment");
_Static_assert(offsetof(siginfo_t, si_signo) == 0, "Darwin siginfo si_signo offset");
_Static_assert(offsetof(siginfo_t, si_errno) == 4, "Darwin siginfo si_errno offset");
_Static_assert(offsetof(siginfo_t, si_code) == 8, "Darwin siginfo si_code offset");
_Static_assert(offsetof(siginfo_t, si_pid) == 12, "Darwin siginfo si_pid offset");
_Static_assert(offsetof(siginfo_t, si_uid) == 16, "Darwin siginfo si_uid offset");
_Static_assert(offsetof(siginfo_t, si_status) == 20, "Darwin siginfo si_status offset");
_Static_assert(offsetof(siginfo_t, si_addr) == 24, "Darwin siginfo si_addr offset");
_Static_assert(offsetof(siginfo_t, si_value) == 32, "Darwin siginfo si_value offset");
_Static_assert(offsetof(siginfo_t, si_band) == 40, "Darwin siginfo si_band offset");
_Static_assert(offsetof(siginfo_t, __pad) == 48, "Darwin siginfo __pad offset");
_Static_assert(sizeof(struct stat) == 144 && _Alignof(struct stat) == 8, "Darwin stat ABI");
_Static_assert(offsetof(struct stat, st_dev) == 0, "Darwin stat st_dev offset");
_Static_assert(offsetof(struct stat, st_mode) == 4, "Darwin stat st_mode offset");
_Static_assert(offsetof(struct stat, st_nlink) == 6, "Darwin stat st_nlink offset");
_Static_assert(offsetof(struct stat, st_ino) == 8, "Darwin stat st_ino offset");
_Static_assert(offsetof(struct stat, st_uid) == 16, "Darwin stat st_uid offset");
_Static_assert(offsetof(struct stat, st_gid) == 20, "Darwin stat st_gid offset");
_Static_assert(offsetof(struct stat, st_rdev) == 24, "Darwin stat st_rdev offset");
_Static_assert(offsetof(struct stat, st_atimespec) == 32, "Darwin stat st_atimespec offset");
_Static_assert(offsetof(struct stat, st_mtimespec) == 48, "Darwin stat st_mtimespec offset");
_Static_assert(offsetof(struct stat, st_ctimespec) == 64, "Darwin stat st_ctimespec offset");
_Static_assert(offsetof(struct stat, st_birthtimespec) == 80, "Darwin stat st_birthtimespec offset");
_Static_assert(offsetof(struct stat, st_size) == 96, "Darwin stat st_size offset");
_Static_assert(offsetof(struct stat, st_blocks) == 104, "Darwin stat st_blocks offset");
_Static_assert(offsetof(struct stat, st_blksize) == 112, "Darwin stat st_blksize offset");
_Static_assert(offsetof(struct stat, st_flags) == 116, "Darwin stat st_flags offset");
_Static_assert(offsetof(struct stat, st_gen) == 120, "Darwin stat st_gen offset");
_Static_assert(offsetof(struct stat, st_lspare) == 124, "Darwin stat st_lspare offset");
_Static_assert(offsetof(struct stat, st_qspare) == 128, "Darwin stat st_qspare offset");
_Static_assert(sizeof(struct proc_bsdinfo) == 136, "Darwin proc_bsdinfo ABI");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_pgid) == 100, "Darwin PGID offset");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_pid) == 12 && offsetof(struct proc_bsdinfo, pbi_ppid) == 16, "Darwin child identity offsets");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_uid) == 20 && offsetof(struct proc_bsdinfo, pbi_status) == 4, "Darwin owner/status offsets");

static volatile sig_atomic_t cancelled = 0;
static pid_t child = -1;
static int image_fd = -1, directory_fd = -1, anchor_fd = -1;
static char leaf[96];
static struct stat held_image, held_directory;
static double deadline;

static void interrupt_handler(int number) { (void)number; cancelled = 1; }
static double clock_now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}
static int same(const struct stat *a, const struct stat *b);
static int empty_acl(int descriptor) {
    struct stat before, queried, after;
    if (fstat(descriptor, &before)) return 0;
    filesec_t security = filesec_init();
    if (!security) return 0;
    acl_t acl = NULL;
    int accepted = 0;
    if (fstatx_np(descriptor, &queried, security) || !same(&before, &queried)) goto done;
    errno = 0;
    int result = filesec_get_property(security, FILESEC_ACL, &acl);
    if (result == -1 && errno == ENOENT && !acl) {
        accepted = 1;
    } else if (result == 0 && acl && acl != (acl_t)1 && acl_valid(acl) == 0) {
        acl_entry_t entry = NULL;
        errno = 0;
        result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
        accepted = result == -1 && errno == EINVAL && !entry;
    }
    if (fstat(descriptor, &after) || !same(&before, &after)) accepted = 0;
done:
    if (acl && acl_free(acl)) accepted = 0;
    filesec_free(security);
    return accepted;
}
static int same(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_uid == b->st_uid
        && a->st_gid == b->st_gid && a->st_mode == b->st_mode && a->st_nlink == b->st_nlink
        && a->st_size == b->st_size && a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec
        && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec
        && a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec
        && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
static int image_current(void) {
    struct stat named, held, directory;
    return image_fd >= 0 && directory_fd >= 0
        && fstat(image_fd, &held) == 0 && fstatat(directory_fd, "probe", &named, AT_SYMLINK_NOFOLLOW) == 0
        && fstat(directory_fd, &directory) == 0 && same(&held, &held_image) && same(&named, &held_image)
        && fstatat(anchor_fd, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0 && same(&named, &held_directory)
        && same(&directory, &held_directory) && empty_acl(image_fd) && empty_acl(directory_fd);
}
static int open_image(const char *expected) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), path, sizeof(path)) <= 0) return 0;
    const char *prefix = "/private/var/tmp/ergopti-root-process-";
    size_t start = strlen(prefix);
    if (strncmp(path, prefix, start) || strlen(path) != start + 32 + 6) return 0;
    for (size_t i = start; i < start + 32; ++i) if (!((path[i] >= '0' && path[i] <= '9') || (path[i] >= 'a' && path[i] <= 'f'))) return 0;
    if (strcmp(path + start + 32, "/probe")) return 0;
    path[start + 32] = '\0';
    struct stat parent;
    int anchor = open("/private/var/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (anchor < 0 || fstat(anchor, &parent) || parent.st_uid != 0
        || (parent.st_mode & 07777) != 01777 || !empty_acl(anchor)) {
        if (anchor >= 0) close(anchor);
        return 0;
    }
    snprintf(leaf, sizeof(leaf), "%s", path + strlen("/private/var/tmp/"));
    directory_fd = openat(anchor, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    anchor_fd = anchor;
    if (directory_fd < 0 || fstat(directory_fd, &held_directory)
        || held_directory.st_uid != 0 || (held_directory.st_mode & 07777) != 0700 || !empty_acl(directory_fd)) return 0;
    image_fd = openat(directory_fd, "probe", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (image_fd < 0 || fstat(image_fd, &held_image) || !S_ISREG(held_image.st_mode)
        || held_image.st_uid != 0 || (held_image.st_mode & 07777) != 0500 || held_image.st_nlink != 1
        || held_image.st_size <= 0 || held_image.st_size > 4194304 || !empty_acl(image_fd)) return 0;
    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1) return 0;
    unsigned char buffer[65536], bytes[CC_SHA256_DIGEST_LENGTH];
    off_t at = 0;
    while (at < held_image.st_size) {
        ssize_t n = pread(image_fd, buffer, sizeof(buffer), at);
        if (n <= 0 || CC_SHA256_Update(&context, buffer, (CC_LONG)n) != 1) return 0;
        at += n;
    }
    if (at != held_image.st_size || CC_SHA256_Final(bytes, &context) != 1) return 0;
    char rendered[65];
    for (size_t i = 0; i < sizeof(bytes); ++i) snprintf(rendered + 2 * i, 3, "%02x", bytes[i]);
    return !strcmp(rendered, expected) && image_current();
}
static int observation(siginfo_t *out) {
    memset(out, 0, sizeof(*out));
    if (waitid(P_PID, (id_t)child, out, WEXITED | WNOHANG | WNOWAIT)) return -1;
    if (!out->si_pid) return 0;
    if (out->si_pid != child || out->si_signo != SIGCHLD || out->si_uid != 0 || (out->si_code != CLD_EXITED && out->si_code != CLD_KILLED && out->si_code != CLD_DUMPED)) return -1;
    siginfo_t again;
    memset(&again, 0, sizeof(again));
    if (waitid(P_PID, (id_t)child, &again, WEXITED | WNOHANG | WNOWAIT)
        || again.si_pid != out->si_pid || again.si_code != out->si_code || again.si_status != out->si_status
        || again.si_signo != out->si_signo || again.si_uid != out->si_uid) return -1;
    return 1;
}
static int no_live_group(void) {
    if (getpgid(child) != child) {
        struct proc_bsdinfo direct;
        int received = proc_pidinfo(child, PROC_PIDTBSDINFO, 1, &direct, sizeof(direct));
        return received == sizeof(direct) && direct.pbi_pid == (uint32_t)child
            && direct.pbi_ppid == (uint32_t)getpid() && direct.pbi_status == 5
            && direct.pbi_uid == 0 && direct.pbi_pgid != (uint32_t)child;
    }

    int required = proc_listpids(PROC_PGRP_ONLY, (uint32_t)child, NULL, 0);
    if (required <= 0 || required > 65536) return 0;
    int storage[16448];
    int written = proc_listpids(PROC_PGRP_ONLY, (uint32_t)child, storage, sizeof(storage));
    if (written <= 0 || written >= (int)sizeof(storage) || written % (int)sizeof(int)) return 0;
    int saw = 0;
    for (int i = 0; i < written / (int)sizeof(int); ++i) {
        if (storage[i] <= 0) continue;
        struct proc_bsdinfo info;
        errno = 0;
        int received = proc_pidinfo(storage[i], PROC_PIDTBSDINFO, 1, &info, sizeof(info));
        if (!received && errno == ESRCH) continue;
        if (received != sizeof(info) || info.pbi_pid != (uint32_t)storage[i]) return 0;
        if (info.pbi_pgid != (uint32_t)child) continue;
        if (info.pbi_pid == (uint32_t)child) {
            if (info.pbi_ppid != (uint32_t)getpid() || info.pbi_status != 5 || info.pbi_uid != 0) return 0;
            saw = 1;
        }
        if (info.pbi_status != 5) return 0;
    }
    return saw;
}
static int settle(void) {
    if (child < 0) return 1;
    double now = clock_now();
    if (!(now >= 0) || now >= deadline) return 0;
    siginfo_t info;
    int seen = observation(&info);
    if (seen < 0 || !image_current()) return 0;
    /* A waitable direct-child PID remains reserved even before its PGID exists. */
    if (!(seen == 1 && no_live_group())) {
        pid_t target = getpgid(child) == child ? -child : child;
        if (kill(target, SIGTERM) && errno != ESRCH) return 0;
        double grace = now + 0.05;
        for (;;) {
            seen = observation(&info);
            if (seen < 0) return 0;
            if (seen == 1 && no_live_group()) break;
            now = clock_now();
            if (!(now >= 0) || now >= deadline) return 0;
            if (now >= grace) {
                if (!image_current()) return 0;
                target = getpgid(child) == child ? -child : child;
                if (kill(target, SIGKILL) && errno != ESRCH) return 0;
                break;
            }
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
        }
    }
    for (;;) {
        now = clock_now();
        if (!(now >= 0) || now >= deadline) return 0;
        seen = observation(&info);
        if (seen < 0) return 0;
        if (seen == 1 && no_live_group()) {
            int status;
            if (waitpid(child, &status, 0) != child) return 0;
            child = -1;
            return 1;
        }
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
}
static int read_token(char *token, size_t capacity) {
    size_t length = 0;
    for (;;) {
        double now = clock_now();
        if (cancelled || !(now >= 0) || now >= deadline - 3) return -1;
        int flags = fcntl(STDIN_FILENO, F_GETFL);
        if (flags < 0 || !(flags & O_NONBLOCK)) return -1;
        struct pollfd input = {STDIN_FILENO, POLLIN | POLLHUP, 0};
        int result = poll(&input, 1, 20);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (input.revents & (POLLNVAL | POLLERR))) return -1;
        if (!result) continue;
        now = clock_now();
        if (cancelled || !(now >= 0) || now >= deadline - 3) return -1;
        flags = fcntl(STDIN_FILENO, F_GETFL);
        if (flags < 0 || !(flags & O_NONBLOCK)) return -1;
        char value;
        ssize_t n = read(STDIN_FILENO, &value, 1);
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return -1;
        }
        if (length + 1 >= capacity) return -1;
        token[length++] = value;
        if (value == '\n') { token[length] = '\0'; return 1; }
    }
}
/* Irrecoverable child debt keeps its actual parent and PID reservation alive.
 * Operations are permanently revoked. This is not bounded production closure.
 * The outer SDK/Guardian bridge remains HOLD until it can retain this owner. */
static void retain_owner(void) {
    cancelled = 1;
    for (;;) {
        if (child >= 0) {
            siginfo_t info;
            if (observation(&info) == 1) (void)no_live_group();
        }
        struct timespec pause = {1, 0};
        nanosleep(&pause, NULL);
    }
}
static int cleanup_image(void) {
    if (!image_current() || child >= 0) return 0;
    /* This exact root-created scope contains only the admitted executable. */
    int copy = dup(directory_fd);
    if (copy < 0) return 0;
    DIR *directory = fdopendir(copy);
    if (!directory) { close(copy); return 0; }
    unsigned count = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (strcmp(entry->d_name, "probe") && strcmp(entry->d_name, "source.c")) { closedir(directory); return 0; }
        ++count;
    }
    if (closedir(directory) || count != 2 || !image_current()) return 0;
    if (unlinkat(directory_fd, "probe", 0)) return 0;
    int fd = image_fd; image_fd = -1;
    if (close(fd)) return 0;
    struct stat named;
    if (fstatat(anchor_fd, leaf, &named, AT_SYMLINK_NOFOLLOW) || named.st_dev != held_directory.st_dev
        || named.st_ino != held_directory.st_ino || named.st_uid != 0 || (named.st_mode & 07777) != 0700) return 0;
    fd = directory_fd; directory_fd = -1;
    if (close(fd)) return 0;
    fd = anchor_fd; anchor_fd = -1;
    if (close(fd)) return 0;
    return 1;
}
static int native_probe(const char *digest, const char *expiry) {
    double now = clock_now();
    errno = 0;
    unsigned long long bound = strtoull(expiry, NULL, 10);
    deadline = (double)bound / 1000000000.0;
    if (errno || now < 0 || deadline <= now || deadline > now + 25) return 69;
    if (getuid() != 0 || geteuid() != 0 || !open_image(digest)) return 69;
    struct stat input;
    if (fstat(STDIN_FILENO, &input) || !S_ISFIFO(input.st_mode)) return 69;
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = interrupt_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return 69;
    struct sigaction broken;
    memset(&broken, 0, sizeof(broken)); broken.sa_handler = SIG_IGN;
    sigemptyset(&broken.sa_mask);
    if (sigaction(SIGPIPE, &broken, NULL)) return 69;
    printf("V1 HELD %ld\n", (long)getpid()); fflush(stdout);
    char token[8];
    if (read_token(token, sizeof(token)) != 1 || strcmp(token, "GO\n")) return 69;
    if (!image_current()) return 69;
    int ready[2];
    if (pipe(ready)) return 69;
    child = fork();
    if (child == 0) {
        close(ready[0]);
        if (setpgid(0, 0) || signal(SIGTERM, SIG_IGN) == SIG_ERR) _exit(70);
        close(STDIN_FILENO);
        char started = 'R';
        if (write(ready[1], &started, 1) != 1 || close(ready[1])) _exit(70);
        for (;;) pause();
    }
    if (child < 0) { close(ready[0]); close(ready[1]); return 69; }
    int descriptor = ready[1]; ready[1] = -1;
    if (close(descriptor) || setpgid(child, child) || getpgid(child) != child) {
        if (!settle()) retain_owner();
        return 69;
    }
    char started = 0;
    struct pollfd prepared = {ready[0], POLLIN | POLLHUP, 0};
    int visible = 0;
    while (!cancelled) {
        now = clock_now();
        if (!(now >= 0) || now >= deadline - 3) break;
        visible = poll(&prepared, 1, 20);
        if (visible < 0 && errno == EINTR) continue;
        if (visible != 0) break;
    }
    if (visible <= 0 || read(ready[0], &started, 1) != 1 || started != 'R' || close(ready[0]) || getpgid(child) != child) {
        if (!settle()) retain_owner();
        return 69;
    }
    if (printf("V1 CHILD %ld\n", (long)child) < 0 || fflush(stdout)) cancelled = 1;
    int eof = read_token(token, sizeof(token)) == 0;
    if (!settle()) retain_owner();
    puts("V1 CHILD_RETIRED"); fflush(stdout);
    if (!eof || !cleanup_image()) return 69;
    /* Only the root bootstrap parent can retire its protected source/directory. */
    return 0;
}
#endif

int main(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "--probe") || !digest_shape(argv[2]) || !deadline_shape(argv[3])) return 64;
#ifdef __APPLE__
    return native_probe(argv[2], argv[3]);
#else
    fputs("UNAVAILABLE: Darwin root process prerequisite\n", stderr);
    return 69;
#endif
}
