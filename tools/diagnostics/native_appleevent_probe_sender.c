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
    int result = 66;
    if (strcmp(argv[3], "denied") == 0) {
        if (status == errAETargetAddressNotPermitted || status == errAEEventNotPermitted) result = 0;
    } else if (status == noErr) {
        char echoed[37] = {0};
        Size actual_length = 0;
        const OSStatus read = AEGetParamPtr(&reply, nonce_parameter, typeUTF8Text,
            NULL, echoed, 36, &actual_length);
        if (read == noErr && actual_length == 36 && memcmp(echoed, argv[2], 36) == 0) {
            result = 0;
        }
    }
    if (result != 0) {
        fprintf(stderr, "Owned AppleEvent outcome admission failed: %d\n", (int)status);
    } else {
        printf("native_appleevent_status=%d\n", (int)status);
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
    return result;
}
