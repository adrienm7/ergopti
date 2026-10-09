// tools/diagnostics/native_appleevent_probe_sender.c
// Exact kernel-PID private nonce sender for native sandbox admission only.

#include <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <sys/stat.h>
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

/* Signed identity observations are metadata, never an authorization receipt. */
struct SenderIdentityObservation {
    int self_available, target_available;
    int self_team, target_team, team_equal, identifier_equal, hash_equal;
};

static CFDictionaryRef sender_signing_information(pid_t process) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &process);
    if (number == NULL) return NULL;
    const void *keys[] = { kSecGuestAttributePid };
    const void *values[] = { number };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    if (attributes == NULL) return NULL;
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    CFRelease(attributes);
    if (status != errSecSuccess || code == NULL) {
        if (code != NULL) CFRelease(code);
        return NULL;
    }
    SecStaticCodeRef static_code = NULL;
    status = SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &static_code);
    CFRelease(code);
    if (status != errSecSuccess || static_code == NULL) {
        if (static_code != NULL) CFRelease(static_code);
        return NULL;
    }
    CFDictionaryRef information = NULL;
    status = SecCodeCopySigningInformation(static_code, kSecCSSigningInformation, &information);
    CFRelease(static_code);
    if (status != errSecSuccess) {
        if (information != NULL) CFRelease(information);
        return NULL;
    }
    return information;
}

static int sender_identity_equal(CFDictionaryRef self, CFDictionaryRef target,
    CFStringRef key, CFTypeID expected_type) {
    if (self == NULL || target == NULL) return -1;
    CFTypeRef left = CFDictionaryGetValue(self, key), right = CFDictionaryGetValue(target, key);
    if (left == NULL || right == NULL || CFGetTypeID(left) != expected_type ||
        CFGetTypeID(right) != expected_type) return -1;
    return CFEqual(left, right) ? 1 : 0;
}

static struct SenderIdentityObservation observe_sender_identity(pid_t target) {
    CFDictionaryRef self = sender_signing_information(getpid());
    CFDictionaryRef other = sender_signing_information(target);
    struct SenderIdentityObservation observation = {self != NULL, other != NULL, -1, -1, -1, -1, -1};
    if (self != NULL) {
        CFTypeRef team = CFDictionaryGetValue(self, kSecCodeInfoTeamIdentifier);
        observation.self_team = team != NULL && CFGetTypeID(team) == CFStringGetTypeID();
    }
    if (other != NULL) {
        CFTypeRef team = CFDictionaryGetValue(other, kSecCodeInfoTeamIdentifier);
        observation.target_team = team != NULL && CFGetTypeID(team) == CFStringGetTypeID();
    }
    observation.team_equal = sender_identity_equal(self, other, kSecCodeInfoTeamIdentifier, CFStringGetTypeID());
    observation.identifier_equal = sender_identity_equal(self, other, kSecCodeInfoIdentifier, CFStringGetTypeID());
    observation.hash_equal = sender_identity_equal(self, other, kSecCodeInfoUnique, CFDataGetTypeID());
    if (self != NULL) CFRelease(self);
    if (other != NULL) CFRelease(other);
    return observation;
}

/* Actual sender registration is an experiment; it does not grant consent. */
static int admit_sender_appkit(NSApplication *application) {
    if (application == nil) return 1;
    const NSApplicationActivationPolicy initial = [application activationPolicy];
    if (initial != NSApplicationActivationPolicyAccessory &&
        ![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) return 2;
    return [application activationPolicy] == NSApplicationActivationPolicyAccessory ? 0 : 3;
}

static int observe_sender_policy(NSApplication *application) {
    if (application == nil) return -1;
    @try {
        const NSInteger policy = [application activationPolicy];
        return policy >= 0 && policy <= 2 ? (int)policy : -1;
    } @catch (NSException *unavailable) {
        (void)unavailable;
        return -1;
    }
}

/* A separate closed metadata frame never changes nonce/reply admission. */
static void emit_sender_identity(const struct SenderIdentityObservation *identity,
    int before_policy, int after_policy) {
    fprintf(stderr, "OWNED_APPLEEVENT_IDENTITY/1 before=%d after=%d self=%d target=%d self_team=%d target_team=%d team=%d identifier=%d hash=%d\n",
        before_policy, after_policy, identity->self_available, identity->target_available,
        identity->self_team, identity->target_team, identity->team_equal,
        identity->identifier_equal, identity->hash_equal);
}

static const char *owned_second_marker_snapshot(const char *expected_nonce) {
    // Information only: the sender already has the exact owned private cwd.
    // Any ambiguous process-local descriptor retires with this failed sender.
    // No marker observation changes the original send/reply admission result.
    const char *snapshot = "unavailable";
    int directory = -1;
    int descriptor = -1;
    struct stat before_directory;
    struct stat after_directory;
    struct stat before;
    struct stat after;
    int directory_admitted = 0;
    directory = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) return snapshot;
    if (fstat(directory, &before_directory) != 0 ||
        !S_ISDIR(before_directory.st_mode) || before_directory.st_uid != getuid() ||
        (before_directory.st_mode & 0777) != 0700) goto finished;
    directory_admitted = 1;
    descriptor = openat(directory, "appleevent-delivered.2",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) {
        snapshot = errno == ENOENT ? "absent" : errno == ELOOP ? "invalid" : "unavailable";
        goto finished;
    }
    if (fstat(descriptor, &before) != 0) goto finished;
    if (!S_ISREG(before.st_mode) || before.st_uid != getuid() ||
        (before.st_mode & 0777) != 0600 || before.st_nlink != 1 || before.st_size != 36) {
        snapshot = "invalid";
        goto finished;
    }
    char bytes[37];
    const ssize_t count = read(descriptor, bytes, sizeof(bytes));
    if (count < 0 || fstat(descriptor, &after) != 0) goto finished;
    if (count != 36 || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        after.st_uid != getuid() || (after.st_mode & 0777) != 0600 ||
        !S_ISREG(after.st_mode) || after.st_nlink != 1 || after.st_size != 36) {
        snapshot = "invalid";
        goto finished;
    }
    snapshot = memcmp(bytes, expected_nonce, 36) == 0 ? "conforming" : "invalid";
finished:
    if (directory_admitted && (fstat(directory, &after_directory) != 0 ||
        before_directory.st_dev != after_directory.st_dev ||
        before_directory.st_ino != after_directory.st_ino ||
        !S_ISDIR(after_directory.st_mode) || after_directory.st_uid != getuid() ||
        (after_directory.st_mode & 0777) != 0700)) snapshot = "unavailable";
    // Never retry a close or publish marker facts after a refused close.
    // The existing exact sender's physical exit ACK remains mandatory.
    if (descriptor >= 0 && close(descriptor) != 0) snapshot = "unavailable";
    if (close(directory) != 0) snapshot = "unavailable";
    return snapshot;
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
    ProcessSerialNumber serial;
    const OSStatus registration = GetCurrentProcess(&serial);
    if (registration != noErr) {
        fprintf(stderr, "Owned AppleEvent sender current-process registration failed: %d\n", (int)registration);
        return 65;
    }
    NSApplication *application = [NSApplication sharedApplication];
    const int before_policy = observe_sender_policy(application);
    const int admission = admit_sender_appkit(application);
    const int after_policy = observe_sender_policy(application);
    if (admission != 0) {
        const struct SenderIdentityObservation unavailable = {0, 0, -1, -1, -1, -1, -1};
        fprintf(stderr, "Owned AppleEvent sender AppKit admission refused: %d\n", admission);
        emit_sender_identity(&unavailable, before_policy, after_policy);
        return 65;
    }
    const struct SenderIdentityObservation identity = observe_sender_identity(recipient);
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
        emit_sender_identity(&identity, before_policy, after_policy);
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
    int nonce_read_attempted = 0;
    OSStatus nonce_read_status = noErr;
    Size nonce_length = 0;
    int nonce_match = 0;
    int error_read_attempted = 0;
    OSStatus error_read_status = noErr;
    Size error_length = 0;
    SInt32 error_number = 0;
    if (status == noErr) {
        error_read_attempted = 1;
        error_read_status = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32,
            NULL, &error_number, sizeof(SInt32), &error_length);
    }
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
        nonce_read_attempted = nonce_observation.available;
        nonce_read_status = nonce_observation.status;
        nonce_length = nonce_observation.size;
        nonce_match = nonce_observation.matches;
        if (read == noErr && actual_length == 36 && memcmp(echoed, argv[2], 36) == 0) {
            result = 0;
        }
    }
    if (result != 0) {
        fprintf(stderr, "Owned AppleEvent outcome admission failed: %d\n", (int)status);
        emit_sender_diagnostic(status, strcmp(argv[3], "denied") == 0, &nonce_observation, &reply);
        const char *phase = strcmp(argv[3], "denied") == 0 ? "denied-status" :
            status != noErr ? "send" : nonce_read_status != noErr ? "reply-read" :
            nonce_length != 36 ? "reply-length" : "reply-match";
        char read_detail[16] = "unobserved";
        char length_detail[16] = "unobserved";
        char match_detail[16] = "unobserved";
        char error_read_detail[16] = "unobserved";
        char error_length_detail[16] = "unobserved";
        char error_value_detail[16] = "unobserved";
        if (nonce_read_attempted) {
            snprintf(read_detail, sizeof(read_detail), "%d", (int)nonce_read_status);
            if (nonce_read_status == noErr) {
                if (nonce_length >= 0 && nonce_length <= 4096) {
                    snprintf(length_detail, sizeof(length_detail), "%ld", (long)nonce_length);
                } else {
                    strcpy(length_detail, "outside-bound");
                }
                if (nonce_length == 36) {
                    snprintf(match_detail, sizeof(match_detail), "%d", nonce_match);
                }
            }
        }
        if (error_read_attempted) {
            snprintf(error_read_detail, sizeof(error_read_detail), "%d", (int)error_read_status);
            if (error_read_status == noErr) {
                if (error_length >= 0 && error_length <= 4096) {
                    snprintf(error_length_detail, sizeof(error_length_detail), "%ld", (long)error_length);
                } else {
                    strcpy(error_length_detail, "outside-bound");
                }
                if (error_length == sizeof(SInt32)) {
                    snprintf(error_value_detail, sizeof(error_value_detail), "%d", (int)error_number);
                }
            }
        }
        // Snapshot only a failed positive reply; a full-policy denial never
        // acquires this diagnostic. No native policy/permission query is added.
        const int marker_attempted = strcmp(argv[3], "success") == 0 && status == noErr;
        const char *marker_snapshot = marker_attempted ? owned_second_marker_snapshot(argv[2]) : NULL;
        fprintf(stderr, "Owned AppleEvent outcome admission failed: phase=%s, send=%d, read=%s, length=%s, match=%s, error_read=%s, error_length=%s, error_value=%s",
            phase, (int)status, read_detail, length_detail, match_detail,
            error_read_detail, error_length_detail, error_value_detail);
        if (marker_attempted) fprintf(stderr, ", marker2=%s", marker_snapshot);
        fprintf(stderr, "\n");
        emit_sender_identity(&identity, before_policy, after_policy);
        // Observe only this failed positive sender's existing target and event.
        // False forbids a consent prompt; the original refusal remains authoritative.
        if (strcmp(argv[3], "success") == 0) {
            const OSStatus permission = AEDeterminePermissionToAutomateTarget(
                &address, probe_class, probe_event, false);
            printf("OWNED_APPLEEVENT_PERMISSION/1 osstatus=%d\n", (int)permission);
        }
    } else {
        printf("native_appleevent_status=%d\n", (int)status);
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
    return result;
}
