// static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner.h
/**
 * @file nav_event_owner.h
 * @brief Stable x64 C ABI for the Windows LLM navigation event owner.
 *
 * The module makes the low-level keyboard decision, semantic navigation commit,
 * and immutable receipt publication one native transaction. AutoHotkey may paint
 * the receipt later without re-reading whichever tooltip record is current then.
 * Every public structure is packed and uses fixed-width integers so an AHK v2
 * DllCall adapter can address fields by documented offsets.
 */

#ifndef ERGOPTI_NAV_EVENT_OWNER_H
#define ERGOPTI_NAV_EVENT_OWNER_H

#include <stddef.h>
#include <stdint.h>

#if !defined(_WIN32)
#error "The Ergopti navigation event owner requires Win32."
#endif

#if defined(__cplusplus)
extern "C" {
#endif

#define ERGOPTI_NAV_API __declspec(dllexport)
#define ERGOPTI_NAV_CALL __cdecl





// =================================
// =================================
// ======= 1/ ABI Constants =======
// =================================
// =================================

#define ERGOPTI_NAV_ABI_VERSION 1u
#define ERGOPTI_NAV_ROUTE_COUNT 12u
#define ERGOPTI_NAV_MAX_SLOTS 10u
#define ERGOPTI_NAV_RECEIPT_CAPACITY 64u
#define ERGOPTI_NAV_NO_ROUTE 0xFFu
#define ERGOPTI_NAV_AHK_SEND_LEVEL_MAX 100u
#define ERGOPTI_NAV_AHK_SEND_LEVEL_BASE 0xFFC3D44Du

/** Return codes shared by every fallible API entry point. */
typedef enum ErgoptiNav_Status {
	ERGOPTI_NAV_STATUS_OK = 0,
	ERGOPTI_NAV_STATUS_INVALID_ARGUMENT = 1,
	ERGOPTI_NAV_STATUS_INVALID_STATE = 2,
	ERGOPTI_NAV_STATUS_ALREADY_STARTED = 3,
	ERGOPTI_NAV_STATUS_NOT_FOUND = 4,
	ERGOPTI_NAV_STATUS_BUSY = 5,
	ERGOPTI_NAV_STATUS_OS_ERROR = 6,
	ERGOPTI_NAV_STATUS_TIMEOUT = 7,
	ERGOPTI_NAV_STATUS_OWNER_MISMATCH = 8,
	ERGOPTI_NAV_STATUS_STOP_PENDING = 9,
	ERGOPTI_NAV_STATUS_STOPPED_WITH_ERROR = 10
} ErgoptiNav_Status;

/** Descriptor axis values copied from the AHK-027 native descriptor. */
typedef enum ErgoptiNav_Axis {
	ERGOPTI_NAV_AXIS_VK = 1,
	ERGOPTI_NAV_AXIS_SC = 2
} ErgoptiNav_Axis;

/** Route actions supported by the twelve-entry navigation plan. */
typedef enum ErgoptiNav_Action {
	ERGOPTI_NAV_ACTION_CYCLE = 1,
	ERGOPTI_NAV_ACTION_JUMP = 2
} ErgoptiNav_Action;

/** Generic AHK modifier bits expected in bindings and test events. */
typedef enum ErgoptiNav_Modifier {
	ERGOPTI_NAV_MOD_CONTROL = 0x01,
	ERGOPTI_NAV_MOD_ALT = 0x02,
	ERGOPTI_NAV_MOD_SHIFT = 0x04,
	ERGOPTI_NAV_MOD_WIN = 0x08
} ErgoptiNav_Modifier;

/** Test event kinds corresponding to Win32 key-down and key-up messages. */
typedef enum ErgoptiNav_EventKind {
	ERGOPTI_NAV_EVENT_DOWN = 1,
	ERGOPTI_NAV_EVENT_UP = 2
} ErgoptiNav_EventKind;

/** Canonical injection provenance retained by dispatch and key-hold state. */
typedef enum ErgoptiNav_Injection {
	ERGOPTI_NAV_INJECTION_PHYSICAL = 0,
	ERGOPTI_NAV_INJECTION_STANDARD = 1,
	ERGOPTI_NAV_INJECTION_LOWER_INTEGRITY = 2
} ErgoptiNav_Injection;

/** Hook dispositions returned by the shared dispatch state machine. */
typedef enum ErgoptiNav_Disposition {
	ERGOPTI_NAV_DISPOSITION_PASS = 0,
	ERGOPTI_NAV_DISPOSITION_SUPPRESS = 1
} ErgoptiNav_Disposition;





// ==================================
// ==================================
// ======= 2/ Packed ABI Types =======
// ==================================
// ==================================

#pragma pack(push, 1)

/**
 * Describes one normalized physical navigation route.
 *
 * Layout: axis@0:u8, action@1:u8, modifiers@2:u8, pass_through@3:u8,
 * code@4:u16, delta@6:i8, target@7:u8, input_level@8:u8,
 * reserved@9:u8[3]. Jump targets and all owner indices are 1-based.
 */
typedef struct ErgoptiNav_Binding {
	uint8_t axis;
	uint8_t action;
	uint8_t modifiers;
	uint8_t pass_through;
	uint16_t code;
	int8_t delta;
	uint8_t target;
	uint8_t input_level;
	uint8_t reserved[3];
} ErgoptiNav_Binding;

/**
 * Describes the canonical tooltip owner visible to the hook.
 *
 * Layout: token@0:u64, epoch@8:u64, slot_count@16:u8,
 * active_index@17:u8, require_index_match@18:u8, reserved@19:u8[5]. Token zero
 * denotes no owner and requires every other byte to be zero. The match flag is
 * a one-swap guard used only by a repaint of the same semantic owner: a stale
 * prepared surface is rejected instead of inheriting an index its pixels did
 * not render.
 */
typedef struct ErgoptiNav_Owner {
	uint64_t token;
	uint64_t epoch;
	uint8_t slot_count;
	uint8_t active_index;
	uint8_t require_index_match;
	uint8_t reserved[5];
} ErgoptiNav_Owner;

/**
 * Carries one immutable semantic navigation commit to AutoHotkey.
 *
 * Layout: sequence@0:u64, owner_token@8:u64, owner_epoch@16:u64,
 * plan_generation@24:u64, route_index@32:u8, action@33:u8,
 * delta@34:i8, from_index@35:u8, target_index@36:u8,
 * pass_through@37:u8, reserved@38:u8[2]. The receipt retains its original
 * token even if a later owner swap publishes another tooltip.
 */
typedef struct ErgoptiNav_Receipt {
	uint64_t sequence;
	uint64_t owner_token;
	uint64_t owner_epoch;
	uint64_t plan_generation;
	uint8_t route_index;
	uint8_t action;
	int8_t delta;
	uint8_t from_index;
	uint8_t target_index;
	uint8_t pass_through;
	uint8_t reserved[2];
} ErgoptiNav_Receipt;

/**
 * Supplies a deterministic keyboard event to the production dispatch core.
 *
 * Layout: vk@0:u16, sc@2:u16, modifiers@4:u8, kind@5:u8,
 * injected@6:u8, reserved@7:u8, extra_info@8:u64. Injected is an
 * ErgoptiNav_Injection value; lower-integrity events are always fail-open.
 * Scan codes use AHK's compressed extended form, with the extended bit stored
 * as 0x100.
 */
typedef struct ErgoptiNav_TestEvent {
	uint16_t vk;
	uint16_t sc;
	uint8_t modifiers;
	uint8_t kind;
	uint8_t injected;
	uint8_t reserved;
	uint64_t extra_info;
} ErgoptiNav_TestEvent;

/**
 * Reports the observable decision made for a test-dispatched event.
 *
 * Layout: disposition@0:u8, receipt_created@1:u8, route_index@2:u8,
 * reserved@3:u8, receipt_sequence@4:u64.
 */
typedef struct ErgoptiNav_DispatchResult {
	uint8_t disposition;
	uint8_t receipt_created;
	uint8_t route_index;
	uint8_t reserved;
	uint64_t receipt_sequence;
} ErgoptiNav_DispatchResult;

#pragma pack(pop)

#if defined(__cplusplus)
#define ERGOPTI_NAV_STATIC_ASSERT static_assert
#else
#define ERGOPTI_NAV_STATIC_ASSERT _Static_assert
#endif

ERGOPTI_NAV_STATIC_ASSERT(sizeof(void *) == 8, "The navigation owner ABI is x64-only.");
ERGOPTI_NAV_STATIC_ASSERT(sizeof(ErgoptiNav_Binding) == 12, "Binding ABI size changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, axis) == 0, "Binding axis offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, action) == 1, "Binding action offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, modifiers) == 2, "Binding modifiers offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, pass_through) == 3, "Binding pass offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, code) == 4, "Binding code offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, delta) == 6, "Binding delta offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, target) == 7, "Binding target offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, input_level) == 8, "Binding input-level offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Binding, reserved) == 9, "Binding reserved offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(sizeof(ErgoptiNav_Owner) == 24, "Owner ABI size changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, token) == 0, "Owner token offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, epoch) == 8, "Owner epoch offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, slot_count) == 16, "Owner slot-count offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, active_index) == 17, "Owner active-index offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, require_index_match) == 18, "Owner index-match offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Owner, reserved) == 19, "Owner reserved offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(sizeof(ErgoptiNav_Receipt) == 40, "Receipt ABI size changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, sequence) == 0, "Receipt sequence offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, owner_token) == 8, "Receipt token offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, owner_epoch) == 16, "Receipt epoch offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, plan_generation) == 24, "Receipt plan offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, route_index) == 32, "Receipt route offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, action) == 33, "Receipt action offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, delta) == 34, "Receipt delta offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, from_index) == 35, "Receipt source offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, target_index) == 36, "Receipt target offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_Receipt, pass_through) == 37, "Receipt pass offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(sizeof(ErgoptiNav_TestEvent) == 16, "Test event ABI size changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_TestEvent, extra_info) == 8, "Test event marker offset changed.");
ERGOPTI_NAV_STATIC_ASSERT(sizeof(ErgoptiNav_DispatchResult) == 12, "Dispatch result ABI size changed.");
ERGOPTI_NAV_STATIC_ASSERT(offsetof(ErgoptiNav_DispatchResult, receipt_sequence) == 4, "Dispatch sequence offset changed.");

#undef ERGOPTI_NAV_STATIC_ASSERT





// =====================================
// =====================================
// ======= 3/ Lifecycle and Plans =======
// =====================================
// =====================================

/**
 * Starts the dedicated message-loop thread and installs WH_KEYBOARD_LL.
 *
 * @param wake_window Destination HWND encoded as an unsigned x64 pointer.
 * @param wake_message Message posted whenever a new receipt is queued.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_Start(
	uint64_t wake_window,
	uint32_t wake_message);

/**
 * Stops admissions, unhooks, joins the hook thread, and clears native state.
 * The loaded module must remain resident for the process lifetime: its InitOnce
 * lock is deliberately reused by later Start calls, and a quarantined timeout
 * may still own code and handles until a later successful Stop.
 *
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_Stop(void);

/**
 * Validates and stages exactly twelve normalized routes.
 *
 * @param bindings Pointer to twelve packed ErgoptiNav_Binding records.
 * @param binding_count Number of records, which must equal twelve.
 * @param out_generation Receives the nonzero generation of the staged plan.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PreparePlan(
	const ErgoptiNav_Binding *bindings,
	uint32_t binding_count,
	uint64_t *out_generation);

/**
 * Atomically replaces the active plan with a previously prepared generation.
 *
 * @param generation Generation returned by ErgoptiNav_PreparePlan.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CommitPlan(
	uint64_t generation);

/**
 * Enables or suspends new navigation decisions without releasing the hook.
 *
 * Existing consumed key holds still suppress their balancing key-up while
 * suspended. Every new decision is fail-open.
 *
 * @param suspended One to suspend or zero to resume.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_SetSuspended(
	uint8_t suspended);





// ==================================
// ==================================
// ======= 4/ Owner Publication =======
// ==================================
// ==================================

/**
 * Fences new decisions and stages the next tooltip owner.
 *
 * Pending receipts for the expected owner do not block the swap because they
 * retain that owner's token independently. New decisions pass while fenced.
 *
 * @param expected_token Token which must identify the current owner.
 * @param next_owner Owner to publish, or the all-zero owner to clear it.
 * @param out_ticket Receives the nonzero swap ticket.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_BeginOwnerSwap(
	uint64_t expected_token,
	const ErgoptiNav_Owner *next_owner,
	uint64_t *out_ticket);

/**
 * Publishes the staged owner and releases the transition fence.
 *
 * @param ticket Ticket returned by ErgoptiNav_BeginOwnerSwap.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CommitOwnerSwap(
	uint64_t ticket);

/**
 * Discards the staged owner and releases the transition fence.
 *
 * @param ticket Ticket returned by ErgoptiNav_BeginOwnerSwap.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_AbortOwnerSwap(
	uint64_t ticket);

/**
 * Atomically claims one exact tooltip index for acceptance and clears its owner.
 *
 * A successful call linearizes Tab acceptance against navigation: all later
 * key-downs pass because the active owner is empty. Receipts and held key-ups
 * created before the claim remain independently completable.
 *
 * @param owner_token Exact current owner token.
 * @param expected_index Immutable one-based index selected for acceptance.
 * @return OK on claim, BUSY during a swap, or OWNER_MISMATCH when navigation or
 * another owner transition won first.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_ClaimOwner(
	uint64_t owner_token,
	uint8_t expected_index);

/**
 * Copies the current native owner snapshot.
 *
 * The function fills the old active owner and returns BUSY while an owner swap
 * is fenced, allowing callers to distinguish stable and transitional reads.
 *
 * @param out_owner Receives the packed owner snapshot.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_GetOwner(
	ErgoptiNav_Owner *out_owner);





// ==================================
// ==================================
// ======= 5/ Receipt Lifecycle =======
// ==================================
// ==================================

/**
 * Claims the oldest queued receipt exactly once.
 *
 * @param out_receipt Receives the immutable claimed receipt.
 * @return OK when claimed or NOT_FOUND when no queued receipt remains.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PollReceipt(
	ErgoptiNav_Receipt *out_receipt);

/**
 * Completes one claimed receipt after validating its exact token and target.
 *
 * A mismatch leaves the receipt pending so the AHK record cannot retire.
 *
 * @param sequence Claimed receipt sequence.
 * @param owner_token Claimed receipt owner token.
 * @param applied_index One-based index painted by AutoHotkey.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_CompleteReceipt(
	uint64_t sequence,
	uint64_t owner_token,
	uint8_t applied_index);

/**
 * Counts queued and claimed receipts retaining an exact owner token.
 *
 * @param owner_token Nonzero owner token to inspect.
 * @param out_pending Receives the number of pending receipts.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_PendingForToken(
	uint64_t owner_token,
	uint32_t *out_pending);





// ===================================
// ===================================
// ======= 6/ Diagnostics and Test =======
// ===================================
// ===================================

/**
 * Returns the latest Win32 error retained by a lifecycle operation.
 *
 * @return A Win32 error code, or zero when none is retained.
 */
ERGOPTI_NAV_API uint32_t ERGOPTI_NAV_CALL ErgoptiNav_GetLastOsError(void);

/**
 * Dispatches an event through the exact production state machine without a hook.
 *
 * This seam performs the same plan match, injection arbitration, owner commit,
 * receipt reservation, hold latch, and disposition calculation as the live hook.
 * It intentionally does not post the configured wake message.
 *
 * @param event Packed deterministic event supplied by the native test or AHK.
 * @param out_result Receives the state-machine decision.
 * @return An ErgoptiNav_Status value.
 */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestDispatch(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result);

#if defined(ERGOPTI_NAV_TESTING)
/** Applies one provenance-free startup modifier through the production helper. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestSeedInitialModifier(
	uint16_t vk,
	uint16_t sc);

/**
 * Converts a raw hook-shaped test event through the production modifier
 * tracker before dispatching it. This symbol exists only in the hook-free test
 * executable and is never part of the DLL export surface.
 */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestHookDispatch(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result);

/**
 * Drives one raw hook event through production conversion, dispatch and final
 * delivery while replacing SendInput/CallNextHookEx with deterministic sinks.
 * This proves menu camouflage ordering without installing a hook or injecting
 * any real keyboard input. mask_should_fail deterministically models a blocked
 * SendInput call. The three byte outputs are always initialized.
 */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestHookFlow(
	const ErgoptiNav_TestEvent *event,
	ErgoptiNav_DispatchResult *out_result,
	uint8_t mask_should_fail,
	uint8_t *out_mask_emitted,
	uint8_t *out_pass_called,
	uint8_t *out_mask_before_pass);

/** Arms the same drain latch used by Stop without creating a hook thread. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestBeginDrain(void);

/** Reports whether every suppress hold and menu disguise obligation drained. */
int32_t ERGOPTI_NAV_CALL ErgoptiNav_TestDrainComplete(
	uint8_t *out_complete);
#endif

#if defined(__cplusplus)
}
#endif

#endif
