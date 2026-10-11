// tools/test/support/nav_event_owner_portable/runtime.c
/**
 * @file runtime.c
 * @brief Real POSIX synchronization for portable navigation state-machine tests.
 */

#include "windows.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "editor_replace.h"

/** A thread owns its completion condition until the caller joins and closes it. */
typedef struct PortableThread {
	pthread_t thread;
	pthread_mutex_t mutex;
	pthread_cond_t completed;
	DWORD (*entry)(LPVOID);
	LPVOID parameter;
	bool done;
	bool joined;
} PortableThread;

static _Thread_local DWORD g_error;
static pthread_mutex_t g_editor_fence = PTHREAD_MUTEX_INITIALIZER;
static int g_heap_identity;

/** A failed POSIX primitive must not turn into an unlocked green assertion. */
static void PortableRequire(int status, const char *operation)
{
	if (status != 0) {
		fprintf(stderr, "FAIL portable synchronization %s: %d\n", operation, status);
		abort();
	}
}

_Noreturn intptr_t ErgoptiPortable_Unsupported(const char *operation, ...)
{
	fprintf(stderr, "FAIL native operation unavailable on portable target: %s\n", operation);
	abort();
}

BOOL InitOnceExecuteOnce(PINIT_ONCE once,
	BOOL (*callback)(PINIT_ONCE, PVOID, PVOID *), PVOID parameter, PVOID *context)
{
	BOOL initialized;
	PortableRequire(pthread_mutex_lock(&once->mutex), "initialize lock");
	if (!once->initialized)
		once->initialized = callback(once, parameter, context);
	initialized = once->initialized;
	PortableRequire(pthread_mutex_unlock(&once->mutex), "initialize unlock");
	return initialized;
}

BOOL InitializeCriticalSectionEx(CRITICAL_SECTION *lock, DWORD spins, DWORD flags)
{
	pthread_mutexattr_t attributes;
	(void)spins;
	if (flags != 0)
		ErgoptiPortable_Unsupported("critical-section flags");
	PortableRequire(pthread_mutexattr_init(&attributes), "mutex attributes");
	PortableRequire(pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE),
		"recursive critical section");
	PortableRequire(pthread_mutex_init(lock, &attributes), "critical section");
	PortableRequire(pthread_mutexattr_destroy(&attributes), "mutex attributes destroy");
	return TRUE;
}

void EnterCriticalSection(CRITICAL_SECTION *lock)
{
	PortableRequire(pthread_mutex_lock(lock), "critical-section lock");
}

void LeaveCriticalSection(CRITICAL_SECTION *lock)
{
	PortableRequire(pthread_mutex_unlock(lock), "critical-section unlock");
}

/** Runs the actual competing callback on a separate pthread. */
static void *PortableThreadMain(void *pointer)
{
	PortableThread *thread = pointer;
	(void)thread->entry(thread->parameter);
	PortableRequire(pthread_mutex_lock(&thread->mutex), "completion lock");
	thread->done = true;
	PortableRequire(pthread_cond_broadcast(&thread->completed), "completion notify");
	PortableRequire(pthread_mutex_unlock(&thread->mutex), "completion unlock");
	return NULL;
}

HANDLE CreateThread(LPVOID security, size_t stack_size,
	DWORD (*entry)(LPVOID), LPVOID parameter, DWORD flags, DWORD *thread_id)
{
	PortableThread *thread;
	int status;
	if (security != NULL || stack_size != 0 || flags != 0 || thread_id != NULL)
		ErgoptiPortable_Unsupported("non-default thread options");
	thread = calloc(1, sizeof(*thread));
	if (thread == NULL) {
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return NULL;
	}
	PortableRequire(pthread_mutex_init(&thread->mutex, NULL), "thread mutex");
	PortableRequire(pthread_cond_init(&thread->completed, NULL), "thread condition");
	thread->entry = entry;
	thread->parameter = parameter;
	status = pthread_create(&thread->thread, NULL, PortableThreadMain, thread);
	if (status != 0) {
		PortableRequire(pthread_cond_destroy(&thread->completed), "failed thread condition");
		PortableRequire(pthread_mutex_destroy(&thread->mutex), "failed thread mutex");
		free(thread);
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return NULL;
	}
	return thread;
}

DWORD WaitForSingleObject(HANDLE handle, DWORD milliseconds)
{
	PortableThread *thread = handle;
	struct timespec deadline;
	int status = 0;
	if (thread == NULL) {
		SetLastError(ERROR_INVALID_HANDLE);
		return WAIT_FAILED;
	}
	if (clock_gettime(CLOCK_REALTIME, &deadline) != 0)
		ErgoptiPortable_Unsupported("clock_gettime failure");
	deadline.tv_sec += milliseconds / 1000u;
	deadline.tv_nsec += (long)(milliseconds % 1000u) * 1000000L;
	if (deadline.tv_nsec >= 1000000000L) {
		++deadline.tv_sec;
		deadline.tv_nsec -= 1000000000L;
	}
	PortableRequire(pthread_mutex_lock(&thread->mutex), "wait lock");
	while (!thread->done && status != ETIMEDOUT) {
		status = milliseconds == INFINITE
			? pthread_cond_wait(&thread->completed, &thread->mutex)
			: pthread_cond_timedwait(&thread->completed, &thread->mutex, &deadline);
		if (status != ETIMEDOUT)
			PortableRequire(status, "thread wait");
	}
	if (!thread->done) {
		PortableRequire(pthread_mutex_unlock(&thread->mutex), "timeout unlock");
		return WAIT_TIMEOUT;
	}
	if (!thread->joined) {
		PortableRequire(pthread_join(thread->thread, NULL), "thread join");
		thread->joined = true;
	}
	PortableRequire(pthread_mutex_unlock(&thread->mutex), "wait unlock");
	return WAIT_OBJECT_0;
}

BOOL CloseHandle(HANDLE handle)
{
	PortableThread *thread = handle;
	if (WaitForSingleObject(handle, 0) != WAIT_OBJECT_0)
		return FALSE;
	PortableRequire(pthread_cond_destroy(&thread->completed), "completion destroy");
	PortableRequire(pthread_mutex_destroy(&thread->mutex), "thread mutex destroy");
	free(thread);
	return TRUE;
}

DWORD GetLastError(void)
{
	return g_error;
}

void SetLastError(DWORD error)
{
	g_error = error;
}

HANDLE GetProcessHeap(void)
{
	return &g_heap_identity;
}

LPVOID HeapAlloc(HANDLE heap, DWORD flags, size_t size)
{
	if (heap != GetProcessHeap() || (flags != 0 && flags != HEAP_ZERO_MEMORY))
		ErgoptiPortable_Unsupported("heap allocation options");
	return flags == HEAP_ZERO_MEMORY ? calloc(1, size) : malloc(size);
}

BOOL HeapFree(HANDLE heap, DWORD flags, LPVOID pointer)
{
	if (heap != GetProcessHeap() || flags != 0)
		ErgoptiPortable_Unsupported("heap free options");
	free(pointer);
	return TRUE;
}

/** This executable never starts an editor worker; it only fences that absence. */
int ErgoptiEditor_IsBusy(void)
{
	return 0;
}

bool ErgoptiEditor_TryFenceAdmission(void)
{
	int status = pthread_mutex_trylock(&g_editor_fence);
	if (status == EBUSY)
		return false;
	PortableRequire(status, "editor admission fence");
	return true;
}

void ErgoptiEditor_UnfenceAdmission(void)
{
	PortableRequire(pthread_mutex_unlock(&g_editor_fence), "editor admission unfence");
}

bool ErgoptiEditor_TestReplacements(void)
{
	ErgoptiPortable_Unsupported("native editor receiver matrix");
}
