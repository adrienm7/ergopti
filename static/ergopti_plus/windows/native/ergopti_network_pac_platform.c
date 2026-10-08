/* Native DNS, adapter inventory and Windows address-selection order only. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <mstcpip.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "ergopti_network_pac_platform.h"

static uint64_t native_tick(void *owner)
{
	(void)owner;
	return (uint64_t)GetTickCount64();
}

static int append_ip_address(int family, const void *source, char *output, size_t capacity)
{
	char text[INET6_ADDRSTRLEN];
	size_t used = strlen(output), bytes;
	if (InetNtopA(family, (void *)source, text, sizeof(text)) == NULL) return -1;
	bytes = strlen(text);
	if (used >= capacity || bytes >= capacity - used || (used > 0 && bytes >= capacity - used - 1)) return -1;
	if (used > 0) output[used++] = ';';
	memcpy(output + used, text, bytes + 1);
	return 1;
}

static int append_address(const SOCKADDR *address, char *output, size_t capacity, int extended)
{
	if (address->sa_family == AF_INET)
		return append_ip_address(AF_INET, &((const SOCKADDR_IN *)address)->sin_addr, output, capacity);
	if (address->sa_family == AF_INET6 && extended)
		return append_ip_address(AF_INET6, &((const SOCKADDR_IN6 *)address)->sin6_addr, output, capacity);
	return 0;
}

static WCHAR *wide_argument(const char *argument)
{
	int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argument, -1, NULL, 0);
	WCHAR *wide;
	if (count <= 0 || (size_t)count > SIZE_MAX / sizeof(WCHAR)) return NULL;
	wide = (WCHAR *)malloc((size_t)count * sizeof(WCHAR));
	if (wide == NULL) { SetLastError(0); return NULL; }
	if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argument, -1, wide, count) != count) {
		free(wide); return NULL;
	}
	return wide;
}

typedef struct {
	OVERLAPPED overlapped;
	HANDLE cancellation;
	ADDRINFOEXW hints;
	ADDRINFOEXW *addresses;
	WCHAR *wide;
	TIMEVAL timeout;
} dns_operation;

static DWORD dns_remaining(const ergopti_windows_pac_owner *state)
{
	uint64_t now = native_tick(NULL), remaining;
	if (now >= state->limits->deadline_tick) return 0;
	remaining = state->limits->deadline_tick - now;
	return remaining > INT_MAX ? (DWORD)INT_MAX : (DWORD)remaining;
}

static int native_dns(void *owner, const char *host, int extended, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	ergopti_windows_pac_owner *state = (ergopti_windows_pac_owner *)owner;
	dns_operation *operation;
	ADDRINFOEXW *current;
	uint64_t now = native_tick(owner), remaining;
	size_t seen = 0;
	int status, admitted = 0, interrupted = 0;
	if (now >= state->limits->deadline_tick) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	remaining = state->limits->deadline_tick - now;
	if (remaining / 1000 > LONG_MAX) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	operation = (dns_operation *)calloc(1, sizeof(*operation));
	if (operation == NULL) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	operation->timeout.tv_sec = (long)(remaining / 1000);
	operation->timeout.tv_usec = (long)((remaining % 1000) * 1000);
	operation->wide = wide_argument(host);
	if (operation->wide == NULL) {
		error->code = (int32_t)GetLastError(); error->domain = error->code == 0 ? ERGOPTI_PAC_ERROR_NONE : ERGOPTI_PAC_ERROR_WIN32;
		free(operation); return -1;
	}
	operation->overlapped.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (operation->overlapped.hEvent == NULL) {
		error->code = (int32_t)GetLastError(); error->domain = error->code == 0 ? ERGOPTI_PAC_ERROR_NONE : ERGOPTI_PAC_ERROR_WIN32;
		free(operation->wide); free(operation); return -1;
	}
	operation->hints.ai_family = extended ? AF_UNSPEC : AF_INET;
	operation->hints.ai_socktype = SOCK_STREAM;
	/* Use the documented Unicode overlapped event API and retain its
	 * timeout and referenced storage until physical completion. */
	status = GetAddrInfoExW(operation->wide, NULL, NS_DNS, NULL, &operation->hints,
		&operation->addresses, &operation->timeout, &operation->overlapped, NULL, &operation->cancellation);
	if (status == WSA_IO_PENDING) {
		DWORD completed = WaitForSingleObject(operation->overlapped.hEvent, dns_remaining(state));
		if (completed != WAIT_OBJECT_0) {
			int cancelled;
			interrupted = 1;
			if (completed == WAIT_FAILED) {
				error->code = (int32_t)GetLastError();
				error->domain = error->code == 0 ? ERGOPTI_PAC_ERROR_NONE : ERGOPTI_PAC_ERROR_WIN32;
			}
			cancelled = GetAddrInfoExCancel(&operation->cancellation);
			completed = WaitForSingleObject(operation->overlapped.hEvent, dns_remaining(state));
			if (completed != WAIT_OBJECT_0) {
				/* Cancellation is not completion. Retain every native-referenced
				 * byte and handle until the private evaluator process is gone;
				 * the external Job owner proves that physical containment fence. */
				_Exit(EXIT_FAILURE);
			}
			if (cancelled != 0 && cancelled != WSA_INVALID_HANDLE && error->code == 0) {
				error->code = cancelled; error->domain = ERGOPTI_PAC_ERROR_WINSOCK;
			}
		}
		status = GetAddrInfoExOverlappedResult(&operation->overlapped);
		if (status == WSAEINPROGRESS || status == WSA_IO_PENDING || status == WSA_IO_INCOMPLETE) {
			/* An unacknowledged operation must never publish an empty/success
			 * result or release its OVERLAPPED storage while a provider owns it. */
			_Exit(EXIT_FAILURE);
		}
	}
	if (interrupted || error->code != 0) { admitted = -1; goto closed; }
	if (status != 0) {
		if (status == WSAHOST_NOT_FOUND || status == WSANO_DATA || status == WSATRY_AGAIN) goto closed;
		error->code = status; error->domain = ERGOPTI_PAC_ERROR_WINSOCK; admitted = -1; goto closed;
	}
	for (current = operation->addresses; current != NULL; current = current->ai_next) {
		int added;
		if (++seen > state->limits->max_native_queries) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; break; }
		if (current->ai_addr == NULL || (current->ai_family == AF_INET && current->ai_addrlen < sizeof(SOCKADDR_IN)) ||
			(current->ai_family == AF_INET6 && current->ai_addrlen < sizeof(SOCKADDR_IN6))) {
			error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; break;
		}
		added = append_address(current->ai_addr, output, capacity, extended);
		if (added < 0) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; break; }
		if (added > 0) { admitted = 1; if (!extended) break; }
	}
closed:
	if (operation->addresses != NULL) FreeAddrInfoExW(operation->addresses);
	if (!CloseHandle(operation->overlapped.hEvent)) {
		error->code = (int32_t)GetLastError(); error->domain = error->code == 0 ? ERGOPTI_PAC_ERROR_NONE : ERGOPTI_PAC_ERROR_WIN32;
		admitted = -1;
	}
	free(operation->wide); free(operation);
	return admitted;
}

static int native_local_addresses(void *owner, int extended, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	ergopti_windows_pac_owner *state = (ergopti_windows_pac_owner *)owner;
	IP_ADAPTER_ADDRESSES *adapters, *adapter;
	ULONG bytes = 0, status;
	size_t seen = 0;
	int admitted = 0;
	status = GetAdaptersAddresses(extended ? AF_UNSPEC : AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, NULL, NULL, &bytes);
	if (status == ERROR_NO_DATA) return 0;
	if (status != ERROR_BUFFER_OVERFLOW || bytes == 0 || bytes > state->limits->max_input_bytes) {
		error->code = status == ERROR_BUFFER_OVERFLOW ? 0 : (int32_t)status; error->domain = error->code == 0 ? ERGOPTI_PAC_ERROR_NONE : ERGOPTI_PAC_ERROR_WIN32; return -1;
	}
	adapters = (IP_ADAPTER_ADDRESSES *)malloc(bytes);
	if (adapters == NULL) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	status = GetAdaptersAddresses(extended ? AF_UNSPEC : AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, NULL, adapters, &bytes);
	if (status != NO_ERROR) { error->code = (int32_t)status; error->domain = ERGOPTI_PAC_ERROR_WIN32; free(adapters); return -1; }
	for (adapter = adapters; adapter != NULL; adapter = adapter->Next) {
		IP_ADAPTER_UNICAST_ADDRESS *address;
		if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
		for (address = adapter->FirstUnicastAddress; address != NULL; address = address->Next) {
			int added;
			if (++seen > state->limits->max_native_queries) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; goto closed; }
			if (address->DadState != IpDadStatePreferred || address->Address.lpSockaddr == NULL) continue;
			if ((address->Address.lpSockaddr->sa_family == AF_INET && address->Address.iSockaddrLength < (int)sizeof(SOCKADDR_IN)) ||
				(address->Address.lpSockaddr->sa_family == AF_INET6 && address->Address.iSockaddrLength < (int)sizeof(SOCKADDR_IN6))) {
				error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; goto closed;
			}
			added = append_address(address->Address.lpSockaddr, output, capacity, extended);
			if (added < 0) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; admitted = -1; goto closed; }
			if (added > 0) { admitted = 1; if (!extended) goto closed; }
		}
	}
closed:
	free(adapters);
	return admitted;
}

static int native_sort_addresses(void *owner, const char *addresses, char *output, size_t capacity, ergopti_pac_native_error *error)
{
	ergopti_windows_pac_owner *state = (ergopti_windows_pac_owner *)owner;
	size_t count = 1, index, bytes, table_bytes;
	const char *cursor;
	SOCKET_ADDRESS_LIST *input = NULL, *ordered = NULL;
	SOCKADDR_IN6 *items = NULL;
	SOCKET socket_owner = INVALID_SOCKET;
	DWORD returned = 0;
	int admitted = -1;
	for (cursor = addresses; *cursor != 0; cursor++) if (*cursor == ';') count++;
	if (count > state->limits->max_native_queries || count > INT_MAX) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	if (count > (SIZE_MAX - offsetof(SOCKET_ADDRESS_LIST, Address)) / sizeof(SOCKET_ADDRESS)) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	table_bytes = offsetof(SOCKET_ADDRESS_LIST, Address) + count * sizeof(SOCKET_ADDRESS);
	if (count > (SIZE_MAX - table_bytes) / sizeof(SOCKADDR_IN6)) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	bytes = table_bytes + count * sizeof(SOCKADDR_IN6);
	if (bytes > ULONG_MAX) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; return -1; }
	input = (SOCKET_ADDRESS_LIST *)calloc(1, bytes); ordered = (SOCKET_ADDRESS_LIST *)calloc(1, bytes);
	if (input == NULL || ordered == NULL) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; goto closed; }
	items = (SOCKADDR_IN6 *)((unsigned char *)input + table_bytes);
	input->iAddressCount = (INT)count; cursor = addresses;
	for (index = 0; index < count; index++) {
		const char *separator = strchr(cursor, ';');
		size_t length = separator == NULL ? strlen(cursor) : (size_t)(separator - cursor);
		char value[INET6_ADDRSTRLEN];
		IN_ADDR ipv4;
		if (length == 0 || length >= sizeof(value)) { admitted = 0; goto closed; }
		memcpy(value, cursor, length); value[length] = 0;
		items[index].sin6_family = AF_INET6;
		if (InetPtonA(AF_INET6, value, &items[index].sin6_addr) != 1) {
			if (InetPtonA(AF_INET, value, &ipv4) != 1) { admitted = 0; goto closed; }
			items[index].sin6_addr.u.Byte[10] = 255; items[index].sin6_addr.u.Byte[11] = 255;
			memcpy(&items[index].sin6_addr.u.Byte[12], &ipv4, sizeof(ipv4));
		}
		input->Address[index].lpSockaddr = (SOCKADDR *)&items[index]; input->Address[index].iSockaddrLength = (int)sizeof(SOCKADDR_IN6);
		cursor = separator == NULL ? cursor + length : separator + 1;
	}
	socket_owner = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
	if (socket_owner == INVALID_SOCKET) { error->code = WSAGetLastError(); error->domain = ERGOPTI_PAC_ERROR_WINSOCK; goto closed; }
	if (WSAIoctl(socket_owner, SIO_ADDRESS_LIST_SORT, input, (DWORD)bytes, ordered, (DWORD)bytes, &returned, NULL, NULL) != 0) {
		error->code = WSAGetLastError(); error->domain = ERGOPTI_PAC_ERROR_WINSOCK; goto closed;
	}
	if (returned < table_bytes || returned > bytes || ordered->iAddressCount != (INT)count) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; goto closed; }
	for (index = 0; index < count; index++) {
		SOCKADDR_IN6 *address = (SOCKADDR_IN6 *)ordered->Address[index].lpSockaddr;
		uintptr_t pointer = (uintptr_t)address, first = (uintptr_t)items;
		IN_ADDR ipv4;
		int added;
		if (ordered->Address[index].iSockaddrLength != (int)sizeof(SOCKADDR_IN6) || pointer < first ||
			pointer - first >= count * sizeof(SOCKADDR_IN6) || (pointer - first) % sizeof(SOCKADDR_IN6) != 0) {
			error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; goto closed;
		}
		if (IN6_IS_ADDR_V4MAPPED(&address->sin6_addr)) {
			/* Keep the mapped address typed: do not re-read a different
			 * structure's family through an incompatible SOCKADDR alias. */
			memcpy(&ipv4, &address->sin6_addr.u.Byte[12], sizeof(ipv4));
			added = append_ip_address(AF_INET, &ipv4, output, capacity);
		} else added = append_address((SOCKADDR *)address, output, capacity, 1);
		if (added != 1) { error->code = 0; error->domain = ERGOPTI_PAC_ERROR_NONE; goto closed; }
	}
	admitted = 1;
closed:
	if (socket_owner != INVALID_SOCKET && closesocket(socket_owner) != 0) { error->code = WSAGetLastError(); error->domain = ERGOPTI_PAC_ERROR_WINSOCK; admitted = -1; }
	free(ordered); free(input);
	return admitted;
}

ergopti_pac_platform ergopti_windows_pac_platform(ergopti_windows_pac_owner *owner)
{
	ergopti_pac_platform result = {owner, native_tick, native_dns, native_local_addresses, native_sort_addresses};
	return result;
}
