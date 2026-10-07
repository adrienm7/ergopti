// tools/diagnostics/native_appleevent_probe_sender.c
// Exact kernel-PID private nonce sender for native sandbox admission only.

#include <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#include <Security/Security.h>
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

static const char *sender_observed_boolean(int value) {
    return value < 0 ? "null" : (value ? "true" : "false");
}

/* Actual sender registration is an experiment; it does not grant consent. */
static int admit_sender_appkit(NSApplication *application) {
    if (application == nil) return 1;
    if ([application activationPolicy] == NSApplicationActivationPolicyAccessory) return 0;
    if (![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) return 2;
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

/* Fixed scalar diagnostics only; neither reply contents nor target identity escape. */
struct ProbeNonceObservation {
    int available;
    OSStatus status;
    Size size;
    int matches;
};

static void emit_sender_diagnostic(OSStatus send_status, int denied,
    const struct ProbeNonceObservation *nonce, const AppleEvent *reply,
    const struct SenderIdentityObservation *identity, int before_policy, int after_policy) {
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
    char diagnostic[1024];
    const int length = snprintf(diagnostic, sizeof(diagnostic),
        "Owned AppleEvent sender diagnostic: {\"schema\":1,\"mode\":%d,\"send_status\":%d,"
        "\"nonce_read_available\":%s,\"nonce_read_status\":%s,\"nonce_size\":%s,\"nonce_match\":%s,"
        "\"reply_type\":%u,\"error_read_available\":%s,\"error_read_status\":%s,"
        "\"error_type\":%s,\"error_size\":%s,\"error_available\":%s,\"error_number\":%s,"
        "\"identity\":{\"self_available\":%s,\"target_available\":%s,\"self_team\":%s,\"target_team\":%s,"
        "\"team_equal\":%s,\"identifier_equal\":%s,\"hash_equal\":%s},"
        "\"appkit_before\":%d,\"appkit_after\":%d}\n",
        denied ? 2 : 1, (int)send_status, nonce->available ? "true" : "false",
        nonce_status, nonce_size, nonce->available ? (nonce->matches ? "true" : "false") : "null",
        (unsigned int)reply->descriptorType, error_read ? "true" : "false", error_status,
        error_type, error_size, error_available ? "true" : "false", error_number,
        sender_observed_boolean(identity->self_available), sender_observed_boolean(identity->target_available),
        sender_observed_boolean(identity->self_team), sender_observed_boolean(identity->target_team),
        sender_observed_boolean(identity->team_equal), sender_observed_boolean(identity->identifier_equal),
        sender_observed_boolean(identity->hash_equal), before_policy, after_policy);
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
        fprintf(stderr, "Owned AppleEvent sender AppKit admission refused: %d\n", admission);
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
        emit_sender_diagnostic(status, strcmp(argv[3], "denied") == 0, &nonce_observation, &reply,
            &identity, before_policy, after_policy);
    } else {
        printf("native_appleevent_status=%d\n", (int)status);
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
    return result;
}
