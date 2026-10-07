// tools/diagnostics/native_appleevent_probe_sender.c
// Exact kernel-PID private nonce sender for native sandbox admission only.

#include <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "native_appleevent_probe_protocol.h"

static const AEEventClass probe_class = ERGOPTI_PROBE_EVENT_CLASS;
static const AEEventID probe_event = ERGOPTI_PROBE_EVENT_ID;
static const AEKeyword nonce_parameter = ERGOPTI_PROBE_NONCE_PARAMETER;

static int valid_nonce(const char *value) {
    if (strlen(value) != 36) return 0;
    for (size_t index = 0; index < 36; index++) {
        const char byte = value[index];
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (byte != '-') return 0;
        } else if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

/* Fixed scalar diagnostics only; neither reply contents nor target identity escape. */
struct ProbeNonceObservation {
    int available;
    OSStatus status;
    Size size;
    int matches;
};

static void emit_sender_diagnostic(OSStatus send_status, int denied,
    const struct ProbeNonceObservation *nonce, const AppleEvent *reply) {
    char nonce_status[24] = "null", nonce_size[24] = "null";
    char error_status[24] = "null", error_type[24] = "null", error_size[24] = "null";
    char error_number[24] = "null";
    if (nonce->available) {
        snprintf(nonce_status, sizeof(nonce_status), "%d", (int)nonce->status);
        if (nonce->size >= 0 && nonce->size <= 4096) {
            snprintf(nonce_size, sizeof(nonce_size), "%lld", (long long)nonce->size);
        }
    }
    const int error_read = reply->descriptorType != typeNull;
    int error_available = 0;
    if (error_read) {
        SInt32 number = 0;
        DescType actual_type = typeNull;
        Size actual_size = 0;
        const OSErr read = AEGetParamPtr(reply, keyErrorNumber, typeWildCard,
            &actual_type, &number, sizeof(number), &actual_size);
        snprintf(error_status, sizeof(error_status), "%d", (int)read);
        snprintf(error_type, sizeof(error_type), "%u", (unsigned int)actual_type);
        if (actual_size >= 0 && actual_size <= 4096) {
            snprintf(error_size, sizeof(error_size), "%lld", (long long)actual_size);
        }
        if (read == noErr && actual_type == typeSInt32 && actual_size == sizeof(number)) {
            error_available = 1;
            snprintf(error_number, sizeof(error_number), "%d", (int)number);
        }
    }
    char diagnostic[512];
    const int length = snprintf(diagnostic, sizeof(diagnostic),
        "Owned AppleEvent sender diagnostic: {\"schema\":1,\"mode\":%d,\"send_status\":%d,"
        "\"nonce_read_available\":%s,\"nonce_read_status\":%s,\"nonce_size\":%s,\"nonce_match\":%s,"
        "\"reply_type\":%u,\"error_read_available\":%s,\"error_read_status\":%s,"
        "\"error_type\":%s,\"error_size\":%s,\"error_available\":%s,\"error_number\":%s}\n",
        denied ? 2 : 1, (int)send_status, nonce->available ? "true" : "false",
        nonce_status, nonce_size, nonce->available ? (nonce->matches ? "true" : "false") : "null",
        (unsigned int)reply->descriptorType, error_read ? "true" : "false", error_status,
        error_type, error_size, error_available ? "true" : "false", error_number);
    if (length > 0 && (size_t)length < sizeof(diagnostic)) {
        /* Any stream failure remains a failed diagnostic, never a successful send. */
        (void)fwrite(diagnostic, 1, (size_t)length, stderr);
    }
}

int main(int argc, char **argv) {
    if (argc != 4 || !valid_nonce(argv[2]) ||
        (strcmp(argv[3], "success") != 0 && strcmp(argv[3], "denied") != 0)) return 64;
    errno = 0;
    char *end = NULL;
    const long parsed = strtol(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' || parsed <= 0 ||
        parsed > INT_MAX || parsed == getpid()) return 64;
    const pid_t recipient = (pid_t)parsed;
    AEAddressDesc address = {typeNull, NULL};
    AppleEvent event = {typeNull, NULL};
    AppleEvent reply = {typeNull, NULL};
    OSStatus status = AECreateDesc(typeKernelProcessID, &recipient, sizeof(recipient), &address);
    if (status == noErr) {
        status = AECreateAppleEvent(probe_class, probe_event, &address,
            kAutoGenerateReturnID, kAnyTransactionID, &event);
    }
    if (status == noErr) {
        status = AEPutParamPtr(&event, nonce_parameter, typeUTF8Text, argv[2], 36);
    }
    if (status != noErr) {
        fprintf(stderr, "Owned AppleEvent construction failed: %d\n", (int)status);
        AEDisposeDesc(&reply);
        AEDisposeDesc(&event);
        AEDisposeDesc(&address);
        return 65;
    }
    // Only this acquired process receives the event; no bundle lookup or launch.
    // kAENeverInteract governs the receiver, not TCC's Automation prompt.
    // Refuse a consent requirement without ever displaying or changing it.
    status = AESendMessage(&event, &reply,
        kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent, 5 * 60);
    struct ProbeNonceObservation nonce_observation = {0, 0, 0, 0};
    int result = 66;
    if (strcmp(argv[3], "denied") == 0) {
        if (status == errAETargetAddressNotPermitted || status == errAEEventNotPermitted) result = 0;
    } else if (status == noErr) {
        char echoed[37] = {0};
        Size actual_length = 0;
        const OSStatus read = AEGetParamPtr(&reply, nonce_parameter, typeUTF8Text,
            NULL, echoed, 36, &actual_length);
        nonce_observation.available = 1;
        nonce_observation.status = read;
        nonce_observation.size = actual_length;
        nonce_observation.matches = read == noErr && actual_length == 36 && memcmp(echoed, argv[2], 36) == 0;
        if (read == noErr && actual_length == 36 && memcmp(echoed, argv[2], 36) == 0) {
            result = 0;
        }
    }
    if (result != 0) {
        fprintf(stderr, "Owned AppleEvent outcome admission failed: %d\n", (int)status);
        emit_sender_diagnostic(status, strcmp(argv[3], "denied") == 0, &nonce_observation, &reply);
    } else {
        printf("native_appleevent_status=%d\n", (int)status);
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
    return result;
}
