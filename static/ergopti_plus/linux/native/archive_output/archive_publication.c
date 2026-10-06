#define _GNU_SOURCE
#include "archive_publication.h"

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/random.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

enum publication_state { ACQUIRING, RESERVED, STAGING, STAGED, COMMITTED, REFUSED, RETIRING };
struct ergopti_archive_publication {
    int directory, next_directory, parent_directory, pending_fd, output_anchor, archive, proc_directory;
    int uncertain_close, named_remaining;
    int directory_name_remaining, output_attempted, allocation_busy;
    int scan_fd;
    DIR *scan_stream;
    enum publication_state state;
    struct stat directory_identity, parent_identity, output_identity, archive_identity;
    int64_t archive_length;
    char directory_name[64], archive_name[256];
    char display_directory[PATH_MAX];
};

_Static_assert(PATH_MAX == 4096, "unexpected Linux pathname limit");
unsigned int ergopti_archive_publication_abi_version(void) { return 1; }

/* Native integral equality: never convert dev_t/ino_t through Lua doubles. */
static int same_inode(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static int private_directory(const struct stat *info) {
    return S_ISDIR(info->st_mode) && info->st_uid == geteuid()
        && (info->st_mode & 0077) == 0;
}

static int before_deadline(double deadline) {
    if (!isfinite(deadline) || deadline <= 0) { errno = EINVAL; return 0; }
    double now = ergopti_archive_publication_clock_ms();
    if (now < 0) return 0;
    if (now >= deadline) {
        errno = ETIMEDOUT; return 0;
    }
    return 1;
}

double ergopti_archive_publication_clock_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    if (now.tv_sec < 0 || now.tv_nsec < 0 || now.tv_nsec >= 1000000000L
        || (uint64_t)now.tv_sec > (UINT64_MAX - (uint64_t)now.tv_nsec) / UINT64_C(1000000000)) {
        errno = EOVERFLOW; return -1;
    }
    uint64_t ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    return (double)ns / 1000000.0;
}

static int valid_basename(const char *name) {
    if (!name || !*name || strlen(name) > 255 || !strcmp(name, ".")
        || !strcmp(name, "..") || strchr(name, '/')) return 0;
    /* C ingress is private; public Lua strings must reject embedded NUL before
     * crossing this port, since a C string cannot observe a trailing suffix. */
    return 1;
}

static int close_once(int *owned) {
    if (*owned < 0) return 0;
    int exact = *owned;
    *owned = -1; /* Linux close must never be retried after an error/EINTR. */
    return close(exact);
}

static struct ergopti_archive_publication *allocate_owner(
    struct ergopti_archive_publication **result) {
    if (!result) { errno = EINVAL; return NULL; }
    *result = NULL;
    struct ergopti_archive_publication *owner = calloc(1, sizeof(*owner));
    if (!owner) return NULL;
    owner->directory = owner->next_directory = owner->parent_directory = owner->pending_fd = -1;
    owner->archive = owner->proc_directory = -1;
    owner->output_anchor = -1;
    owner->scan_fd = -1;
    owner->state = ACQUIRING;
    *result = owner; /* Return acquisition ledger BEFORE native allocation. */
    return owner;
}

static int capture_path(const char *path, double deadline,
    struct ergopti_archive_publication **result, int require_private) {
    if (!result || !path || path[0] != '/' || !path[1]
        || strnlen(path, PATH_MAX) >= PATH_MAX) { errno = EINVAL; return -1; }
    *result = NULL;
    char *copy = strdup(path + 1);
    if (!copy) return -1;
    /* Validate the complete selection before acquiring a native descriptor. */
    for (char *part = copy; part;) {
        char *end = strchr(part, '/');
        if (end) *end = '\0';
        if (!valid_basename(part)) { free(copy); errno = EINVAL; return -1; }
        if (end) { *end = '/'; part = end + 1; } else part = NULL;
    }
    struct ergopti_archive_publication *owner = allocate_owner(result);
    if (!owner) { free(copy); return -1; }
    memcpy(owner->display_directory, path, strlen(path) + 1);
    if (!before_deadline(deadline)) goto failed;
    owner->directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (owner->directory < 0) goto failed;
    for (char *part = copy; part;) {
        char *end = strchr(part, '/');
        if (end) *end = '\0';
        if (!before_deadline(deadline)) goto failed;
        owner->next_directory = openat(owner->directory, part,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (owner->next_directory < 0) goto failed;
        if (close_once(&owner->directory) != 0) {
            owner->uncertain_close = errno; goto failed;
        }
        owner->directory = owner->next_directory;
        owner->next_directory = -1;
        part = end ? end + 1 : NULL;
    }
    if (fstat(owner->directory, &owner->directory_identity) != 0) goto failed;
    if (require_private && !private_directory(&owner->directory_identity)) { errno = EPERM; goto failed; }
    if (!before_deadline(deadline)) goto failed;
    owner->state = RESERVED;
    free(copy);
    return 0;
failed:
    owner->state = REFUSED;
    int saved_errno = errno;
    free(copy);
    errno = saved_errno;
    return -1;
}

int ergopti_archive_publication_capture_directory(const char *path,
    double deadline, struct ergopti_archive_publication **result) {
    return capture_path(path, deadline, result, 1);
}

int ergopti_archive_publication_create_directory(const char *parent, double deadline,
    struct ergopti_archive_publication **result) {
    if (capture_path(parent, deadline, result, 0) != 0) return -1;
    struct ergopti_archive_publication *owner = *result;
    owner->state = ACQUIRING;
    owner->parent_directory = owner->directory;
    owner->directory = -1;
    owner->parent_identity = owner->directory_identity;
    unsigned char random[16];
    ssize_t count = getrandom(random, sizeof(random), GRND_NONBLOCK);
    if (count != (ssize_t)sizeof(random)) {
        if (count >= 0) errno = EIO;
        goto failed_create;
    }
    const char hex[] = "0123456789abcdef";
    const char prefix[] = ".ergopti-transfer-";
    memcpy(owner->directory_name, prefix, sizeof(prefix) - 1);
    for (size_t i = 0; i < sizeof(random); ++i) {
        owner->directory_name[sizeof(prefix) - 1 + 2 * i] = hex[random[i] >> 4];
        owner->directory_name[sizeof(prefix) + 2 * i] = hex[random[i] & 15];
    }
    size_t base_length = strlen(owner->display_directory);
    size_t child_length = strlen(owner->directory_name);
    if (base_length + child_length + 2 > sizeof(owner->display_directory)) {
        errno = ENAMETOOLONG; goto failed_create;
    }
    owner->display_directory[base_length] = '/';
    memcpy(owner->display_directory + base_length + 1, owner->directory_name, child_length + 1);
    if (!before_deadline(deadline)) goto failed_create;
    owner->directory_name_remaining = 2; /* mkdir can also report ambiguous IO. */
    if (mkdirat(owner->parent_directory, owner->directory_name, 0700) != 0) goto failed_create;
    owner->directory = openat(owner->parent_directory, owner->directory_name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (owner->directory < 0 || fstat(owner->directory, &owner->directory_identity) != 0) goto failed_create;
    struct stat parent_again, named;
    if (fstat(owner->parent_directory, &parent_again) != 0
        || fstatat(owner->parent_directory, owner->directory_name, &named, AT_SYMLINK_NOFOLLOW) != 0) goto failed_create;
    if (!same_inode(&parent_again, &owner->parent_identity)
        || !same_inode(&named, &owner->directory_identity)
        || !private_directory(&owner->directory_identity) || !private_directory(&named)) {
        errno = ESTALE; goto failed_create;
    }
    owner->directory_name_remaining = 1;
    if (!before_deadline(deadline)) goto failed_create;
    owner->state = RESERVED;
    return 0;
failed_create:
    owner->state = REFUSED;
    return -1;
}

int ergopti_archive_publication_allocate_output(struct ergopti_archive_publication *owner,
    double deadline, int *out_fd) {
    if (!out_fd) { errno = EINVAL; return -1; }
    *out_fd = -1;
    if (!owner || owner->state != RESERVED || owner->allocation_busy
        || owner->output_attempted) { errno = EINVAL; return -1; }
    owner->output_attempted = owner->allocation_busy = 1;
    if (!before_deadline(deadline)) goto failed_output;
    struct stat directory, output;
    if (fstat(owner->directory, &directory) != 0) goto failed_output;
    if (!same_inode(&directory, &owner->directory_identity) || !private_directory(&directory)) {
        errno = ESTALE; goto failed_output;
    }
    owner->pending_fd = openat(owner->directory, ".",
        O_TMPFILE | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (owner->pending_fd < 0 || fstat(owner->pending_fd, &output) != 0
        || fstat(owner->directory, &directory) != 0) goto failed_output;
    if (!S_ISREG(output.st_mode) || output.st_uid != geteuid()
        || (output.st_mode & 0077) != 0 || output.st_nlink != 0 || output.st_size != 0
        || !same_inode(&directory, &owner->directory_identity) || !private_directory(&directory)) {
        errno = ESTALE; goto failed_output;
    }
    /* Keep the created inode alive independently of the returned lease FD:
     * a closed/recycled numeric FD must not borrow a foreign same-size file. */
    owner->output_anchor = fcntl(owner->pending_fd, F_DUPFD_CLOEXEC, 3);
    if (owner->output_anchor < 0) goto failed_output;
    owner->output_identity = output;
    if (!before_deadline(deadline)) goto failed_output;
    *out_fd = owner->pending_fd;
    owner->pending_fd = -1; /* Ownership passes ONLY to original private lease. */
    owner->allocation_busy = 0;
    return 0;
failed_output:
    owner->allocation_busy = 0;
    owner->state = REFUSED;
    return -1;
}

int ergopti_archive_publication_allocate_reader(struct ergopti_archive_publication *owner,
    double deadline, int *out_fd) {
    if (!out_fd) { errno = EINVAL; return -1; }
    *out_fd = -1;
    if (!owner || owner->state != COMMITTED || owner->allocation_busy
        || owner->pending_fd >= 0) { errno = EINVAL; return -1; }
    owner->allocation_busy = 1;
    if (!before_deadline(deadline)) goto failed_reader;
    struct stat archive, copy, directory;
    if (fstat(owner->archive, &archive) != 0
        || fstat(owner->directory, &directory) != 0) goto failed_reader;
    if (!S_ISREG(archive.st_mode) || !same_inode(&archive, &owner->archive_identity)
        || archive.st_uid != geteuid() || (archive.st_mode & 0077) != 0
        || archive.st_size != owner->archive_length
        || !same_inode(&directory, &owner->directory_identity) || !private_directory(&directory)) {
        errno = ESTALE; goto failed_reader;
    }
    owner->pending_fd = fcntl(owner->archive, F_DUPFD_CLOEXEC, 3);
    if (owner->pending_fd < 0 || fstat(owner->pending_fd, &copy) != 0
        || fstat(owner->directory, &directory) != 0) goto failed_reader;
    if (!same_inode(&copy, &archive) || copy.st_size != owner->archive_length
        || copy.st_uid != geteuid() || (copy.st_mode & 0077) != 0
        || !same_inode(&directory, &owner->directory_identity) || !private_directory(&directory)) {
        errno = ESTALE; goto failed_reader;
    }
    if (!before_deadline(deadline)) goto failed_reader;
    *out_fd = owner->pending_fd;
    owner->pending_fd = -1; /* Captured native read owner now holds exact duplicate. */
    owner->allocation_busy = 0;
    return 0;
failed_reader:
    owner->allocation_busy = 0;
    return -1;
}

int ergopti_archive_publication_reserve(int owned_directory_fd,
    struct ergopti_archive_publication **result) {
    if (!result || owned_directory_fd < 0) { errno = EINVAL; return -1; }
    struct ergopti_archive_publication *owner = allocate_owner(result);
    if (!owner) return -1;
    /* Return the acquired owner immediately: later failures cannot lose debt. */
    *result = owner;
    owner->directory = fcntl(owned_directory_fd, F_DUPFD_CLOEXEC, 3);
    if (owner->directory < 0) { owner->state = REFUSED; return -1; }
    struct stat original;
    if (fstat(owned_directory_fd, &original) != 0
        || fstat(owner->directory, &owner->directory_identity) != 0) {
        owner->state = REFUSED; return -1;
    }
    if (!same_inode(&original, &owner->directory_identity)
        || !private_directory(&owner->directory_identity)) {
        owner->state = REFUSED; errno = EPERM; return -1;
    }
    owner->state = RESERVED;
    return 0;
}

int ergopti_archive_publication_stage(struct ergopti_archive_publication *owner,
    int sealed_fd, int64_t length, const char *name, double deadline) {
    if (!owner || owner->state != RESERVED || owner->allocation_busy || sealed_fd < 0 || length <= 0
        || !valid_basename(name)) { errno = EINVAL; return -1; }
    owner->state = STAGING; /* Reserve before any probe/allocation/syscall. */
    if (!before_deadline(deadline)) goto refused;
    struct stat original, copy, directory, proc_source, published, source_again;
    if (fstat(sealed_fd, &original) != 0) goto refused;
    if (!S_ISREG(original.st_mode) || original.st_uid != geteuid()
        || (original.st_mode & 0077) != 0 || original.st_size != length
        || original.st_nlink != 0) {
        errno = EPERM; goto refused;
    }
    if (owner->directory_name_remaining && (owner->output_anchor < 0
        || !same_inode(&original, &owner->output_identity))) {
        errno = ESTALE; goto refused;
    }
    owner->archive_identity = original;
    owner->archive_length = length;
    memcpy(owner->archive_name, name, strlen(name) + 1);
    owner->archive = fcntl(sealed_fd, F_DUPFD_CLOEXEC, 3);
    if (owner->archive < 0 || fstat(owner->archive, &copy) != 0) goto refused;
    if (!same_inode(&original, &copy) || copy.st_size != length) {
        errno = ESTALE; goto refused;
    }
    /* This fixed kernel namespace is the documented unprivileged O_TMPFILE
     * link mechanism. It never opens a displayed/named archive or caller path.
     * Retain the exact directory and use ONLY the private duplicate's number. */
    owner->proc_directory = open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (owner->proc_directory < 0) goto refused;
    struct statfs filesystem;
    if (fstatfs(owner->proc_directory, &filesystem) != 0) goto refused;
    if (filesystem.f_type != PROC_SUPER_MAGIC) { errno = EPERM; goto refused; }
    char own_fd_name[32];
    int written = snprintf(own_fd_name, sizeof(own_fd_name), "%d", owner->archive);
    if (written <= 0 || (size_t)written >= sizeof(own_fd_name)) {
        errno = EINVAL; goto refused;
    }
    if (fstat(sealed_fd, &source_again) != 0
        || fstatat(owner->proc_directory, own_fd_name, &proc_source, 0) != 0
        || fstat(owner->directory, &directory) != 0) goto refused;
    if (!same_inode(&original, &source_again) || source_again.st_size != length
        || !same_inode(&copy, &proc_source) || !S_ISREG(proc_source.st_mode)
        || proc_source.st_size != length || !private_directory(&directory)
        || !same_inode(&directory, &owner->directory_identity)) {
        errno = ESTALE; goto refused;
    }
    if (!before_deadline(deadline)) goto refused;
    /* linkat intrinsically refuses EEXIST, including symlinks. There is no
     * stat/rename/unlink retry and no AT_FDCWD destination or named fallback. */
    owner->named_remaining = 2; /* Reserve possible name debt BEFORE syscall.
     * A filesystem/server can perform link then report failure. Never infer
     * absence or release the owner merely from a negative return code. */
    if (linkat(owner->proc_directory, own_fd_name, owner->directory,
        name, AT_SYMLINK_FOLLOW) != 0) goto refused;
    owner->named_remaining = 1;
    if (fstat(sealed_fd, &source_again) != 0
        || fstatat(owner->directory, name, &published, AT_SYMLINK_NOFOLLOW) != 0
        || fstat(owner->archive, &copy) != 0
        || fstat(owner->directory, &directory) != 0) goto refused;
    if (!S_ISREG(published.st_mode) || !same_inode(&published, &copy)
        || !same_inode(&original, &copy) || !same_inode(&original, &source_again)
        || copy.st_size != length || source_again.st_size != length
        || !same_inode(&directory, &owner->directory_identity)
        || !private_directory(&directory)) {
        errno = ESTALE; goto refused;
    }
    if (!before_deadline(deadline)) goto refused;
    if (close_once(&owner->output_anchor) != 0) {
        owner->uncertain_close = errno; goto refused;
    }
    if (!before_deadline(deadline)) goto refused;
    owner->state = STAGED;
    return 0;
refused:
    owner->state = REFUSED;
    return -1;
}

int ergopti_archive_publication_commit(struct ergopti_archive_publication *owner) {
    if (!owner || owner->state != STAGED) { errno = EINVAL; return -1; }
    owner->state = COMMITTED;
    return 0;
}

int ergopti_archive_publication_copy_display_path(
    const struct ergopti_archive_publication *owner, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) { errno = EINVAL; return -1; }
    buffer[0] = '\0';
    if (!owner || owner->state != COMMITTED || !owner->display_directory[0]
        || !owner->archive_name[0]) { errno = EINVAL; return -1; }
    size_t directory_length = strlen(owner->display_directory);
    size_t name_length = strlen(owner->archive_name);
    if (directory_length + name_length + 2 > capacity) { errno = ERANGE; return -1; }
    memcpy(buffer, owner->display_directory, directory_length);
    buffer[directory_length] = '/';
    memcpy(buffer + directory_length + 1, owner->archive_name, name_length + 1);
    return 0;
}

/* The exclusively created namespace may contain only this one captured name.
 * This is not a promise of isolation from a hostile same-UID process: wrapper
 * admits its private namespace/source owner and documents that exact premise. */
static int scan_namespace(struct ergopti_archive_publication *owner, int allow_archive) {
    if (owner->scan_fd >= 0 || owner->scan_stream != NULL || owner->uncertain_close) {
        errno = EBUSY; return -1; /* Never overwrite an unacknowledged scan owner. */
    }
    /* A duplicate shares directory offsets, so each independent census needs
     * a NEW directory open-file description relative to this retained FD. */
    owner->scan_fd = openat(owner->directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (owner->scan_fd < 0) return -1;
    struct stat scan_identity;
    if (fstat(owner->scan_fd, &scan_identity) != 0) return -1;
    if (!same_inode(&scan_identity, &owner->directory_identity) || !private_directory(&scan_identity)) {
        errno = ESTALE; return -1;
    }
    owner->scan_stream = fdopendir(owner->scan_fd);
    if (!owner->scan_stream) return -1; /* Exact scan_fd remains owned. */
    int failure = 0;
    errno = 0;
    for (;;) {
        struct dirent *entry = readdir(owner->scan_stream);
        if (!entry) { failure = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (!allow_archive || strcmp(entry->d_name, owner->archive_name)) {
            failure = ENOTEMPTY; break;
        }
    }
    DIR *exact = owner->scan_stream;
    owner->scan_stream = NULL;
    owner->scan_fd = -1; /* closedir takes/closes this exact descriptor once. */
    if (closedir(exact) != 0) {
        owner->uncertain_close = errno;
        if (!failure) failure = errno;
    }
    if (failure) { errno = failure; return -1; }
    return 0;
}

int ergopti_archive_publication_cleanup(struct ergopti_archive_publication *owner) {
    if (!owner || owner->state == ACQUIRING || owner->state == STAGING
        || owner->allocation_busy || owner->uncertain_close) { errno = EBUSY; return -1; }
    owner->allocation_busy = 1;
    owner->state = RETIRING; /* No new reader/output/publication after this point. */
    if (owner->directory < 0) {
        if (owner->named_remaining || owner->directory_name_remaining) { errno = ESTALE; goto refused_cleanup; }
        owner->allocation_busy = 0;
        return ergopti_archive_publication_retire(owner);
    }
    struct stat directory, entry, inode, parent;
    if (fstat(owner->directory, &directory) != 0) goto refused_cleanup;
    if (!same_inode(&directory, &owner->directory_identity) || !private_directory(&directory)) {
        errno = ESTALE; goto refused_cleanup;
    }
    if (scan_namespace(owner, owner->named_remaining != 0) != 0) goto refused_cleanup;
    if (owner->named_remaining) {
        if (owner->archive < 0 || fstat(owner->archive, &inode) != 0) goto refused_cleanup;
        if (!same_inode(&inode, &owner->archive_identity) || inode.st_size != owner->archive_length) {
            errno = ESTALE; goto refused_cleanup;
        }
        if (fstatat(owner->directory, owner->archive_name, &entry, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT) goto refused_cleanup;
        } else {
            if (!S_ISREG(entry.st_mode) || !same_inode(&entry, &inode)) {
                errno = ESTALE; goto refused_cleanup;
            }
            /* No guessed path unlink: this exact entry belongs to the privately
             * held EXCLUSIVE namespace and same retained inode. Foreign/noisy
             * entries refuse; hostile same-UID mutation is outside that premise. */
            if (unlinkat(owner->directory, owner->archive_name, 0) != 0) goto refused_cleanup;
            if (fstatat(owner->directory, owner->archive_name, &entry, AT_SYMLINK_NOFOLLOW) == 0
                || errno != ENOENT) { owner->named_remaining = 2; errno = ESTALE; goto refused_cleanup; }
        }
        owner->named_remaining = 0;
    }
    if (scan_namespace(owner, 0) != 0) goto refused_cleanup;
    if (owner->directory_name_remaining) {
        if (owner->parent_directory < 0
            || fstat(owner->parent_directory, &parent) != 0
            || fstatat(owner->parent_directory, owner->directory_name, &entry, AT_SYMLINK_NOFOLLOW) != 0) goto refused_cleanup;
        if (!same_inode(&parent, &owner->parent_identity)
            || !same_inode(&entry, &directory) || !private_directory(&entry)) {
            errno = ESTALE; goto refused_cleanup;
        }
        if (unlinkat(owner->parent_directory, owner->directory_name, AT_REMOVEDIR) != 0) goto refused_cleanup;
        owner->directory_name_remaining = 2;
        if (fstatat(owner->parent_directory, owner->directory_name, &entry, AT_SYMLINK_NOFOLLOW) == 0
            || errno != ENOENT) { errno = ESTALE; goto refused_cleanup; }
        owner->directory_name_remaining = 0;
    }
    owner->allocation_busy = 0;
    return ergopti_archive_publication_retire(owner);
refused_cleanup:
    owner->allocation_busy = 0;
    return -1;
}

int ergopti_archive_publication_retire(struct ergopti_archive_publication *owner) {
    if (!owner) { errno = EINVAL; return -1; }
    if (owner->state == ACQUIRING || owner->state == STAGING || owner->allocation_busy) { errno = EBUSY; return -1; }
    owner->state = RETIRING;
    int failure = 0;
    /* The inode itself stays reserved through possible-name verification. */
    if (!owner->named_remaining && close_once(&owner->archive) != 0) failure = errno;
    if (close_once(&owner->proc_directory) != 0 && !failure) failure = errno;
    /* Keep the directory authority while any possible published name remains.
     * Dropping this FD would force a later cleanup owner to reopen a path. */
    if (!owner->named_remaining && !owner->directory_name_remaining
        && close_once(&owner->directory) != 0 && !failure) failure = errno;
    if (close_once(&owner->next_directory) != 0 && !failure) failure = errno;
    if (close_once(&owner->pending_fd) != 0 && !failure) failure = errno;
    if (close_once(&owner->output_anchor) != 0 && !failure) failure = errno;
    if (close_once(&owner->scan_fd) != 0 && !failure) failure = errno;
    if (!owner->directory_name_remaining && close_once(&owner->parent_directory) != 0 && !failure) failure = errno;
    if (failure) owner->uncertain_close = failure;
    if (owner->uncertain_close) { errno = owner->uncertain_close; return -1; }
    if (owner->named_remaining || owner->directory_name_remaining) { errno = EBUSY; return -1; }
    return 0;
}

int ergopti_archive_publication_descriptors_closed(
    const struct ergopti_archive_publication *owner) {
    return owner && owner->state == RETIRING && !owner->uncertain_close
        && owner->directory < 0 && owner->next_directory < 0
        && owner->archive < 0 && owner->proc_directory < 0
        && owner->parent_directory < 0 && owner->pending_fd < 0 && owner->output_anchor < 0
        && owner->scan_fd < 0 && owner->scan_stream == NULL;
}

int ergopti_archive_publication_named_remaining(
    const struct ergopti_archive_publication *owner) {
    return owner ? owner->named_remaining : 0;
}

int ergopti_archive_publication_dispose_unpublished(
    struct ergopti_archive_publication *owner) {
    if (!ergopti_archive_publication_descriptors_closed(owner)
        || owner->named_remaining) { errno = EBUSY; return -1; }
    free(owner);
    return 0;
}
