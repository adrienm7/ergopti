// tools/test/fixtures/owned_suspended_image_portable.c
// Literal receiving vectors; native observations are explicit doubles, not SDK proof.

#define _POSIX_C_SOURCE 200809L
#include "OwnedSuspendedImageCompatibility.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int mode;
static int observations;
static int mappings;
static int writable;
static ergopti_owned_program_observation controlled = {
 .process_id = 123, .process_group_id = 123, .start_seconds = 101, .start_microseconds = 202
};
ergopti_owned_program_observation ergopti_owned_program_prepared_identity(ergopti_owned_program *owner) {
 assert(owner != NULL);
 observations++;
 ergopti_owned_program_observation result = controlled;
 if (mode == 1) { result.error_code = EPERM; }
 if (mode == 2 && observations == 2) { result.start_seconds++; }
 if (mode == 3) { result.nonlive = true; }
 if (mode == 4) { result.process_group_id++; }
 if (mode == 5) { result.start_microseconds = 1000000; }
 return result;
}
int ergopti_suspended_image_validate(const char *path, const ergopti_listener_identity *expected,
 uint32_t remaining, ergopti_listener_identity *output) {
 assert(strcmp(path, "/owned/image") == 0);
 assert(expected->pid == 123 && expected->uid == geteuid());
 assert(expected->start_seconds == 101 && expected->start_microseconds == 202);
 assert(remaining > 0 && remaining <= 1000);
 mappings++;
 if (mode == 6) { return ENOENT; }
 *output = *expected;
 if (mode == 7) { output->pid++; }
 if (mode == 8) { output->device++; }
 if (mode == 9) { output->inode++; }
 if (mode == 10) { output->start_microseconds++; }
 if (mode == 11) { assert(fchmod(writable, 0722) == 0); }
 if (mode == 12) { assert(write(writable, "changed", 7) == 7); }
 if (mode == 13) { struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000}; assert(nanosleep(&delay, NULL) == 0); }
 return 0;
}
// The appended production active-image entry point is linked, but its native
// observations are outside this suspended-image cohort. Any call fails closed.
ergopti_owned_program_observation ergopti_owned_program_active_identity(ergopti_owned_program *owner) {
 (void)owner;
 assert(0 && "Active image native observations are not enrolled in this cohort");
 return (ergopti_owned_program_observation) {.error_code = ENOTSUP};
}
int ergopti_active_image_validate(const char *path, const ergopti_listener_identity *expected,
 uint32_t remaining, ergopti_listener_identity *output) {
 (void)path; (void)expected; (void)remaining; (void)output;
 assert(0 && "Active image native mapping is not enrolled in this cohort");
 return ENOTSUP;
}
int main(int argc, char **argv) {
 assert(argc == 2);
 char path[4096]; assert(snprintf(path, sizeof(path), "%s/image.XXXXXX", argv[1]) > 0);
 writable = mkstemp(path); assert(writable >= 0);
 assert(write(writable, "image", 5) == 5); assert(fchmod(writable, 0700) == 0);
 int descriptor = open(path, O_RDONLY | O_CLOEXEC); assert(descriptor >= 0);
 struct stat identity; assert(fstat(descriptor, &identity) == 0);
 uint64_t device = (uint64_t)(uint32_t)identity.st_dev, inode = (uint64_t)identity.st_ino;
 ergopti_owned_program *owner = (ergopti_owned_program *)(uintptr_t)1;
 ergopti_listener_identity output;
 int passed = 0;
 for (mode = 0; mode <= 13; mode++) {
  observations = 0; mappings = 0;
  assert(ftruncate(writable, 5) == 0); assert(lseek(writable, 0, SEEK_SET) == 0); assert(fchmod(writable, 0700) == 0);
  memset(&output, 0xff, sizeof(output));
  int result = ergopti_owned_suspended_image_validate(owner, "/owned/image", descriptor, device, inode, mode == 13 ? 10 : 1000, &output);
  if (mode == 0) { assert(result == 0 && output.pid == 123 && output.inode == inode && observations == 2 && mappings == 1); }
  else { assert(result != 0); ergopti_listener_identity zero = {0}; assert(memcmp(&output, &zero, sizeof(output)) == 0); }
  passed++;
 }
 mode = 0;
 assert(fchmod(writable, 0700) == 0);
 #define REFUSAL(call) do { memset(&output, 0xff, sizeof(output)); assert((call) != 0); assert(output.pid == 0); passed++; } while (0)
 REFUSAL(ergopti_owned_suspended_image_validate(NULL, "/owned/image", descriptor, device, inode, 1000, &output));
 REFUSAL(ergopti_owned_suspended_image_validate(owner, "relative", descriptor, device, inode, 1000, &output));
 REFUSAL(ergopti_owned_suspended_image_validate(owner, "/owned/image", descriptor, device, inode, 0, &output));
 REFUSAL(ergopti_owned_suspended_image_validate(owner, "/owned/image", descriptor, device, inode + 1, 1000, &output));
 REFUSAL(ergopti_owned_suspended_image_validate(owner, "/owned/image", writable, device, inode, 1000, &output));
 assert(fcntl(descriptor, F_SETFD, 0) == 0);
 REFUSAL(ergopti_owned_suspended_image_validate(owner, "/owned/image", descriptor, device, inode, 1000, &output));
 assert(close(descriptor) == 0); assert(close(writable) == 0); assert(unlink(path) == 0);
 printf("PASS %d actual-C receiving-boundary controls; native SDK functions are explicit test doubles\n", passed);
 return 0;
}
