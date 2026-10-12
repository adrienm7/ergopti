// static/ergopti_plus/windows/native/nav_event_owner/replay_route_core_test.c
/**
 * @file replay_route_core_test.c
 * @brief Independent vectors for event-time replay registration and provenance.
 *
 * These literal vectors were defined before the implementation. Expected masks,
 * recipes and transitions do not come from production matching helpers. No
 * Windows hook, keyboard, glyph composition or native execution is simulated.
 */

#include "replay_route_core.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define OWNER 700u
#define LAYOUT 81u

/** Authoritative representative KLE subset, including an effective Ctrl-to-Alt. */
static const ErgoptiReplay_Route ROUTES[] = {
	{ .recipe_id = 1001, .route_id = 1, .code = 0xA2, .axis = ERGOPTI_REPLAY_VK,
		.kind = ERGOPTI_REPLAY_MODIFIER, .target_vk = 0xA4,
		.effective_modifiers_lr = 0x04 },
	{ .recipe_id = 1002, .route_id = 2, .code = 0xA4, .axis = ERGOPTI_REPLAY_VK,
		.kind = ERGOPTI_REPLAY_MODIFIER, .target_vk = 0xA4,
		.effective_modifiers_lr = 0x04 },
	{ .recipe_id = 1003, .route_id = 3, .code = 0x2A, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_MODIFIER, .target_scan = 0x2A,
		.effective_modifiers_lr = 0x10 },
	{ .recipe_id = 1004, .route_id = 4, .code = 0x138, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_PREFIX, .target_scan = 0x138, .prefix_bit = 1 },
	{ .recipe_id = 100, .route_id = 5, .code = 0x1E, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_CHARACTER, .target_scan = 0x30 },
	{ .recipe_id = 101, .route_id = 6, .code = 0x1E, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_CHARACTER, .target_scan = 0x2E,
		.required_modifiers = 4 },
	{ .recipe_id = 200, .route_id = 7, .code = 0x02, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_DIGIT, .target_scan = 0x03,
		.required_modifiers = 2 },
	{ .recipe_id = 102, .route_id = 8, .code = 0x1E, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_CHARACTER, .target_scan = 0x20,
		.required_prefixes = 1 },
	{ .recipe_id = 300, .route_id = 9, .code = 0x29, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_DEAD_KEY, .target_scan = 0x1A, .next_dead_key_id = 7 },
	{ .recipe_id = 301, .route_id = 10, .code = 0x1E, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_CHARACTER, .target_scan = 0x30,
		.required_dead_key_id = 7 },
	{ .recipe_id = 302, .route_id = 11, .code = 0x29, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_DEAD_KEY, .target_scan = 0x1A,
		.required_dead_key_id = 7 },
	{ .recipe_id = 400, .route_id = 12, .code = 0x40, .axis = ERGOPTI_REPLAY_SCAN,
		.kind = ERGOPTI_REPLAY_CHARACTER },
	{ .recipe_id = 1005, .route_id = 13, .code = 0xA1, .axis = ERGOPTI_REPLAY_VK,
		.kind = ERGOPTI_REPLAY_MODIFIER, .target_vk = 0xA1,
		.effective_modifiers_lr = 0x20 }
};

#define ROUTE_COUNT ((uint32_t)(sizeof(ROUTES) / sizeof(ROUTES[0])))

/** Initializes independent state for each invariant. */
static void Start(ErgoptiReplay_State *state)
{
	memset(state, 0, sizeof(*state));
	assert(ErgoptiReplay_Initialize(state, OWNER) == ERGOPTI_REPLAY_OK);
	assert(ErgoptiReplay_Register(state, OWNER, 1, LAYOUT, ROUTES, ROUTE_COUNT)
		== ERGOPTI_REPLAY_OK);
}

/** Carries literal expected event-time state, independent of the matcher. */
typedef struct Vector {
	uint16_t vk;
	uint16_t scan;
	uint8_t origin;
	uint8_t up;
	uint8_t repeat;
	uint64_t source;
	int32_t status;
	uint8_t before;
	uint8_t after;
	uint32_t prefixes_before;
	uint32_t prefixes_after;
	uint64_t recipe;
} Vector;

/** Proves remaps, crossed sources, repeat holds and prefixes from fixed vectors. */
static void TestEventVectors(void)
{
	const Vector vectors[] = {
		{0xA2, 0x1D, 1, 0, 0, 0, 0, 0x00, 0x04, 0, 0, 1001},
		{0x31, 0x02, 1, 0, 0, 0, 0, 0x04, 0x04, 0, 0, 200},
		{0x31, 0x02, 1, 0, 1, 0, 0, 0x04, 0x04, 0, 0, 200},
		{0xA2, 0x1D, 2, 0, 0, 0, 0, 0x04, 0x04, 0, 0, 1001},
		{0xA2, 0x1D, 1, 1, 0, 0, 0, 0x04, 0x04, 0, 0, 1001},
		{0xA2, 0x1D, 2, 1, 0, 0, 0, 0x04, 0x00, 0, 0, 1001},
		{0x31, 0x02, 1, 1, 0, 0, 0, 0x00, 0x00, 0, 0, 200},
		{0xA0, 0x2A, 1, 0, 0, 0, 0, 0x00, 0x10, 0, 0, 1003},
		{0x41, 0x1E, 1, 0, 0, 0, 0, 0x10, 0x10, 0, 0, 101},
		{0x41, 0x1E, 1, 1, 0, 0, 0, 0x10, 0x10, 0, 0, 101},
		{0xA0, 0x2A, 1, 1, 0, 0, 0, 0x10, 0x00, 0, 0, 1003},
		{0xA5, 0x138, 1, 0, 0, 0, 0, 0x00, 0x00, 0, 1, 1004},
		{0x41, 0x1E, 1, 0, 0, 0, 0, 0x00, 0x00, 1, 1, 102},
		{0xA5, 0x138, 1, 1, 0, 0, 0, 0x00, 0x00, 1, 0, 1004},
		{0x41, 0x1E, 1, 1, 0, 0, 0, 0x00, 0x00, 0, 0, 102},
		{0x41, 0x1E, 2, 0, 0, 9, 0, 0x00, 0x00, 0, 0, 100},
		{0x41, 0x1E, 2, 1, 0, 9, 0, 0x00, 0x00, 0, 0, 100},
		{0xA0, 0x2A, 1, 0, 0, 0, 0, 0x00, 0x10, 0, 0, 1003},
		{0xA1, 0x36, 2, 0, 0, 9, 0, 0x10, 0x30, 0, 0, 1005},
		{0xA0, 0x2A, 1, 1, 0, 0, 0, 0x30, 0x20, 0, 0, 1003},
		{0x41, 0x1E, 1, 0, 0, 0, 0, 0x20, 0x20, 0, 0, 101},
		{0x41, 0x1E, 1, 1, 0, 0, 0, 0x20, 0x20, 0, 0, 101},
		{0xA1, 0x36, 2, 1, 0, 9, 0, 0x20, 0x00, 0, 0, 1005},
		{0xA5, 0x138, 1, 0, 0, 0, 0, 0x00, 0x00, 0, 1, 1004},
		{0xA5, 0x138, 2, 0, 0, 9, 0, 0x00, 0x00, 1, 1, 1004},
		{0xA5, 0x138, 1, 1, 0, 0, 0, 0x00, 0x00, 1, 1, 1004},
		{0x41, 0x1E, 1, 0, 0, 0, 0, 0x00, 0x00, 1, 1, 102},
		{0x41, 0x1E, 1, 1, 0, 0, 0, 0x00, 0x00, 1, 1, 102},
		{0xA5, 0x138, 2, 1, 0, 9, 0, 0x00, 0x00, 1, 0, 1004}
	};
	const ErgoptiReplay_NativeKeyEdge native_edges[] = {
		{0xA4, 0, 0, 0}, {0, 0x03, 0, 0}, {0, 0x03, 0, 1},
		{0xA4, 0, 0, 0}, {0xA4, 0, 1, 0}, {0xA4, 0, 1, 0},
		{0, 0x03, 1, 0}, {0, 0x2A, 0, 0}, {0, 0x2E, 0, 0},
		{0, 0x2E, 1, 0}, {0, 0x2A, 1, 0}, {0, 0x138, 0, 0},
		{0, 0x20, 0, 0}, {0, 0x138, 1, 0}, {0, 0x20, 1, 0},
		{0, 0x30, 0, 0}, {0, 0x30, 1, 0},
		{0, 0x2A, 0, 0}, {0xA1, 0, 0, 0}, {0, 0x2A, 1, 0},
		{0, 0x2E, 0, 0}, {0, 0x2E, 1, 0}, {0xA1, 0, 1, 0},
		{0, 0x138, 0, 0}, {0, 0x138, 0, 0}, {0, 0x138, 1, 0},
		{0, 0x20, 0, 0}, {0, 0x20, 1, 0}, {0, 0x138, 1, 0}
	};
	ErgoptiReplay_State state;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_NativeKeyEdge edge;
	uint32_t index;
	_Static_assert(sizeof(vectors) / sizeof(vectors[0])
		== sizeof(native_edges) / sizeof(native_edges[0]), "Every event needs a native-edge oracle.");
	Start(&state);
	for (index = 0; index < sizeof(vectors) / sizeof(vectors[0]); ++index) {
		const Vector *vector = &vectors[index];
		ErgoptiReplay_Event event = { .timestamp = index + 1, .vk = vector->vk,
			.scan = vector->scan, .origin = vector->origin, .key_up = vector->up,
			.repeat = vector->repeat, .source_id = vector->source };
		assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == vector->status);
		assert(snapshot.event.timestamp == index + 1);
		assert(snapshot.modifiers_lr_before == vector->before);
		assert(snapshot.modifiers_lr_after == vector->after);
		assert(snapshot.prefixes_before == vector->prefixes_before);
		assert(snapshot.prefixes_after == vector->prefixes_after);
		assert(snapshot.route.recipe_id == vector->recipe);
		assert(snapshot.route_generation == 1 && snapshot.route_layout_id == LAYOUT);
		assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &snapshot, &edge) == 0);
		assert(edge.key_up == vector->up && edge.repeat == vector->repeat);
		assert(edge.vk == native_edges[index].vk && edge.scan == native_edges[index].scan);
	}
	puts("PASS replay-route event vectors: effective transforms, sources, repeats and prefixes.");
}

/** Queue snapshots and held ups retain old immutable route/layout identities. */
static void TestRegistrationSwap(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_Snapshot down;
	ErgoptiReplay_Snapshot repeat;
	ErgoptiReplay_Snapshot up;
	ErgoptiReplay_NativeKeyEdge edge;
	ErgoptiReplay_Route replacement = ROUTES[4];
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 1, .vk = 0x41, .scan = 0x1E };
	Start(&state);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &down) == 0);
	replacement.recipe_id = 900;
	replacement.target_scan = 0x2D;
	assert(ErgoptiReplay_Register(&state, OWNER, 2, 82, &replacement, 1) == 0);
	event.timestamp = 2;
	event.repeat = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &repeat) == 0);
	assert(repeat.observed_generation == 2 && repeat.observed_layout_id == 82);
	assert(repeat.route_generation == 1 && repeat.route_layout_id == 81);
	assert(repeat.route.recipe_id == 100 && repeat.route.target_scan == 0x30);
	event.timestamp = 3;
	event.repeat = 0;
	event.key_up = 1;
	event.vk = 0x42;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &up) == 0);
	assert(up.route_generation == 1 && up.route_layout_id == 81);
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &down, &edge) == 0);
	assert(edge.scan == 0x30 && edge.key_up == 0);
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &up, &edge) == 0);
	assert(edge.scan == 0x30 && edge.key_up == 1);
	event.timestamp = 4;
	event.key_up = 0;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &down) == 0);
	assert(down.route.recipe_id == 900 && down.route_generation == 2);
	assert(ErgoptiReplay_Register(&state, OWNER, 3, 82, NULL, 0) == 0);
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &down, &edge) == 0);
	assert(edge.scan == 0x2D);
	puts("PASS replay-route registration swap: queued and held recipes remain immutable.");
}

/** Supplied composition identities survive edges and refuse layout guesses. */
static void TestComposition(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_State before;
	ErgoptiReplay_Snapshot dead;
	ErgoptiReplay_Snapshot character;
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 1, .vk = 0xC0, .scan = 0x29 };
	Start(&state);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &dead) == 0);
	assert(dead.composition_before.dead_key_id == 0);
	assert(dead.composition_after.dead_key_id == 7);
	assert(dead.composition_after.generation == 1 && dead.composition_after.layout_id == 81);
	event.timestamp = 2;
	event.repeat = 1;
	before = state;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &character) == ERGOPTI_REPLAY_UNSUPPORTED);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	event.repeat = 0;
	event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &character) == 0);
	assert(character.composition_before.dead_key_id == 7);
	assert(character.composition_after.dead_key_id == 7);
	assert(ErgoptiReplay_Register(&state, OWNER, 2, 82, ROUTES, ROUTE_COUNT) == 0);
	event.timestamp = 3;
	event.key_up = 0;
	event.vk = 0x41;
	event.scan = 0x1E;
	before = state;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &character) == ERGOPTI_REPLAY_UNSUPPORTED);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	assert(ErgoptiReplay_Register(&state, OWNER, 3, 81, ROUTES, ROUTE_COUNT) == 0);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &character) == 0);
	assert(character.route.recipe_id == 301);
	assert(character.composition_before.dead_key_id == 7);
	assert(character.composition_before.generation == 1);
	assert(character.composition_after.dead_key_id == 0);
	assert(dead.composition_after.dead_key_id == 7);
	puts("PASS replay-route composition: supplied transitions and frozen snapshots, no glyph oracle.");
}

/** Invalid registration and events cannot partially publish or mutate state. */
static void TestRejections(void)
{
	ErgoptiReplay_State state = ERGOPTI_REPLAY_STATE_INIT;
	ErgoptiReplay_State before;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_NativeKeyEdge edge;
	ErgoptiReplay_Route invalid[2];
	ErgoptiReplay_Event event = { .timestamp = 9, .origin = 1, .vk = 0x42, .scan = 0x30 };
	assert(ErgoptiReplay_Initialize(&state, 0) == ERGOPTI_REPLAY_INVALID_ARGUMENT);
	assert(ErgoptiReplay_Register(&state, OWNER, 1, LAYOUT, NULL, 0) == ERGOPTI_REPLAY_NOT_INITIALIZED);
	Start(&state);
	before = state;
	assert(ErgoptiReplay_Initialize(&state, OWNER) == ERGOPTI_REPLAY_ALREADY_INITIALIZED);
	assert(ErgoptiReplay_Register(&state, OWNER + 1, 2, LAYOUT, NULL, 0) == ERGOPTI_REPLAY_OWNER_MISMATCH);
	assert(ErgoptiReplay_Register(&state, OWNER, 1, LAYOUT, NULL, 0) == ERGOPTI_REPLAY_STALE_REGISTRATION);
	invalid[0] = ROUTES[4];
	invalid[1] = ROUTES[4];
	invalid[1].route_id = 999;
	assert(ErgoptiReplay_Register(&state, OWNER, 2, LAYOUT, invalid, 2) == ERGOPTI_REPLAY_INVALID_REGISTRATION);
	invalid[1].code = 0x20;
	invalid[1].route_id = invalid[0].route_id;
	assert(ErgoptiReplay_Register(&state, OWNER, 2, LAYOUT, invalid, 2) == ERGOPTI_REPLAY_INVALID_REGISTRATION);
	invalid[1] = ROUTES[3];
	invalid[1].prefix_bit = 3;
	assert(ErgoptiReplay_Register(&state, OWNER, 2, LAYOUT, invalid, 2) == ERGOPTI_REPLAY_INVALID_REGISTRATION);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	assert(snapshot.route.recipe_id == 0 && snapshot.status == ERGOPTI_REPLAY_UNREGISTERED);
	memset(&edge, 0xAA, sizeof(edge));
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &snapshot, &edge) == ERGOPTI_REPLAY_UNREGISTERED);
	assert(edge.vk == 0 && edge.scan == 0);
	before = state;
	event.timestamp = 8;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_STALE_EVENT);
	event.timestamp = 10;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_INVALID_EVENT);
	event.origin = 4;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNSUPPORTED);
	event.origin = 3;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNSUPPORTED);
	event.origin = 2;
	event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_ORPHAN_EDGE);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	event.origin = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	event.timestamp = 11;
	event.key_up = 0;
	event.vk = 0x70;
	event.scan = 0x40;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(snapshot.route.recipe_id == 400);
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &snapshot, &edge) == ERGOPTI_REPLAY_UNSUPPORTED);
	assert(edge.vk == 0 && edge.scan == 0);
	puts("PASS replay-route rejection: initialization, ownership, registration, time and unsupported output.");
}

/** An explicit scan family cannot silently fall back to a VK character recipe. */
static void TestScanPriorityAndCapacity(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_State before;
	ErgoptiReplay_Route routes[3] = { ROUTES[5], ROUTES[4], ROUTES[0] };
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 1, .vk = 0x41, .scan = 0x1E };
	uint32_t index;
	Start(&state);
	routes[1].axis = ERGOPTI_REPLAY_VK;
	routes[1].code = 0x41;
	assert(ErgoptiReplay_Register(&state, OWNER, 2, LAYOUT, routes, 3) == 0);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	assert(snapshot.route.recipe_id == 0);
	for (index = 1; index < ERGOPTI_REPLAY_MAX_HELD_KEYS; ++index) {
		event.timestamp = index + 1;
		event.source_id = index;
		assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	}
	before = state;
	event.timestamp = 100;
	event.source_id = 100;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_CAPACITY);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	event.source_id = 0;
	event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	event.source_id = 100;
	event.key_up = 0;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNREGISTERED);
	puts("PASS replay-route scan ownership and finite source-aware hold capacity.");
}

/** Reusing an event buffer for its output must not erase the incoming edge. */
static void TestInputOutputAliasing(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 1, .vk = 0x41, .scan = 0x1E };
	Start(&state);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	snapshot.event.timestamp = 2;
	snapshot.event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &snapshot.event, &snapshot) == 0);
	assert(snapshot.event.timestamp == 2 && snapshot.event.key_up == 1);
	assert(snapshot.route.recipe_id == 100 && snapshot.route.target_scan == 0x30);
	puts("PASS replay-route reused input/output buffer retains its incoming event.");
}

/** Recipe consumption must not promote corrupted or untrusted provenance. */
static void TestRecipeValidation(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_Snapshot corrupt;
	ErgoptiReplay_NativeKeyEdge edge;
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 1, .vk = 0x41, .scan = 0x1E };
	Start(&state);
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER + 1, &snapshot, &edge)
		== ERGOPTI_REPLAY_OWNER_MISMATCH);
	corrupt = snapshot;
	corrupt.owner = OWNER + 1;
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &corrupt, &edge)
		== ERGOPTI_REPLAY_OWNER_MISMATCH);
	corrupt = snapshot;
	corrupt.event.origin = ERGOPTI_REPLAY_LOWER_INTEGRITY;
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &corrupt, &edge)
		== ERGOPTI_REPLAY_INVALID_ARGUMENT);
	corrupt = snapshot;
	corrupt.route_generation = 2;
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &corrupt, &edge)
		== ERGOPTI_REPLAY_INVALID_ARGUMENT);
	corrupt = snapshot;
	corrupt.route.recipe_id = 0;
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &corrupt, &edge)
		== ERGOPTI_REPLAY_INVALID_ARGUMENT);
	corrupt = snapshot;
	corrupt.event.repeat = 1;
	corrupt.event.key_up = 1;
	assert(ErgoptiReplay_PrepareNativeEdge(&state, OWNER, &corrupt, &edge)
		== ERGOPTI_REPLAY_INVALID_ARGUMENT);
	assert(edge.vk == 0 && edge.scan == 0 && edge.key_up == 0 && edge.repeat == 0);
	puts("PASS replay-route recipe validation rejects owner, provenance and malformed output.");
}

/** Unsupported modifier sources cannot poison the later authoritative route. */
static void TestSourceIdsAndDeadTransitions(void)
{
	ErgoptiReplay_State state;
	ErgoptiReplay_State before;
	ErgoptiReplay_Snapshot snapshot;
	ErgoptiReplay_Event event = { .timestamp = 1, .origin = 4, .vk = 0xA2, .scan = 0x1D };
	Start(&state);
	before = state;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == ERGOPTI_REPLAY_UNSUPPORTED);
	assert(memcmp(&state, &before, sizeof(state)) == 0);
	event.origin = 1;
	event.source_id = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	event.timestamp = 2;
	event.source_id = 2;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	event.timestamp = 3;
	event.source_id = 1;
	event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(snapshot.modifiers_lr_before == 0x04 && snapshot.modifiers_lr_after == 0x04);
	event.timestamp = 4;
	event.source_id = 2;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(snapshot.modifiers_lr_before == 0x04 && snapshot.modifiers_lr_after == 0);
	event.timestamp = 5;
	event.key_up = 0;
	event.vk = 0xC0;
	event.scan = 0x29;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(snapshot.composition_after.dead_key_id == 7);
	event.timestamp = 6;
	event.key_up = 1;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	event.timestamp = 7;
	event.key_up = 0;
	assert(ErgoptiReplay_Step(&state, OWNER, &event, &snapshot) == 0);
	assert(snapshot.route.recipe_id == 302);
	assert(snapshot.composition_before.dead_key_id == 7);
	assert(snapshot.composition_after.dead_key_id == 0);
	puts("PASS replay-route physical source IDs and explicitly supplied repeated dead-key transition.");
}

int main(void)
{
	TestEventVectors();
	TestRegistrationSwap();
	TestComposition();
	TestRejections();
	TestScanPriorityAndCapacity();
	TestInputOutputAliasing();
	TestRecipeValidation();
	TestSourceIdsAndDeadTransitions();
	puts("Portable replay-route core tests passed: 8/8 matrices.");
	puts("Windows native registration, replay delivery and physical qualification remain untested.");
	return 0;
}
