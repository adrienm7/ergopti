// Sources/CPOSIXCompatibility/LoopbackListenerCompatibility.c
// The SDK owns every layout used to bind a live accepted socket to its runtime.

#include "LoopbackListenerCompatibility.h"
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <mach/vm_prot.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int monotonic(struct timespec *value) {
	return clock_gettime(CLOCK_MONOTONIC, value) == 0 ? 0 : errno;
}
static bool expired(const struct timespec *started, uint32_t budget) {
	struct timespec now;
	if (monotonic(&now) != 0) { return true; }
	int64_t elapsed = ((int64_t)now.tv_sec - started->tv_sec) * 1000000000LL
		+ now.tv_nsec - started->tv_nsec;
	return elapsed < 0 || elapsed / 1000000 >= budget;
}
static int bsd_identity(pid_t pid, struct proc_bsdinfo *info) {
	memset(info, 0, sizeof(*info));
	errno = 0;
	int received = proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, info, sizeof(*info));
	if (received != sizeof(*info)) { return errno == 0 ? EIO : errno; }
	if (info->pbi_pid != (uint32_t)pid || info->pbi_status == SZOMB
		|| info->pbi_uid != geteuid() || info->pbi_ruid != getuid()
		|| info->pbi_start_tvusec >= 1000000) { return EPERM; }
	return 0;
}
static bool same_process(const struct proc_bsdinfo *a, const struct proc_bsdinfo *b) {
	return a->pbi_pid == b->pbi_pid && a->pbi_uid == b->pbi_uid
		&& a->pbi_ruid == b->pbi_ruid && a->pbi_start_tvsec == b->pbi_start_tvsec
		&& a->pbi_start_tvusec == b->pbi_start_tvusec;
}
static int path_identity(pid_t pid, const char *executable, uint64_t device, uint64_t inode) {
	char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
	errno = 0;
	int count = proc_pidpath(pid, path, sizeof(path));
	if (count <= 0 || count >= sizeof(path) || memchr(path, 0, sizeof(path)) == NULL) {
		return errno == 0 ? EIO : errno;
	}
	if (strcmp(path, executable) != 0) { return ENOENT; }
	struct stat named;
	if (lstat(path, &named) != 0) { return errno; }
	if (!S_ISREG(named.st_mode) || named.st_uid != geteuid()
		|| (uint64_t)(uint32_t)named.st_dev != device || (uint64_t)named.st_ino != inode) {
		return ESTALE;
	}
	return 0;
}
// A known fixture PID is diagnostic input only. This observation does not
// participate in discovering, selecting or validating a connected socket.
void ergopti_listener_known_peer_diagnostic(pid_t pid, const char *executable,
	uint64_t device, uint64_t inode, ergopti_listener_peer_diagnostic *lexical,
	ergopti_listener_peer_diagnostic *physical) {
	if (lexical == NULL || physical == NULL) { return; }
	memset(lexical, 0, sizeof(*lexical));
	memset(physical, 0, sizeof(*physical));
	if (pid <= 0 || executable == NULL) { lexical->path_errno = EINVAL; *physical = *lexical; return; }
	errno = 0;
	int needed = proc_listallpids(NULL, 0);
	if (needed <= 0 || needed > 65536) {
		lexical->list_errno = needed < 0 && errno != 0 ? errno : EOVERFLOW;
	} else {
		size_t capacity = (size_t)needed + 32;
		pid_t *pids = calloc(capacity, sizeof(*pids));
		if (pids == NULL) { lexical->list_errno = ENOMEM; } else {
			errno = 0;
			int count = proc_listallpids(pids, (int)(capacity * sizeof(*pids)));
			if (count <= 0 || (size_t)count >= capacity) {
				lexical->list_errno = count < 0 && errno != 0 ? errno : EOVERFLOW;
			} else {
				for (int index = 0; index < count; index++) {
					if (pids[index] == pid) { lexical->listed = 1; break; }
				}
			}
			free(pids);
		}
	}
	char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
	errno = 0;
	int count = proc_pidpath(pid, path, sizeof(path));
	if (count <= 0 || (size_t)count >= sizeof(path) || memchr(path, 0, sizeof(path)) == NULL) {
		lexical->path_errno = errno == 0 ? EIO : errno;
		*physical = *lexical;
		return;
	}
	lexical->pathreceived = 1;
	lexical->pathmatches = strcmp(path, executable) == 0;
	struct stat named;
	errno = 0;
	if (lstat(path, &named) != 0) { lexical->stat_errno = errno; } else {
		lexical->uidmatches = named.st_uid == geteuid();
		lexical->devicematches = (uint64_t)(uint32_t)named.st_dev == device;
		lexical->inodematches = (uint64_t)named.st_ino == inode;
		if (!S_ISREG(named.st_mode)) { lexical->stat_errno = ESTALE; }
	}
	*physical = *lexical;
	physical->pathmatches = 0;
	errno = 0;
	char *canonical = realpath(executable, NULL);
	if (canonical == NULL) { physical->canonical_errno = errno == 0 ? EIO : errno; } else {
		physical->pathmatches = strcmp(path, canonical) == 0;
		free(canonical);
	}
}
static int executable_mapping(pid_t pid, uint64_t device, uint64_t inode,
	const struct timespec *started, uint32_t budget) {
	uint64_t address = 0;
	for (size_t index = 0; index < 8192; index++) {
		if (expired(started, budget)) { return ETIMEDOUT; }
		struct proc_regionwithpathinfo region;
		memset(&region, 0, sizeof(region));
		errno = 0;
		int count = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, sizeof(region));
		if (count != sizeof(region)) { return errno == 0 ? ENOENT : errno; }
		const struct vinfo_stat *mapped = &region.prp_vip.vip_vi.vi_stat;
		if ((region.prp_prinfo.pri_protection & VM_PROT_EXECUTE) != 0
			&& S_ISREG(mapped->vst_mode) && mapped->vst_uid == geteuid()
			&& (uint64_t)mapped->vst_dev == device && mapped->vst_ino == inode) { return 0; }
		uint64_t next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size;
		if (region.prp_prinfo.pri_size == 0 || next <= address
			|| next < region.prp_prinfo.pri_address) { return EOVERFLOW; }
		address = next;
	}
	return EOVERFLOW;
}
static int connected_tuple(int descriptor, struct sockaddr_in *local, struct sockaddr_in *peer) {
	socklen_t size = sizeof(*local);
	int type = 0;
	socklen_t type_size = sizeof(type);
	if (getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &type_size) != 0
		|| type_size != sizeof(type) || type != SOCK_STREAM) { return EINVAL; }
	memset(local, 0, sizeof(*local)); memset(peer, 0, sizeof(*peer));
	if (getsockname(descriptor, (struct sockaddr *)local, &size) != 0) { return errno; }
	if (size != sizeof(*local) || local->sin_family != AF_INET
		|| local->sin_addr.s_addr != htonl(INADDR_LOOPBACK)) { return EINVAL; }
	size = sizeof(*peer);
	if (getpeername(descriptor, (struct sockaddr *)peer, &size) != 0) { return errno; }
	if (size != sizeof(*peer) || peer->sin_family != AF_INET
		|| peer->sin_addr.s_addr != htonl(INADDR_LOOPBACK)
		|| peer->sin_port == 0 || local->sin_port == 0) { return EINVAL; }
	return 0;
}
static bool tuple_matches(const struct socket_fdinfo *info,
	const struct sockaddr_in *local, const struct sockaddr_in *peer) {
	const struct socket_info *socket = &info->psi;
	const struct tcp_sockinfo *tcp = &socket->soi_proto.pri_tcp;
	const struct in_sockinfo *internet = &tcp->tcpsi_ini;
	// SDK ports retain network byte order (XNU fill_socketinfo); no guessed ABI
	// offsets or ctypes definitions participate in this comparison.
	return socket->soi_kind == SOCKINFO_TCP && socket->soi_type == SOCK_STREAM
		&& socket->soi_protocol == IPPROTO_TCP && socket->soi_family == AF_INET
		&& tcp->tcpsi_state == TSI_S_ESTABLISHED && (internet->insi_vflag & INI_IPV4) != 0
		&& (uint16_t)internet->insi_lport == peer->sin_port
		&& (uint16_t)internet->insi_fport == local->sin_port
		&& internet->insi_laddr.ina_46.i46a_addr4.s_addr == peer->sin_addr.s_addr
		&& internet->insi_faddr.ina_46.i46a_addr4.s_addr == local->sin_addr.s_addr;
}
static int accepted_tuple(pid_t pid, const struct sockaddr_in *local, const struct sockaddr_in *peer,
	const struct timespec *started, uint32_t budget) {
	errno = 0;
	int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
	if (required <= 0 || required > (int)(8192 * sizeof(struct proc_fdinfo))) {
		return errno == 0 ? EOVERFLOW : errno;
	}
	size_t capacity = (size_t)required + 16 * sizeof(struct proc_fdinfo);
	struct proc_fdinfo *fds = calloc(1, capacity);
	if (fds == NULL) { return ENOMEM; }
	int result = ENOENT;
	int count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)capacity);
	if (count <= 0 || count >= capacity || count % sizeof(*fds) != 0) { result = EIO; }
	else {
		for (size_t i = 0; i < (size_t)count / sizeof(*fds); i++) {
			if (expired(started, budget)) { result = ETIMEDOUT; break; }
			if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) { continue; }
			struct socket_fdinfo info;
			memset(&info, 0, sizeof(info));
			int size = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info));
			// A different transient socket can disappear while the table is read;
			// it cannot supply the required positive accepted-connection witness.
			if (size == sizeof(info) && tuple_matches(&info, local, peer)) { result = 0; break; }
		}
	}
	free(fds);
	return result;
}
static int candidate(int descriptor, pid_t pid, const char *executable,
	uint64_t device, uint64_t inode, const struct timespec *started, uint32_t budget,
	const ergopti_listener_identity *expected, ergopti_listener_identity *result,
	ergopti_listener_diagnostic *diagnostic) {
	struct proc_bsdinfo before, after;
#define WITNESS_ERROR(stage, value) do { \
	if (diagnostic != NULL) { diagnostic->candidate_stage = stage; diagnostic->candidate_errno = value; } \
	return value; \
} while (0)
	int error = bsd_identity(pid, &before);
	if (error != 0) { WITNESS_ERROR(1, error); }
	if (expected != NULL && (before.pbi_pid != (uint32_t)expected->pid
		|| before.pbi_uid != expected->uid || before.pbi_start_tvsec != expected->start_seconds
		|| before.pbi_start_tvusec != expected->start_microseconds)) { WITNESS_ERROR(2, ESTALE); }
	if ((error = path_identity(pid, executable, device, inode)) != 0) { WITNESS_ERROR(3, error); }
	if ((error = executable_mapping(pid, device, inode, started, budget)) != 0) { WITNESS_ERROR(4, error); }
	struct sockaddr_in local, peer, final_local, final_peer;
	if ((error = connected_tuple(descriptor, &local, &peer)) != 0) { WITNESS_ERROR(5, error); }
	if ((error = accepted_tuple(pid, &local, &peer, started, budget)) != 0) { WITNESS_ERROR(6, error); }
	if ((error = bsd_identity(pid, &after)) != 0) { WITNESS_ERROR(7, error); }
	if ((error = path_identity(pid, executable, device, inode)) != 0) { WITNESS_ERROR(8, error); }
	if (!same_process(&before, &after)) { WITNESS_ERROR(9, ESTALE); }
	if ((error = connected_tuple(descriptor, &final_local, &final_peer)) != 0) { WITNESS_ERROR(10, error); }
	if (memcmp(&local, &final_local, sizeof(local)) != 0 || memcmp(&peer, &final_peer, sizeof(peer)) != 0) { WITNESS_ERROR(11, ESTALE); }
#undef WITNESS_ERROR
	*result = (ergopti_listener_identity) { .pid = pid, .uid = before.pbi_uid,
		.start_seconds = before.pbi_start_tvsec, .start_microseconds = before.pbi_start_tvusec,
		.device = device, .inode = inode };
	return 0;
}
int ergopti_listener_validate(int descriptor, const char *executable,
	const ergopti_listener_identity *expected, uint32_t remaining_ms, ergopti_listener_identity *identity) {
	if (expected == NULL || identity == NULL || executable == NULL || executable[0] != '/'
		|| expected->pid <= 0 || expected->uid != geteuid() || expected->start_microseconds >= 1000000
		|| remaining_ms == 0) { return EINVAL; }
	struct timespec started;
	int error = monotonic(&started);
	if (error != 0) { return error; }
	return candidate(descriptor, expected->pid, executable, expected->device, expected->inode,
		&started, remaining_ms, expected, identity, NULL);
}
static int discover(int descriptor, const char *executable, uint64_t device,
	uint64_t inode, uint32_t remaining_ms, ergopti_listener_identity *identity,
	ergopti_listener_diagnostic *diagnostic) {
	if (diagnostic != NULL) { *diagnostic = (ergopti_listener_diagnostic) {0}; }
	if (identity == NULL || executable == NULL || executable[0] != '/' || remaining_ms == 0) { return EINVAL; }
	struct sockaddr_in local, peer;
	int error = connected_tuple(descriptor, &local, &peer);
	if (error != 0) { return error; }
	struct timespec started;
	if ((error = monotonic(&started)) != 0) { return error; }
	int needed = proc_listallpids(NULL, 0);
	if (needed <= 0 || needed > 65536) { return EOVERFLOW; }
	size_t capacity = (size_t)needed + 32;
	pid_t *pids = calloc(capacity, sizeof(*pids));
	if (pids == NULL) { return ENOMEM; }
	int count = proc_listallpids(pids, (int)(capacity * sizeof(*pids)));
	if (count <= 0 || count >= capacity) { free(pids); return EOVERFLOW; }
	int matches = 0;
	for (int i = 0; i < count; i++) {
		if (expired(&started, remaining_ms)) { error = ETIMEDOUT; break; }
		if (pids[i] <= 0 || path_identity(pids[i], executable, device, inode) != 0) { continue; }
		if (diagnostic != NULL) { diagnostic->path_matches++; }
		ergopti_listener_identity found;
		error = candidate(descriptor, pids[i], executable, device, inode, &started, remaining_ms, NULL, &found, diagnostic);
		if (error == 0) { *identity = found; matches++; }
		if (matches > 1) { error = EEXIST; break; }
	}
	free(pids);
	if (error == ETIMEDOUT || error == EEXIST) { return error; }
	return matches == 1 ? 0 : ENOENT;
}

int ergopti_listener_discover(int descriptor, const char *executable, uint64_t device,
	uint64_t inode, uint32_t remaining_ms, ergopti_listener_identity *identity) {
	return discover(descriptor, executable, device, inode, remaining_ms, identity, NULL);
}
int ergopti_listener_discover_diagnostic(int descriptor, const char *executable, uint64_t device,
	uint64_t inode, uint32_t remaining_ms, ergopti_listener_identity *identity,
	ergopti_listener_diagnostic *diagnostic) {
	if (diagnostic == NULL) { return EINVAL; }
	return discover(descriptor, executable, device, inode, remaining_ms, identity, diagnostic);
}
