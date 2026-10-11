// tools/test/support/nav_event_owner_portable/runtime_test.c
/**
 * @file runtime_test.c
 * @brief Proves the test boundary really waits, locks and runs competing threads.
 */

#include "windows.h"

#include <assert.h>
#include <stdio.h>

static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_lock;
static unsigned g_initialized;
static unsigned g_counter;
static pthread_mutex_t g_gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_gate = PTHREAD_COND_INITIALIZER;
static BOOL g_released;

/** Initializes shared state once despite calls from both real thread contexts. */
static BOOL Initialize(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
	(void)once;
	(void)parameter;
	(void)context;
	++g_initialized;
	return InitializeCriticalSectionEx(&g_lock, 0, 0);
}

/** Cannot finish until its gate and the main thread's critical section release. */
static DWORD Worker(LPVOID parameter)
{
	(void)parameter;
	assert(InitOnceExecuteOnce(&g_once, Initialize, NULL, NULL));
	SetLastError(88);
	assert(pthread_mutex_lock(&g_gate_lock) == 0);
	while (!g_released)
		assert(pthread_cond_wait(&g_gate, &g_gate_lock) == 0);
	assert(pthread_mutex_unlock(&g_gate_lock) == 0);
	EnterCriticalSection(&g_lock);
	++g_counter;
	LeaveCriticalSection(&g_lock);
	assert(GetLastError() == 88);
	return 0;
}

/** Rejects a synchronous callback, a fake wait and missing lock exclusion. */
int main(void)
{
	HANDLE thread;
	unsigned char *allocation;
	unsigned index;
	assert(InitOnceExecuteOnce(&g_once, Initialize, NULL, NULL));
	SetLastError(77);
	EnterCriticalSection(&g_lock);
	EnterCriticalSection(&g_lock);
	LeaveCriticalSection(&g_lock);
	thread = CreateThread(NULL, 0, Worker, NULL, 0, NULL);
	assert(thread != NULL);
	assert(WaitForSingleObject(thread, 0) == WAIT_TIMEOUT);
	assert(pthread_mutex_lock(&g_gate_lock) == 0);
	g_released = TRUE;
	assert(pthread_cond_signal(&g_gate) == 0);
	assert(pthread_mutex_unlock(&g_gate_lock) == 0);
	assert(WaitForSingleObject(thread, 0) == WAIT_TIMEOUT);
	assert(g_counter == 0);
	LeaveCriticalSection(&g_lock);
	assert(WaitForSingleObject(thread, 5000) == WAIT_OBJECT_0);
	assert(g_initialized == 1 && g_counter == 1);
	assert(GetLastError() == 77);
	assert(WaitForSingleObject(thread, 0) == WAIT_OBJECT_0);
	assert(CloseHandle(thread));
	allocation = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, 64);
	assert(allocation != NULL);
	for (index = 0; index < 64; ++index)
		assert(allocation[index] == 0);
	assert(HeapFree(GetProcessHeap(), 0, allocation));
	puts("PASS portable boundary: real threads, exclusion, timeout, init-once, TLS and heap.");
	return 0;
}
