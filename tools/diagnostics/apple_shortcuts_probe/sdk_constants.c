// tools/diagnostics/apple_shortcuts_probe/sdk_constants.c
// Emit SDK constants, or ask TCC about existing Shortcuts Events consent.
// Neither mode sends an Apple event or can raise an Automation prompt.
#include <CoreServices/CoreServices.h>
#include <ApplicationServices/ApplicationServices.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int emit_constants(void) {
    int written = printf("{\"event_class\":%" PRIu32 ",\"event_id\":%" PRIu32
                         ",\"target_type\":%" PRIu32 ",\"version\":1}\n",
                         (uint32_t)kAECoreSuite, (uint32_t)kAEGetData,
                         (uint32_t)typeApplicationBundleID);
    return written > 0 && fflush(stdout) == 0 ? 0 : 1;
}

// JXA cannot pass an AEDesc pointer to this C API, so the check lives here.
// TCC keys the answer on the responsible process, which this helper shares
// with the osascript catalogue query that run_probe starts afterwards.
static int emit_permission_preflight(void) {
    static const char target[] = "com.apple.shortcuts.events";
    AEAddressDesc address = {typeNull, NULL};
    if (AECreateDesc(typeApplicationBundleID, target, sizeof target - 1, &address) != noErr)
        return 1;
    // askUserIfNeeded=false answers from existing consent only and never prompts.
    // procNotFound (-600) means the target is not running, not a refusal.
    OSStatus status =
        AEDeterminePermissionToAutomateTarget(&address, kAECoreSuite, kAEGetData, false);
    if (AEDisposeDesc(&address) != noErr)
        return 1;
    int written = printf("{\"mode\":\"permission_preflight\",\"status\":%" PRId32
                         ",\"version\":1}\n",
                         (int32_t)status);
    return written > 0 && fflush(stdout) == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 1)
        return emit_constants();
    if (argc == 2 && strcmp(argv[1], "--permission-preflight") == 0)
        return emit_permission_preflight();
    return 2;
}
