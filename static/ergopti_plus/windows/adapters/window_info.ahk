; adapters/window_info.ahk

; ==============================================================================
; MODULE: WindowInfo Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the WindowInfo port contract defined in
; static/ergopti_plus/_shared/core/ports/WindowInfo.spec.js. Wraps AHK v2's
; WinGetTitle, WinGetProcessName, WinGetList, and WinGetID built-ins behind
; the two canonical functions (WIGetFocused, WIGetAll) so domain modules can
; query foreground-window identity without coupling to AHK-specific APIs. The
; Windows-only focus helpers expose bounded HWND identity for keyboard-context
; generations without expanding the shared port.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   getFocused() → WIGetFocused()
;   getAll()     → WIGetAll()
;
; RETURN SHAPE:
; Both functions return Map objects with the four contract fields:
;   { "appId", "windowTitle", "bundleId", "executablePath" }
; bundleId is always "" on Windows (macOS-only concept).
; executablePath is the full path from WinGetProcessPath when available.
;
; FAIL-SAFE:
; All AHK window API calls are wrapped in try/catch. If the foreground window
; cannot be queried (locked screen, UAC elevation, restricted process),
; WIGetFocused returns an empty-field Map rather than throwing.
;
; BOUNDED FOCUS SNAPSHOT:
; WICaptureBoundedFocusSnapshot is the Windows-only privacy path used by the
; metrics and keylogger modules. Its resident poll reads the system-cached
; top-level caption without messaging the target process and retains one exact
; process handle so path resolution runs only when the process identity changes.
; Any partial or raced acquisition is rejected so privacy consumers fail closed.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Transactional dispatch callers still use a bounded target-window title read.
; Keep that cross-process wait at or below the profiler's 5 ms slow threshold.
global WI_FOCUS_TITLE_TIMEOUT_MS := 5
; A top-level caption that reaches this bound is rejected rather than truncated:
; dropping its suffix could hide a private-browsing marker.
global WI_FOCUS_TITLE_MAX_CHARS := 4096
; Win32 class names are capped at 256 characters including the terminator.
global WI_FOCUS_CLASS_MAX_CHARS := 256
; Long executable paths beyond this conservative buffer fail closed.
global WI_FOCUS_PROCESS_PATH_MAX_CHARS := 2048
; WM_GETTEXT is a system message, so User32 marshals its buffer cross-process.
global WI_WM_GETTEXT := 0x000D
; Do not add SMTO_NOTIMEOUTIFNOTHUNG: it explicitly disables the deadline while
; the target pumps messages, recreating an unbounded wait.
global WI_SMTO_BOUNDED_FLAGS := 0x0023  ; BLOCK | ABORTIFHUNG | ERRORONEXIT
global WI_PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
global WI_PROCESS_SYNCHRONIZE := 0x00100000

class WIFocusProcessCache {
	static process_id := 0
	static process_handle := 0
	static process_name := ""
	static generation := 0
	; Handles whose CloseHandle receipt was refused remain exact owners here.
	; A new process identity is not admitted until this debt is discharged.
	static cleanup_debt := []
	; Injectable native seams used only by the cache regression tests.
	static acquire_fn := 0
	static alive_fn := 0
	static close_fn := 0
}





; =======================================
; =======================================
; ======= 2/ Internal Helpers ===========
; =======================================
; =======================================

; Returns an empty WindowInfo Map with all four fields set to "".
_WIEmptyInfo() {
	return Map(
		"appId",          "",
		"windowTitle",    "",
		"bundleId",       "",
		"executablePath", ""
	)
}

; Builds a WindowInfo Map for a given window HWND.
; @param HWND {Integer} Window handle (0 = active window "A").
; @return {Map} WindowInfo Map.
_WIInfoFromHwnd(HWND) {
	local Info := _WIEmptyInfo()
	local WinSpec := HWND = 0 ? "A" : "ahk_id " . HWND
	try {
		local Title := WinGetTitle(WinSpec)
		if Title != ""
			Info["windowTitle"] := Title
	}
	try {
		local ProcName := WinGetProcessName(WinSpec)
		if ProcName != ""
			Info["appId"] := ProcName
	}
	try {
		local ProcPath := WinGetProcessPath(WinSpec)
		if ProcPath != ""
			Info["executablePath"] := ProcPath
	}
	return Info
}

; Returns a complete rejected snapshot. Consumers treat every rejected probe as
; private; empty fields are diagnostic only and must never be interpreted as a
; permissive context.
; @param Reason {String} Stable acquisition failure category.
; @param TimedOut {Boolean} Whether the bounded title transaction timed out.
; @return {Object} Rejected focus snapshot.
_WIRejectedFocusSnapshot(Reason, TimedOut := false) {
	return {
		ok: false,
		hwnd: 0,
		process_name: "",
		title: "",
		class: "",
		failure_reason: Reason,
		timed_out: TimedOut
	}
}

; Acquires one retained process identity. The handle is deliberately returned
; to the cache: while it remains open, Windows cannot recycle the PID into a
; different process without WaitForSingleObject first reporting termination.
_WIAcquireProcessIdentity(ProcessId) {
	ProcessHandle := DllCall("Kernel32\OpenProcess", "UInt",
		WI_PROCESS_QUERY_LIMITED_INFORMATION | WI_PROCESS_SYNCHRONIZE,
		"Int", false, "UInt", ProcessId,
		"Ptr")
	if !ProcessHandle
		return false

	Succeeded := false
	try {
		PathBuffer := Buffer(WI_FOCUS_PROCESS_PATH_MAX_CHARS * 2, 0)
		PathChars := WI_FOCUS_PROCESS_PATH_MAX_CHARS
		if !DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", ProcessHandle,
			"UInt", 0, "Ptr", PathBuffer.Ptr, "UInt*", &PathChars, "Int")
			return false
		if (PathChars <= 0 || PathChars >= WI_FOCUS_PROCESS_PATH_MAX_CHARS)
			return false
		ProcessPath := StrGet(PathBuffer, PathChars, "UTF-16")
		SplitPath(ProcessPath, &ProcessName)
		if (ProcessName = "")
			return false
		Succeeded := true
		return {
			name: ProcessName,
			process_id: ProcessId,
			process_handle: ProcessHandle
		}
	} finally {
		if !Succeeded
			try DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle)
	}
}

_WIFocusProcessHandleAlive(ProcessHandle) {
	if IsObject(WIFocusProcessCache.alive_fn)
		return !!WIFocusProcessCache.alive_fn.Call(ProcessHandle)
	return ProcessHandle
		&& DllCall("Kernel32\WaitForSingleObject", "Ptr", ProcessHandle,
			"UInt", 0, "UInt") = 0x00000102
}

_WIFocusCloseProcessHandle(ProcessHandle) {
	if !ProcessHandle
		return true
	try {
		if IsObject(WIFocusProcessCache.close_fn)
			return WIFocusProcessCache.close_fn.Call(ProcessHandle) == true
		return DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle, "Int") != 0
	} catch {
		return false
	}
}

_WIFocusQueueProcessCleanupDebt(ProcessHandle) {
	if !ProcessHandle
		return false
	PreviousCritical := Critical("On")
	try {
		for ExistingHandle in WIFocusProcessCache.cleanup_debt {
			if ExistingHandle == ProcessHandle
				return false
		}
		WIFocusProcessCache.cleanup_debt.Push(ProcessHandle)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_WIFocusReleaseProcessHandle(ProcessHandle) {
	if !ProcessHandle
		return true
	if _WIFocusCloseProcessHandle(ProcessHandle)
		return true
	_WIFocusQueueProcessCleanupDebt(ProcessHandle)
	return false
}

_WIFocusDrainProcessCleanupDebt() {
	PreviousCritical := Critical("On")
	try {
		if WIFocusProcessCache.cleanup_debt.Length = 0
			return true
		Pending := WIFocusProcessCache.cleanup_debt
		WIFocusProcessCache.cleanup_debt := []
	} finally {
		Critical(PreviousCritical)
	}
	for ProcessHandle in Pending {
		if !_WIFocusCloseProcessHandle(ProcessHandle)
			_WIFocusQueueProcessCleanupDebt(ProcessHandle)
	}
	PreviousCritical := Critical("On")
	try return WIFocusProcessCache.cleanup_debt.Length = 0
	finally Critical(PreviousCritical)
}

; Clears the retained identity and invalidates an acquisition that was already
; outside Critical. Stop/suspend calls this after retiring snapshot ownership.
_WIResetFocusProcessCache() {
	PreviousCritical := Critical("On")
	try {
		ProcessHandle := WIFocusProcessCache.process_handle
		WIFocusProcessCache.process_id := 0
		WIFocusProcessCache.process_handle := 0
		WIFocusProcessCache.process_name := ""
		WIFocusProcessCache.generation += 1
	} finally {
		Critical(PreviousCritical)
	}
	if ProcessHandle
		_WIFocusQueueProcessCleanupDebt(ProcessHandle)
	return _WIFocusDrainProcessCleanupDebt()
}

; Resolves a process basename once per live PID. The 20 Hz focus poll used to
; execute OpenProcess + QueryFullProcessImageNameW on every tick, accounting for
; most of the 117 seconds of resident stalls observed in production. A retained
; handle makes the cache safe against PID reuse instead of relying on time.
_WIReadProcessIdentityCached(ProcessId) {
	if !ProcessId
		return false
	; A refused close retains an exact live kernel owner. Retry it before opening
	; another process handle so a transient failure cannot grow without bound.
	if !_WIFocusDrainProcessCleanupDebt()
		return false
	PreviousCritical := Critical("On")
	try {
		CacheMatches := (WIFocusProcessCache.process_id = ProcessId
			&& WIFocusProcessCache.process_name != ""
			&& WIFocusProcessCache.process_handle)
		CachedName := CacheMatches ? WIFocusProcessCache.process_name : ""
		CachedHandle := CacheMatches ? WIFocusProcessCache.process_handle : 0
	} finally {
		Critical(PreviousCritical)
	}
	if (CachedHandle && _WIFocusProcessHandleAlive(CachedHandle)) {
		return {
			name: CachedName,
			process_id: ProcessId
		}
	}

	PreviousCritical := Critical("On")
	try {
		WIFocusProcessCache.generation += 1
		RequestGeneration := WIFocusProcessCache.generation
	} finally {
		Critical(PreviousCritical)
	}
	AcquireFn := WIFocusProcessCache.acquire_fn
	try Acquired := IsObject(AcquireFn)
		? AcquireFn.Call(ProcessId) : _WIAcquireProcessIdentity(ProcessId)
	catch
		Acquired := false
	if !IsObject(Acquired) || !Acquired.HasOwnProp("name")
		|| !Acquired.HasOwnProp("process_id")
		|| !Acquired.HasOwnProp("process_handle")
		|| Acquired.process_id != ProcessId || Acquired.name = ""
		|| !Acquired.process_handle {
		if IsObject(Acquired) && Acquired.HasOwnProp("process_handle")
			if !_WIFocusReleaseProcessHandle(Acquired.process_handle)
				try LoggerError("WindowInfo",
					"Could not close a rejected focus-process handle.")
		return false
	}

	PreviousCritical := Critical("On")
	try {
		if (RequestGeneration != WIFocusProcessCache.generation) {
			Accepted := false
			PreviousHandle := 0
		} else {
			Accepted := true
			PreviousHandle := WIFocusProcessCache.process_handle
			WIFocusProcessCache.process_id := ProcessId
			WIFocusProcessCache.process_handle := Acquired.process_handle
			WIFocusProcessCache.process_name := Acquired.name
		}
	} finally {
		Critical(PreviousCritical)
	}
	if !Accepted {
		if !_WIFocusReleaseProcessHandle(Acquired.process_handle)
			try LoggerError("WindowInfo",
				"Could not close a superseded focus-process handle.")
		return false
	}
	if (PreviousHandle && PreviousHandle != Acquired.process_handle) {
		if !_WIFocusReleaseProcessHandle(PreviousHandle) {
			try LoggerError("WindowInfo",
				"Could not close the previous focus-process handle.")
			return false
		}
	}
	return { name: Acquired.name, process_id: ProcessId }
}

; Reads a class name without sending a message to the target process.
; @param HWND {Integer} Foreground top-level window handle.
; @return {String|Boolean} Class name, or false on failure/truncation.
_WIReadClassNameLocal(HWND) {
	ClassBuffer := Buffer(WI_FOCUS_CLASS_MAX_CHARS * 2, 0)
	ClassChars := DllCall("User32\GetClassNameW", "Ptr", HWND,
		"Ptr", ClassBuffer.Ptr, "Int", WI_FOCUS_CLASS_MAX_CHARS, "Int")
	if (ClassChars <= 0 || ClassChars >= WI_FOCUS_CLASS_MAX_CHARS - 1)
		return false
	return StrGet(ClassBuffer, ClassChars, "UTF-16")
}

; Reads a top-level caption with an OS-enforced deadline. SMTO_BLOCK prevents a
; nested AHK callback from reusing the local buffer while User32 waits; unlike a
; Critical span it does not keep unrelated AHK work non-interruptible before or
; after the native transaction.
; @param HWND {Integer} Foreground top-level window handle.
; @param TimeoutMs {Integer} Hard SendMessageTimeoutW deadline in milliseconds.
; @return {Object} { ok, title, timed_out }.
_WIReadTitleBounded(HWND, TimeoutMs) {
	if !IsNumber(TimeoutMs) || TimeoutMs <= 0
		throw ValueError("Focus title timeout must be a positive number")
	BoundedTimeoutMs := Min(Round(TimeoutMs), WI_FOCUS_TITLE_TIMEOUT_MS)
	if (BoundedTimeoutMs <= 0)
		throw ValueError("Focus title timeout rounds below one millisecond")
	TitleBuffer := Buffer(WI_FOCUS_TITLE_MAX_CHARS * 2, 0)
	MessageResult := 0
	DllCall("Kernel32\SetLastError", "UInt", 0)
	Sent := DllCall("User32\SendMessageTimeoutW",
		"Ptr", HWND, "UInt", WI_WM_GETTEXT,
		"UPtr", WI_FOCUS_TITLE_MAX_CHARS, "Ptr", TitleBuffer.Ptr,
		"UInt", WI_SMTO_BOUNDED_FLAGS, "UInt", BoundedTimeoutMs,
		"UPtr*", &MessageResult, "Ptr")
	if !Sent {
		; SendMessageTimeout does not reliably set LastError on timeout, so every
		; zero result is conservatively classified as deadline/failure.
		return { ok: false, title: "", timed_out: true }
	}
	if (MessageResult >= WI_FOCUS_TITLE_MAX_CHARS - 1)
		return { ok: false, title: "", timed_out: false }
	return {
		ok: true,
		title: StrGet(TitleBuffer, MessageResult, "UTF-16"),
		timed_out: false
	}
}

; GetWindowTextW reads the system-owned caption for another process's top-level
; window instead of sending WM_GETTEXT to that process. This is the resident
; focus-poll primitive: it cannot inherit a hung target window procedure.
_WIReadForegroundTitleLocal(HWND) {
	TitleBuffer := Buffer(WI_FOCUS_TITLE_MAX_CHARS * 2, 0)
	DllCall("Kernel32\SetLastError", "UInt", 0)
	TitleChars := DllCall("User32\GetWindowTextW", "Ptr", HWND,
		"Ptr", TitleBuffer.Ptr, "Int", WI_FOCUS_TITLE_MAX_CHARS, "Int")
	LastError := DllCall("Kernel32\GetLastError", "UInt")
	if (TitleChars < 0 || TitleChars >= WI_FOCUS_TITLE_MAX_CHARS - 1)
		return { ok: false, title: "", timed_out: false }
	if (TitleChars = 0 && LastError != 0)
		return { ok: false, title: "", timed_out: false }
	return {
		ok: true,
		title: TitleChars > 0
			? StrGet(TitleBuffer, TitleChars, "UTF-16") : "",
		timed_out: false
	}
}

; Captures the foreground identity through one bounded, fail-closed adapter
; seam. The final HWND check rejects a focus switch that occurred between any
; two fields so consumers never see a title from one window paired with another
; process or class.
; @param TitleTimeoutMs {Integer} Compatibility validation for existing callers.
; @return {Object} Complete accepted or rejected snapshot.
WICaptureBoundedFocusSnapshot(TitleTimeoutMs := WI_FOCUS_TITLE_TIMEOUT_MS) {
	if !IsNumber(TitleTimeoutMs) || TitleTimeoutMs <= 0
		throw ValueError("Focus title timeout must be a positive number")
	if (Round(TitleTimeoutMs) <= 0)
		throw ValueError("Focus title timeout rounds below one millisecond")

	; Enforce the non-Critical boundary inside the adapter as well as at the
	; resident caller. A future caller cannot accidentally stretch its own
	; non-interruptible transaction across the target-window message.
	InheritedCritical := A_IsCritical
	if InheritedCritical
		Critical("Off")
	try {
		HWND := DllCall("User32\GetForegroundWindow", "Ptr")
		if !HWND
			return _WIRejectedFocusSnapshot("no_foreground_window")

		ProcessId := 0
		ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", HWND,
			"UInt*", &ProcessId, "UInt")
		if !ThreadId || !ProcessId
			return _WIRejectedFocusSnapshot("process_unavailable")

		ProcessIdentity := _WIReadProcessIdentityCached(ProcessId)
		if !IsObject(ProcessIdentity)
			return _WIRejectedFocusSnapshot("process_unavailable")

		ClassName := _WIReadClassNameLocal(HWND)
		if !(ClassName is String)
			return _WIRejectedFocusSnapshot("class_unavailable")

		TitleResult := _WIReadForegroundTitleLocal(HWND)
		if !TitleResult.ok
			return _WIRejectedFocusSnapshot("title_unavailable",
				TitleResult.timed_out)

		FinalProcessId := 0
		FinalThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", HWND,
			"UInt*", &FinalProcessId, "UInt")
		if DllCall("User32\GetForegroundWindow", "Ptr") != HWND
			|| !FinalThreadId || FinalProcessId != ProcessIdentity.process_id
			return _WIRejectedFocusSnapshot("focus_changed")

		return {
			ok: true,
			hwnd: HWND,
			process_name: ProcessIdentity.name,
			title: TitleResult.title,
			class: ClassName,
			failure_reason: "",
			timed_out: false
		}
	} catch {
		return _WIRejectedFocusSnapshot("native_error")
	} finally {
		if InheritedCritical
			Critical(InheritedCritical)
	}
}




; ===========================================
; ===========================================
; ======= 3/ Adapter Methods ================
; ===========================================
; ===========================================

; Returns the identity of the currently focused window.
; @return {Map} WindowInfo: { appId, windowTitle, bundleId, executablePath }
WIGetFocused() {
	try {
		return _WIInfoFromHwnd(0)
	} catch {
		return _WIEmptyInfo()
	}
}

; Returns the foreground top-level HWND without invoking title/process lookups.
; @return {Integer} Foreground HWND, or 0 when Windows has no foreground owner.
WIGetForegroundHwnd() {
	try return DllCall("User32\GetForegroundWindow", "Ptr")
	return 0
}

; Returns a stable identity for the focused Win32 control. GUI-thread focus is
; more precise than the foreground top-level HWND (an editor, Find box and
; address bar can all live in one window). Windowless/restricted controls may
; expose no child HWND; falling back to the foreground HWND still detects an
; application/window switch. Zero means focus could not be verified, so callers
; can fail closed instead of applying an old buffer in an unknown control.
; @return {Integer} Focused-control HWND, foreground HWND fallback, or 0.
WIGetFocusedControlToken() {
	static Info := Buffer(8 + 6 * A_PtrSize + 16, 0)
	PreviousCritical := Critical("On")
	try {
		; GUITHREADINFO is two DWORDs, six HWND-sized fields, then RECT (4 LONGs).
		; Thread 0 asks Windows for the foreground queue directly, avoiding a
		; foreground-HWND + thread-id round trip on every physical character.
		; The static buffer removes the matching hot-path allocation; Critical only
		; protects that buffer across this non-blocking in-process API call.
		NumPut("UInt", Info.Size, Info, 0)
		if DllCall("User32\GetGUIThreadInfo", "UInt", 0, "Ptr", Info.Ptr, "Int") {
			FocusHwnd := NumGet(Info, 8 + A_PtrSize, "Ptr")
			if FocusHwnd
				return FocusHwnd
			ActiveHwnd := NumGet(Info, 8, "Ptr")
			if ActiveHwnd
				return ActiveHwnd
		}
		return DllCall("User32\GetForegroundWindow", "Ptr")
	} catch {
		return 0
	} finally {
		Critical(PreviousCritical)
	}
}

; Returns an array of WindowInfo Maps for all visible windows.
; @return {Array} Array of WindowInfo Maps (may be empty).
WIGetAll() {
	local Results := []
	try {
		local HWNDs := WinGetList()
		for HWND in HWNDs {
			try {
				local Info := _WIInfoFromHwnd(HWND)
				; Skip windows with no process name (system internals, invisible windows)
				if Info["appId"] != ""
					Results.Push(Info)
			} catch as Err {
				; A window closing mid-enumeration (a routine race, not a bug)
				; throws TargetError on the next WinGet* call for that HWnd — skip
				; just this window instead of aborting the whole enumeration,
				; mirroring the identical TOCTOU guard already applied to
				; GestureGetCyclableWindows.
				try LoggerDebug("WindowInfo", "WIGetAll: skipped ahk_id {1}: {2}.", HWND, Err.Message)
				continue
			}
		}
	}
	return Results
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_WINDOW_INFO := Map(
    "getFocused", WIGetFocused,
    "getAll",     WIGetAll,
)
