// Supplemental private producer-boundary evidence; not a registered native case.
/**
 * @file native-serializer-bridge-fault-harness.c
 * @brief Actual production inclusion for otherwise unreachable custody faults.
 *
 * Compile using the unchanged portable Win32 boundary. This fixture alone owns
 * the native singleton and perturbs/restores its head under its recursive lock.
 * No testing setter, shipping export, sender or admission bypass is added.
 * This supplements the registered regressions; it is not native qualification.
 */
#include "terminal_output_plan.h"
static int32_t BridgeObservePureSerialization(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt, ErgoptiOutput_Win32Input *inputs, uint32_t capacity, uint32_t *count);
#define ErgoptiOutput_SerializeAttempt BridgeObservePureSerialization
#include "nav_event_owner.c"
#undef ErgoptiOutput_SerializeAttempt
#define main BridgeRegisteredNativeMain
#include "nav_event_owner_test.c"
#undef main
#include <stdlib.h>
#include <errno.h>

static uint32_t bridge_probe_calls;
static bool bridge_probe_lock_held = true;

/** A distinct thread must observe the owner's mutex as busy at pure dispatch. */
static void *BridgeProbeOwnerLock(void *context)
{
	int *result = context;
	*result = pthread_mutex_trylock(&g_nav_state.lock);
	if (*result == 0) (void)pthread_mutex_unlock(&g_nav_state.lock);
	return NULL;
}

static int32_t BridgeObservePureSerialization(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt, ErgoptiOutput_Win32Input *inputs, uint32_t capacity, uint32_t *count)
{
	pthread_t thread; int result = -1;
	if (pthread_create(&thread, NULL, BridgeProbeOwnerLock, &result) != 0) abort();
	if (pthread_join(thread, NULL) != 0) abort();
	++bridge_probe_calls;
	bridge_probe_lock_held = bridge_probe_lock_held && result == EBUSY;
	return ErgoptiOutput_SerializeAttempt(state, owner, key, attempt, inputs, capacity, count);
}

static bool TestBridgeInternalBoundaries(void)
{
	const char *name = "supplemental native serializer custody fault boundaries";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiReplay_Route route = {.recipe_id = 2200, .route_id = 2,
		.code = 0x1E, .axis = ERGOPTI_REPLAY_SCAN, .kind = ERGOPTI_REPLAY_CHARACTER};
	ErgoptiNav_DispatchResult result; uint8_t mask = 0, passed = 0, ordered = 0;
	ErgoptiNav_TerminalRouteSnapshot head; ErgoptiOutput_Key key;
	ErgoptiOutput_Unit units[4]; ErgoptiOutput_Win32Input inputs[4], before[4];
	uint64_t generation = 0, attempt; uint32_t count; const uint16_t text[2] = {0xD83D,0xDE00};
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, head.sequence, text, 2, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key, units, 4, &count, &attempt) == 0);
	for (uint32_t fault = 0; fault < 3; ++fault) {
		count = 99; memset(inputs, 0xA5, sizeof(inputs)); memcpy(before, inputs, sizeof(inputs));
		EnterCriticalSection(&g_nav_state.lock);
		uint64_t sequence = g_nav_state.terminal_events[0].sequence;
		uint64_t timestamp = g_nav_state.terminal_events[0].route.event.timestamp;
		uint8_t release = g_nav_state.terminal_release_active;
		if (fault == 0) ++g_nav_state.terminal_events[0].sequence;
		if (fault == 1) ++g_nav_state.terminal_events[0].route.event.timestamp;
		if (fault == 2) g_nav_state.terminal_release_active = 1;
		NavState *snapshot = malloc(sizeof(g_nav_state));
		TEST_ASSERT(name, snapshot != NULL);
		memcpy(snapshot, &g_nav_state, sizeof(g_nav_state));
		int32_t status = ErgoptiNav_SerializeTerminalOutputAttempt(TEST_OWNER_A,
			&key, attempt, inputs, 4, &count);
		bool preserved = memcmp(snapshot, &g_nav_state, sizeof(g_nav_state)) == 0;
		free(snapshot);
		g_nav_state.terminal_events[0].sequence = sequence;
		g_nav_state.terminal_events[0].route.event.timestamp = timestamp;
		g_nav_state.terminal_release_active = release;
		LeaveCriticalSection(&g_nav_state.lock);
		TEST_ASSERT(name, status == (fault == 2 ? ERGOPTI_NAV_STATUS_BUSY : ERGOPTI_NAV_STATUS_INVALID_STATE));
		TEST_ASSERT(name, preserved && count == 99 && memcmp(inputs, before, sizeof(inputs)) == 0);
	}
	/* Aliases into lock, routes and raw FIFO are outside the pure output state. */
	ErgoptiOutput_Win32Input *aliases[] = {
		(ErgoptiOutput_Win32Input *)&g_nav_state.lock,
		(ErgoptiOutput_Win32Input *)&g_nav_state.terminal_routes,
		(ErgoptiOutput_Win32Input *)&g_nav_state.terminal_events[0]
	};
	for (uint32_t i = 0; i < 3; ++i) {
		NavState *snapshot = malloc(sizeof(g_nav_state));
		TEST_ASSERT(name, snapshot != NULL);
		memcpy(snapshot, &g_nav_state, sizeof(g_nav_state)); count = 99;
		int32_t status = ErgoptiNav_SerializeTerminalOutputAttempt(TEST_OWNER_A,
			&key, attempt, aliases[i], 4, &count);
		bool preserved = memcmp(snapshot, &g_nav_state, sizeof(g_nav_state)) == 0;
		free(snapshot);
		TEST_ASSERT(name, status == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT && count == 99 && preserved);
	}
	NavState *snapshot = malloc(sizeof(g_nav_state));
	TEST_ASSERT(name, snapshot != NULL);
	memcpy(snapshot, &g_nav_state, sizeof(g_nav_state));
	memset(inputs, 0xA5, sizeof(inputs)); memcpy(before, inputs, sizeof(inputs));
	int32_t status = ErgoptiNav_SerializeTerminalOutputAttempt(TEST_OWNER_A,
		&key, attempt, inputs, 4, &g_nav_state.terminal_queued);
	bool preserved = memcmp(snapshot, &g_nav_state, sizeof(g_nav_state)) == 0;
	free(snapshot);
	TEST_ASSERT(name, status == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT && preserved);
	TEST_ASSERT(name, memcmp(inputs, before, sizeof(inputs)) == 0);
	/* Fault probes and alias refusal did not invalidate the real pending attempt. */
	TEST_ASSERT(name, ErgoptiNav_SerializeTerminalOutputAttempt(TEST_OWNER_A, &key, attempt, inputs, 4, &count) == 0);
	TEST_ASSERT(name, count == 4 && g_nav_state.terminal_output.attempting && g_nav_state.terminal_queued == 1);
	TEST_ASSERT(name, bridge_probe_calls != 0 && bridge_probe_lock_held);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == 0);
	return true;
}

int main(void)
{
	if (!TestBridgeInternalBoundaries()) return 1;
	puts("PASS supplemental actual-C bridge head/snapshot/release/whole-owner alias and real cross-thread lock boundaries");
	return 0;
}
