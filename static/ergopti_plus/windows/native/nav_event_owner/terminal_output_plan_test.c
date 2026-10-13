// static/ergopti_plus/windows/native/nav_event_owner/terminal_output_plan_test.c
/**
 * @file terminal_output_plan_test.c
 * @brief Independent literal output/ACK vectors, authored before implementation.
 *
 * Actual C executes here; Windows SendInput acceptance is not simulated as a
 * native result. The supplied numeric acceptance values are API boundary cases.
 */
#include "terminal_output_plan.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define OWNER 90u
static const ErgoptiReplay_Route ROUTE = {
	.recipe_id = 17, .route_id = 1, .code = 0x10,
	.axis = ERGOPTI_REPLAY_SCAN, .kind = ERGOPTI_REPLAY_CHARACTER
};
static void Start(ErgoptiOutput_State *output, ErgoptiReplay_State *routes)
{
	memset(output, 0, sizeof(*output));
	memset(routes, 0, sizeof(*routes));
	assert(ErgoptiOutput_Initialize(output, OWNER) == 0);
	assert(ErgoptiReplay_Initialize(routes, OWNER) == 0);
	assert(ErgoptiReplay_Register(routes, OWNER, 1, 2, &ROUTE, 1) == 0);
}
static ErgoptiReplay_Snapshot Snapshot(void)
{
	ErgoptiReplay_Snapshot s = {0};
	s.owner = OWNER; s.observed_generation = 1; s.observed_layout_id = 2;
	s.route_generation = 1; s.route_layout_id = 2;
	s.event.timestamp = 100; s.event.source_id = 1;
	s.event.vk = 0x51; s.event.scan = 0x10; s.event.origin = 1;
	s.route = ROUTE;
	return s;
}

static void TestLiteralVectors(void)
{
	/* ASCII, accented BMP, decomposed BMP, emoji surrogate, literal NUL, empty. */
	static const struct {
		uint16_t text[3]; uint32_t length;
	} vectors[] = {{{0x0061}, 1}, {{0x00E9}, 1}, {{0x0065, 0x0301}, 2},
		{{0xD83D, 0xDE00}, 2}, {{0x0000}, 1}, {{0}, 0}};
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	for (uint32_t i = 0; i < sizeof(vectors) / sizeof(vectors[0]); ++i) {
		ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
		ErgoptiOutput_Unit units[6]; uint32_t count = 99; uint64_t attempt = 0;
		assert(ErgoptiOutput_Plan(&o, OWNER, 10, i + 1, &r, &s,
			vectors[i].text, vectors[i].length, 1, &key) == 0);
		if (vectors[i].length) {
			assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 6, &count, &attempt) == 0);
			assert(count == vectors[i].length * 2);
			for (uint32_t j = 0; j < count; ++j) {
				assert(units[j].kind == 1 && units[j].utf16 == vectors[i].text[j / 2]);
				assert(units[j].key_up == j % 2 && units[j].vk == 0 && units[j].scan == 0);
				assert(units[j].reserved == 0);
			}
			assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, count) == 0);
		}
		ErgoptiReplay_Event edge;
		assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0);
		assert(edge.scan == 0x10 && edge.key_up == 0 && edge.origin == 1);
	}
}

static void TestSuffixAndFailure(void)
{
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
	uint16_t text[] = {0x0061, 0x00E9};
	ErgoptiOutput_Unit units[4]; uint32_t count; uint64_t a, b;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, text, 2, 1, &key) == 0);
	text[0] = 0x007A; s.event.scan = 0x11; /* caller changes cannot rewrite debt. */
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &a) == 0);
	assert(count == 4 && units[0].utf16 == 0x0061);
	ErgoptiOutput_Key foreign = key; foreign.sequence++;
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &foreign, a, 1) == -6);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER + 1, &key, a, 1) == -4);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, a + 1, 1) == -6);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == -8);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &b) == -5);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, a, 5) == -1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, a, 1) == 0);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == -8);
	ErgoptiReplay_Event edge;
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == -8);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &b) == -7);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &b) == 0);
	assert(count == 3 && units[0].utf16 == 0x0061 && units[0].key_up == 1);
	assert(units[1].utf16 == 0x00E9 && units[1].key_up == 0);
	assert(units[2].utf16 == 0x00E9 && units[2].key_up == 1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, a, 1) == -6);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, b, 0) == 0);
	assert(o.accepted == 1 && o.active);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &b) == 0);
	assert(count == 3 && units[0].key_up == 1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, b, 2) == 0);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &b) == 0);
	assert(count == 1 && units[0].utf16 == 0x00E9 && units[0].key_up == 1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, b, 1) == 0);
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0 && edge.scan == 0x10);
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == -6);
}

static void TestEdgesAndGuard(void)
{
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
	ErgoptiReplay_Event edge; ErgoptiOutput_Unit units[2]; uint32_t count; uint64_t a;
	s.event.key_up = 1; s.route.required_modifiers = 4; /* Shift was released first. */
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, NULL, 0, 1, &key) == 0);
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0 && edge.key_up == 1);
	s = Snapshot(); s.route.kind = 4; s.route.code = 0x2A;
	s.event.scan = 0x2A; s.event.vk = 0xA0;
	s.route.target_scan = 0x2A; s.route.effective_modifiers_lr = 0x10;
	for (uint32_t up = 0; up < 2; ++up) {
		s.event.key_up = (uint8_t)up;
		s.modifiers_lr_before = up ? 0x10 : 0;
		s.modifiers_lr_after = up ? 0 : 0x10;
		assert(ErgoptiOutput_Plan(&o, OWNER, 10, up + 2, &r, &s, NULL, 0, 1, &key) == 0);
		assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &a) == 0);
		assert(count == 1 && units[0].kind == 2 && units[0].scan == 0x2A);
		assert(units[0].key_up == up && units[0].utf16 == 0 && units[0].reserved == 0);
		assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, a, 1) == 0);
		assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0);
	}
	for (uint32_t i = 0; i < 5; ++i) {
		s = Snapshot(); uint16_t text = 0x0061;
		if (i == 1) { s.route.kind = 3; s.route.next_dead_key_id = 7; }
		if (i == 2) { s.route.kind = 5; s.route.prefix_bit = 1; }
		if (i == 3) s.status = 2;
		if (i == 4) { s.route.kind = 4; s.route.target_scan = 0x20; }
		assert(ErgoptiOutput_Plan(&o, OWNER, 10, i + 4, &r, &s, &text, 1,
			i == 0 ? 0 : 1, &key) == 1);
		assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &a) == 1);
		assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 1);
		assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	}
}

static void TestDiagnosticCopyAndBounds(void)
{
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
	uint16_t text[] = {0xD83D, 0xDE00};
	ErgoptiOutput_Unit units[ERGOPTI_OUTPUT_MAX_UNITS]; uint32_t count, dispatchable;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, text, 2, 0, &key) == 1);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, NULL, 0, &count, &dispatchable) == 0);
	assert(count == 4 && dispatchable == 0);
	memset(units, 0x55, sizeof(units));
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, units, 3, &count, &dispatchable) == -7);
	assert(units[0].utf16 == 0x5555 && o.accepted == 0 && !o.attempting);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, units, 4, &count, &dispatchable) == 0);
	assert(units[0].utf16 == 0xD83D && units[0].key_up == 0);
	assert(units[1].utf16 == 0xD83D && units[1].key_up == 1);
	assert(units[2].utf16 == 0xDE00 && units[2].key_up == 0);
	assert(units[3].utf16 == 0xDE00 && units[3].key_up == 1);
	units[0].utf16 = 0x0061;
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, units, 4, &count, &dispatchable) == 0);
	assert(units[0].utf16 == 0xD83D && o.accepted == 0 && !o.dispatchable);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	uint16_t maximum[ERGOPTI_OUTPUT_MAX_UTF16];
	for (uint32_t i = 0; i < ERGOPTI_OUTPUT_MAX_UTF16; ++i) maximum[i] = 0x0061;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &s, maximum, 1024, 1, &key) == 0);
	uint64_t attempt;
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2048, &count, &attempt) == 0);
	assert(count == 2048 && units[2047].utf16 == 0x0061 && units[2047].key_up == 1);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == -8);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 0) == 0);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	/* A letter declared as a modifier is not a natural native modifier. */
	s.route.kind = 4; s.route.target_scan = 0x10; s.route.effective_modifiers_lr = 0x10;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 3, &r, &s, NULL, 0, 1, &key) == 1);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, NULL, 0, &count, &dispatchable) == 0);
	assert(count == 0 && dispatchable == 0);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	memset(&s.route, 0, sizeof(s.route)); s.route_generation = 0; s.route_layout_id = 0;
	s.status = 1;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 4, &r, &s, NULL, 0, 1, &key) == 1);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, NULL, 0, &count, &dispatchable) == 0);
	assert(count == 0 && dispatchable == 0 && o.snapshot.status == 1);
}

/** Real routing output, not a fabricated all-zero absent-registration fixture. */
static void TestUnregisteredCoreInterop(void)
{
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Event input = {.timestamp = 100, .source_id = 1,
		.vk = 0x42, .scan = 0x30, .origin = ERGOPTI_REPLAY_PHYSICAL};
	ErgoptiReplay_Snapshot actual;
	assert(ErgoptiReplay_Step(&r, OWNER, &input, &actual) == ERGOPTI_REPLAY_UNREGISTERED);
	assert(actual.route.recipe_id == 0 && actual.route.route_id == 0);
	assert(actual.route_generation == 1 && actual.route_layout_id == 2);
	ErgoptiOutput_Key key; uint32_t count, dispatchable;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &actual, NULL, 0, 0, &key) == 1);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, NULL, 0, &count, &dispatchable) == 0);
	assert(count == 0 && dispatchable == 0 && o.snapshot.route_generation == 1);
	assert(o.snapshot.route_layout_id == 2 && o.snapshot.event.scan == 0x30);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	ErgoptiReplay_Snapshot bad = actual;
	bad.route_generation = 0;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &bad, NULL, 0, 0, &key) == -1);
	bad = actual; bad.route_layout_id = 0;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &bad, NULL, 0, 0, &key) == -1);
	bad = actual; bad.route_generation = 2;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &bad, NULL, 0, 0, &key) == -1);
	bad = actual; bad.observed_generation = 2; bad.route_generation = 2;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &bad, NULL, 0, 0, &key) == -1);
	/* An old unknown hold retains its original layout after a registry swap. */
	assert(ErgoptiReplay_Register(&r, OWNER, 2, 3, &ROUTE, 1) == 0);
	input.timestamp = 101; input.key_up = 1;
	assert(ErgoptiReplay_Step(&r, OWNER, &input, &actual) == ERGOPTI_REPLAY_UNREGISTERED);
	assert(actual.observed_generation == 2 && actual.observed_layout_id == 3);
	assert(actual.route_generation == 1 && actual.route_layout_id == 2);
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &actual, NULL, 0, 1, &key) == 1);
	assert(ErgoptiOutput_Inspect(&o, OWNER, &key, NULL, 0, &count, &dispatchable) == 0);
	assert(count == 0 && dispatchable == 0 && o.snapshot.event.key_up == 1);
}

/** Exact ABI custody must retain representation bytes, not only field values. */
static void TestSnapshotRepresentationCustody(void)
{
	/* Independent pinned x64 padding offsets: snapshot, composition, event, route. */
	static const uint32_t padding[] = {
		54, 55, 76, 77, 78, 79, 100, 101, 102, 103, 127, 166, 167
	};
	ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Snapshot s = Snapshot();
	unsigned char expected[168];
	unsigned char *bytes = (unsigned char *)&s;
	for (uint32_t i = 0; i < sizeof(padding) / sizeof(padding[0]); ++i)
		bytes[padding[i]] = (unsigned char)(0x91u + i);
	memcpy(expected, &s, sizeof(expected));
	uint16_t text = 0x0061;
	ErgoptiOutput_Key key; ErgoptiOutput_Unit units[2];
	uint32_t count; uint64_t attempt;
	assert(sizeof(s) == sizeof(expected));
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, &text, 1, 1, &key) == 0);
	assert(memcmp(&o.snapshot, expected, sizeof(expected)) == 0);
	/* Caller storage retires while the complete immutable owned receipt survives. */
	memset(&s, 0xDD, sizeof(s));
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &attempt) == 0);
	assert(count == 2 && units[0].utf16 == 0x0061 && units[1].key_up == 1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 1) == 0);
	assert(memcmp(&o.snapshot, expected, sizeof(expected)) == 0);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &attempt) == 0);
	assert(count == 1 && units[0].utf16 == 0x0061 && units[0].key_up == 1);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 1) == 0);
	ErgoptiReplay_Event edge;
	memset(&edge, 0xEE, sizeof(edge));
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0);
	assert(memcmp(&edge, expected + 104, 24) == 0);
	assert(memcmp(&o.snapshot, expected, sizeof(expected)) == 0);
}

static void TestInvalidAndOwnership(void)
{
	ErgoptiOutput_State o = ERGOPTI_OUTPUT_STATE_INIT; ErgoptiReplay_State r;
	assert(ErgoptiOutput_Initialize(&o, 0) == -1);
	o.owner = OWNER + 1; assert(ErgoptiOutput_Initialize(&o, OWNER) == -1);
	Start(&o, &r); assert(ErgoptiOutput_Initialize(&o, OWNER) == -3);
	ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
	uint16_t bad[][2] = {{0xD800,0}, {0xDC00,0}, {0xD800,0x0061}};
	for (uint32_t i = 0; i < 3; ++i)
		assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, bad[i], i == 2 ? 2 : 1, 1, &key) == -1);
	assert(ErgoptiOutput_Plan(&o, OWNER + 1, 10, 1, &r, &s, NULL, 0, 1, &key) == -4);
	assert(ErgoptiOutput_Plan(&o, OWNER, 0, 1, &r, &s, NULL, 0, 1, &key) == -1);
	s.owner = OWNER + 1;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, NULL, 0, 1, &key) == -4);
	s = Snapshot(); s.event.origin = 4;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, NULL, 0, 1, &key) == -1);
	s = Snapshot(); s.event.repeat = 1;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, NULL, 0, 1, &key) == 0);
	ErgoptiOutput_Key foreign = key; foreign.token++;
	assert(ErgoptiOutput_Cancel(&o, OWNER, &foreign) == -6);
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &s, NULL, 0, 1, &foreign) == -5);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, NULL, 0, 1, &key) == -6);
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 2, &r, &s, NULL, 1025, 1, &key) == -7);
}

/** Crossed authentic sources keep a natural modifier active until its final UP. */
static void TestNaturalModifierSourceCustody(void)
{
	/* Literal Win32 natural identities and independent left/right bit expectations. */
	static const struct { uint16_t vk, scan; uint8_t bit; } modifiers[] = {
		{0xA2, 0x01D, 0x01}, {0xA3, 0x11D, 0x02},
		{0xA4, 0x038, 0x04}, {0xA5, 0x138, 0x08},
		{0xA0, 0x02A, 0x10}, {0xA1, 0x036, 0x20},
		{0x5B, 0x15B, 0x40}, {0x5C, 0x15C, 0x80}
	};
	/* One source may repeat, and a replay source cannot retire a physical hold.
	 * before/after are expected ownership booleans for the selected natural bit. */
	static const struct {
		uint64_t source; uint8_t up, repeat, before, after, count;
	} vectors[] = {
		{1, 0, 0, 0, 1, 1},
		{2, 0, 0, 1, 1, 0},
		{1, 0, 1, 1, 1, 0},
		{1, 1, 0, 1, 1, 0},
		{2, 1, 0, 1, 0, 1}
	};
	for (uint32_t modifier = 0; modifier < sizeof(modifiers) / sizeof(modifiers[0]); ++modifier) {
		for (uint32_t axis = 1; axis <= 2; ++axis) {
			for (uint32_t split_origin = 0; split_origin <= 1; ++split_origin) {
				for (uint32_t unrelated = 0; unrelated <= 1; ++unrelated) {
					ErgoptiOutput_State o; ErgoptiReplay_State r; Start(&o, &r);
					uint32_t background_index = modifier == 0 ? 1 : 0;
					uint8_t background_mask = unrelated ? modifiers[background_index].bit : 0;
					ErgoptiReplay_Route routes[2] = {
						{ .recipe_id = 42, .route_id = 42,
							.code = axis == 1 ? modifiers[modifier].vk : modifiers[modifier].scan,
							.axis = (uint8_t)axis, .kind = ERGOPTI_REPLAY_MODIFIER,
							.target_vk = axis == 1 ? modifiers[modifier].vk : 0,
							.target_scan = axis == 2 ? modifiers[modifier].scan : 0,
							.effective_modifiers_lr = modifiers[modifier].bit },
						{ .recipe_id = 43, .route_id = 43,
							.code = axis == 1 ? modifiers[background_index].vk : modifiers[background_index].scan,
							.axis = (uint8_t)axis, .kind = ERGOPTI_REPLAY_MODIFIER,
							.target_vk = axis == 1 ? modifiers[background_index].vk : 0,
							.target_scan = axis == 2 ? modifiers[background_index].scan : 0,
							.effective_modifiers_lr = modifiers[background_index].bit }
					};
					assert(ErgoptiReplay_Register(&r, OWNER, 2, 2, routes, 2) == 0);
					if (unrelated) {
						ErgoptiReplay_Event background = {
							.timestamp = 0, .source_id = 3,
							.vk = modifiers[background_index].vk, .scan = modifiers[background_index].scan,
							.origin = ERGOPTI_REPLAY_PHYSICAL
						};
						ErgoptiReplay_Snapshot held;
						assert(ErgoptiReplay_Step(&r, OWNER, &background, &held) == 0);
						assert(held.modifiers_lr_before == 0 && held.modifiers_lr_after == background_mask);
					}
					for (uint32_t i = 0; i < sizeof(vectors) / sizeof(vectors[0]); ++i) {
						ErgoptiReplay_Event input = {
							.timestamp = i + 1, .source_id = vectors[i].source,
							.vk = modifiers[modifier].vk, .scan = modifiers[modifier].scan,
							.origin = split_origin && vectors[i].source == 2
								? ERGOPTI_REPLAY_OWNED_REPLAY : ERGOPTI_REPLAY_PHYSICAL,
							.key_up = vectors[i].up, .repeat = vectors[i].repeat
						};
						ErgoptiReplay_Snapshot snapshot; ErgoptiOutput_Key key;
						ErgoptiOutput_Unit units[2]; uint32_t count, dispatchable; uint64_t attempt;
						ErgoptiReplay_Event consumed;
						assert(ErgoptiReplay_Step(&r, OWNER, &input, &snapshot) == 0);
						assert(snapshot.modifiers_lr_before == (uint8_t)(background_mask
							| (vectors[i].before ? modifiers[modifier].bit : 0)));
						assert(snapshot.modifiers_lr_after == (uint8_t)(background_mask
							| (vectors[i].after ? modifiers[modifier].bit : 0)));
						if (vectors[i].count == 0) {
							ErgoptiOutput_State guarded = ERGOPTI_OUTPUT_STATE_INIT;
							ErgoptiOutput_Key refused;
							assert(ErgoptiOutput_Initialize(&guarded, OWNER) == 0);
							assert(ErgoptiOutput_Plan(&guarded, OWNER, 77, i + 1, &r,
								&snapshot, NULL, 0, 0, &refused) == ERGOPTI_OUTPUT_DIAGNOSTIC);
							assert(ErgoptiOutput_Inspect(&guarded, OWNER, &refused,
								units, 2, &count, &dispatchable) == 0);
							assert(count == 0 && dispatchable == 0);
							assert(ErgoptiOutput_Consume(&guarded, OWNER, &refused,
								&consumed) == ERGOPTI_OUTPUT_DIAGNOSTIC);
							assert(ErgoptiOutput_BeginAttempt(&guarded, OWNER, &refused,
								units, 2, &count, &attempt) == ERGOPTI_OUTPUT_DIAGNOSTIC);
							assert(ErgoptiOutput_Cancel(&guarded, OWNER, &refused) == 0);
						}
						assert(ErgoptiOutput_Plan(&o, OWNER, 77, i + 1, &r,
							&snapshot, NULL, 0, 1, &key) == 0);
						assert(ErgoptiOutput_Inspect(&o, OWNER, &key,
							units, 2, &count, &dispatchable) == 0);
						assert(count == vectors[i].count && dispatchable == 1);
						if (count == 1) {
							assert(units[0].kind == ERGOPTI_OUTPUT_NATIVE_EDGE);
							assert(units[0].vk == (axis == 1 ? modifiers[modifier].vk : 0));
							assert(units[0].scan == (axis == 2 ? modifiers[modifier].scan : 0));
							assert(units[0].key_up == vectors[i].up && units[0].repeat == 0);
							assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &attempt) == 0);
							assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 0) == 0);
							assert(ErgoptiOutput_Consume(&o, OWNER, &key, &consumed) == ERGOPTI_OUTPUT_DEBT);
							assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2, &count, &attempt) == 0);
							assert(count == 1 && units[0].key_up == vectors[i].up);
							assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 1) == 0);
						} else {
							assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 2,
								&count, &attempt) == ERGOPTI_OUTPUT_DEBT);
							assert(!o.attempting && o.accepted == 0);
						}
						assert(ErgoptiOutput_Consume(&o, OWNER, &key, &consumed) == 0);
						assert(consumed.source_id == input.source_id && consumed.origin == input.origin);
						assert(consumed.key_up == input.key_up && consumed.repeat == input.repeat);
						assert(consumed.vk == modifiers[modifier].vk && consumed.scan == modifiers[modifier].scan);
						assert(ErgoptiOutput_Consume(&o, OWNER, &key, &consumed) == ERGOPTI_OUTPUT_STALE);
					}
				}
			}
		}
	}
}

/** Each expectation is literal Win32 data, independent of serializer branches. */
static void AssertWin32Packet(const ErgoptiOutput_Win32Input *p,
	uint16_t vk, uint16_t scan, uint32_t flags)
{
	const ErgoptiOutput_Win32Input expected = {
		.type = 1, .vk = vk, .scan = scan, .flags = flags,
		.extra_info = 0x4552475054524D31ull
	};
	assert(memcmp(p, &expected, 40) == 0);
}

static void TestWin32UnicodeAttemptPrefixes(void)
{
	static const struct { uint16_t text[3]; uint32_t length; } vectors[] = {
		{{0x0061},1}, {{0x00E9},1}, {{0x0065,0x0301},2},
		{{0xD83D,0xDE00},2}, {{0x0000},1}, {{0x0061,0xD83D,0xDE00},3}
	};
	for (uint32_t v = 0; v < sizeof(vectors) / sizeof(vectors[0]); ++v) {
		uint32_t total = vectors[v].length * 2;
		for (uint32_t prefix = 0; prefix <= total; ++prefix) {
			ErgoptiOutput_State o, retained; ErgoptiReplay_State r; Start(&o, &r);
			ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key;
			ErgoptiOutput_Unit units[6]; ErgoptiOutput_Win32Input packets[6];
			uint32_t count = 99; uint64_t attempt, old_attempt;
			s.event.repeat = 1; /* Repeat is an edge annotation, never extra INPUTs. */
			assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s,
				vectors[v].text, vectors[v].length, 1, &key) == 0);
			assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 6, &count, &attempt) == 0);
			old_attempt = attempt;
			memcpy(&retained, &o, sizeof(o)); memset(packets, 0xA5, sizeof(packets));
			assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 6, &count) == 0);
			assert(count == total && memcmp(&retained, &o, sizeof(o)) == 0);
			for (uint32_t i = 0; i < count; ++i)
				AssertWin32Packet(&packets[i], 0, vectors[v].text[i / 2], i % 2 ? 6 : 4);
			packets[0].scan = 0x007A; /* External copies do not rewrite retained units. */
			assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 6, &count) == 0);
			AssertWin32Packet(&packets[0], 0, vectors[v].text[0], 4);
			assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == -8);
			assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, prefix) == 0);
			count = 99; memset(packets, 0xA5, sizeof(packets));
			assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, old_attempt, packets, 6, &count) == -6);
			assert(count == 99 && packets[0].type == 0xA5A5A5A5u);
			ErgoptiReplay_Event edge;
			if (prefix < total) {
				assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == -8);
				assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 6, &count, &attempt) == 0);
				assert(attempt != old_attempt && count == total - prefix);
				assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, old_attempt, packets, 6, &count) == -6);
				memcpy(&retained, &o, sizeof(o));
				assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 6, &count) == 0);
				assert(count == total - prefix && memcmp(&retained, &o, sizeof(o)) == 0);
				for (uint32_t i = 0; i < count; ++i) {
					uint32_t original = prefix + i;
					AssertWin32Packet(&packets[i], 0, vectors[v].text[original / 2], original % 2 ? 6 : 4);
				}
				assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, count) == 0);
			}
			assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0);
			assert(edge.scan == 0x10 && edge.repeat == 1);
		}
	}
}

static void TestWin32NaturalKeysFromActualReplay(void)
{
	/* VK, encoded scan, effective LR bit, literal scan-mode DOWN flags. */
	static const struct { uint16_t vk, scan; uint8_t lr; uint32_t flags; } vectors[] = {
		{0xA2,0x01D,0x01,8}, {0xA3,0x11D,0x02,9},
		{0xA4,0x038,0x04,8}, {0xA5,0x138,0x08,9},
		{0xA0,0x02A,0x10,8}, {0xA1,0x036,0x20,8},
		{0x5B,0x15B,0x40,9}, {0x5C,0x15C,0x80,9}
	};
	for (uint32_t v = 0; v < 8; ++v) for (uint32_t axis = 1; axis <= 2; ++axis) {
		ErgoptiOutput_State o = ERGOPTI_OUTPUT_STATE_INIT;
		ErgoptiReplay_State r = ERGOPTI_REPLAY_STATE_INIT;
		ErgoptiReplay_Route route = {.recipe_id = 1, .route_id = 1,
			.kind = ERGOPTI_REPLAY_MODIFIER, .axis = (uint8_t)axis,
			.effective_modifiers_lr = vectors[v].lr};
		route.code = axis == 1 ? vectors[v].vk : vectors[v].scan;
		if (axis == 1) route.target_vk = vectors[v].vk;
		else route.target_scan = vectors[v].scan;
		assert(ErgoptiOutput_Initialize(&o, OWNER) == 0);
		assert(ErgoptiReplay_Initialize(&r, OWNER) == 0);
		assert(ErgoptiReplay_Register(&r, OWNER, 1, 2, &route, 1) == 0);
		for (uint32_t up = 0; up < 2; ++up) {
			ErgoptiReplay_Event event = {.timestamp = up + 1, .source_id = 1,
				.vk = vectors[v].vk, .scan = vectors[v].scan, .key_up = (uint8_t)up,
				.origin = ERGOPTI_REPLAY_PHYSICAL};
			ErgoptiReplay_Snapshot s; ErgoptiOutput_Key key;
			ErgoptiOutput_Unit unit; ErgoptiOutput_Win32Input packet;
			uint32_t count; uint64_t attempt; ErgoptiReplay_Event consumed;
			assert(ErgoptiReplay_Step(&r, OWNER, &event, &s) == 0);
			assert(ErgoptiOutput_Plan(&o, OWNER, 10, up + 1, &r, &s, NULL, 0, 1, &key) == 0);
			assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, &unit, 1, &count, &attempt) == 0);
			assert(count == 1);
			assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, &packet, 1, &count) == 0);
			assert(count == 1);
			if (axis == 1) AssertWin32Packet(&packet, vectors[v].vk, 0, up ? 2 : 0);
			else AssertWin32Packet(&packet, 0, vectors[v].scan & 0xFFu, vectors[v].flags | (up ? 2 : 0));
			assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 1) == 0);
			assert(ErgoptiOutput_Consume(&o, OWNER, &key, &consumed) == 0);
			assert(consumed.key_up == up && consumed.scan == vectors[v].scan);
		}
	}
}

static void TestWin32SerializationRefusalsAndBounds(void)
{
	ErgoptiOutput_State o, retained; ErgoptiReplay_State r; Start(&o, &r);
	ErgoptiReplay_Snapshot s = Snapshot(); ErgoptiOutput_Key key, foreign;
	uint16_t text[] = {0xD83D,0xDE00};
	ErgoptiOutput_Unit units[4]; ErgoptiOutput_Win32Input packets[4], unchanged[4];
	uint32_t count = 99; uint64_t attempt;
	assert(ErgoptiOutput_Plan(&o, OWNER, 10, 1, &r, &s, text, 2, 1, &key) == 0);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, 1, packets, 4, &count) == -6);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, units, 4, &count, &attempt) == 0);
	count = 99; memset(packets, 0xA5, sizeof(packets)); memcpy(unchanged, packets, sizeof(packets));
	memcpy(&retained, &o, sizeof(o));
	assert(ErgoptiOutput_SerializeAttempt(NULL, OWNER, &key, attempt, packets, 4, &count) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER + 1, &key, attempt, packets, 4, &count) == -4);
	for (uint32_t i = 0; i < 3; ++i) {
		foreign = key;
		if (i == 0) ++foreign.token;
		if (i == 1) ++foreign.sequence;
		if (i == 2) ++foreign.plan_id;
		assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &foreign, attempt, packets, 4, &count) == -6);
	}
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt + 1, packets, 4, &count) == -6);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 3, &count) == -7);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 2049, &count) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, NULL, 4, &count) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, NULL) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt,
		(ErgoptiOutput_Win32Input *)&o, 4, &count) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt,
		(ErgoptiOutput_Win32Input *)&key, 4, &count) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, &packets[0].type) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, &o.accepted) == -1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, (uint32_t *)&key) == -1);
	assert(count == 99 && memcmp(packets, unchanged, sizeof(packets)) == 0);
	assert(memcmp(&retained, &o, sizeof(o)) == 0);
	/* Corrupted intrinsic unit data cannot partially overwrite an earlier packet. */
	for (uint32_t bad = 0; bad < 8; ++bad) {
		memcpy(&o, &retained, sizeof(o));
		ErgoptiOutput_Unit *last = &o.units[3];
		if (bad == 0) last->reserved = 1;
		if (bad == 1) last->key_up = 2;
		if (bad == 2) last->repeat = 1;
		if (bad == 3) last->vk = 1;
		if (bad == 4) last->kind = 0;
		if (bad == 5) { last->kind = 2; last->utf16 = 0; last->vk = 0xA0; last->scan = 0x2A; }
		if (bad == 6) { last->kind = 2; last->utf16 = 0; last->scan = 0x100; }
		if (bad == 7) { last->kind = 2; last->utf16 = 0; last->vk = 256; }
		ErgoptiOutput_State invalid; memcpy(&invalid, &o, sizeof(o));
		assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, &count) == -1);
		assert(count == 99 && memcmp(packets, unchanged, sizeof(packets)) == 0);
		assert(memcmp(&invalid, &o, sizeof(o)) == 0);
	}
	memcpy(&o, &retained, sizeof(o));
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 0) == 0);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, &count) == -6);
	assert(ErgoptiOutput_Plan(&o, OWNER, 11, 2, &r, &s, text, 2, 0, &key) == 1);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, packets, 4, &count) == 1);
	assert(count == 99 && memcmp(packets, unchanged, sizeof(packets)) == 0);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == 0);
	/* Upper bound has exactly 2048 packets, retaining every last Unicode UP. */
	uint16_t maximum[1024];
	ErgoptiOutput_Unit maximum_units[2048]; ErgoptiOutput_Win32Input maximum_packets[2048];
	for (uint32_t i = 0; i < 1024; ++i) maximum[i] = 0x0061;
	assert(ErgoptiOutput_Plan(&o, OWNER, 12, 3, &r, &s, maximum, 1024, 1, &key) == 0);
	assert(ErgoptiOutput_BeginAttempt(&o, OWNER, &key, maximum_units, 2048, &count, &attempt) == 0);
	assert(ErgoptiOutput_SerializeAttempt(&o, OWNER, &key, attempt, maximum_packets, 2048, &count) == 0);
	assert(count == 2048);
	AssertWin32Packet(&maximum_packets[0], 0, 0x0061, 4);
	AssertWin32Packet(&maximum_packets[2047], 0, 0x0061, 6);
	assert(ErgoptiOutput_Cancel(&o, OWNER, &key) == -8);
	assert(ErgoptiOutput_Acknowledge(&o, OWNER, &key, attempt, 2048) == 0);
	ErgoptiReplay_Event edge;
	assert(ErgoptiOutput_Consume(&o, OWNER, &key, &edge) == 0);
}

int main(void)
{
	TestLiteralVectors(); puts("PASS output-plan literal Unicode vectors (6)");
	TestSuffixAndFailure(); puts("PASS output-plan exact partial ACK, zero acceptance and immutable retry");
	TestEdgesAndGuard(); puts("PASS output-plan edge consumption, natural modifiers and cohort guards");
	TestInvalidAndOwnership(); puts("PASS output-plan malformed UTF16, provenance, ownership and sequence");
	TestDiagnosticCopyAndBounds(); puts("PASS output-plan guarded diagnostic copies and 1024-unit text bound");
	TestUnregisteredCoreInterop(); puts("PASS output-plan actual unregistered core snapshots and registration coherence");
	TestSnapshotRepresentationCustody(); puts("PASS output-plan exact nonzero-padding snapshot and edge custody");
	TestNaturalModifierSourceCustody(); puts("PASS output-plan eight natural LR families retain crossed source and unrelated modifier custody");
	TestWin32UnicodeAttemptPrefixes(); puts("PASS output-plan Win32 UTF16 packets and every accepted prefix (6 vectors, 26 prefix cohorts)");
	TestWin32NaturalKeysFromActualReplay(); puts("PASS output-plan Win32 native VK/extended scan packets (8 LR families, 32 edges)");
	TestWin32SerializationRefusalsAndBounds(); puts("PASS output-plan Win32 immutable custody, atomic refusal, aliases and maximum bound");
	puts("PASS terminal output plan: 11 matrices; native Windows output UNRUN");
	return 0;
}
