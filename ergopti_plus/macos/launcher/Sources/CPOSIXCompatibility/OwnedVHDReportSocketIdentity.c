// Sources/CPOSIXCompatibility/OwnedVHDReportSocketIdentity.c
#include "OwnedVHDReportSocketIdentity.h"
#include <errno.h>
#include <libproc.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/proc.h>
#include <sys/un.h>
#include <unistd.h>

int ergopti_vhd_report_socket_capture(int descriptor, struct ergopti_vhd_report_socket_identity *output) {
  if (!output || descriptor < 0) return EINVAL;
  memset(output, 0, sizeof(*output));
  struct stat first, last;
  struct socket_fdinfo before, after;
  memset(&before, 0, sizeof(before));
  memset(&after, 0, sizeof(after));
  if (fstat(descriptor, &first) != 0) return errno;
  if (!S_ISSOCK(first.st_mode)) return ENOTSOCK;
  int result = proc_pidfdinfo(getpid(), descriptor, PROC_PIDFDSOCKETINFO, &before, sizeof(before));
  int saved = errno;
  if (result != sizeof(before)) return result <= 0 && saved ? saved : ESTALE;
  result = proc_pidfdinfo(getpid(), descriptor, PROC_PIDFDSOCKETINFO, &after, sizeof(after));
  saved = errno;
  if (result != sizeof(after)) return result <= 0 && saved ? saved : ESTALE;
  if (fstat(descriptor, &last) != 0) return errno;
  if (!S_ISSOCK(last.st_mode) || first.st_dev != last.st_dev || first.st_ino != last.st_ino
      || !before.psi.soi_so || before.psi.soi_so != after.psi.soi_so
      || before.psi.soi_family != AF_UNIX || after.psi.soi_family != AF_UNIX
      || before.psi.soi_type != SOCK_STREAM || after.psi.soi_type != SOCK_STREAM) return ESTALE;
  output->cookie = before.psi.soi_so;
  output->device = (uint64_t)first.st_dev;
  output->inode = (uint64_t)first.st_ino;
  return 0;
}
int ergopti_vhd_report_socket_matches(int descriptor, const struct ergopti_vhd_report_socket_identity *original) {
  if (!original || !original->cookie) return EINVAL;
  struct ergopti_vhd_report_socket_identity now;
  int status = ergopti_vhd_report_socket_capture(descriptor, &now);
  if (status) return status;
  return now.cookie == original->cookie && now.device == original->device && now.inode == original->inode ? 0 : ESTALE;
}

// A process can retain its mapped text vnode after unlink; CS_VALID is sampled anew on every negative cleanup cut.
#if __has_include(<sys/codesign.h>) && __has_include(<kern/cs_blobs.h>)
#include <sys/codesign.h>
#else
// The public macOS SDK omits these XNU declarations, yet libSystem exports the
// csops system call. Compiling the supplier out made every shipped build refuse
// its own image. These are the fixed kernel ABI values from xnu
// bsd/sys/codesign.h and osfmk/kern/cs_blobs.h; the kernel still answers.
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_OPS_CDHASH 5
#define CS_VALID 0x00000001u
#define CS_KILLED 0x01000000u
#define CS_CDHASH_LEN 20
#endif
_Static_assert(CS_CDHASH_LEN == 20, "Unsupported kernel CDHash length");
static int report_self_image(struct ergopti_vhd_report_self_image *output) {
  if (!output) return EINVAL;
  memset(output, 0, sizeof(*output));
  struct proc_bsdinfo before, after;
  memset(&before, 0, sizeof(before)); memset(&after, 0, sizeof(after));
  pid_t pid = getpid();
  int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before));
  int saved = errno;
  if (result != sizeof(before)) return result <= 0 && saved ? saved : ESTALE;
  uint32_t initial = 0, final = 0;
  uint8_t first[CS_CDHASH_LEN], last[CS_CDHASH_LEN];
  if (csops(0, CS_OPS_STATUS, &initial, sizeof(initial)) != 0) return errno;
  if (!(initial & CS_VALID) || (initial & CS_KILLED)) return EPERM;
  if (csops(0, CS_OPS_CDHASH, first, sizeof(first)) != 0) return errno;
  if (csops(0, CS_OPS_CDHASH, last, sizeof(last)) != 0) return errno;
  if (csops(0, CS_OPS_STATUS, &final, sizeof(final)) != 0) return errno;
  if (!(final & CS_VALID) || (final & CS_KILLED)) return EPERM;
  result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)); saved = errno;
  if (result != sizeof(after)) return result <= 0 && saved ? saved : ESTALE;
  if (before.pbi_pid != pid || after.pbi_pid != pid || before.pbi_status == SZOMB || after.pbi_status == SZOMB
      || before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec
      || before.pbi_uid != getuid() || after.pbi_uid != getuid() || before.pbi_ruid != getuid() || after.pbi_ruid != getuid()
      || before.pbi_start_tvusec >= 1000000 || memcmp(first, last, CS_CDHASH_LEN)) return ESTALE;
  output->pid = pid; output->seconds = before.pbi_start_tvsec; output->microseconds = before.pbi_start_tvusec;
  memcpy(output->cdhash, first, CS_CDHASH_LEN);
  return 0;
}
int ergopti_vhd_report_self_image_capture(struct ergopti_vhd_report_self_image *output) { return report_self_image(output); }
int ergopti_vhd_report_self_image_matches(const struct ergopti_vhd_report_self_image *original) {
  if (!original || original->pid != getpid()) return EINVAL;
  struct ergopti_vhd_report_self_image observed;
  int status = report_self_image(&observed);
  if (status) return status;
  return observed.pid == original->pid && observed.seconds == original->seconds && observed.microseconds == original->microseconds
    && !memcmp(observed.cdhash, original->cdhash, CS_CDHASH_LEN) ? 0 : ESTALE;
}

// Same guarded kernel peer observation as the authenticated original supplier; no publication purpose.
int ergopti_vhd_report_channel_peer(int descriptor, ergopti_vhd_report_peer_identity* out) {
 if(!out || descriptor<0) return EINVAL; memset(out,0,sizeof(*out));
 uid_t uid=0;gid_t gid=0;pid_t peer=0;socklen_t size=sizeof(peer);
 if(getpeereid(descriptor,&uid,&gid)!=0 || getsockopt(descriptor,SOL_LOCAL,LOCAL_PEERPID,&peer,&size)!=0
  || size!=sizeof(peer) || peer<=1) return EPERM;
 struct proc_bsdinfo first={0},last={0};
 if(proc_pidinfo(peer,PROC_PIDTBSDINFO,1,&first,sizeof(first))!=sizeof(first)
  || first.pbi_pid!=(unsigned)peer || first.pbi_status==SZOMB || first.pbi_uid!=uid || first.pbi_ruid!=uid) return ESTALE;
 uid_t fresh_uid=0;gid_t fresh_gid=0;pid_t fresh_peer=0;size=sizeof(fresh_peer);
 if(getpeereid(descriptor,&fresh_uid,&fresh_gid)!=0 || getsockopt(descriptor,SOL_LOCAL,LOCAL_PEERPID,&fresh_peer,&size)!=0
  || size!=sizeof(fresh_peer) || fresh_peer!=peer || fresh_uid!=uid || fresh_gid!=gid
  || proc_pidinfo(peer,PROC_PIDTBSDINFO,1,&last,sizeof(last))!=sizeof(last)
  || last.pbi_pid!=(unsigned)peer || last.pbi_status==SZOMB || last.pbi_uid!=uid || last.pbi_ruid!=uid
  || last.pbi_start_tvsec!=first.pbi_start_tvsec || last.pbi_start_tvusec!=first.pbi_start_tvusec) return ESTALE;
 out->pid=peer;out->uid=uid;out->start_seconds=first.pbi_start_tvsec;out->start_microseconds=first.pbi_start_tvusec;
 return 0;
}
