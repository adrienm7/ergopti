// static/ergopti_plus/windows/native/nav_event_owner/terminal_output_plan.h
/**
 * @file terminal_output_plan.h
 * @brief Portable, guarded output planning and exact accepted-prefix accounting.
 *
 * No hook, FIFO, OS call or text composition is owned here. The caller supplies
 * immutable event metadata and canonical UTF-16 from the retained KLE recipe.
 * Production cohort completeness must remain false until all observers and
 * handlers are converted; diagnostic plans never authorize dispatch/consumption.
 */
#ifndef ERGOPTI_TERMINAL_OUTPUT_PLAN_H
#define ERGOPTI_TERMINAL_OUTPUT_PLAN_H

#include "replay_route_core.h"

#define ERGOPTI_OUTPUT_MAX_UTF16 1024u
#define ERGOPTI_OUTPUT_MAX_UNITS (ERGOPTI_OUTPUT_MAX_UTF16 * 2u)
#define ERGOPTI_OUTPUT_STATE_INIT {0}

enum ErgoptiOutput_Status {
	ERGOPTI_OUTPUT_OK = 0,
	ERGOPTI_OUTPUT_DIAGNOSTIC = 1,
	ERGOPTI_OUTPUT_INVALID = -1,
	ERGOPTI_OUTPUT_NOT_INITIALIZED = -2,
	ERGOPTI_OUTPUT_ALREADY_INITIALIZED = -3,
	ERGOPTI_OUTPUT_WRONG_OWNER = -4,
	ERGOPTI_OUTPUT_BUSY = -5,
	ERGOPTI_OUTPUT_STALE = -6,
	ERGOPTI_OUTPUT_CAPACITY = -7,
	ERGOPTI_OUTPUT_DEBT = -8
};

enum ErgoptiOutput_Kind {
	ERGOPTI_OUTPUT_UNICODE = 1,
	ERGOPTI_OUTPUT_NATIVE_EDGE = 2
};

/** Unicode units map literally to KEYEVENTF_UNICODE, adding KEYUP on release. */
typedef struct ErgoptiOutput_Unit {
	uint16_t vk;
	uint16_t scan;
	uint16_t utf16;
	uint8_t kind;
	uint8_t key_up;
	uint8_t repeat;
	uint8_t reserved;
} ErgoptiOutput_Unit;

/** An obsolete plan cannot acknowledge a later event with the same queue token. */
typedef struct ErgoptiOutput_Key {
	uint64_t token;
	uint64_t sequence;
	uint64_t plan_id;
} ErgoptiOutput_Key;

/** Single serialized owner; copying live storage does not transfer ownership. */
typedef struct ErgoptiOutput_State {
	uint64_t owner;
	uint64_t last_sequence;
	uint64_t next_plan_id;
	uint64_t next_attempt_id;
	uint64_t attempt_id;
	uint32_t count;
	uint32_t accepted;
	uint32_t attempt_count;
	uint8_t initialized;
	uint8_t active;
	uint8_t dispatchable;
	uint8_t attempting;
	ErgoptiOutput_Key key;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiOutput_Unit units[ERGOPTI_OUTPUT_MAX_UNITS];
} ErgoptiOutput_State;

int32_t ErgoptiOutput_Initialize(ErgoptiOutput_State *state, uint64_t owner);

/**
 * Copies canonical UTF-16 and the snapshot transactionally. Sequence is the
 * native FIFO's globally increasing sequence, never an array index. A consumed
 * or cancelled sequence cannot be reused. Empty text and literal U+0000 are
 * valid; unpaired surrogates are rejected. Character UP plans zero units and
 * still requires explicit original-edge consumption. Natural modifiers use
 * PrepareNativeEdge; remapped modifiers/prefix/dead/uncertain metadata are
 * diagnostic only. This API never computes or guesses the canonical string.
 */
int32_t ErgoptiOutput_Plan(
	ErgoptiOutput_State *state, uint64_t owner, uint64_t token, uint64_t sequence,
	const ErgoptiReplay_State *routes, const ErgoptiReplay_Snapshot *snapshot,
	const uint16_t *text, uint32_t length, uint8_t cohort_complete,
	ErgoptiOutput_Key *key);

/**
 * Nonmutating diagnostic copy, also available for cohort-incomplete plans.
 * A NULL units pointer with capacity zero queries count only. Copies all units,
 * including already accepted prefixes; dispatchable never becomes true here.
 */
int32_t ErgoptiOutput_Inspect(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiOutput_Unit *units, uint32_t capacity, uint32_t *count,
	uint32_t *dispatchable);

_Static_assert(sizeof(ErgoptiOutput_Unit) == 10, "Output unit ABI changed.");
_Static_assert(offsetof(ErgoptiOutput_Unit, utf16) == 4, "Output UTF16 offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Unit, kind) == 6, "Output kind offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Unit, key_up) == 7, "Output edge offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Unit, repeat) == 8, "Output repeat offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Unit, reserved) == 9, "Output reserved offset changed.");

/** Copies the exact immutable remaining suffix before a caller's OS attempt. */
int32_t ErgoptiOutput_BeginAttempt(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiOutput_Unit *units, uint32_t capacity, uint32_t *count,
	uint64_t *attempt_id);

/**
 * Commits only an exact accepted prefix. Zero acceptance closes the attempt
 * while retaining all debt. An invalid count/identity leaves the attempt intact.
 * Retrying copies only the remaining suffix, including a stranded Unicode UP.
 */
int32_t ErgoptiOutput_Acknowledge(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt_id, uint32_t accepted);

/** After every unit ACK, grants consumption of exactly this original edge. */
int32_t ErgoptiOutput_Consume(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiReplay_Event *original_edge);

/** No abandonment is allowed once any unit was accepted or while attempting. */
int32_t ErgoptiOutput_Cancel(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key);

#endif
