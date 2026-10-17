// static/ergopti_plus/windows/native/nav_event_owner/terminal_capture_owned_test.c
/**
 * @file terminal_capture_owned_test.c
 * @brief Exercises capture intervals and processed frontiers without native input.
 *
 * Include the exact production core to inspect retained queue bytes and inject
 * exhaustion without exposing private state in the DLL ABI. The original test
 * owner supplies its real allocation, dispatch and counted replay collaborators;
 * its independent forty-four-case executable and assertions remain unchanged.
 */
#define main CapturedOriginalNativeMain
#include "nav_event_owner_test.c"
#undef main
#include "nav_event_owner.c"

static bool CaptureOwnedSetup(const char *name)
{
	uint64_t generation = 0;
	TEST_ASSERT(name, TestResetWithPlan(name, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	return true;
}

static bool CaptureOwnedEdge(const char *name, uint16_t vk, uint16_t scan, uint8_t kind)
{
	ErgoptiNav_DispatchResult result;
	uint8_t mask = 0, passed = 0, ordered = 0;
	TEST_ASSERT(name, TestHookFlow(name, vk, scan, kind,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	return true;
}

static bool CaptureOwnedSameToken(void)
{
	const char *name = "capture-owned same-token legacy successor and Stop";
	uint64_t first = 0, next = 0;
	ErgoptiNav_TerminalCaptureOwnedSnapshot before, after, denied, sentinel;
	ErgoptiNav_TerminalRouteSnapshot route, refused, route_sentinel, queue_before[2], queue_after[2];
	ErgoptiNav_TestEvent events[4];
	uint32_t count = 0;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &first) == 0 && first != 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, first, &before) == 0);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, first, 0, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, g_nav_state.terminal_capture_serial > first);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &route) == 0);
	TEST_ASSERT(name, route.token == TEST_OWNER_B && route.sequence != 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &before.capture) == 0 && before.capture.queued == 2);
	for (uint32_t index = 0; index < 2; ++index)
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index, &queue_before[index]) == 0);
	memset(&denied, 0xa5, sizeof(denied));
	memset(&refused, 0xa5, sizeof(refused));
	sentinel = denied;
	route_sentinel = refused;
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, first, &denied)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, first, 0, &refused)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, first, route.sequence, 0)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, memcmp(&denied, &sentinel, sizeof(denied)) == 0);
	TEST_ASSERT(name, memcmp(&refused, &route_sentinel, sizeof(refused)) == 0);
	for (uint32_t index = 0; index < 2; ++index) {
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index, &queue_after[index]) == 0);
		TEST_ASSERT(name, memcmp(&queue_before[index], &queue_after[index], sizeof(queue_before[index])) == 0);
	}
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after.capture) == 0);
	TEST_ASSERT(name, memcmp(&before.capture, &after.capture, sizeof(before.capture)) == 0 && !g_nav_state.terminal_release_active);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 4, &count) == 0 && count == 2);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &next) == 0 && next > first + 1);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, first, &denied)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, first, 0, &refused)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, first, 0, 0)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, next, 0, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

typedef struct CaptureOwnedObservation {
	const char *name;
	uint64_t serial;
	uint64_t watermark;
	uint32_t calls;
	bool valid;
} CaptureOwnedObservation;

static void CaptureOwnedAppend(void *raw)
{
	CaptureOwnedObservation *observation = (CaptureOwnedObservation *)raw;
	int32_t nested;
	if (++observation->calls != 1) return;
	nested = NavReleaseTerminalCaptureBound(TEST_OWNER_B, observation->serial,
		observation->watermark, ERGOPTI_NAV_TERMINAL_RELEASE_ABORT,
		NavTestSendTerminalInputs, NULL);
	observation->valid = nested == ERGOPTI_NAV_STATUS_BUSY
		&& CaptureOwnedEdge(observation->name, 'B', 0x30, ERGOPTI_NAV_EVENT_DOWN)
		&& CaptureOwnedEdge(observation->name, 'B', 0x30, ERGOPTI_NAV_EVENT_UP);
}

static bool CaptureOwnedWatermark(void)
{
	const char *name = "capture-owned unprocessed arrival stays in FIFO";
	uint64_t serial = 0;
	ErgoptiNav_TerminalRouteSnapshot first, last;
	ErgoptiNav_TerminalCaptureOwnedSnapshot snapshot;
	ErgoptiNav_TestEvent events[8];
	NavTestTerminalSendContext sink;
	CaptureOwnedObservation observation = {name, 0, 0, 0, false};
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 1, &last) == 0);
	memset(&sink, 0, sizeof(sink));
	sink.remaining = UINT32_MAX;
	sink.events = events;
	sink.capacity = 8;
	observation.serial = serial;
	observation.watermark = last.sequence;
	sink.observer = CaptureOwnedAppend;
	sink.observer_context = &observation;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, last.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, observation.valid && observation.calls == 1 && sink.count == 2);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &snapshot) == 0);
	TEST_ASSERT(name, snapshot.capture.queued == 2 && snapshot.capture.replayed == 2
		&& snapshot.capture.phase == ERGOPTI_NAV_TERMINAL_RELEASE_PENDING);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &first) == 0);
	TEST_ASSERT(name, first.sequence == last.sequence + 1 && first.route.event.vk == 'B');
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 1, &last) == 0);
	TEST_ASSERT(name, last.sequence == first.sequence + 1 && last.route.event.key_up == 1);
	sink.observer = NULL;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, last.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == 0 && sink.count == 4);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &snapshot) == 0);
	TEST_ASSERT(name, snapshot.capture.queued == 0 && snapshot.capture.replayed == 4 && snapshot.capture.phase == ERGOPTI_NAV_TERMINAL_IDLE);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, last.sequence, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedPartial(void)
{
	const char *name = "capture-owned zero and partial accepted prefixes";
	uint64_t serial = 0;
	ErgoptiNav_TerminalRouteSnapshot last, head;
	ErgoptiNav_TestEvent events[4];
	ErgoptiNav_TerminalCaptureOwnedSnapshot snapshot;
	NavTestTerminalSendContext sink;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 1, &last) == 0);
	memset(&sink, 0, sizeof(sink));
	sink.events = events;
	sink.capacity = 4;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, last.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, sink.count == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &snapshot) == 0
		&& snapshot.capture.queued == 2 && snapshot.capture.replayed == 0);
	sink.remaining = 1;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, last.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, sink.count == 1 && events[0].sc == 0x1e && events[0].kind == ERGOPTI_NAV_EVENT_DOWN);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &head) == 0
		&& head.sequence == last.sequence && head.route.event.key_up == 1);
	sink.remaining = UINT32_MAX;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, last.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == 0);
	TEST_ASSERT(name, sink.count == 2 && events[1].kind == ERGOPTI_NAV_EVENT_UP);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedPreflight(void)
{
	const char *name = "capture-owned output aliases and exhausted serial";
	uint64_t serial = 0xfedcba9876543210ull;
	uint64_t saved;
	size_t offset;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	saved = g_nav_state.terminal_capture_serial;
	for (offset = 0; offset + sizeof(uint64_t) <= sizeof(g_nav_state); offset += sizeof(uint64_t)) {
		TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B,
			(uint64_t *)((unsigned char *)&g_nav_state + offset)) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
		TEST_ASSERT(name, g_nav_state.terminal_capture_serial == saved && g_nav_state.terminal_token == 0);
	}
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B,
		(uint64_t *)(UINTPTR_MAX - 3)) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, NULL) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	/* Fault injection changes no admitted identity; restore only that fixture input. */
	g_nav_state.terminal_capture_serial = UINT64_MAX;
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, serial == 0xfedcba9876543210ull && g_nav_state.terminal_token == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, g_nav_state.terminal_capture_serial == UINT64_MAX && g_nav_state.terminal_token == 0);
	g_nav_state.terminal_capture_serial = saved;
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0 && serial == saved + 1);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, 1, 0) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, 0, 2) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, 0, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedCommitAndQueuedBoundary(void)
{
	const char *name = "capture-owned committed interval and queued pair boundary";
	uint64_t serial = 0, refused = 0xfeedull;
	ErgoptiNav_TerminalRouteSnapshot down, up, retained;
	ErgoptiNav_TerminalCaptureOwnedSnapshot before, after;
	ErgoptiNav_TestEvent events[4];
	NavTestTerminalSendContext sink;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_C, &refused) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, refused == 0xfeedull && g_nav_state.terminal_capture_serial == serial);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &down) == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 1, &up) == 0);
	memset(&sink, 0, sizeof(sink));
	sink.remaining = UINT32_MAX; sink.events = events; sink.capacity = 4;
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &before) == 0);
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, up.sequence + 1,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, sink.count == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &after) == 0);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &retained) == 0);
	TEST_ASSERT(name, memcmp(&retained, &down, sizeof(down)) == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 1, &retained) == 0);
	TEST_ASSERT(name, memcmp(&retained, &up, sizeof(up)) == 0);
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, down.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, sink.count == 1 && events[0].kind == ERGOPTI_NAV_EVENT_DOWN);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &retained) == 0);
	TEST_ASSERT(name, memcmp(&retained, &up, sizeof(up)) == 0);
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, up.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, NavTestSendTerminalInputs, &sink) == 0);
	TEST_ASSERT(name, sink.count == 2 && events[1].kind == ERGOPTI_NAV_EVENT_UP);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, up.sequence, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, up.sequence, 0)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedSettledUp(void)
{
	const char *name = "capture-owned settled UP needs its processed watermark";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiReplay_Route route = {.recipe_id = 2200, .route_id = 2,
		.code = 0x1e, .axis = ERGOPTI_REPLAY_SCAN, .kind = ERGOPTI_REPLAY_CHARACTER};
	ErgoptiNav_TerminalRouteSnapshot down, up, retained;
	ErgoptiNav_TerminalCaptureOwnedSnapshot before, pending, completed;
	ErgoptiOutput_Key key;
	ErgoptiOutput_Unit units[2];
	ErgoptiNav_TestEvent events[2];
	NavTestTerminalSendContext sink;
	uint16_t text = 0x61;
	uint64_t generation = 0, serial = 0, attempt = 0;
	uint32_t count = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &down) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, down.sequence, &text, 1, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key, units, 2, &count, &attempt) == 0 && count == 2);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, count) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &up) == 0);
	TEST_ASSERT(name, up.sequence == down.sequence + 1 && up.route.event.key_up == 1);
	TEST_ASSERT(name, g_nav_state.terminal_events[g_nav_state.terminal_prefix_queued].output_settled);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &before) == 0);
	memset(&sink, 0, sizeof(sink)); sink.remaining = UINT32_MAX; sink.events = events; sink.capacity = 2;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, down.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &pending) == 0);
	TEST_ASSERT(name, pending.capture.queued == before.capture.queued && pending.capture.replayed == before.capture.replayed && sink.count == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &retained) == 0);
	TEST_ASSERT(name, memcmp(&retained, &up, sizeof(up)) == 0);
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, up.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &completed) == 0);
	TEST_ASSERT(name, completed.capture.queued == 0 && completed.capture.replayed == before.capture.replayed + 1
		&& completed.capture.phase == ERGOPTI_NAV_TERMINAL_IDLE && sink.count == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedRollbackPrefix(void)
{
	const char *name = "capture-owned rollback prefix preserves unprocessed tail";
	ErgoptiNav_TerminalRouteSnapshot starter, up, tail[2], retained;
	ErgoptiNav_TerminalCaptureOwnedSnapshot snapshot;
	ErgoptiNav_TestEvent events[4];
	NavTestTerminalSendContext sink;
	uint64_t serial;
	TEST_ASSERT(name, TestCanonicalPrefixOnly(name, &starter));
	serial = g_nav_state.terminal_capture_serial;
	TEST_ASSERT(name, serial != 0 && g_nav_state.terminal_prefix_queued == 1);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 0xc0, 0x29, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &up) == 0);
	TEST_ASSERT(name, up.sequence == starter.sequence + 1);
	for (uint32_t index = 0; index < 2; ++index)
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, index + 1, &tail[index]) == 0);
	memset(&sink, 0, sizeof(sink)); sink.remaining = 1; sink.events = events; sink.capacity = 4;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, up.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, sink.count == 1 && events[0].sc == 0x29 && events[0].kind == ERGOPTI_NAV_EVENT_DOWN);
	sink.remaining = UINT32_MAX;
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, up.sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, sink.count == 2 && events[1].sc == 0x29 && events[1].kind == ERGOPTI_NAV_EVENT_UP);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &snapshot) == 0
		&& snapshot.capture.queued == 2 && snapshot.capture.replayed == 2);
	for (uint32_t index = 0; index < 2; ++index) {
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, index, &retained) == 0);
		TEST_ASSERT(name, memcmp(&retained, &tail[index], sizeof(retained)) == 0);
	}
	TEST_ASSERT(name, NavReleaseTerminalCaptureBound(TEST_OWNER_B, serial, tail[1].sequence,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, NavTestSendTerminalInputs, &sink) == 0 && sink.count == 4);
	TEST_ASSERT(name, events[2].sc == 0x1e && events[2].kind == ERGOPTI_NAV_EVENT_DOWN
		&& events[3].sc == 0x1e && events[3].kind == ERGOPTI_NAV_EVENT_UP);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

static bool CaptureOwnedAllocatedAliases(void)
{
	const char *name = "capture-owned allocated route outputs preserve all bytes";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiReplay_Route routes[196] = {{0}};
	ErgoptiNav_TestStorageView view;
	ErgoptiNav_TerminalRouteSnapshot head;
	ErgoptiNav_TerminalCaptureOwnedSnapshot snapshot;
	ErgoptiNav_TestEvent events[2];
	uint64_t generation = 0, serial = 0;
	uint32_t count = 0;
	unsigned char *descriptors, *semantic;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	for (uint32_t index = 0; index < 196; ++index) {
		routes[index].recipe_id = index + 1; routes[index].route_id = index + 1;
		routes[index].code = (uint16_t)(index + 1); routes[index].axis = ERGOPTI_REPLAY_SCAN;
		routes[index].kind = ERGOPTI_REPLAY_CHARACTER;
	}
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 81, routes, 196) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestBorrowStorage(TEST_OWNER_A, &view) == 0);
	TEST_ASSERT(name, view.route_bytes >= sizeof(head) && view.semantic_bytes >= sizeof(head));
	descriptors = malloc(view.route_bytes); semantic = malloc(view.semantic_bytes);
	TEST_ASSERT(name, descriptors != NULL && semantic != NULL);
	memcpy(descriptors, view.routes, view.route_bytes); memcpy(semantic, view.semantic, view.semantic_bytes);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, (uint64_t *)view.routes) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, (uint64_t *)view.semantic) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, memcmp(descriptors, view.routes, view.route_bytes) == 0
		&& memcmp(semantic, view.semantic, view.semantic_bytes) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 196, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 196, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &snapshot) == 0 && snapshot.capture.queued == 2);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &head) == 0);
	memcpy(descriptors, view.routes, view.route_bytes); memcpy(semantic, view.semantic, view.semantic_bytes);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial,
		(ErgoptiNav_TerminalCaptureOwnedSnapshot *)view.routes) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0,
		(ErgoptiNav_TerminalRouteSnapshot *)view.semantic) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, memcmp(descriptors, view.routes, view.route_bytes) == 0
		&& memcmp(semantic, view.semantic, view.semantic_bytes) == 0);
	free(descriptors); free(semantic);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 2, &count) == 0 && count == 2);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}


/** Bounds survive ordinary retirement and distinguish successive capture intervals. */
static bool CaptureOwnedSequenceBounds(void)
{
	const char *name = "capture-owned exact bounds survive retirement and successor";
	ErgoptiNav_TerminalCaptureOwnedSnapshot receipt, idle;
	ErgoptiNav_TerminalRouteSnapshot route;
	ErgoptiNav_TestEvent events[4];
	uint64_t serial = 0, next = 0;
	uint32_t count = 0;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	memset(&receipt, 0xa5, sizeof(receipt));
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture_base_sequence == 0 && receipt.captured_through_sequence == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 4, &count) == 0 && count == 2);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &idle) == 0);
	TEST_ASSERT(name, idle.capture.phase == ERGOPTI_NAV_TERMINAL_IDLE
		&& idle.capture.queued == 0 && idle.capture.replayed == 2);
	TEST_ASSERT(name, idle.capture_base_sequence == 0 && idle.captured_through_sequence == 2);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &next) == 0 && next > serial);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, next, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture_base_sequence == idle.captured_through_sequence
		&& receipt.captured_through_sequence == idle.captured_through_sequence);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'B', 0x30, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'B', 0x30, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, next, 0, &route) == 0);
	TEST_ASSERT(name, route.sequence == receipt.capture_base_sequence + 1);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, next, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture_base_sequence == 2 && receipt.captured_through_sequence == 4);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 4, &count) == 0 && count == 2);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, next, &idle) == 0);
	TEST_ASSERT(name, idle.capture_base_sequence == receipt.capture_base_sequence
		&& idle.captured_through_sequence == receipt.captured_through_sequence);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0 && serial > next);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture_base_sequence == 0 && receipt.captured_through_sequence == 0);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, 0, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

/** Empty serviceable counts cannot conceal an unwitnessed rollback prefix. */
static bool CaptureOwnedHiddenPrefixBounds(void)
{
	const char *name = "capture-owned hidden prefix retains its exact interval";
	ErgoptiNav_TerminalCaptureOwnedSnapshot receipt;
	ErgoptiNav_TerminalRouteSnapshot starter, absent;
	ErgoptiNav_TestEvent events[1];
	uint64_t serial;
	uint32_t count = 0;
	TEST_ASSERT(name, TestCanonicalPrefixOnly(name, &starter));
	serial = g_nav_state.terminal_capture_serial;
	memset(&receipt, 0xa5, sizeof(receipt));
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture.queued == 0 && receipt.capture.replayed == 0
		&& receipt.capture.phase == ERGOPTI_NAV_TERMINAL_CAPTURING);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &absent)
		== ERGOPTI_NAV_STATUS_NOT_FOUND);
	TEST_ASSERT(name, receipt.capture_base_sequence == 0
		&& receipt.captured_through_sequence == starter.sequence
		&& receipt.captured_through_sequence > receipt.capture_base_sequence);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 1, &count) == 0 && count == 1);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture.phase == ERGOPTI_NAV_TERMINAL_IDLE
		&& receipt.capture_base_sequence == 0 && receipt.captured_through_sequence == starter.sequence);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

/** Preflight covers all44 writable bytes, including spans crossing the owner's start. */
static bool CaptureOwnedBoundsAliases(void)
{
	const char *name = "capture-owned whole extended receipt preflight";
	ErgoptiNav_TerminalCaptureOwnedSnapshot before, after, denied, sentinel;
	uint64_t serial = 0;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &before) == 0);
	for (size_t offset = 0; offset < sizeof(g_nav_state); offset += 8) {
		TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial,
			(ErgoptiNav_TerminalCaptureOwnedSnapshot *)((unsigned char *)&g_nav_state + offset))
			== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	}
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial,
		(ErgoptiNav_TerminalCaptureOwnedSnapshot *)((uintptr_t)&g_nav_state - 32))
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial,
		(ErgoptiNav_TerminalCaptureOwnedSnapshot *)(UINTPTR_MAX - 32))
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, NULL)
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	memset(&denied, 0xa5, sizeof(denied)); sentinel = denied;
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial + 1, &denied)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, memcmp(&denied, &sentinel, sizeof(denied)) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &after) == 0);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	TEST_ASSERT(name, ErgoptiNav_ReleaseTerminalCaptureOwned(TEST_OWNER_B, serial, 0, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

/** Sequence exhaustion faults before capture can publish a wrapped identifier. */
static bool CaptureOwnedSequenceExhaustion(void)
{
	const char *name = "capture-owned exhausted sequence never wraps";
	ErgoptiNav_TerminalCaptureOwnedSnapshot receipt;
	ErgoptiNav_TerminalRouteSnapshot head;
	ErgoptiNav_TestEvent events[1];
	uint64_t serial = 0;
	uint32_t count = 0;
	TEST_ASSERT(name, CaptureOwnedSetup(name));
	/* Inject only the counter prerequisite; actual dispatch still owns the queue. */
	g_nav_state.terminal_next_sequence = UINT64_MAX - 1;
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCaptureOwned(TEST_OWNER_B, &serial) == 0);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_DOWN));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRouteOwned(TEST_OWNER_B, serial, 0, &head) == 0
		&& head.sequence == UINT64_MAX);
	TEST_ASSERT(name, CaptureOwnedEdge(name, 'A', 0x1e, ERGOPTI_NAV_EVENT_UP));
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture.phase == ERGOPTI_NAV_TERMINAL_FAULTED
		&& receipt.capture.last_os_error == ERROR_ARITHMETIC_OVERFLOW);
	TEST_ASSERT(name, receipt.capture.queued == 1 && receipt.capture.replayed == 0
		&& receipt.capture_base_sequence == UINT64_MAX - 1
		&& receipt.captured_through_sequence == UINT64_MAX);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, events, 1, &count)
		== ERGOPTI_NAV_STATUS_OS_ERROR && count == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCaptureOwned(TEST_OWNER_B, serial, &receipt) == 0);
	TEST_ASSERT(name, receipt.capture.phase == ERGOPTI_NAV_TERMINAL_FAULTED
		&& receipt.capture.queued == 1 && receipt.capture.replayed == 0
		&& receipt.captured_through_sequence == UINT64_MAX);
	/* The hookless raw fixture has no initialized transformed owner to retain. */
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}

int main(int argc, char **argv)
{
	uint32_t index, passed = 0;
	const NavTestCase tests[] = {
		{"capture-owned same-token legacy successor and Stop", CaptureOwnedSameToken},
		{"capture-owned unprocessed arrival stays in FIFO", CaptureOwnedWatermark},
		{"capture-owned zero and partial accepted prefixes", CaptureOwnedPartial},
		{"capture-owned output aliases and exhausted serial", CaptureOwnedPreflight},
		{"capture-owned committed interval and queued pair boundary", CaptureOwnedCommitAndQueuedBoundary},
		{"capture-owned settled UP needs its processed watermark", CaptureOwnedSettledUp},
		{"capture-owned rollback prefix preserves unprocessed tail", CaptureOwnedRollbackPrefix},
		{"capture-owned allocated route outputs preserve all bytes", CaptureOwnedAllocatedAliases},
		{"capture-owned exact bounds survive retirement and successor", CaptureOwnedSequenceBounds},
		{"capture-owned hidden prefix retains its exact interval", CaptureOwnedHiddenPrefixBounds},
		{"capture-owned whole extended receipt preflight", CaptureOwnedBoundsAliases},
		{"capture-owned exhausted sequence never wraps", CaptureOwnedSequenceExhaustion}
	};
	uint32_t test_count = (uint32_t)(sizeof(tests) / sizeof(tests[0]));
	uint32_t selected_count = test_count;
	if (argc > 2) {
		fprintf(stderr, "Expected at most one exact capture test name.\n");
		return 2;
	}
	if (argc == 2) {
		selected_count = 0;
		for (index = 0; index < test_count; ++index) {
			if (strcmp(tests[index].name, argv[1]) == 0)
				++selected_count;
		}
		if (selected_count != 1) {
			fprintf(stderr, "Unknown or ambiguous capture test name: %s\n", argv[1]);
			return 2;
		}
	}
	for (index = 0; index < test_count; ++index) {
		if (argc == 2 && strcmp(tests[index].name, argv[1]) != 0)
			continue;
		if (!tests[index].function()) {
			fprintf(stderr, "Native capture-owned tests stopped after %u/%u passes.\n", passed, selected_count);
			ErgoptiNav_Stop();
			return 1;
		}
		++passed;
		printf("PASS %s\n", tests[index].name);
	}
	ErgoptiNav_Stop();
	printf("Native capture-owned tests passed: %u/%u.\n", passed, selected_count);
	return 0;
}
