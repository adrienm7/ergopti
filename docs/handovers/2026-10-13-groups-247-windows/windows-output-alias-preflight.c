#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t init_calls, lock_calls;
static bool cold;
static BOOL WINAPI ObserveInit(PINIT_ONCE once, PINIT_ONCE_FN callback,
	PVOID parameter, PVOID *context)
{
	++init_calls;
	return cold ? FALSE : InitOnceExecuteOnce(once, callback, parameter, context);
}
static void WINAPI ObserveEnter(CRITICAL_SECTION *lock)
{
	++lock_calls;
	EnterCriticalSection(lock);
}
#define InitOnceExecuteOnce ObserveInit
#define EnterCriticalSection ObserveEnter
#include "nav_event_owner.c"
#undef EnterCriticalSection
#undef InitOnceExecuteOnce
#define main OriginalNativeMain
#include "nav_event_owner_test.c"
#undef main
typedef struct Outputs {
	ErgoptiOutput_Unit units[4];
	uint32_t count;
	uint64_t attempt;
	ErgoptiOutput_Key key;
} Outputs;
static bool Matrix(void)
{
	const char *name = "whole-owner cold/live preflight";
	Outputs out, saved;
	NavState *snapshot = malloc(sizeof(g_nav_state));
	uint32_t initial_init = init_calls, initial_lock = lock_calls, vectors = 0;
	const uint16_t text[2] = {0x78, 0x79};
	void *aliases[] = {&g_nav_state.lock, &g_nav_state.terminal_routes,
		&g_nav_state.terminal_output, &g_nav_state.terminal_events[0],
		(unsigned char *)&g_nav_state + sizeof(g_nav_state) - 8};
	TEST_ASSERT(name, snapshot != NULL);
	memset(&out, 0xA5, sizeof(out));
	out.key = (ErgoptiOutput_Key){TEST_OWNER_B, 1, 1};
	memcpy(&saved, &out, sizeof(out));
	memcpy(snapshot, &g_nav_state, sizeof(g_nav_state));
#define REFUSE(call) do { \
	TEST_ASSERT(name, (call) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT); \
	TEST_ASSERT(name, init_calls == initial_init && lock_calls == initial_lock); \
	TEST_ASSERT(name, memcmp(snapshot, &g_nav_state, sizeof(g_nav_state)) == 0); \
	TEST_ASSERT(name, memcmp(&saved, &out, sizeof(out)) == 0); \
	++vectors; \
} while (0)
	for (size_t i = 0; i < sizeof(aliases) / sizeof(aliases[0]); ++i) {
		REFUSE(ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, 1,
			text, 2, (ErgoptiOutput_Key *)aliases[i]));
		REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
			(ErgoptiOutput_Unit *)aliases[i], 1, &out.count, &out.attempt));
		REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
			out.units, 1, (uint32_t *)aliases[i], &out.attempt));
		REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
			out.units, 1, &out.count, (uint64_t *)aliases[i]));
	}
	REFUSE(ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, 1,
		(const uint16_t *)&out.key, 2, &out.key));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		(ErgoptiOutput_Unit *)&out.key, 1, &out.count, &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, (uint32_t *)&out.key.token, &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, &out.count, &out.key.plan_id));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		(ErgoptiOutput_Unit *)((unsigned char *)&out.key + 16), 1, &out.count, &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, (uint32_t *)&out.units[0], &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, &out.count, (uint64_t *)&out.units[0]));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, (uint32_t *)&out.attempt, &out.attempt));
	REFUSE(ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, 1,
		text, 2, (ErgoptiOutput_Key *)(uintptr_t)(UINTPTR_MAX - 7)));
	REFUSE(ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, 1,
		(const uint16_t *)(uintptr_t)(UINTPTR_MAX - 1), 2, &out.key));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		(ErgoptiOutput_Unit *)(uintptr_t)(UINTPTR_MAX - 1), 1, &out.count, &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, (uint32_t *)(uintptr_t)(UINTPTR_MAX - 3), &out.attempt));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &out.key,
		out.units, 1, &out.count, (uint64_t *)(uintptr_t)(UINTPTR_MAX - 7)));
	REFUSE(ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A,
		(const ErgoptiOutput_Key *)(uintptr_t)(UINTPTR_MAX - 7),
		out.units, 1, &out.count, &out.attempt));
#undef REFUSE
	free(snapshot);
	printf("PASS %s: %u vectors, zero init/lock/writes\n", cold ? "cold" : "live", vectors);
	return true;
}
static bool Live(void)
{
	const char *name = "live owner setup";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	uint64_t generation = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, Matrix());
	ErgoptiReplay_Route route = {.recipe_id = 2200, .route_id = 2, .code = 0x1E,
		.axis = ERGOPTI_REPLAY_SCAN, .kind = ERGOPTI_REPLAY_CHARACTER};
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalRouteSnapshot head;
	ErgoptiOutput_Key key;
	ErgoptiOutput_Unit units[2];
	ErgoptiNav_TestEvent replayed;
	uint8_t mask = 0, passed = 0, ordered = 0;
	uint32_t count = 0;
	uint64_t attempt = 0;
	const uint16_t text[1] = {0x78};
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, Matrix());
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B, head.sequence, text, 1, &key) == 0);
	TEST_ASSERT(name, Matrix());
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key, units, 2, &count, &attempt) == 0);
	TEST_ASSERT(name, count == 2 && units[0].utf16 == 0x78 && units[1].key_up == 1);
	TEST_ASSERT(name, Matrix());
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, &replayed, 1, &count) == 0);
	TEST_ASSERT(name, count == 1);
	TEST_ASSERT(name, ErgoptiNav_Stop() == 0);
	return true;
}
int main(int argc, char **argv)
{
	cold = true;
	if (!Matrix()) return 1;
	if (argc == 2 && strcmp(argv[1], "--cold-only") == 0) return 0;
	cold = false;
	if (!Live()) return 1;
	puts("PASS private actual-C state and output span preflight");
	return 0;
}
