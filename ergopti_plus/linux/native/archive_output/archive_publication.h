/* Private parent-only archive publication port. SOURCE ONLY; not installed. */
#ifndef ERGOPTI_ARCHIVE_PUBLICATION_H
#define ERGOPTI_ARCHIVE_PUBLICATION_H

#include <stdint.h>
#include <stddef.h>

struct ergopti_archive_publication;
#define ERGOPTI_ARCHIVE_PUBLICATION_DISPLAY_BYTES 4352
unsigned int ergopti_archive_publication_abi_version(void);
/* Actual Linux CLOCK_MONOTONIC nanoseconds /1e6, matching luv.hrtime division.
 * Admission brackets this value with actual luv.hrtime reads; no calibration,
 * relative budget restart or timestamp flooring. Failure returns -1 + errno. */
double ergopti_archive_publication_clock_ms(void);

/* Information ONLY: original recorded allocation location plus captured
 * archive name, not a proof of current path/inode and never installer authority.
 * No partial copy on insufficient capacity; byte count includes trailing NUL. */
int ergopti_archive_publication_copy_display_path(
    const struct ergopti_archive_publication *owner, char *buffer, size_t capacity);

/* Private native parent selection, captured source consent before/after call.
 * Creates one fresh cryptographically random0700 child before checksum.
 * Retains exact parent+child directory descriptors and acquired-name debt.
 * No manager/public arbitrary parent path may invoke this constructor. */
int ergopti_archive_publication_create_directory(const char *native_parent,
    double original_total_deadline_ms, struct ergopti_archive_publication **result);

/* Private original lease allocation port ONLY. Success transfers this NEW
 * parent O_TMPFILE descriptor to the original lease, never a manager/callback.
 * Refusal retains any acquired descriptor inside owner; out_fd remains -1.
 * Owner permits exactly one output allocation, including attempted failures.
 * A private native anchor retains the created inode to prevent numeric-FD/inode
 * reuse; stage validates this creation identity, then physically closes anchor
 * before successful staging. Cancel/cleanup owns anchor retirement on refusal. */
int ergopti_archive_publication_allocate_output(struct ergopti_archive_publication *owner,
    double original_deadline_ms, int *out_fd);

/* Private native parent reader allocation ONLY, after committed artifact/new
 * authenticated install reservation. This returns a NEW close-on-exec duplicate
 * to the captured native async reader, NOT the original artifact FD. Wrapper
 * must retain its exact native read/pipe/consumer settlement owner and must join
 * all readers before cleanup/retirement. No public integer/token/path fallback.
 * Negative return retains any partial new allocation internally. */
int ergopti_archive_publication_allocate_reader(struct ergopti_archive_publication *owner,
    double original_install_deadline_ms, int *out_fd);

/* Called ONLY by the private namespace owner after exact reader/consumer joins.
 * Captured random0700 namespace is exclusive to this trusted owner, not an
 * isolation boundary against a hostile same-UID process. Any foreign/noisy
 * entry/identity or syscall/close ambiguity refuses and retains physical debt.
 * Uses ONLY retained dir/parent FDs and captured names; never a display path. */
int ergopti_archive_publication_cleanup(struct ergopti_archive_publication *owner);
/* Additive ABI1 retirement-only receipt. out is initialized UNKNOWN=0 on every
 * call. RETAINED_NAMESPACE_CONFLICT=1 is acknowledged only for a known foreign
 * entry before any namespace mutation/retire, after exact scan closure and
 * retained-identity checks. Neither errno nor nonzero status grants retry.
 * Success keeps UNKNOWN and requires the original physical receipt checks. */
int ergopti_archive_publication_cleanup_with_disposition(
    struct ergopti_archive_publication *owner, int *out_disposition);

/* Private bootstrap before checksum dispatch. The transaction's existing
 * native selection owns this absolute private directory; public path hints
 * cannot select it. Each component is opened relative to its retained parent,
 * O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC. Caller refences captured source consent
 * before/after this call and validates embedded NUL before C conversion. */
int ergopti_archive_publication_capture_directory(const char *owned_directory,
    double original_deadline_ms, struct ergopti_archive_publication **result);

/* Called ONLY by the captured native directory owner before checksum dispatch.
 * No manager/public table receives the directory descriptor or this pointer.
 * The directory must be private, user-owned and retained by its original owner.
 * result owns its duplicate even on later refusal. errno is a syscall receipt;
 * policy errors use EINVAL/EPERM without pretending a native syscall failed. */
int ergopti_archive_publication_reserve(int owned_directory_fd,
    struct ergopti_archive_publication **result);

/* Called ONLY inside the sealing lease's private adapter. The lease reserves
 * against close/cancel/reentry and supplies its actual matching-checksum FD.
 * Length is the acknowledged final EOF, not a returned filename's stat.
 * Deadline is the ORIGINAL native CLOCK_MONOTONIC hash deadline, milliseconds.
 * staged publication is NOT installation authority. On a post-link refusal the
 * name remains retained debt: never compare-then-unlink a possibly foreign name. */
int ergopti_archive_publication_stage(struct ergopti_archive_publication *owner,
    int sealed_fd, int64_t acknowledged_length, const char *basename,
    double original_deadline_ms);

/* Called ONLY by the captured adapter after original transfer FD + timer and
 * producer/writer/hash owner have actually settled, with source/generation
 * consent rechecked. This function cannot establish those external facts. */
int ergopti_archive_publication_commit(struct ergopti_archive_publication *owner);

/* No artifact FD getter or displayed-path reopen. Private allocation ports
 * transfer only NEW descriptors to original native lease/read owners.
 * retire itself does not remove names: explicit cleanup owns that operation.
 * Descriptor close is attempted at most once; any refused close remains debt.
 * The destination directory stays retained while name debt remains: releasing
 * it would require a prohibited later path reopen. Retirement reports EBUSY
 * and descriptors_closed remains false until that obligation is actually solved.
 * named_remaining is 0 before link, 1 for a confirmed created link, or 2 for
 * syscall-attempt ambiguity. Any nonzero value is cleanup debt, not closure.
 * The caller must retain owner until both descriptor and name debts are solved
 * by a separately reviewed installation/directory cleanup owner. */
int ergopti_archive_publication_retire(struct ergopti_archive_publication *owner);
int ergopti_archive_publication_descriptors_closed(
    const struct ergopti_archive_publication *owner);
int ergopti_archive_publication_named_remaining(
    const struct ergopti_archive_publication *owner);

/* Memory retirement is permitted only after actual cleanup/descriptor ACKs.
 * No caller boolean or display path can substitute for those native receipts. */
int ergopti_archive_publication_dispose_unpublished(
    struct ergopti_archive_publication *owner);

#endif
