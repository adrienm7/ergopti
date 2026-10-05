// static/ergopti_plus/windows/native/nav_event_owner/editor_replace.c
/**
 * @file editor_replace.c
 * @brief Owns editor messages outside AutoHotkey's cooperative keyboard thread.
 *
 * Native replacement avoids the asynchronous Backspace/Ctrl+V ordering defect
 * in modern Notepad. Preparation and final admission are separate. Exact focus,
 * collapsed caret, deleted suffix and complete document are checked before
 * mutation; complete text and DWORD selection are checked afterwards. A timeout
 * after selection begins is indeterminate, never an invitation to repeat input.
 * This does not quarantine the global keyboard: unexpected concurrent edits
 * fail verification and require the caller to invalidate its text mirrors.
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include "editor_replace.h"

/** Retains the exact target and copied text until its thread terminates. */
typedef struct EditorJob {
	uint64_t token;
	HWND window;
	HWND control;
	DWORD process_id;
	HANDLE process;
	HANDLE thread;
	HANDLE decision;
	HMODULE module;
	volatile LONG phase;
	volatile LONG error;
	volatile LONG commit;
	bool rich;
#if defined(ERGOPTI_NAV_TESTING)
	volatile LONG waiting_for_character;
	volatile LONG mutation_calls;
#endif
	wchar_t *deleted;
	wchar_t *inserted;
	wchar_t *before;
	wchar_t *expected;
	DWORD start;
	DWORD end;
} EditorJob;

static SRWLOCK g_editor_lock = SRWLOCK_INIT;
static EditorJob *g_editor_job;
static bool g_editor_admission_fenced;

#if defined(ERGOPTI_NAV_TESTING)
static HWND g_editor_test_window;
static HWND g_editor_test_control;

/** Implements ErgoptiEditor_TestFocus. */
void ErgoptiEditor_TestFocus(uint64_t window, uint64_t control)
{
	InterlockedExchangePointer((PVOID volatile *)&g_editor_test_window,
		(PVOID)(uintptr_t)window);
	InterlockedExchangePointer((PVOID volatile *)&g_editor_test_control,
		(PVOID)(uintptr_t)control);
}
#endif

/** Copies text while mapping RichEdit's CRLF/LF spelling to its CR offsets. */
static wchar_t *EditorCopy(const wchar_t *text, bool rich)
{
	size_t length = wcsnlen(text, ERGOPTI_EDITOR_MAX_UNITS + 1u);
	size_t input;
	size_t output = 0;
	wchar_t *copy;
	if (length > ERGOPTI_EDITOR_MAX_UNITS)
		return NULL;
	copy = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
		(length + 1u) * sizeof(wchar_t));
	if (copy == NULL)
		return NULL;
	for (input = 0; input < length; ++input) {
		wchar_t value = text[input];
		if (rich && value == L'\r' && text[input + 1u] == L'\n')
			++input;
		else if (rich && value == L'\n')
			value = L'\r';
		copy[output++] = value;
	}
	return copy;
}

/** Rejects a switched focus, reused HWND, dead process or read-only editor. */
static bool EditorTargetCurrent(EditorJob *job)
{
	DWORD window_pid = 0;
	DWORD control_pid = 0;
	DWORD thread;
	HWND focused_window;
	HWND focused_control;
	GUITHREADINFO info;
	wchar_t class_name[64];
	if (WaitForSingleObject(job->process, 0) != WAIT_TIMEOUT)
		return false;
	thread = GetWindowThreadProcessId(job->window, &window_pid);
	GetWindowThreadProcessId(job->control, &control_pid);
	memset(&info, 0, sizeof(info));
	info.cbSize = sizeof(info);

#if defined(ERGOPTI_NAV_TESTING)
	focused_window = InterlockedCompareExchangePointer(
		(PVOID volatile *)&g_editor_test_window, NULL, NULL);
	focused_control = InterlockedCompareExchangePointer(
		(PVOID volatile *)&g_editor_test_control, NULL, NULL);
#else
	focused_window = GetForegroundWindow();
	if (!GetGUIThreadInfo(thread, &info))
		return false;
	focused_control = info.hwndFocus;
#endif
	if (thread == 0 || window_pid != job->process_id
			|| control_pid != job->process_id
			|| !IsChild(job->window, job->control)
			|| focused_window != job->window || focused_control != job->control
			|| !GetClassNameW(job->control, class_name, 64)
			|| wcscmp(class_name, job->rich ? L"RichEditD2DPT" : L"Edit") != 0
			|| (GetWindowLongPtrW(job->control, GWL_STYLE) & ES_READONLY) != 0)
		return false;
	return true;
}

/** A bounded message keeps all pointer storage owned until the call returns. */
static bool EditorMessage(EditorJob *job, UINT message, WPARAM word,
	LPARAM pointer, DWORD_PTR *result)
{
	SetLastError(ERROR_SUCCESS);
#if defined(ERGOPTI_NAV_TESTING)
	if (message == EM_SETSEL || message == EM_REPLACESEL)
		InterlockedIncrement(&job->mutation_calls);
#endif
	if (!SendMessageTimeoutW(job->control, message, word, pointer,
			SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT,
			ERGOPTI_EDITOR_MESSAGE_TIMEOUT_MS, result)) {
		DWORD error = GetLastError();
		InterlockedExchange(&job->error,
			(LONG)(error == ERROR_SUCCESS ? ERROR_TIMEOUT : error));
		return false;
	}
	return true;
}

/** Uses pointer DWORDs instead of the truncated packed EM_GETSEL result. */
static bool EditorSelection(EditorJob *job, DWORD *start, DWORD *end)
{
	DWORD_PTR result = 0;
	return EditorMessage(job, EM_GETSEL, (WPARAM)start, (LPARAM)end, &result);
}

/** Reads a complete, bounded document and rejects truncated or changing reads. */
static wchar_t *EditorRead(EditorJob *job)
{
	DWORD_PTR length = 0;
	DWORD_PTR read = 0;
	DWORD_PTR final_length = 0;
	wchar_t *storage;
	wchar_t *normalized;
	if (!EditorMessage(job, WM_GETTEXTLENGTH, 0, 0, &length)
			|| length > ERGOPTI_EDITOR_MAX_UNITS)
		return NULL;
	storage = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
		(length + 1u) * sizeof(wchar_t));
	if (storage == NULL)
		return NULL;
	if (!EditorMessage(job, WM_GETTEXT, length + 1u, (LPARAM)storage, &read)
			|| !EditorMessage(job, WM_GETTEXTLENGTH, 0, 0, &final_length)
			|| read != length || final_length != length) {
		HeapFree(GetProcessHeap(), 0, storage);
		return NULL;
	}
	normalized = EditorCopy(storage, job->rich);
	HeapFree(GetProcessHeap(), 0, storage);
	return normalized;
}

/** Declines a cursor inside a surrogate pair rather than deleting half of it. */
static bool EditorBoundary(const wchar_t *text, size_t position)
{
	return position == 0 || !(text[position - 1u] >= 0xD800
		&& text[position - 1u] <= 0xDBFF && text[position] >= 0xDC00
		&& text[position] <= 0xDFFF);
}

/**
 * Waits only for one independently predicted completing scalar to become visible.
 *
 * InputHook can observe a character before a modern editor has stored it. The
 * initial full image must end at the exact preceding trigger prefix. Every later
 * image must either remain byte-identical or gain that one scalar at the original
 * caret, preserving the complete suffix; arbitrary edits never reopen admission.
 */
static bool EditorWaitCompletingCharacter(EditorJob *job)
{
	wchar_t *initial = NULL;
	wchar_t *expected = NULL;
	wchar_t *actual = NULL;
	size_t deleted_length = wcslen(job->deleted);
	size_t missing;
	size_t initial_length;
	DWORD start = 0;
	DWORD end = 0;
	ULONGLONG started;
	bool visible = false;
	if (deleted_length == 0 || !EditorTargetCurrent(job))
		return false;
	missing = deleted_length >= 2 && job->deleted[deleted_length - 1u] >= 0xDC00
		&& job->deleted[deleted_length - 1u] <= 0xDFFF
		&& job->deleted[deleted_length - 2u] >= 0xD800
		&& job->deleted[deleted_length - 2u] <= 0xDBFF ? 2u : 1u;
	if (deleted_length <= missing)
		return false;
	initial = EditorRead(job);
	if (initial == NULL)
		goto finished;
	initial_length = wcslen(initial);
	if (!EditorSelection(job, &start, &end)
			|| start != end || end < deleted_length - missing
			|| end > initial_length
			|| wmemcmp(initial + end - (deleted_length - missing), job->deleted,
				deleted_length - missing) != 0)
		goto finished;
	if (end > initial_length || initial_length + missing > ERGOPTI_EDITOR_MAX_UNITS)
		goto finished;
	expected = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
		(initial_length + missing + 1u) * sizeof(wchar_t));
	if (expected == NULL)
		goto finished;
	memcpy(expected, initial, end * sizeof(wchar_t));
	memcpy(expected + end, job->deleted + deleted_length - missing,
		missing * sizeof(wchar_t));
	memcpy(expected + end + missing, initial + end,
		(initial_length - end + 1u) * sizeof(wchar_t));
	started = GetTickCount64();
#if defined(ERGOPTI_NAV_TESTING)
	InterlockedExchange(&job->waiting_for_character, 1);
#endif
	do {
		DWORD current_start = 0;
		DWORD current_end = 0;
		Sleep(ERGOPTI_EDITOR_VISIBILITY_POLL_MS);
		if (!EditorTargetCurrent(job))
			break;
		actual = EditorRead(job);
		if (actual == NULL || !EditorSelection(job, &current_start, &current_end))
			break;
		if (wcscmp(actual, expected) == 0 && current_start == end + missing
				&& current_end == current_start) {
			visible = true;
			break;
		}
		if (wcscmp(actual, initial) != 0 || current_start != end || current_end != end)
			break;
		HeapFree(GetProcessHeap(), 0, actual);
		actual = NULL;
	} while (GetTickCount64() - started < ERGOPTI_EDITOR_VISIBILITY_TIMEOUT_MS);
finished:
#if defined(ERGOPTI_NAV_TESTING)
	InterlockedExchange(&job->waiting_for_character, 0);
#endif
	if (actual != NULL)
		HeapFree(GetProcessHeap(), 0, actual);
	if (expected != NULL)
		HeapFree(GetProcessHeap(), 0, expected);
	if (initial != NULL)
		HeapFree(GetProcessHeap(), 0, initial);
	return visible;
}

/** Freezes the actual caret, exact deleted tail and complete expected document. */
static bool EditorPrepare(EditorJob *job)
{
	size_t length;
	size_t deleted_length = wcslen(job->deleted);
	size_t inserted_length = wcslen(job->inserted);
	size_t expected_length;
	if (!EditorTargetCurrent(job))
		return false;
	job->before = EditorRead(job);
	if (job->before == NULL || !EditorSelection(job, &job->start, &job->end))
		return false;
	length = wcslen(job->before);
	if (job->start != job->end || job->end > length
			|| job->end < deleted_length)
		return false;
	job->start -= (DWORD)deleted_length;
	if (!EditorBoundary(job->before, job->start)
			|| !EditorBoundary(job->before, job->end)
			|| wmemcmp(job->before + job->start, job->deleted, deleted_length) != 0)
		return false;
	expected_length = length - deleted_length + inserted_length;
	if (expected_length > ERGOPTI_EDITOR_MAX_UNITS)
		return false;
	job->expected = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
		(expected_length + 1u) * sizeof(wchar_t));
	if (job->expected == NULL)
		return false;
	memcpy(job->expected, job->before, job->start * sizeof(wchar_t));
	memcpy(job->expected + job->start, job->inserted,
		inserted_length * sizeof(wchar_t));
	memcpy(job->expected + job->start + inserted_length, job->before + job->end,
		(length - job->end + 1u) * sizeof(wchar_t));
	return EditorTargetCurrent(job);
}

/** Revalidates the prepared image immediately before selecting the owned tail. */
static bool EditorPreparedCurrent(EditorJob *job)
{
	wchar_t *current;
	DWORD start = 0;
	DWORD end = 0;
	bool matches;
	if (!EditorTargetCurrent(job))
		return false;
	current = EditorRead(job);
	matches = current != NULL && wcscmp(current, job->before) == 0
		&& EditorSelection(job, &start, &end)
		&& start == job->end && end == job->end;
	if (current != NULL)
		HeapFree(GetProcessHeap(), 0, current);
	return matches && EditorTargetCurrent(job);
}

/** Runs only native editor messages; never calls AutoHotkey or SendInput. */
static DWORD WINAPI EditorThread(void *context)
{
	EditorJob *job = context;
	DWORD_PTR result = 0;
	DWORD start = 0;
	DWORD end = 0;
	wchar_t *actual = NULL;
	LONG terminal = ERGOPTI_EDITOR_REFUSED;
	if (!EditorPrepare(job)) {
		if (!EditorWaitCompletingCharacter(job))
			goto finished;
		if (job->before != NULL) {
			HeapFree(GetProcessHeap(), 0, job->before);
			job->before = NULL;
		}
		if (job->expected != NULL) {
			HeapFree(GetProcessHeap(), 0, job->expected);
			job->expected = NULL;
		}
		if (!EditorPrepare(job))
			goto finished;
	}
	InterlockedExchange(&job->phase, ERGOPTI_EDITOR_READY);
	if (WaitForSingleObject(job->decision, ERGOPTI_EDITOR_ADMISSION_TIMEOUT_MS)
			!= WAIT_OBJECT_0 || InterlockedCompareExchange(&job->commit, 0, 0) != 1
			|| !EditorPreparedCurrent(job))
		goto finished;
	InterlockedExchange(&job->phase, ERGOPTI_EDITOR_EMITTING);
	terminal = ERGOPTI_EDITOR_INDETERMINATE;
	if (!EditorMessage(job, EM_SETSEL, job->start, job->end, &result)
			|| !EditorSelection(job, &start, &end)
			|| start != job->start || end != job->end
			|| !EditorTargetCurrent(job)
			|| !EditorMessage(job, EM_REPLACESEL, TRUE, (LPARAM)job->inserted, &result))
		goto finished;
	actual = EditorRead(job);
	if (actual != NULL && wcscmp(actual, job->expected) == 0
			&& EditorSelection(job, &start, &end)
			&& start == job->start + wcslen(job->inserted) && end == start
			&& EditorTargetCurrent(job))
		terminal = ERGOPTI_EDITOR_SUCCESS;
finished:
	if (actual != NULL)
		HeapFree(GetProcessHeap(), 0, actual);
	InterlockedExchange(&job->phase, terminal);
	if (job->module != NULL)
		FreeLibraryAndExitThread(job->module, 0);
	return 0;
}

/** Releases a never-published job or a job whose worker has actually exited. */
static void EditorFree(EditorJob *job)
{
	if (job->thread != NULL)
		CloseHandle(job->thread);
	if (job->decision != NULL)
		CloseHandle(job->decision);
	if (job->process != NULL)
		CloseHandle(job->process);
	if (job->deleted != NULL)
		HeapFree(GetProcessHeap(), 0, job->deleted);
	if (job->inserted != NULL)
		HeapFree(GetProcessHeap(), 0, job->inserted);
	if (job->before != NULL)
		HeapFree(GetProcessHeap(), 0, job->before);
	if (job->expected != NULL)
		HeapFree(GetProcessHeap(), 0, job->expected);
	HeapFree(GetProcessHeap(), 0, job);
}

/** Implements ErgoptiEditor_Begin. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Begin(
	uint64_t token, uint64_t window, uint64_t control, uint32_t process_id,
	const uint16_t *deleted_text, const uint16_t *inserted_text)
{
	EditorJob *job;
	wchar_t class_name[64];
	if (token == 0 || window == 0 || control == 0 || process_id == 0
			|| deleted_text == NULL || inserted_text == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
#if !defined(ERGOPTI_NAV_TESTING)
	/* Timed-out cross-process system messages own their marshalled storage.
	 * A same-process receiver could instead retain our raw stack pointers. */
	if (process_id == GetCurrentProcessId())
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
#endif
	AcquireSRWLockExclusive(&g_editor_lock);
	if (g_editor_admission_fenced || g_editor_job != NULL) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	job = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*job));
	if (job == NULL) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	job->token = token;
	job->window = (HWND)(uintptr_t)window;
	job->control = (HWND)(uintptr_t)control;
	job->process_id = process_id;
	if (!GetClassNameW(job->control, class_name, 64)
			|| (wcscmp(class_name, L"RichEditD2DPT") != 0
				&& wcscmp(class_name, L"Edit") != 0)) {
		EditorFree(job);
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	}
	job->rich = wcscmp(class_name, L"RichEditD2DPT") == 0;
	job->process = OpenProcess(SYNCHRONIZE, FALSE, process_id);
	job->decision = CreateEventW(NULL, FALSE, FALSE, NULL);
	job->deleted = EditorCopy((const wchar_t *)deleted_text, job->rich);
	job->inserted = EditorCopy((const wchar_t *)inserted_text, job->rich);
	job->phase = ERGOPTI_EDITOR_PREPARING;
	if (job->process == NULL || job->decision == NULL || job->deleted == NULL
			|| job->inserted == NULL) {
		EditorFree(job);
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
#if !defined(ERGOPTI_NAV_TESTING)
	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
			(LPCWSTR)(uintptr_t)&EditorThread, &job->module)) {
		EditorFree(job);
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
#endif
	job->thread = CreateThread(NULL, 0, EditorThread, job, 0, NULL);
	if (job->thread == NULL) {
		if (job->module != NULL)
			FreeLibrary(job->module);
		EditorFree(job);
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	g_editor_job = job;
	ReleaseSRWLockExclusive(&g_editor_lock);
	return ERGOPTI_NAV_STATUS_OK;
}

/** Implements ErgoptiEditor_Poll. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Poll(
	uint64_t token, uint32_t *phase, uint32_t *os_error)
{
	if (phase == NULL || os_error == NULL)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	AcquireSRWLockShared(&g_editor_lock);
	if (g_editor_job == NULL || g_editor_job->token != token) {
		ReleaseSRWLockShared(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	*phase = (uint32_t)InterlockedCompareExchange(&g_editor_job->phase, 0, 0);
	*os_error = (uint32_t)InterlockedCompareExchange(&g_editor_job->error, 0, 0);
	ReleaseSRWLockShared(&g_editor_lock);
	return ERGOPTI_NAV_STATUS_OK;
}

/** Implements ErgoptiEditor_Decide. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Decide(
	uint64_t token, uint32_t commit)
{
	if (commit > 1)
		return ERGOPTI_NAV_STATUS_INVALID_ARGUMENT;
	AcquireSRWLockExclusive(&g_editor_lock);
	if (g_editor_job == NULL || g_editor_job->token != token
			|| g_editor_job->phase != ERGOPTI_EDITOR_READY) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	/* A second AHK notification cannot reopen a cancelled or committed worker. */
	if (InterlockedCompareExchange(&g_editor_job->commit, commit ? 1 : -1, 0) != 0) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_INVALID_STATE;
	}
	if (!SetEvent(g_editor_job->decision)) {
		InterlockedExchange(&g_editor_job->error, (LONG)GetLastError());
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OS_ERROR;
	}
	ReleaseSRWLockExclusive(&g_editor_lock);
	return ERGOPTI_NAV_STATUS_OK;
}

/** Implements ErgoptiEditor_Close. */
ERGOPTI_NAV_API int32_t ERGOPTI_NAV_CALL ErgoptiEditor_Close(uint64_t token)
{
	AcquireSRWLockExclusive(&g_editor_lock);
	if (g_editor_job == NULL || g_editor_job->token != token) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
	}
	if (WaitForSingleObject(g_editor_job->thread, 0) != WAIT_OBJECT_0) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return ERGOPTI_NAV_STATUS_BUSY;
	}
	EditorFree(g_editor_job);
	g_editor_job = NULL;
	ReleaseSRWLockExclusive(&g_editor_lock);
	return ERGOPTI_NAV_STATUS_OK;
}

/** Implements ErgoptiEditor_IsBusy. */
int ErgoptiEditor_IsBusy(void)
{
	int busy;
	AcquireSRWLockShared(&g_editor_lock);
	busy = g_editor_job != NULL;
	ReleaseSRWLockShared(&g_editor_lock);
	return busy;
}

/** Implements ErgoptiEditor_TryFenceAdmission. */
bool ErgoptiEditor_TryFenceAdmission(void)
{
	AcquireSRWLockExclusive(&g_editor_lock);
	if (g_editor_admission_fenced || g_editor_job != NULL) {
		ReleaseSRWLockExclusive(&g_editor_lock);
		return false;
	}
	g_editor_admission_fenced = true;
	ReleaseSRWLockExclusive(&g_editor_lock);
	return true;
}

/** Implements ErgoptiEditor_UnfenceAdmission. */
void ErgoptiEditor_UnfenceAdmission(void)
{
	AcquireSRWLockExclusive(&g_editor_lock);
	g_editor_admission_fenced = false;
	ReleaseSRWLockExclusive(&g_editor_lock);
}

#if defined(ERGOPTI_NAV_TESTING)
/** Reports only the actual token-owned visibility wait after its image freeze. */
bool ErgoptiEditor_TestWaiting(uint64_t token)
{
	bool waiting;
	AcquireSRWLockShared(&g_editor_lock);
	waiting = g_editor_job != NULL && g_editor_job->token == token
		&& InterlockedCompareExchange(&g_editor_job->waiting_for_character, 0, 0) == 1;
	ReleaseSRWLockShared(&g_editor_lock);
	return waiting;
}

/** Counts actual worker mutation attempts; an unknown owner is never zero. */
uint32_t ErgoptiEditor_TestMutationCount(uint64_t token)
{
	uint32_t count = UINT32_MAX;
	AcquireSRWLockShared(&g_editor_lock);
	if (g_editor_job != NULL && g_editor_job->token == token)
		count = (uint32_t)InterlockedCompareExchange(&g_editor_job->mutation_calls, 0, 0);
	ReleaseSRWLockShared(&g_editor_lock);
	return count;
}
#endif
