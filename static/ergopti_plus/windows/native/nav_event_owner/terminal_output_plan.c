// static/ergopti_plus/windows/native/nav_event_owner/terminal_output_plan.c
/** @file terminal_output_plan.c @brief Guarded immutable plans and prefix ACKs. */
#include "terminal_output_plan.h"
#include <string.h>

static int32_t CheckOwner(const ErgoptiOutput_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0) return ERGOPTI_OUTPUT_INVALID;
	if (!state->initialized) return ERGOPTI_OUTPUT_NOT_INITIALIZED;
	return state->owner == owner ? ERGOPTI_OUTPUT_OK : ERGOPTI_OUTPUT_WRONG_OWNER;
}
static int32_t CheckKey(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key)
{
	int32_t status = CheckOwner(state, owner);
	if (status != 0) return status;
	if (key == NULL) return ERGOPTI_OUTPUT_INVALID;
	if (!state->active || key->token != state->key.token
			|| key->sequence != state->key.sequence || key->plan_id != state->key.plan_id)
		return ERGOPTI_OUTPUT_STALE;
	return ERGOPTI_OUTPUT_OK;
}
static int ValidUtf16(const uint16_t *text, uint32_t length)
{
	for (uint32_t i = 0; i < length; ++i) {
		if (text[i] >= 0xD800 && text[i] <= 0xDBFF) {
			if (++i == length || text[i] < 0xDC00 || text[i] > 0xDFFF) return 0;
		} else if (text[i] >= 0xDC00 && text[i] <= 0xDFFF) return 0;
	}
	return 1;
}
static uint8_t GenericModifiers(uint8_t lr)
{
	return (uint8_t)(((lr & 3) ? 1 : 0) | ((lr & 12) ? 2 : 0)
		| ((lr & 48) ? 4 : 0) | ((lr & 192) ? 8 : 0));
}
static int InputValid(
	const ErgoptiReplay_State *routes, uint64_t owner, const ErgoptiReplay_Snapshot *s)
{
	return routes != NULL && routes->initialized && routes->owner == owner
		&& s->observed_generation != 0 && s->observed_generation <= routes->generation
		&& s->observed_layout_id != 0 && s->event.source_id != 0
		&& s->event.vk <= 255 && s->event.scan <= 511
		&& (s->event.vk != 0 || s->event.scan != 0)
		&& s->event.key_up <= 1 && s->event.repeat <= 1
		&& !(s->event.key_up && s->event.repeat)
		&& (s->event.origin == ERGOPTI_REPLAY_PHYSICAL
			|| s->event.origin == ERGOPTI_REPLAY_OWNED_REPLAY);
}
static int AbsentRecipe(const ErgoptiReplay_State *routes, const ErgoptiReplay_Snapshot *s)
{
	return (s->status == ERGOPTI_REPLAY_UNREGISTERED || s->status == ERGOPTI_REPLAY_UNSUPPORTED)
		&& ((s->route_generation == 0 && s->route_layout_id == 0)
			|| (s->route_generation != 0 && s->route_layout_id != 0
				&& s->route_generation <= s->observed_generation
				&& s->route_generation <= routes->generation))
		&& s->route.recipe_id == 0 && s->route.route_id == 0 && s->route.code == 0
		&& s->route.target_vk == 0 && s->route.target_scan == 0 && s->route.axis == 0
		&& s->route.kind == 0 && s->route.required_modifiers == 0
		&& s->route.effective_modifiers_lr == 0 && s->route.required_prefixes == 0
		&& s->route.prefix_bit == 0 && s->route.required_dead_key_id == 0
		&& s->route.next_dead_key_id == 0;
}
static int SnapshotValid(
	const ErgoptiReplay_State *routes, uint64_t owner, const ErgoptiReplay_Snapshot *s)
{
	if (routes == NULL || !routes->initialized || routes->owner != owner
			|| s->observed_generation == 0 || s->observed_layout_id == 0
			|| s->route_generation == 0 || s->route_layout_id == 0
			|| s->route_generation > s->observed_generation
			|| s->route_generation > routes->generation
			|| s->event.source_id == 0 || s->event.vk > 255 || s->event.scan > 511
			|| (s->event.vk == 0 && s->event.scan == 0)
			|| s->event.key_up > 1 || s->event.repeat > 1
			|| (s->event.key_up && s->event.repeat)
			|| (s->event.origin != ERGOPTI_REPLAY_PHYSICAL
				&& s->event.origin != ERGOPTI_REPLAY_OWNED_REPLAY)
			|| s->route.recipe_id == 0 || s->route.route_id == 0
			|| s->route.kind < 1 || s->route.kind > 5
			|| s->route.required_modifiers > 15
			|| s->route.target_vk > 255 || s->route.target_scan > 511
			|| (s->route.target_vk && s->route.target_scan))
		return 0;
	if (s->route.axis == ERGOPTI_REPLAY_SCAN)
		return s->route.code != 0 && s->route.code <= 511 && s->route.code == s->event.scan;
	if (s->route.axis == ERGOPTI_REPLAY_VK)
		return s->route.code != 0 && s->route.code <= 255 && s->route.code == s->event.vk;
	return 0;
}
static int Neutral(const ErgoptiReplay_Snapshot *s)
{
	return s->prefixes_before == 0 && s->prefixes_after == 0
		&& s->route.required_prefixes == 0 && s->route.prefix_bit == 0
		&& s->route.required_dead_key_id == 0 && s->route.next_dead_key_id == 0
		&& s->composition_before.dead_key_id == 0 && s->composition_after.dead_key_id == 0;
}
static int NaturalModifier(const ErgoptiReplay_Snapshot *s)
{
	static const struct { uint16_t vk, scan; uint8_t lr; } natural[] = {
		{0xA2,0x01D,0x01}, {0xA3,0x11D,0x02}, {0xA4,0x038,0x04},
		{0xA5,0x138,0x08}, {0xA0,0x02A,0x10}, {0xA1,0x036,0x20},
		{0x5B,0x15B,0x40}, {0x5C,0x15C,0x80}
	};
	for (uint32_t i = 0; i < sizeof(natural) / sizeof(natural[0]); ++i) {
		if (s->route.effective_modifiers_lr != natural[i].lr) continue;
		if (s->route.axis == ERGOPTI_REPLAY_SCAN && s->route.code == natural[i].scan
				&& s->route.target_scan == natural[i].scan && s->route.target_vk == 0) return 1;
		if (s->route.axis == ERGOPTI_REPLAY_VK && s->route.code == natural[i].vk
				&& s->route.target_vk == natural[i].vk && s->route.target_scan == 0) return 1;
	}
	return 0;
}
int32_t ErgoptiOutput_Initialize(ErgoptiOutput_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0) return ERGOPTI_OUTPUT_INVALID;
	if (state->initialized) return ERGOPTI_OUTPUT_ALREADY_INITIALIZED;
	if (state->owner != 0 || state->active || state->next_plan_id != 0
			|| state->last_sequence != 0) return ERGOPTI_OUTPUT_INVALID;
	memset(state, 0, sizeof(*state)); state->owner = owner; state->initialized = 1;
	return ERGOPTI_OUTPUT_OK;
}
int32_t ErgoptiOutput_Plan(
	ErgoptiOutput_State *state, uint64_t owner, uint64_t token, uint64_t sequence,
	const ErgoptiReplay_State *routes, const ErgoptiReplay_Snapshot *snapshot,
	const uint16_t *text, uint32_t length, uint8_t cohort_complete, ErgoptiOutput_Key *key)
{
	int32_t status = CheckOwner(state, owner);
	ErgoptiReplay_Snapshot frozen;
	ErgoptiOutput_Unit units[ERGOPTI_OUTPUT_MAX_UNITS] = {{0}};
	uint32_t count = 0; uint8_t eligible = 0;
	if (status != 0) return status;
	if (state->active) return ERGOPTI_OUTPUT_BUSY;
	if (length > ERGOPTI_OUTPUT_MAX_UTF16) return ERGOPTI_OUTPUT_CAPACITY;
	if (snapshot == NULL || key == NULL || token == 0 || sequence == 0
			|| cohort_complete > 1 || (length && text == NULL)) return ERGOPTI_OUTPUT_INVALID;
	if (sequence <= state->last_sequence || state->next_plan_id == UINT64_MAX)
		return ERGOPTI_OUTPUT_STALE;
	/* Custody compares the complete ABI representation, including padding. */
	memcpy(&frozen, snapshot, sizeof(frozen));
	if (frozen.owner != owner) return ERGOPTI_OUTPUT_WRONG_OWNER;
	if (!InputValid(routes, owner, &frozen)
			|| (!SnapshotValid(routes, owner, &frozen) && !AbsentRecipe(routes, &frozen))
			|| (frozen.status != ERGOPTI_REPLAY_OK
				&& frozen.status != ERGOPTI_REPLAY_UNREGISTERED
				&& frozen.status != ERGOPTI_REPLAY_UNSUPPORTED)
			|| !ValidUtf16(text, length))
		return ERGOPTI_OUTPUT_INVALID;
	if (frozen.status == ERGOPTI_REPLAY_OK && Neutral(&frozen)) {
		if ((frozen.route.kind == ERGOPTI_REPLAY_CHARACTER
				|| frozen.route.kind == ERGOPTI_REPLAY_DIGIT)
				&& frozen.route.effective_modifiers_lr == 0
				&& (frozen.event.key_up || frozen.route.required_modifiers
					== GenericModifiers(frozen.modifiers_lr_before))
				&& frozen.modifiers_lr_before == frozen.modifiers_lr_after) {
			if (frozen.event.key_up && length != 0) return ERGOPTI_OUTPUT_INVALID;
			eligible = 1;
			if (!frozen.event.key_up) {
				for (uint32_t i = 0; i < length; ++i) {
					units[count].kind = ERGOPTI_OUTPUT_UNICODE;
					units[count++].utf16 = text[i];
					units[count].kind = ERGOPTI_OUTPUT_UNICODE;
					units[count].key_up = 1;
					units[count++].utf16 = text[i];
				}
			}
		} else if (frozen.route.kind == ERGOPTI_REPLAY_MODIFIER && NaturalModifier(&frozen)) {
			ErgoptiReplay_NativeKeyEdge edge;
			if (length != 0) return ERGOPTI_OUTPUT_INVALID;
			if (ErgoptiReplay_PrepareNativeEdge(routes, owner, &frozen, &edge) == 0) {
				eligible = 1;
				/* Source-owned holds are unioned by the routing core. Releasing
				 * one source cannot clear a modifier retained by another, and a
				 * repeated/redundant DOWN has no effective transition to emit. */
				if (((frozen.modifiers_lr_before ^ frozen.modifiers_lr_after)
						& frozen.route.effective_modifiers_lr) != 0) {
					count = 1;
					units[0].kind = ERGOPTI_OUTPUT_NATIVE_EDGE;
					units[0].vk = edge.vk; units[0].scan = edge.scan;
					units[0].key_up = edge.key_up; units[0].repeat = edge.repeat;
				}
			}
		}
	}
	state->key.token = token; state->key.sequence = sequence;
	state->key.plan_id = ++state->next_plan_id; state->last_sequence = sequence;
	memcpy(&state->snapshot, &frozen, sizeof(state->snapshot)); state->count = count; state->accepted = 0;
	state->attempting = 0; state->attempt_count = 0; state->attempt_id = 0;
	state->active = 1; state->dispatchable = (uint8_t)(eligible && cohort_complete);
	memcpy(state->units, units, count * sizeof(units[0])); *key = state->key;
	return state->dispatchable ? ERGOPTI_OUTPUT_OK : ERGOPTI_OUTPUT_DIAGNOSTIC;
}
int32_t ErgoptiOutput_Inspect(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiOutput_Unit *units, uint32_t capacity, uint32_t *count, uint32_t *dispatchable)
{
	int32_t status = CheckKey(state, owner, key);
	if (status != 0) return status;
	if (count == NULL || dispatchable == NULL || (units == NULL && capacity != 0))
		return ERGOPTI_OUTPUT_INVALID;
	*count = state->count; *dispatchable = state->dispatchable;
	if (units == NULL) return ERGOPTI_OUTPUT_OK;
	if (capacity < state->count) return ERGOPTI_OUTPUT_CAPACITY;
	memcpy(units, state->units, state->count * sizeof(units[0]));
	return ERGOPTI_OUTPUT_OK;
}
int32_t ErgoptiOutput_BeginAttempt(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiOutput_Unit *units, uint32_t capacity, uint32_t *count, uint64_t *attempt_id)
{
	int32_t status = CheckKey(state, owner, key); uint32_t remaining;
	if (status != 0) return status;
	if (!state->dispatchable) return ERGOPTI_OUTPUT_DIAGNOSTIC;
	if (state->attempting) return ERGOPTI_OUTPUT_BUSY;
	if (count == NULL || attempt_id == NULL || units == NULL) return ERGOPTI_OUTPUT_INVALID;
	remaining = state->count - state->accepted;
	if (remaining == 0) return ERGOPTI_OUTPUT_DEBT;
	if (capacity < remaining) return ERGOPTI_OUTPUT_CAPACITY;
	if (state->next_attempt_id == UINT64_MAX) return ERGOPTI_OUTPUT_STALE;
	memcpy(units, state->units + state->accepted, remaining * sizeof(units[0]));
	state->attempting = 1; state->attempt_count = remaining;
	state->attempt_id = ++state->next_attempt_id;
	*count = remaining; *attempt_id = state->attempt_id;
	return ERGOPTI_OUTPUT_OK;
}
/** Data layout only: selecting a native send backend remains a separate task. */
static int OutputWin32LayoutSupported(void)
{
#if (defined(_M_X64) || defined(_M_ARM64) || defined(__x86_64__) \
		|| defined(__aarch64__)) && UINTPTR_MAX == UINT64_MAX \
		&& !defined(__AARCH64EB__) \
		&& (!defined(__BYTE_ORDER__) || __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
	return 1;
#else
	return 0;
#endif
}

/** Reject writable aliases before any caller output or custody is touched. */
static int OutputRangesOverlap(const void *a, size_t an, const void *b, size_t bn)
{
	uintptr_t ap = (uintptr_t)a, bp = (uintptr_t)b;
	if (an > UINTPTR_MAX - ap || bn > UINTPTR_MAX - bp) return 1;
	return ap < bp + bn && bp < ap + an;
}

/** Validates units independently of byte construction to make refusal atomic. */
static int OutputWin32UnitValid(const ErgoptiOutput_Unit *unit)
{
	if (unit->reserved != 0 || unit->key_up > 1 || unit->repeat > 1
			|| (unit->key_up && unit->repeat)) return 0;
	if (unit->kind == ERGOPTI_OUTPUT_UNICODE)
		return unit->vk == 0 && unit->scan == 0;
	if (unit->kind != ERGOPTI_OUTPUT_NATIVE_EDGE || unit->utf16 != 0
			|| unit->vk > 255 || unit->scan > 511 || (unit->vk && unit->scan)) return 0;
	return unit->vk != 0 || (unit->scan & 0xFFu) != 0;
}

int32_t ErgoptiOutput_SerializeAttempt(
	const ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt_id, ErgoptiOutput_Win32Input *packets,
	uint32_t capacity, uint32_t *count)
{
	int32_t status = CheckKey(state, owner, key);
	size_t bytes;
	if (status != 0) return status;
	if (!state->dispatchable) return ERGOPTI_OUTPUT_DIAGNOSTIC;
	if (!state->attempting || attempt_id == 0 || attempt_id != state->attempt_id)
		return ERGOPTI_OUTPUT_STALE;
	if (!OutputWin32LayoutSupported() || packets == NULL || count == NULL
			|| capacity > ERGOPTI_OUTPUT_MAX_UNITS) return ERGOPTI_OUTPUT_INVALID;
	if (state->count > ERGOPTI_OUTPUT_MAX_UNITS || state->accepted >= state->count
			|| state->attempt_count != state->count - state->accepted)
		return ERGOPTI_OUTPUT_INVALID;
	if (capacity < state->attempt_count) return ERGOPTI_OUTPUT_CAPACITY;
	bytes = state->attempt_count * sizeof(packets[0]);
	if (OutputRangesOverlap(packets, bytes, state, sizeof(*state))
			|| OutputRangesOverlap(packets, bytes, key, sizeof(*key))
			|| OutputRangesOverlap(packets, bytes, count, sizeof(*count))
			|| OutputRangesOverlap(count, sizeof(*count), state, sizeof(*state))
			|| OutputRangesOverlap(count, sizeof(*count), key, sizeof(*key)))
		return ERGOPTI_OUTPUT_INVALID;
	for (uint32_t i = 0; i < state->attempt_count; ++i)
		if (!OutputWin32UnitValid(&state->units[state->accepted + i]))
			return ERGOPTI_OUTPUT_INVALID;
	for (uint32_t i = 0; i < state->attempt_count; ++i) {
		const ErgoptiOutput_Unit *unit = &state->units[state->accepted + i];
		ErgoptiOutput_Win32Input packet = {0};
		packet.type = 1; /* INPUT_KEYBOARD. */
		packet.extra_info = ERGOPTI_NAV_TERMINAL_REPLAY_MARKER;
		packet.flags = unit->key_up ? 2u : 0u; /* KEYEVENTF_KEYUP. */
		if (unit->kind == ERGOPTI_OUTPUT_UNICODE) {
			packet.scan = unit->utf16;
			packet.flags |= 4u; /* KEYEVENTF_UNICODE; literal UTF-16 code unit. */
		} else if (unit->scan != 0) {
			packet.scan = unit->scan & 0xFFu;
			packet.flags |= 8u | ((unit->scan & 0x100u) ? 1u : 0u);
		} else packet.vk = unit->vk;
		memcpy(&packets[i], &packet, sizeof(packet));
	}
	*count = state->attempt_count;
	return ERGOPTI_OUTPUT_OK;
}

int32_t ErgoptiOutput_Acknowledge(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	uint64_t attempt_id, uint32_t accepted)
{
	int32_t status = CheckKey(state, owner, key);
	if (status != 0) return status;
	if (!state->dispatchable) return ERGOPTI_OUTPUT_DIAGNOSTIC;
	if (!state->attempting || attempt_id != state->attempt_id) return ERGOPTI_OUTPUT_STALE;
	if (accepted > state->attempt_count) return ERGOPTI_OUTPUT_INVALID;
	state->accepted += accepted; state->attempting = 0; state->attempt_count = 0;
	return ERGOPTI_OUTPUT_OK;
}
int32_t ErgoptiOutput_Consume(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key,
	ErgoptiReplay_Event *original_edge)
{
	int32_t status = CheckKey(state, owner, key);
	if (status != 0) return status;
	if (!state->dispatchable) return ERGOPTI_OUTPUT_DIAGNOSTIC;
	if (original_edge == NULL) return ERGOPTI_OUTPUT_INVALID;
	if (state->attempting || state->accepted != state->count) return ERGOPTI_OUTPUT_DEBT;
	memcpy(original_edge, &state->snapshot.event, sizeof(*original_edge)); state->active = 0;
	return ERGOPTI_OUTPUT_OK;
}
int32_t ErgoptiOutput_Cancel(
	ErgoptiOutput_State *state, uint64_t owner, const ErgoptiOutput_Key *key)
{
	int32_t status = CheckKey(state, owner, key);
	if (status != 0) return status;
	if (state->attempting || state->accepted != 0) return ERGOPTI_OUTPUT_DEBT;
	state->active = 0; return ERGOPTI_OUTPUT_OK;
}
