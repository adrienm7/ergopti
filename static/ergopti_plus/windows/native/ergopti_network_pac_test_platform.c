/* Real Windows APIs, without editing DNS, proxy settings, interfaces or trust. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef ERGOPTI_PAC_PLATFORM_DIAGNOSTICS
#include <stdlib.h>
#include <stddef.h>
#endif
#include "ergopti_network_pac_platform.h"
#include "pac_generated.h"

static void require(int admitted, const char *stage, int32_t error)
{
	if (admitted) return;
	/* Fixed stage and native integer only; never print captured network metadata. */
	fprintf(stderr, "NATIVE_PAC_PLATFORM_DIAG stage=%s native_error=%ld\n", stage, (long)error);
#ifdef ERGOPTI_PAC_PLATFORM_DIAGNOSTICS
	/* ExitProcess does not run the C stream flush; publish notices first. */
	(void)fflush(stdout);
#endif
	ExitProcess(1);
}

#ifdef ERGOPTI_PAC_PLATFORM_DIAGNOSTICS
/* Independent literal-vector ABI probe. No captured network data or raw pointers. */
static void diagnose_sort_shape(void)
{
	const size_t count = 2;
	size_t table = offsetof(SOCKET_ADDRESS_LIST, Address) + count * sizeof(SOCKET_ADDRESS);
	size_t bytes = table + count * sizeof(SOCKADDR_IN6), index;
	SOCKET_ADDRESS_LIST *input = (SOCKET_ADDRESS_LIST *)calloc(1, bytes);
	SOCKET_ADDRESS_LIST *output = (SOCKET_ADDRESS_LIST *)calloc(1, bytes);
	SOCKADDR_IN6 *items;
	SOCKET socket_owner = INVALID_SOCKET;
	DWORD returned = 0;
	int status, native_error;
	if (input == NULL || output == NULL) {
		fputs("::notice::NATIVE_PAC_SORT_SHAPE allocation=refused\n", stdout); goto closed;
	}
	items = (SOCKADDR_IN6 *)((unsigned char *)input + table);
	input->iAddressCount = (INT)count;
	items[0].sin6_family = items[1].sin6_family = AF_INET6;
	if (InetPtonA(AF_INET6, "::ffff:127.0.0.1", &items[0].sin6_addr) != 1 ||
		InetPtonA(AF_INET6, "::1", &items[1].sin6_addr) != 1) {
		fputs("::notice::NATIVE_PAC_SORT_SHAPE literal_parse=refused\n", stdout); goto closed;
	}
	for (index = 0; index < count; index++) {
		input->Address[index].lpSockaddr = (SOCKADDR *)&items[index];
		input->Address[index].iSockaddrLength = (int)sizeof(SOCKADDR_IN6);
	}
	socket_owner = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
	if (socket_owner == INVALID_SOCKET) {
		fprintf(stdout, "::notice::NATIVE_PAC_SORT_SHAPE socket_error=%d\n", WSAGetLastError()); goto closed;
	}
	status = WSAIoctl(socket_owner, SIO_ADDRESS_LIST_SORT, input, (DWORD)bytes, output, (DWORD)bytes, &returned, NULL, NULL);
	native_error = status == 0 ? 0 : WSAGetLastError();
	fprintf(stdout, "::notice::NATIVE_PAC_SORT_SHAPE status=%d error=%d returned=%lu table=%llu allocated=%llu count=%d\n",
		status, native_error, (unsigned long)returned, (unsigned long long)table, (unsigned long long)bytes,
		returned >= sizeof(INT) && returned <= bytes ? output->iAddressCount : -1);
	if (status == 0 && returned >= table && returned <= bytes && output->iAddressCount >= 0 && output->iAddressCount <= (INT)count) {
		for (index = 0; index < (size_t)output->iAddressCount; index++) {
			uintptr_t pointer = (uintptr_t)output->Address[index].lpSockaddr;
			uintptr_t first_input = (uintptr_t)items, first_output = (uintptr_t)((unsigned char *)output + table);
			int input_owned = pointer >= first_input && pointer - first_input < count * sizeof(SOCKADDR_IN6) &&
				(pointer - first_input) % sizeof(SOCKADDR_IN6) == 0;
			int output_owned = returned >= table + sizeof(SOCKADDR_IN6) && pointer >= first_output &&
				pointer - first_output <= (size_t)returned - table - sizeof(SOCKADDR_IN6);
			fprintf(stdout, "::notice::NATIVE_PAC_SORT_SHAPE index=%llu sockaddr_bytes=%d input_owned=%d output_owned=%d\n",
				(unsigned long long)index, output->Address[index].iSockaddrLength, input_owned, output_owned);
			if ((input_owned || (output_owned && pointer % _Alignof(SOCKADDR_IN6) == 0)) &&
				output->Address[index].iSockaddrLength == (int)sizeof(SOCKADDR_IN6)) {
				SOCKADDR_IN6 *address = (SOCKADDR_IN6 *)output->Address[index].lpSockaddr;
				char text[INET6_ADDRSTRLEN];
				SOCKADDR_IN ipv4;
				const void *source;
				int family = address->sin6_family, mapped = 0;
				int converted, conversion_error;
				if (family == AF_INET6 && IN6_IS_ADDR_V4MAPPED(&address->sin6_addr)) {
					mapped = 1; memset(&ipv4, 0, sizeof(ipv4)); ipv4.sin_family = AF_INET;
					memcpy(&ipv4.sin_addr, &address->sin6_addr.u.Byte[12], sizeof(ipv4.sin_addr));
					family = AF_INET; source = &ipv4.sin_addr;
				} else source = &address->sin6_addr;
				converted = InetNtopA(family, (void *)source, text, sizeof(text)) != NULL;
				conversion_error = converted ? 0 : WSAGetLastError();
				fprintf(stdout, "::notice::NATIVE_PAC_SORT_SHAPE index=%llu input_slot=%llu family=%d mapped=%d converted=%d conversion_error=%d ipv4_loopback=%d ipv6_loopback=%d\n",
					(unsigned long long)index,
					input_owned ? (unsigned long long)((pointer - first_input) / sizeof(SOCKADDR_IN6)) : (unsigned long long)count,
					(int)address->sin6_family, mapped, converted, conversion_error,
					converted && strcmp(text, "127.0.0.1") == 0, converted && strcmp(text, "::1") == 0);
			}
		}
	}
closed:
	if (socket_owner != INVALID_SOCKET && closesocket(socket_owner) != 0)
		fprintf(stdout, "::notice::NATIVE_PAC_SORT_SHAPE socket_retirement_error=%d\n", WSAGetLastError());
	free(output); free(input);
}
#endif

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
#ifdef ERGOPTI_PAC_PLATFORM_DIAGNOSTICS
	if (status != 1 || (strcmp(output, "127.0.0.1;::1") != 0 && strcmp(output, "::1;127.0.0.1") != 0)) {
		fprintf(stdout, "::notice::NATIVE_PAC_SORT_RECEIVING status=%d error=%ld domain=%d output_bytes=%llu forward_literal=%d reverse_literal=%d\n",
			status, (long)error.code, (int)error.domain, (unsigned long long)strlen(output),
			strcmp(output, "127.0.0.1;::1") == 0, strcmp(output, "::1;127.0.0.1") == 0);
		diagnose_sort_shape();
	}
#endif
	require(status == 1 && (strcmp(output, "127.0.0.1;::1") == 0 || strcmp(output, "::1;127.0.0.1") == 0), "native_address_sort", error.code);
	memset(output, 0, sizeof(output)); error.code = 0; error.domain = ERGOPTI_PAC_ERROR_NONE;
	status = platform.sort_addresses(platform.owner, "invalid-address", output, sizeof(output), &error);
	require(status == 0 && error.code == 0 && error.domain == ERGOPTI_PAC_ERROR_NONE, "invalid_address_refusal", error.code);
	require(WSACleanup() == 0, "winsock_retirement", WSAGetLastError());
	puts("PASS 6 actual Windows PAC platform cases and exact Winsock retirement.");
	return 0;
}
