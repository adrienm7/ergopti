#ifndef ERGOPTI_OWNED_LISTENER_EVENT_COMPATIBILITY_H
#define ERGOPTI_OWNED_LISTENER_EVENT_COMPATIBILITY_H
#include "OwnedSuspendedImageCompatibility.h"
#include <stdbool.h>
typedef struct ergopti_owned_listener_event ergopti_owned_listener_event;
// Fresh native namespace, never a caller-selected filename or numeric FD.
int ergopti_owned_listener_event_create(ergopti_owned_listener_event **out);
const char *ergopti_owned_listener_event_path(ergopti_owned_listener_event *event);
int ergopti_owned_listener_event_descriptor(ergopti_owned_listener_event *event);
// 0 pending, 1 exact original live mapped peer/frame/EOF/accepted close; <0 refusal.
int ergopti_owned_listener_event_receive(ergopti_owned_listener_event *event,
 ergopti_owned_program *owner, const char *executable, int alias_descriptor,
 uint64_t device, uint64_t inode, uint32_t remaining_ms, const char *nonce);
// Only acknowledged exact owned namespace and single-attempt FD closure frees.
bool ergopti_owned_listener_event_destroy(ergopti_owned_listener_event **out);
// Declarations for the Debug-only SDK role; no release caller or implementation.
int ergopti_listener_event_native_fixture(const char *executable, const char *mode);
int ergopti_listener_event_peer_fixture(const char *path, const char *nonce, const char *mode);
#endif
