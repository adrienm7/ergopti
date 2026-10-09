/* Build-time consumer: static/ergopti_plus/_shared/modules/network/pac_helpers.js.
 * prepare_network_pac_sources.py embeds those exact bytes in pac_generated.h. */
/* Binary stdin/stdout keeps full URLs and PAC text outside the process argv. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ergopti_network_pac_platform.h"
#include "pac_generated.h"

static uint32_t read32(const unsigned char *bytes)
{
	return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}
static uint64_t read64(const unsigned char *bytes)
{
	return (uint64_t)read32(bytes) | ((uint64_t)read32(bytes + 4) << 32);
}
static void write32(unsigned char *bytes, uint32_t value)
{
	unsigned int index;
	for (index = 0; index < 4; index++) bytes[index] = (unsigned char)(value >> (index * 8));
}
static void write64(unsigned char *bytes, uint64_t value)
{
	write32(bytes, (uint32_t)value); write32(bytes + 4, (uint32_t)(value >> 32));
}
static char *read_owned_bytes(size_t bytes)
{
	char *owned;
	if (bytes == 0 || bytes == SIZE_MAX) return NULL;
	owned = (char *)malloc(bytes + 1);
	if (owned == NULL) return NULL;
	if (fread(owned, 1, bytes, stdin) != bytes) {
		SecureZeroMemory(owned, bytes + 1); free(owned); return NULL;
	}
	owned[bytes] = 0;
	return owned;
}
static void release_owned_bytes(char *owned, size_t bytes)
{
	if (owned == NULL) return;
	SecureZeroMemory(owned, bytes + 1); free(owned);
}

int main(int argc, char **argv)
{
	unsigned char input[28], frame[44];
	uint64_t now;
	size_t script_bytes, url_bytes, host_bytes;
	char *script = NULL, *url = NULL, *host = NULL, *output = NULL;
	ergopti_pac_limits limits = {0, ERGOPTI_PAC_HEAP_BYTES, ERGOPTI_PAC_SCRIPT_BYTES,
		ERGOPTI_PAC_INPUT_BYTES, ERGOPTI_PAC_OUTPUT_BYTES, ERGOPTI_PAC_NATIVE_QUERIES};
	ergopti_windows_pac_owner owner = {&limits};
	ergopti_pac_platform platform = ergopti_windows_pac_platform(&owner);
	ergopti_pac_receipt receipt;
	WSADATA winsock;
	int started = 0, result = 2;
	memset(&receipt, 0, sizeof(receipt)); receipt.status = ERGOPTI_PAC_INVALID_INPUT;
	if (argc == 2 && strcmp(argv[1], "--identity") == 0) {
		printf("{\"schema_version\":1,\"duktape_version\":20700,\"source_fingerprint\":\"%s\"}\n", ERGOPTI_PAC_SOURCE_FINGERPRINT);
		return fflush(stdout) == 0 ? 0 : 2;
	}
	if (argc != 1 || _setmode(_fileno(stdin), _O_BINARY) < 0 || _setmode(_fileno(stdout), _O_BINARY) < 0) return 2;
	if (fread(input, 1, sizeof(input), stdin) != sizeof(input) || memcmp(input, "ERGOPAC1", 8) != 0) return 2;
	limits.deadline_tick = read64(input + 8);
	script_bytes = read32(input + 16); url_bytes = read32(input + 20); host_bytes = read32(input + 24);
	if (script_bytes == 0 || script_bytes > limits.max_script_bytes || url_bytes == 0 ||
		url_bytes > limits.max_input_bytes || host_bytes == 0 || host_bytes > limits.max_input_bytes) return 2;
	now = (uint64_t)GetTickCount64();
	if (limits.deadline_tick <= now || limits.deadline_tick - now > ERGOPTI_PAC_LOOKUP_MS) return 2;
	script = read_owned_bytes(script_bytes); url = read_owned_bytes(url_bytes); host = read_owned_bytes(host_bytes);
	output = (char *)calloc(limits.max_output_bytes + 1, 1);
	if (script == NULL || url == NULL || host == NULL || output == NULL || fgetc(stdin) != EOF || ferror(stdin)) goto closed;
	receipt.native_error = WSAStartup(MAKEWORD(2, 2), &winsock);
	if (receipt.native_error != 0) receipt.native_error_domain = ERGOPTI_PAC_ERROR_WINSOCK;
	if (receipt.native_error != 0) { receipt.status = ERGOPTI_PAC_NATIVE_REFUSED; goto report; }
	started = 1;
	if (winsock.wVersion != MAKEWORD(2, 2)) { receipt.status = ERGOPTI_PAC_NATIVE_REFUSED; goto report; }
	receipt = ergopti_pac_execute(&platform, &limits, (const char *)ergopti_pac_helpers, sizeof(ergopti_pac_helpers),
		script, script_bytes, url, url_bytes, host, host_bytes, output, limits.max_output_bytes + 1);
report:
	if (started) {
		if (WSACleanup() != 0) { receipt.status = ERGOPTI_PAC_NATIVE_REFUSED; receipt.native_error = WSAGetLastError(); receipt.native_error_domain = ERGOPTI_PAC_ERROR_WINSOCK; receipt.output_bytes = 0; }
		started = 0;
	}
	if (receipt.retained_heap_bytes != 0) { receipt.status = ERGOPTI_PAC_MEMORY_REFUSED; receipt.output_bytes = 0; }
	if ((uint64_t)GetTickCount64() >= limits.deadline_tick) { receipt.status = ERGOPTI_PAC_BUDGET_EXPIRED; receipt.output_bytes = 0; }
	if (receipt.status != ERGOPTI_PAC_OK) receipt.output_bytes = 0;
	memset(frame, 0, sizeof(frame)); memcpy(frame, "ERGOPAC3", 8);
	write32(frame + 8, (uint32_t)receipt.status); write32(frame + 12, (uint32_t)receipt.native_error);
	write32(frame + 16, (uint32_t)receipt.output_bytes); write64(frame + 20, receipt.peak_heap_bytes);
	write64(frame + 28, receipt.retained_heap_bytes); write32(frame + 36, (uint32_t)receipt.native_queries); write32(frame + 40, (uint32_t)receipt.native_error_domain);
	if (fwrite(frame, 1, sizeof(frame), stdout) != sizeof(frame) ||
		(receipt.output_bytes > 0 && fwrite(output, 1, receipt.output_bytes, stdout) != receipt.output_bytes) || fflush(stdout) != 0) goto closed;
	result = 0;
closed:
	if (started && WSACleanup() != 0) result = 2;
	release_owned_bytes(script, script_bytes); release_owned_bytes(url, url_bytes); release_owned_bytes(host, host_bytes);
	release_owned_bytes(output, limits.max_output_bytes);
	return result;
}
