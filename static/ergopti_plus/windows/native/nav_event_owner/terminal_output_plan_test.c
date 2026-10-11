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

int main(void)
{
	TestLiteralVectors(); puts("PASS output-plan literal Unicode vectors (6)");
	TestSuffixAndFailure(); puts("PASS output-plan exact partial ACK, zero acceptance and immutable retry");
	TestEdgesAndGuard(); puts("PASS output-plan edge consumption, natural modifiers and cohort guards");
	TestInvalidAndOwnership(); puts("PASS output-plan malformed UTF16, provenance, ownership and sequence");
	TestDiagnosticCopyAndBounds(); puts("PASS output-plan guarded diagnostic copies and 1024-unit text bound");
	TestUnregisteredCoreInterop(); puts("PASS output-plan actual unregistered core snapshots and registration coherence");
	TestSnapshotRepresentationCustody(); puts("PASS output-plan exact nonzero-padding snapshot and edge custody");
	puts("PASS terminal output plan: 7 matrices; native Windows output UNRUN");
	return 0;
}
