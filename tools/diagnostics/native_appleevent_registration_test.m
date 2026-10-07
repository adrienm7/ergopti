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
        puts("native_appkit_registration_controls=6");
        return 0;
    }
}
