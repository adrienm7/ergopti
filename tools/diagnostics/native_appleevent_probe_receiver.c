// tools/diagnostics/native_appleevent_probe_receiver.c
// Owned open-application recipient for non-self native sandbox admission only.

#include <Carbon/Carbon.h>
#include <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const AEEventClass probe_class = kCoreEventClass;
static const AEEventID probe_event = kAEOpenApplication;
static const AEKeyword nonce_parameter = 0x45674e63; /* EgNc */
static const char *expected_nonce;
static const char *delivery_path;
static unsigned int delivered;

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

static int write_exclusive(const char *path, const char *bytes, size_t length) {
    const int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (descriptor < 0) return -1;
    size_t offset = 0;
    while (offset < length) {
        const ssize_t count = write(descriptor, bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(descriptor);
            return -1;
        }
        offset += (size_t)count;
    }
    const int acknowledged = fsync(descriptor);
    const int closed = close(descriptor);
    return acknowledged == 0 && closed == 0 ? 0 : -1;
}

static OSErr receive_probe(const AppleEvent *event, AppleEvent *reply, SRefCon context) {
    (void)context;
    char nonce[37] = {0};
    Size actual_length = 0;
    const OSErr admitted = AEGetParamPtr(event, nonce_parameter, typeUTF8Text,
        NULL, nonce, 36, &actual_length);
    if (admitted != noErr || actual_length != 36 ||
        memcmp(nonce, expected_nonce, 36) != 0 || delivered >= 2) {
        return errAEEventNotHandled;
    }
    // Only the two actual positive controls may deliver. The denied third
    // attempt cannot pass by reaching this handler or replaying an old reply.
    delivered += 1;
    char marker[PATH_MAX];
    const int length = snprintf(marker, sizeof(marker), "%s.%u", delivery_path, delivered);
    if (length <= 0 || (size_t)length >= sizeof(marker) ||
        write_exclusive(marker, expected_nonce, 36) != 0) return ioErr;
    return AEPutParamPtr(reply, nonce_parameter, typeUTF8Text, expected_nonce, 36);
}

enum AppKitAdmission {
    AppKitAdmitted = 0,
    AppKitApplicationMissing,
    AppKitPolicyRefused,
    AppKitPolicyUnconfirmed
};

static enum AppKitAdmission admit_appkit(NSApplication *application) {
    if (application == nil) return AppKitApplicationMissing;
    if (![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
        return AppKitPolicyRefused;
    }
    if ([application activationPolicy] != NSApplicationActivationPolicyAccessory) {
        return AppKitPolicyUnconfirmed;
    }
    return AppKitAdmitted;
}

static int receiver_main(int argc, char **argv) {
    if (argc != 4 || !valid_nonce(argv[3])) return 64;
    delivery_path = argv[2];
    expected_nonce = argv[3];
    ProcessSerialNumber serial;
    OSStatus status = GetCurrentProcess(&serial);
    if (status != noErr) {
        fprintf(stderr, "Owned AppleEvent recipient registration failed: phase=get-current-process, osstatus=%d\n", (int)status);
        return 65;
    }
    const enum AppKitAdmission admission = admit_appkit([NSApplication sharedApplication]);
    if (admission != AppKitAdmitted) {
        // This reason is not an OSStatus. Existing bounded terminal diagnostics
        // retain it as unclassified instead of inventing a Carbon status.
        fprintf(stderr, "Owned AppleEvent recipient AppKit admission refused (reason %d).\n", (int)admission);
        return 65;
    }
    const AEEventHandlerUPP handler = NewAEEventHandlerUPP(receive_probe);
    status = AEInstallEventHandler(probe_class, probe_event, handler, 0, false);
    if (status != noErr) {
        fprintf(stderr, "Owned AppleEvent handler admission failed: %d\n", (int)status);
        DisposeAEEventHandlerUPP(handler);
        return 66;
    }
    char readiness[96];
    const int length = snprintf(readiness, sizeof(readiness), "%ld\n%s\n",
        (long)getpid(), expected_nonce);
    if (length <= 0 || (size_t)length >= sizeof(readiness) ||
        write_exclusive(argv[1], readiness, (size_t)length) != 0) {
        AERemoveEventHandler(probe_class, probe_event, handler, false);
        DisposeAEEventHandlerUPP(handler);
        return 67;
    }
    // RunApplicationEventLoop is 32-bit only. The documented 64-bit dispatch
    // dequeues only AppleEvents and routes them to the unchanged nonce handler.
    // The parent retains physical shutdown ownership through all three sends.
    const EventTypeSpec apple_event = {kEventClassAppleEvent, kEventAppleEvent};
    for (;;) {
        EventRef event = NULL;
        status = ReceiveNextEvent(1, &apple_event, kEventDurationForever, true, &event);
        if (status != noErr || event == NULL) {
            if (event != NULL) ReleaseEvent(event);
            fprintf(stderr, "Owned AppleEvent receipt failed: %d\n", (int)status);
            break;
        }
        status = AEProcessEvent(event);
        ReleaseEvent(event);
        // A rejected nonce remains an AppleEvent handler refusal, as before;
        // it does not close the receiver or fabricate a successful reply.
        if (status != noErr && status != errAEEventNotHandled) {
            fprintf(stderr, "Owned AppleEvent dispatch failed: %d\n", (int)status);
            break;
        }
    }
    AERemoveEventHandler(probe_class, probe_event, handler, false);
    DisposeAEEventHandlerUPP(handler);
    return 68;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        return receiver_main(argc, argv);
    }
}
