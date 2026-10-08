/* static/ergopti_plus/linux/tests/hardware/run_native_artifact_capture_completion.c */
#define _GNU_SOURCE
/* Actual public native API regression; no native call or owner is substituted. */
#include "archive_publication.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fd_count(void) {
    DIR *scan = opendir("/proc/self/fd");
    if (!scan) return -1;
    int own = dirfd(scan), count = 0, error = 0;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(scan)) != NULL) {
        char *end;
        long value = strtol(entry->d_name, &end, 10);
        if (end != entry->d_name && *end == '\0' && value >= 0 && value != own) count++;
        errno = 0;
    }
    if (errno) error = 1;
    if (closedir(scan) != 0) error = 1;
    return error ? -1 : count;
}

/* Known pre-namespace failure owns only exact acquired descriptors. On an old
 * producer failure, its existing native retire/dispose still runs independently
 * before returning the original regression failure; no guessed FD is closed. */
static int refusal(const char *selection, double deadline, int expected_errno) {
    struct ergopti_archive_publication *owner = NULL;
    int before = fd_count(), failed = before < 0;
    int status = ergopti_archive_publication_create_directory(selection, deadline, &owner);
    int original_errno = errno;
    if (status != -1 || original_errno != expected_errno || !owner) failed = 1;
    int acquired = fd_count();
    if (acquired <= before) failed = 1; /* independently observe actual partial acquisition */
    if (owner) {
        if (ergopti_archive_publication_cleanup(owner) != 0) failed = 1;
        /* Always attempt exact original owner retirement, even after old failure. */
        if (ergopti_archive_publication_retire(owner) != 0) failed = 1;
        if (ergopti_archive_publication_descriptors_closed(owner) != 1 ||
            ergopti_archive_publication_named_remaining(owner) != 0) failed = 1;
        if (ergopti_archive_publication_descriptors_closed(owner) == 1 &&
            ergopti_archive_publication_named_remaining(owner) == 0) {
            if (ergopti_archive_publication_dispose_unpublished(owner) != 0) failed = 1;
            else owner = NULL;
        }
    }
    if (owner || fd_count() != before) failed = 1;
    return failed ? -1 : 0;
}

/* Invalid literal component is a separate pre-acquisition NULL refusal. */
static int preacquisition(const char *selection, double deadline) {
    struct ergopti_archive_publication *owner = NULL;
    struct stat absent;
    if (stat(selection, &absent) != -1 || errno != ENOENT) return -1;
    int before = fd_count();
    int status = ergopti_archive_publication_create_directory(selection, deadline, &owner);
    int original_errno = errno, failed = before < 0 || status != -1 || original_errno != EINVAL || owner != NULL;
    if (owner) {
        /* Unexpected acquired authority is still retired through the real owner. */
        if (ergopti_archive_publication_retire(owner) != 0) failed = 1;
        if (ergopti_archive_publication_descriptors_closed(owner) == 1 &&
            ergopti_archive_publication_named_remaining(owner) == 0) {
            if (ergopti_archive_publication_dispose_unpublished(owner) != 0) failed = 1;
            else owner = NULL;
        }
    }
    return !failed && !owner && fd_count() == before ? 0 : -1;
}

static int noise(const char *selection) {
    struct ergopti_archive_publication *owner = NULL;
    int original = -1, sentinel = -1, failed = 0, fixture_name = 0, captured_identity = 0;
    struct stat captured, named;
    original = open(selection, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (original < 0) return -1;
    int before = fd_count();
    if (before < 0 || ergopti_archive_publication_reserve(original, &owner) != 0 || !owner) failed = 1;
    if (!failed) {
        sentinel = openat(original, "fixture-owned-noise", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (sentinel < 0) failed = 1;
        else {
            fixture_name = 1;
            if (fstat(sentinel, &captured) != 0) failed = 1;
            else captured_identity = 1;
            int exact = sentinel; sentinel = -1;
            if (close(exact) != 0) failed = 1;
        }
    }
    if (!failed && (ergopti_archive_publication_cleanup(owner) != -1 ||
        ergopti_archive_publication_descriptors_closed(owner) != 0)) failed = 1;
    /* Remove only the independently created fixture entry after actual identity;
     * the native owner never bypasses its completed namespace census. */
    if (fixture_name) {
        if (!captured_identity || fstatat(original, "fixture-owned-noise", &named, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISREG(named.st_mode) || named.st_dev != captured.st_dev || named.st_ino != captured.st_ino) failed = 1;
        else if (unlinkat(original, "fixture-owned-noise", 0) != 0) failed = 1;
        else fixture_name = 0;
    }
    if (owner && !fixture_name) {
        if (ergopti_archive_publication_cleanup(owner) != 0 ||
            ergopti_archive_publication_descriptors_closed(owner) != 1 ||
            ergopti_archive_publication_named_remaining(owner) != 0) failed = 1;
        if (ergopti_archive_publication_descriptors_closed(owner) == 1 &&
            ergopti_archive_publication_named_remaining(owner) == 0) {
            if (ergopti_archive_publication_dispose_unpublished(owner) != 0) failed = 1;
            else owner = NULL;
        }
    }
    if (sentinel >= 0) { int exact = sentinel; sentinel = -1; if (close(exact) != 0) failed = 1; }
    if (owner || fixture_name || fd_count() != before) failed = 1;
    int exact = original; original = -1;
    if (close(exact) != 0) failed = 1;
    return failed ? -1 : 0;
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') return 1;
    struct stat parent;
    if (lstat(argv[1], &parent) != 0 || !S_ISDIR(parent.st_mode) ||
        parent.st_uid != geteuid() || (parent.st_mode & 0077) != 0) return 1;
    double original_now = ergopti_archive_publication_clock_ms();
    if (original_now < 0) return 1;
    double deadline = original_now + 10000.0;
    char work[PATH_MAX], missing[PATH_MAX], invalid[PATH_MAX], ordinary[PATH_MAX];
    int written = snprintf(work, sizeof(work), "%s/capture-completion-XXXXXX", argv[1]);
    if (written < 0 || (size_t)written >= sizeof(work) || !mkdtemp(work)) return 1;
    int failed = 0, ordinary_owned = 0, ordinary_captured = 0;
    struct stat ordinary_identity, again;
    written = snprintf(invalid, sizeof(invalid), "%s/independently-absent/./child", work);
    if (written < 0 || (size_t)written >= sizeof(invalid) || preacquisition(invalid, deadline) != 0) failed = 1;
    else puts("PASS invalid literal component refuses before any native owner acquisition");
    written = snprintf(missing, sizeof(missing), "%s/independently-absent/child", work);
    if (failed || written < 0 || (size_t)written >= sizeof(missing) || refusal(missing, deadline, ENOENT) != 0) failed = 1;
    else puts("PASS missing component retains then closes exact acquired descriptors");
    if (!failed) {
        written = snprintf(ordinary, sizeof(ordinary), "%s/ordinary-file", work);
        int file = written < 0 || (size_t)written >= sizeof(ordinary) ? -1 : open(ordinary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (file < 0) failed = 1;
        else {
            ordinary_owned = 1;
            if (fstat(file, &ordinary_identity) != 0) failed = 1;
            else ordinary_captured = 1;
            int exact = file; file = -1;
            if (close(exact) != 0) failed = 1;
        }
        if (!failed && refusal(ordinary, deadline, ENOTDIR) != 0) failed = 1;
        if (!failed) puts("PASS non-directory component retains then closes exact acquired descriptors");
    }
    if (ordinary_owned) {
        if (!ordinary_captured || lstat(ordinary, &again) != 0 || !S_ISREG(again.st_mode) || again.st_dev != ordinary_identity.st_dev || again.st_ino != ordinary_identity.st_ino || unlink(ordinary) != 0) failed = 1;
        else ordinary_owned = 0;
    }
    if (!failed && noise(work) != 0) failed = 1;
    if (!failed) puts("PASS completed reserve still refuses actual foreign namespace noise");
    double final_now = ergopti_archive_publication_clock_ms();
    if (failed || ordinary_owned || final_now < 0 || final_now >= deadline) return 1; /* keep fixture inputs on failure */
    if (rmdir(work) != 0) return 1;
    final_now = ergopti_archive_publication_clock_ms();
    if (final_now < 0 || final_now >= deadline) return 1;
    puts("Native capture completion: 4 passed; 0 skipped; exact native retirement complete.");
    return 0;
}
