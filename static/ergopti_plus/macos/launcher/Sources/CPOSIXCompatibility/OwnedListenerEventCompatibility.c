#include "OwnedListenerEventCompatibility.h"
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <time.h>

// Separate original guardian resource ledger. No endpoint is inherited by the
// daemon. Namespace capture and every close ambiguity remain retained debt.
struct ergopti_owned_listener_event {
 int parent, directory, listener, accepted, close_error;
 bool parent_closed, directory_closed, listener_closed, accepted_closed;
 bool directory_possible, directory_captured, socket_possible, socket_captured;
 bool socket_removed, directory_removed, accepted_once, consumed;
 struct stat parent_identity, directory_identity, socket_identity;
 char directory_path[96], path[104], bytes[64];
 size_t used;
};
static int event_error(void) { return errno == 0 ? EIO : errno; }
static bool same_vnode(const struct stat *a, const struct stat *b) {
 return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
static int close_once(int *fd, bool *spent, int *debt) {
 if (*spent) { return *debt; }
 *spent = true;
 if (*fd < 0) { return *debt; }
 int exact = *fd; *fd = -1;
 if (close(exact) != 0 && *debt == 0) { *debt = event_error(); }
 return *debt;
}
static int event_flags(int fd) {
 int flags = fcntl(fd, F_GETFL);
 if (flags < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0
  || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) { return event_error(); }
 return 0;
}
static bool directory_bound(ergopti_owned_listener_event *event) {
 struct stat parent, parent_name, held, named;
 return event->directory_captured && event->parent >= 0 && event->directory >= 0
  && fstat(event->parent, &parent) == 0 && lstat("/private/tmp", &parent_name) == 0
  && S_ISDIR(parent.st_mode) && same_vnode(&parent, &parent_name)
  && same_vnode(&parent, &event->parent_identity)
  && fstat(event->directory, &held) == 0 && lstat(event->directory_path, &named) == 0
  && S_ISDIR(held.st_mode) && S_ISDIR(named.st_mode) && held.st_uid == geteuid()
  && (held.st_mode & 07777) == 0700 && same_vnode(&held, &named)
  && same_vnode(&held, &event->directory_identity);
}
static bool socket_bound(ergopti_owned_listener_event *event) {
 struct stat named;
 return directory_bound(event) && event->socket_captured && !event->socket_removed
  && fstatat(event->directory, "notice", &named, AT_SYMLINK_NOFOLLOW) == 0
  && S_ISSOCK(named.st_mode) && named.st_uid == geteuid()
  && same_vnode(&named, &event->socket_identity);
}
int ergopti_owned_listener_event_create(ergopti_owned_listener_event **out) {
 if (out == NULL || *out != NULL || getsid(0) != getpid()) { return EINVAL; }
 ergopti_owned_listener_event *event = calloc(1, sizeof(*event));
 if (event == NULL) { return ENOMEM; }
 event->parent = event->directory = event->listener = event->accepted = -1;
 *out = event; // Register before any external acquisition.
 event->parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
 if (event->parent < 0 || fstat(event->parent, &event->parent_identity) != 0) { return event_error(); }
 if (!S_ISDIR(event->parent_identity.st_mode) || event->parent_identity.st_uid != 0
  || (event->parent_identity.st_mode & S_ISVTX) == 0) { return EPERM; }
 strcpy(event->directory_path, "/private/tmp/ergopti-listener-XXXXXX");
 event->directory_possible = true;
 if (mkdtemp(event->directory_path) == NULL) { return event_error(); }
 event->directory = open(event->directory_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
 if (event->directory < 0 || fstat(event->directory, &event->directory_identity) != 0) { return event_error(); }
 event->directory_captured = true;
 if (!directory_bound(event)) { return ESTALE; }
 size_t directory_length = strlen(event->directory_path);
 if (directory_length + sizeof("/notice") > sizeof(event->path)) { return ENAMETOOLONG; }
 memcpy(event->path, event->directory_path, directory_length);
 memcpy(event->path + directory_length, "/notice", sizeof("/notice"));
 event->listener = socket(AF_UNIX, SOCK_STREAM, 0);
 if (event->listener < 0) { return event_error(); }
 int error = event_flags(event->listener);
 if (error != 0) { return error; }
 struct sockaddr_un address = {0};
 address.sun_family = AF_UNIX;
 size_t length = strlen(event->path);
 if (length >= sizeof(address.sun_path)) { return ENAMETOOLONG; }
 memcpy(address.sun_path, event->path, length + 1);
 address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + length + 1);
 event->socket_possible = true;
 if (bind(event->listener, (struct sockaddr *)&address, address.sun_len) != 0) { return event_error(); }
 if (fstatat(event->directory, "notice", &event->socket_identity, AT_SYMLINK_NOFOLLOW) != 0) { return event_error(); }
 event->socket_captured = true;
 if (!socket_bound(event)) { return ESTALE; }
 if (listen(event->listener, 1) != 0) { return event_error(); }
 return 0;
}
const char *ergopti_owned_listener_event_path(ergopti_owned_listener_event *event) {
 return event != NULL && event->close_error == 0 && !event->listener_closed
  && socket_bound(event) ? event->path : NULL;
}
int ergopti_owned_listener_event_descriptor(ergopti_owned_listener_event *event) {
 if (event == NULL || event->close_error != 0 || event->consumed) { return -1; }
 return event->accepted_once ? event->accepted : event->listener;
}
static int event_remaining(const struct timespec *start, uint32_t budget, uint32_t *remaining) {
 struct timespec now;
 if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { return event_error(); }
 int64_t elapsed = ((int64_t)now.tv_sec - start->tv_sec) * 1000000000LL + now.tv_nsec - start->tv_nsec;
 if (elapsed < 0 || elapsed >= (int64_t)budget * 1000000LL) { return ETIMEDOUT; }
 uint64_t spent = ((uint64_t)elapsed + 999999) / 1000000;
 if (spent >= budget) { return ETIMEDOUT; }
 *remaining = budget - (uint32_t)spent;
 return 0;
}
static int peer_bound(ergopti_owned_listener_event *event, ergopti_owned_program *owner,
 const char *executable, int alias, uint64_t device, uint64_t inode, uint32_t remaining) {
 if (!socket_bound(event) || event->accepted < 0) { return ESTALE; }
 uid_t uid = (uid_t)-1; gid_t gid = (gid_t)-1; pid_t pid = -1;
 socklen_t size = sizeof(pid);
 if (getpeereid(event->accepted, &uid, &gid) != 0
  || getsockopt(event->accepted, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0) { return event_error(); }
 // LOCAL_PEERPID is the peer socket's most recent accessor, not an immutable
 // connect-time PID. Sole writer scope additionally depends on the pinned
 // late Go connection's CLOEXEC/ForkLock and admitted runtime source.
 if (uid != geteuid() || gid != getegid() || size != sizeof(pid)) { return EPERM; }
 ergopti_listener_identity actual = {0};
 int error = ergopti_owned_active_image_validate(owner, executable, alias, device, inode, remaining, &actual);
 if (error != 0) { return error; }
 if (pid != actual.pid || actual.uid != uid) { return ESTALE; }
 size = sizeof(pid); pid = -1;
 if (getsockopt(event->accepted, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0) { return event_error(); }
 return size == sizeof(pid) && pid == actual.pid ? 0 : ESTALE;
}
int ergopti_owned_listener_event_receive(ergopti_owned_listener_event *event,
 ergopti_owned_program *owner, const char *executable, int alias,
 uint64_t device, uint64_t inode, uint32_t remaining, const char *nonce) {
 if (event == NULL || owner == NULL || nonce == NULL || strlen(nonce) != 32
  || remaining == 0 || event->consumed || event->close_error != 0) { return -EINVAL; }
 for (size_t i = 0; i < 32; i++) {
  if (!((nonce[i] >= '0' && nonce[i] <= '9') || (nonce[i] >= 'a' && nonce[i] <= 'f'))) { return -EINVAL; }
 }
 struct timespec started;
 if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) { return -event_error(); }
 uint32_t current = 0;
 if (!socket_bound(event)) { return -ESTALE; }
 if (!event->accepted_once) {
  event->accepted = accept(event->listener, NULL, NULL);
  if (event->accepted < 0) {
   return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -event_error();
  }
  event->accepted_once = true; // Record exact accepted FD before any callback.
  int error = event_flags(event->accepted);
  if (error != 0) { return -error; }
 }
 int error = event_remaining(&started, remaining, &current);
 if (error != 0) { return -error; }
 error = peer_bound(event, owner, executable, alias, device, inode, current);
 if (error != 0) { return -error; }
 char bytes[64]; ssize_t count = read(event->accepted, bytes, sizeof(bytes));
 if (count < 0) {
  return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -event_error();
 }
 if (count > 0) {
  if ((size_t)count > sizeof(event->bytes) - event->used) { return -EOVERFLOW; }
  memcpy(event->bytes + event->used, bytes, (size_t)count); event->used += (size_t)count;
  return 0;
 }
 const char prefix[] = "V1 LISTENER_BOUND ";
 if (event->used != sizeof(prefix) - 1 + 32 + 1
  || memcmp(event->bytes, prefix, sizeof(prefix) - 1) != 0
  || memcmp(event->bytes + sizeof(prefix) - 1, nonce, 32) != 0
  || event->bytes[event->used - 1] != '\n') { return -EPROTO; }
 // The producer uses CloseWrite and stays connected until guardian close;
 // kernel peer facts therefore remain available at this physical EOF.
 if ((error = event_remaining(&started, remaining, &current)) != 0) { return -error; }
 if ((error = peer_bound(event, owner, executable, alias, device, inode, current)) != 0) { return -error; }
 if ((error = event_remaining(&started, remaining, &current)) != 0) { return -error; }
 if (close_once(&event->accepted, &event->accepted_closed, &event->close_error) != 0) { return -EIO; }
 event->consumed = true;
 return 1;
}
bool ergopti_owned_listener_event_destroy(ergopti_owned_listener_event **out) {
 if (out == NULL || *out == NULL) { return false; }
 ergopti_owned_listener_event *event = *out;
 (void)close_once(&event->accepted, &event->accepted_closed, &event->close_error);
 (void)close_once(&event->listener, &event->listener_closed, &event->close_error);
 if (event->close_error != 0) { return false; }
 if (event->socket_possible && !event->socket_removed) {
  if (!socket_bound(event) || unlinkat(event->directory, "notice", 0) != 0) { return false; }
  event->socket_removed = true;
 }
 if (event->directory_possible && !event->directory_removed) {
  if (!directory_bound(event) || rmdir(event->directory_path) != 0) { return false; }
  event->directory_removed = true;
 }
 (void)close_once(&event->directory, &event->directory_closed, &event->close_error);
 (void)close_once(&event->parent, &event->parent_closed, &event->close_error);
 if (event->close_error != 0) { return false; }
 free(event); *out = NULL;
 return true;
}

#ifdef ERGOPTI_GUARDIAN_TEST_SUPPORT
#include <signal.h>
#include <sys/wait.h>
// These executable fixture roles are unavailable in release. They exercise
// actual original C ownership/kernel Unix credentials, not a qualified daemon.
static const char fixture_nonce[] = "0123456789abcdef0123456789abcdef";
static int fixture_peer(const char *path, const char *nonce, const char *mode) {
 int fd = socket(AF_UNIX, SOCK_STREAM, 0);
 if (fd < 0) { return 71; }
 if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) { close(fd); return 71; }
 struct sockaddr_un address = {0}; size_t length = strlen(path);
 if (length >= sizeof(address.sun_path)) { close(fd); return 71; }
 address.sun_family = AF_UNIX; memcpy(address.sun_path, path, length + 1);
 address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + length + 1);
 if (connect(fd, (struct sockaddr *)&address, address.sun_len) != 0) { close(fd); return 71; }
 char frame[64]; const char prefix[] = "V1 LISTENER_BOUND ";
 size_t prefix_length = sizeof(prefix) - 1;
 memcpy(frame, prefix, prefix_length); memcpy(frame + prefix_length, nonce, 32); frame[prefix_length + 32] = '\n';
 if (write(fd, frame, prefix_length + 33) != (ssize_t)(prefix_length + 33)) { close(fd); return 71; }
 if (strcmp(mode, "missing-eof") == 0) { for (;;) { pause(); } }
 if (shutdown(fd, SHUT_WR) != 0) { close(fd); return 71; }
 char byte; ssize_t n;
 do { n = read(fd, &byte, 1); } while (n < 0 && errno == EINTR);
 int result = n == 0 ? 0 : 71;
 if (close(fd) != 0) { return 71; }
 return result;
}
int ergopti_listener_event_peer_fixture(const char *path, const char *nonce, const char *mode) {
 if (path == NULL || nonce == NULL || strlen(nonce) != 32 || mode == NULL) { return 64; }
 if (strcmp(mode, "descendant") == 0) {
  // Fork occurs before the new endpoint FD exists; no Swift/Foundation work
  // runs after fork in the descendant. Its own real PID must be rejected.
  pid_t child = fork();
  if (child < 0) { return 71; }
  if (child == 0) { _exit(fixture_peer(path, nonce, "positive")); }
  int status; pid_t waited;
  do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
  return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 71;
 }
 return fixture_peer(path, nonce, mode);
}
static bool fixture_manual_namespace(ergopti_owned_listener_event *event) {
 // Only the fixture-known externally closed socket scenario reaches this.
 // It does not clear the production ledger error or acknowledge native retire.
 if (!socket_bound(event) || unlinkat(event->directory, "notice", 0) != 0) { return false; }
 event->socket_removed = true;
 if (!directory_bound(event) || rmdir(event->directory_path) != 0) { return false; }
 event->directory_removed = true;
 if (close(event->directory) != 0) { return false; }
 event->directory = -1; event->directory_closed = true;
 if (close(event->parent) != 0) { return false; }
 event->parent = -1; event->parent_closed = true;
 return true;
}
int ergopti_listener_event_native_fixture(const char *executable, const char *mode) {
 if (executable == NULL || mode == NULL || ergopti_owned_program_create_private_session() != 0) { return 64; }
 signal(SIGPIPE, SIG_IGN);
 struct timespec started;
 if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) { return 71; }
 ergopti_owned_listener_event *event = NULL;
 if (ergopti_owned_listener_event_create(&event) != 0) { return 71; }
 const char *path = ergopti_owned_listener_event_path(event);
 if (path == NULL) { return 71; }
 if (strcmp(mode, "uncertain-close") == 0) {
  int borrowed = ergopti_owned_listener_event_descriptor(event);
  if (borrowed < 0 || close(borrowed) != 0) { return 71; }
  if (ergopti_owned_listener_event_destroy(&event) || event == NULL || event->close_error != EBADF) { return 71; }
  if (ergopti_owned_listener_event_destroy(&event) || event->close_error != EBADF) { return 71; }
  if (!fixture_manual_namespace(event)) { return 71; }
  // Actual fixture FDs/names closed; same native object still refuses closure.
  return !ergopti_owned_listener_event_destroy(&event) && event != NULL ? 0 : 71;
 }
 if (strcmp(mode, "namespace-replacement") == 0) {
  if (renameat(event->directory, "notice", event->directory, "owned-original") != 0) { return 71; }
  int foreign = openat(event->directory, "notice", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (foreign < 0) { return 71; }
  static const char sentinel[] = "INDEPENDENT_FOREIGN_NODE\n";
  struct stat before, after;
  if (write(foreign, sentinel, sizeof(sentinel) - 1) != sizeof(sentinel) - 1 || fstat(foreign, &before) != 0) { return 71; }
  if (ergopti_owned_listener_event_destroy(&event) || event == NULL
   || fstatat(event->directory, "notice", &after, AT_SYMLINK_NOFOLLOW) != 0 || !same_vnode(&before, &after)) { return 71; }
  char actual[sizeof(sentinel)];
  if (pread(foreign, actual, sizeof(actual), 0) != sizeof(sentinel) - 1
   || memcmp(actual, sentinel, sizeof(sentinel) - 1) != 0 || close(foreign) != 0) { return 71; }
  if (unlinkat(event->directory, "notice", 0) != 0
   || renameat(event->directory, "owned-original", event->directory, "notice") != 0) { return 71; }
  return ergopti_owned_listener_event_destroy(&event) && event == NULL ? 0 : 71;
 }
 int alias = open(executable, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
 struct stat image;
 if (alias < 0 || fstat(alias, &image) != 0) { return 71; }
 char *argv[] = {(char *)executable, "--owned-listener-event-peer-fixture", (char *)path, (char *)fixture_nonce, (char *)mode, NULL};
 char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", NULL};
 ergopti_owned_program *owner = NULL;
 int prepared = ergopti_owned_program_prepare(executable, argv, env, &owner);
 bool accepted = false, refused = false, cancelled = false, cancelled_after_bytes = false;
 if (owner == NULL) { return 71; }
 if (prepared != 0 || strcmp(mode, "cancel-acquisition") == 0) {
  cancelled = true; ergopti_owned_program_cancel(owner);
 } else {
  ergopti_owned_program_receipt activated = ergopti_owned_program_activate(owner);
  if (!activated.active || activated.cancelled || activated.error_code != 0) { cancelled = true; }
 }
 for (;;) {
  uint32_t remaining;
  if (!cancelled && event_remaining(&started, 10000, &remaining) != 0) { cancelled = true; }
  if (!cancelled && !accepted) {
   int received = ergopti_owned_listener_event_receive(event, owner, executable, alias,
    (uint64_t)(uint32_t)image.st_dev, image.st_ino, remaining, fixture_nonce);
   if (received < 0) { refused = true; cancelled = true; }
   if (received == 1) { accepted = true; }
   if (strcmp(mode, "missing-eof") == 0 && event->used == 51 && received == 0) {
    cancelled_after_bytes = true; cancelled = true;
   }
  }
  if (cancelled) { ergopti_owned_program_cancel(owner); }
  ergopti_owned_program_receipt receipt = ergopti_owned_program_poll(owner);
  if (receipt.retired && receipt.leader_exited && receipt.status_valid && receipt.error_code == 0) {
   bool expected = (strcmp(mode, "positive") == 0 && accepted && receipt.exit_status == 0)
    || (strcmp(mode, "descendant") == 0 && refused && !accepted)
    || (strcmp(mode, "missing-eof") == 0 && cancelled_after_bytes && !accepted)
    || (strcmp(mode, "cancel-acquisition") == 0 && !accepted && event->accepted < 0);
   if (!ergopti_owned_listener_event_destroy(&event) || !ergopti_owned_program_destroy(&owner) || close(alias) != 0) { return 71; }
   return expected ? 0 : 71;
  }
  if (receipt.error_code != 0) { cancelled = true; }
  // Fixture observation only, inside the same original 10000ms admission;
  // physical cleanup never becomes successful because this clock expires.
  usleep(1000);
 }
}
#endif
