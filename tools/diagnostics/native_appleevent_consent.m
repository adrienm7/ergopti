// tools/diagnostics/native_appleevent_consent.m
// Approve only an Apple-signed OS consent window naming both private fixtures.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#include <stdio.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <string.h>

// Bounded facts go only to a separately reserved private regular file. The
// original stdout state and every consent qualification remain unchanged.
static int factDescriptor = -1;
static char *factPath = NULL;
static struct stat factIdentity;
static BOOL factTrusted = NO, factRequester = NO;
static int factAgent = -1, factScanned = 0, factWindows = 0, factNodes = 0;
static int factCandidates = 0, factMatches = 0, factError = 0;
static const char *factAttribute = "none", *factType = "none";
static AXError attributeError = kAXErrorSuccess;
static BOOL factButtonObserved = NO;
static int factButtonError = 0;
static const char *factButtonSubrole = "absent", *factButtonType = "absent";

static const char *kind(id value) {
    if (value == nil) return "absent";
    if (CFGetTypeID((__bridge CFTypeRef)value) == AXUIElementGetTypeID()) return "ax-element";
    if ([value isKindOfClass:[NSString class]]) return "string";
    if ([value isKindOfClass:[NSArray class]]) return "array";
    if ([value isKindOfClass:[NSNumber class]]) return "number";
    return "other";
}

static void refused_fact(int agent, const char *key, id value, AXError error) {
    if (strcmp(factAttribute, "none") != 0) return;
    factAgent = agent;
    factAttribute = key;
    factType = kind(value);
    factError = (int)error;
}

static void publish_facts(void) {
    if (factDescriptor < 0) return;
    struct stat named;
    if (lstat(factPath, &named) == 0 && named.st_dev == factIdentity.st_dev &&
        named.st_ino == factIdentity.st_ino) {
        char buttonPacket[256] = "";
        if (factButtonObserved) {
            int buttonLength = snprintf(buttonPacket, sizeof(buttonPacket),
                ",\"first_button\":{\"schema\":1,\"subrole\":\"%s\","
                "\"type\":\"%s\",\"error\":%d}",
                factButtonSubrole, factButtonType, factButtonError);
            if (buttonLength <= 0 || buttonLength >= (int)sizeof(buttonPacket)) buttonPacket[0] = '\0';
        }
        char packet[1024];
        int length = snprintf(packet, sizeof(packet),
            "{\"schema\":1,\"ax_trusted\":%s,\"requester_qualified\":%s,"
            "\"scanned_agents\":%d,\"windows\":%d,\"nodes\":%d,\"candidates\":%d,"
            "\"matches\":%d,\"first_agent\":%d,\"first_attribute\":\"%s\","
            "\"first_type\":\"%s\",\"first_error\":%d%s}\n",
            factTrusted ? "true" : "false", factRequester ? "true" : "false",
            factScanned, factWindows, factNodes, factCandidates, factMatches,
            factAgent, factAttribute, factType, factError, buttonPacket);
        if (length > 0 && length < (int)sizeof(packet)) {
            size_t offset = 0;
            while (offset < (size_t)length) {
                ssize_t count = write(factDescriptor, packet + offset, length - offset);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                offset += (size_t)count;
            }
            if (offset == (size_t)length) (void)fsync(factDescriptor);
        }
    }
    close(factDescriptor);
    free(factPath);
}

static BOOL prepare_facts(const char *path) {
    factDescriptor = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (factDescriptor < 0) return NO;
    struct stat named;
    if (fstat(factDescriptor, &factIdentity) != 0 || lstat(path, &named) != 0 ||
        !S_ISREG(factIdentity.st_mode) || factIdentity.st_uid != geteuid() ||
        (factIdentity.st_mode & 0777) != 0600 || factIdentity.st_size != 0 ||
        factIdentity.st_nlink != 1 || named.st_dev != factIdentity.st_dev ||
        named.st_ino != factIdentity.st_ino) {
        close(factDescriptor); factDescriptor = -1; return NO;
    }
    factPath = strdup(path);
    if (factPath == NULL || atexit(publish_facts) != 0) {
        close(factDescriptor); factDescriptor = -1; free(factPath); return NO;
    }
    return YES;
}

static BOOL same_signed_sender(pid_t pid, NSString *name) {
    SecCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    NSString *identifier = nil;
    NSString *expected = [@"com.ergopti.private.appleevent.sender."
        stringByAppendingString:[name substringFromIndex:[@"Owned AppleEvent sender " length]]];
    BOOL admitted = NO;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes,
        kSecCSDefaultFlags, &code) != errSecSuccess) goto done;
    if (SecCodeCheckValidity(code, kSecCSStrictValidate, NULL) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation,
        &information) != errSecSuccess) goto done;
    identifier = ((__bridge NSDictionary *)information)[(__bridge NSString *)kSecCodeInfoIdentifier];
    admitted = [identifier isEqualToString:expected];
done:
    if (information != NULL) CFRelease(information);
    if (code != NULL) CFRelease(code);
    return admitted;
}

static BOOL owned_name(NSString *value, NSString *role) {
    NSString *prefix = [@"Owned AppleEvent " stringByAppendingString:role];
    prefix = [prefix stringByAppendingString:@" "];
    if (![value hasPrefix:prefix]) return NO;
    NSString *nonce = [value substringFromIndex:prefix.length];
    NSUUID *identity = [[NSUUID alloc] initWithUUIDString:nonce];
    return identity != nil && [identity.UUIDString.lowercaseString isEqualToString:nonce];
}

static BOOL apple_signed_process(NSRunningApplication *application) {
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    SecRequirementRef designated = NULL;
    CFDictionaryRef information = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(application.processIdentifier)};
    BOOL admitted = NO;
    NSString *identifier = nil;
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes,
        kSecCSDefaultFlags, &code) != errSecSuccess) goto done;
    if (SecRequirementCreateWithString(CFSTR("anchor apple"), kSecCSDefaultFlags,
        &requirement) != errSecSuccess) goto done;
    if (SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) != errSecSuccess) goto done;
    if (SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &designated) != errSecSuccess) goto done;
    if (SecCodeCheckValidity(code, kSecCSStrictValidate, designated) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation,
        &information) != errSecSuccess) goto done;
    identifier = ((__bridge NSDictionary *)information)[(__bridge NSString *)kSecCodeInfoIdentifier];
    admitted = [identifier isEqualToString:application.bundleIdentifier];
done:
    if (information != NULL) CFRelease(information);
    if (requirement != NULL) CFRelease(requirement);
    if (designated != NULL) CFRelease(designated);
    if (code != NULL) CFRelease(code);
    return admitted;
}

static id attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    attributeError = AXUIElementCopyAttributeValue(element, key, &value);
    if (attributeError != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

// Observe only the same first refused button. These fixed facts never
// authorize a button, alter the original refusal or disclose a UI string.
static void observe_refused_button(AXUIElementRef element) {
    id value = attribute(element, kAXSubroleAttribute);
    factButtonError = (int)attributeError;
    factButtonType = kind(value);
    if (value == nil) factButtonSubrole = "absent";
    else if (![value isKindOfClass:[NSString class]]) factButtonSubrole = "wrong-type";
    else if ([value isEqualToString:(__bridge NSString *)kAXCloseButtonSubrole]) factButtonSubrole = "close";
    else if ([value isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole]) factButtonSubrole = "minimize";
    else if ([value isEqualToString:(__bridge NSString *)kAXZoomButtonSubrole]) factButtonSubrole = "zoom";
    else factButtonSubrole = "unknown";
    factButtonObserved = YES;
}

static BOOL inspect_window(AXUIElementRef window, NSString *sender, NSString *receiver,
    NSMutableArray *allowButtons, BOOL *targetSeen, BOOL *senderSeen, BOOL *denySeen, int agent) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:(__bridge id)window];
    NSUInteger examined = 0;
    while (pending.count > 0) {
        if (++examined > 256) { refused_fact(agent, "node-limit", nil, kAXErrorSuccess); return NO; }
        factNodes++;
        id item = pending.lastObject;
        [pending removeLastObject];
        AXUIElementRef element = (__bridge AXUIElementRef)item;
        if (CFGetTypeID(element) != AXUIElementGetTypeID()) { refused_fact(agent, "node-type", item, kAXErrorSuccess); return NO; }
        NSString *role = attribute(element, kAXRoleAttribute);
        if (![role isKindOfClass:[NSString class]]) { refused_fact(agent, "role", role, attributeError); return NO; }
        if ([role isEqualToString:(__bridge NSString *)kAXStaticTextRole]) {
            id value = attribute(element, kAXValueAttribute);
            if (![value isKindOfClass:[NSString class]] || [value length] > 4096) { refused_fact(agent, "value", value, attributeError); return NO; }
            if ([value rangeOfString:sender].location != NSNotFound) *senderSeen = YES;
            if ([value rangeOfString:receiver].location != NSNotFound) *targetSeen = YES;
        }
        if ([role isEqualToString:(__bridge NSString *)kAXButtonRole]) {
            NSString *title = attribute(element, kAXTitleAttribute);
            AXError titleError = attributeError;
            NSNumber *enabled = attribute(element, kAXEnabledAttribute);
            if (![title isKindOfClass:[NSString class]]) {
                BOOL firstButton = strcmp(factAttribute, "none") == 0 && factDescriptor >= 0;
                refused_fact(agent, "button-title", title, titleError);
                if (firstButton) observe_refused_button(element);
                return NO;
            }
            if (![enabled isKindOfClass:[NSNumber class]]) { refused_fact(agent, "button-enabled", enabled, attributeError); return NO; }
            if ([title isEqualToString:@"Allow"] && enabled.boolValue) [allowButtons addObject:item];
            if ([title isEqualToString:@"Don't Allow"] || [title isEqualToString:@"Don’t Allow"])
                *denySeen = YES;
        }
        NSArray *children = attribute(element, kAXChildrenAttribute);
        if (children == nil) continue;
        if (![children isKindOfClass:[NSArray class]] || children.count > 256) { refused_fact(agent, "children", children, attributeError); return NO; }
        [pending addObjectsFromArray:children];
    }
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4 && argc != 5) return 64;
        if (argc == 5 && !prepare_facts(argv[4])) return 68;
        NSString *sender = [NSString stringWithUTF8String:argv[1]];
        NSString *receiver = [NSString stringWithUTF8String:argv[2]];
        if (!owned_name(sender, @"sender") || !owned_name(receiver, @"receiver")) return 64;
        if (![[sender substringFromIndex:[@"Owned AppleEvent sender " length]]
            isEqualToString:[receiver substringFromIndex:[@"Owned AppleEvent receiver " length]]]) return 64;
        errno = 0;
        char *end = NULL;
        long parsed = strtol(argv[3], &end, 10);
        if (errno != 0 || end == argv[3] || *end != '\0' || parsed <= 0 ||
            parsed > INT_MAX || parsed == getpid()) return 64;
        pid_t requester = (pid_t)parsed;
        if (!same_signed_sender(requester, sender)) {
            puts("OWNED_AUTOMATION_UI/1 state=requester-unavailable");
            return 67;
        }
        factRequester = YES;
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO})) {
            puts("OWNED_AUTOMATION_UI/1 state=accessibility-unavailable");
            return 67;
        }
        factTrusted = YES;
        NSArray *agentNames = @[
            @"com.apple.UserNotificationCenter", @"com.apple.CoreServicesUIAgent",
            @"com.apple.SecurityAgent", @"com.apple.universalaccessAuthWarn"];
        NSSet *agents = [NSSet setWithArray:agentNames];
        NSMutableArray *approvedButtons = [NSMutableArray array];
        NSMutableArray *approvedApplications = [NSMutableArray array];
        BOOL targetUnqualified = NO;
        BOOL observationRefused = NO;
        BOOL observationPending = NO;
        NSArray *applications = NSWorkspace.sharedWorkspace.runningApplications;
        if (applications.count > 512) return 68;
        for (NSRunningApplication *application in applications) {
            if (![agents containsObject:application.bundleIdentifier] ||
                application.processIdentifier <= 0 || !apple_signed_process(application)) continue;
            int agentIndex = (int)[agentNames indexOfObject:application.bundleIdentifier];
            factScanned++;
            AXUIElementRef process = AXUIElementCreateApplication(application.processIdentifier);
            if (process == NULL) { refused_fact(agentIndex, "application", nil, kAXErrorFailure); observationRefused = YES; continue; }
            AXUIElementSetMessagingTimeout(process, 0.5);
            NSArray *windows = attribute(process, kAXWindowsAttribute);
            CFRelease(process);
            if (![windows isKindOfClass:[NSArray class]] || windows.count > 8) {
                refused_fact(agentIndex, "windows", windows, attributeError);
                // A newly appearing OS agent can fail its first AX IPC. Keep
                // that observation pending within the requester's original
                // deadline; no partially observed census may press a button.
                if (windows == nil && attributeError == kAXErrorCannotComplete)
                    observationPending = YES;
                else
                    observationRefused = YES;
                continue;
            }
            factWindows += (int)windows.count;
            for (id item in windows) {
                AXUIElementRef window = (__bridge AXUIElementRef)item;
                if (CFGetTypeID(window) != AXUIElementGetTypeID()) { refused_fact(agentIndex, "window-type", item, kAXErrorSuccess); observationRefused = YES; continue; }
                AXUIElementSetMessagingTimeout(window, 0.5);
                NSMutableArray *buttons = [NSMutableArray array];
                BOOL targetSeen = NO, senderSeen = NO, denySeen = NO;
                if (!inspect_window(window, sender, receiver, buttons, &targetSeen, &senderSeen, &denySeen, agentIndex)) {
                    observationRefused = YES;
                    continue;
                }
                if (!targetSeen) continue;
                factCandidates++;
                if (!senderSeen || !denySeen || buttons.count != 1) {
                    targetUnqualified = YES;
                    continue;
                }
                factMatches++;
                [approvedButtons addObjectsFromArray:buttons];
                [approvedApplications addObject:application];
            }
        }
        if (targetUnqualified || approvedButtons.count > 1) {
            puts("OWNED_AUTOMATION_UI/1 state=identity-unqualified");
            return 67;
        }
        if (observationRefused) {
            puts("OWNED_AUTOMATION_UI/1 state=observation-refused");
            return 67;
        }
        if (observationPending) {
            puts("OWNED_AUTOMATION_UI/1 state=observation-pending");
            return 0;
        }
        if (approvedButtons.count == 0) {
            puts("OWNED_AUTOMATION_UI/1 state=absent");
            return 0;
        }
        NSRunningApplication *agent = approvedApplications[0];
        if (agent.terminated || !apple_signed_process(agent) || !same_signed_sender(requester, sender)) {
            puts("OWNED_AUTOMATION_UI/1 state=requester-unavailable");
            return 67;
        }
        AXError result = AXUIElementPerformAction((__bridge AXUIElementRef)approvedButtons[0], kAXPressAction);
        if (result != kAXErrorSuccess) {
            puts("OWNED_AUTOMATION_UI/1 state=approval-refused");
            return 67;
        }
        // This is a button action only; fresh native permission and both actual
        // nonce deliveries independently determine whether consent was granted.
        puts("OWNED_AUTOMATION_UI/1 state=pressed");
        return 0;
    }
}
