// static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner.c
/**
 * @file nav_event_owner.c
 * @brief Native atomic owner for Windows LLM navigation keyboard events.
 *
 * A dedicated Win32 thread owns WH_KEYBOARD_LL and runs a bounded state machine
 * which never calls into AutoHotkey. The same state machine backs TestDispatch,
 * making suppression, receipt reservation, owner transitions, injection levels,
 * and key-hold balancing deterministic under unit test.
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "nav_event_owner.h"





// ====================================
// ====================================
// ======= 1/ Internal State =======
// ====================================
// ====================================

#define NAV_HOOK_START_TIMEOUT_MS 5000u
#define NAV_HOOK_STOP_TIMEOUT_MS 5000u
#define NAV_LOCK_SPIN_COUNT 4000u
#define NAV_HELD_KEY_CAPACITY 32u
#define NAV_INJECTED_MODIFIER_CAPACITY 16u
#define NAV_TERMINAL_REPLAY_BATCH 128u

#define NAV_RECEIPT_EMPTY 0u
#define NAV_RECEIPT_QUEUED 1u
#define NAV_RECEIPT_CLAIMED 2u

#define NAV_HOLD_PASS 1u
#define NAV_HOLD_SUPPRESS 2u

#define NAV_MOD_LCONTROL 0x01u
#define NAV_MOD_RCONTROL 0x02u
#define NAV_MOD_LALT 0x04u
#define NAV_MOD_RALT 0x08u
#define NAV_MOD_LSHIFT 0x10u
#define NAV_MOD_RSHIFT 0x20u
#define NAV_MOD_LWIN 0x40u
#define NAV_MOD_RWIN 0x80u

/** Stores one queued or claimed immutable receipt. */
typedef struct NavReceiptSlot {
	uint8_t state;
	ErgoptiNav_Receipt receipt;
} NavReceiptSlot;

/** Retains the pass/suppress decision for one consumed physical key hold. */
typedef struct NavHeldKey {
	uint8_t active;
	uint8_t mode;
	uint8_t axis;
	uint8_t injected;
	uint16_t code;
	uint8_t reserved[2];
	uint64_t extra_info;
} NavHeldKey;

/** Retains one admitted injected modifier until its exact provenance releases. */
typedef struct NavInjectedModifierHold {
	uint8_t active;
	uint8_t modifier_bit;
	uint8_t reserved[6];
	uint64_t extra_info;
} NavInjectedModifierHold;

/** Retains one exact physical keyboard edge until terminal output releases it. */
typedef struct NavTerminalKeyEdge {
	uint16_t vk;
	uint16_t sc;
	uint8_t key_up;
	uint8_t extended;
	uint8_t reserved[2];
} NavTerminalKeyEdge;

/** Injectable SendInput boundary shared by production and hook-free tests. */
typedef uint32_t (*NavTerminalSendFn)(
	const INPUT *events,
	uint32_t event_count,
	void *context);

/** Owns every mutable field shared by the API and hook thread. */
typedef struct NavState {
	CRITICAL_SECTION lock;
	HANDLE thread_handle;
	HANDLE ready_event;
	HANDLE stop_event;
	DWORD thread_id;
	HHOOK hook;
	HWND wake_window;
	UINT wake_message;
	DWORD last_os_error;
	int32_t thread_start_status;
	int32_t thread_exit_status;
	uint8_t running;
	uint8_t suspended;
	uint8_t transition;
	uint8_t physical_modifiers_lr;
	uint8_t active_plan_valid;
	uint8_t prepared_plan_valid;
	uint8_t startup_cancelled;
	uint8_t draining;
	uint8_t menu_guard_passed_lr;
	uint8_t menu_undisguised;
	uint8_t downstream_modifiers_lr;
	uint8_t held_key_overflowed;
	uint8_t menu_guard_suppressed_lr;
	ErgoptiNav_Binding active_plan[ERGOPTI_NAV_ROUTE_COUNT];
	ErgoptiNav_Binding prepared_plan[ERGOPTI_NAV_ROUTE_COUNT];
	uint64_t active_plan_generation;
	uint64_t prepared_plan_generation;
	uint64_t next_plan_generation;
	ErgoptiNav_Owner active_owner;
	ErgoptiNav_Owner staged_owner;
	uint64_t active_swap_ticket;
	uint64_t next_swap_ticket;
	uint64_t next_receipt_sequence;
	NavReceiptSlot receipts[ERGOPTI_NAV_RECEIPT_CAPACITY];
	NavHeldKey held_keys[NAV_HELD_KEY_CAPACITY];
	NavInjectedModifierHold injected_modifiers[
		NAV_INJECTED_MODIFIER_CAPACITY];
	uint64_t terminal_token;
	uint32_t terminal_phase;
	uint32_t terminal_queued;
	uint32_t terminal_replayed;
	uint32_t terminal_last_os_error;
	uint32_t terminal_release_kind;
	NavTerminalKeyEdge terminal_events[ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY];
} NavState;

static INIT_ONCE g_nav_init_once = INIT_ONCE_STATIC_INIT;
static NavState g_nav_state;
static HINSTANCE g_nav_module;
static DWORD g_nav_initialization_error;

static LRESULT CALLBACK NavLowLevelKeyboardProc(
	int code,
	WPARAM message,
	LPARAM data_pointer);
static uint8_t NavRoutingModifiersLocked(const NavState *state);
static uint8_t NavModifierBit(uint16_t vk, uint16_t sc);



/**
 * Captures the module handle without performing work under the loader lock.
 *
 * @param module Module instance supplied by the Windows loader.
 * @param reason Loader notification reason.
 * @param reserved Loader-owned reserved pointer.
 * @return TRUE because no attach path can fail.
 */
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved)
{
	(void)reserved;
	if (reason == DLL_PROCESS_ATTACH) {
		g_nav_module = module;
		DisableThreadLibraryCalls(module);
	}
	return TRUE;
}



/**
 * Initializes the process-wide state lock exactly once.
 *
 * @param once Win32 initialization token.
 * @param parameter Unused callback parameter.
 * @param context Unused callback context output.
 * @return TRUE when the lock is available.
 */
static BOOL CALLBACK NavInitializeOnce(
	PINIT_ONCE once,
	PVOID parameter,
	PVOID *context)
{
	(void)once;
	(void)parameter;
	(void)context;
	if (!InitializeCriticalSectionEx(
			&g_nav_state.lock,
			NAV_LOCK_SPIN_COUNT,
			0)) {
		g_nav_initialization_error = GetLastError();
		return FALSE;
	}
	return TRUE;
}



/**
 * Ensures the native state lock exists before any public operation.
 *
 * @return True when initialization succeeded.
 */
static bool NavEnsureInitialized(void)
{
	return InitOnceExecuteOnce(
		&g_nav_init_once,
		NavInitializeOnce,
		NULL,
		NULL) != FALSE;
}



/**
 * Advances a monotonic counter while reserving zero as an invalid identity.
 *
 * @param counter Counter to advance.
 * @return The next nonzero value.
 */
static uint64_t NavNextIdentity(uint64_t *counter)
{
	++(*counter);
	if (*counter == 0)
		++(*counter);
	return *counter;
}



/**
 * Clears semantic state after the hook thread has stopped.
 *
 * @param state Locked state to clear.
 */
static void NavResetSemanticStateLocked(NavState *state)
{
	memset(state->active_plan, 0, sizeof(state->active_plan));
	memset(state->prepared_plan, 0, sizeof(state->prepared_plan));
	memset(&state->active_owner, 0, sizeof(state->active_owner));
	memset(&state->staged_owner, 0, sizeof(state->staged_owner));
	memset(state->receipts, 0, sizeof(state->receipts));
	memset(state->held_keys, 0, sizeof(state->held_keys));
	memset(state->injected_modifiers, 0, sizeof(state->injected_modifiers));
	state->wake_window = NULL;
	state->wake_message = 0;
	state->last_os_error = 0;
	state->thread_start_status = ERGOPTI_NAV_STATUS_INVALID_STATE;
	state->thread_exit_status = ERGOPTI_NAV_STATUS_INVALID_STATE;
	state->running = 0;
	state->suspended = 0;
	state->transition = 0;
	state->physical_modifiers_lr = 0;
	state->downstream_modifiers_lr = 0;
	state->active_plan_valid = 0;
	state->prepared_plan_valid = 0;
	state->startup_cancelled = 0;
	state->draining = 0;
	state->menu_guard_passed_lr = 0;
	state->menu_undisguised = 0;
	state->held_key_overflowed = 0;
	state->menu_guard_suppressed_lr = 0;
	state->active_plan_generation = 0;
	state->prepared_plan_generation = 0;
	state->next_plan_generation = 0;
	state->active_swap_ticket = 0;
	state->next_swap_ticket = 0;
	state->next_receipt_sequence = 0;
	state->terminal_token = 0;
	state->terminal_phase = ERGOPTI_NAV_TERMINAL_IDLE;
	state->terminal_queued = 0;
	state->terminal_replayed = 0;
	state->terminal_last_os_error = 0;
	state->terminal_release_kind = ERGOPTI_NAV_TERMINAL_RELEASE_NONE;
	memset(state->terminal_events, 0, sizeof(state->terminal_events));
}



/**
 * Closes a nullable Win32 handle.
 *
 * @param handle Handle to close when non-null.
 */
static void NavCloseHandle(HANDLE handle)
{
	if (handle != NULL)
		CloseHandle(handle);
}




// =========================================
// =========================================
// ======= 2/ Validation and Matching =======
// =========================================
// =========================================

/**
 * Tests whether a byte range contains only zeroes.
 *
 * @param bytes Byte range to inspect.
 * @param count Number of bytes to inspect.
 * @return True when every byte is zero.
 */
static bool NavBytesAreZero(const uint8_t *bytes, size_t count)
{
	size_t index;
	for (index = 0; index < count; ++index) {
		if (bytes[index] != 0)
			return false;
	}
	return true;
}



/**
 * Validates an owner snapshot at the native publication boundary.
 *
 * @param owner Owner snapshot to validate.
 * @return True when the snapshot is canonical.
 */
static bool NavOwnerIsValid(const ErgoptiNav_Owner *owner)
{
	if (owner == NULL || !NavBytesAreZero(owner->reserved, sizeof(owner->reserved)))
		return false;
	if (owner->token == 0) {
		return owner->epoch == 0
			&& owner->slot_count == 0
			&& owner->active_index == 0
			&& owner->require_index_match == 0;
	}
	return owner->epoch != 0
		&& owner->slot_count >= 1
		&& owner->slot_count <= ERGOPTI_NAV_MAX_SLOTS
		&& owner->active_index >= 1
		&& owner->active_index <= owner->slot_count
		&& owner->require_index_match <= 1;
}



/**
 * Validates the complete twelve-route plan as one atomic candidate.
 *
 * @param bindings Candidate route array.
 * @return True when the route family is complete and collision-free.
 */
static bool NavPlanIsValid(
	const ErgoptiNav_Binding bindings[ERGOPTI_NAV_ROUTE_COUNT])
{
	uint32_t index;
	uint32_t prior;
	uint32_t cycle_up_count = 0;
	uint32_t cycle_down_count = 0;
	uint16_t jump_targets = 0;

	for (index = 0; index < ERGOPTI_NAV_ROUTE_COUNT; ++index) {
		const ErgoptiNav_Binding *binding = &bindings[index];
		if (!NavBytesAreZero(binding->reserved, sizeof(binding->reserved)))
			return false;
		if (binding->axis != ERGOPTI_NAV_AXIS_VK
				&& binding->axis != ERGOPTI_NAV_AXIS_SC)
			return false;
		if (binding->code == 0)
			return false;
		if (binding->axis == ERGOPTI_NAV_AXIS_VK && binding->code > 0xFFu)
			return false;
		if (binding->axis == ERGOPTI_NAV_AXIS_SC && binding->code > 0x1FFu)
			return false;
		if ((binding->modifiers & 0xF0u) != 0)
			return false;
		if (binding->pass_through > 1)
			return false;
		if (binding->input_level > ERGOPTI_NAV_AHK_SEND_LEVEL_MAX)
			return false;

		if (binding->action == ERGOPTI_NAV_ACTION_CYCLE) {
			if (binding->pass_through != 1 || binding->target != 0)
				return false;
			if (binding->delta == -1)
				++cycle_up_count;
			else if (binding->delta == 1)
				++cycle_down_count;
			else
				return false;
		} else if (binding->action == ERGOPTI_NAV_ACTION_JUMP) {
			uint16_t target_bit;
			if (binding->pass_through != 0 || binding->delta != 0)
				return false;
			if (binding->target < 1
					|| binding->target > ERGOPTI_NAV_MAX_SLOTS)
				return false;
			target_bit = (uint16_t)(1u << (binding->target - 1u));
			if ((jump_targets & target_bit) != 0)
				return false;
			jump_targets = (uint16_t)(jump_targets | target_bit);
		} else {
			return false;
		}

		for (prior = 0; prior < index; ++prior) {
			const ErgoptiNav_Binding *other = &bindings[prior];
			if (binding->axis == other->axis
					&& binding->code == other->code
					&& binding->modifiers == other->modifiers)
				return false;
		}
	}

	return cycle_up_count == 1
		&& cycle_down_count == 1
		&& jump_targets == 0x03FFu;
}



/**
 * Validates the deterministic event ABI before entering the state machine.
 *
 * @param event Event supplied by the test seam.
 * @return True when all public fields are canonical.
 */
static bool NavTestEventIsValid(const ErgoptiNav_TestEvent *event)
{
	return event != NULL
		&& (event->kind == ERGOPTI_NAV_EVENT_DOWN
			|| event->kind == ERGOPTI_NAV_EVENT_UP)
		&& event->injected <= ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY
		&& event->reserved == 0
		&& (event->modifiers & 0xF0u) == 0
		&& event->vk <= 0xFFu
		&& event->sc <= 0x1FFu;
}



/**
 * Returns the event code selected by one descriptor axis.
 *
 * @param event Keyboard event to project.
 * @param axis Descriptor axis.
 * @return The projected virtual key or scan code.
 */
static uint16_t NavEventCode(
	const ErgoptiNav_TestEvent *event,
	uint8_t axis)
{
	return axis == ERGOPTI_NAV_AXIS_SC ? event->sc : event->vk;
}



/**
 * Tests whether an event matches a normalized binding identity.
 *
 * @param event Event to match.
 * @param binding Binding to inspect.
 * @return True when code and generic modifiers are exact.
 */
static bool NavEventMatchesBinding(
	const ErgoptiNav_TestEvent *event,
	const ErgoptiNav_Binding *binding)
{
	return NavEventCode(event, binding->axis) == binding->code
		&& event->modifiers == binding->modifiers;
}



/**
 * Resolves a known AHK SendLevel marker from dwExtraInfo.
 *
 * AutoHotkey v2.0.26 encodes level N as 0xFFC3D44D-N. Other injected
 * provenance is intentionally unknown and therefore cannot own an event.
 *
 * @param event Injected event to classify.
 * @param out_level Receives the decoded level.
 * @return True only for the official level marker range.
 */
static bool NavTryDecodeAhkSendLevel(
	const ErgoptiNav_TestEvent *event,
	uint8_t *out_level)
{
	uint64_t minimum_marker = (uint64_t)ERGOPTI_NAV_AHK_SEND_LEVEL_BASE
		- ERGOPTI_NAV_AHK_SEND_LEVEL_MAX;
	if (event->extra_info > ERGOPTI_NAV_AHK_SEND_LEVEL_BASE
			|| event->extra_info < minimum_marker)
		return false;
	*out_level = (uint8_t)(ERGOPTI_NAV_AHK_SEND_LEVEL_BASE
		- (uint32_t)event->extra_info);
	return true;
}



/**
 * Applies the AHK InputLevel rule to one event and binding.
 *
 * @param event Event to classify.
 * @param binding Candidate binding.
 * @return True for physical input or a known SendLevel above InputLevel.
 */
static bool NavInputIsEligible(
	const ErgoptiNav_TestEvent *event,
	const ErgoptiNav_Binding *binding)
{
	uint8_t send_level;
	if (event->injected == ERGOPTI_NAV_INJECTION_PHYSICAL)
		return true;
	if (event->injected == ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY)
		return false;
	if (!NavTryDecodeAhkSendLevel(event, &send_level))
		return false;
	return send_level > binding->input_level;
}



/**
 * Finds the active plan route matching an event.
 *
 * @param state Locked native state.
 * @param event Event to match.
 * @return Route index or -1 when no route matches.
 */
static int32_t NavFindRouteLocked(
	const NavState *state,
	const ErgoptiNav_TestEvent *event)
{
	uint32_t index;
	if (!state->active_plan_valid)
		return -1;
	for (index = 0; index < ERGOPTI_NAV_ROUTE_COUNT; ++index) {
		if (NavEventMatchesBinding(event, &state->active_plan[index]))
			return (int32_t)index;
	}
	return -1;
}



/**
 * Tests whether an event belongs to a retained key-hold decision.
 *
 * @param event Event to compare.
 * @param held Retained hold record.
 * @return True when physical identity and injection provenance match.
 */
static bool NavEventMatchesHeldKey(
	const ErgoptiNav_TestEvent *event,
	const NavHeldKey *held)
{
	if (!held->active
			|| NavEventCode(event, held->axis) != held->code
			|| event->injected != held->injected)
		return false;
	return !event->injected || event->extra_info == held->extra_info;
}



/**
 * Finds a retained decision for a down repeat or balancing key-up.
 *
 * @param state Locked native state.
 * @param event Event to compare.
 * @return Held-key index or -1 when absent.
 */
static int32_t NavFindHeldKeyLocked(
	const NavState *state,
	const ErgoptiNav_TestEvent *event)
{
	uint32_t index;
	for (index = 0; index < NAV_HELD_KEY_CAPACITY; ++index) {
		if (NavEventMatchesHeldKey(event, &state->held_keys[index]))
			return (int32_t)index;
	}
	return -1;
}



/**
 * Finds storage for a new consumed-route hold.
 *
 * @param state Locked native state.
 * @return Free held-key index or -1 when exhausted.
 */
static int32_t NavFindFreeHeldKeyLocked(const NavState *state)
{
	uint32_t index;
	for (index = 0; index < NAV_HELD_KEY_CAPACITY; ++index) {
		if (!state->held_keys[index].active)
			return (int32_t)index;
	}
	return -1;
}



/** Returns true while any previously consumed down still owns its key-up. */
static bool NavHasSuppressHoldLocked(const NavState *state)
{
	uint32_t index;
	for (index = 0; index < NAV_HELD_KEY_CAPACITY; ++index) {
		if (state->held_keys[index].active
				&& state->held_keys[index].mode == NAV_HOLD_SUPPRESS) {
			return true;
		}
	}
	return false;
}



/** Returns true while an accepted receipt still awaits AHK acknowledgement. */
static bool NavHasPendingReceiptLocked(const NavState *state)
{
	uint32_t index;
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		if (state->receipts[index].state != NAV_RECEIPT_EMPTY)
			return true;
	}
	return false;
}



/** Returns true while terminal capture owns suppressed physical input. */
static bool NavHasTerminalDebtLocked(const NavState *state)
{
	return state->terminal_phase != ERGOPTI_NAV_TERMINAL_IDLE
		|| state->terminal_queued != 0;
}



/**
 * Captures one physical keyboard edge before navigation sees it.
 *
 * AHK SendEvent input and native replay input are injected and therefore pass
 * this boundary. Every physical edge remains suppressed through release retry.
 */
static bool NavCaptureTerminalEventLocked(
	NavState *state,
	WPARAM message,
	const KBDLLHOOKSTRUCT *event)
{
	NavTerminalKeyEdge *edge;
	bool key_up;
	if (!NavHasTerminalDebtLocked(state)
			|| event == NULL
			|| (event->flags & LLKHF_INJECTED) != 0)
		return false;
	if (message != WM_KEYDOWN && message != WM_SYSKEYDOWN
			&& message != WM_KEYUP && message != WM_SYSKEYUP)
		return false;
	if (state->terminal_queued >= ERGOPTI_NAV_TERMINAL_CAPTURE_CAPACITY) {
		state->terminal_phase = ERGOPTI_NAV_TERMINAL_FAULTED;
		state->terminal_last_os_error = ERROR_NOT_ENOUGH_MEMORY;
		state->last_os_error = ERROR_NOT_ENOUGH_MEMORY;
		return true;
	}
	key_up = message == WM_KEYUP || message == WM_SYSKEYUP;
	edge = &state->terminal_events[state->terminal_queued++];
	memset(edge, 0, sizeof(*edge));
	edge->vk = (uint16_t)event->vkCode;
	edge->sc = (uint16_t)(event->scanCode & 0xFFu);
	edge->key_up = key_up ? 1 : 0;
	edge->extended = (event->flags & LLKHF_EXTENDED) != 0 ? 1 : 0;
	return true;
}



/**
 * Tests whether Stop may unhook without leaking a consumed edge or naked menu.
 *
 * @param state Locked native state.
 * @return True only after all suppression and camouflage obligations resolve.
 */
static bool NavDrainCompleteLocked(const NavState *state)
{
	return !NavHasSuppressHoldLocked(state)
		&& state->menu_guard_passed_lr == 0
		&& state->menu_guard_suppressed_lr == 0
		&& !NavHasPendingReceiptLocked(state)
		&& !NavHasTerminalDebtLocked(state);
}



/**
 * Stores one coherent pass or suppress decision until key-up.
 *
 * @param held Destination hold record.
 * @param binding Matched consumed binding.
 * @param event Initial key-down event.
 * @param mode NAV_HOLD_PASS or NAV_HOLD_SUPPRESS.
 */
static void NavSetHeldKey(
	NavHeldKey *held,
	const ErgoptiNav_Binding *binding,
	const ErgoptiNav_TestEvent *event,
	uint8_t mode)
{
	memset(held, 0, sizeof(*held));
	held->active = 1;
	held->mode = mode;
	held->axis = binding->axis;
	held->injected = event->injected;
	held->code = binding->code;
	held->extra_info = event->extra_info;
}



/**
 * Finds a free immutable receipt slot.
 *
 * @param state Locked native state.
 * @return Free receipt index or -1 when the bounded queue is full.
 */
static int32_t NavFindFreeReceiptLocked(const NavState *state)
{
	uint32_t index;
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		if (state->receipts[index].state == NAV_RECEIPT_EMPTY)
			return (int32_t)index;
	}
	return -1;
}



/**
 * Computes the one-based target for one valid owner and binding.
 *
 * @param owner Current canonical owner.
 * @param binding Matched navigation action.
 * @param out_target Receives the one-based target.
 * @return True when the action is eligible for the owner's slot count.
 */
static bool NavTryComputeTarget(
	const ErgoptiNav_Owner *owner,
	const ErgoptiNav_Binding *binding,
	uint8_t *out_target)
{
	if (binding->action == ERGOPTI_NAV_ACTION_JUMP) {
		if (binding->target > owner->slot_count)
			return false;
		*out_target = binding->target;
		return true;
	}
	if (owner->slot_count <= 1)
		return false;
	if (binding->delta < 0) {
		*out_target = owner->active_index == 1
			? owner->slot_count
			: (uint8_t)(owner->active_index - 1u);
	} else {
		*out_target = owner->active_index == owner->slot_count
			? 1u
			: (uint8_t)(owner->active_index + 1u);
	}
	return true;
}




// ======================================
// ======================================
// ======= 3/ Atomic Dispatch Core =======
// ======================================
// ======================================

/**
 * Initializes a fail-open dispatch result.
 *
 * @param result Result to initialize.
 */
static void NavInitializeDispatchResult(ErgoptiNav_DispatchResult *result)
{
	memset(result, 0, sizeof(*result));
	result->disposition = ERGOPTI_NAV_DISPOSITION_PASS;
	result->route_index = ERGOPTI_NAV_NO_ROUTE;
}



/**
 * Retains a failed consumed-route down as pass-through until its key-up.
 *
 * @param state Locked native state.
 * @param binding Matched consumed binding.
 * @param event Initial key-down event.
 * @param held_index Pre-resolved free hold slot, or -1 when unavailable.
 */
static void NavLatchPassForRefusalLocked(
	NavState *state,
	const ErgoptiNav_Binding *binding,
	const ErgoptiNav_TestEvent *event,
	int32_t held_index)
{
	if (binding->pass_through)
		return;
	if (held_index >= 0) {
		NavSetHeldKey(
			&state->held_keys[held_index],
			binding,
			event,
			NAV_HOLD_PASS);
	} else {
		/* The missing identity makes every later consumed hold ambiguous. */
		state->held_key_overflowed = 1;
	}
}



/**
 * Runs the complete navigation ownership state machine under the state lock.
 *
 * Existing consumed holds are resolved before suspension or transition fences
 * so a suppressed key-down always receives a suppressed balancing key-up.
 * Every new failure path is fail-open and leaves owner state unchanged.
 *
 * @param state Locked native state.
 * @param event Canonical deterministic event.
 * @param menu_mask_ready True after a required camouflage pulse succeeded.
 * @param result Receives the hook disposition and receipt identity.
 * @return True when suppression must wait for a menu-mask pulse.
 */
static bool NavDispatchLocked(
	NavState *state,
	const ErgoptiNav_TestEvent *event,
	bool menu_mask_ready,
	ErgoptiNav_DispatchResult *result)
{
	int32_t held_index;
	int32_t route_index;
	int32_t free_held_index = -1;
	int32_t receipt_index;
	uint8_t target_index;
	uint8_t modifier_bit;
	const uint8_t menu_bits =
		NAV_MOD_LALT | NAV_MOD_RALT | NAV_MOD_LWIN | NAV_MOD_RWIN;
	const uint8_t disguise_bits =
		NAV_MOD_LCONTROL | NAV_MOD_RCONTROL | NAV_MOD_LSHIFT | NAV_MOD_RSHIFT;
	const ErgoptiNav_Binding *binding;
	NavReceiptSlot *receipt_slot;

	NavInitializeDispatchResult(result);
	modifier_bit = NavModifierBit(event->vk, event->sc);
	if ((state->menu_guard_passed_lr != 0
			|| state->menu_guard_suppressed_lr != 0)
			&& event->kind == ERGOPTI_NAV_EVENT_UP
			&& (modifier_bit & disguise_bits) != 0
			&& (state->downstream_modifiers_lr & modifier_bit) == 0) {
		/* A truly orphaned Ctrl/Shift up has no downstream down to release and can
		 * expose a pending Alt/Win menu. Suppress it without weakening the guard;
		 * a matched downstream release remains PASS. */
		result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
		return false;
	}
	/* A successful pre-suppression pulse guards every Alt/Win down which was
	 * already visible downstream. Modifier repeats (and a newly pressed sibling
	 * menu key) must not be passed afterward: Windows can treat that down as a
	 * fresh naked menu generation, but another fallible pulse would occur after
	 * the suffix suppression had already become irreversible. */
	if ((modifier_bit & menu_bits) != 0
			&& (state->menu_guard_passed_lr != 0
				|| state->menu_guard_suppressed_lr != 0)) {
		if (event->kind == ERGOPTI_NAV_EVENT_DOWN) {
			if ((state->menu_guard_passed_lr & modifier_bit) == 0)
				state->menu_guard_suppressed_lr |= modifier_bit;
			result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
			return false;
		}
		if ((state->menu_guard_suppressed_lr & modifier_bit) != 0) {
			if ((NavRoutingModifiersLocked(state) & modifier_bit) == 0) {
				state->menu_guard_suppressed_lr &=
					(uint8_t)~modifier_bit;
			}
			result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
			return false;
		}
		if ((state->menu_guard_passed_lr & modifier_bit) != 0) {
			if ((NavRoutingModifiersLocked(state) & modifier_bit) == 0)
				state->menu_guard_passed_lr &= (uint8_t)~modifier_bit;
			return false;
		}
	}
	held_index = NavFindHeldKeyLocked(state, event);
	if (held_index >= 0) {
		NavHeldKey *held = &state->held_keys[held_index];
		if (held->mode == NAV_HOLD_SUPPRESS)
			result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
		if (event->kind == ERGOPTI_NAV_EVENT_UP)
			memset(held, 0, sizeof(*held));
		return false;
	}

	if (event->kind == ERGOPTI_NAV_EVENT_UP)
		return false;

	route_index = NavFindRouteLocked(state, event);
	if (route_index < 0)
		return false;
	result->route_index = (uint8_t)route_index;
	binding = &state->active_plan[route_index];
	if (!binding->pass_through && state->held_key_overflowed)
		return false;
	if (!binding->pass_through)
		free_held_index = NavFindFreeHeldKeyLocked(state);

	if (state->startup_cancelled
			|| state->draining
			|| state->transition
			|| state->suspended
			|| state->active_owner.token == 0
			|| !NavInputIsEligible(event, binding)
			|| !NavTryComputeTarget(&state->active_owner, binding, &target_index)) {
		NavLatchPassForRefusalLocked(
			state,
			binding,
			event,
			free_held_index);
		return false;
	}

	if (!binding->pass_through && free_held_index < 0) {
		NavLatchPassForRefusalLocked(
			state,
			binding,
			event,
			free_held_index);
		return false;
	}
	receipt_index = NavFindFreeReceiptLocked(state);
	if (receipt_index < 0) {
		NavLatchPassForRefusalLocked(
			state,
			binding,
			event,
			free_held_index);
		return false;
	}
	/* A naked Alt/Win chord needs its inert Ctrl pulse before the receipt and
	 * suppress hold become irreversible. The caller emits outside the lock and
	 * then re-enters this complete admission path with menu_mask_ready=true. */
	if (!binding->pass_through && !menu_mask_ready
			&& state->menu_undisguised
			&& (event->modifiers
				& (ERGOPTI_NAV_MOD_ALT | ERGOPTI_NAV_MOD_WIN)) != 0) {
		return true;
	}

	receipt_slot = &state->receipts[receipt_index];
	memset(&receipt_slot->receipt, 0, sizeof(receipt_slot->receipt));
	receipt_slot->receipt.sequence = NavNextIdentity(
		&state->next_receipt_sequence);
	receipt_slot->receipt.owner_token = state->active_owner.token;
	receipt_slot->receipt.owner_epoch = state->active_owner.epoch;
	receipt_slot->receipt.plan_generation = state->active_plan_generation;
	receipt_slot->receipt.route_index = (uint8_t)route_index;
	receipt_slot->receipt.action = binding->action;
	receipt_slot->receipt.delta = binding->delta;
	receipt_slot->receipt.from_index = state->active_owner.active_index;
	receipt_slot->receipt.target_index = target_index;
	receipt_slot->receipt.pass_through = binding->pass_through;
	receipt_slot->state = NAV_RECEIPT_QUEUED;
	state->active_owner.active_index = target_index;

	if (!binding->pass_through) {
		NavSetHeldKey(
			&state->held_keys[free_held_index],
			binding,
			event,
			NAV_HOLD_SUPPRESS);
		result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
	}
	result->receipt_created = 1;
	result->receipt_sequence = receipt_slot->receipt.sequence;
	return false;
}




// ========================================
// ========================================
// ======= 4/ Win32 Hook Thread =======
// ========================================
// ========================================

/**
 * Reads the initial left/right modifier state before the hook begins dispatching.
 *
 * @return Internal left/right modifier mask.
 */
static uint8_t NavReadModifierState(void)
{
	uint8_t modifiers = 0;
	if ((GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_LCONTROL);
	if ((GetAsyncKeyState(VK_RCONTROL) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_RCONTROL);
	if ((GetAsyncKeyState(VK_LMENU) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_LALT);
	if ((GetAsyncKeyState(VK_RMENU) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_RALT);
	if ((GetAsyncKeyState(VK_LSHIFT) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_LSHIFT);
	if ((GetAsyncKeyState(VK_RSHIFT) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_RSHIFT);
	if ((GetAsyncKeyState(VK_LWIN) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_LWIN);
	if ((GetAsyncKeyState(VK_RWIN) & 0x8000) != 0)
		modifiers = (uint8_t)(modifiers | NAV_MOD_RWIN);
	return modifiers;
}



/** Conservatively seeds menu state when a modifier predates hook startup. */
static bool NavInitialMenuCouldBeUndisguised(uint8_t modifiers)
{
	const uint8_t alt_bits = NAV_MOD_LALT | NAV_MOD_RALT;
	const uint8_t control_bits = NAV_MOD_LCONTROL | NAV_MOD_RCONTROL;
	const uint8_t win_bits = NAV_MOD_LWIN | NAV_MOD_RWIN;
	bool has_alt = (modifiers & alt_bits) != 0;
	bool has_win = (modifiers & win_bits) != 0;
	return (has_alt || has_win)
		&& (modifiers & control_bits) == 0
		&& !(has_alt && has_win);
}



/**
 * Applies the provenance-free keyboard snapshot captured at hook startup.
 *
 * GetAsyncKeyState includes injected input, so its bits may describe events
 * whose provenance the hook never observed. They are valid downstream/menu
 * state, but they must not enter physical route matching. Routing therefore
 * remains fail-open until a later physical modifier-down is seen by the hook.
 *
 * @param state Locked native state.
 * @param modifiers Initial left/right logical keyboard mask.
 */
static void NavApplyInitialModifierSnapshotLocked(
	NavState *state,
	uint8_t modifiers)
{
	state->physical_modifiers_lr = 0;
	state->downstream_modifiers_lr = modifiers;
	state->menu_undisguised =
		NavInitialMenuCouldBeUndisguised(modifiers) ? 1 : 0;
}



/**
 * Maps a low-level modifier event to one internal left/right bit.
 *
 * @param vk Virtual key from KBDLLHOOKSTRUCT.
 * @param sc Compressed AHK-style scan code.
 * @return Internal modifier bit or zero for a non-modifier.
 */
static uint8_t NavModifierBit(uint16_t vk, uint16_t sc)
{
	switch (vk) {
	case VK_LCONTROL:
		return NAV_MOD_LCONTROL;
	case VK_RCONTROL:
		return NAV_MOD_RCONTROL;
	case VK_CONTROL:
		return (sc & 0x100u) != 0 ? NAV_MOD_RCONTROL : NAV_MOD_LCONTROL;
	case VK_LMENU:
		return NAV_MOD_LALT;
	case VK_RMENU:
		return NAV_MOD_RALT;
	case VK_MENU:
		return (sc & 0x100u) != 0 ? NAV_MOD_RALT : NAV_MOD_LALT;
	case VK_LSHIFT:
		return NAV_MOD_LSHIFT;
	case VK_RSHIFT:
		return NAV_MOD_RSHIFT;
	case VK_SHIFT:
		return (sc & 0xFFu) == 0x36u ? NAV_MOD_RSHIFT : NAV_MOD_LSHIFT;
	case VK_LWIN:
		return NAV_MOD_LWIN;
	case VK_RWIN:
		return NAV_MOD_RWIN;
	default:
		return 0;
	}
}



/**
 * Collapses internal left/right state to the generic AHK modifier ABI.
 *
 * @param modifiers Internal left/right modifier mask.
 * @return Generic ErgoptiNav_Modifier mask.
 */
static uint8_t NavCollapseModifiers(uint8_t modifiers)
{
	uint8_t generic = 0;
	if ((modifiers & (NAV_MOD_LCONTROL | NAV_MOD_RCONTROL)) != 0)
		generic = (uint8_t)(generic | ERGOPTI_NAV_MOD_CONTROL);
	if ((modifiers & (NAV_MOD_LALT | NAV_MOD_RALT)) != 0)
		generic = (uint8_t)(generic | ERGOPTI_NAV_MOD_ALT);
	if ((modifiers & (NAV_MOD_LSHIFT | NAV_MOD_RSHIFT)) != 0)
		generic = (uint8_t)(generic | ERGOPTI_NAV_MOD_SHIFT);
	if ((modifiers & (NAV_MOD_LWIN | NAV_MOD_RWIN)) != 0)
		generic = (uint8_t)(generic | ERGOPTI_NAV_MOD_WIN);
	return generic;
}



/**
 * Collapses every retained injected modifier provenance to one left/right mask.
 *
 * @param state Locked native state.
 * @return Union of admitted injected modifier holds.
 */
static uint8_t NavInjectedModifierMaskLocked(const NavState *state)
{
	uint8_t modifiers = 0;
	uint32_t index;
	for (index = 0; index < NAV_INJECTED_MODIFIER_CAPACITY; ++index) {
		const NavInjectedModifierHold *hold = &state->injected_modifiers[index];
		if (hold->active)
			modifiers = (uint8_t)(modifiers | hold->modifier_bit);
	}
	return modifiers;
}



/**
 * Retains one trusted injected modifier-down without replacing another source.
 *
 * Duplicate edges from the same AHK marker are idempotent. When the bounded
 * table is full, the new edge is ignored so later routing fails open.
 *
 * @param state Locked native state.
 * @param modifier_bit Exact left/right modifier bit.
 * @param extra_info Proven AHK SendLevel marker.
 */
static void NavRetainInjectedModifierLocked(
	NavState *state,
	uint8_t modifier_bit,
	uint64_t extra_info)
{
	uint32_t free_index = NAV_INJECTED_MODIFIER_CAPACITY;
	uint32_t index;
	for (index = 0; index < NAV_INJECTED_MODIFIER_CAPACITY; ++index) {
		NavInjectedModifierHold *hold = &state->injected_modifiers[index];
		if (hold->active
				&& hold->modifier_bit == modifier_bit
				&& hold->extra_info == extra_info)
			return;
		if (!hold->active && free_index == NAV_INJECTED_MODIFIER_CAPACITY)
			free_index = index;
	}
	if (free_index == NAV_INJECTED_MODIFIER_CAPACITY)
		return;
	state->injected_modifiers[free_index].active = 1;
	state->injected_modifiers[free_index].modifier_bit = modifier_bit;
	state->injected_modifiers[free_index].extra_info = extra_info;
}



/**
 * Releases only the injected modifier provenance admitted on its matching down.
 *
 * Current plan eligibility is deliberately irrelevant: a plan may change
 * between the two edges, but a release must still retire its retained source.
 *
 * @param state Locked native state.
 * @param modifier_bit Exact left/right modifier bit.
 * @param extra_info AHK SendLevel marker carried by the release.
 */
static void NavReleaseInjectedModifierLocked(
	NavState *state,
	uint8_t modifier_bit,
	uint64_t extra_info)
{
	uint32_t index;
	for (index = 0; index < NAV_INJECTED_MODIFIER_CAPACITY; ++index) {
		NavInjectedModifierHold *hold = &state->injected_modifiers[index];
		if (!hold->active
				|| hold->modifier_bit != modifier_bit
				|| hold->extra_info != extra_info)
			continue;
		memset(hold, 0, sizeof(*hold));
		return;
	}
}



/**
 * Tests whether an injected modifier-up has an exact retained down provenance.
 *
 * @param state Locked native state before processing the key-up.
 * @param modifier_bit Exact left/right modifier bit.
 * @param extra_info Native injection marker.
 * @return True when the same injected source is currently retained.
 */
static bool NavHasInjectedModifierLocked(
	const NavState *state,
	uint8_t modifier_bit,
	uint64_t extra_info)
{
	uint32_t index;
	for (index = 0; index < NAV_INJECTED_MODIFIER_CAPACITY; ++index) {
		const NavInjectedModifierHold *hold = &state->injected_modifiers[index];
		if (hold->active
				&& hold->modifier_bit == modifier_bit
				&& hold->extra_info == extra_info) {
			return true;
		}
	}
	return false;
}



/**
 * Decides whether an injected modifier may enter the shared chord tracker.
 *
 * One collapsed modifier mask feeds every route. It is therefore safe to admit
 * an injected modifier only when its proven SendLevel exceeds every active
 * route InputLevel. Unknown and lower-integrity input cannot influence a later
 * physical key. Matching releases are authorized by the retained down rather
 * than by the possibly newer active plan.
 *
 * @param state Locked native state.
 * @param event Canonical modifier event.
 * @return True when this modifier-down provenance is trusted by every route.
 */
static bool NavModifierInputIsEligibleLocked(
	const NavState *state,
	const ErgoptiNav_TestEvent *event)
{
	uint8_t send_level;
	uint32_t index;
	if (event->injected == ERGOPTI_NAV_INJECTION_PHYSICAL)
		return true;
	if (event->injected == ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY
			|| !state->active_plan_valid
			|| !NavTryDecodeAhkSendLevel(event, &send_level))
		return false;
	for (index = 0; index < ERGOPTI_NAV_ROUTE_COUNT; ++index) {
		if (send_level <= state->active_plan[index].input_level)
			return false;
	}
	return true;
}



/**
 * Converts one KBDLLHOOKSTRUCT into the deterministic event ABI.
 *
 * @param message Low-level keyboard message identifier.
 * @param native_event Win32 keyboard event.
 * @param state Locked native state whose modifier tracker is updated.
 * @param out_event Receives the canonical event.
 * @return True for supported down/up messages.
 */
static bool NavBuildHookEventLocked(
	WPARAM message,
	const KBDLLHOOKSTRUCT *native_event,
	NavState *state,
	ErgoptiNav_TestEvent *out_event)
{
	uint8_t modifier_bit;
	bool key_up;
	if (message != WM_KEYDOWN
			&& message != WM_SYSKEYDOWN
			&& message != WM_KEYUP
			&& message != WM_SYSKEYUP)
		return false;

	memset(out_event, 0, sizeof(*out_event));
	key_up = message == WM_KEYUP || message == WM_SYSKEYUP;
	out_event->vk = (uint16_t)(native_event->vkCode & 0xFFu);
	out_event->sc = (uint16_t)(native_event->scanCode & 0xFFu);
	if ((native_event->flags & LLKHF_EXTENDED) != 0)
		out_event->sc = (uint16_t)(out_event->sc | 0x100u);
	out_event->kind = key_up ? ERGOPTI_NAV_EVENT_UP : ERGOPTI_NAV_EVENT_DOWN;
	if ((uint64_t)native_event->dwExtraInfo
			== ERGOPTI_NAV_TERMINAL_REPLAY_MARKER) {
		/* Replayed physical input keeps physical routing semantics while the
		 * private marker prevents the terminal capture from recapturing it. */
		out_event->injected = ERGOPTI_NAV_INJECTION_PHYSICAL;
	} else if ((native_event->flags & LLKHF_LOWER_IL_INJECTED) != 0) {
		out_event->injected = ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY;
	} else if ((native_event->flags & LLKHF_INJECTED) != 0) {
		out_event->injected = ERGOPTI_NAV_INJECTION_STANDARD;
	}
	out_event->extra_info = (uint64_t)native_event->dwExtraInfo;

	modifier_bit = NavModifierBit(out_event->vk, out_event->sc);
	if (modifier_bit != 0) {
		if (out_event->injected == ERGOPTI_NAV_INJECTION_PHYSICAL) {
			if (key_up) {
				state->physical_modifiers_lr = (uint8_t)(
					state->physical_modifiers_lr & ~modifier_bit);
			} else {
				state->physical_modifiers_lr = (uint8_t)(
					state->physical_modifiers_lr | modifier_bit);
			}
		} else if (out_event->injected == ERGOPTI_NAV_INJECTION_STANDARD) {
			if (key_up) {
				NavReleaseInjectedModifierLocked(
					state, modifier_bit, out_event->extra_info);
			} else if (NavModifierInputIsEligibleLocked(state, out_event)) {
				NavRetainInjectedModifierLocked(
					state, modifier_bit, out_event->extra_info);
			}
		}
	}
	out_event->modifiers = NavCollapseModifiers(
		NavRoutingModifiersLocked(state));
	return true;
}



/** Callback used by the hook finalizer to emit one inert menu-mask pulse. */
typedef bool (*NavEmitMenuMaskFn)(void *context, DWORD *out_error);

/** Callback used by the hook finalizer to pass the original event unchanged. */
typedef LRESULT (*NavPassOriginalFn)(void *context);

/** Holds the original event tuple required by CallNextHookEx. */
typedef struct NavPassContext {
	HHOOK hook;
	int code;
	WPARAM message;
	LPARAM data_pointer;
} NavPassContext;



/**
 * Returns the exact trusted left/right modifiers retained by the hook.
 *
 * @param state Locked native state.
 * @return Union of physical and admitted injected modifier holds.
 */
static uint8_t NavRoutingModifiersLocked(const NavState *state)
{
	return (uint8_t)(state->physical_modifiers_lr
		| NavInjectedModifierMaskLocked(state));
}



/**
 * Mirrors modifier edges which the hook actually passes to Windows.
 *
 * This edge-level state is deliberately separate from routing provenance.
 * Unknown or low-level injected modifiers must never affect route matching,
 * but their passed edges still affect Windows' logical modifier state. A flat
 * left/right mask models that downstream state: like Windows, any passed up
 * edge releases the corresponding logical key regardless of its producer.
 *
 * @param state Locked native state.
 * @param event Canonical modifier event.
 * @param result Atomic decision for that same event.
 */
static void NavTrackDownstreamModifierLocked(
	NavState *state,
	const ErgoptiNav_TestEvent *event,
	const ErgoptiNav_DispatchResult *result)
{
	uint8_t modifier_bit;
	if (result->disposition != ERGOPTI_NAV_DISPOSITION_PASS)
		return;
	modifier_bit = NavModifierBit(event->vk, event->sc);
	if (modifier_bit == 0)
		return;
	if (event->kind == ERGOPTI_NAV_EVENT_UP) {
		state->downstream_modifiers_lr = (uint8_t)(
			state->downstream_modifiers_lr & ~modifier_bit);
	} else {
		state->downstream_modifiers_lr = (uint8_t)(
			state->downstream_modifiers_lr | modifier_bit);
	}
}



/**
 * Tracks whether a passed Alt/Win sequence still looks naked downstream.
 *
 * A consumed suffix arms one future camouflage pulse. A passed non-modifier,
 * Ctrl or Shift naturally disguises the menu key and therefore avoids an
 * unnecessary synthetic event. The state intentionally survives plan/owner
 * changes and suspension because those operations cannot retract a key-down
 * which Windows has already observed.
 *
 * @param state Locked native state.
 * @param event Canonical event after modifier tracking.
 * @param result Atomic navigation decision for the same event.
 * @param out_emit_mask Receives true when a pulse must precede downstream PASS.
 */
static void NavTrackMenuDisguiseLocked(
	NavState *state,
	const ErgoptiNav_TestEvent *event,
	const ErgoptiNav_DispatchResult *result,
	bool modifier_release_was_tracked,
	bool *out_emit_mask)
{
	const uint8_t alt_bits = NAV_MOD_LALT | NAV_MOD_RALT;
	const uint8_t control_bits = NAV_MOD_LCONTROL | NAV_MOD_RCONTROL;
	const uint8_t win_bits = NAV_MOD_LWIN | NAV_MOD_RWIN;
	uint8_t modifier_bit = NavModifierBit(event->vk, event->sc);
	uint8_t tracked = state->downstream_modifiers_lr;

	(void)modifier_release_was_tracked;
	*out_emit_mask = false;
	if (result->disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS)
		return;

	if (modifier_bit == 0) {
		state->menu_undisguised = 0;
		return;
	}

	if (event->kind == ERGOPTI_NAV_EVENT_DOWN) {
		if ((modifier_bit & win_bits) != 0) {
			state->menu_undisguised =
				(tracked & (uint8_t)~win_bits) == 0;
		} else if ((modifier_bit & alt_bits) != 0) {
			state->menu_undisguised =
				(tracked & control_bits) == 0
				&& (tracked & win_bits) == 0;
		} else {
			state->menu_undisguised = 0;
		}
		return;
	}

	state->menu_undisguised = 0;
}



/**
 * Converts and dispatches one raw hook event under the native state lock.
 *
 * @param message Low-level keyboard message identifier.
 * @param native_event Raw Win32 keyboard event.
 * @param state Locked native state.
 * @param out_event Receives the canonical event.
 * @param out_result Receives the navigation decision.
 * @param menu_mask_ready True after a required camouflage pulse succeeded.
 * @param out_mask_required Receives a pre-dispatch camouflage requirement.
 * @param out_emit_mask Receives the pre-PASS camouflage requirement.
 * @return True for supported keyboard messages.
 */
static bool NavProcessHookEventLocked(
	WPARAM message,
	const KBDLLHOOKSTRUCT *native_event,
	NavState *state,
	ErgoptiNav_TestEvent *out_event,
	ErgoptiNav_DispatchResult *out_result,
	bool menu_mask_ready,
	bool *out_mask_required,
	bool *out_emit_mask)
{
	uint16_t raw_sc;
	uint8_t modifier_bit;
	bool modifier_release_was_tracked = false;
	bool key_up = message == WM_KEYUP || message == WM_SYSKEYUP;
	*out_mask_required = false;
	*out_emit_mask = false;

	raw_sc = (uint16_t)(native_event->scanCode & 0xFFu);
	if ((native_event->flags & LLKHF_EXTENDED) != 0)
		raw_sc = (uint16_t)(raw_sc | 0x100u);
	modifier_bit = NavModifierBit(
		(uint16_t)(native_event->vkCode & 0xFFu), raw_sc);
	if (key_up && modifier_bit != 0) {
		if ((native_event->flags & LLKHF_INJECTED) == 0) {
			modifier_release_was_tracked =
				(state->physical_modifiers_lr & modifier_bit) != 0;
		} else if ((native_event->flags & LLKHF_LOWER_IL_INJECTED) == 0) {
			modifier_release_was_tracked = NavHasInjectedModifierLocked(
				state,
				modifier_bit,
				(uint64_t)native_event->dwExtraInfo);
		}
	}
	if (!NavBuildHookEventLocked(message, native_event, state, out_event))
		return false;
	*out_mask_required = NavDispatchLocked(
		state, out_event, menu_mask_ready, out_result);
	if (*out_mask_required)
		return true;
	NavTrackDownstreamModifierLocked(state, out_event, out_result);
	NavTrackMenuDisguiseLocked(
		state,
		out_event,
		out_result,
		modifier_release_was_tracked,
		out_emit_mask);
	return true;
}



/** Arms the post-mask modifier guard before a suppress decision is published. */
static void NavArmMenuGuardLocked(NavState *state)
{
	const uint8_t menu_bits =
		NAV_MOD_LALT | NAV_MOD_RALT | NAV_MOD_LWIN | NAV_MOD_RWIN;
	state->menu_guard_passed_lr |=
		state->downstream_modifiers_lr & menu_bits;
	state->menu_undisguised = 0;
}



/**
 * Converts a failed pre-suppression mask into one balanced fail-open key hold.
 *
 * The route and owner have not mutated yet. Only a new hold can request this
 * fallible pre-mask; an existing suppress hold is returned before admission so
 * its repeats and eventual key-up remain suppressed without another pulse.
 *
 * @param state Locked native state.
 * @param event Canonical non-modifier down whose mask failed.
 * @param result Provisional route result, replaced with PASS.
 * @param mask_error Nonzero Win32 SendInput failure.
 */
static void NavFailOpenMenuMaskFailureLocked(
	NavState *state,
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *result,
	DWORD mask_error)
{
	uint8_t route_index = result->route_index;
	int32_t held_index = NavFindHeldKeyLocked(state, event);
	NavInitializeDispatchResult(result);
	result->route_index = route_index;
	if (held_index >= 0) {
		state->held_keys[held_index].mode = NAV_HOLD_PASS;
	} else if (route_index < ERGOPTI_NAV_ROUTE_COUNT) {
		const ErgoptiNav_Binding *binding = &state->active_plan[route_index];
		NavLatchPassForRefusalLocked(
			state,
			binding,
			event,
			NavFindFreeHeldKeyLocked(state));
	}
	state->last_os_error = mask_error != ERROR_SUCCESS
		? mask_error : ERROR_WRITE_FAULT;
	state->suspended = 1;
	state->menu_undisguised = 0;
}



/** Emits the Ctrl down/up pulse used by AHK to camouflage Alt/Win release. */
static bool NavEmitMenuMask(void *context, DWORD *out_error)
{
	INPUT input[2];
	UINT sent;
	(void)context;
	memset(input, 0, sizeof(input));
	input[0].type = INPUT_KEYBOARD;
	input[0].ki.wVk = VK_CONTROL;
	input[0].ki.dwExtraInfo = ERGOPTI_NAV_AHK_SEND_LEVEL_BASE;
	input[1] = input[0];
	input[1].ki.dwFlags = KEYEVENTF_KEYUP;
	SetLastError(ERROR_SUCCESS);
	sent = SendInput(2, input, sizeof(INPUT));
	if (sent == 2) {
		*out_error = ERROR_SUCCESS;
		return true;
	}
	*out_error = GetLastError();
	if (*out_error == ERROR_SUCCESS)
		*out_error = ERROR_WRITE_FAULT;
	return false;
}



/** Passes the exact original hook tuple to the next hook. */
static LRESULT NavPassOriginal(void *context)
{
	const NavPassContext *pass = (const NavPassContext *)context;
	return CallNextHookEx(
		pass->hook,
		pass->code,
		pass->message,
		pass->data_pointer);
}



/**
 * Delivers an already-linearized hook decision in its only valid order.
 *
 * @param result Atomic navigation decision.
 * @param emit_menu_mask Whether Ctrl camouflage must precede PASS.
 * @param emit_mask_fn Production SendInput or a hook-free test sink.
 * @param pass_fn Production CallNextHookEx or a hook-free test sink.
 * @param context Opaque sink context.
 * @param out_mask_error Receives an emitter error without suppressing input.
 * @return One for suppression or the exact downstream hook result.
 */
static LRESULT NavDeliverHookDecision(
	const ErgoptiNav_DispatchResult *result,
	bool emit_menu_mask,
	NavEmitMenuMaskFn emit_mask_fn,
	NavPassOriginalFn pass_fn,
	void *context,
	DWORD *out_mask_error)
{
	*out_mask_error = ERROR_SUCCESS;
	if (result->disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS)
		return 1;
	if (emit_menu_mask)
		(void)emit_mask_fn(context, out_mask_error);
	return pass_fn(context);
}



/**
 * Handles one global low-level keyboard event on the dedicated hook thread.
 *
 * @param code Hook action code.
 * @param message Low-level keyboard message identifier.
 * @param data_pointer Pointer to KBDLLHOOKSTRUCT.
 * @return One to suppress or the next hook result to pass.
 */
static LRESULT CALLBACK NavLowLevelKeyboardProc(
	int code,
	WPARAM message,
	LPARAM data_pointer)
{
	ErgoptiNav_TestEvent event;
	ErgoptiNav_DispatchResult result;
	HWND wake_window = NULL;
	UINT wake_message = 0;
	HHOOK hook;
	bool mask_required = false;
	bool emit_menu_mask = false;
	bool drain_complete = false;
	DWORD mask_error = ERROR_SUCCESS;
	DWORD drain_error = ERROR_SUCCESS;
	LRESULT delivery_result;
	HANDLE drain_event = NULL;
	NavPassContext pass_context;

	if (code != HC_ACTION || data_pointer == 0)
		return CallNextHookEx(NULL, code, message, data_pointer);

	EnterCriticalSection(&g_nav_state.lock);
	hook = g_nav_state.hook;
	if (NavCaptureTerminalEventLocked(
			&g_nav_state,
			message,
			(const KBDLLHOOKSTRUCT *)data_pointer)) {
		if (g_nav_state.terminal_phase == ERGOPTI_NAV_TERMINAL_FAULTED) {
			wake_window = g_nav_state.wake_window;
			wake_message = g_nav_state.wake_message;
		}
		LeaveCriticalSection(&g_nav_state.lock);
		if (wake_window != NULL && wake_message != 0)
			PostMessageW(wake_window, wake_message, 0, 0);
		return 1;
	}
	if (!NavProcessHookEventLocked(
			message,
			(const KBDLLHOOKSTRUCT *)data_pointer,
			&g_nav_state,
			&event,
			&result,
			false,
			&mask_required,
			&emit_menu_mask)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return CallNextHookEx(hook, code, message, data_pointer);
	}
	/* Camouflage must succeed before a digit receipt or suppress hold commits.
	 * SendInput may be blocked by UIPI; in that case latch the original hold PASS,
	 * suspend native ownership and wake AHK to perform terminal recovery. */
	if (mask_required) {
		LeaveCriticalSection(&g_nav_state.lock);
		if (!NavEmitMenuMask(NULL, &mask_error)) {
			EnterCriticalSection(&g_nav_state.lock);
			NavFailOpenMenuMaskFailureLocked(
				&g_nav_state, &event, &result, mask_error);
			wake_window = g_nav_state.wake_window;
			wake_message = g_nav_state.wake_message;
			LeaveCriticalSection(&g_nav_state.lock);
			if (wake_window != NULL && wake_message != 0)
				PostMessageW(wake_window, wake_message, 0, 0);
			return CallNextHookEx(hook, code, message, data_pointer);
		}
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.menu_undisguised = 0;
		mask_required = false;
		emit_menu_mask = false;
		if (!NavProcessHookEventLocked(
				message,
				(const KBDLLHOOKSTRUCT *)data_pointer,
				&g_nav_state,
				&event,
				&result,
				true,
				&mask_required,
				&emit_menu_mask)) {
			LeaveCriticalSection(&g_nav_state.lock);
			return CallNextHookEx(hook, code, message, data_pointer);
		}
		if (result.disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS)
			NavArmMenuGuardLocked(&g_nav_state);
	}
	if (result.receipt_created) {
		wake_window = g_nav_state.wake_window;
		wake_message = g_nav_state.wake_message;
	}
	if (g_nav_state.draining && NavDrainCompleteLocked(&g_nav_state)) {
		drain_complete = true;
		drain_event = g_nav_state.stop_event;
	}
	LeaveCriticalSection(&g_nav_state.lock);

	if (wake_window != NULL && wake_message != 0)
		PostMessageW(wake_window, wake_message, 0, 0);
	pass_context.hook = hook;
	pass_context.code = code;
	pass_context.message = message;
	pass_context.data_pointer = data_pointer;
	delivery_result = NavDeliverHookDecision(
		&result,
		emit_menu_mask,
		NavEmitMenuMask,
		NavPassOriginal,
		&pass_context,
		&mask_error);
	if (mask_error != ERROR_SUCCESS) {
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = mask_error;
		g_nav_state.suspended = 1;
		LeaveCriticalSection(&g_nav_state.lock);
	}
	if (drain_complete && mask_error == ERROR_SUCCESS
			&& drain_event != NULL && !SetEvent(drain_event)) {
		drain_error = GetLastError();
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = drain_error;
		LeaveCriticalSection(&g_nav_state.lock);
	}
	return delivery_result;
}



/**
 * Installs the hook and pumps messages until the stop event is signaled.
 *
 * @param parameter Unused CreateThread parameter.
 * @return Zero after deterministic unhooking.
 */
static DWORD WINAPI NavHookThreadMain(LPVOID parameter)
{
	MSG message;
	HHOOK hook;
	HANDLE ready_event;
	HANDLE stop_event;
	uint8_t initial_modifiers;
	DWORD os_error = 0;
	DWORD exit_os_error = 0;
	int32_t exit_status = ERGOPTI_NAV_STATUS_OK;
	bool stop_requested = false;
	HINSTANCE module = g_nav_module != NULL
		? g_nav_module
		: GetModuleHandleW(NULL);

	(void)parameter;
	EnterCriticalSection(&g_nav_state.lock);
	ready_event = g_nav_state.ready_event;
	stop_event = g_nav_state.stop_event;
	if (g_nav_state.startup_cancelled) {
		LeaveCriticalSection(&g_nav_state.lock);
		if (ready_event != NULL)
			SetEvent(ready_event);
		return 0;
	}
	LeaveCriticalSection(&g_nav_state.lock);
	if (stop_event != NULL
			&& WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0) {
		if (ready_event != NULL)
			SetEvent(ready_event);
		return 0;
	}

	PeekMessageW(&message, NULL, WM_USER, WM_USER, PM_NOREMOVE);
	hook = SetWindowsHookExW(
		WH_KEYBOARD_LL,
		NavLowLevelKeyboardProc,
		module,
		0);
	if (hook == NULL)
		os_error = GetLastError();
	initial_modifiers = NavReadModifierState();

	EnterCriticalSection(&g_nav_state.lock);
	g_nav_state.thread_id = GetCurrentThreadId();
	g_nav_state.hook = hook;
	g_nav_state.running = hook != NULL;
	NavApplyInitialModifierSnapshotLocked(
		&g_nav_state, initial_modifiers);
	if (!g_nav_state.startup_cancelled) {
		g_nav_state.thread_start_status = hook != NULL
			? ERGOPTI_NAV_STATUS_OK
			: ERGOPTI_NAV_STATUS_OS_ERROR;
		if (os_error != 0)
			g_nav_state.last_os_error = os_error;
	}
	ready_event = g_nav_state.ready_event;
	stop_event = g_nav_state.stop_event;
	LeaveCriticalSection(&g_nav_state.lock);

	if (ready_event != NULL)
		SetEvent(ready_event);
	if (hook == NULL)
		return 0;

	while (!stop_requested) {
		DWORD wait_result = MsgWaitForMultipleObjects(
			1,
			&stop_event,
			FALSE,
			INFINITE,
			QS_ALLINPUT);
		if (wait_result == WAIT_OBJECT_0) {
			bool drain_complete;
			bool startup_cancelled;
			EnterCriticalSection(&g_nav_state.lock);
			g_nav_state.draining = 1;
			startup_cancelled = g_nav_state.startup_cancelled != 0;
			drain_complete = NavDrainCompleteLocked(&g_nav_state);
			LeaveCriticalSection(&g_nav_state.lock);
			if (startup_cancelled || drain_complete)
				break;
			if (!ResetEvent(stop_event)) {
				exit_os_error = GetLastError();
				exit_status = ERGOPTI_NAV_STATUS_OS_ERROR;
				break;
			}
			continue;
		}
		if (wait_result == WAIT_OBJECT_0 + 1u) {
			while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
				if (message.message == WM_QUIT) {
					stop_requested = true;
					break;
				}
				TranslateMessage(&message);
				DispatchMessageW(&message);
			}
		} else {
			exit_os_error = GetLastError();
			exit_status = ERGOPTI_NAV_STATUS_OS_ERROR;
			break;
		}
	}

	if (!UnhookWindowsHookEx(hook)) {
		if (exit_os_error == 0)
			exit_os_error = GetLastError();
		exit_status = ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	EnterCriticalSection(&g_nav_state.lock);
	g_nav_state.thread_exit_status = exit_status;
	if (exit_os_error != 0 && !g_nav_state.startup_cancelled)
		g_nav_state.last_os_error = exit_os_error;
	g_nav_state.hook = NULL;
	g_nav_state.running = 0;
	g_nav_state.thread_id = 0;
	LeaveCriticalSection(&g_nav_state.lock);
	return 0;
}



/**
 * Detaches completed thread handles from state so callers can close them.
 *
 * @param state Locked native state.
 * @param out_thread Receives the thread handle.
 * @param out_ready Receives the ready-event handle.
 * @param out_stop Receives the stop-event handle.
 */
static void NavDetachThreadHandlesLocked(
	NavState *state,
	HANDLE *out_thread,
	HANDLE *out_ready,
	HANDLE *out_stop)
{
	*out_thread = state->thread_handle;
	*out_ready = state->ready_event;
	*out_stop = state->stop_event;
	state->thread_handle = NULL;
	state->ready_event = NULL;
	state->stop_event = NULL;
	state->thread_id = 0;
	state->hook = NULL;
	state->running = 0;
}




// ==================================
// ==================================
// ======= 5/ Public Lifecycle =======
// ==================================
// ==================================

/** Implements ErgoptiNav_Start. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_Start(
	uint64_t wake_window,
	uint32_t wake_message)
{
	HANDLE ready_event;
	HANDLE stop_event;
	HANDLE thread_handle;
	DWORD wait_result;
	DWORD failure_error;
	DWORD rollback_result;
	DWORD os_error;
	int32_t failure_status;
	int32_t start_status;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (wake_window == 0 || wake_message == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;

	ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (ready_event == NULL) {
		os_error = GetLastError();
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = os_error;
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (stop_event == NULL) {
		os_error = GetLastError();
		NavCloseHandle(ready_event);
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = os_error;
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}

	EnterCriticalSection(&g_nav_state.lock);
	if (g_nav_state.thread_handle != NULL) {
		LeaveCriticalSection(&g_nav_state.lock);
		NavCloseHandle(ready_event);
		NavCloseHandle(stop_event);
		return ERGOPTI_NAV_STATUS_ALREADY_STARTED;
	}
	g_nav_state.ready_event = ready_event;
	g_nav_state.stop_event = stop_event;
	g_nav_state.wake_window = (HWND)(uintptr_t)wake_window;
	g_nav_state.wake_message = wake_message;
	g_nav_state.last_os_error = 0;
	g_nav_state.thread_start_status = ERGOPTI_NAV_STATUS_INVALID_STATE;
	g_nav_state.thread_exit_status = ERGOPTI_NAV_STATUS_OK;
	thread_handle = CreateThread(
		NULL,
		0,
		NavHookThreadMain,
		NULL,
		0,
		NULL);
	if (thread_handle == NULL) {
		g_nav_state.last_os_error = GetLastError();
		g_nav_state.ready_event = NULL;
		g_nav_state.stop_event = NULL;
		g_nav_state.wake_window = NULL;
		g_nav_state.wake_message = 0;
		LeaveCriticalSection(&g_nav_state.lock);
		NavCloseHandle(ready_event);
		NavCloseHandle(stop_event);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	g_nav_state.thread_handle = thread_handle;
	LeaveCriticalSection(&g_nav_state.lock);

	wait_result = WaitForSingleObject(ready_event, NAV_HOOK_START_TIMEOUT_MS);
	if (wait_result != WAIT_OBJECT_0) {
		failure_error = wait_result == WAIT_TIMEOUT
			? ERROR_TIMEOUT
			: GetLastError();
		failure_status = wait_result == WAIT_TIMEOUT
			? ERGOPTI_NAV_STATUS_TIMEOUT
			: ERGOPTI_NAV_STATUS_OS_ERROR;
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.suspended = 1;
		g_nav_state.startup_cancelled = 1;
		g_nav_state.thread_start_status = failure_status;
		g_nav_state.last_os_error = failure_error;
		LeaveCriticalSection(&g_nav_state.lock);

		/*
		 * Preserve the first failure while rolling back the entire thread/hook
		 * admission. A second timeout quarantines the still-owned handles in
		 * state so Stop can retry; closing them while the thread can access them
		 * would turn a recoverable install refusal into use-after-close.
		 */
		(void)SetEvent(stop_event);
		rollback_result = WaitForSingleObject(
			thread_handle,
			NAV_HOOK_STOP_TIMEOUT_MS);
		if (rollback_result == WAIT_OBJECT_0) {
			EnterCriticalSection(&g_nav_state.lock);
			{
				HANDLE detached_thread;
				HANDLE detached_ready;
				HANDLE detached_stop;
				NavDetachThreadHandlesLocked(
					&g_nav_state,
					&detached_thread,
					&detached_ready,
					&detached_stop);
				g_nav_state.wake_window = NULL;
				g_nav_state.wake_message = 0;
				g_nav_state.suspended = 0;
				g_nav_state.startup_cancelled = 0;
				LeaveCriticalSection(&g_nav_state.lock);
				NavCloseHandle(detached_thread);
				NavCloseHandle(detached_ready);
				NavCloseHandle(detached_stop);
			}
		}
		return failure_status;
	}

	EnterCriticalSection(&g_nav_state.lock);
	start_status = g_nav_state.thread_start_status;
	if (start_status == ERGOPTI_NAV_STATUS_OK)
		g_nav_state.ready_event = NULL;
	LeaveCriticalSection(&g_nav_state.lock);
	if (start_status == ERGOPTI_NAV_STATUS_OK) {
		NavCloseHandle(ready_event);
		return ERGOPTI_NAV_STATUS_OK;
	}

	rollback_result = WaitForSingleObject(
		thread_handle,
		NAV_HOOK_STOP_TIMEOUT_MS);
	if (rollback_result != WAIT_OBJECT_0) {
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.suspended = 1;
		g_nav_state.startup_cancelled = 1;
		LeaveCriticalSection(&g_nav_state.lock);
		(void)SetEvent(stop_event);
		return start_status;
	}
	EnterCriticalSection(&g_nav_state.lock);
	{
		HANDLE detached_thread;
		HANDLE detached_ready;
		HANDLE detached_stop;
		NavDetachThreadHandlesLocked(
			&g_nav_state,
			&detached_thread,
			&detached_ready,
			&detached_stop);
		g_nav_state.wake_window = NULL;
		g_nav_state.wake_message = 0;
		LeaveCriticalSection(&g_nav_state.lock);
		NavCloseHandle(detached_thread);
		NavCloseHandle(detached_ready);
		NavCloseHandle(detached_stop);
	}
	return start_status;
}



/** Implements ErgoptiNav_Stop. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_Stop(void)
{
	HANDLE thread_handle;
	HANDLE stop_event;
	DWORD wait_result;
	DWORD wait_timeout;
	DWORD os_error;
	int32_t stop_status;
	bool drain_complete;
	uint8_t previous_draining;
	uint8_t previous_suspended;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;

	EnterCriticalSection(&g_nav_state.lock);
	previous_suspended = g_nav_state.suspended;
	previous_draining = g_nav_state.draining;
	g_nav_state.suspended = 1;
	g_nav_state.draining = 1;
	drain_complete = NavDrainCompleteLocked(&g_nav_state);
	thread_handle = g_nav_state.thread_handle;
	stop_event = g_nav_state.stop_event;
	if (thread_handle == NULL) {
		NavResetSemanticStateLocked(&g_nav_state);
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OK;
	}
	LeaveCriticalSection(&g_nav_state.lock);

	if (stop_event == NULL) {
		os_error = ERROR_INVALID_HANDLE;
	} else if (!SetEvent(stop_event)) {
		os_error = GetLastError();
	} else {
		os_error = ERROR_SUCCESS;
	}
	if (os_error != ERROR_SUCCESS) {
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = os_error;
		if (g_nav_state.thread_handle == thread_handle
				&& g_nav_state.stop_event == stop_event) {
			g_nav_state.suspended = previous_suspended;
			g_nav_state.draining = previous_draining;
		}
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	if (!drain_complete)
		return ERGOPTI_NAV_STATUS_STOP_PENDING;
	wait_timeout = previous_draining ? 0 : NAV_HOOK_STOP_TIMEOUT_MS;
	wait_result = WaitForSingleObject(thread_handle, wait_timeout);
	if (wait_result != WAIT_OBJECT_0) {
		os_error = wait_result == WAIT_TIMEOUT
			? ERROR_TIMEOUT
			: GetLastError();
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = os_error;
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_STOP_PENDING;
	}

	EnterCriticalSection(&g_nav_state.lock);
	{
		HANDLE detached_thread;
		HANDLE detached_ready;
		HANDLE detached_stop;
		stop_status = g_nav_state.thread_exit_status;
		os_error = g_nav_state.last_os_error;
		NavDetachThreadHandlesLocked(
			&g_nav_state,
			&detached_thread,
			&detached_ready,
			&detached_stop);
		NavResetSemanticStateLocked(&g_nav_state);
		if (stop_status != ERGOPTI_NAV_STATUS_OK)
			g_nav_state.last_os_error = os_error;
		LeaveCriticalSection(&g_nav_state.lock);
		NavCloseHandle(detached_thread);
		NavCloseHandle(detached_ready);
		NavCloseHandle(detached_stop);
	}
	return stop_status == ERGOPTI_NAV_STATUS_OK
		? ERGOPTI_NAV_STATUS_OK
		: ERGOPTI_NAV_STATUS_STOPPED_WITH_ERROR;
}



/** Implements ErgoptiNav_PreparePlan. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PreparePlan(
	const ErgoptiNav_Binding *bindings,
	uint32_t binding_count,
	uint64_t *out_generation)
{
	ErgoptiNav_Binding candidate[ERGOPTI_NAV_ROUTE_COUNT];
	uint64_t generation;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (bindings == NULL
			|| out_generation == NULL
			|| binding_count != ERGOPTI_NAV_ROUTE_COUNT)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	memcpy(candidate, bindings, sizeof(candidate));
	if (!NavPlanIsValid(candidate))
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;

	EnterCriticalSection(&g_nav_state.lock);
	generation = NavNextIdentity(&g_nav_state.next_plan_generation);
	memcpy(g_nav_state.prepared_plan, candidate, sizeof(candidate));
	g_nav_state.prepared_plan_generation = generation;
	g_nav_state.prepared_plan_valid = 1;
	LeaveCriticalSection(&g_nav_state.lock);
	*out_generation = generation;
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_CommitPlan. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CommitPlan(
	uint64_t generation)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (generation == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (g_nav_state.transition) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	if (!g_nav_state.prepared_plan_valid
			|| g_nav_state.prepared_plan_generation != generation) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_NOT_FOUND;
	}
	memcpy(
		g_nav_state.active_plan,
		g_nav_state.prepared_plan,
		sizeof(g_nav_state.active_plan));
	g_nav_state.active_plan_generation = generation;
	g_nav_state.active_plan_valid = 1;
	g_nav_state.prepared_plan_valid = 0;
	g_nav_state.prepared_plan_generation = 0;
	memset(g_nav_state.prepared_plan, 0, sizeof(g_nav_state.prepared_plan));
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Sends one replay batch through the Win32 serialization boundary. */
static uint32_t NavSendTerminalInputsSystem(
	const INPUT *events,
	uint32_t event_count,
	void *context)
{
	(void)context;
	return (uint32_t)SendInput(
		(UINT)event_count,
		(INPUT *)(uintptr_t)events,
		(int)sizeof(INPUT));
}



/** Builds one replay batch from the oldest captured physical edges. */
static uint32_t NavBuildTerminalReplayBatchLocked(
	const NavState *state,
	INPUT events[NAV_TERMINAL_REPLAY_BATCH])
{
	uint32_t index;
	uint32_t count = state->terminal_queued < NAV_TERMINAL_REPLAY_BATCH
		? state->terminal_queued : NAV_TERMINAL_REPLAY_BATCH;
	memset(events, 0, sizeof(INPUT) * NAV_TERMINAL_REPLAY_BATCH);
	for (index = 0; index < count; ++index) {
		const NavTerminalKeyEdge *edge = &state->terminal_events[index];
		events[index].type = INPUT_KEYBOARD;
		if (edge->sc != 0) {
			events[index].ki.wVk = 0;
			events[index].ki.wScan = edge->sc;
			events[index].ki.dwFlags = KEYEVENTF_SCANCODE;
		} else {
			/* LL hooks may report a virtual key without a scan code. Preserve
			 * that edge through the VK SendInput form instead of emitting an
			 * invalid scan-code-zero event. */
			events[index].ki.wVk = edge->vk;
			events[index].ki.wScan = 0;
			events[index].ki.dwFlags = 0;
		}
		if (edge->extended)
			events[index].ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
		if (edge->key_up)
			events[index].ki.dwFlags |= KEYEVENTF_KEYUP;
		events[index].ki.dwExtraInfo =
			(ULONG_PTR)ERGOPTI_NAV_TERMINAL_REPLAY_MARKER;
	}
	return count;
}



/** Removes one successfully replayed FIFO prefix under the state lock. */
static void NavConsumeTerminalReplayLocked(NavState *state, uint32_t count)
{
	if (count >= state->terminal_queued) {
		state->terminal_queued = 0;
		memset(state->terminal_events, 0, sizeof(state->terminal_events));
		return;
	}
	memmove(
		state->terminal_events,
		&state->terminal_events[count],
		(state->terminal_queued - count) * sizeof(state->terminal_events[0]));
	state->terminal_queued -= count;
	memset(
		&state->terminal_events[state->terminal_queued],
		0,
		count * sizeof(state->terminal_events[0]));
}



/** Replays one capture through an injectable SendInput-compatible sink. */
static int32_t NavReleaseTerminalCapture(
	uint64_t token,
	uint32_t release_kind,
	NavTerminalSendFn send_fn,
	void *context)
{
	INPUT events[NAV_TERMINAL_REPLAY_BATCH];
	uint32_t count;
	uint32_t sent;
	DWORD os_error;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (token == 0 || send_fn == NULL
			|| (release_kind != ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT
				&& release_kind != ERGOPTI_NAV_TERMINAL_RELEASE_ABORT))
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;

	for (;;) {
		EnterCriticalSection(&g_nav_state.lock);
		if (g_nav_state.terminal_token != token) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
		}
		if (g_nav_state.terminal_phase == ERGOPTI_NAV_TERMINAL_FAULTED) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OS_ERROR;
		}
		if (g_nav_state.terminal_phase == ERGOPTI_NAV_TERMINAL_IDLE) {
			int32_t idle_status = g_nav_state.terminal_release_kind == release_kind
				? ERGOPTI_NAV_STATUS_OK : ERGOPTI_NAV_STATUS_INVALID_STATE;
			LeaveCriticalSection(&g_nav_state.lock);
			return idle_status;
		}
		if (g_nav_state.terminal_release_kind != ERGOPTI_NAV_TERMINAL_RELEASE_NONE
				&& g_nav_state.terminal_release_kind != release_kind) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_INVALID_STATE;
		}
		g_nav_state.terminal_release_kind = release_kind;
		g_nav_state.terminal_phase = ERGOPTI_NAV_TERMINAL_REPLAYING;
		count = NavBuildTerminalReplayBatchLocked(&g_nav_state, events);
		if (count == 0) {
			g_nav_state.terminal_phase = ERGOPTI_NAV_TERMINAL_IDLE;
			g_nav_state.terminal_last_os_error = ERROR_SUCCESS;
			g_nav_state.last_os_error = ERROR_SUCCESS;
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OK;
		}
		LeaveCriticalSection(&g_nav_state.lock);

		SetLastError(ERROR_SUCCESS);
		sent = send_fn(events, count, context);
		os_error = GetLastError();
		if (sent > count)
			sent = 0;

		EnterCriticalSection(&g_nav_state.lock);
		if (g_nav_state.terminal_token != token) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
		}
		if (sent != 0) {
			NavConsumeTerminalReplayLocked(&g_nav_state, sent);
			g_nav_state.terminal_replayed += sent;
		}
		if (sent != count) {
			if (os_error == ERROR_SUCCESS)
				os_error = ERROR_WRITE_FAULT;
			g_nav_state.terminal_phase = ERGOPTI_NAV_TERMINAL_RELEASE_PENDING;
			g_nav_state.terminal_last_os_error = os_error;
			g_nav_state.last_os_error = os_error;
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OS_ERROR;
		}
		g_nav_state.terminal_last_os_error = ERROR_SUCCESS;
		if (g_nav_state.terminal_queued == 0) {
			g_nav_state.terminal_phase = ERGOPTI_NAV_TERMINAL_IDLE;
			g_nav_state.last_os_error = ERROR_SUCCESS;
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OK;
		}
		LeaveCriticalSection(&g_nav_state.lock);
	}
}



/** Implements ErgoptiNav_SetSuspended. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_SetSuspended(
	uint8_t suspended)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (suspended > 1)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (suspended && NavHasTerminalDebtLocked(&g_nav_state)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	g_nav_state.suspended = suspended;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_BeginTerminalCapture. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_BeginTerminalCapture(
	uint64_t token)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (token == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (!g_nav_state.running || g_nav_state.suspended
			|| g_nav_state.draining || g_nav_state.transition
			|| NavHasTerminalDebtLocked(&g_nav_state)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	g_nav_state.terminal_token = token;
	g_nav_state.terminal_phase = ERGOPTI_NAV_TERMINAL_CAPTURING;
	g_nav_state.terminal_queued = 0;
	g_nav_state.terminal_replayed = 0;
	g_nav_state.terminal_last_os_error = ERROR_SUCCESS;
	g_nav_state.terminal_release_kind = ERGOPTI_NAV_TERMINAL_RELEASE_NONE;
	memset(g_nav_state.terminal_events, 0, sizeof(g_nav_state.terminal_events));
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_CommitTerminalCapture. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CommitTerminalCapture(
	uint64_t token)
{
	return NavReleaseTerminalCapture(
		token,
		ERGOPTI_NAV_TERMINAL_RELEASE_COMMIT,
		NavSendTerminalInputsSystem,
		NULL);
}



/** Implements ErgoptiNav_AbortTerminalCapture. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_AbortTerminalCapture(
	uint64_t token)
{
	return NavReleaseTerminalCapture(
		token,
		ERGOPTI_NAV_TERMINAL_RELEASE_ABORT,
		NavSendTerminalInputsSystem,
		NULL);
}



/** Implements ErgoptiNav_GetTerminalCapture. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_GetTerminalCapture(
	uint64_t token,
	ErgoptiNav_TerminalCaptureSnapshot *out_snapshot)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (token == 0 || out_snapshot == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (g_nav_state.terminal_token != token) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	out_snapshot->token = g_nav_state.terminal_token;
	out_snapshot->phase = g_nav_state.terminal_phase;
	out_snapshot->queued = g_nav_state.terminal_queued;
	out_snapshot->replayed = g_nav_state.terminal_replayed;
	out_snapshot->last_os_error = g_nav_state.terminal_last_os_error;
	out_snapshot->release_kind = g_nav_state.terminal_release_kind;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}




// ========================================
// ========================================
// ======= 6/ Public Owner Lifecycle =======
// ========================================
// ========================================

/** Implements ErgoptiNav_BeginOwnerSwap. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_BeginOwnerSwap(
	uint64_t expected_token,
	const ErgoptiNav_Owner *next_owner,
	uint64_t *out_ticket)
{
	uint64_t ticket;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (out_ticket == NULL || !NavOwnerIsValid(next_owner))
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (g_nav_state.transition) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	if (g_nav_state.active_owner.token != expected_token) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	if (next_owner->require_index_match
			&& (g_nav_state.active_owner.token == 0
				|| g_nav_state.active_owner.active_index
					!= next_owner->active_index)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	ticket = NavNextIdentity(&g_nav_state.next_swap_ticket);
	g_nav_state.staged_owner = *next_owner;
	g_nav_state.staged_owner.require_index_match = 0;
	g_nav_state.active_swap_ticket = ticket;
	g_nav_state.transition = 1;
	LeaveCriticalSection(&g_nav_state.lock);
	*out_ticket = ticket;
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_CommitOwnerSwap. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CommitOwnerSwap(
	uint64_t ticket)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (ticket == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (!g_nav_state.transition
			|| g_nav_state.active_swap_ticket != ticket) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_NOT_FOUND;
	}
	g_nav_state.active_owner = g_nav_state.staged_owner;
	memset(&g_nav_state.staged_owner, 0, sizeof(g_nav_state.staged_owner));
	g_nav_state.active_swap_ticket = 0;
	g_nav_state.transition = 0;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_AbortOwnerSwap. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_AbortOwnerSwap(
	uint64_t ticket)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (ticket == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (!g_nav_state.transition
			|| g_nav_state.active_swap_ticket != ticket) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_NOT_FOUND;
	}
	memset(&g_nav_state.staged_owner, 0, sizeof(g_nav_state.staged_owner));
	g_nav_state.active_swap_ticket = 0;
	g_nav_state.transition = 0;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_ClaimOwner. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_ClaimOwner(
	uint64_t owner_token,
	uint8_t expected_index)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (owner_token == 0
			|| expected_index == 0
			|| expected_index > ERGOPTI_NAV_MAX_SLOTS)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	if (g_nav_state.transition) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	if (g_nav_state.active_owner.token != owner_token
			|| g_nav_state.active_owner.active_index != expected_index) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	memset(&g_nav_state.active_owner, 0, sizeof(g_nav_state.active_owner));
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_GetOwner. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_GetOwner(
	ErgoptiNav_Owner *out_owner)
{
	int32_t status;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (out_owner == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	*out_owner = g_nav_state.active_owner;
	status = g_nav_state.transition
		? ERGOPTI_NAV_STATUS_BUSY
		: ERGOPTI_NAV_STATUS_OK;
	LeaveCriticalSection(&g_nav_state.lock);
	return status;
}




// =========================================
// =========================================
// ======= 7/ Public Receipt Lifecycle =======
// =========================================
// =========================================

/** Implements ErgoptiNav_PollReceipt. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PollReceipt(
	ErgoptiNav_Receipt *out_receipt)
{
	uint32_t index;
	int32_t found_index = -1;
	uint64_t found_sequence = UINT64_MAX;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (out_receipt == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	memset(out_receipt, 0, sizeof(*out_receipt));

	EnterCriticalSection(&g_nav_state.lock);
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		const NavReceiptSlot *slot = &g_nav_state.receipts[index];
		if (slot->state == NAV_RECEIPT_QUEUED
				&& slot->receipt.sequence < found_sequence) {
			found_sequence = slot->receipt.sequence;
			found_index = (int32_t)index;
		}
	}
	if (found_index < 0) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_NOT_FOUND;
	}
	g_nav_state.receipts[found_index].state = NAV_RECEIPT_CLAIMED;
	*out_receipt = g_nav_state.receipts[found_index].receipt;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements ErgoptiNav_CompleteReceipt. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CompleteReceipt(
	uint64_t sequence,
	uint64_t owner_token,
	uint8_t applied_index)
{
	HANDLE drain_event = NULL;
	uint32_t index;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (sequence == 0 || owner_token == 0 || applied_index == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		NavReceiptSlot *slot = &g_nav_state.receipts[index];
		if (slot->state == NAV_RECEIPT_EMPTY
				|| slot->receipt.sequence != sequence)
			continue;
		if (slot->state != NAV_RECEIPT_CLAIMED) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_INVALID_STATE;
		}
		if (slot->receipt.owner_token != owner_token) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
		}
		if (slot->receipt.target_index != applied_index) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
		}
		memset(slot, 0, sizeof(*slot));
		if (g_nav_state.draining && NavDrainCompleteLocked(&g_nav_state))
			drain_event = g_nav_state.stop_event;
		LeaveCriticalSection(&g_nav_state.lock);
		if (drain_event != NULL && !SetEvent(drain_event)) {
			DWORD os_error = GetLastError();
			EnterCriticalSection(&g_nav_state.lock);
			g_nav_state.last_os_error = os_error;
			LeaveCriticalSection(&g_nav_state.lock);
		}
		return ERGOPTI_NAV_STATUS_OK;
	}
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_NOT_FOUND;
}



/** Implements ErgoptiNav_PendingForToken. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PendingForToken(
	uint64_t owner_token,
	uint32_t *out_pending)
{
	uint32_t index;
	uint32_t pending = 0;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (owner_token == 0 || out_pending == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	for (index = 0; index < ERGOPTI_NAV_RECEIPT_CAPACITY; ++index) {
		const NavReceiptSlot *slot = &g_nav_state.receipts[index];
		if (slot->state != NAV_RECEIPT_EMPTY
				&& slot->receipt.owner_token == owner_token)
			++pending;
	}
	LeaveCriticalSection(&g_nav_state.lock);
	*out_pending = pending;
	return ERGOPTI_NAV_STATUS_OK;
}




// ==========================================
// ==========================================
// ======= 8/ Diagnostics and Test Seam =======
// ==========================================
// ==========================================

/** Implements ErgoptiNav_GetLastOsError. */
ERGOPTI_NAV_API uint32_t ERGOPTI_NAV_CALL ErgoptiNav_GetLastOsError(void)
{
	DWORD os_error;
	if (!NavEnsureInitialized())
		return g_nav_initialization_error;
	EnterCriticalSection(&g_nav_state.lock);
	os_error = g_nav_state.last_os_error;
	LeaveCriticalSection(&g_nav_state.lock);
	return os_error;
}



/** Implements ErgoptiNav_TestDispatch. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestDispatch(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (!NavTestEventIsValid(event) || out_result == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	(void)NavDispatchLocked(&g_nav_state, event, true, out_result);
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



#if defined(ERGOPTI_NAV_TESTING)
/** Captures exact delivery ordering without SendInput or CallNextHookEx. */
typedef struct NavTestDeliveryTrace {
	uint8_t sequence;
	uint8_t mask_emitted;
	uint8_t pass_called;
	uint8_t mask_before_pass;
	uint8_t mask_should_fail;
} NavTestDeliveryTrace;



/** Seeds the exact production startup snapshot without installing a hook. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestSeedInitialModifier(
	uint16_t vk,
	uint16_t sc)
{
	uint8_t modifier_bit;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	modifier_bit = NavModifierBit(vk, sc);
	if (modifier_bit == 0)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	NavApplyInitialModifierSnapshotLocked(&g_nav_state, modifier_bit);
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Records the synthetic mask position in one hook-free delivery trace. */
static bool NavTestEmitMenuMask(void *context, DWORD *out_error)
{
	NavTestDeliveryTrace *trace = (NavTestDeliveryTrace *)context;
	if (trace->mask_should_fail) {
		*out_error = ERROR_ACCESS_DENIED;
		return false;
	}
	trace->sequence = (uint8_t)(trace->sequence + 1u);
	trace->mask_emitted = 1;
	*out_error = ERROR_SUCCESS;
	return true;
}



/** Records the downstream PASS position in one hook-free delivery trace. */
static LRESULT NavTestPassOriginal(void *context)
{
	NavTestDeliveryTrace *trace = (NavTestDeliveryTrace *)context;
	trace->sequence = (uint8_t)(trace->sequence + 1u);
	trace->pass_called = 1;
	if (trace->mask_emitted && trace->sequence == 2)
		trace->mask_before_pass = 1;
	return 0x5A5Au;
}



/** Implements the hook-free raw-event test seam. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestHookDispatch(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result)
{
	KBDLLHOOKSTRUCT native_event;
	ErgoptiNav_TestEvent canonical_event;
	bool mask_required = false;
	bool emit_menu_mask = false;
	WPARAM message;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (event == NULL || out_result == NULL || event->reserved != 0
			|| event->kind < ERGOPTI_NAV_EVENT_DOWN
			|| event->kind > ERGOPTI_NAV_EVENT_UP
			|| event->injected > ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	memset(&native_event, 0, sizeof(native_event));
	native_event.vkCode = event->vk;
	native_event.scanCode = event->sc & 0xFFu;
	if ((event->sc & 0x100u) != 0)
		native_event.flags |= LLKHF_EXTENDED;
	if (event->injected == ERGOPTI_NAV_INJECTION_STANDARD)
		native_event.flags |= LLKHF_INJECTED;
	else if (event->injected == ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY)
		native_event.flags |= LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED;
	native_event.dwExtraInfo = (ULONG_PTR)event->extra_info;
	message = event->kind == ERGOPTI_NAV_EVENT_UP ? WM_KEYUP : WM_KEYDOWN;

	EnterCriticalSection(&g_nav_state.lock);
	if (NavCaptureTerminalEventLocked(
			&g_nav_state, message, &native_event)) {
		memset(out_result, 0, sizeof(*out_result));
		out_result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OK;
	}
	if (!NavProcessHookEventLocked(
			message,
			&native_event,
			&g_nav_state,
			&canonical_event,
			out_result,
			true,
			&mask_required,
			&emit_menu_mask)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	}
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements the complete hook-flow test seam with inert delivery sinks. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestHookFlow(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result,
	uint8_t mask_should_fail,
	uint8_t *out_mask_emitted,
	uint8_t *out_pass_called,
	uint8_t *out_mask_before_pass)
{
	KBDLLHOOKSTRUCT native_event;
	ErgoptiNav_TestEvent canonical_event;
	NavTestDeliveryTrace trace;
	WPARAM message;
	bool mask_required = false;
	bool emit_menu_mask = false;
	DWORD mask_error = ERROR_SUCCESS;
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (event == NULL || out_result == NULL
			|| out_mask_emitted == NULL
			|| out_pass_called == NULL
			|| out_mask_before_pass == NULL
			|| mask_should_fail > 1
			|| event->reserved != 0
			|| event->kind < ERGOPTI_NAV_EVENT_DOWN
			|| event->kind > ERGOPTI_NAV_EVENT_UP
			|| event->injected > ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY) {
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	}
	memset(&native_event, 0, sizeof(native_event));
	memset(&trace, 0, sizeof(trace));
	trace.mask_should_fail = mask_should_fail;
	*out_mask_emitted = 0;
	*out_pass_called = 0;
	*out_mask_before_pass = 0;
	native_event.vkCode = event->vk;
	native_event.scanCode = event->sc & 0xFFu;
	if ((event->sc & 0x100u) != 0)
		native_event.flags |= LLKHF_EXTENDED;
	if (event->injected == ERGOPTI_NAV_INJECTION_STANDARD)
		native_event.flags |= LLKHF_INJECTED;
	else if (event->injected == ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY)
		native_event.flags |= LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED;
	native_event.dwExtraInfo = (ULONG_PTR)event->extra_info;
	message = event->kind == ERGOPTI_NAV_EVENT_UP ? WM_KEYUP : WM_KEYDOWN;

	EnterCriticalSection(&g_nav_state.lock);
	if (NavCaptureTerminalEventLocked(
			&g_nav_state, message, &native_event)) {
		memset(out_result, 0, sizeof(*out_result));
		out_result->disposition = ERGOPTI_NAV_DISPOSITION_SUPPRESS;
		LeaveCriticalSection(&g_nav_state.lock);
		*out_mask_emitted = 0;
		*out_pass_called = 0;
		*out_mask_before_pass = 0;
		return ERGOPTI_NAV_STATUS_OK;
	}
	if (!NavProcessHookEventLocked(
			message,
			&native_event,
			&g_nav_state,
			&canonical_event,
			out_result,
			false,
			&mask_required,
			&emit_menu_mask)) {
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	}
	if (mask_required) {
		LeaveCriticalSection(&g_nav_state.lock);
		if (!NavTestEmitMenuMask(&trace, &mask_error)) {
			EnterCriticalSection(&g_nav_state.lock);
			NavFailOpenMenuMaskFailureLocked(
				&g_nav_state, &canonical_event, out_result, mask_error);
			LeaveCriticalSection(&g_nav_state.lock);
			(void)NavTestPassOriginal(&trace);
			*out_mask_emitted = trace.mask_emitted;
			*out_pass_called = trace.pass_called;
			*out_mask_before_pass = trace.mask_before_pass;
			return ERGOPTI_NAV_STATUS_OS_ERROR;
		}
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.menu_undisguised = 0;
		mask_required = false;
		emit_menu_mask = false;
		if (!NavProcessHookEventLocked(
				message,
				&native_event,
				&g_nav_state,
				&canonical_event,
				out_result,
				true,
				&mask_required,
				&emit_menu_mask)) {
			LeaveCriticalSection(&g_nav_state.lock);
			return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
		}
		if (out_result->disposition == ERGOPTI_NAV_DISPOSITION_SUPPRESS)
			NavArmMenuGuardLocked(&g_nav_state);
	}
	LeaveCriticalSection(&g_nav_state.lock);
	(void)NavDeliverHookDecision(
		out_result,
		emit_menu_mask,
		NavTestEmitMenuMask,
		NavTestPassOriginal,
		&trace,
		&mask_error);
	*out_mask_emitted = trace.mask_emitted;
	*out_pass_called = trace.pass_called;
	*out_mask_before_pass = trace.mask_before_pass;
	if (mask_error != ERROR_SUCCESS) {
		EnterCriticalSection(&g_nav_state.lock);
		g_nav_state.last_os_error = mask_error;
		g_nav_state.suspended = 1;
		LeaveCriticalSection(&g_nav_state.lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements the hook-free Stop-drain admission seam. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestBeginDrain(void)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	EnterCriticalSection(&g_nav_state.lock);
	g_nav_state.suspended = 1;
	g_nav_state.draining = 1;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements the hook-free Stop-drain completion seam. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestDrainComplete(
	uint8_t *out_complete)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (out_complete == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	*out_complete = NavDrainCompleteLocked(&g_nav_state) ? 1 : 0;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** Implements the hook-free terminal running-state seam. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestSetRunning(uint8_t running)
{
	if (!NavEnsureInitialized())
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	if (running > 1)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	EnterCriticalSection(&g_nav_state.lock);
	g_nav_state.running = running;
	LeaveCriticalSection(&g_nav_state.lock);
	return ERGOPTI_NAV_STATUS_OK;
}



/** State for the deterministic terminal replay sink. */
typedef struct NavTestTerminalSendContext {
	uint32_t remaining;
	ErgoptiNav_TestEvent *events;
	uint32_t capacity;
	uint32_t count;
} NavTestTerminalSendContext;



/** Records one accepted replay prefix without injecting real input. */
static uint32_t NavTestSendTerminalInputs(
	const INPUT *events,
	uint32_t event_count,
	void *raw_context)
{
	NavTestTerminalSendContext *context =
		(NavTestTerminalSendContext *)raw_context;
	uint32_t accepted = event_count;
	uint32_t index;
	if (context->remaining != UINT32_MAX && accepted > context->remaining)
		accepted = context->remaining;
	for (index = 0; index < accepted; ++index) {
		ErgoptiNav_TestEvent *out_event;
		if (context->count >= context->capacity)
			break;
		out_event = &context->events[context->count++];
		memset(out_event, 0, sizeof(*out_event));
		out_event->vk = events[index].ki.wVk;
		out_event->sc = events[index].ki.wScan;
		if ((events[index].ki.dwFlags & KEYEVENTF_EXTENDEDKEY) != 0)
			out_event->sc = (uint16_t)(out_event->sc | 0x100u);
		out_event->kind =
			(events[index].ki.dwFlags & KEYEVENTF_KEYUP) != 0
				? ERGOPTI_NAV_EVENT_UP : ERGOPTI_NAV_EVENT_DOWN;
		out_event->injected = ERGOPTI_NAV_INJECTION_PHYSICAL;
		out_event->extra_info =
			(uint64_t)events[index].ki.dwExtraInfo;
	}
	if (context->remaining != UINT32_MAX)
		context->remaining -= accepted;
	if (accepted != event_count)
		SetLastError(ERROR_ACCESS_DENIED);
	return accepted;
}



/** Implements the hook-free terminal replay seam. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestReleaseTerminalCapture(
	uint64_t token,
	uint32_t release_kind,
	uint32_t send_limit,
	ErgoptiNav_TestEvent *out_events,
	uint32_t event_capacity,
	uint32_t *out_event_count)
{
	NavTestTerminalSendContext context;
	if (out_event_count == NULL
			|| (event_capacity != 0 && out_events == NULL))
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	memset(&context, 0, sizeof(context));
	context.remaining = send_limit;
	context.events = out_events;
	context.capacity = event_capacity;
	*out_event_count = 0;
	{
		int32_t status = NavReleaseTerminalCapture(
			token, release_kind, NavTestSendTerminalInputs, &context);
		*out_event_count = context.count;
		return status;
	}
}
#endif
