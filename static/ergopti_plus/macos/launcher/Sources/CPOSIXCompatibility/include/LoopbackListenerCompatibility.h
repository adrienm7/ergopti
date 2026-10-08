// Sources/CPOSIXCompatibility/include/LoopbackListenerCompatibility.h
#ifndef ERGOPTI_LOOPBACK_LISTENER_COMPATIBILITY_H
#define ERGOPTI_LOOPBACK_LISTENER_COMPATIBILITY_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
	int32_t pid;
	uint32_t uid;
	uint64_t start_seconds;
	uint64_t start_microseconds;
	uint64_t device;
	uint64_t inode;
} ergopti_listener_identity;

// Borrow a connected IPv4 loopback socket. No HTTP bytes are sent, no descriptor
// is closed, and no authority is inferred from a listening-port-only match.
int ergopti_listener_discover(int connected_socket, const char *executable,
	uint64_t device, uint64_t inode, uint32_t remaining_ms,
	ergopti_listener_identity *identity);
// Diagnostic scalars carry no pathname, HTTP bytes, credentials or environment.
// The debug fixture can distinguish a missing path candidate from a refused
// BSD/mapping/socket witness without relaxing the production admission result.
typedef struct {
	uint32_t path_matches;
	uint32_t candidate_stage;
	int32_t candidate_errno;
} ergopti_listener_diagnostic;
int ergopti_listener_discover_diagnostic(int connected_socket, const char *executable,
	uint64_t device, uint64_t inode, uint32_t remaining_ms,
	ergopti_listener_identity *identity, ergopti_listener_diagnostic *diagnostic);
// Compare one debug fixture's known PID with both the supplied spelling and
// POSIX realpath spelling. Only booleans and typed errors leave this helper;
// neither observation supplies admission authority or changes its predicates.
// stat_errno is ESTALE for a nonregular named object, otherwise the lstat errno.
// The physical observation shares the exact same list/path/stat snapshot.
typedef struct {
	uint32_t listed;
	uint32_t pathreceived;
	uint32_t pathmatches;
	uint32_t uidmatches;
	uint32_t devicematches;
	uint32_t inodematches;
	int32_t list_errno;
	int32_t path_errno;
	int32_t stat_errno;
	int32_t canonical_errno;
} ergopti_listener_peer_diagnostic;
void ergopti_listener_known_peer_diagnostic(pid_t pid, const char *executable,
	uint64_t device, uint64_t inode, ergopti_listener_peer_diagnostic *lexical,
	ergopti_listener_peer_diagnostic *physical);
// Every request requires the exact earlier native identity. The same connected
// socket must remain retained until the request/response is physically closed.
int ergopti_listener_validate(int connected_socket, const char *executable,
	const ergopti_listener_identity *expected, uint32_t remaining_ms,
	ergopti_listener_identity *identity);
#endif
