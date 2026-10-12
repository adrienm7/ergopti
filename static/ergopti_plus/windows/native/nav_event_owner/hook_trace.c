// static/ergopti_plus/windows/native/nav_event_owner/hook_trace.c
/** @file hook_trace.c @brief Disabled-default bounded hook evidence storage. */
#include "hook_trace.h"
#include <string.h>

static int32_t Owner(const ErgoptiTrace_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0) return ERGOPTI_TRACE_INVALID;
	if (!state->initialized) return ERGOPTI_TRACE_NOT_INITIALIZED;
	return state->owner == owner ? ERGOPTI_TRACE_OK : ERGOPTI_TRACE_WRONG_OWNER;
}
static int32_t Session(
	const ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation)
{
	int32_t status = Owner(state, owner);
	if (status != 0) return status;
	if (token == 0 || generation == 0) return ERGOPTI_TRACE_INVALID;
	return state->token == token && state->generation == generation
		? ERGOPTI_TRACE_OK : ERGOPTI_TRACE_WRONG_SESSION;
}
static int Overlap(const void *a, size_t a_size, const void *b, size_t b_size)
{
	uintptr_t a_address = (uintptr_t)a, b_address = (uintptr_t)b;
	if (a_size == 0 || b_size == 0) return 0;
	return a_address <= b_address ? b_address - a_address < a_size
		: a_address - b_address < b_size;
}
static void CountAttempt(ErgoptiTrace_State *state)
{
	if (state->attempted != UINT64_MAX) ++state->attempted;
	if (state->next_sequence != UINT64_MAX) ++state->next_sequence;
}
static int32_t Drop(ErgoptiTrace_State *state)
{
	CountAttempt(state);
	if (state->dropped != UINT64_MAX) ++state->dropped;
	state->overflow = 1;
	return ERGOPTI_TRACE_OVERFLOW;
}
int32_t ErgoptiTrace_Initialize(ErgoptiTrace_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0) return ERGOPTI_TRACE_INVALID;
	if (state->initialized) return ERGOPTI_TRACE_ALREADY_INITIALIZED;
	if (state->owner != 0 || state->token != 0 || state->generation != 0
			|| state->next_sequence != 0 || state->enabled) return ERGOPTI_TRACE_INVALID;
	memset(state, 0, sizeof(*state)); state->owner = owner; state->initialized = 1;
	return ERGOPTI_TRACE_OK;
}
int32_t ErgoptiTrace_Start(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation)
{
	int32_t status = Owner(state, owner);
	if (status != 0) return status;
	if (token == 0 || generation == 0) return ERGOPTI_TRACE_INVALID;
	if (state->enabled) return ERGOPTI_TRACE_BUSY;
	if (generation <= state->generation) return ERGOPTI_TRACE_STALE_GENERATION;
	state->token = token; state->generation = generation;
	state->count = 0; state->attempted = 0; state->dropped = 0;
	state->overflow = 0; state->enabled = 1;
	memset(state->entries, 0, sizeof(state->entries));
	return ERGOPTI_TRACE_OK;
}
int32_t ErgoptiTrace_Stop(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation)
{
	int32_t status = Session(state, owner, token, generation);
	if (status != 0) return status;
	if (!state->enabled) return ERGOPTI_TRACE_DISABLED;
	state->enabled = 0;
	return state->overflow ? ERGOPTI_TRACE_OVERFLOW : ERGOPTI_TRACE_OK;
}
int32_t ErgoptiTrace_RecordDrop(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation)
{
	int32_t status = Session(state, owner, token, generation);
	if (status != 0) return status;
	if (!state->enabled) return ERGOPTI_TRACE_DISABLED;
	return Drop(state);
}
int32_t ErgoptiTrace_Push(
	ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation,
	const ErgoptiTrace_Event *event)
{
	int32_t status = Session(state, owner, token, generation);
	ErgoptiTrace_Event frozen;
	if (status != 0) return status;
	if (!state->enabled) return ERGOPTI_TRACE_DISABLED;
	if (event == NULL || event->reserved != 0 || event->decision < ERGOPTI_TRACE_PASS
			|| event->decision > ERGOPTI_TRACE_UNKNOWN) return ERGOPTI_TRACE_INVALID;
	frozen = *event;
	if (state->count == ERGOPTI_TRACE_CAPACITY || state->next_sequence == UINT64_MAX
			|| state->attempted == UINT64_MAX) return Drop(state);
	CountAttempt(state);
	state->entries[state->count].sequence = state->next_sequence;
	state->entries[state->count].event = frozen;
	++state->count;
	return state->overflow ? ERGOPTI_TRACE_OVERFLOW : ERGOPTI_TRACE_OK;
}
int32_t ErgoptiTrace_Page(
	const ErgoptiTrace_State *state, uint64_t owner, uint64_t token, uint64_t generation,
	uint32_t offset, uint32_t count, ErgoptiTrace_Entry *entries,
	uint32_t capacity, ErgoptiTrace_Receipt *receipt)
{
	int32_t status = Session(state, owner, token, generation);
	ErgoptiTrace_Receipt result = {0};
	if (status != 0) return status;
	if (receipt == NULL || offset > state->count || count > state->count - offset
			|| count > ERGOPTI_TRACE_CAPACITY || capacity > ERGOPTI_TRACE_CAPACITY
			|| (count != 0 && entries == NULL)) return ERGOPTI_TRACE_INVALID;
	if (capacity < count) return ERGOPTI_TRACE_CAPACITY_ERROR;
	if (Overlap(receipt, sizeof(*receipt), state, sizeof(*state))
			|| Overlap(entries, count * sizeof(*entries), state, sizeof(*state))
			|| Overlap(entries, count * sizeof(*entries), receipt, sizeof(*receipt)))
		return ERGOPTI_TRACE_INVALID;
	result.owner = state->owner; result.token = state->token; result.generation = state->generation;
	result.attempted = state->attempted; result.dropped = state->dropped;
	result.first_sequence = state->count ? state->entries[0].sequence : 0;
	result.last_sequence = state->count ? state->entries[state->count - 1].sequence : 0;
	result.capacity = ERGOPTI_TRACE_CAPACITY; result.stored = state->count;
	result.page_offset = offset; result.page_count = count;
	result.enabled = state->enabled; result.overflow = state->overflow;
	if (count) memcpy(entries, state->entries + offset, count * sizeof(*entries));
	*receipt = result;
	return state->overflow ? ERGOPTI_TRACE_OVERFLOW : ERGOPTI_TRACE_OK;
}
