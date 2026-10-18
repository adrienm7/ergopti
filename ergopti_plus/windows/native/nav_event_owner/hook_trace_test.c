// static/ergopti_plus/windows/native/nav_event_owner/hook_trace_test.c
/**
 * @file hook_trace_test.c
 * @brief Independent raw integer, lifecycle, paging and saturation regressions.
 *
 * Executes the actual portable ring source. QPC and hook fields are literal
 * vectors; this does not run or qualify a Windows hook or a physical device.
 */
#include "hook_trace.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define OWNER 900u
#define TOKEN 81u
static const ErgoptiTrace_Event RAW = {
	.qpc = UINT64_C(0xF123456789ABCDEF),
	.extra_info = UINT64_C(0xFEDCBA9876543210),
	.capture_sequence = UINT64_C(0xE123456789ABCDE0),
	.vk = UINT32_C(0xFFFFFFFF), .scan = UINT32_C(0xDEADBEEF),
	.flags = UINT32_C(0x800000A5), .time = UINT32_C(0xFFFFFFFF),
	.message = UINT32_C(0xABCD0101), .decision = ERGOPTI_TRACE_PASS
};
static void Begin(ErgoptiTrace_State *s)
{
	memset(s, 0, sizeof(*s));
	assert(ErgoptiTrace_Initialize(s, OWNER) == 0);
	assert(ErgoptiTrace_Start(s, OWNER, TOKEN, 1) == 0);
}
static void TestDefaultAndLifecycle(void)
{
	ErgoptiTrace_State s = ERGOPTI_TRACE_STATE_INIT;
	assert(ErgoptiTrace_Initialize(&s, 0) == -1);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == -2);
	assert(ErgoptiTrace_Initialize(&s, OWNER) == 0 && !s.enabled);
	assert(ErgoptiTrace_Initialize(&s, OWNER) == -3);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == -5);
	assert(s.count == 0 && s.attempted == 0 && s.dropped == 0);
	assert(ErgoptiTrace_Start(&s, OWNER, TOKEN, 1) == 0);
	assert(ErgoptiTrace_Start(&s, OWNER, TOKEN, 2) == -7);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 0);
	assert(ErgoptiTrace_Stop(&s, OWNER, TOKEN, 1) == 0);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 2);
	assert(ErgoptiTrace_Stop(&s, OWNER, TOKEN, 1) == 2);
	assert(s.count == 1 && s.attempted == 1 && s.dropped == 0);
	assert(ErgoptiTrace_Start(&s, OWNER, TOKEN + 1, 1) == -6);
	assert(ErgoptiTrace_Start(&s, OWNER, TOKEN + 1, 2) == 0);
	assert(s.count == 0 && s.attempted == 0 && s.dropped == 0);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN + 1, 2, &RAW) == 0);
	assert(s.entries[0].sequence == 2 && s.entries[0].event.reserved == 0);
}
static void TestLiteralRawAndReadOnly(void)
{
	ErgoptiTrace_State s; Begin(&s);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 0);
	ErgoptiTrace_Event changed = RAW; changed.qpc = 1; changed.decision = 5;
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &changed) == 0);
	ErgoptiTrace_State before; memcpy(&before, &s, sizeof(s));
	ErgoptiTrace_Entry entries[2]; ErgoptiTrace_Receipt receipt;
	memset(entries, 0xCC, sizeof(entries)); memset(&receipt, 0xCC, sizeof(receipt));
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 2, entries, 2, &receipt) == 0);
	assert(memcmp(&s, &before, sizeof(s)) == 0);
	assert(entries[0].sequence == 1 && entries[1].sequence == 2);
	assert(entries[0].event.qpc == UINT64_C(0xF123456789ABCDEF));
	assert(entries[0].event.extra_info == UINT64_C(0xFEDCBA9876543210));
	assert(entries[0].event.capture_sequence == UINT64_C(0xE123456789ABCDE0));
	assert(entries[0].event.vk == UINT32_C(0xFFFFFFFF));
	assert(entries[0].event.scan == UINT32_C(0xDEADBEEF));
	assert(entries[0].event.flags == UINT32_C(0x800000A5));
	assert(entries[0].event.time == UINT32_C(0xFFFFFFFF));
	assert(entries[0].event.message == UINT32_C(0xABCD0101));
	assert(entries[0].event.decision == 1 && entries[0].event.reserved == 0);
	assert(entries[1].event.qpc == 1 && entries[1].event.decision == 5);
	assert(receipt.owner == OWNER && receipt.token == TOKEN && receipt.generation == 1);
	assert(receipt.attempted == 2 && receipt.dropped == 0 && receipt.stored == 2);
	assert(receipt.first_sequence == 1 && receipt.last_sequence == 2);
	assert(receipt.capacity == 256 && receipt.page_offset == 0 && receipt.page_count == 2);
	assert(receipt.enabled == 1 && receipt.overflow == 0);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 1, 1, entries, 2, &receipt) == 0);
	assert(entries[0].sequence == 2 && receipt.page_offset == 1 && receipt.page_count == 1);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 2, 0, NULL, 0, &receipt) == 0);
	assert(receipt.page_count == 0 && memcmp(&s, &before, sizeof(s)) == 0);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 1, 1, &s.entries[0], 1, &receipt) == -1);
	assert(memcmp(&s, &before, sizeof(s)) == 0);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 0, NULL, 0,
		(ErgoptiTrace_Receipt *)(void *)&s.entries[0]) == -1);
	assert(memcmp(&s, &before, sizeof(s)) == 0);
}
static void TestIdentityAndMalformed(void)
{
	ErgoptiTrace_State s; Begin(&s); ErgoptiTrace_State before; memcpy(&before, &s, sizeof(s));
	ErgoptiTrace_Entry entry; ErgoptiTrace_Receipt receipt;
	memset(&entry, 0x55, sizeof(entry)); memset(&receipt, 0x55, sizeof(receipt));
	ErgoptiTrace_Entry original_entry = entry; ErgoptiTrace_Receipt original_receipt = receipt;
	assert(ErgoptiTrace_Push(&s, OWNER + 1, TOKEN, 1, &RAW) == -4);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN + 1, 1, &RAW) == -5);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 2, &RAW) == -5);
	assert(ErgoptiTrace_Stop(&s, OWNER + 1, TOKEN, 1) == -4);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN + 1, 1, 0, 0, NULL, 0, &receipt) == -5);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 2, 0, 0, NULL, 0, &receipt) == -5);
	assert(ErgoptiTrace_Page(&s, OWNER + 1, TOKEN, 1, 0, 0, NULL, 0, &receipt) == -4);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, UINT32_MAX, 1, &entry, 1, &receipt) == -1);
	ErgoptiTrace_Event bad = RAW; bad.reserved = 1;
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &bad) == -1);
	bad = RAW; bad.decision = 7;
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &bad) == -1);
	assert(memcmp(&s, &before, sizeof(s)) == 0);
	assert(memcmp(&entry, &original_entry, sizeof(entry)) == 0);
	assert(memcmp(&receipt, &original_receipt, sizeof(receipt)) == 0);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 0);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 1, &entry, 0, &receipt) == -8);
	assert(memcmp(&entry, &original_entry, sizeof(entry)) == 0);
	assert(memcmp(&receipt, &original_receipt, sizeof(receipt)) == 0);
}
static void TestNoOverwriteAndStickyOverflow(void)
{
	ErgoptiTrace_State s; Begin(&s);
	for (uint32_t i = 0; i < 256; ++i) {
		ErgoptiTrace_Event e = RAW; e.capture_sequence = i;
		assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &e) == 0);
	}
	ErgoptiTrace_Entry first = s.entries[0], last = s.entries[255];
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 1);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 1);
	assert(s.attempted == 258 && s.dropped == 2 && s.count == 256 && s.overflow);
	assert(memcmp(&first, &s.entries[0], sizeof(first)) == 0);
	assert(memcmp(&last, &s.entries[255], sizeof(last)) == 0);
	ErgoptiTrace_Entry entry; ErgoptiTrace_Receipt receipt;
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 255, 1, &entry, 1, &receipt) == 1);
	assert(entry.sequence == 256 && entry.event.capture_sequence == 255);
	assert(receipt.dropped == 2 && receipt.attempted == 258 && receipt.overflow == 1);
	assert(ErgoptiTrace_Stop(&s, OWNER, TOKEN, 1) == 1);
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 0, NULL, 0, &receipt) == 1);
	assert(receipt.enabled == 0 && receipt.overflow == 1 && receipt.dropped == 2);
	assert(ErgoptiTrace_Start(&s, OWNER, TOKEN + 1, 2) == 0);
	assert(!s.overflow && s.dropped == 0 && s.next_sequence == 258);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN + 1, 2, &RAW) == 0);
	assert(s.entries[0].sequence == 259);
}
static void TestExplicitMissingEvidence(void)
{
	ErgoptiTrace_State s; Begin(&s);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 0);
	assert(ErgoptiTrace_RecordDrop(&s, OWNER, TOKEN + 1, 1) == -5);
	assert(!s.overflow && s.attempted == 1 && s.dropped == 0);
	assert(ErgoptiTrace_RecordDrop(&s, OWNER, TOKEN, 1) == 1);
	assert(s.attempted == 2 && s.dropped == 1 && s.count == 1);
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 1);
	assert(s.entries[0].sequence == 1 && s.entries[1].sequence == 3 && s.count == 2);
	ErgoptiTrace_Receipt receipt;
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 0, NULL, 0, &receipt) == 1);
	assert(receipt.stored == 2 && receipt.attempted == 3 && receipt.dropped == 1);
	assert(ErgoptiTrace_Stop(&s, OWNER, TOKEN, 1) == 1);
	assert(ErgoptiTrace_RecordDrop(&s, OWNER, TOKEN, 1) == 2);
	assert(s.attempted == 3 && s.dropped == 1);
}

static void TestCounterExhaustion(void)
{
	ErgoptiTrace_State s; Begin(&s); s.next_sequence = UINT64_MAX;
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 1);
	assert(s.count == 0 && s.attempted == 1 && s.dropped == 1 && s.overflow);
	ErgoptiTrace_Receipt receipt;
	assert(ErgoptiTrace_Page(&s, OWNER, TOKEN, 1, 0, 0, NULL, 0, &receipt) == 1);
	assert(receipt.first_sequence == 0 && receipt.last_sequence == 0);
	s.attempted = UINT64_MAX; s.dropped = UINT64_MAX;
	assert(ErgoptiTrace_Push(&s, OWNER, TOKEN, 1, &RAW) == 1);
	assert(s.attempted == UINT64_MAX && s.dropped == UINT64_MAX && s.next_sequence == UINT64_MAX);
}
int main(void)
{
	TestDefaultAndLifecycle(); puts("PASS trace default-disabled and explicit session lifecycle");
	TestLiteralRawAndReadOnly(); puts("PASS trace high-bit raw values and immutable exact pages");
	TestIdentityAndMalformed(); puts("PASS trace identity, malformed event and output preservation");
	TestNoOverwriteAndStickyOverflow(); puts("PASS trace capacity, retained drop counts and sticky overflow");
	TestCounterExhaustion(); puts("PASS trace exhausted counters never wrap or qualify");
	TestExplicitMissingEvidence(); puts("PASS trace explicit missing evidence is sticky without payload retention");
	puts("PASS hook trace: 6 matrices; native Windows hooks UNRUN");
	return 0;
}
