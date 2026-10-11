// tools/test/support/nav_event_owner_portable/windows.h
/**
 * @file windows.h
 * @brief Narrow POSIX boundary for the unchanged hook-free navigation C tests.
 *
 * This is test infrastructure, not a Windows implementation or qualification.
 * Unsupported native operations terminate the process instead of returning a
 * simulated success. Only locks, threads, error storage and heap allocation
 * required by deterministic tests have implementations. Desktop ownership and
 * QPC boundaries return explicit unavailable results for refusal-path checks.
 */

#ifndef ERGOPTI_PORTABLE_WINDOWS_H
#define ERGOPTI_PORTABLE_WINDOWS_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#define __declspec(attribute)
#define __cdecl
#define WINAPI
#define CALLBACK

typedef struct LARGE_INTEGER { int64_t QuadPart; } LARGE_INTEGER;
typedef int BOOL;
typedef uint32_t DWORD;
typedef uint32_t UINT;
typedef uint16_t WORD;
typedef int16_t SHORT;
typedef uintptr_t ULONG_PTR;
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef intptr_t LRESULT;
typedef void *PVOID;
typedef void *LPVOID;
typedef void *HANDLE;
typedef void *HWND;
typedef void *HHOOK;
typedef void *HINSTANCE;
typedef struct RECT { int32_t left, top, right, bottom; } RECT;
typedef struct GUITHREADINFO {
	DWORD cbSize;
	DWORD flags;
	HWND hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
	RECT rcCaret;
} GUITHREADINFO;
typedef pthread_mutex_t CRITICAL_SECTION;
typedef struct INIT_ONCE {
	pthread_mutex_t mutex;
	BOOL initialized;
} INIT_ONCE, *PINIT_ONCE;

#define INIT_ONCE_STATIC_INIT { PTHREAD_MUTEX_INITIALIZER, 0 }

typedef struct KBDLLHOOKSTRUCT {
	DWORD vkCode;
	DWORD scanCode;
	DWORD flags;
	DWORD time;
	ULONG_PTR dwExtraInfo;
} KBDLLHOOKSTRUCT;

typedef struct KEYBDINPUT {
	WORD wVk;
	WORD wScan;
	DWORD dwFlags;
	DWORD time;
	ULONG_PTR dwExtraInfo;
} KEYBDINPUT;

typedef struct INPUT {
	DWORD type;
	union {
		KEYBDINPUT ki;
		uint8_t win32_union_size[32];
	};
} INPUT;

typedef struct MSG {
	UINT message;
} MSG;

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_ATTACH 1u
#define ERROR_SUCCESS 0u
#define ERROR_ACCESS_DENIED 5u
#define ERROR_INVALID_HANDLE 6u
#define ERROR_NOT_ENOUGH_MEMORY 8u
#define ERROR_WRITE_FAULT 29u
#define ERROR_TIMEOUT 1460u
#define WAIT_OBJECT_0 0u
#define WAIT_TIMEOUT 258u
#define WAIT_FAILED 0xFFFFFFFFu
#define INFINITE 0xFFFFFFFFu
#define HEAP_ZERO_MEMORY 8u
#define INPUT_KEYBOARD 1u
#define KEYEVENTF_EXTENDEDKEY 1u
#define KEYEVENTF_KEYUP 2u
#define KEYEVENTF_SCANCODE 8u
#define LLKHF_EXTENDED 1u
#define LLKHF_LOWER_IL_INJECTED 2u
#define LLKHF_INJECTED 16u
#define VK_CAPITAL 0x14u
#define VK_SHIFT 0x10u
#define VK_CONTROL 0x11u
#define VK_MENU 0x12u
#define VK_LEFT 0x25u
#define VK_UP 0x26u
#define VK_DOWN 0x28u
#define VK_LWIN 0x5Bu
#define VK_RWIN 0x5Cu
#define VK_LSHIFT 0xA0u
#define VK_RSHIFT 0xA1u
#define VK_LCONTROL 0xA2u
#define VK_RCONTROL 0xA3u
#define VK_LMENU 0xA4u
#define VK_RMENU 0xA5u
#define WM_QUIT 0x12u
#define WM_KEYDOWN 0x100u
#define WM_KEYUP 0x101u
#define WM_SYSKEYDOWN 0x104u
#define WM_SYSKEYUP 0x105u
#define WM_USER 0x400u
#define WH_KEYBOARD_LL 13
#define HC_ACTION 0
#define PM_NOREMOVE 0u
#define PM_REMOVE 1u
#define QS_ALLINPUT 0x4FFu

_Static_assert(sizeof(INPUT) == 40, "Portable keyboard input must retain x64 layout.");
_Static_assert(offsetof(INPUT, ki) == 8, "Portable keyboard input union offset changed.");
_Static_assert(sizeof(KBDLLHOOKSTRUCT) == 24, "Portable hook event layout changed.");

BOOL InitOnceExecuteOnce(PINIT_ONCE once,
	BOOL (*callback)(PINIT_ONCE, PVOID, PVOID *), PVOID parameter, PVOID *context);
BOOL InitializeCriticalSectionEx(CRITICAL_SECTION *lock, DWORD spins, DWORD flags);
void EnterCriticalSection(CRITICAL_SECTION *lock);
void LeaveCriticalSection(CRITICAL_SECTION *lock);
HANDLE CreateThread(LPVOID security, size_t stack_size,
	DWORD (*entry)(LPVOID), LPVOID parameter, DWORD flags, DWORD *thread_id);
DWORD WaitForSingleObject(HANDLE handle, DWORD milliseconds);
BOOL CloseHandle(HANDLE handle);
/** Missing desktop/QPC capability is a fail-closed refusal, never fake success. */
BOOL QueryPerformanceCounter(LARGE_INTEGER *counter);
HWND GetForegroundWindow(void);
DWORD GetWindowThreadProcessId(HWND window, DWORD *process_id);
DWORD GetCurrentProcessId(void);
BOOL GetGUIThreadInfo(DWORD thread_id, GUITHREADINFO *information);
BOOL IsChild(HWND parent, HWND child);
DWORD GetLastError(void);
void SetLastError(DWORD error);
HANDLE GetProcessHeap(void);
LPVOID HeapAlloc(HANDLE heap, DWORD flags, size_t size);
BOOL HeapFree(HANDLE heap, DWORD flags, LPVOID pointer);

/** A native boundary reached by a portable test is a failure, never a skip. */
_Noreturn intptr_t ErgoptiPortable_Unsupported(const char *operation, ...);

#define DisableThreadLibraryCalls(...) ErgoptiPortable_Unsupported("DisableThreadLibraryCalls", __VA_ARGS__)
#define CreateEventW(...) ((HANDLE)ErgoptiPortable_Unsupported("CreateEventW", __VA_ARGS__))
#define SetEvent(...) ErgoptiPortable_Unsupported("SetEvent", __VA_ARGS__)
#define ResetEvent(...) ErgoptiPortable_Unsupported("ResetEvent", __VA_ARGS__)
#define GetAsyncKeyState(...) ErgoptiPortable_Unsupported("GetAsyncKeyState", __VA_ARGS__)
#define GetCurrentThreadId(...) ErgoptiPortable_Unsupported("GetCurrentThreadId")
#define GetModuleHandleW(...) ((HINSTANCE)ErgoptiPortable_Unsupported("GetModuleHandleW", __VA_ARGS__))
#define SetWindowsHookExW(...) ((HHOOK)ErgoptiPortable_Unsupported("SetWindowsHookExW", __VA_ARGS__))
#define UnhookWindowsHookEx(...) ErgoptiPortable_Unsupported("UnhookWindowsHookEx", __VA_ARGS__)
#define CallNextHookEx(...) ErgoptiPortable_Unsupported("CallNextHookEx", __VA_ARGS__)
#define SendInput(...) ErgoptiPortable_Unsupported("SendInput", __VA_ARGS__)
#define PostMessageW(...) ErgoptiPortable_Unsupported("PostMessageW", __VA_ARGS__)
#define PeekMessageW(...) ErgoptiPortable_Unsupported("PeekMessageW", __VA_ARGS__)
#define TranslateMessage(...) ErgoptiPortable_Unsupported("TranslateMessage", __VA_ARGS__)
#define DispatchMessageW(...) ErgoptiPortable_Unsupported("DispatchMessageW", __VA_ARGS__)
#define MsgWaitForMultipleObjects(...) ErgoptiPortable_Unsupported("MsgWaitForMultipleObjects", __VA_ARGS__)

#endif
