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
; metrics and keylogger modules. Unlike WinGetTitle, it sends WM_GETTEXT through
; SendMessageTimeoutW with a real OS deadline. Process and class identity use
; local Win32 queries rather than target-thread messages. Any partial or raced
; acquisition is rejected so privacy consumers can fail closed.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; A resident callback shares the only AHK thread with keyboard dispatch. Keep
; the cross-process title wait at or below the profiler’s 5 ms slow threshold.
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

; Reads the executable basename through process APIs that never call the target
; window procedure. A denied or oversized path is a privacy failure, not an
; empty-but-valid process identity.
; @param HWND {Integer} Foreground top-level window handle.
; @return {Object|Boolean} { name, process_id }, or false on failure.
_WIReadProcessIdentityLocal(HWND) {
	ProcessId := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", HWND,
		"UInt*", &ProcessId, "UInt")
	if !ThreadId || !ProcessId
		return false

	ProcessHandle := DllCall("Kernel32\OpenProcess", "UInt",
		WI_PROCESS_QUERY_LIMITED_INFORMATION, "Int", false, "UInt", ProcessId,
		"Ptr")
	if !ProcessHandle
		return false

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
		return ProcessName != ""
			? { name: ProcessName, process_id: ProcessId }
			: false
	} finally {
		try DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle)
	}
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

; Captures the foreground identity through one bounded, fail-closed adapter
; seam. The final HWND check rejects a focus switch that occurred between any
; two fields so consumers never see a title from one window paired with another
; process or class.
; @param TitleTimeoutMs {Integer} WM_GETTEXT deadline in milliseconds.
; @return {Object} Complete accepted or rejected snapshot.
WICaptureBoundedFocusSnapshot(TitleTimeoutMs := WI_FOCUS_TITLE_TIMEOUT_MS) {
	if !IsNumber(TitleTimeoutMs) || TitleTimeoutMs <= 0
		throw ValueError("Focus title timeout must be a positive number")
	BoundedTimeoutMs := Round(TitleTimeoutMs)
	if (BoundedTimeoutMs <= 0)
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

		ProcessIdentity := _WIReadProcessIdentityLocal(HWND)
		if !IsObject(ProcessIdentity)
			return _WIRejectedFocusSnapshot("process_unavailable")

		ClassName := _WIReadClassNameLocal(HWND)
		if !(ClassName is String)
			return _WIRejectedFocusSnapshot("class_unavailable")

		TitleResult := _WIReadTitleBounded(HWND, BoundedTimeoutMs)
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
