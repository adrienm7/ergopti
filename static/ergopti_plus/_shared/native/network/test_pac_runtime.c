/* Actual VM tests with controlled platform ports; these do not qualify DNS. */
#include "pac_runtime.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t tick; int advance; int fail; ergopti_pac_error_domain domain; } fixture;
static uint64_t tick(void *owner)
{
	fixture *state = (fixture *)owner;
	uint64_t observed = state->tick;
	if (state->advance) state->tick++;
	return observed;
}
static int dns(void *owner, const char *host, int extended, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	fixture *state = (fixture *)owner;
	const char *value = extended ? "192.0.2.9;2001:db8::9" : "192.0.2.9";
	if (state->fail) { error->code = 11002; error->domain = state->domain; return -1; }
	if (strcmp(host, "owned.invalid") != 0) return 0;
	assert(capacity > strlen(value)); strcpy(output, value); return 1;
}
static int local(void *owner, int extended, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	return dns(owner, "owned.invalid", extended, output, capacity, error);
}
static int sort(void *owner, const char *input, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	(void)owner; (void)error;
	assert(capacity > strlen(input)); strcpy(output, input); return 1;
}
static char *read_file(const char *path, size_t *bytes)
{
	FILE *file = fopen(path, "rb");
	long length;
	char *contents;
	assert(file != NULL && fseek(file, 0, SEEK_END) == 0);
	length = ftell(file); assert(length > 0 && length < 65536);
	assert(fseek(file, 0, SEEK_SET) == 0);
	contents = (char *)malloc((size_t)length + 1); assert(contents != NULL);
	assert(fread(contents, 1, (size_t)length, file) == (size_t)length);
	assert(fclose(file) == 0); contents[length] = 0; *bytes = (size_t)length;
	return contents;
}
int main(int argc, char **argv)
{
	fixture state = {100, 0, 0, ERGOPTI_PAC_ERROR_WINSOCK};
	ergopti_pac_platform platform = {&state, tick, dns, local, sort};
	ergopti_pac_limits limits = {200, 2097152, 65536, 65536, 65536, 128};
	const char *url = "https://ordered-fixture.invalid:8443/first?marker=private";
	const char *host = "ordered-fixture.invalid";
	const char *script;
	char output[65537];
	char *helpers;
	size_t helper_bytes;
	ergopti_pac_receipt receipt;
	assert(argc == 2); helpers = read_file(argv[1], &helper_bytes);
#define RUN(body) ergopti_pac_execute(&platform, &limits, helpers, helper_bytes, (body), strlen(body), url, strlen(url), host, strlen(host), output, sizeof(output))
#define CLOSED() assert(receipt.retained_heap_bytes == 0 && receipt.peak_heap_bytes <= limits.max_heap_bytes)
	script = "function FindProxyForURL(url,host){if(url==='https://ordered-fixture.invalid:8443/first?marker=private')return 'PROXY first.invalid:38101; PROXY second.invalid:38102; DIRECT';return 'DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OK);
	assert(strcmp(output, "PROXY first.invalid:38101; PROXY second.invalid:38102; DIRECT") == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return 'PROXY first.invalid:38101; DIRECT; PROXY second.invalid:38102';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OK);
	assert(strcmp(output, "PROXY first.invalid:38101; DIRECT; PROXY second.invalid:38102") == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return 'DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OK && strcmp(output, "DIRECT") == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return 'PROXY second.invalid:38102; PROXY first.invalid:38101; DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OK);
	assert(strcmp(output, "PROXY second.invalid:38102; PROXY first.invalid:38101; DIRECT") == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return 1;}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OUTPUT_REFUSED && output[0] == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return 'DIRECT\\x00PROXY hidden.invalid:1';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OUTPUT_REFUSED && output[0] == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return new Array(65539).join('x');}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OUTPUT_REFUSED && output[0] == 0); CLOSED();
	script = "function FindProxyForURL(url,host){return isInNetEx(dnsResolveEx('owned.invalid'),'2001:db8::/32')?'DIRECT':'PROXY wrong.invalid:1';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_OK && receipt.native_queries == 1 && strcmp(output, "DIRECT") == 0); CLOSED();
	state.fail = 1;
	script = "function FindProxyForURL(url,host){try{dnsResolve('owned.invalid');}catch(e){}return 'DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_NATIVE_REFUSED && receipt.native_error == 11002 && output[0] == 0); CLOSED();
	assert(receipt.native_error_domain == ERGOPTI_PAC_ERROR_WINSOCK);
	/* The identical numeric error from the same callback carries its actual API domain.
	 * A DNS port may fail in Win32 UTF conversion before reaching a Winsock lookup. */
	state.domain = ERGOPTI_PAC_ERROR_WIN32;
	receipt = RUN(script);
	assert(receipt.status == ERGOPTI_PAC_NATIVE_REFUSED && receipt.native_error == 11002);
	assert(receipt.native_error_domain == ERGOPTI_PAC_ERROR_WIN32 && output[0] == 0); CLOSED();
	state.domain = ERGOPTI_PAC_ERROR_POSIX;
	receipt = RUN(script);
	assert(receipt.status == ERGOPTI_PAC_NATIVE_REFUSED && receipt.native_error == 11002);
	assert(receipt.native_error_domain == ERGOPTI_PAC_ERROR_POSIX && output[0] == 0); CLOSED();
	state.domain = (ergopti_pac_error_domain)4;
	receipt = RUN(script);
	assert(receipt.status == ERGOPTI_PAC_NATIVE_REFUSED && receipt.native_error == 11002);
	assert(receipt.native_error_domain == ERGOPTI_PAC_ERROR_NONE && output[0] == 0); CLOSED();
	state.domain = ERGOPTI_PAC_ERROR_WINSOCK;
	state.fail = 0; limits.max_native_queries = 1;
	script = "function FindProxyForURL(url,host){dnsResolve('owned.invalid');dnsResolve('owned.invalid');return 'DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_NATIVE_REFUSED && receipt.native_queries == 1 && output[0] == 0); CLOSED();
	limits.max_native_queries = 128;
	script = "function FindProxyForURL(url,host){throw new Error('private credentials');}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_SCRIPT_REFUSED && output[0] == 0); CLOSED();
	state.advance = 1; limits.deadline_tick = state.tick + 5;
	script = "function FindProxyForURL(url,host){while(true){}return 'DIRECT';}";
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_BUDGET_EXPIRED && output[0] == 0); CLOSED();
	state.advance = 0; limits.deadline_tick = state.tick;
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_BUDGET_EXPIRED && output[0] == 0); CLOSED();
	limits.deadline_tick = state.tick + 100; limits.max_heap_bytes = 1;
	receipt = RUN(script); assert(receipt.status == ERGOPTI_PAC_MEMORY_REFUSED && output[0] == 0); CLOSED();
	free(helpers);
	puts("PASS 17 actual Duktape PAC core cases; controlled platform ports are not native DNS acceptance.");
	return 0;
}
