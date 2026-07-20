; tests/meta/test_screenshot_async_run.ahk

; ==============================================================================
; MODULE: Screenshot Async Run Meta-Test
; DESCRIPTION:
; Structural regression for the screenshot hotkey fix in modules/shortcuts/win.ahk.
;
; Before the fix the SC029 hotkey called RunWait() to invoke the PowerShell
; screen capture script. RunWait blocks the calling AHK thread until the child
; process exits. Because the hotkey fires on the keyboard hook thread, this
; blocked ALL keyboard processing (input drops, modifier key hangs) for the
; entire duration of the PowerShell process — typically 300-800 ms.
;
; The fix replaces RunWait with Run (async) so the hook thread returns
; immediately. The TrayTip notification fires optimistically before the file
; appears on disk; the race is acceptable because the notification is cosmetic.
;
; This test inspects shortcuts/win.ahk source and asserts:
;   1. RunWait is NOT used in the screenshot block.
;   2. A Run( call IS present in the screenshot block.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Source-inspection helpers =====================
; ==========================================================
; ==========================================================

; Move-resilient: scan the shortcuts module dir via the framework helper instead
; of a pinned win.ahk path. SC029:: is unique within modules/shortcuts (only the
; screenshot hotkey lives here; layout.ahk's SC029:: is in modules/, out of scope),
; so the first-match extraction below still targets the screenshot block. The
; ~600-char window stays inside win.ahk (the block sits well before EOF), so it
; never spills into a neighbouring file's content.
_SAR_FindScreenshotBlock(src) {
	pos := InStr(src, "SC029::")
	if (!pos)
		return ""
	; Capture through the closing #HotIf.  This keeps the test coupled to the
	; complete callback rather than a brittle character window: additional
	; error handling must not become invisible to the regression guard.
	endPos := InStr(src, "#HotIf", false, pos + StrLen("SC029::"))
	return endPos ? SubStr(src, pos, endPos - pos) : ""
}

; This test fragment is loaded through run_all.ahk, where test_framework.ahk
; supplies _DriverDirConcat. Consume its exported callable reference so isolated
; #Warn analysis does not mistake the cross-include function name for an unset
; local variable. A missing framework helper still fails loudly at test runtime.
_SAR_ShortcutsSource() {
	global _DriverDirConcatFn
	return _DriverDirConcatFn.Call("modules/shortcuts")
}




; ==========================================================
; ==========================================================
; ======= 2/ Assertions ====================================
; ==========================================================
; ==========================================================

_SAR_NoRunWait() {
	block := _SAR_FindScreenshotBlock(_SAR_ShortcutsSource())
	Assert(block != "",
		"shortcuts/win.ahk: SC029 screenshot hotkey block must be present")
	Assert(InStr(block, "RunWait") = 0,
		"shortcuts/win.ahk: SC029 must not use RunWait — it blocks the keyboard hook thread during screen capture")
}
Test("Screenshot hotkey: RunWait not used in SC029 block (screenshot-async-run)", _SAR_NoRunWait)


_SAR_AsyncRunPresent() {
	block := _SAR_FindScreenshotBlock(_SAR_ShortcutsSource())
	; Run( with an opening paren distinguishes the Run function from RunWait.
	Assert(InStr(block, "Run(") > 0,
		"shortcuts/win.ahk: SC029 must call Run() (async) instead of RunWait for the PowerShell capture process")
}
Test("Screenshot hotkey: async Run() used in SC029 block (screenshot-async-run)", _SAR_AsyncRunPresent)

_SAR_HotkeyBoundariesAreContained() {
	block := _SAR_FindScreenshotBlock(_SAR_ShortcutsSource())
	Assert(InStr(block, "try") > 0 && InStr(block, "catch as Err") > 0,
		"SC029 must contain desktop, filesystem, and Run failures inside the hotkey callback")
	Assert(InStr(block, "LoggerError") > 0,
		"SC029 must log an OS launch failure rather than silently losing the screenshot action")
	Assert(InStr(block, "MsgBox") = 0,
		"SC029 must not open a modal dialog from the keyboard hotkey thread")
	Assert(InStr(block, "TrayTip") > 0,
		"SC029 must give nonblocking feedback for both unavailable windows and launch failures")
}
Test("Screenshot hotkey: SC029 contains OS failures and never blocks on a modal dialog", _SAR_HotkeyBoundariesAreContained)

_SAR_GestureInstantBoundariesAreContained() {
	Body := _DriverFuncBody("GestureScreenshotInstant")
	Assert(Body != "", "GestureScreenshotInstant must exist")
	Assert(InStr(Body, "try") > 0 && InStr(Body, "catch as Err") > 0,
		"GestureScreenshotInstant must contain desktop, filesystem, and Run failures")
	Assert(InStr(Body, "LoggerError") > 0 && InStr(Body, "TrayTip") > 0,
		"a failed instant gesture screenshot must be logged and reported non-modally")
	Assert(InStr(Body, "MsgBox") = 0,
		"GestureScreenshotInstant must not stall the driver's message thread with a modal dialog")
	; The instant capture now delegates to the shared hardened path (F23) instead of
	; launching its own worker, so the asynchronous-worker invariant is enforced on
	; GestureCaptureRegion — pinned by the F-H07 test below. What must hold HERE is that
	; the instant path goes through it and never spawns a blocking worker of its own.
	Assert(InStr(Body, "GestureCaptureRegion(") > 0,
		"GestureScreenshotInstant must dispatch through GestureCaptureRegion's asynchronous worker")
	Assert(InStr(Body, "RunWait") = 0,
		"GestureScreenshotInstant must never block the keyboard hook thread with RunWait")
}
Test("Gesture screenshot: instant capture contains OS failures and remains nonblocking", _SAR_GestureInstantBoundariesAreContained)


; F-H07: GestureCaptureRegion (window/fullscreen capture) used RunWait, blocking the
; keyboard hook thread for the whole PowerShell capture (~300-1500 ms) on every such
; screenshot gesture — the SC029 fix missed it. It must now use async Run. (The region
; Region saving used to be deliberately synchronous, but that blocked the hook thread for
; up to the 30-second Snipping Tool selection plus a PowerShell process.  Its transaction
; is now timer-driven; the hotkey must never contain either a long ClipWait or RunWait.
_SAR_GestureCaptureNoRunWait() {
	Body := _DriverFuncBody("GestureCaptureRegion")
	Assert(Body != "", "GestureCaptureRegion(X,Y,W,H,Mode,Path) must exist")
	Assert(InStr(Body, "RunWait") = 0,
		"GestureCaptureRegion must not use RunWait — it blocks the keyboard hook thread on every window/fullscreen screenshot gesture (gesture-capture-async-run)")
	Assert(InStr(Body, "Run(") > 0,
		"GestureCaptureRegion must launch the capture via async Run()")
}
Test("Gesture screenshot: GestureCaptureRegion uses async Run, not RunWait (gesture-capture-async-run)", _SAR_GestureCaptureNoRunWait)

_SAR_RegionCaptureNoBlockingWait() {
        Body := _DriverFuncBody("GestureScreenshotRegion")
        Assert(Body != "", "GestureScreenshotRegion(Mode) must exist")
        Assert(InStr(Body, "RunWait") = 0, "region screenshot hotkey must not wait for PowerShell")
        Assert(InStr(Body, "ClipWait(30") = 0, "region screenshot hotkey must not wait up to 30 seconds for user selection")
        Assert(InStr(Body, "SetTimer(GestureRegionCapturePoll.Bind(Epoch)") > 0,
                "region screenshot must hand selection tracking to an epoch-bound timer")
}
Test("Gesture screenshot: region save defers selection and PowerShell (gesture-region-async)", _SAR_RegionCaptureNoBlockingWait)

_SAR_DirectCaptureConfirmsOutputBeforeSuccess() {
	CaptureBody := _DriverFuncBody("GestureCaptureRegion")
	PollBody := _DriverFuncBody("GestureDirectCapturePoll")
	CompleteBody := _DriverFuncBody("GestureScreenshotComplete")
	WindowBody := _DriverFuncBody("GestureScreenshotWindow")
	Assert(InStr(CaptureBody, "Run(") > 0 and InStr(CaptureBody, "&Pid)") > 0
		and InStr(CaptureBody, "_GestureDirectCaptures[Epoch]") > 0
		and InStr(CaptureBody, "SetTimer(GestureDirectCapturePoll.Bind(Epoch)") > 0,
		"direct screenshot capture must retain its worker identity and defer completion; a successful Run only proves process launch")
	Assert(InStr(PollBody, 'ProcessExist(State["pid"])') > 0
		and InStr(PollBody, 'FileExist(State["path"])') > 0
		and InStr(PollBody, 'CB_GetSequenceNumber() != State["clipboard_sequence"]') > 0
		and InStr(PollBody, "CB_HasImage()") > 0,
		"completion must require a terminated worker plus a save-file or new image clipboard postcondition")
	Assert(InStr(CompleteBody, "if !Ok") > 0 and InStr(CompleteBody, "LoggerSuccess") > 0,
		"only the confirmed completion callback may emit screenshot success")
	Assert(InStr(WindowBody, "LoggerSuccess") = 0,
		"window screenshot action must not report success synchronously after starting PowerShell")
}
Test("Gesture screenshot: direct capture confirms output before success (screenshot-launch-is-not-success)", _SAR_DirectCaptureConfirmsOutputBeforeSuccess)
