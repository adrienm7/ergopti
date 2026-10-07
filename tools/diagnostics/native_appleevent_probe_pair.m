// tools/diagnostics/native_appleevent_probe_pair.m
// Two acquired processes share one signed fixture image, never a self-target.

#include <string.h>

#define main owned_receiver_entry
#define probe_class owned_receiver_class
#define probe_event owned_receiver_event
#define nonce_parameter owned_receiver_parameter
#define valid_nonce owned_receiver_valid_nonce
#include "native_appleevent_probe_receiver.c"
#undef valid_nonce
#undef nonce_parameter
#undef probe_event
#undef probe_class
#undef main

#define main owned_sender_entry
#define probe_class owned_sender_class
#define probe_event owned_sender_event
#define nonce_parameter owned_sender_parameter
#define valid_nonce owned_sender_valid_nonce
#include "native_appleevent_probe_sender.c"
#undef valid_nonce
#undef nonce_parameter
#undef probe_event
#undef probe_class
#undef main

int main(int argc, char **argv) {
    if (argc < 2) return 64;
    if (strcmp(argv[1], "receiver") == 0) return owned_receiver_entry(argc - 1, argv + 1);
    if (strcmp(argv[1], "sender") == 0) return owned_sender_entry(argc - 1, argv + 1);
    return 64;
}
