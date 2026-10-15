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

/* One marker owner shared by raw replay and retained output serialization. */
#define ERGOPTI_NAV_TERMINAL_REPLAY_MARKER 0x4552475054524D31ull

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
 * PrepareNativeEdge only when their source-owned effective bit changes. A
 * repeated or crossed-source modifier edge with no effective transition plans
 * zero units and still requires original-edge consumption. Remapped modifiers,
 * prefix/dead/uncertain metadata are diagnostic only. Direct-digit source
 * metadata stays diagnostic even with cohort_complete: its native host mapping
 * and accepted-effect owner are not implemented. It never enters the KLE
 * Unicode branch. This API never computes or guesses the canonical string.
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
 * Fixed x64/ARM64 Win32 INPUT representation, never a pointer into retained custody.
 * Reserved bytes cover alignment and the unused MOUSEINPUT union tail. The
 * Windows receiving build must additionally pin this against its SDK INPUT.
 */
typedef struct ErgoptiOutput_Win32Input {
	uint32_t type;
	uint32_t reserved0;
	uint16_t vk;
	uint16_t scan;
	uint32_t flags;
	uint32_t time;
	uint32_t reserved1;
	uint64_t extra_info;
	uint64_t reserved2;
} ErgoptiOutput_Win32Input;

_Static_assert(sizeof(ErgoptiOutput_Win32Input) == 40, "Win32 INPUT size changed.");
_Static_assert(offsetof(ErgoptiOutput_Win32Input, vk) == 8, "Win32 VK offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Win32Input, scan) == 10, "Win32 scan offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Win32Input, flags) == 12, "Win32 flags offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Win32Input, time) == 16, "Win32 time offset changed.");
_Static_assert(offsetof(ErgoptiOutput_Win32Input, extra_info) == 24, "Win32 marker offset changed.");

/**
 * Serializes an existing immutable attempt without starting, sending, accepting
 * or retiring it. Exactly one retained unit maps to one x64/ARM64 INPUT packet, so an
 * eventual exact native accepted-prefix count can use Acknowledge unchanged.
 * A suffix may begin with a stranded Unicode UP or low surrogate; never compose
 * or discard it. No repeat expansion, surrogate aggregation or extra edges occur.
 * Uses the existing native owner replay marker; callers cannot supply a foreign
 * marker or send-level admission grant. Only x64/ARM64 pointer layouts qualify
 * for construction; other host architectures refuse. This helper never emits.
 * Capacity is at most MAX_UNITS. Refusal changes neither outputs nor state;
 * outputs must not alias custody, the key, or each other. Concurrent access must
 * be serialized by the same native owner that protects Plan/Begin/Acknowledge.
 */
int32_t ErgoptiOutput_SerializeAttempt(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt_id, ErgoptiOutput_Win32Input *packets,
	uint32_t capacity, uint32_t *count);

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
