// tools/diagnostics/native_appleevent_registration_test.m
// Actual receiver admission body with controlled Objective-C policy responses.

#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <ApplicationServices/ApplicationServices.h>
#define main fixture_receiver_entrypoint
#include "native_appleevent_probe_receiver.c"
#undef main
#include <assert.h>

@interface RegistrationProbe : NSObject
@property(nonatomic) BOOL acceptsPolicy;
@property(nonatomic) NSApplicationActivationPolicy initialPolicy;
@property(nonatomic) NSApplicationActivationPolicy observedPolicy;
@property(nonatomic) unsigned int setCalls;
@property(nonatomic) unsigned int readCalls;
@end

@implementation RegistrationProbe
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy {
    assert(policy == NSApplicationActivationPolicyAccessory);
    self.setCalls += 1;
    return self.acceptsPolicy;
}
- (NSApplicationActivationPolicy)activationPolicy {
    self.readCalls += 1;
    return self.readCalls == 1 ? self.initialPolicy : self.observedPolicy;
}
@end

/* Real SDK descriptor construction only: no send, handler, consent or delivery. */
static void assert_private_probe_event(void) {
    assert(probe_class == ERGOPTI_PROBE_EVENT_CLASS);
    assert(probe_event == ERGOPTI_PROBE_EVENT_ID);
    assert(probe_class != kCoreEventClass);
    assert(probe_event != kAEOpenApplication && probe_event != kAEOpenDocuments &&
        probe_event != kAEPrintDocuments && probe_event != kAEQuitApplication);
    const pid_t target = getpid();
    const char nonce[] = "54bc7a36-e2f0-43f8-917e-ce3d286d7520";
    AEAddressDesc address = {typeNull, NULL};
    AppleEvent event = {typeNull, NULL};
    assert(AECreateDesc(typeKernelProcessID, &target, sizeof(target), &address) == noErr);
    assert(AECreateAppleEvent(probe_class, probe_event, &address,
        kAutoGenerateReturnID, kAnyTransactionID, &event) == noErr);
    AEEventClass actual_class = 0;
    AEEventID actual_event = 0;
    Size bytes = 0;
    assert(AEGetAttributePtr(&event, keyEventClassAttr, typeType, NULL,
        &actual_class, sizeof(actual_class), &bytes) == noErr);
    assert(bytes == sizeof(actual_class) && actual_class == ERGOPTI_PROBE_EVENT_CLASS);
    assert(AEGetAttributePtr(&event, keyEventIDAttr, typeType, NULL,
        &actual_event, sizeof(actual_event), &bytes) == noErr);
    assert(bytes == sizeof(actual_event) && actual_event == ERGOPTI_PROBE_EVENT_ID);
    assert(AEPutParamPtr(&event, nonce_parameter, typeUTF8Text, nonce, 36) == noErr);
    char echoed[37] = {0};
    assert(AEGetParamPtr(&event, nonce_parameter, typeUTF8Text, NULL,
        echoed, 36, &bytes) == noErr);
    assert(bytes == 36 && memcmp(echoed, nonce, 36) == 0);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
}

int main(void) {
    @autoreleasepool {
        assert(admit_appkit(nil) == AppKitApplicationMissing);
        RegistrationProbe *refused = [RegistrationProbe new];
        refused.initialPolicy = NSApplicationActivationPolicyRegular;
        refused.acceptsPolicy = NO;
        refused.observedPolicy = NSApplicationActivationPolicyAccessory;
        assert(admit_appkit((NSApplication *)refused) == AppKitPolicyRefused);
        assert(refused.setCalls == 1 && refused.readCalls == 1);
        RegistrationProbe *unconfirmed = [RegistrationProbe new];
        unconfirmed.initialPolicy = NSApplicationActivationPolicyRegular;
        unconfirmed.acceptsPolicy = YES;
        unconfirmed.observedPolicy = NSApplicationActivationPolicyRegular;
        assert(admit_appkit((NSApplication *)unconfirmed) == AppKitPolicyUnconfirmed);
        assert(unconfirmed.setCalls == 1 && unconfirmed.readCalls == 2);
        RegistrationProbe *admitted = [RegistrationProbe new];
        admitted.initialPolicy = NSApplicationActivationPolicyRegular;
        admitted.acceptsPolicy = YES;
        admitted.observedPolicy = NSApplicationActivationPolicyAccessory;
        assert(admit_appkit((NSApplication *)admitted) == AppKitAdmitted);
        assert(admitted.setCalls == 1 && admitted.readCalls == 2);
        // Literal same-state controls run the actual included admission body.
        // A refused setter must never be invoked when state is already correct.
        RegistrationProbe *alreadyAccessory = [RegistrationProbe new];
        alreadyAccessory.initialPolicy = NSApplicationActivationPolicyAccessory;
        alreadyAccessory.acceptsPolicy = NO;
        alreadyAccessory.observedPolicy = NSApplicationActivationPolicyAccessory;
        assert(admit_appkit((NSApplication *)alreadyAccessory) == AppKitAdmitted);
        assert(alreadyAccessory.setCalls == 0 && alreadyAccessory.readCalls == 2);
        RegistrationProbe *changedAccessory = [RegistrationProbe new];
        changedAccessory.initialPolicy = NSApplicationActivationPolicyAccessory;
        changedAccessory.acceptsPolicy = NO;
        changedAccessory.observedPolicy = NSApplicationActivationPolicyRegular;
        assert(admit_appkit((NSApplication *)changedAccessory) == AppKitPolicyUnconfirmed);
        assert(changedAccessory.setCalls == 0 && changedAccessory.readCalls == 2);
        assert_private_probe_event();
        puts("native_appkit_registration_controls=6");
        puts("native_private_appleevent_controls=1");
        return 0;
    }
}
