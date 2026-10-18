// static/ergopti_plus/windows/native/nav_event_owner/hook_trace.h
/**
 * @file hook_trace.h
 * @brief Explicit opt-in bounded hook diagnostics without source classification.
 *
 * The native owner serializes these calls under its lock. This module performs
 * no OS hook, QPC query, injection, FIFO ACK or physical/native qualification.
 * A caller may publish raw hook observations only after an explicit isolated
 * diagnostic start. Disabled by default; stopping preserves readable evidence.
 */
#ifndef ERGOPTI_HOOK_TRACE_H
#define ERGOPTI_HOOK_TRACE_H
#include <stddef.h>
#include <stdint.h>

#define ERGOPTI_TRACE_CAPACITY 256u
#define ERGOPTI_TRACE_STATE_INIT {0}

enum ErgoptiTrace_Status {
	ERGOPTI_TRACE_OK = 0,
	ERGOPTI_TRACE_OVERFLOW = 1,
	ERGOPTI_TRACE_DISABLED = 2,
	ERGOPTI_TRACE_INVALID = -1,
	ERGOPTI_TRACE_NOT_INITIALIZED = -2,
	ERGOPTI_TRACE_ALREADY_INITIALIZED = -3,
	ERGOPTI_TRACE_WRONG_OWNER = -4,
	ERGOPTI_TRACE_WRONG_SESSION = -5,
	ERGOPTI_TRACE_STALE_GENERATION = -6,
	ERGOPTI_TRACE_BUSY = -7,
	ERGOPTI_TRACE_CAPACITY_ERROR = -8
};

/** Caller-reported decisions are diagnostic labels, never inferred provenance. */
enum ErgoptiTrace_Decision {
	ERGOPTI_TRACE_PASS = 1,
	ERGOPTI_TRACE_CAPTURE = 2,
	ERGOPTI_TRACE_NAV_SUPPRESS = 3,
	ERGOPTI_TRACE_INJECTED_PASS = 4,
	ERGOPTI_TRACE_REPLAY_PASS = 5,
	ERGOPTI_TRACE_UNKNOWN = 6
};

/** Raw integers retain all bits; the caller queries QPC and supplies hook data. */
typedef struct ErgoptiTrace_Event {
	uint64_t qpc;
	uint64_t extra_info;
	uint64_t capture_sequence;
	uint32_t vk;
	uint32_t scan;
	uint32_t flags;
	uint32_t time;
	uint32_t message;
	uint32_t decision;
	uint64_t reserved;
} ErgoptiTrace_Event;

typedef struct ErgoptiTrace_Entry {
	uint64_t sequence;
	ErgoptiTrace_Event event;
} ErgoptiTrace_Entry;

/** Overflow/drop prevents complete-evidence status, even after stopping. */
typedef struct ErgoptiTrace_Receipt {
	uint64_t owner;
	uint64_t token;
	uint64_t generation;
	uint64_t attempted;
	uint64_t dropped;
	uint64_t first_sequence;
	uint64_t last_sequence;
	uint32_t capacity;
	uint32_t stored;
	uint32_t page_offset;
	uint32_t page_count;
	uint32_t enabled;
	uint32_t overflow;
} ErgoptiTrace_Receipt;

/** Single serialized owner; copying live state does not transfer ownership. */
typedef struct ErgoptiTrace_State {
	uint64_t owner;
	uint64_t token;
	uint64_t generation;
	uint64_t next_sequence;
	uint64_t attempted;
	uint64_t dropped;
	uint32_t count;
	uint8_t initialized;
	uint8_t enabled;
	uint8_t overflow;
	ErgoptiTrace_Entry entries[ERGOPTI_TRACE_CAPACITY];
} ErgoptiTrace_State;

_Static_assert(sizeof(ErgoptiTrace_Event) == 56, "Trace event ABI changed.");
_Static_assert(sizeof(ErgoptiTrace_Entry) == 64, "Trace entry ABI changed.");
_Static_assert(offsetof(ErgoptiTrace_Entry, event) == 8, "Trace QPC offset changed.");
_Static_assert(offsetof(ErgoptiTrace_Event, reserved) == 48, "Trace reserved offset changed.");
_Static_assert(sizeof(ErgoptiTrace_Receipt) == 80, "Trace receipt ABI changed.");
_Static_assert(offsetof(ErgoptiTrace_Receipt, attempted) == 24, "Trace attempted offset changed.");
_Static_assert(offsetof(ErgoptiTrace_Receipt, capacity) == 56, "Trace capacity offset changed.");
_Static_assert(offsetof(ErgoptiTrace_Receipt, overflow) == 76, "Trace overflow offset changed.");

int32_t ErgoptiTrace_Initialize(ErgoptiTrace_State *state, uint64_t owner);

/** Starts a fresh session; generation strictly increases, active start refuses. */
int32_t ErgoptiTrace_Start(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation);

/** Freezes evidence; returns OVERFLOW if any dropped observation remains. */
int32_t ErgoptiTrace_Stop(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation);

/**
 * Appends without overwriting. Full capacity or exhausted counters latch overflow
 * and record saturating attempted/drop counts. Wrong identity, disabled state or
 * malformed inputs never change the session. Reserved input must be zero.
 */
int32_t ErgoptiTrace_Push(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation,
	const ErgoptiTrace_Event *event);

/** Latches missing evidence without retaining any foreign hook payload. */
int32_t ErgoptiTrace_RecordDrop(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation);

/**
 * Read-only exact page, including after Stop; offset/count are not cursors.
 * Count zero permits a NULL entry buffer for receipt-only inspection. An
 * overflowed session copies its diagnostic page but returns OVERFLOW forever;
 * callers must reject it as complete evidence. No native qualification follows
 * from OK. Rejected calls leave state and output storage unchanged.
 */
int32_t ErgoptiTrace_Page(
	const ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation,
	uint32_t offset, uint32_t count, ErgoptiTrace_Entry *entries,
	uint32_t capacity, ErgoptiTrace_Receipt *receipt);
#endif
