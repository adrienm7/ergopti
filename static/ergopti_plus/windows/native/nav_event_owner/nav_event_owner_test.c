// static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner_test.c
/**
 * @file nav_event_owner_test.c
 * @brief Deterministic regression tests for the native navigation owner.
 *
 * The tests never install a Windows hook. They drive TestDispatch, which invokes
 * the exact production state machine, and assert event-time owner identity,
 * fail-open behavior, key-hold balancing, SendLevel arbitration, bounded queue
 * semantics, and claim-before-complete receipt ownership.
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nav_event_owner.h"





// ==================================
// ==================================
// ======= 1/ Test Infrastructure =======
// ==================================
// ==================================

#define TEST_OWNER_A 0xA100000000000001ull
#define TEST_OWNER_B 0xB200000000000002ull
#define TEST_OWNER_C 0xC300000000000003ull
#define TEST_SHARED_EPOCH 0x2600000000000001ull
#define TEST_INPUT_LEVEL 2u

#define TEST_ASSERT(test_name, condition) \
	do { \
		if (!(condition)) { \
			fprintf(stderr, "FAIL %s:%d: %s\n", \
				test_name, __LINE__, #condition); \
			return false; \
		} \
	} while (0)

/** Signature shared by deterministic test cases. */
typedef bool (*NavTestFunction)(void);

/** Associates a stable test name with its function. */
typedef struct NavTestCase {
	const char *name;
	NavTestFunction function;
} NavTestCase;



/**
 * Fills one route without relying on compiler-specific initializers.
 *
 * @param binding Destination packed binding.
 * @param action ErgoptiNav_Action value.
 * @param pass_through One for arrows or zero for digits.
 * @param code Virtual-key code.
 * @param modifiers Generic modifier mask.
 * @param delta Cycle direction or zero for a jump.
 * @param target One-based jump target or zero for a cycle.
 */
static void TestFillBinding(
	ErgoptiNav_Binding *binding,
	uint8_t action,
	uint8_t pass_through,
	uint16_t code,
	uint8_t modifiers,
	int8_t delta,
	uint8_t target)
{
	memset(binding, 0, sizeof(*binding));
	binding->axis = ERGOPTI_NAV_AXIS_VK;
	binding->action = action;
	binding->modifiers = modifiers;
	binding->pass_through = pass_through;
	binding->code = code;
	binding->delta = delta;
	binding->target = target;
	binding->input_level = TEST_INPUT_LEVEL;
}



/**
 * Builds the two-arrow and ten-digit AHK-027 route family.
 *
 * @param plan Destination array of exactly twelve bindings.
 */
static void TestBuildPlan(
	ErgoptiNav_Binding plan[ERGOPTI_NAV_ROUTE_COUNT])
{
	uint32_t target;
	memset(plan, 0, sizeof(ErgoptiNav_Binding) * ERGOPTI_NAV_ROUTE_COUNT);
	TestFillBinding(
		&plan[0],
		ERGOPTI_NAV_ACTION_CYCLE,
		1,
		VK_UP,
		0,
		-1,
		0);
	TestFillBinding(
		&plan[1],
		ERGOPTI_NAV_ACTION_CYCLE,
		1,
		VK_DOWN,
		0,
		1,
		0);
	for (target = 1; target <= ERGOPTI_NAV_MAX_SLOTS; ++target) {
		uint16_t code = target == ERGOPTI_NAV_MAX_SLOTS
			? (uint16_t)'0'
			: (uint16_t)('0' + target);
		TestFillBinding(
			&plan[target + 1u],
			ERGOPTI_NAV_ACTION_JUMP,
			0,
			code,
			ERGOPTI_NAV_MOD_ALT,
			0,
			(uint8_t)target);
	}
}



/**
 * Constructs a canonical nonempty tooltip owner.
 *
 * @param token Exact record token.
 * @param slot_count Number of immutable slots.
 * @param active_index One-based active slot.
 * @return Packed owner snapshot.
 */
static ErgoptiNav_Owner TestOwner(
	uint64_t token,
	uint8_t slot_count,
	uint8_t active_index)
{
	ErgoptiNav_Owner owner;
	memset(&owner, 0, sizeof(owner));
	owner.token = token;
	owner.epoch = TEST_SHARED_EPOCH;
	owner.slot_count = slot_count;
	owner.active_index = active_index;
	return owner;
}



/**
 * Resets native state and commits the canonical twelve-route plan.
 *
 * @param test_name Stable test name for assertions.
 * @param out_generation Receives the active plan generation.
 * @return True when setup succeeds.
 */
static bool TestResetWithPlan(
	const char *test_name,
	uint64_t *out_generation)
{
	ErgoptiNav_Binding plan[ERGOPTI_NAV_ROUTE_COUNT];
	int32_t status;
	TEST_ASSERT(test_name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
	TestBuildPlan(plan);
	status = ErgoptiNav_PreparePlan(
		plan,
		ERGOPTI_NAV_ROUTE_COUNT,
		out_generation);
	TEST_ASSERT(test_name, status == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(test_name, *out_generation != 0);
	TEST_ASSERT(test_name,
		ErgoptiNav_CommitPlan(*out_generation) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Replaces the active plan with one uniform deterministic InputLevel.
 *
 * @param test_name Stable test name for assertions.
 * @param input_level InputLevel applied to all twelve routes.
 * @return True when the replacement generation commits.
 */
static bool TestCommitPlanAtInputLevel(
	const char *test_name,
	uint8_t input_level)
{
	ErgoptiNav_Binding plan[ERGOPTI_NAV_ROUTE_COUNT];
	uint64_t generation = 0;
	uint32_t index;
	TestBuildPlan(plan);
	for (index = 0; index < ERGOPTI_NAV_ROUTE_COUNT; ++index)
		plan[index].input_level = input_level;
	TEST_ASSERT(test_name,
		ErgoptiNav_PreparePlan(
			plan,
			ERGOPTI_NAV_ROUTE_COUNT,
			&generation) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(test_name, generation != 0);
	TEST_ASSERT(test_name,
		ErgoptiNav_CommitPlan(generation) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Replaces both navigation modifier families with deterministic masks.
 *
 * @param test_name Stable test name for assertions.
 * @param navigation_modifiers Modifier mask for Up and Down.
 * @param value_modifiers Modifier mask for the ten jump routes.
 * @return True when the replacement generation commits.
 */
static bool TestCommitPlanAtModifiers(
	const char *test_name,
	uint8_t navigation_modifiers,
	uint8_t value_modifiers)
{
	ErgoptiNav_Binding plan[ERGOPTI_NAV_ROUTE_COUNT];
	uint64_t generation = 0;
	uint32_t index;
	TestBuildPlan(plan);
	plan[0].modifiers = navigation_modifiers;
	plan[1].modifiers = navigation_modifiers;
	for (index = 2; index < ERGOPTI_NAV_ROUTE_COUNT; ++index)
		plan[index].modifiers = value_modifiers;
	TEST_ASSERT(test_name,
		ErgoptiNav_PreparePlan(
			plan,
			ERGOPTI_NAV_ROUTE_COUNT,
			&generation) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(test_name, generation != 0);
	TEST_ASSERT(test_name,
		ErgoptiNav_CommitPlan(generation) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Publishes an owner through the same begin/commit fence used by production.
 *
 * @param test_name Stable test name for assertions.
 * @param expected_token Current owner token.
 * @param owner Next owner snapshot.
 * @return True when publication succeeds.
 */
static bool TestPublishOwner(
	const char *test_name,
	uint64_t expected_token,
	const ErgoptiNav_Owner *owner)
{
	uint64_t ticket = 0;
	TEST_ASSERT(test_name,
		ErgoptiNav_BeginOwnerSwap(expected_token, owner, &ticket)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(test_name, ticket != 0);
	TEST_ASSERT(test_name,
		ErgoptiNav_CommitOwnerSwap(ticket) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Resets the plan and publishes one initial owner.
 *
 * @param test_name Stable test name for assertions.
 * @param owner Initial owner snapshot.
 * @param out_generation Receives the plan generation.
 * @return True when setup succeeds.
 */
static bool TestSetupOwner(
	const char *test_name,
	const ErgoptiNav_Owner *owner,
	uint64_t *out_generation)
{
	if (!TestResetWithPlan(test_name, out_generation))
		return false;
	return TestPublishOwner(test_name, 0, owner);
}



/**
 * Dispatches one virtual-key event through the production core.
 *
 * @param test_name Stable test name for assertions.
 * @param vk Virtual-key code.
 * @param kind ErgoptiNav_EventKind value.
 * @param modifiers Generic modifier mask.
 * @param injected ErgoptiNav_Injection provenance value.
 * @param extra_info Native dwExtraInfo value.
 * @param out_result Receives the decision.
 * @return True when dispatch itself succeeds.
 */
static bool TestDispatch(
	const char *test_name,
	uint16_t vk,
	uint8_t kind,
	uint8_t modifiers,
	uint8_t injected,
	uint64_t extra_info,
	ErgoptiNav_DispatchResult *out_result)
{
	ErgoptiNav_TestEvent event;
	memset(&event, 0, sizeof(event));
	event.vk = vk;
	event.kind = kind;
	event.modifiers = modifiers;
	event.injected = injected;
	event.extra_info = extra_info;
	TEST_ASSERT(test_name,
		ErgoptiNav_TestDispatch(&event, out_result)
			== ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Dispatches a raw hook-shaped event through the production modifier tracker.
 *
 * @param test_name Stable test name for assertions.
 * @param vk Virtual-key code.
 * @param sc AHK-style scan code.
 * @param kind ErgoptiNav_EventKind value.
 * @param injected ErgoptiNav_Injection provenance value.
 * @param extra_info Native dwExtraInfo value.
 * @param out_result Receives the decision.
 * @return True when conversion and dispatch succeed.
 */
static bool TestHookDispatch(
	const char *test_name,
	uint16_t vk,
	uint16_t sc,
	uint8_t kind,
	uint8_t injected,
	uint64_t extra_info,
	ErgoptiNav_DispatchResult *out_result)
{
	ErgoptiNav_TestEvent event;
	memset(&event, 0, sizeof(event));
	event.vk = vk;
	event.sc = sc;
	event.kind = kind;
	event.injected = injected;
	event.extra_info = extra_info;
	TEST_ASSERT(test_name,
		ErgoptiNav_TestHookDispatch(&event, out_result)
			== ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Drives one raw event through the complete hook flow with inert delivery.
 *
 * The production test seam replaces the menu-mask SendInput and downstream
 * CallNextHookEx calls with trace sinks. No OS input or hook is used.
 *
 * @param test_name Stable test name for assertions.
 * @param vk Virtual-key code.
 * @param sc AHK-style scan code.
 * @param kind ErgoptiNav_EventKind value.
 * @param injected ErgoptiNav_Injection provenance value.
 * @param extra_info Native dwExtraInfo value.
 * @param out_result Receives the navigation decision.
 * @param out_mask Receives one when the Ctrl camouflage pulse was emitted.
 * @param out_pass Receives one when the original event was passed downstream.
 * @param out_order Receives one only when camouflage preceded downstream PASS.
 * @return True when conversion, dispatch and delivery all succeeded.
 */
static bool TestHookFlow(
	const char *test_name,
	uint16_t vk,
	uint16_t sc,
	uint8_t kind,
	uint8_t injected,
	uint64_t extra_info,
	ErgoptiNav_DispatchResult *out_result,
	uint8_t *out_mask,
	uint8_t *out_pass,
	uint8_t *out_order)
{
	ErgoptiNav_TestEvent event;
	memset(&event, 0, sizeof(event));
	event.vk = vk;
	event.sc = sc;
	event.kind = kind;
	event.injected = injected;
	event.extra_info = extra_info;
	TEST_ASSERT(test_name,
		ErgoptiNav_TestHookFlow(
			&event,
			out_result,
			0,
			out_mask,
			out_pass,
			out_order) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Reads the stable current owner.
 *
 * @param test_name Stable test name for assertions.
 * @param out_owner Receives the current owner.
 * @return True when the owner was stable.
 */
static bool TestGetOwner(
	const char *test_name,
	ErgoptiNav_Owner *out_owner)
{
	TEST_ASSERT(test_name,
		ErgoptiNav_GetOwner(out_owner) == ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Completes every queued receipt while preserving claim order.
 *
 * @param test_name Stable test name for assertions.
 * @param expected_count Expected number of receipts.
 * @return True when exactly that many receipts are completed.
 */
static bool TestDrainReceipts(
	const char *test_name,
	uint32_t expected_count)
{
	uint32_t count = 0;
	uint64_t previous_sequence = 0;
	ErgoptiNav_Receipt receipt;
	while (ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK) {
		TEST_ASSERT(test_name, receipt.sequence > previous_sequence);
		previous_sequence = receipt.sequence;
		TEST_ASSERT(test_name,
			ErgoptiNav_CompleteReceipt(
				receipt.sequence,
				receipt.owner_token,
				receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
		++count;
	}
	TEST_ASSERT(test_name, count == expected_count);
	return true;
}




// =================================
// =================================
// ======= 2/ Behavioral Tests =======
// =================================
// =================================

/**
 * Proves A7 remains exact when B publishes before A's receipt is drained.
 *
 * @return True when the event-time token and B isolation hold.
 */
static bool TestA7ReceiptSurvivesBSwap(void)
{
	const char *name = "A7 receipt survives B swap";
	ErgoptiNav_Owner owner_a = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner owner_b = TestOwner(TEST_OWNER_B, 7, 2);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation;
	uint32_t pending;

	TEST_ASSERT(name, TestSetupOwner(name, &owner_a, &generation));
	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'7',
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT,
		0,
		0,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, current.active_index == 7);

	TEST_ASSERT(name, TestPublishOwner(name, TEST_OWNER_A, &owner_b));
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_B);
	TEST_ASSERT(name, current.epoch == TEST_SHARED_EPOCH);
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 1);

	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.sequence == result.receipt_sequence);
	TEST_ASSERT(name, receipt.owner_token == TEST_OWNER_A);
	TEST_ASSERT(name, receipt.owner_epoch == TEST_SHARED_EPOCH);
	TEST_ASSERT(name, receipt.plan_generation == generation);
	TEST_ASSERT(name, receipt.from_index == 1);
	TEST_ASSERT(name, receipt.target_index == 7);
	TEST_ASSERT(name, receipt.action == ERGOPTI_NAV_ACTION_JUMP);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			TEST_OWNER_A,
			7) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 0);

	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'7',
		ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_ALT,
		0,
		0,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_B);
	TEST_ASSERT(name, current.active_index == 2);
	return true;
}



/**
 * Proves a repaint swap rejects pixels built for a stale native index.
 *
 * The repaint snapshot is intentionally stale. A second hook decision commits
 * against A before the fence opens; BeginOwnerSwap must leave A published and
 * accept only a replacement rebuilt for the now-current index.
 *
 * @return True when stale pixels are refused and the rebuilt owner is exact.
 */
static bool TestRepaintSwapRejectsStaleIndex(void)
{
	const char *name = "repaint swap rejects stale index";
	ErgoptiNav_Owner owner_a = TestOwner(TEST_OWNER_A, 7, 7);
	ErgoptiNav_Owner owner_b = TestOwner(TEST_OWNER_B, 7, 7);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t ticket = 0;

	TEST_ASSERT(name, TestSetupOwner(name, &owner_a, &generation));
	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'6',
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT,
		0,
		0,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	owner_b.require_index_match = 1;
	TEST_ASSERT(name,
		ErgoptiNav_BeginOwnerSwap(TEST_OWNER_A, &owner_b, &ticket)
			== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ticket == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, current.active_index == 6);

	owner_b.active_index = 6;
	TEST_ASSERT(name, TestPublishOwner(name, TEST_OWNER_A, &owner_b));
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_B);
	TEST_ASSERT(name, current.active_index == 6);
	TEST_ASSERT(name, current.require_index_match == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves digit seven is entirely native when B exposes only six slots.
 *
 * @return True when refusal preserves B and both key edges pass.
 */
static bool TestB6RefusalIsFailOpen(void)
{
	const char *name = "B6 refusal is fail-open";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_B, 6, 2);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, result.route_index == 8);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_NOT_FOUND);
	return true;
}



/**
 * Proves the transition fence passes a whole digit hold and abort is lossless.
 *
 * @return True when no fenced event mutates either owner.
 */
static bool TestTransitionFencePasses(void)
{
	const char *name = "transition fence passes";
	ErgoptiNav_Owner owner_a = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner owner_b = TestOwner(TEST_OWNER_B, 7, 3);
	ErgoptiNav_Owner owner_c = TestOwner(TEST_OWNER_C, 7, 4);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t ticket;

	TEST_ASSERT(name, TestSetupOwner(name, &owner_a, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_BeginOwnerSwap(TEST_OWNER_A, &owner_b, &ticket)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_GetOwner(&current) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name,
		ErgoptiNav_CommitOwnerSwap(ticket) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_B);
	TEST_ASSERT(name, current.active_index == 3);

	TEST_ASSERT(name,
		ErgoptiNav_BeginOwnerSwap(TEST_OWNER_B, &owner_c, &ticket)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_AbortOwnerSwap(ticket) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_B);
	return true;
}



/**
 * Proves arrows pass natively while committing wrapped navigation receipts.
 *
 * @return True when both cycle directions preserve pass-through semantics.
 */
static bool TestArrowsPassWithReceipts(void)
{
	const char *name = "arrows pass with receipts";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, VK_UP, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 7);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.action == ERGOPTI_NAV_ACTION_CYCLE);
	TEST_ASSERT(name, receipt.delta == -1);
	TEST_ASSERT(name, receipt.from_index == 1);
	TEST_ASSERT(name, receipt.target_index == 7);
	TEST_ASSERT(name, receipt.pass_through == 1);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);

	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves a consumed digit owns repeats and exactly one balancing key-up.
 *
 * @return True when one hold emits one receipt and never leaks an edge.
 */
static bool TestDigitKeyupLatch(void)
{
	const char *name = "digit keyup latch";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 3);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves unknown injections fail open and only SendLevel above InputLevel owns.
 *
 * @return True when provenance arbitration matches AHK v2 semantics.
 */
static bool TestInjectedInputLevels(void)
{
	const char *name = "injected input levels";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 4);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t marker_level_two = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 2u;
	uint64_t marker_level_three = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 3u;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		1, 0x12345678u, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		1, 0x12345678u, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		1, marker_level_two, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		1, marker_level_two, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		1, marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		1, marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves untrusted modifier edges cannot change a later physical chord.
 *
 * @return True when both injected down/up attacks fail open and a proven
 * SendLevel sequence still navigates.
 */
static bool TestInjectedModifiersCannotPoisonPhysicalInput(void)
{
	const char *name = "injected modifiers cannot poison physical input";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t marker_level_two = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 2u;
	uint64_t marker_level_three = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 3u;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_two, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 7);
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves modifier releases are paired to the provenance admitted on key-down.
 *
 * @return True when physical and injected holds cannot release each other and
 * an admitted injected hold survives a plan change until its matching key-up.
 */
static bool TestModifierProvenanceSurvivesCrossedReleases(void)
{
	const char *name = "modifier provenance survives crossed releases";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t marker_level_three = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 3u;
	uint64_t marker_level_four = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 4u;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_four, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_four, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestCommitPlanAtInputLevel(name, 3));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtInputLevel(name, 3));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestCommitPlanAtInputLevel(name, 2));
	TEST_ASSERT(name, TestHookDispatch(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		marker_level_three, &result));
	TEST_ASSERT(name, TestHookDispatch(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves Tab acceptance atomically wins or loses against exact navigation.
 *
 * @return True when a stale index cannot claim, a successful claim makes later
 * navigation fail open, and pre-claim receipts/key-up latches remain valid.
 */
static bool TestAcceptanceClaimLinearizesNavigation(void)
{
	const char *name = "acceptance claim linearizes navigation";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner replacement = TestOwner(TEST_OWNER_B, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t ticket = 0;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_BeginOwnerSwap(TEST_OWNER_A, &replacement, &ticket)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ticket != 0);
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(TEST_OWNER_A, 1)
			== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_AbortOwnerSwap(ticket) == ERGOPTI_NAV_STATUS_OK);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_INJECTION_PHYSICAL,
		0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(TEST_OWNER_A, 1)
			== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(TEST_OWNER_A, 1)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == 0);
	TEST_ASSERT(name, current.active_index == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'2', ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_INJECTION_PHYSICAL,
		0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_INJECTION_PHYSICAL,
		0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(TEST_OWNER_A, 1)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_INJECTION_PHYSICAL,
		0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(0, 1)
			== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name,
		ErgoptiNav_ClaimOwner(TEST_OWNER_A, 0)
			== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	return true;
}



/**
 * Proves polling and completion claim each receipt exactly once in FIFO order.
 *
 * @return True when mismatches retain the receipt, duplicates are rejected and
 * a reused low slot cannot overtake an older queued receipt.
 */
static bool TestDuplicateReceiptOwnership(void)
{
	const char *name = "duplicate receipt ownership";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	ErgoptiNav_Receipt second;
	ErgoptiNav_Receipt third;
	uint64_t generation;
	uint64_t first_sequence;
	uint64_t second_sequence;
	uint64_t third_sequence;
	uint32_t pending;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&second) == ERGOPTI_NAV_STATUS_NOT_FOUND);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			TEST_OWNER_B,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			7) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 1);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_NOT_FOUND);

	/* Freeing slot zero while an older receipt remains in slot one forces Poll to
	 * order by immutable sequence rather than physical queue storage */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.receipt_created == 1);
	first_sequence = result.receipt_sequence;
	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.receipt_created == 1);
	second_sequence = result.receipt_sequence;
	TEST_ASSERT(name, second_sequence > first_sequence);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.sequence == first_sequence);
	TEST_ASSERT(name, receipt.from_index == 1);
	TEST_ASSERT(name, receipt.target_index == 2);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);

	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.receipt_created == 1);
	third_sequence = result.receipt_sequence;
	TEST_ASSERT(name, third_sequence > second_sequence);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 2);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&second) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, second.sequence == second_sequence);
	TEST_ASSERT(name, second.from_index == 2);
	TEST_ASSERT(name, second.target_index == 3);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			second.sequence,
			second.owner_token,
			second.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&third) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, third.sequence == third_sequence);
	TEST_ASSERT(name, third.from_index == 3);
	TEST_ASSERT(name, third.target_index == 4);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			third.sequence,
			third.owner_token,
			third.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, current.active_index == 4);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 0);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_NOT_FOUND);
	return true;
}



/**
 * Proves queue exhaustion passes the event without mutating canonical state.
 *
 * @return True when the bounded queue commits its capacity and one refused
 * consumed hold remains fail-open through release.
 */
static bool TestQueueFullIsFailOpen(void)
{
	const char *name = "queue full is fail-open";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation;
	uint32_t index;
	uint32_t pending;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		TEST_ASSERT(name, TestDispatch(
			name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, result.receipt_created == 1);
	}
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name, TestDispatch(
		name, VK_DOWN, ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == ERGOPTI_NAV_RECEIPT_CAPACITY);

	/* A consumed route which fails open at capacity must retain that PASS for the
	 * whole physical hold. Freeing a receipt slot before an auto-repeat must not
	 * let the repeat switch to SUPPRESS and strand its already-passed key-down */
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == ERGOPTI_NAV_RECEIPT_CAPACITY);

	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == ERGOPTI_NAV_RECEIPT_CAPACITY - 1u);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 2);

	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == ERGOPTI_NAV_RECEIPT_CAPACITY - 1u);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 2);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		TestDrainReceipts(name, ERGOPTI_NAV_RECEIPT_CAPACITY - 1u));
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(TEST_OWNER_A, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 0);
	return true;
}



/**
 * Proves suspension is fail-open for a complete hold and resumes afterwards.
 *
 * @return True when suspension never suppresses a newly observed digit.
 */
static bool TestSuspendIsFailOpen(void)
{
	const char *name = "suspend is fail-open";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'3', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(0) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'3', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'3', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'3', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'3', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_ALT,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves hold-table exhaustion cannot change one key from PASS to SUPPRESS.
 *
 * Once an unrecorded consumed down passes downstream, its identity is lost.
 * Freeing a slot later must therefore keep every new consumed hold fail-open
 * until the native runtime resets instead of suppressing a repeat mid-hold.
 *
 * @return True when the overflowed key and its balancing up both remain PASS.
 */
static bool TestHeldKeyOverflowStaysFailOpen(void)
{
	const char *name = "held-key overflow stays fail-open";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint64_t first_marker = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 3u;
	uint64_t overflow_marker = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 50u;
	uint32_t index;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_OK);
	for (index = 0; index < 31u; ++index) {
		TEST_ASSERT(name, TestDispatch(
			name,
			(uint16_t)'2',
			ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_MOD_ALT,
			ERGOPTI_NAV_INJECTION_STANDARD,
			ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - (3u + index),
			&result));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, result.receipt_created == 0);
	}
	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'3',
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 40u,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);

	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'1',
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_STANDARD,
		overflow_marker,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'2',
		ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_STANDARD,
		first_marker,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(0) == ERGOPTI_NAV_STATUS_OK);

	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'1',
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_STANDARD,
		overflow_marker,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name,
		(uint16_t)'1',
		ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_ALT,
		ERGOPTI_NAV_INJECTION_STANDARD,
		overflow_marker,
		&result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.token == TEST_OWNER_A);
	TEST_ASSERT(name, current.active_index == 1);
	TEST_ASSERT(name, TestDrainReceipts(name, 0));
	return true;
}



/**
 * Proves suppressed Alt/Win chords cannot become naked menu-key presses.
 *
 * @return True when exactly one Ctrl camouflage pulse succeeds before the
 * suffix suppression commits, including repeats and inverse release order.
 */
static bool TestSuppressedMenuChordDisguisesRelease(void)
{
	const char *name = "suppressed menu chord disguises release";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RMENU, 0x138, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RMENU, 0x138, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_WIN, ERGOPTI_NAV_MOD_WIN));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves a blocked menu-mask injection fails open before navigation commits.
 *
 * @return True when the original digit hold remains balanced and observable.
 */
static bool TestMenuMaskFailurePrecedesSuppression(void)
{
	const char *name = "menu mask failure precedes suppression";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner current;
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TestEvent event;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);

	memset(&event, 0, sizeof(event));
	event.vk = (uint16_t)'1';
	event.sc = 0x02;
	event.kind = ERGOPTI_NAV_EVENT_DOWN;
	event.injected = ERGOPTI_NAV_INJECTION_PHYSICAL;
	TEST_ASSERT(name,
		ErgoptiNav_TestHookFlow(
			&event,
			&result,
			1,
			&mask,
			&passed,
			&ordered) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, ErgoptiNav_GetLastOsError() == ERROR_ACCESS_DENIED);
	TEST_ASSERT(name, TestGetOwner(name, &current));
	TEST_ASSERT(name, current.active_index == 1);

	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 0));

	/* Once a down is suppressed, repeats and the matching up must retain that
	 * exact latch. A later menu-key repeat must not introduce a new fallible mask
	 * attempt which could turn the middle of the same hold into PASS. */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	memset(&event, 0, sizeof(event));
	event.vk = (uint16_t)'1';
	event.sc = 0x02;
	event.kind = ERGOPTI_NAV_EVENT_DOWN;
	event.injected = ERGOPTI_NAV_INJECTION_PHYSICAL;
	TEST_ASSERT(name,
		ErgoptiNav_TestHookFlow(
			&event,
			&result,
			1,
			&mask,
			&passed,
			&ordered) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves downstream events which naturally disguise Alt need no Ctrl pulse.
 *
 * @return True for naked Alt, pass-through arrow, rejected digit and the AHK
 * mask marker itself, with no false receipt or camouflage emission.
 */
static bool TestPassedEventsDoNotEmitMenuMask(void)
{
	const char *name = "passed events do not emit menu mask";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_Owner six_slots = TestOwner(TEST_OWNER_A, 6, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_UP, 0x148, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_UP, 0x148, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &six_slots, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'7', 0x08, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_CONTROL, 0x1D, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_AHK_SEND_LEVEL_BASE,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_CONTROL, 0x1D, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_AHK_SEND_LEVEL_BASE,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	return true;
}



/**
 * Proves a passed but routing-ineligible Ctrl hold forbids a menu-mask pulse.
 *
 * The untrusted Ctrl edge must affect Windows' downstream logical state without
 * entering route matching. Releasing it must then re-arm ordinary Alt/Win
 * camouflage, proving that the downstream tracker is neither omitted nor
 * sticky.
 *
 * @return True for both Alt and Win with exact suppress/pass/mask behavior.
 */
static bool TestPassedUntrustedControlPreventsMenuMask(void)
{
	const char *name = "passed untrusted control prevents menu mask";
	const uint16_t menu_vk[] = {VK_LMENU, VK_LWIN};
	const uint16_t menu_sc[] = {0x38, 0x15B};
	const uint8_t menu_modifiers[] = {
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_WIN
	};
	const uint64_t unknown_marker = 0x12345678u;
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;
	uint32_t index;

	for (index = 0; index < 2; ++index) {
		TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
		TEST_ASSERT(name, TestCommitPlanAtModifiers(
			name, menu_modifiers[index], menu_modifiers[index]));
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LCONTROL, 0x1D, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_STANDARD, unknown_marker,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, menu_vk[index], menu_sc[index], ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 1);
		TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, TestHookFlow(
			name, menu_vk[index], menu_sc[index], ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LCONTROL, 0x1D, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_STANDARD, unknown_marker,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestDrainReceipts(name, 1));

		TEST_ASSERT(name, TestHookFlow(
			name, menu_vk[index], menu_sc[index], ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 1);
		TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, TestHookFlow(
			name, menu_vk[index], menu_sc[index], ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestDrainReceipts(name, 1));
	}
	return true;
}



/**
 * Proves the provenance-free startup snapshot never claims physical routing.
 *
 * @return True when unknown injected Alt/Win releases clear downstream state
 * and a later physical digit remains untouched by the modifier-only plan.
 */
static bool TestStartupSnapshotCannotClaimPhysicalProvenance(void)
{
	const char *name = "startup snapshot cannot claim physical provenance";
	const uint16_t menu_vk[] = {VK_LMENU, VK_LWIN};
	const uint16_t menu_sc[] = {0x38, 0x15B};
	const uint8_t menu_modifiers[] = {
		ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_WIN
	};
	const uint64_t unknown_marker = 0x12345678u;
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;
	uint32_t index;

	for (index = 0; index < 2; ++index) {
		TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
		TEST_ASSERT(name, TestCommitPlanAtModifiers(
			name, menu_modifiers[index], menu_modifiers[index]));
		TEST_ASSERT(name, ErgoptiNav_TestSeedInitialModifier(
			menu_vk[index], menu_sc[index]) == ERGOPTI_NAV_STATUS_OK);
		TEST_ASSERT(name, TestHookFlow(
			name, menu_vk[index], menu_sc[index], ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_STANDARD, unknown_marker,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, result.receipt_created == 0);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	}
	return true;
}



/**
 * Proves the post-mask guard distinguishes orphan and matched Ctrl/Shift up.
 *
 * @return True when orphan releases are suppressed, matched releases pass and
 * neither path introduces another fallible camouflage pulse.
 */
static bool TestOrphanModifierUpDisguisesPendingMenu(void)
{
	const char *name = "orphan modifier up disguises pending menu";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;
	uint32_t index;
	const uint16_t orphan_vk[] = {VK_LCONTROL, VK_RSHIFT};
	const uint16_t orphan_sc[] = {0x1D, 0x36};
	const uint8_t orphan_injection[] = {
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		ERGOPTI_NAV_INJECTION_STANDARD
	};
	const uint64_t orphan_marker[] = {
		ERGOPTI_NAV_AHK_SEND_LEVEL_BASE - 3u,
		0x12345678u
	};

	for (index = 0; index < 2; ++index) {
		TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
		TEST_ASSERT(name, TestCommitPlanAtModifiers(
			name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, TestHookFlow(
			name, orphan_vk[index], orphan_sc[index],
			ERGOPTI_NAV_EVENT_UP,
			orphan_injection[index], orphan_marker[index],
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 0);
		TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LCONTROL, 0x1D, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LCONTROL, 0x1D, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 0);
		TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
		TEST_ASSERT(name, TestDrainReceipts(name, 1));
	}
	return true;
}



/**
 * Proves one early disguise guards both Win keys and their auto-repeat.
 *
 * @return True when the owned suffix emits one pulse before suppression and
 * later menu-key downs are latched SUPPRESS without another fallible pulse.
 */
static bool TestMenuMaskSurvivesMultipleWinHolds(void)
{
	const char *name = "menu mask survives multiple Win holds";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_WIN, ERGOPTI_NAV_MOD_WIN));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_WIN, ERGOPTI_NAV_MOD_WIN));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_WIN, ERGOPTI_NAV_MOD_WIN));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Proves Stop's drain state retains every already-consumed edge and receipt.
 *
 * @return True when new downs pass and every consumed digit hold, menu guard,
 * and receipt independently blocks completion until balanced.
 */
static bool TestStopDrainBalancesConsumedHolds(void)
{
	const char *name = "stop drain balances consumed holds";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation;
	uint32_t pending = 0;
	uint8_t complete = 0;
	uint8_t mask;
	uint8_t passed;
	uint8_t ordered;

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestBeginDrain() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_TestBeginDrain() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 1);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_ALT, ERGOPTI_NAV_MOD_ALT));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestBeginDrain() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(owner.token, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 1);

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(
		name, ERGOPTI_NAV_MOD_WIN, ERGOPTI_NAV_MOD_WIN));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, mask == 1 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestBeginDrain() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_PendingForToken(owner.token, &pending)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LWIN, 0x15B, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, mask == 0 && passed == 1 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_RWIN, 0x15C, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, mask == 0 && passed == 0 && ordered == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 1);
	return true;
}



/** Proves terminal capture suppresses physical input and replays exact edges. */
static bool TestTerminalCaptureReplaysExactPhysicalEdges(void)
{
	const char *name = "terminal capture replays exact physical edges";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot snapshot;
	ErgoptiNav_TestEvent replayed[10];
	ErgoptiNav_Receipt receipt;
	uint64_t generation = 0;
	uint32_t replayed_count = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	uint32_t index;
	const uint16_t vks[6] = {
		VK_LMENU, (uint16_t)'1', (uint16_t)'1', VK_LMENU,
		(uint16_t)'Z', (uint16_t)'Z'
	};
	const uint16_t scans[6] = { 0x38, 0x02, 0x02, 0x38, 0, 0 };
	const uint8_t kinds[6] = {
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_EVENT_UP
	};

	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
			== ERGOPTI_NAV_STATUS_OK);
	for (index = 0; index < 6; ++index) {
		TEST_ASSERT(name, TestHookFlow(
			name, vks[index], scans[index], kinds[index],
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 0);
		TEST_ASSERT(name, passed == 0 && mask == 0);
	}
	/* AHK SendLevel-0 output is not physical and must cross the capture. */
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'X', 0x2D, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD, ERGOPTI_NAV_AHK_SEND_LEVEL_BASE,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, passed == 1);
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_CAPTURING);
	TEST_ASSERT(name, snapshot.queued == 6 && snapshot.replayed == 0);

	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			TEST_OWNER_B,
			ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT,
			UINT32_MAX,
			replayed,
			10,
			&replayed_count) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, replayed_count == 6);
	for (index = 0; index < 6; ++index) {
		TEST_ASSERT(name, replayed[index].sc == scans[index]);
		TEST_ASSERT(name,
			replayed[index].vk == (scans[index] == 0 ? vks[index] : 0));
		TEST_ASSERT(name, replayed[index].kind == kinds[index]);
		TEST_ASSERT(name,
			replayed[index].extra_info == ERGOPTI_NAV_TERMINAL_REPLAY_MARKER);
	}
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_IDLE);
	TEST_ASSERT(name, snapshot.queued == 0 && snapshot.replayed == 6);
	TEST_ASSERT(name,
		snapshot.release_kind == ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT);

	/* The private replay marker is logical physical input for navigation. */
	for (index = 0; index < 6; ++index) {
		TEST_ASSERT(name, TestHookFlow(
			name, vks[index], scans[index], kinds[index],
			ERGOPTI_NAV_INJECTION_STANDARD,
			ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
			&result, &mask, &passed, &ordered));
		if (index == 1 || index == 2)
			TEST_ASSERT(name,
				result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	}
	TEST_ASSERT(name, ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.owner_token == owner.token);
	TEST_ASSERT(name, receipt.target_index == 1);
	return true;
}



/** Proves partial replay retains the exact FIFO suffix and lifecycle debt. */
static bool TestTerminalCapturePartialReplayIsRetryable(void)
{
	const char *name = "terminal capture partial replay is retryable";
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot snapshot;
	ErgoptiNav_TestEvent replayed[8];
	uint32_t replayed_count = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	uint8_t complete = 1;
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_C)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'A', 0x1E, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LEFT, 0x14B, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			TEST_OWNER_C,
			ERGOPTI_NAV_TERMINAL_RELEASE_ABORT,
			1,
			replayed,
			8,
			&replayed_count) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, replayed_count == 1);
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(TEST_OWNER_C, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		snapshot.phase == ERGOPTI_NAV_TERMINAL_RELEASE_PENDING);
	TEST_ASSERT(name, snapshot.queued == 2 && snapshot.replayed == 1);
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_TestBeginDrain() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	/* Physical input arriving during a failed release joins the FIFO tail. */
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'B', 0x30, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	memset(replayed, 0, sizeof(replayed));
	replayed_count = 0;
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			TEST_OWNER_C,
			ERGOPTI_NAV_TERMINAL_RELEASE_ABORT,
			UINT32_MAX,
			replayed,
			8,
			&replayed_count) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, replayed_count == 3);
	TEST_ASSERT(name,
		replayed[0].sc == 0x1E
			&& replayed[0].kind == ERGOPTI_NAV_EVENT_UP);
	TEST_ASSERT(name,
		replayed[1].sc == 0x14B
			&& replayed[1].kind == ERGOPTI_NAV_EVENT_DOWN);
	TEST_ASSERT(name,
		replayed[2].sc == 0x30
			&& replayed[2].kind == ERGOPTI_NAV_EVENT_DOWN);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 1);
	return true;
}



/** Proves capture admission is bounded and fails closed when storage exhausts. */
static bool TestTerminalCaptureAdmissionAndOverflow(void)
{
	const char *name = "terminal capture admission and overflow";
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot snapshot;
	uint32_t index;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(0)
			== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A)
			== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A)
			== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(0) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
			== ERGOPTI_NAV_STATUS_BUSY);
	for (index = 0; index <= ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY; ++index) {
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'C', 0x2E, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	}
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_FAULTED);
	TEST_ASSERT(name,
		snapshot.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY);
	TEST_ASSERT(name, snapshot.last_os_error == ERROR_NOT_ENOUGH_MEMORY);
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			TEST_OWNER_A,
			ERGOPTI_NAV_TERMINAL_RELEASE_ABORT,
			UINT32_MAX,
			NULL,
			0,
			&index) == ERGOPTI_NAV_STATUS_OS_ERROR);
	return true;
}



/**
 * Proves malformed or incomplete plans cannot replace the current generation.
 *
 * @return True when candidate validation rejects the broken route family.
 */
static bool TestPlanValidationIsAtomic(void)
{
	const char *name = "plan validation is atomic";
	ErgoptiNav_Binding plan[ERGOPTI_NAV_ROUTE_COUNT];
	uint64_t generation = 0;
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
	TestBuildPlan(plan);
	TEST_ASSERT(name,
		ErgoptiNav_PreparePlan(
			plan,
			ERGOPTI_NAV_ROUTE_COUNT - 1u,
			&generation) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	plan[3].reserved[0] = 1;
	TEST_ASSERT(name,
		ErgoptiNav_PreparePlan(
			plan,
			ERGOPTI_NAV_ROUTE_COUNT,
			&generation) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, generation == 0);
	return true;
}




// =============================
// =============================
// ======= 3/ Test Runner =======
// =============================
// =============================

/**
 * Runs every deterministic native navigation-owner regression.
 *
 * @return Zero when every test passes or one after the first failure set.
 */
int main(void)
{
	uint32_t index;
	uint32_t passed = 0;
	NavTestCase tests[] = {
		{"A7 receipt survives B swap", TestA7ReceiptSurvivesBSwap},
		{"repaint swap rejects stale index", TestRepaintSwapRejectsStaleIndex},
		{"B6 refusal is fail-open", TestB6RefusalIsFailOpen},
		{"transition fence passes", TestTransitionFencePasses},
		{"arrows pass with receipts", TestArrowsPassWithReceipts},
		{"digit keyup latch", TestDigitKeyupLatch},
		{"injected input levels", TestInjectedInputLevels},
		{"injected modifiers cannot poison physical input",
			TestInjectedModifiersCannotPoisonPhysicalInput},
		{"modifier provenance survives crossed releases",
			TestModifierProvenanceSurvivesCrossedReleases},
		{"acceptance claim linearizes navigation",
			TestAcceptanceClaimLinearizesNavigation},
		{"duplicate receipt ownership", TestDuplicateReceiptOwnership},
		{"queue full is fail-open", TestQueueFullIsFailOpen},
		{"suspend is fail-open", TestSuspendIsFailOpen},
		{"held-key overflow stays fail-open",
			TestHeldKeyOverflowStaysFailOpen},
		{"suppressed menu chord disguises release",
			TestSuppressedMenuChordDisguisesRelease},
		{"menu mask failure precedes suppression",
			TestMenuMaskFailurePrecedesSuppression},
		{"passed events do not emit menu mask",
			TestPassedEventsDoNotEmitMenuMask},
		{"passed untrusted control prevents menu mask",
			TestPassedUntrustedControlPreventsMenuMask},
		{"startup snapshot cannot claim physical provenance",
			TestStartupSnapshotCannotClaimPhysicalProvenance},
		{"orphan modifier up disguises pending menu",
			TestOrphanModifierUpDisguisesPendingMenu},
		{"menu mask survives multiple Win holds",
			TestMenuMaskSurvivesMultipleWinHolds},
		{"stop drain balances consumed holds",
			TestStopDrainBalancesConsumedHolds},
		{"terminal capture replays exact physical edges",
			TestTerminalCaptureReplaysExactPhysicalEdges},
		{"terminal capture partial replay is retryable",
			TestTerminalCapturePartialReplayIsRetryable},
		{"terminal capture admission and overflow",
			TestTerminalCaptureAdmissionAndOverflow},
		{"plan validation is atomic", TestPlanValidationIsAtomic}
	};
	uint32_t test_count = (uint32_t)(sizeof(tests) / sizeof(tests[0]));

	for (index = 0; index < test_count; ++index) {
		if (!tests[index].function()) {
			fprintf(stderr, "Native navigation-owner tests stopped after %u/%u passes.\n",
				passed, test_count);
			ErgoptiNav_Stop();
			return 1;
		}
		++passed;
		printf("PASS %s\n", tests[index].name);
	}
	ErgoptiNav_Stop();
	printf("Native navigation-owner tests passed: %u/%u.\n", passed, test_count);
	return 0;
}
