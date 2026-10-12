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
#include "editor_replace.h"





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



/** Builds the fixed Ctrl+1 through Ctrl+9 profile-selection route family. */
static void TestBuildProfilePlan(
	ErgoptiNav_Binding plan[ERGOPTI_NAV_PROFILE_ROUTE_COUNT])
{
	uint32_t target;
	memset(
		plan,
		0,
		sizeof(ErgoptiNav_Binding) * ERGOPTI_NAV_PROFILE_ROUTE_COUNT);
	for (target = 1; target <= ERGOPTI_NAV_PROFILE_ROUTE_COUNT; ++target) {
		TestFillBinding(
			&plan[target - 1u],
			ERGOPTI_NAV_ACTION_PROFILE_SELECT,
			0,
			(uint16_t)('0' + target),
			ERGOPTI_NAV_MOD_CONTROL,
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



/** Constructs one immutable profile-order owner. */
static ErgoptiNav_ProfileOwner TestProfileOwner(
	uint64_t token,
	uint8_t profile_count)
{
	ErgoptiNav_ProfileOwner owner;
	memset(&owner, 0, sizeof(owner));
	owner.token = token;
	owner.epoch = token == 0 ? 0 : TEST_SHARED_EPOCH;
	owner.profile_count = profile_count;
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



/** Publishes one fixed profile plan and immutable order owner. */
static bool TestPublishProfileOwner(
	const char *test_name,
	uint64_t expected_token,
	const ErgoptiNav_ProfileOwner *owner,
	uint16_t *out_pending_mask)
{
	ErgoptiNav_Binding plan[ERGOPTI_NAV_PROFILE_ROUTE_COUNT];
	uint64_t ticket = 0;
	uint16_t pending_mask = 0;
	TestBuildProfilePlan(plan);
	TEST_ASSERT(test_name,
		ErgoptiNav_BeginProfileSwap(
			expected_token,
			plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT,
			owner,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(test_name, ticket != 0);
	TEST_ASSERT(test_name,
		ErgoptiNav_CommitProfileSwap(ticket) == ERGOPTI_NAV_STATUS_OK);
	if (out_pending_mask != NULL)
		*out_pending_mask = pending_mask;
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



/** Proves immutable event recipes follow the exact acknowledged FIFO suffix. */
static bool TestTerminalRouteSnapshotsRetainExactSuffix(void)
{
	const char *name = "terminal route snapshots retain exact suffix (todo49-route-fifo)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalRouteSnapshot snapshots[6];
	ErgoptiNav_TerminalRouteSnapshot peek;
	ErgoptiNav_TestEvent output[8];
	ErgoptiNav_TerminalCaptureSnapshot capture;
	ErgoptiReplay_Route routes[4];
	uint64_t generation = 0;
	uint32_t output_count = 0;
	uint32_t retained_count = 0;
	uint64_t retained[ERGOPTI_REPLAY_MAX_HELD_KEYS];
	uint32_t index;
	uint8_t mask = 0, passed = 0, ordered = 0;
	const uint16_t vks[6] = { 'A', 'A', 'A', VK_LSHIFT, 'B', 'B' };
	const uint16_t scans[6] = { 0x1E, 0x1E, 0x1E, 0x2A, 0x30, 0x30 };
	const uint8_t kinds[6] = {
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP
	};
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	memset(routes, 0, sizeof(routes));
	routes[0].recipe_id = 1100;
	routes[0].route_id = 1;
	routes[0].code = VK_LSHIFT;
	routes[0].axis = ERGOPTI_REPLAY_VK;
	routes[0].kind = ERGOPTI_REPLAY_MODIFIER;
	routes[0].effective_modifiers_lr = ERGOPTI_REPLAY_LSHIFT;
	routes[1].recipe_id = 2200;
	routes[1].route_id = 2;
	routes[1].code = 0x1E;
	routes[1].axis = ERGOPTI_REPLAY_SCAN;
	routes[1].kind = ERGOPTI_REPLAY_CHARACTER;
	routes[2] = routes[1];
	routes[2].recipe_id = 3300;
	routes[2].route_id = 3;
	routes[2].required_modifiers = ERGOPTI_REPLAY_SHIFT;
	/* Even a supplied Caps text declaration cannot bypass its missing axis. */
	routes[3].recipe_id = 4400;
	routes[3].route_id = 4;
	routes[3].code = VK_CAPITAL;
	routes[3].axis = ERGOPTI_REPLAY_VK;
	routes[3].kind = ERGOPTI_REPLAY_CHARACTER;
	/* Invalid first registration cannot acquire lifecycle ownership. */
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_B, 1, 11,
		NULL, 1) == ERGOPTI_REPLAY_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11,
		routes, 4) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_B, 2, 11,
		routes, 4) == ERGOPTI_REPLAY_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	/* Event-time ownership starts before capture, independently of OS polling. */
	TEST_ASSERT(name, TestHookFlow(name, VK_LSHIFT, 0x2A,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_ListTerminalHeldRecipes(TEST_OWNER_A,
		retained, ERGOPTI_REPLAY_MAX_HELD_KEYS, &retained_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, retained_count == 1 && retained[0] == 1100);
	retained[0] = 9999;
	TEST_ASSERT(name, ErgoptiNav_ListTerminalHeldRecipes(TEST_OWNER_A,
		retained, 0, &retained_count) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, retained_count == 1 && retained[0] == 9999);
	TEST_ASSERT(name, ErgoptiNav_ListTerminalHeldRecipes(TEST_OWNER_B,
		retained, ERGOPTI_REPLAY_MAX_HELD_KEYS, &retained_count)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_ListTerminalHeldRecipes(TEST_OWNER_A,
		retained, ERGOPTI_REPLAY_MAX_HELD_KEYS, &retained_count)
		== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 2, 12,
		routes, 4) == ERGOPTI_NAV_TERMINAL_ROUTE_BUSY);
	for (index = 0; index < 6; ++index) {
		TEST_ASSERT(name, TestHookFlow(name, vks[index], scans[index], kinds[index],
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
		TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index,
			&snapshots[index]) == ERGOPTI_NAV_STATUS_OK);
		TEST_ASSERT(name, snapshots[index].token == TEST_OWNER_B);
		TEST_ASSERT(name, snapshots[index].sequence == index + 1);
		TEST_ASSERT(name, snapshots[index].route.event.source_id == 1);
		TEST_ASSERT(name, snapshots[index].route.event.scan == scans[index]);
		TEST_ASSERT(name, snapshots[index].route.event.origin == ERGOPTI_REPLAY_PHYSICAL);
		TEST_ASSERT(name, snapshots[index].route.observed_generation == 1);
		TEST_ASSERT(name, snapshots[index].route.observed_layout_id == 11);
	}
	for (index = 0; index < 3; ++index) {
		TEST_ASSERT(name, snapshots[index].route.status == ERGOPTI_REPLAY_OK);
		TEST_ASSERT(name, snapshots[index].route.route.recipe_id == 3300);
		TEST_ASSERT(name, snapshots[index].route.modifiers_lr_before == ERGOPTI_REPLAY_LSHIFT);
		TEST_ASSERT(name, snapshots[index].route.route_generation == 1);
		TEST_ASSERT(name, snapshots[index].route.route_layout_id == 11);
	}
	TEST_ASSERT(name, snapshots[1].route.event.repeat == 1);
	TEST_ASSERT(name, snapshots[2].route.event.key_up == 1);
	TEST_ASSERT(name, snapshots[3].route.modifiers_lr_before == ERGOPTI_REPLAY_LSHIFT);
	TEST_ASSERT(name, snapshots[3].route.modifiers_lr_after == 0);
	TEST_ASSERT(name, snapshots[4].route.status == ERGOPTI_REPLAY_UNREGISTERED);
	TEST_ASSERT(name, snapshots[5].route.status == ERGOPTI_REPLAY_UNREGISTERED);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_A, 0, &peek)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 6, &peek)
		== ERGOPTI_NAV_STATUS_NOT_FOUND);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, NULL)
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, 1, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, output_count == 1);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &capture)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, capture.queued == 5 && capture.replayed == 1);
	for (index = 0; index < 5; ++index) {
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index, &peek)
			== ERGOPTI_NAV_STATUS_OK);
		TEST_ASSERT(name, memcmp(&peek, &snapshots[index + 1], sizeof(peek)) == 0);
	}
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, UINT32_MAX, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, output_count == 5);
	TEST_ASSERT(name, ErgoptiNav_ListTerminalHeldRecipes(TEST_OWNER_A,
		retained, ERGOPTI_REPLAY_MAX_HELD_KEYS, &retained_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, retained_count == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &peek)
		== ERGOPTI_NAV_STATUS_NOT_FOUND);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 2, 12,
		routes, 4) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 2, 12,
		routes, 4) == ERGOPTI_REPLAY_STALE_REGISTRATION);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(name, VK_CAPITAL, 0x3A,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 1, &peek)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, peek.route.status == ERGOPTI_REPLAY_UNSUPPORTED);
	TEST_ASSERT(name, peek.route.event.vk == 'A');
	TEST_ASSERT(name, peek.route.route.recipe_id == 2200);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, VK_CAPITAL, 0x3A,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, output_count == 4);
	/* A missing prefix/dead/tap route cannot silently select a later base recipe. */
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 3, 12,
		routes, 4) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(name, 'B', 0x30,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 1, &peek)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, peek.route.status == ERGOPTI_REPLAY_UNSUPPORTED);
	TEST_ASSERT(name, peek.route.route.recipe_id == 2200);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, 'B', 0x30,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, output_count == 4);
	/* An OS bit may veto unknown startup state but cannot supply provenance. */
	{
		const uint16_t unknown_modifiers[1] = { VK_LMENU };
		TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, unknown_modifiers, 1)
			== ERGOPTI_NAV_STATUS_OK);
	}
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 4, 12,
		routes, 4) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &peek)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, peek.route.status == ERGOPTI_REPLAY_UNSUPPORTED);
	TEST_ASSERT(name, peek.route.modifiers_lr_before == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, output_count == 2);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	/* Clock wrap is real unsigned time; late and backwards edges stay explicit. */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11,
		routes, 4) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	{
		const uint32_t times[5] = { UINT32_MAX - 1u, 1u, UINT32_MAX, 2u, 1u };
		const uint64_t lifted[5] = {
			0xFFFFFFFEull, 0x100000001ull, 0xFFFFFFFFull,
			0x100000002ull, 0x100000001ull
		};
		const uint16_t clock_vks[5] = { 'A', 'A', 'B', 'B', 'B' };
		const uint16_t clock_scans[5] = { 0x1E, 0x1E, 0x30, 0x30, 0x30 };
		const uint8_t clock_edges[5] = {
			ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP
		};
		for (index = 0; index < 5; ++index) {
			TEST_ASSERT(name, ErgoptiNav_TestSetHookTime(times[index])
				== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, TestHookFlow(name, clock_vks[index], clock_scans[index],
				clock_edges[index], ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
				&result, &mask, &passed, &ordered));
			TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index, &peek)
				== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, peek.route.event.timestamp == lifted[index]);
			if (index == 2 || index == 4)
				TEST_ASSERT(name, peek.route.status == ERGOPTI_REPLAY_STALE_EVENT);
		}
	}
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, output, 8, &output_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, output_count == 5);
	return true;
}



/** Authenticates canonical previews without acknowledging or sending any edge. */
static bool TestTerminalOutputPreviewIsAuthenticatedAndGuarded(void)
{
	const char *name = "terminal output preview is authenticated and guarded (todo49-output-preview)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot before, after;
	ErgoptiNav_TerminalRouteSnapshot snapshots[5];
	ErgoptiNav_TerminalOutputPreview preview;
	ErgoptiOutput_Unit units[4];
	ErgoptiNav_TestEvent replayed[5];
	ErgoptiReplay_Route routes[2];
	uint64_t generation = 0;
	uint32_t index, replayed_count = 0;
	uint8_t mask = 0, passed = 0, ordered = 0;
	const uint16_t ascii[1] = { 0x78 };
	const uint16_t supplementary[2] = { 0xD83D, 0xDE00 };
	const uint16_t malformed[1] = { 0xD83D };
	const uint16_t vks[5] = { VK_LSHIFT, VK_LSHIFT, 'A', 'A', 'B' };
	const uint16_t scans[5] = { 0x2A, 0x2A, 0x1E, 0x1E, 0x30 };
	const uint8_t edges[5] = {
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_EVENT_DOWN
	};
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	memset(routes, 0, sizeof(routes));
	routes[0].recipe_id = 1100;
	routes[0].route_id = 1;
	routes[0].code = 0x2A;
	routes[0].axis = ERGOPTI_REPLAY_SCAN;
	routes[0].target_scan = 0x2A;
	routes[0].kind = ERGOPTI_REPLAY_MODIFIER;
	routes[0].effective_modifiers_lr = ERGOPTI_REPLAY_LSHIFT;
	routes[1].recipe_id = 2200;
	routes[1].route_id = 2;
	routes[1].code = 0x1E;
	routes[1].axis = ERGOPTI_REPLAY_SCAN;
	routes[1].kind = ERGOPTI_REPLAY_CHARACTER;
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11,
		routes, 2) == ERGOPTI_REPLAY_OK);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	for (index = 0; index < 5; ++index) {
		TEST_ASSERT(name, TestHookFlow(name, vks[index], scans[index], edges[index],
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
		TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, index,
			&snapshots[index]) == ERGOPTI_NAV_STATUS_OK);
	}
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &before)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 2, ascii, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.owner == TEST_OWNER_A && preview.token == TEST_OWNER_B);
	TEST_ASSERT(name, preview.sequence == snapshots[2].sequence && preview.plan_id != 0);
	TEST_ASSERT(name, preview.planner_status == ERGOPTI_OUTPUT_DIAGNOSTIC);
	TEST_ASSERT(name, preview.dispatchable == 0 && preview.unit_count == 2);
	TEST_ASSERT(name, preview.reserved == 0 && preview.reserved_tail[0] == 0);
	for (index = 0; index < 2; ++index) {
		TEST_ASSERT(name, units[index].kind == ERGOPTI_OUTPUT_UNICODE);
		TEST_ASSERT(name, units[index].utf16 == 0x78 && units[index].key_up == index);
		TEST_ASSERT(name, units[index].vk == 0 && units[index].scan == 0 && units[index].repeat == 0);
	}
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 2, supplementary, 2, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.unit_count == 4 && preview.dispatchable == 0);
	for (index = 0; index < 4; ++index) {
		TEST_ASSERT(name, units[index].utf16 == supplementary[index / 2]);
		TEST_ASSERT(name, units[index].key_up == index % 2);
	}
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 2, ascii, 1, &preview, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.unit_count == 2 && preview.dispatchable == 0);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[3].sequence, 3, NULL, 0, &preview, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.unit_count == 0 && preview.dispatchable == 0);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[0].sequence, 0, NULL, 0, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.unit_count == 1 && preview.dispatchable == 0);
	TEST_ASSERT(name, units[0].kind == ERGOPTI_OUTPUT_NATIVE_EDGE);
	TEST_ASSERT(name, units[0].scan == 0x2A && units[0].vk == 0 && units[0].key_up == 0);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[4].sequence, 4, NULL, 0, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, preview.unit_count == 0 && preview.dispatchable == 0);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_B, TEST_OWNER_B,
		snapshots[2].sequence, 2, ascii, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_A,
		snapshots[2].sequence, 2, ascii, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence + 1, 2, ascii, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 5, ascii, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_NOT_FOUND);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 2, malformed, 1, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[2].sequence, 2, ascii, 1, &preview, units, 1)
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, 1, replayed, 5, &replayed_count)
		== ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, replayed_count == 1);
	/* An array index cannot authorize a preview after an accepted prefix moved it. */
	TEST_ASSERT(name, ErgoptiNav_PreviewTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		snapshots[0].sequence, 0, NULL, 0, &preview, units, 4)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, replayed, 5, &replayed_count)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, replayed_count == 4);
	return true;
}



/** Couples accepted output prefixes to exactly one authenticated FIFO edge. */
static bool TestTerminalOutputCustodySettlesExactFifoHead(void)
{
	const char *name = "terminal output custody settles exact FIFO head (todo49-output-custody)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot before, after;
	ErgoptiNav_TerminalRouteSnapshot head, next, owned_head, observed_head;
	ErgoptiOutput_Key key, stale, next_key;
	ErgoptiOutput_Unit units[4], expected_suffix[3];
	ErgoptiReplay_Route route;
	ErgoptiNav_TestEvent replayed[4];
	uint64_t generation = 0, attempt = 0, first_attempt = 0;
	uint32_t count = 0, replayed_count = 0;
	uint8_t mask = 0, passed = 0, ordered = 0;
	const uint16_t text[2] = { 0xD83D, 0xDE00 };
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == ERGOPTI_NAV_STATUS_OK);
	memset(&route, 0, sizeof(route));
	route.recipe_id = 2200; route.route_id = 2; route.code = 0x1E;
	route.axis = ERGOPTI_REPLAY_SCAN; route.kind = ERGOPTI_REPLAY_CHARACTER;
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 1, &next) == 0);
	memcpy(&owned_head, &head, sizeof(owned_head));
	memset(&key, 0xA5, sizeof(key)); stale = key;
	/* The production-default guard cannot be opened through any public argument. */
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 2, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, memcmp(&key, &stale, sizeof(key)) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_B, TEST_OWNER_B,
		head.sequence, text, 2, &key) == ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_A,
		head.sequence, text, 2, &key) == ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		next.sequence, text, 2, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 2, &key) == 0);
	stale = key; ++stale.plan_id;
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &stale)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_B, &key)
		== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &before) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	count = 99; attempt = 99; memset(units, 0xA5, sizeof(units));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 3, &count, &attempt) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, count == 99 && attempt == 99 && units[0].reserved == 0xA5);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 4, &count, &attempt) == 0);
	TEST_ASSERT(name, count == 4 && attempt != 0);
	first_attempt = attempt;
	for (uint32_t i = 0; i < 4; ++i) {
		TEST_ASSERT(name, units[i].kind == ERGOPTI_OUTPUT_UNICODE && units[i].utf16 == text[i / 2]);
		TEST_ASSERT(name, units[i].key_up == i % 2 && units[i].reserved == 0);
	}
	memcpy(expected_suffix, units + 1, sizeof(expected_suffix));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 4, &count, &attempt) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(0) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 2, &next_key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, UINT32_MAX, replayed, 4, &replayed_count)
		== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, replayed_count == 0);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, replayed, 4, &replayed_count)
		== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key,
		first_attempt + 1, 1) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key,
		first_attempt, 5) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after) == 0);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, first_attempt, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key,
		first_attempt, 1) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	/* Authentic capture can append while the external output attempt is unsettled. */
	TEST_ASSERT(name, TestHookFlow(name, 'B', 0x30, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(name, 'B', 0x30, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 4, &count, &attempt) == 0);
	TEST_ASSERT(name, count == 3 && attempt != first_attempt);
	TEST_ASSERT(name, memcmp(units, expected_suffix, sizeof(expected_suffix)) == 0);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 4, &count, &attempt) == 0);
	TEST_ASSERT(name, count == 3 && memcmp(units, expected_suffix, sizeof(expected_suffix)) == 0);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 3) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after) == 0);
	TEST_ASSERT(name, after.queued == 4 && after.replayed == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &observed_head) == 0);
	TEST_ASSERT(name, memcmp(&owned_head, &observed_head, sizeof(owned_head)) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after) == 0);
	TEST_ASSERT(name, after.queued == 3 && after.replayed == 1);
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_STOP_PENDING);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after) == 0);
	TEST_ASSERT(name, after.queued == 3 && after.replayed == 1);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, head.sequence == next.sequence && memcmp(&head.route, &next.route, sizeof(head.route)) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, NULL, 0, &next_key) == 0);
	TEST_ASSERT(name, next_key.plan_id > key.plan_id);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &next_key) == 0);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	/* Unregistered metadata never turns into a silent zero-unit consumption. */
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, NULL, 0, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, replayed, 4, &replayed_count) == 0);
	TEST_ASSERT(name, replayed_count == 2 && replayed[0].sc == 0x30 && replayed[1].kind == ERGOPTI_NAV_EVENT_UP);
	/* Cancellation preserves the edge; a cancelled sequence cannot be replanned. */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 2, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 2, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &before) == 0);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &after) == 0);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 2, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCapture(TEST_OWNER_B,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT, UINT32_MAX, replayed, 4, &replayed_count) == 0);
	TEST_ASSERT(name, replayed_count == 1);
	return true;
}

/** Retains output attempt debt through stop reentry and capture overflow. */
static bool TestTerminalOutputCustodyPreservesFaultDebt(void)
{
	const char *name = "terminal output custody preserves fault debt (todo49-output-custody)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TerminalCaptureSnapshot receipt;
	ErgoptiNav_TerminalRouteSnapshot head, observed_head;
	ErgoptiOutput_Key key;
	ErgoptiOutput_Unit units[2];
	ErgoptiReplay_Route route;
	uint64_t generation = 0, attempt = 0;
	uint32_t count = 0;
	uint8_t mask = 0, passed = 0, ordered = 0;
	const uint16_t text[1] = { 0x78 };
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0) == 0);
	memset(&route, 0, sizeof(route));
	route.recipe_id = 2200; route.route_id = 2; route.code = 0x1E;
	route.axis = ERGOPTI_REPLAY_SCAN; route.kind = ERGOPTI_REPLAY_CHARACTER;
	TEST_ASSERT(name, ErgoptiNav_RegisterTerminalRoutes(TEST_OWNER_A, 1, 11, &route, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_TestAdmitTerminalOutput(1) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B) == 0);
	TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &head) == 0);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 1, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 2, &count, &attempt) == 0);
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_STOP_PENDING);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &receipt) == 0);
	TEST_ASSERT(name, receipt.queued == 1 && receipt.replayed == 0);
	TEST_ASSERT(name, ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A) == ERGOPTI_NAV_STATUS_BUSY);
	for (uint32_t i = 1; i <= ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY; ++i)
		TEST_ASSERT(name, TestHookFlow(name, 'A', 0x1E, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result, &mask, &passed, &ordered));
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &receipt) == 0);
	TEST_ASSERT(name, receipt.phase == ERGOPTI_NAV_TERMINAL_FAULTED);
	TEST_ASSERT(name, receipt.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_CancelTerminalOutput(TEST_OWNER_A, &key) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalOutputAttempt(TEST_OWNER_A, &key,
		units, 2, &count, &attempt) == 0);
	TEST_ASSERT(name, count == 1 && units[0].utf16 == 0x78 && units[0].key_up == 1);
	TEST_ASSERT(name, ErgoptiNav_PeekTerminalRoute(TEST_OWNER_B, 0, &observed_head) == 0);
	TEST_ASSERT(name, memcmp(&head, &observed_head, sizeof(head)) == 0);
	TEST_ASSERT(name, ErgoptiNav_AcknowledgeTerminalOutput(TEST_OWNER_A, &key, attempt, 1) == 0);
	TEST_ASSERT(name, ErgoptiNav_ConsumeTerminalOutput(TEST_OWNER_A, &key) == 0);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &receipt) == 0);
	TEST_ASSERT(name, receipt.phase == ERGOPTI_NAV_TERMINAL_FAULTED);
	TEST_ASSERT(name, receipt.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY - 1 && receipt.replayed == 1);
	TEST_ASSERT(name, ErgoptiNav_PlanTerminalOutput(TEST_OWNER_A, TEST_OWNER_B,
		head.sequence, text, 1, &key) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_AbortTerminalCapture(TEST_OWNER_B) == ERGOPTI_NAV_STATUS_OS_ERROR);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &receipt) == 0);
	TEST_ASSERT(name, receipt.phase == ERGOPTI_NAV_TERMINAL_FAULTED && receipt.replayed == 1);
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_STOP_PENDING);
	TEST_ASSERT(name, ErgoptiNav_GetTerminalCapture(TEST_OWNER_B, &receipt) == 0);
	TEST_ASSERT(name, receipt.phase == ERGOPTI_NAV_TERMINAL_FAULTED
		&& receipt.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY - 1 && receipt.replayed == 1);
	return true;
}



/** Rejects a replay marker when Win32 reports lower-integrity injection. */
static bool TestTerminalReplayCannotPromoteLowerIntegrity(void)
{
	const char *name = "terminal replay cannot promote lower integrity (todo49-replay-provenance)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	return true;
}



/** Keeps replay modifiers independent of the asynchronous physical-key snapshot. */
static bool TestTerminalReplayRetainsEffectiveModifiers(void)
{
	const char *name = "terminal replay retains effective modifiers (todo49-replay-modifiers)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	/* The physical key may already be up: the replayed down still owns Alt. */
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	return true;
}



/** Retires only the replay modifier owner when a physical release crosses it. */
static bool TestTerminalReplaySurvivesCrossedModifierReleases(void)
{
	const char *name = "terminal replay survives crossed modifier releases (todo49-replay-modifiers)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	uint64_t generation = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'2', 0x03, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	return true;
}



/** Records the replayed modifier before the production FIFO acknowledgement. */
typedef struct NavReplayModifierProbe {
	const char *name;
	bool accepted;
} NavReplayModifierProbe;



/** Exercises the actual hook converter during the deterministic send boundary. */
static void TestReplayHeldModifierObserver(void *context)
{
	NavReplayModifierProbe *probe = context;
	ErgoptiNav_DispatchResult result;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	probe->accepted = TestHookFlow(
		probe->name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_STANDARD,
		ERGOPTI_NAV_TERMINAL_REPLAY_MARKER,
		&result, &mask, &passed, &ordered);
}



/** Hands a replayed still-held modifier back to its later physical release. */
static bool TestTerminalReplayHandsOffHeldModifier(void)
{
	const char *name = "terminal replay hands off held modifier (todo49-replay-modifiers)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 7, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_TestEvent replayed;
	NavReplayModifierProbe probe = { name, false };
	uint64_t generation = 0;
	uint32_t replayed_count = 0;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, ErgoptiNav_TestReleaseTerminalCaptureObserved(
		TEST_OWNER_B, ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT, UINT32_MAX,
		&replayed, 1, &replayed_count, TestReplayHeldModifierObserver, &probe)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, probe.accepted && replayed_count == 1);
	/* The capture ended while Alt was held. Its ordinary up must finish it. */
	TEST_ASSERT(name, TestHookFlow(
		name, VK_LMENU, 0x38, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, TestHookFlow(
		name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
		&result, &mask, &passed, &ordered));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
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



/** Carries independent observations across the unlocked replay send boundary. */
typedef struct TestTerminalReleaseObservation {
	const char *name;
	uint64_t token;
	uint32_t release_kind;
	uint32_t calls;
	bool passed;
} TestTerminalReleaseObservation;



/** Carries actual worker-thread release results to the replay observer. */
typedef struct TestTerminalReleaseThreadObservation {
	uint64_t token;
	uint32_t release_kind;
	int32_t statuses[3];
	uint32_t counts[3];
} TestTerminalReleaseThreadObservation;



/** Competes for release ownership from another actual native thread. */
static DWORD WINAPI TestTerminalReleaseThread(void *raw_observation)
{
	TestTerminalReleaseThreadObservation *observation =
		(TestTerminalReleaseThreadObservation *)raw_observation;
	uint32_t other_kind = observation->release_kind
		== ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT
			? ERGOPTI_NAV_TERMINAL_RELEASE_ABORT
			: ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT;
	observation->statuses[0] = ErgoptiNav_TestReleaseTerminalCapture(
		observation->token, observation->release_kind, UINT32_MAX,
		NULL, 0, &observation->counts[0]);
	observation->statuses[1] = ErgoptiNav_TestReleaseTerminalCapture(
		observation->token, other_kind, UINT32_MAX,
		NULL, 0, &observation->counts[1]);
	observation->statuses[2] = ErgoptiNav_TestReleaseTerminalCapture(
		TEST_OWNER_B, observation->release_kind, UINT32_MAX,
		NULL, 0, &observation->counts[2]);
	return 0;
}



/** Joins a competing release caller without borrowing a timed-out stack. */
static bool TestTerminalReleaseThreadRefusals(
	const char *name,
	uint64_t token,
	uint32_t release_kind)
{
	TestTerminalReleaseThreadObservation *observation;
	HANDLE thread;
	DWORD wait_result;
	bool closed;
	bool expected;
	observation = (TestTerminalReleaseThreadObservation *)HeapAlloc(
		GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*observation));
	TEST_ASSERT(name, observation != NULL);
	observation->token = token;
	observation->release_kind = release_kind;
	thread = CreateThread(NULL, 0, TestTerminalReleaseThread, observation, 0, NULL);
	if (thread == NULL) {
		HeapFree(GetProcessHeap(), 0, observation);
		TEST_ASSERT(name, thread != NULL);
	}
	wait_result = WaitForSingleObject(thread, 5000);
	closed = CloseHandle(thread) != 0;
	/* On timeout the worker still owns its heap observation; leave it valid
	 * until the failing test process exits rather than freeing borrowed memory. */
	TEST_ASSERT(name, wait_result == WAIT_OBJECT_0);
	expected = observation->statuses[0] == ERGOPTI_NAV_STATUS_BUSY
		&& observation->statuses[1] == ERGOPTI_NAV_STATUS_BUSY
		&& observation->statuses[2] == ERGOPTI_NAV_STATUS_OWNER_MISMATCH
		&& observation->counts[0] == 0
		&& observation->counts[1] == 0
		&& observation->counts[2] == 0;
	TEST_ASSERT(name, HeapFree(GetProcessHeap(), 0, observation) != 0);
	TEST_ASSERT(name, closed);
	TEST_ASSERT(name, expected);
	return true;
}



/** Checks release refusals and captures fresh physical input during a send. */
static bool TestObserveTerminalRelease(TestTerminalReleaseObservation *observation)
{
	const char *name = observation->name;
	ErgoptiNav_TerminalCaptureSnapshot before;
	ErgoptiNav_TerminalCaptureSnapshot after;
	ErgoptiNav_TestEvent nested_events[8];
	ErgoptiNav_DispatchResult result;
	uint32_t nested_count = 9;
	uint32_t other_kind = observation->release_kind
		== ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT
			? ERGOPTI_NAV_TERMINAL_RELEASE_ABORT
			: ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT;
	uint8_t can_stop = 1;
	uint8_t complete = 1;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	++observation->calls;
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(observation->token, &before)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, before.phase == ERGOPTI_NAV_TERMINAL_REPLAYING);
	TEST_ASSERT(name, before.release_kind == observation->release_kind);
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			observation->token, observation->release_kind, UINT32_MAX,
			nested_events, 8, &nested_count) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, nested_count == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			observation->token, other_kind, UINT32_MAX,
			nested_events, 8, &nested_count) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name, nested_count == 0);
	TEST_ASSERT(name,
		ErgoptiNav_TestReleaseTerminalCapture(
			TEST_OWNER_B, observation->release_kind, UINT32_MAX,
			nested_events, 8, &nested_count)
				== ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, nested_count == 0);
	TEST_ASSERT(name, TestTerminalReleaseThreadRefusals(
		name, observation->token, observation->release_kind));
	TEST_ASSERT(name,
		ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(observation->token)
			== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
			== ERGOPTI_NAV_STATUS_BUSY);
	TEST_ASSERT(name,
		ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, can_stop == 0);
	TEST_ASSERT(name,
		ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_STOP_PENDING);
	TEST_ASSERT(name,
		ErgoptiNav_TestDrainComplete(&complete) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, complete == 0);
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(observation->token, &after)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, memcmp(&before, &after, sizeof(before)) == 0);
	if (observation->calls == 1) {
		/* Physical input may still join the tail while this prefix is in flight. */
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'B', 0x30, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, passed == 0 && mask == 0);
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'B', 0x30, ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, passed == 0 && mask == 0);
	}
	return true;
}



/** Invokes assertions through the same unlocked boundary used by SendInput. */
static void TestTerminalReleaseObserver(void *raw_observation)
{
	TestTerminalReleaseObservation *observation =
		(TestTerminalReleaseObservation *)raw_observation;
	if (!TestObserveTerminalRelease(observation))
		observation->passed = false;
}



/** Proves exact FIFO replay survives reentrant releases, failures and retries. */
static bool TestTerminalReleaseHasOneOwner(void)
{
	const char *name = "terminal release has one owner";
	const uint32_t kinds[2] = {
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT
	};
	const uint32_t limits[3] = { 0, 1, UINT32_MAX };
	const uint16_t scans[5] = { 0x1E, 0x1E, 0x14B, 0x30, 0x30 };
	const uint8_t edges[5] = {
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_EVENT_UP
	};
	uint32_t kind_index;
	uint32_t limit_index;
	for (kind_index = 0; kind_index < 2; ++kind_index) {
		for (limit_index = 0; limit_index < 3; ++limit_index) {
			TestTerminalReleaseObservation observation;
			ErgoptiNav_TerminalCaptureSnapshot snapshot;
			ErgoptiNav_TerminalCaptureSnapshot before_refusal;
			ErgoptiNav_DispatchResult result;
			ErgoptiNav_TestEvent replayed[5];
			uint32_t first_count = 0;
			uint32_t retry_count = 0;
			uint32_t refused_count = 9;
			uint32_t index;
			uint32_t other_kind = kinds[kind_index]
				== ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT
					? ERGOPTI_NAV_TERMINAL_RELEASE_ABORT
					: ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT;
			uint8_t can_stop = 0;
			uint8_t mask = 0;
			uint8_t passed = 0;
			uint8_t ordered = 0;
			int32_t status;
			TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A)
					== ERGOPTI_NAV_STATUS_OK);
			for (index = 0; index < 3; ++index) {
				TEST_ASSERT(name, TestHookFlow(
					name, index == 2 ? VK_LEFT : (uint16_t)'A',
					scans[index], edges[index],
					ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
					&result, &mask, &passed, &ordered));
				TEST_ASSERT(name,
					result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
			}
			memset(&observation, 0, sizeof(observation));
			observation.name = name;
			observation.token = TEST_OWNER_A;
			observation.release_kind = kinds[kind_index];
			observation.passed = true;
			status = ErgoptiNav_TestReleaseTerminalCaptureObserved(
				TEST_OWNER_A, kinds[kind_index], limits[limit_index],
				replayed, 5, &first_count,
				TestTerminalReleaseObserver, &observation);
			TEST_ASSERT(name, observation.passed);
			TEST_ASSERT(name, observation.calls
				== (limits[limit_index] == UINT32_MAX ? 2u : 1u));
			TEST_ASSERT(name, status == (limits[limit_index] == UINT32_MAX
				? ERGOPTI_NAV_STATUS_OK : ERGOPTI_NAV_STATUS_OS_ERROR));
			TEST_ASSERT(name, first_count
				== (limits[limit_index] == UINT32_MAX ? 5u : limits[limit_index]));
			TEST_ASSERT(name,
				ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
					== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, snapshot.token == TEST_OWNER_A);
			TEST_ASSERT(name, snapshot.release_kind == kinds[kind_index]);
			TEST_ASSERT(name, snapshot.replayed == first_count);
			TEST_ASSERT(name, snapshot.queued == 5u - first_count);
			TEST_ASSERT(name, snapshot.phase == (uint32_t)(first_count == 5
				? ERGOPTI_NAV_TERMINAL_IDLE
				: ERGOPTI_NAV_TERMINAL_RELEASE_PENDING));
			before_refusal = snapshot;
			TEST_ASSERT(name,
				ErgoptiNav_TestReleaseTerminalCapture(
					TEST_OWNER_A, other_kind, UINT32_MAX, NULL, 0,
					&refused_count) == ERGOPTI_NAV_STATUS_INVALID_STATE);
			TEST_ASSERT(name, refused_count == 0);
			TEST_ASSERT(name,
				ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
					== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				memcmp(&before_refusal, &snapshot, sizeof(snapshot)) == 0);
			TEST_ASSERT(name,
				ErgoptiNav_TestReleaseTerminalCapture(
					TEST_OWNER_A, kinds[kind_index], UINT32_MAX,
					&replayed[first_count], 5u - first_count, &retry_count)
						== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, first_count + retry_count == 5);
			for (index = 0; index < 5; ++index) {
				TEST_ASSERT(name, replayed[index].vk == 0);
				TEST_ASSERT(name, replayed[index].sc == scans[index]);
				TEST_ASSERT(name, replayed[index].kind == edges[index]);
				TEST_ASSERT(name,
					replayed[index].extra_info == ERGOPTI_NAV_TERMINAL_REPLAY_MARKER);
			}
			TEST_ASSERT(name,
				ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
					== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_IDLE);
			TEST_ASSERT(name, snapshot.queued == 0 && snapshot.replayed == 5);
			TEST_ASSERT(name,
				ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, can_stop == 1);
			TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
		}
	}
	return true;
}



/** Captures a terminal FIFO overflow while an earlier replay prefix is sent. */
static bool TestOverflowDuringTerminalRelease(TestTerminalReleaseObservation *observation)
{
	const char *name = observation->name;
	ErgoptiNav_TerminalCaptureSnapshot snapshot;
	ErgoptiNav_DispatchResult result;
	uint32_t index;
	uint8_t mask = 0;
	uint8_t passed = 0;
	uint8_t ordered = 0;
	++observation->calls;
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(observation->token, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, snapshot.queued == 3);
	TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_REPLAYING);
	for (index = 3; index <= ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY; ++index) {
		TEST_ASSERT(name, TestHookFlow(
			name, (uint16_t)'C', 0x2E, ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
			&result, &mask, &passed, &ordered));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, result.receipt_created == 0 && passed == 0 && mask == 0);
	}
	TEST_ASSERT(name,
		ErgoptiNav_GetTerminalCapture(observation->token, &snapshot)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_FAULTED);
	TEST_ASSERT(name, snapshot.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY);
	TEST_ASSERT(name, snapshot.last_os_error == ERROR_NOT_ENOUGH_MEMORY);
	return true;
}



/** Invokes the overflow probe from the actual unlocked replay send boundary. */
static void TestTerminalReleaseOverflowObserver(void *raw_observation)
{
	TestTerminalReleaseObservation *observation =
		(TestTerminalReleaseObservation *)raw_observation;
	if (!TestOverflowDuringTerminalRelease(observation))
		observation->passed = false;
}



/** Proves send completion cannot clear an overflow fault or retry lost input. */
static bool TestTerminalReleasePreservesConcurrentOverflow(void)
{
	const char *name = "terminal release preserves concurrent overflow";
	const uint32_t kinds[2] = {
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT
	};
	const uint32_t limits[3] = { 0, 1, UINT32_MAX };
	const uint16_t scans[3] = { 0x1E, 0x1E, 0x14B };
	const uint8_t edges[3] = {
		ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_EVENT_DOWN
	};
	uint32_t kind_index;
	uint32_t limit_index;
	for (kind_index = 0; kind_index < 2; ++kind_index) {
		for (limit_index = 0; limit_index < 3; ++limit_index) {
			TestTerminalReleaseObservation observation;
			ErgoptiNav_TerminalCaptureSnapshot snapshot;
			ErgoptiNav_TerminalCaptureSnapshot before_retry;
			ErgoptiNav_DispatchResult result;
			ErgoptiNav_TestEvent replayed[3];
			uint32_t replayed_count = 0;
			uint32_t retry_count = 9;
			uint32_t accepted = limits[limit_index] == UINT32_MAX
				? 3u : limits[limit_index];
			uint32_t index;
			uint8_t can_stop = 1;
			uint8_t mask = 0;
			uint8_t passed = 0;
			uint8_t ordered = 0;
			TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				ErgoptiNav_BeginTerminalCapture(TEST_OWNER_A)
					== ERGOPTI_NAV_STATUS_OK);
			for (index = 0; index < 3; ++index) {
				TEST_ASSERT(name, TestHookFlow(
					name, index == 2 ? VK_LEFT : (uint16_t)'A',
					scans[index], edges[index], ERGOPTI_NAV_INJECTION_PHYSICAL, 0,
					&result, &mask, &passed, &ordered));
			}
			memset(&observation, 0, sizeof(observation));
			observation.name = name;
			observation.token = TEST_OWNER_A;
			observation.release_kind = kinds[kind_index];
			observation.passed = true;
			TEST_ASSERT(name,
				ErgoptiNav_TestReleaseTerminalCaptureObserved(
					TEST_OWNER_A, kinds[kind_index], limits[limit_index],
					replayed, 3, &replayed_count,
					TestTerminalReleaseOverflowObserver, &observation)
						== ERGOPTI_NAV_STATUS_OS_ERROR);
			TEST_ASSERT(name, observation.passed && observation.calls == 1);
			TEST_ASSERT(name, replayed_count == accepted);
			for (index = 0; index < accepted; ++index) {
				TEST_ASSERT(name, replayed[index].vk == 0);
				TEST_ASSERT(name, replayed[index].sc == scans[index]);
				TEST_ASSERT(name, replayed[index].kind == edges[index]);
				TEST_ASSERT(name,
					replayed[index].extra_info == ERGOPTI_NAV_TERMINAL_REPLAY_MARKER);
			}
			TEST_ASSERT(name,
				ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
					== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, snapshot.token == TEST_OWNER_A);
			TEST_ASSERT(name, snapshot.release_kind == kinds[kind_index]);
			TEST_ASSERT(name, snapshot.phase == ERGOPTI_NAV_TERMINAL_FAULTED);
			TEST_ASSERT(name,
				snapshot.queued == ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY - accepted);
			TEST_ASSERT(name, snapshot.replayed == accepted);
			TEST_ASSERT(name, snapshot.last_os_error == ERROR_NOT_ENOUGH_MEMORY);
			TEST_ASSERT(name, ErgoptiNav_GetLastOsError() == ERROR_NOT_ENOUGH_MEMORY);
			before_retry = snapshot;
			TEST_ASSERT(name,
				ErgoptiNav_TestReleaseTerminalCapture(
					TEST_OWNER_A, kinds[kind_index], UINT32_MAX,
					NULL, 0, &retry_count) == ERGOPTI_NAV_STATUS_OS_ERROR);
			TEST_ASSERT(name, retry_count == 0);
			TEST_ASSERT(name,
				ErgoptiNav_GetTerminalCapture(TEST_OWNER_A, &snapshot)
					== ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name,
				memcmp(&before_retry, &snapshot, sizeof(snapshot)) == 0);
			TEST_ASSERT(name,
				ErgoptiNav_SetSuspended(1) == ERGOPTI_NAV_STATUS_BUSY);
			TEST_ASSERT(name,
				ErgoptiNav_BeginTerminalCapture(TEST_OWNER_B)
					== ERGOPTI_NAV_STATUS_BUSY);
			TEST_ASSERT(name,
				ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
			TEST_ASSERT(name, can_stop == 0);
			/* The hook-free fixture owns no OS thread; retire its synthetic state. */
			TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
		}
	}
	return true;
}



/**
 * Proves a passed first down cannot become suppressed after modifiers change.
 *
 * @return True when one physical hold keeps its initial disposition.
 */
static bool TestUnmatchedDownLatchesPassAcrossModifiers(void)
{
	const char *name = "unmatched down latches pass across modifiers";
	ErgoptiNav_ProfileOwner owner = TestProfileOwner(TEST_OWNER_A, 9);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation = 0;
	uint8_t can_stop = 1;

	TEST_ASSERT(name, TestResetWithPlan(name, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestPublishProfileOwner(name, 0, &owner, NULL));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_NOT_FOUND);

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);
	TEST_ASSERT(name,
		ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, can_stop == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'1', ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	return true;
}



/**
 * Presses and releases one physical digit through the hook tracker.
 *
 * @param test_name Stable test name for assertions.
 * @param expected Expected disposition of the down edge.
 * @return True when the down edge has the expected disposition.
 */
static bool TestStaleModifierDigit(
	const char *test_name,
	uint8_t expected)
{
	ErgoptiNav_DispatchResult result;
	TEST_ASSERT(test_name, TestHookDispatch(
		test_name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_DOWN,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(test_name, result.disposition == expected);
	TEST_ASSERT(test_name, result.receipt_created
		== (expected == ERGOPTI_NAV_DISPOSITION_SUPPRESS ? 1 : 0));
	TEST_ASSERT(test_name, TestHookDispatch(
		test_name, (uint16_t)'1', 0x02, ERGOPTI_NAV_EVENT_UP,
		ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
	TEST_ASSERT(test_name, result.disposition == expected);
	return true;
}



/**
 * Presses physical modifiers through the hook tracker without releasing them.
 *
 * @param test_name Stable test name for assertions.
 * @param vks Left/right modifier virtual keys.
 * @param scs Matching scan codes.
 * @param count Number of modifiers.
 * @return True when every down edge passed.
 */
static bool TestPressPhysicalModifiers(
	const char *test_name,
	const uint16_t *vks,
	const uint16_t *scs,
	uint32_t count)
{
	ErgoptiNav_DispatchResult result;
	uint32_t index;
	for (index = 0; index < count; ++index) {
		TEST_ASSERT(test_name, TestHookDispatch(
			test_name, vks[index], scs[index], ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_INJECTION_PHYSICAL, 0, &result));
		TEST_ASSERT(test_name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	}
	return true;
}



/**
 * Proves a modifier whose release the hook never saw cannot keep a route armed
 * (nav-stale-physical-modifier). A secure desktop, an AltGr fake Ctrl or an
 * upstream hook can swallow the up edge; the OS then reports the key up while
 * the tracked bit stays set, and every digit became a swallowed chord.
 *
 * @return True when stale bits pass the digit and real holds still route.
 */
static bool TestStalePhysicalModifierCannotArmRoutes(void)
{
	const char *name = "nav-stale-physical-modifier";
	const uint16_t ctrl_vk[] = {VK_LCONTROL};
	const uint16_t ctrl_sc[] = {0x1D};
	const uint16_t alt_vk[] = {VK_LMENU};
	const uint16_t alt_sc[] = {0x38};
	const uint16_t chord_vk[] = {VK_LCONTROL, VK_LSHIFT};
	const uint16_t chord_sc[] = {0x1D, 0x2A};
	ErgoptiNav_ProfileOwner profile_owner = TestProfileOwner(TEST_OWNER_B, 4);
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 3, 1);
	uint64_t generation = 0;

	/* Ctrl+digit profile routes. */
	TEST_ASSERT(name, TestResetWithPlan(name, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestPublishProfileOwner(name, 0, &profile_owner, NULL));
	TEST_ASSERT(name, TestPressPhysicalModifiers(name, ctrl_vk, ctrl_sc, 1));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_PASS));
	TEST_ASSERT(name, TestPressPhysicalModifiers(name, ctrl_vk, ctrl_sc, 1));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, ctrl_vk, 1)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_SUPPRESS));
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	/* Alt+digit prediction jumps, the default validation chord. */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestPressPhysicalModifiers(name, alt_vk, alt_sc, 1));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_PASS));
	TEST_ASSERT(name, TestPressPhysicalModifiers(name, alt_vk, alt_sc, 1));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, alt_vk, 1)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_SUPPRESS));
	TEST_ASSERT(name, TestDrainReceipts(name, 1));

	/* A configured Ctrl+Shift chord with only Shift stale. */
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestCommitPlanAtModifiers(name, 0,
		(uint8_t)(ERGOPTI_NAV_MOD_CONTROL | ERGOPTI_NAV_MOD_SHIFT)));
	TEST_ASSERT(name,
		TestPressPhysicalModifiers(name, chord_vk, chord_sc, 2));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, ctrl_vk, 1)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_PASS));
	TEST_ASSERT(name,
		TestPressPhysicalModifiers(name, chord_vk, chord_sc, 2));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(1, chord_vk, 2)
		== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestStaleModifierDigit(name, ERGOPTI_NAV_DISPOSITION_SUPPRESS));
	TEST_ASSERT(name, TestDrainReceipts(name, 1));
	TEST_ASSERT(name, ErgoptiNav_TestSetOsModifierKeys(0, NULL, 0)
		== ERGOPTI_NAV_STATUS_OK);
	return true;
}



/**
 * Proves an admitted profile target keeps its event-time owner across reorder.
 *
 * @return True when the old receipt remains exact and the new owner is isolated.
 */
static bool TestProfileReceiptSurvivesOrderSwap(void)
{
	const char *name = "profile receipt survives order swap";
	ErgoptiNav_Binding plan[ERGOPTI_NAV_PROFILE_ROUTE_COUNT];
	ErgoptiNav_ProfileOwner owner_a = TestProfileOwner(TEST_OWNER_A, 7);
	ErgoptiNav_ProfileOwner owner_b = TestProfileOwner(TEST_OWNER_B, 7);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation = 0;
	uint64_t ticket = 0;
	uint16_t pending_mask = 0;
	uint8_t can_stop = 1;

	TEST_ASSERT(name, TestResetWithPlan(name, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestPublishProfileOwner(name, 0, &owner_a, NULL));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, result.receipt_created == 1);

	TestBuildProfilePlan(plan);
	TEST_ASSERT(name,
		ErgoptiNav_BeginProfileSwap(
			TEST_OWNER_A,
			plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT,
			&owner_b,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending_mask == (uint16_t)(1u << 5));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name,
		ErgoptiNav_CommitProfileSwap(ticket) == ERGOPTI_NAV_STATUS_OK);

	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.owner_token == TEST_OWNER_A);
	TEST_ASSERT(name, receipt.owner_epoch == TEST_SHARED_EPOCH);
	TEST_ASSERT(name, receipt.action == ERGOPTI_NAV_ACTION_PROFILE_SELECT);
	TEST_ASSERT(name, receipt.from_index == 0);
	TEST_ASSERT(name, receipt.target_index == 6);
	TEST_ASSERT(name,
		ErgoptiNav_ProfilePendingMask(TEST_OWNER_A, &pending_mask)
			== ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending_mask == (uint16_t)(1u << 5));
	TEST_ASSERT(name,
		TestDispatch(
			name, (uint16_t)'6', ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, can_stop == 0);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		ErgoptiNav_CanStop(&can_stop) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, can_stop == 1);

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.owner_token == TEST_OWNER_B);
	TEST_ASSERT(name, receipt.target_index == 6);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	return true;
}



/**
 * Proves queued and claimed targets freeze profile admission during a swap.
 *
 * @return True when the target mask and abort fence are exact.
 */
static bool TestProfileTransitionFreezesPendingTargets(void)
{
	const char *name = "profile transition freezes pending targets";
	ErgoptiNav_Binding plan[ERGOPTI_NAV_PROFILE_ROUTE_COUNT];
	ErgoptiNav_ProfileOwner owner_a = TestProfileOwner(TEST_OWNER_A, 9);
	ErgoptiNav_ProfileOwner owner_b = TestProfileOwner(TEST_OWNER_B, 9);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt claimed;
	uint64_t generation = 0;
	uint64_t ticket = 0;
	uint16_t pending_mask = 0;
	uint8_t target;

	TEST_ASSERT(name, TestResetWithPlan(name, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestPublishProfileOwner(name, 0, &owner_a, NULL));
	for (target = 5; target <= 6; ++target) {
		TEST_ASSERT(name, TestDispatch(
			name, (uint16_t)('0' + target), ERGOPTI_NAV_EVENT_DOWN,
			ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
		TEST_ASSERT(name,
			result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
		TEST_ASSERT(name, TestDispatch(
			name, (uint16_t)('0' + target), ERGOPTI_NAV_EVENT_UP,
			ERGOPTI_NAV_MOD_CONTROL, 0, 0, &result));
	}
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&claimed) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, claimed.target_index == 5);

	TestBuildProfilePlan(plan);
	TEST_ASSERT(name,
		ErgoptiNav_BeginProfileSwap(
			TEST_OWNER_A,
			plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT,
			&owner_b,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, pending_mask == 0x30u);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name,
		ErgoptiNav_AbortProfileSwap(ticket) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'7', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			claimed.sequence,
			claimed.owner_token,
			claimed.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDrainReceipts(name, 2));
	return true;
}



/**
 * Proves an active tooltip owns a colliding chord before the profile domain.
 *
 * @return True when an ineligible nav target passes rather than selecting a profile.
 */
static bool TestNavigationPrecedesProfileSelection(void)
{
	const char *name = "navigation precedes profile selection";
	ErgoptiNav_Owner nav_owner = TestOwner(TEST_OWNER_A, 5, 1);
	ErgoptiNav_Owner no_nav_owner;
	ErgoptiNav_ProfileOwner profile_owner = TestProfileOwner(TEST_OWNER_B, 9);
	ErgoptiNav_DispatchResult result;
	ErgoptiNav_Receipt receipt;
	uint64_t generation = 0;
	memset(&no_nav_owner, 0, sizeof(no_nav_owner));

	TEST_ASSERT(name, TestSetupOwner(name, &nav_owner, &generation));
	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name,
		TestCommitPlanAtModifiers(name, 0, ERGOPTI_NAV_MOD_CONTROL));
	TEST_ASSERT(name, TestPublishProfileOwner(name, 0, &profile_owner, NULL));

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, result.receipt_created == 0);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));

	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'4', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.action == ERGOPTI_NAV_ACTION_JUMP);
	TEST_ASSERT(name, receipt.owner_token == TEST_OWNER_A);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'4', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));

	TEST_ASSERT(name, TestPublishOwner(name, TEST_OWNER_A, &no_nav_owner));
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_DOWN, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS);
	TEST_ASSERT(name,
		ErgoptiNav_PollReceipt(&receipt) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, receipt.action == ERGOPTI_NAV_ACTION_PROFILE_SELECT);
	TEST_ASSERT(name, receipt.owner_token == TEST_OWNER_B);
	TEST_ASSERT(name, receipt.target_index == 6);
	TEST_ASSERT(name,
		ErgoptiNav_CompleteReceipt(
			receipt.sequence,
			receipt.owner_token,
			receipt.target_index) == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, TestDispatch(
		name, (uint16_t)'6', ERGOPTI_NAV_EVENT_UP, ERGOPTI_NAV_MOD_CONTROL,
		0, 0, &result));
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
	ErgoptiNav_Binding profile_plan[ERGOPTI_NAV_PROFILE_ROUTE_COUNT];
	ErgoptiNav_ProfileOwner profile_owner = TestProfileOwner(TEST_OWNER_A, 9);
	uint64_t generation = 0;
	uint64_t ticket = 0;
	uint16_t pending_mask = 0;
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

	TEST_ASSERT(name,
		ErgoptiNav_TestSetRunning(1) == ERGOPTI_NAV_STATUS_OK);
	TestBuildProfilePlan(profile_plan);
	TEST_ASSERT(name,
		ErgoptiNav_BeginProfileSwap(
			0,
			profile_plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT - 1u,
			&profile_owner,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	profile_plan[8].target = 8;
	TEST_ASSERT(name,
		ErgoptiNav_BeginProfileSwap(
			0,
			profile_plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT,
			&profile_owner,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TestBuildProfilePlan(profile_plan);
	profile_owner.profile_count = 0;
	TEST_ASSERT(name,
		ErgoptiNav_BeginProfileSwap(
			0,
			profile_plan,
			ERGOPTI_NAV_PROFILE_ROUTE_COUNT,
			&profile_owner,
			&ticket,
			&pending_mask) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ticket == 0);
	return true;
}




// =============================
// =============================
// ======= 3/ Test Runner =======
// =============================
// =============================

/** Refusal paths never establish foreground ownership or overwrite output. */
static bool TestHookTraceRefusesUnauthenticatedSessions(void)
{
	const char *name = "hook trace refuses unauthenticated sessions (todo49-hook-trace)";
	ErgoptiTrace_Entry entry, saved_entry;
	ErgoptiTrace_Receipt receipt, saved_receipt;
	memset(&entry, 0x55, sizeof(entry)); saved_entry = entry;
	memset(&receipt, 0xAA, sizeof(receipt)); saved_receipt = receipt;
	TEST_ASSERT(name, ErgoptiNav_Stop() == ERGOPTI_NAV_STATUS_OK);
	TEST_ASSERT(name, ErgoptiNav_StartHookTrace(0, 81, 1) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_StartHookTrace(TEST_OWNER_A, 0, 1) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_StartHookTrace(TEST_OWNER_A, 81, 0) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	/* A semantic test token is not an owned foreground HWND on any platform. */
	TEST_ASSERT(name, ErgoptiNav_StartHookTrace(TEST_OWNER_A, 81, 1) == ERGOPTI_NAV_STATUS_OWNER_MISMATCH);
	TEST_ASSERT(name, ErgoptiNav_ReadHookTrace(0, 81, 1, 0, &entry, 1, &receipt)
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_ReadHookTrace(TEST_OWNER_A, 81, 1, 0, &entry, 257, &receipt)
		== ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_ReadHookTrace(TEST_OWNER_A, 81, 1, 0, &entry, 1, &receipt)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, ErgoptiNav_StopHookTrace(0, 81, 1) == ERGOPTI_NAV_STATUS_INVALID_ARGUMENT);
	TEST_ASSERT(name, ErgoptiNav_StopHookTrace(TEST_OWNER_A, 81, 1) == ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, memcmp(&entry, &saved_entry, sizeof(entry)) == 0);
	TEST_ASSERT(name, memcmp(&receipt, &saved_receipt, sizeof(receipt)) == 0);
	return true;
}

/** Hook-shaped deterministic dispatch must never create authenticated evidence. */
static bool TestHookTraceDoesNotQualifyTestDispatch(void)
{
	const char *name = "hook trace excludes deterministic dispatch (todo49-hook-trace)";
	ErgoptiNav_Owner owner = TestOwner(TEST_OWNER_A, 2, 1);
	ErgoptiNav_DispatchResult result;
	ErgoptiTrace_Receipt receipt, saved;
	uint64_t generation;
	TEST_ASSERT(name, TestSetupOwner(name, &owner, &generation));
	TEST_ASSERT(name, TestDispatch(name, (uint16_t)'A', ERGOPTI_NAV_EVENT_DOWN, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	TEST_ASSERT(name, TestDispatch(name, (uint16_t)'A', ERGOPTI_NAV_EVENT_UP, 0, 0, 0, &result));
	TEST_ASSERT(name, result.disposition == ERGOPTI_NAV_DISPOSITION_PASS);
	memset(&receipt, 0xAA, sizeof(receipt)); saved = receipt;
	TEST_ASSERT(name, ErgoptiNav_ReadHookTrace(TEST_OWNER_A, 81, 1, 0, NULL, 0, &receipt)
		== ERGOPTI_NAV_STATUS_INVALID_STATE);
	TEST_ASSERT(name, memcmp(&receipt, &saved, sizeof(receipt)) == 0);
	return true;
}

/**
 * Runs every deterministic native navigation-owner regression.
 *
 * @return Zero when every test passes or one after the first failure set.
 */
int main(int argc, char **argv)
{
	uint32_t index;
	uint32_t passed = 0;
	/* Irrecoverable simulated lost-edge debt owns the final process lifetime. */
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
		{"terminal route snapshots retain exact suffix (todo49-route-fifo)",
			TestTerminalRouteSnapshotsRetainExactSuffix},
		{"terminal output preview is authenticated and guarded (todo49-output-preview)",
			TestTerminalOutputPreviewIsAuthenticatedAndGuarded},
		{"terminal output custody settles exact FIFO head (todo49-output-custody)",
			TestTerminalOutputCustodySettlesExactFifoHead},
		{"terminal replay cannot promote lower integrity (todo49-replay-provenance)",
			TestTerminalReplayCannotPromoteLowerIntegrity},
		{"terminal replay retains effective modifiers (todo49-replay-modifiers)",
			TestTerminalReplayRetainsEffectiveModifiers},
		{"terminal replay survives crossed modifier releases (todo49-replay-modifiers)",
			TestTerminalReplaySurvivesCrossedModifierReleases},
		{"terminal replay hands off held modifier (todo49-replay-modifiers)",
			TestTerminalReplayHandsOffHeldModifier},
		{"terminal capture partial replay is retryable",
			TestTerminalCapturePartialReplayIsRetryable},
		{"terminal capture admission and overflow",
			TestTerminalCaptureAdmissionAndOverflow},
		{"terminal release has one owner", TestTerminalReleaseHasOneOwner},
		{"terminal release preserves concurrent overflow",
			TestTerminalReleasePreservesConcurrentOverflow},
		{"unmatched down latches pass across modifiers",
			TestUnmatchedDownLatchesPassAcrossModifiers},
		{"profile receipt survives order swap",
			TestProfileReceiptSurvivesOrderSwap},
		{"profile transition freezes pending targets",
			TestProfileTransitionFreezesPendingTargets},
		{"navigation precedes profile selection",
			TestNavigationPrecedesProfileSelection},
		{"plan validation is atomic", TestPlanValidationIsAtomic},
		{"nav-stale-physical-modifier",
			TestStalePhysicalModifierCannotArmRoutes},
		{"hook trace refuses unauthenticated sessions (todo49-hook-trace)",
			TestHookTraceRefusesUnauthenticatedSessions},
		{"hook trace excludes deterministic dispatch (todo49-hook-trace)",
			TestHookTraceDoesNotQualifyTestDispatch},
		{"native editor receiver matrix", ErgoptiEditor_TestReplacements},
		{"terminal output custody preserves fault debt (todo49-output-custody)",
			TestTerminalOutputCustodyPreservesFaultDebt}
	};
	uint32_t test_count = (uint32_t)(sizeof(tests) / sizeof(tests[0]));
	uint32_t selected_count = test_count;
	if (argc > 2) {
		fprintf(stderr, "Expected at most one exact native test name.\n");
		return 2;
	}
	if (argc == 2) {
		selected_count = 0;
		for (index = 0; index < test_count; ++index) {
			if (strcmp(tests[index].name, argv[1]) == 0)
				++selected_count;
		}
		if (selected_count != 1) {
			fprintf(stderr, "Unknown or ambiguous native test name: %s\n", argv[1]);
			return 2;
		}
	}

	for (index = 0; index < test_count; ++index) {
		if (argc == 2 && strcmp(tests[index].name, argv[1]) != 0)
			continue;
		if (!tests[index].function()) {
			fprintf(stderr, "Native navigation-owner tests stopped after %u/%u passes.\n",
				passed, selected_count);
			ErgoptiNav_Stop();
			return 1;
		}
		++passed;
		printf("PASS %s\n", tests[index].name);
	}
	ErgoptiNav_Stop();
	printf("Native navigation-owner tests passed: %u/%u.\n", passed, selected_count);
	return 0;
}
