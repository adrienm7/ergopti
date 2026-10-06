/* tools/diagnostics/installed-vhd-acl-ancestry.c
 * Sample two exact held Darwin directory descriptors; never mutate ancestry.
 */
#include <sys/acl.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

struct acl_observation {
  bool attempted, acquired, entry;
  int acquisition_errno, valid, valid_errno, first, first_errno, freed, free_errno;
  bool validated, iterated;
};

struct node {
  const char *role;
  int fd;
  bool identified, current, closed;
  struct stat identity;
  const char *pin_error;
  int error_code, close_result, close_errno;
  bool has_error_code;
  struct acl_observation acl;
};

static bool same(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
         a->st_mode == b->st_mode && a->st_uid == b->st_uid &&
         a->st_gid == b->st_gid;
}

static void failure(struct node *n, const char *label, int error) {
  n->pin_error = label;
  n->has_error_code = true;
  n->error_code = error;
}

static void identify(struct node *n, const struct stat *named) {
  errno = 0;
  const int outcome = fstat(n->fd, &n->identity);
  const int error = errno;
  if (outcome != 0) { failure(n, "held_stat", error); return; }
  n->identified = true;
  if (!S_ISDIR(n->identity.st_mode) || !same(named, &n->identity)) {
    n->pin_error = "identity";
    return;
  }
  n->current = true;
}

static void acl_sample(struct node *n) {
  if (!n->current) return;
  n->acl.attempted = true;
  errno = 0;
  acl_t value = acl_get_fd_np(n->fd, ACL_TYPE_EXTENDED);
  n->acl.acquisition_errno = errno;
  if (value == NULL) return;
  n->acl.acquired = true;
  errno = 0;
  n->acl.valid = acl_valid(value);
  n->acl.valid_errno = errno;
  n->acl.validated = true;
  if (n->acl.valid == 0) {
    acl_entry_t borrowed = NULL;
    errno = 0;
    n->acl.first = acl_get_entry(value, ACL_FIRST_ENTRY, &borrowed);
    n->acl.first_errno = errno;
    n->acl.entry = borrowed != NULL;
    n->acl.iterated = true;
  }
  /* Every acquired ACL is released even when validation/iteration failed. */
  errno = 0;
  n->acl.freed = acl_free(value);
  n->acl.free_errno = errno;
}

static void verify(struct node *n, int parent) {
  if (!n->current) return;
  struct stat held, named;
  errno = 0;
  int result = fstat(n->fd, &held);
  int error = errno;
  if (result != 0) { failure(n, "held_stat", error); n->current = false; return; }
  errno = 0;
  result = parent < 0 ? lstat("/", &named) :
      fstatat(parent, "Library", &named, AT_SYMLINK_NOFOLLOW);
  error = errno;
  if (result != 0) { failure(n, "named_stat", error); n->current = false; return; }
  n->current = S_ISDIR(named.st_mode) && same(&n->identity, &held) &&
      same(&n->identity, &named);
  if (!n->current) n->pin_error = "identity";
}

static void close_owned(struct node *n) {
  if (n->fd < 0) return;
  errno = 0;
  n->close_result = close(n->fd);
  n->close_errno = errno;
  n->closed = true;
  /* Ambiguous close failures are reported once, never retried against a reused FD. */
}

static void integer_or_null(bool observed, int value) {
  if (observed) printf("%d", value); else printf("null");
}

static void print_node(const struct node *n) {
  printf("{\"role\":\"%s\",\"opened\":%s,\"identity\":", n->role,
         n->fd >= 0 ? "true" : "false");
  if (n->identified) {
    printf("{\"device\":%ju,\"inode\":%ju,\"mode\":%ju,\"uid\":%ju,\"gid\":%ju}",
           (uintmax_t)n->identity.st_dev, (uintmax_t)n->identity.st_ino,
           (uintmax_t)n->identity.st_mode, (uintmax_t)n->identity.st_uid,
           (uintmax_t)n->identity.st_gid);
  } else printf("null");
  printf(",\"current\":%s,\"pin_error\":", n->current ? "true" : "false");
  if (n->pin_error != NULL) printf("\"%s\"", n->pin_error); else printf("null");
  printf(",\"error_code\":"); integer_or_null(n->has_error_code, n->error_code);
  printf(",\"acl\":{\"acquisition_attempted\":%s,\"acquired\":%s,\"acquire_errno\":",
         n->acl.attempted ? "true" : "false", n->acl.acquired ? "true" : "false");
  integer_or_null(n->acl.attempted, n->acl.acquisition_errno);
  printf(",\"valid_result\":"); integer_or_null(n->acl.validated, n->acl.valid);
  printf(",\"valid_errno\":"); integer_or_null(n->acl.validated, n->acl.valid_errno);
  printf(",\"first_result\":"); integer_or_null(n->acl.iterated, n->acl.first);
  printf(",\"first_errno\":"); integer_or_null(n->acl.iterated, n->acl.first_errno);
  printf(",\"entry_present\":");
  if (n->acl.iterated) printf("%s", n->acl.entry ? "true" : "false"); else printf("null");
  printf(",\"free_result\":"); integer_or_null(n->acl.acquired, n->acl.freed);
  printf(",\"free_errno\":"); integer_or_null(n->acl.acquired, n->acl.free_errno);
  printf("},\"close_result\":"); integer_or_null(n->closed, n->close_result);
  printf(",\"close_errno\":"); integer_or_null(n->closed, n->close_errno);
  printf("}");
}

int main(int argc, char **argv) {
  (void)argv;
  if (argc != 1) return 64;
  struct node root = {.role = "root", .fd = -1};
  struct node library = {.role = "library", .fd = -1};
  struct stat named;
  errno = 0;
  int result = lstat("/", &named);
  int error = errno;
  if (result != 0) failure(&root, "named_stat", error);
  else if (!S_ISDIR(named.st_mode)) root.pin_error = "wrong_type";
  else {
    errno = 0;
    root.fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    error = errno;
    if (root.fd < 0) failure(&root, "open", error); else identify(&root, &named);
  }
  if (root.current) {
    errno = 0;
    result = fstatat(root.fd, "Library", &named, AT_SYMLINK_NOFOLLOW);
    error = errno;
    if (result != 0) failure(&library, "named_stat", error);
    else if (!S_ISDIR(named.st_mode)) library.pin_error = "wrong_type";
    else {
      errno = 0;
      library.fd = openat(root.fd, "Library", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      error = errno;
      if (library.fd < 0) failure(&library, "open", error); else identify(&library, &named);
    }
  } else library.pin_error = "parent_unavailable";
  acl_sample(&root);
  acl_sample(&library);
  verify(&library, root.fd);
  verify(&root, -1);
  close_owned(&library);
  close_owned(&root);
  printf("{\"schema\":1,\"pid\":%jd,\"nodes\":[", (intmax_t)getpid());
  print_node(&root); printf(","); print_node(&library); printf("]}\n");
  return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 74;
}
