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
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static BOOL inspect_window(AXUIElementRef window, NSString *sender, NSString *receiver,
    NSMutableArray *allowButtons, BOOL *targetSeen, BOOL *senderSeen, BOOL *denySeen) {
    NSMutableArray *pending = [NSMutableArray arrayWithObject:(__bridge id)window];
    NSUInteger examined = 0;
    while (pending.count > 0) {
        if (++examined > 256) return NO;
        id item = pending.lastObject;
        [pending removeLastObject];
        AXUIElementRef element = (__bridge AXUIElementRef)item;
        if (CFGetTypeID(element) != AXUIElementGetTypeID()) return NO;
        NSString *role = attribute(element, kAXRoleAttribute);
        if (![role isKindOfClass:[NSString class]]) return NO;
        if ([role isEqualToString:(__bridge NSString *)kAXStaticTextRole]) {
            id value = attribute(element, kAXValueAttribute);
            if (![value isKindOfClass:[NSString class]] || [value length] > 4096) return NO;
            if ([value rangeOfString:sender].location != NSNotFound) *senderSeen = YES;
            if ([value rangeOfString:receiver].location != NSNotFound) *targetSeen = YES;
        }
        if ([role isEqualToString:(__bridge NSString *)kAXButtonRole]) {
            NSString *title = attribute(element, kAXTitleAttribute);
            NSNumber *enabled = attribute(element, kAXEnabledAttribute);
            if (![title isKindOfClass:[NSString class]] || ![enabled isKindOfClass:[NSNumber class]]) return NO;
            if ([title isEqualToString:@"Allow"] && enabled.boolValue) [allowButtons addObject:item];
            if ([title isEqualToString:@"Don't Allow"] || [title isEqualToString:@"Don’t Allow"])
                *denySeen = YES;
        }
        NSArray *children = attribute(element, kAXChildrenAttribute);
        if (children == nil) continue;
        if (![children isKindOfClass:[NSArray class]] || children.count > 256) return NO;
        [pending addObjectsFromArray:children];
    }
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 64;
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
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO})) {
            puts("OWNED_AUTOMATION_UI/1 state=accessibility-unavailable");
            return 67;
        }
        NSSet *agents = [NSSet setWithArray:@[
            @"com.apple.UserNotificationCenter", @"com.apple.CoreServicesUIAgent",
            @"com.apple.SecurityAgent", @"com.apple.universalaccessAuthWarn"]];
        NSMutableArray *approvedButtons = [NSMutableArray array];
        NSMutableArray *approvedApplications = [NSMutableArray array];
        BOOL targetUnqualified = NO;
        BOOL observationRefused = NO;
        NSArray *applications = NSWorkspace.sharedWorkspace.runningApplications;
        if (applications.count > 512) return 68;
        for (NSRunningApplication *application in applications) {
            if (![agents containsObject:application.bundleIdentifier] ||
                application.processIdentifier <= 0 || !apple_signed_process(application)) continue;
            AXUIElementRef process = AXUIElementCreateApplication(application.processIdentifier);
            if (process == NULL) { observationRefused = YES; continue; }
            AXUIElementSetMessagingTimeout(process, 0.5);
            NSArray *windows = attribute(process, kAXWindowsAttribute);
            CFRelease(process);
            if (![windows isKindOfClass:[NSArray class]] || windows.count > 8) {
                observationRefused = YES;
                continue;
            }
            for (id item in windows) {
                AXUIElementRef window = (__bridge AXUIElementRef)item;
                if (CFGetTypeID(window) != AXUIElementGetTypeID()) { observationRefused = YES; continue; }
                AXUIElementSetMessagingTimeout(window, 0.5);
                NSMutableArray *buttons = [NSMutableArray array];
                BOOL targetSeen = NO, senderSeen = NO, denySeen = NO;
                if (!inspect_window(window, sender, receiver, buttons, &targetSeen, &senderSeen, &denySeen)) {
                    observationRefused = YES;
                    continue;
                }
                if (!targetSeen) continue;
                if (!senderSeen || !denySeen || buttons.count != 1) {
                    targetUnqualified = YES;
                    continue;
                }
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
