/* Real Windows APIs, without editing DNS, proxy settings, interfaces or trust. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "ergopti_network_pac_platform.h"
#include "pac_generated.h"

static void require(int admitted, const char *stage, int32_t error)
{
	if (admitted) return;
	/* Fixed stage and native integer only; never print captured network metadata. */
	fprintf(stderr, "NATIVE_PAC_PLATFORM_DIAG stage=%s native_error=%ld\n", stage, (long)error);
	ExitProcess(1);
}

int main(void)
{
	ergopti_pac_limits limits = {0, ERGOPTI_PAC_HEAP_BYTES, ERGOPTI_PAC_SCRIPT_BYTES,
		ERGOPTI_PAC_INPUT_BYTES, ERGOPTI_PAC_OUTPUT_BYTES, ERGOPTI_PAC_NATIVE_QUERIES};
	ergopti_windows_pac_owner owner = {&limits};
	ergopti_pac_platform platform = ergopti_windows_pac_platform(&owner);
	WSADATA winsock;
	char output[ERGOPTI_PAC_OUTPUT_BYTES + 1];
	IN_ADDR ipv4;
	ergopti_pac_native_error error = {0, ERGOPTI_PAC_ERROR_NONE};
	int status;
	require(WSAStartup(MAKEWORD(2, 2), &winsock) == 0, "winsock_start", 0);
	limits.deadline_tick = platform.tick(platform.owner) + ERGOPTI_PAC_LOOKUP_MS;
	memset(output, 0, sizeof(output));
	status = platform.dns(platform.owner, "localhost", 0, output, sizeof(output), &error);
	require(status == 1 && InetPtonA(AF_INET, output, &ipv4) == 1 && ipv4.S_un.S_un_b.s_b1 == 127, "ipv4_loopback", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.dns(platform.owner, "localhost", 1, output, sizeof(output), &error);
	require(status == 1 && output[0] != 0, "extended_loopback", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.local_addresses(platform.owner, 0, output, sizeof(output), &error);
	require(status == 1 && InetPtonA(AF_INET, output, &ipv4) == 1 && ipv4.S_un.S_un_b.s_b1 != 127, "actual_interface_ipv4", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.local_addresses(platform.owner, 1, output, sizeof(output), &error);
	require(status == 1 && output[0] != 0, "actual_interface_extended", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.sort_addresses(platform.owner, "127.0.0.1;::1", output, sizeof(output), &error);
	require(status == 1 && (strcmp(output, "127.0.0.1;::1") == 0 || strcmp(output, "::1;127.0.0.1") == 0), "native_address_sort", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.sort_addresses(platform.owner, "invalid-address", output, sizeof(output), &error);
	require(status == 0 && error.code == 0 && error.domain == ERGOPTI_PAC_ERROR_NONE, "invalid_address_refusal", error.code);
	require(WSACleanup() == 0, "winsock_retirement", WSAGetLastError());
	puts("PASS 6 actual Windows PAC platform cases and exact Winsock retirement.");
	return 0;
}
