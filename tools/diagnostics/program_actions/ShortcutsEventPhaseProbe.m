// tools/diagnostics/program_actions/ShortcutsEventPhaseProbe.m
// Readonly endpoint comparators. This sender is NOT the old osascript sender.
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import <Security/Security.h>
#import <mach/message.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSString *const endpoint = @"com.apple.shortcuts.events";
static NSUInteger records = 0;

static void marker(const char *phase, int32_t value) {
	char line[96];
	if (++records > 24) _exit(74);
	int length = snprintf(line, sizeof(line), "EP1 %s %d\n", phase, value);
	if (length <= 0 || length >= sizeof(line)) _exit(74);
	NSUInteger written = 0;
	while (written < length) {
		ssize_t result = write(STDOUT_FILENO, line + written, length - written);
		if (result < 0 && errno == EINTR) continue;
		if (result <= 0) _exit(74);
		written += result;
	}
}

static BOOL exactAttribute(const AppleEvent *event, AEKeyword key, DescType expected, void *value, Size size) {
	AEDesc desc = {typeNull, NULL};
	OSStatus status = AEGetAttributeDesc(event, key, typeWildCard, &desc);
	BOOL valid = status == noErr && desc.descriptorType == expected && AEGetDescDataSize(&desc) == size && AEGetDescData(&desc, value, size) == noErr;
	AEDisposeDesc(&desc); return valid;
}

static BOOL exactError(const AppleEvent *reply, int32_t *value) {
	AEDesc desc = {typeNull, NULL};
	OSStatus status = AEGetParamDesc(reply, keyErrorNumber, typeWildCard, &desc);
	BOOL valid = status == errAEDescNotFound || (status == noErr && desc.descriptorType == typeSInt32 && AEGetDescDataSize(&desc) == sizeof(*value) && AEGetDescData(&desc, value, sizeof(*value)) == noErr);
	if (status == errAEDescNotFound) *value = 0;
	AEDisposeDesc(&desc); return valid;
}

static BOOL appleCode(SecCodeRef code, SecRequirementRef requirement) {
	if (SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) != errSecSuccess) return NO;
	CFDictionaryRef information = NULL;
	if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) != errSecSuccess) return NO;
	NSDictionary *values = CFBridgingRelease(information);
	return [values[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:endpoint];
}

static BOOL applePID(pid_t pid, SecRequirementRef requirement) {
	if (pid <= 0) return NO;
	SecCodeRef code = NULL;
	NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
	if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess) return NO;
	BOOL valid = appleCode(code, requirement);
	CFRelease(code);
	return valid;
}

static BOOL appleReplyAudit(const AppleEvent *reply, SecRequirementRef requirement) {
	audit_token_t token;
	if (!exactAttribute(reply, keySenderAuditTokenAttr, typeAuditToken, &token, sizeof(token))) return NO;
	SecCodeRef code = NULL;
	NSData *audit = [NSData dataWithBytes:&token length:sizeof(token)];
	NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit: audit};
	if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess) return NO;
	BOOL valid = appleCode(code, requirement); CFRelease(code); return valid;
}

static BOOL validEndpoint(NSURL *url, SecRequirementRef requirement) {
	if (!url.isFileURL || ![[NSBundle bundleWithURL:url].bundleIdentifier isEqual:endpoint]) return NO;
	SecStaticCodeRef code = NULL;
	if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) != errSecSuccess) return NO;
	OSStatus status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, requirement);
	CFRelease(code);
	return status == errSecSuccess;
}

static int32_t runningTarget(NSURL *url, SecRequirementRef requirement) {
	NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:endpoint];
	if (apps.count > 16) return 2; // Unknown bounded census, not a running verdict.
	for (NSRunningApplication *app in apps) {
		if ([app.bundleURL.URLByResolvingSymlinksInPath isEqual:url.URLByResolvingSymlinksInPath] && applePID(app.processIdentifier, requirement)) return 1;
	}
	return 0; // Absence of this observation does not prove that all services are absent.
}

static OSStatus rawVersion(const AEAddressDesc *target, SecRequirementRef requirement) {
	AEDesc container = {typeNull, NULL}, key = {typeNull, NULL}, object = {typeNull, NULL};
	AppleEvent request = {typeNull, NULL}, reply = {typeNull, NULL};
	DescType property = pVersion;
	OSStatus status = AECreateDesc(typeType, &property, sizeof(property), &key);
	if (status == noErr) status = CreateObjSpecifier(cProperty, &container, formPropertyID, &key, false, &object);
	if (status == noErr) status = AECreateAppleEvent(kAECoreSuite, kAEGetData, target, kAutoGenerateReturnID, kAnyTransactionID, &request);
	if (status == noErr) status = AEPutParamDesc(&request, keyDirectObject, &object);
	AEReturnID requestID = 0;
	if (status == noErr && !exactAttribute(&request, keyReturnIDAttr, typeSInt16, &requestID, sizeof(requestID))) status = -1700;
	if (status != noErr) {
		marker("REQUEST_REFUSED", status == noErr ? -1700 : status);
	} else {
		marker("RAW_SEND_ENTER", 0);
		status = AESendMessage(&request, &reply, kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent, 15 * 60);
		marker("RAW_SEND_RETURN", status);
		if (status == noErr) {
			AEReturnID replyID = 0;
			BOOL correlated = reply.descriptorType == typeAppleEvent && exactAttribute(&reply, keyReturnIDAttr, typeSInt16, &replyID, sizeof(replyID)) && requestID == replyID;
			marker("REPLY_CORRELATED", correlated);
			int32_t error = 0;
			BOOL errorShape = exactError(&reply, &error);
			marker("REPLY_ERROR_SHAPE", errorShape);
			marker("REPLY_ERROR", error);
			// Native audit token binds the sender generation, not a reusable PID alone.
			// Never read or export the direct-object value or audit-token bytes.
			BOOL service = correlated && errorShape && appleReplyAudit(&reply, requirement);
			marker("SERVICE_REPLY", service);
		}
	}
	AEDisposeDesc(&reply); AEDisposeDesc(&request); AEDisposeDesc(&object); AEDisposeDesc(&key);
	return status;
}

@interface SBApplication (ReadonlyShortcuts)
- (SBElementArray *)shortcuts;
@end

@interface PhaseDelegate : NSObject <SBApplicationDelegate>
@property int32_t failure;
@property BOOL failed;
@end
@implementation PhaseDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
	(void)event;
	self.failed = YES;
	self.failure = [error.domain isEqual:NSOSStatusErrorDomain] && error.code >= INT32_MIN && error.code <= INT32_MAX ? (int32_t)error.code : -1700;
	return nil; // Never replace a failure with an invented native value.
}
@end

static void sbCount(void) {
	marker("SB_CONSTRUCT_ENTER", 0);
	SBApplication *app = [SBApplication applicationWithBundleIdentifier:endpoint];
	marker("SB_CONSTRUCT_RETURN", app != nil);
	if (!app) return;
	PhaseDelegate *delegate = [PhaseDelegate new];
	app.delegate = delegate;
	app.sendMode = kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent;
	app.timeout = 15 * 60;
	marker("SB_COLLECTION_ENTER", 0);
	SBElementArray *collection = [app shortcuts];
	marker("SB_COLLECTION_RETURN", collection != nil);
	if (collection != nil && !delegate.failed) {
		marker("SB_COUNT_ENTER", 0);
		(void)collection.count; // Only count is requested; opaque bridge allocation remains unproved.
		marker("SB_COUNT_RETURN", !delegate.failed);
	}
	marker("SB_FAILED", delegate.failed);
	marker("SB_ERROR", delegate.failed ? delegate.failure : 0);
}

#if defined(ERGOPTI_PHASE_FIXTURE)
static BOOL fixtureHandled = NO;
static OSErr fixtureReply(const AppleEvent *event, AppleEvent *reply, SRefCon context) {
	(void)event; (void)context;
	fixtureHandled = YES;
	int32_t value = 7;
	return AEPutParamPtr(reply, keyDirectObject, typeSInt32, &value, sizeof(value));
}
static int nativeFixture(void) {
	marker("FIXTURE", 1);
	ProcessSerialNumber self = {0, kCurrentProcess};
	AEAddressDesc target = {typeNull, NULL};
	AppleEvent request = {typeNull, NULL}, reply = {typeNull, NULL};
	AEEventHandlerUPP handler = NewAEEventHandlerUPP(fixtureReply);
	OSStatus status = AEInstallEventHandler(kAECoreSuite, kAEGetData, handler, 0, false);
	if (status == noErr) status = AECreateDesc(typeProcessSerialNumber, &self, sizeof(self), &target);
	if (status == noErr) status = AECreateAppleEvent(kAECoreSuite, kAEGetData, &target, kAutoGenerateReturnID, kAnyTransactionID, &request);
	if (status == noErr) status = AESendMessage(&request, &reply, kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent, 15 * 60);
	marker("FIXTURE_STATUS", status); marker("FIXTURE_HANDLER", fixtureHandled);
	AERemoveEventHandler(kAECoreSuite, kAEGetData, handler, false); DisposeAEEventHandlerUPP(handler);
	AEDisposeDesc(&reply); AEDisposeDesc(&request); AEDisposeDesc(&target);
	return status == noErr && fixtureHandled ? 0 : 1;
}
#endif

int main(int argc, const char *argv[]) {
	@autoreleasepool {
#if defined(ERGOPTI_PHASE_FIXTURE)
		if (argc == 2 && strcmp(argv[1], "native-fixture") == 0) return nativeFixture();
#endif
		if (argc != 2 || (strcmp(argv[1], "raw-version") != 0 && strcmp(argv[1], "sb-count") != 0)) return 64;
		marker("START", strcmp(argv[1], "raw-version") == 0 ? 1 : 2);
		SecRequirementRef requirement = NULL;
		OSStatus status = SecRequirementCreateWithString(CFSTR("anchor apple"), kSecCSDefaultFlags, &requirement);
		NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:endpoint];
		BOOL verified = status == errSecSuccess && validEndpoint(url, requirement);
		marker("ENDPOINT", verified);
		if (!verified) { if (requirement) CFRelease(requirement); marker("END", 0); return 0; }
		marker("RUNNING_BEFORE", runningTarget(url, requirement));
		const char *identifier = "com.apple.shortcuts.events";
		AEAddressDesc target = {typeNull, NULL};
		status = AECreateDesc(typeApplicationBundleID, identifier, strlen(identifier), &target);
		if (status != noErr) { marker("REQUEST_REFUSED", status); marker("END", 0); CFRelease(requirement); return 0; }
		marker("PREFLIGHT_ENTER", 0);
		status = AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, false);
		marker("PREFLIGHT_RETURN", status);
		// This comparator sends only a fixed readonly request with no-prompt flags.
		// Preflight is an observation, not consent for any product operation.
		if (strcmp(argv[1], "raw-version") == 0) rawVersion(&target, requirement); else sbCount();
		marker("RUNNING_AFTER", runningTarget(url, requirement));
		AEDisposeDesc(&target); CFRelease(requirement); marker("END", 0);
		return 0;
	}
}
