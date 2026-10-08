// tools/diagnostics/native_appleevent_permission.c
// Public Automation consent request linked into the exact owned sender identity.

#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

struct permission_request {
    const AEAddressDesc *target;
    AEEventClass event_class;
    AEEventID event_id;
    bool ask;
    OSStatus status;
};

static void *query_permission(void *value) {
    struct permission_request *request = value;
    // Apple's API may wait indefinitely for consent and forbids the main thread.
    // The native child owner bounds the entire process, including this worker.
    request->status = AEDeterminePermissionToAutomateTarget(
        request->target, request->event_class, request->event_id, request->ask);
    return NULL;
}

int owned_appleevent_permission(const AEAddressDesc *target,
    AEEventClass event_class, AEEventID event_id, bool ask) {
    struct permission_request request = {target, event_class, event_id, ask, noErr};
    pthread_t worker;
    if (pthread_create(&worker, NULL, query_permission, &request) != 0) {
        fputs("Owned Automation worker acquisition failed\n", stderr);
        return 68;
    }
    if (pthread_join(worker, NULL) != 0) {
        // Do not dispose the target while an unjoined worker might still use it.
        fputs("Owned Automation worker retirement failed\n", stderr);
        _Exit(68);
    }
    printf("OWNED_APPLEEVENT_PREFLIGHT/1 mode=%s osstatus=%d\n",
        ask ? "request" : "query", (int)request.status);
    return request.status == noErr ? 0 : 67;
}
