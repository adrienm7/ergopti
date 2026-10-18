// Sources/CPOSIXCompatibility/include/OwnedVHDReportSocketIdentity.h
#ifndef ERGOPTI_OWNED_VHD_REPORT_SOCKET_IDENTITY_H
#define ERGOPTI_OWNED_VHD_REPORT_SOCKET_IDENTITY_H
#include <stdint.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  pid_t pid;
  uid_t uid;
  uint64_t start_seconds;
  uint64_t start_microseconds;
} ergopti_vhd_report_peer_identity;
int ergopti_vhd_report_channel_peer(int descriptor, ergopti_vhd_report_peer_identity *output);
/* Kernel observation of this process's exact socket object; data only, never a caller/Root grant. */
struct ergopti_vhd_report_socket_identity {
  uint64_t cookie;
  uint64_t device;
  uint64_t inode;
};
int ergopti_vhd_report_socket_capture(int descriptor, struct ergopti_vhd_report_socket_identity *output);
int ergopti_vhd_report_socket_matches(int descriptor, const struct ergopti_vhd_report_socket_identity *original);
// Kernel observation of this executing image only; caller data is never a permission.
struct ergopti_vhd_report_self_image {
  int32_t pid;
  uint64_t seconds;
  uint64_t microseconds;
  uint8_t cdhash[20];
};
int ergopti_vhd_report_self_image_capture(struct ergopti_vhd_report_self_image *output);
int ergopti_vhd_report_self_image_matches(const struct ergopti_vhd_report_self_image *original);
#ifdef __cplusplus
}
#endif
#endif
