// static/ergopti_plus/windows/native/nav_event_owner/editor_replace_test.c
/**
 * @file editor_replace_test.c
 * @brief Tests the real asynchronous worker against a hidden native Edit.
 *
 * Only focus acquisition is substituted for headless CI. Window messages, text
 * storage, selection, threads, completion and resource ownership are real. No
 * keyboard input, clipboard, foreign window or global hook is involved.
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>
#include "editor_replace.h"

/** Pumps the owned receiver without changing its text or worker state. */
static void EditorTestPump(void)
{
	MSG message;
	while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
		TranslateMessage(&message);
		DispatchMessageW(&message);
	}
	Sleep(1);
}

/** Bounds a phase wait while letting the real receiver process messages. */
static bool EditorTestWait(uint64_t token, uint32_t minimum, uint32_t *phase)
{
	ULONGLONG started = GetTickCount64();
	uint32_t error = 0;
	do {
		EditorTestPump();
		if (ErgoptiEditor_Poll(token, phase, &error) != 0)
			return false;
		if (*phase >= minimum)
			return true;
	} while (GetTickCount64() - started < 3000u);
	return false;
}

/** Runs a literal edit or one deliberate revocation against actual storage. */
static bool EditorTestCase(HWND window, HWND control, uint64_t token,
	const wchar_t *seed, DWORD caret, const wchar_t *deleted,
	const wchar_t *inserted, const wchar_t *expected, DWORD expected_caret,
	uint32_t revoke)
{
	uint32_t phase = 0;
	wchar_t actual[256];
	DWORD start = 0;
	DWORD end = 0;
	ULONGLONG started;
	int32_t close_status;
	SendMessageW(control, WM_SETTEXT, 0, (LPARAM)seed);
	SendMessageW(control, EM_SETSEL, caret, caret);
	ErgoptiEditor_TestFocus((uint64_t)(uintptr_t)window,
		(uint64_t)(uintptr_t)control);
	if (ErgoptiEditor_Begin(token, (uint64_t)(uintptr_t)window,
			(uint64_t)(uintptr_t)control, GetCurrentProcessId(),
			(const uint16_t *)deleted, (const uint16_t *)inserted) != 0
			|| !ErgoptiEditor_IsBusy()
			|| !EditorTestWait(token, ERGOPTI_EDITOR_READY, &phase))
		return false;
	if (phase == ERGOPTI_EDITOR_READY) {
		if (ErgoptiEditor_Close(token) != ERGOPTI_NAV_STATUS_BUSY
				|| ErgoptiNav_Stop() != ERGOPTI_NAV_STATUS_BUSY)
			return false;
		if (revoke == 1)
			SendMessageW(control, EM_SETSEL, 0, 0);
		else if (revoke == 2)
			SendMessageW(control, WM_SETTEXT, 0, (LPARAM)L"newer input");
		else if (revoke == 3)
			ErgoptiEditor_TestFocus(0, 0);
		if (ErgoptiEditor_Decide(token, revoke == 4 ? 0 : 1) != 0
				|| ErgoptiEditor_Decide(token, 1) == 0)
			return false;
	}
	if (!EditorTestWait(token, ERGOPTI_EDITOR_SUCCESS, &phase)
			|| phase != (uint32_t)(revoke == 0 ? ERGOPTI_EDITOR_SUCCESS : ERGOPTI_EDITOR_REFUSED))
		return false;
	SendMessageW(control, WM_GETTEXT, 256, (LPARAM)actual);
	SendMessageW(control, EM_GETSEL, (WPARAM)&start, (LPARAM)&end);
	if (wcscmp(actual, expected) != 0 || start != expected_caret || end != start)
		return false;
	started = GetTickCount64();
	do {
		close_status = ErgoptiEditor_Close(token);
		if (close_status != ERGOPTI_NAV_STATUS_BUSY)
			break;
		EditorTestPump();
	} while (GetTickCount64() - started < 3000u);
	return close_status == 0 && !ErgoptiEditor_IsBusy()
		&& ErgoptiEditor_Close(token) == ERGOPTI_NAV_STATUS_OWNER_MISMATCH;
}


/** Retires the exact test worker without destroying a receiver it may still use. */
static bool EditorTestCloseFinished(uint64_t token)
{
	ULONGLONG started = GetTickCount64();
	int32_t status;
	do {
		EditorTestPump();
		status = ErgoptiEditor_Close(token);
		if (status != ERGOPTI_NAV_STATUS_BUSY)
			return status == 0 && !ErgoptiEditor_IsBusy();
	} while (GetTickCount64() - started < 3000u);
	return false;
}

/** Changes actual receiver storage only after observing the real wait boundary. */
static bool EditorTestDelayedCharacter(HWND window, HWND control, uint64_t token,
	bool surrogate, uint32_t revoke)
{
	const wchar_t *deleted = surrogate ? L"ct\xD83D\xDE00" : L"ct\x2605";
	const wchar_t *completion = surrogate ? L"\xD83D\xDE00" : L"\x2605";
	const wchar_t *replacement = surrogate ? L"X" : L"c'\xE9tait";
	const wchar_t *expected = surrogate ? L"left X tail" : L"left c'\xE9tait tail";
	DWORD expected_caret = surrogate ? 6u : 12u;
	DWORD start = 0;
	DWORD end = 0;
	wchar_t actual[256];
	uint32_t phase = 0;
	ULONGLONG started;
	bool passed = false;
	bool observed = false;
	bool closed;
	SendMessageW(control, WM_SETTEXT, 0, (LPARAM)L"left ct tail");
	SendMessageW(control, EM_SETSEL, 7, 7);
	ErgoptiEditor_TestFocus((uint64_t)(uintptr_t)window,
		(uint64_t)(uintptr_t)control);
	if (ErgoptiEditor_Begin(token, (uint64_t)(uintptr_t)window,
			(uint64_t)(uintptr_t)control, GetCurrentProcessId(),
			(const uint16_t *)deleted, (const uint16_t *)replacement) != 0)
		return false;
	started = GetTickCount64();
	do {
		EditorTestPump();
		observed = ErgoptiEditor_TestWaiting(token);
		if (observed)
			break;
	} while (GetTickCount64() - started < 3000u);
	if (!observed || ErgoptiEditor_TestMutationCount(token) != 0)
		goto finished;
	if (revoke == 2u) {
		SendMessageW(control, EM_SETSEL, 0, 0);
		expected = L"left ct tail";
		expected_caret = 0;
	} else if (revoke == 1u) {
		SendMessageW(control, EM_REPLACESEL, TRUE, (LPARAM)L"?");
		expected = L"left ct? tail";
		expected_caret = 8;
	} else {
		SendMessageW(control, EM_REPLACESEL, TRUE, (LPARAM)completion);
	}
	if (!EditorTestWait(token, ERGOPTI_EDITOR_READY, &phase))
		goto finished;
	if (revoke == 0u) {
		if (phase != ERGOPTI_EDITOR_READY
				|| ErgoptiEditor_Decide(token, 1) != 0
				|| !EditorTestWait(token, ERGOPTI_EDITOR_SUCCESS, &phase)
				|| phase != ERGOPTI_EDITOR_SUCCESS
				|| ErgoptiEditor_TestMutationCount(token) != 2u)
			goto finished;
	} else if (phase != ERGOPTI_EDITOR_REFUSED
			|| ErgoptiEditor_TestMutationCount(token) != 0) {
		goto finished;
	}
	SendMessageW(control, WM_GETTEXT, 256, (LPARAM)actual);
	SendMessageW(control, EM_GETSEL, (WPARAM)&start, (LPARAM)&end);
	passed = wcscmp(actual, expected) == 0 && start == expected_caret && end == start;
finished:
	/* No test failure is permission to free or destroy a live worker receiver. */
	closed = EditorTestCloseFinished(token);
	return passed && closed;
}

/** Implements ErgoptiEditor_TestReplacements. */
bool ErgoptiEditor_TestReplacements(void)
{
	HINSTANCE instance = GetModuleHandleW(NULL);
	HWND window = CreateWindowExW(0, L"STATIC", L"Ergopti owned native fixture",
		WS_POPUP, 0, 0, 300, 100, NULL, NULL, instance, NULL);
	HWND control;
	bool passed;
	if (window == NULL)
		return 0;
	control = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_MULTILINE,
		0, 0, 300, 100, window, NULL, instance, NULL);
	if (control == NULL) {
		DestroyWindow(window);
		return 0;
	}
	passed = EditorTestCase(window, control, 1, L"ct\x2605", 3, L"ct\x2605",
			L"c'\xE9tait", L"c'\xE9tait", 7, 0)
		&& EditorTestCase(window, control, 2, L"napol\xE9on \xE9tait", 14,
			L"napol\xE9on \xE9tait", L"Napol\xE9on \xE9tait un empereur",
			L"Napol\xE9on \xE9tait un empereur", 26, 0)
		&& EditorTestCase(window, control, 3, L"left \xD83D\xDE00 tail", 7,
			L"\xD83D\xDE00", L"star", L"left star tail", 9, 0)
		&& EditorTestCase(window, control, 4, L"one\r\ntwo tail", 8,
			L"two", L"three", L"one\r\nthree tail", 10, 0)
		&& EditorTestCase(window, control, 5, L"ct\x2605", 3, L"ct\x2605",
			L"replacement", L"ct\x2605", 0, 1)
		&& EditorTestCase(window, control, 6, L"ct\x2605", 3, L"ct\x2605",
			L"replacement", L"newer input", 0, 2)
		&& EditorTestCase(window, control, 7, L"ct\x2605", 3, L"ct\x2605",
			L"replacement", L"ct\x2605", 3, 3)
		&& EditorTestCase(window, control, 8, L"ct\x2605", 3, L"ct\x2605",
			L"replacement", L"ct\x2605", 3, 4)
		&& EditorTestCase(window, control, 9, L"ct\x2605", 3, L"different",
			L"replacement", L"ct\x2605", 3, 5)
		&& EditorTestDelayedCharacter(window, control, 10, false, 0)
		&& EditorTestDelayedCharacter(window, control, 11, true, 0)
		&& EditorTestDelayedCharacter(window, control, 12, false, 1)
		&& EditorTestDelayedCharacter(window, control, 13, false, 2);
	ErgoptiEditor_TestFocus(0, 0);
	if (ErgoptiEditor_IsBusy()) {
		ULONGLONG retirement_started = GetTickCount64();
		do {
			uint64_t owned_token;
			EditorTestPump();
			for (owned_token = 1; owned_token <= 13u; ++owned_token)
				(void)ErgoptiEditor_Close(owned_token);
		} while (ErgoptiEditor_IsBusy()
			&& GetTickCount64() - retirement_started < 3000u);
		if (ErgoptiEditor_IsBusy()) {
			/* Retain both exact receiver HWNDs while their worker can still use them. */
			fprintf(stderr, "Native editor fixture retains an unsettled worker.\n");
			return false;
		}
	}
	DestroyWindow(control);
	DestroyWindow(window);
	if (!passed)
		fprintf(stderr, "Native editor receiver matrix failed.\n");
	return passed ? 1 : 0;
}
