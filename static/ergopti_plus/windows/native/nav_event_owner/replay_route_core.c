// static/ergopti_plus/windows/native/nav_event_owner/replay_route_core.c
/**
 * @file replay_route_core.c
 * @brief Authoritative supplied-route matching with immutable event-time recipes.
 */

#include "replay_route_core.h"

#include <stdbool.h>
#include <string.h>

/** Checks lifecycle ownership before any mutation or recipe consumption. */
static int32_t CheckOwner(const ErgoptiReplay_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0)
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (!state->initialized)
		return ERGOPTI_REPLAY_NOT_INITIALIZED;
	if (state->owner != owner)
		return ERGOPTI_REPLAY_OWNER_MISMATCH;
	return ERGOPTI_REPLAY_OK;
}

/** Refuses writable spans that wrap or overlap protected input/lifecycle storage. */
static bool WritableOverlaps(
	const void *output, size_t output_size, const void *protected, size_t protected_size)
{
	uintptr_t output_start;
	uintptr_t protected_start;
	if (output == NULL)
		return false;
	output_start = (uintptr_t)output;
	if (output_size > UINTPTR_MAX - output_start)
		return true;
	if (protected == NULL)
		return false;
	protected_start = (uintptr_t)protected;
	if (protected_size > UINTPTR_MAX - protected_start)
		return true;
	return output_start < protected_start + protected_size
		&& protected_start < output_start + output_size;
}

/** Only one-bit prefix identities may enter the shared held-prefix mask. */
static bool IsOneBit(uint32_t value)
{
	return value != 0 && (value & (value - 1u)) == 0;
}

/** Rejects incomplete, conflicting and unverifiable recipe declarations. */
static bool RouteValid(const ErgoptiReplay_Route *route)
{
	if (route->recipe_id == 0 || route->route_id == 0 || route->code == 0
			|| route->kind < ERGOPTI_REPLAY_CHARACTER
			|| route->kind > ERGOPTI_REPLAY_DIRECT_DIGIT
			|| route->required_modifiers > 0x0Fu
			|| route->target_vk > 0xFFu || route->target_scan > 0x1FFu
			|| (route->target_vk != 0 && route->target_scan != 0))
		return false;
	if (route->axis == ERGOPTI_REPLAY_VK) {
		if (route->code > 0xFFu)
			return false;
	} else if (route->axis == ERGOPTI_REPLAY_SCAN) {
		if (route->code > 0x1FFu)
			return false;
	} else {
		return false;
	}
	if (route->kind == ERGOPTI_REPLAY_DIRECT_DIGIT) {
		/* The producer supplies literal intent later; registration cannot guess
		 * a host target or borrow KLE's Unicode-digit interpretation. */
		return route->axis == ERGOPTI_REPLAY_SCAN
			&& route->code >= 0x02u && route->code <= 0x0Bu
			&& route->target_vk == 0 && route->target_scan == 0
			&& route->required_modifiers == 0 && route->required_prefixes == 0
			&& route->prefix_bit == 0 && route->effective_modifiers_lr == 0
			&& route->required_dead_key_id == 0 && route->next_dead_key_id == 0;
	}
	if (route->kind == ERGOPTI_REPLAY_MODIFIER
			|| route->kind == ERGOPTI_REPLAY_PREFIX) {
		if (route->required_modifiers != 0 || route->required_prefixes != 0
				|| route->required_dead_key_id != 0 || route->next_dead_key_id != 0)
			return false;
		if (route->kind == ERGOPTI_REPLAY_MODIFIER)
			return route->effective_modifiers_lr != 0 && route->prefix_bit == 0;
		return route->effective_modifiers_lr == 0 && IsOneBit(route->prefix_bit);
	}
	if (route->effective_modifiers_lr != 0 || route->prefix_bit != 0)
		return false;
	if (route->kind == ERGOPTI_REPLAY_DEAD_KEY)
		return route->required_dead_key_id != 0 || route->next_dead_key_id != 0;
	return true;
}

/** A modifier/prefix identity owns its entire key family, at every chord. */
static bool IsHoldTransform(const ErgoptiReplay_Route *route)
{
	return route->kind == ERGOPTI_REPLAY_MODIFIER
		|| route->kind == ERGOPTI_REPLAY_PREFIX;
}

/** One full registration set must have an unambiguous event-time selector. */
static bool RoutesConflict(
	const ErgoptiReplay_Route *left, const ErgoptiReplay_Route *right)
{
	if (left->route_id == right->route_id)
		return true;
	if (left->axis != right->axis || left->code != right->code)
		return false;
	return IsHoldTransform(left) || IsHoldTransform(right)
		|| (left->required_modifiers == right->required_modifiers
			&& left->required_prefixes == right->required_prefixes
			&& left->required_dead_key_id == right->required_dead_key_id);
}

int32_t ErgoptiReplay_Initialize(ErgoptiReplay_State *state, uint64_t owner)
{
	if (state == NULL || owner == 0)
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (state->initialized)
		return ERGOPTI_REPLAY_ALREADY_INITIALIZED;
	if (state->owner != 0 || state->generation != 0 || state->route_count != 0)
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	memset(state, 0, sizeof(*state));
	state->owner = owner;
	state->initialized = 1;
	return ERGOPTI_REPLAY_OK;
}

int32_t ErgoptiReplay_Register(
	ErgoptiReplay_State *state, uint64_t owner, uint64_t generation,
	uint64_t layout_id, const ErgoptiReplay_Route *routes, uint32_t count)
{
	ErgoptiReplay_Route candidate[ERGOPTI_REPLAY_MAX_ROUTES];
	uint32_t index;
	uint32_t previous;
	int32_t status = CheckOwner(state, owner);
	if (status != ERGOPTI_REPLAY_OK)
		return status;
	if (generation == 0 || layout_id == 0 || count > ERGOPTI_REPLAY_MAX_ROUTES
			|| (count != 0 && routes == NULL))
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (generation <= state->generation)
		return ERGOPTI_REPLAY_STALE_REGISTRATION;
	/* Copy first so a caller-owned or overlapping input cannot mutate validation. */
	memset(candidate, 0, sizeof(candidate));
	if (count != 0)
		memcpy(candidate, routes, sizeof(*routes) * count);
	for (index = 0; index < count; ++index) {
		if (!RouteValid(&candidate[index]))
			return ERGOPTI_REPLAY_INVALID_REGISTRATION;
		for (previous = 0; previous < index; ++previous) {
			if (RoutesConflict(&candidate[previous], &candidate[index]))
				return ERGOPTI_REPLAY_INVALID_REGISTRATION;
		}
	}
	memcpy(state->routes, candidate, sizeof(candidate));
	state->route_count = count;
	state->generation = generation;
	state->layout_id = layout_id;
	return ERGOPTI_REPLAY_OK;
}

/** Union source-owned effective transforms rather than borrowing async key state. */
static void EffectiveState(
	const ErgoptiReplay_State *state, uint8_t *modifiers, uint32_t *prefixes)
{
	uint32_t index;
	*modifiers = 0;
	*prefixes = 0;
	for (index = 0; index < ERGOPTI_REPLAY_MAX_HELD_KEYS; ++index) {
		const ErgoptiReplay_Hold *hold = &state->holds[index];
		if (!hold->active || hold->status != ERGOPTI_REPLAY_OK)
			continue;
		*modifiers |= hold->route.effective_modifiers_lr;
		*prefixes |= hold->route.prefix_bit;
	}
}

/** Generic route matching deliberately collapses left/right only at this edge. */
static uint8_t GenericModifiers(uint8_t modifiers)
{
	uint8_t generic = 0;
	if ((modifiers & 0x03u) != 0)
		generic |= ERGOPTI_REPLAY_CONTROL;
	if ((modifiers & 0x0Cu) != 0)
		generic |= ERGOPTI_REPLAY_ALT;
	if ((modifiers & 0x30u) != 0)
		generic |= ERGOPTI_REPLAY_SHIFT;
	if ((modifiers & 0xC0u) != 0)
		generic |= ERGOPTI_REPLAY_WIN;
	return generic;
}

/** Scan ownership forbids a missing scan chord from falling back to VK text. */
static const ErgoptiReplay_Route *SelectRoute(
	const ErgoptiReplay_State *state, const ErgoptiReplay_Event *event,
	uint8_t modifiers, uint32_t prefixes)
{
	uint32_t index;
	uint8_t axis = ERGOPTI_REPLAY_VK;
	uint16_t code = event->vk;
	for (index = 0; index < state->route_count; ++index) {
		if (state->routes[index].axis == ERGOPTI_REPLAY_SCAN
				&& state->routes[index].code == event->scan) {
			axis = ERGOPTI_REPLAY_SCAN;
			code = event->scan;
			break;
		}
	}
	for (index = 0; index < state->route_count; ++index) {
		const ErgoptiReplay_Route *route = &state->routes[index];
		if (route->axis != axis || route->code != code)
			continue;
		if (IsHoldTransform(route)
				|| (route->required_modifiers == GenericModifiers(modifiers)
					&& route->required_prefixes == prefixes
					&& route->required_dead_key_id == state->composition.dead_key_id))
			return route;
	}
	return NULL;
}

/** Layout changes may alter VK, so physical scan identity wins when present. */
static bool SameKey(const ErgoptiReplay_Hold *hold, const ErgoptiReplay_Event *event)
{
	if (!hold->active || hold->origin != event->origin
			|| hold->source_id != event->source_id)
		return false;
	if (hold->scan != 0 || event->scan != 0)
		return hold->scan != 0 && hold->scan == event->scan;
	return hold->vk == event->vk;
}

/** Every return exposes its exact outcome instead of a zeroed success receipt. */
static int32_t Result(ErgoptiReplay_Snapshot *snapshot, int32_t status)
{
	if (snapshot != NULL)
		snapshot->status = status;
	return status;
}

int32_t ErgoptiReplay_Step(
	ErgoptiReplay_State *state, uint64_t owner,
	const ErgoptiReplay_Event *event, ErgoptiReplay_Snapshot *snapshot)
{
	uint32_t index;
	ErgoptiReplay_Event incoming;
	ErgoptiReplay_Hold *held = NULL;
	ErgoptiReplay_Hold *free_hold = NULL;
	const ErgoptiReplay_Route *route;
	int32_t status;
	/* Refuse before even a refusal result could overwrite lifecycle storage. */
	if (WritableOverlaps(snapshot, sizeof(*snapshot), state, sizeof(*state)))
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	/* A caller may reuse snapshot.event as the next input buffer. Freeze that
	 * edge before clearing the output, so a valid up cannot become an orphan. */
	if (event != NULL) {
		incoming = *event;
		event = &incoming;
	}
	if (snapshot != NULL)
		memset(snapshot, 0, sizeof(*snapshot));
	status = CheckOwner(state, owner);
	if (status != ERGOPTI_REPLAY_OK)
		return Result(snapshot, status);
	if (event == NULL || snapshot == NULL)
		return Result(snapshot, ERGOPTI_REPLAY_INVALID_ARGUMENT);
	if (event->vk > 0xFFu || event->scan > 0x1FFu
			|| (event->vk == 0 && event->scan == 0)
			|| event->key_up > 1 || event->repeat > 1
			|| (event->key_up && event->repeat)
			|| event->origin < ERGOPTI_REPLAY_PHYSICAL
			|| event->origin > ERGOPTI_REPLAY_LOWER_INTEGRITY)
		return Result(snapshot, ERGOPTI_REPLAY_INVALID_EVENT);
	snapshot->owner = owner;
	snapshot->event = *event;
	snapshot->observed_generation = state->generation;
	snapshot->observed_layout_id = state->layout_id;
	snapshot->composition_before = state->composition;
	snapshot->composition_after = state->composition;
	EffectiveState(state, &snapshot->modifiers_lr_before, &snapshot->prefixes_before);
	snapshot->modifiers_lr_after = snapshot->modifiers_lr_before;
	snapshot->prefixes_after = snapshot->prefixes_before;
	if (state->has_timestamp && event->timestamp < state->last_timestamp)
		return Result(snapshot, ERGOPTI_REPLAY_STALE_EVENT);
	if (event->origin == ERGOPTI_REPLAY_EXTERNAL_INJECTION
			|| event->origin == ERGOPTI_REPLAY_LOWER_INTEGRITY)
		return Result(snapshot, ERGOPTI_REPLAY_UNSUPPORTED);
	for (index = 0; index < ERGOPTI_REPLAY_MAX_HELD_KEYS; ++index) {
		if (SameKey(&state->holds[index], event))
			held = &state->holds[index];
		if (!state->holds[index].active && free_hold == NULL)
			free_hold = &state->holds[index];
	}
	if (event->key_up || event->repeat) {
		if (held == NULL)
			return Result(snapshot, ERGOPTI_REPLAY_ORPHAN_EDGE);
		/* An immutable edge recipe is insufficient for an unregistered repeated
		 * composition transition. Leave it to the captured KLE model adapter. */
		if (event->repeat && held->status == ERGOPTI_REPLAY_OK
				&& !IsHoldTransform(&held->route)
				&& held->route.required_dead_key_id != state->composition.dead_key_id)
			return Result(snapshot, ERGOPTI_REPLAY_UNSUPPORTED);
		snapshot->route = held->route;
		snapshot->route_generation = held->generation;
		snapshot->route_layout_id = held->layout_id;
		status = held->status;
		if (event->key_up)
			memset(held, 0, sizeof(*held));
	} else {
		if (held != NULL)
			return Result(snapshot, ERGOPTI_REPLAY_INVALID_EVENT);
		if (free_hold == NULL)
			return Result(snapshot, ERGOPTI_REPLAY_CAPACITY);
		route = SelectRoute(state, event,
			snapshot->modifiers_lr_before, snapshot->prefixes_before);
		if (route != NULL && !IsHoldTransform(route)
				&& state->composition.dead_key_id != 0
				&& state->composition.layout_id != state->layout_id)
			return Result(snapshot, ERGOPTI_REPLAY_UNSUPPORTED);
		status = route != NULL ? ERGOPTI_REPLAY_OK : ERGOPTI_REPLAY_UNREGISTERED;
		memset(free_hold, 0, sizeof(*free_hold));
		free_hold->active = 1;
		free_hold->origin = event->origin;
		free_hold->source_id = event->source_id;
		free_hold->vk = event->vk;
		free_hold->scan = event->scan;
		free_hold->generation = state->generation;
		free_hold->layout_id = state->layout_id;
		free_hold->status = status;
		if (route != NULL) {
			free_hold->route = *route;
			if (!IsHoldTransform(route)) {
				memset(&state->composition, 0, sizeof(state->composition));
				if (route->next_dead_key_id != 0) {
					state->composition.dead_key_id = route->next_dead_key_id;
					state->composition.generation = state->generation;
					state->composition.layout_id = state->layout_id;
				}
			}
		}
		snapshot->route = free_hold->route;
		snapshot->route_generation = free_hold->generation;
		snapshot->route_layout_id = free_hold->layout_id;
	}
	state->last_timestamp = event->timestamp;
	state->has_timestamp = 1;
	EffectiveState(state, &snapshot->modifiers_lr_after, &snapshot->prefixes_after);
	snapshot->composition_after = state->composition;
	return Result(snapshot, status);
}

int32_t ErgoptiReplay_PrepareNativeEdge(
	const ErgoptiReplay_State *state, uint64_t owner,
	const ErgoptiReplay_Snapshot *snapshot, ErgoptiReplay_NativeKeyEdge *edge)
{
	int32_t status;
	/* The output cannot destroy either lifecycle storage or its captured recipe. */
	if (WritableOverlaps(edge, sizeof(*edge), state, sizeof(*state))
			|| WritableOverlaps(edge, sizeof(*edge), snapshot, sizeof(*snapshot)))
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (edge != NULL)
		memset(edge, 0, sizeof(*edge));
	status = CheckOwner(state, owner);
	if (status != ERGOPTI_REPLAY_OK)
		return status;
	if (snapshot == NULL || edge == NULL)
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (snapshot->owner != owner)
		return ERGOPTI_REPLAY_OWNER_MISMATCH;
	if (snapshot->status == ERGOPTI_REPLAY_UNREGISTERED
			|| snapshot->status == ERGOPTI_REPLAY_UNSUPPORTED)
		return snapshot->status;
	if (snapshot->status != ERGOPTI_REPLAY_OK || !RouteValid(&snapshot->route)
			|| snapshot->route_generation == 0 || snapshot->route_layout_id == 0
			|| snapshot->route_generation > state->generation
			|| snapshot->event.key_up > 1 || snapshot->event.repeat > 1
			|| (snapshot->event.key_up && snapshot->event.repeat)
			|| (snapshot->event.origin != ERGOPTI_REPLAY_PHYSICAL
				&& snapshot->event.origin != ERGOPTI_REPLAY_OWNED_REPLAY))
		return ERGOPTI_REPLAY_INVALID_ARGUMENT;
	if (snapshot->route.target_vk == 0 && snapshot->route.target_scan == 0)
		return ERGOPTI_REPLAY_UNSUPPORTED;
	edge->vk = snapshot->route.target_vk;
	edge->scan = snapshot->route.target_scan;
	edge->key_up = snapshot->event.key_up;
	edge->repeat = snapshot->event.repeat;
	return ERGOPTI_REPLAY_OK;
}
