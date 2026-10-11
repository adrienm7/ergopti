// tools/diagnostics/apple_shortcuts_probe/sdk_constants.c
// Emit SDK constants only. Apple event descriptors and permission calls stay in JXA.
#include <CoreServices/CoreServices.h>
#include <ApplicationServices/ApplicationServices.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    int written = printf("{\"event_class\":%" PRIu32 ",\"event_id\":%" PRIu32
                         ",\"target_type\":%" PRIu32 ",\"version\":1}\n",
                         (uint32_t)kAECoreSuite, (uint32_t)kAEGetData,
                         (uint32_t)typeApplicationBundleID);
    return written > 0 && fflush(stdout) == 0 ? 0 : 1;
}
