; tests/meta/test_magic_key_capture.ahk

; ============================================================================== 
; MODULE: Magic Key capture completion regression test
; DESCRIPTION:
; A one-character InputHook ends with EndReason "Max", not "Stopped". Its
; result must therefore be persisted, while closing the dialog must stop the
; suppressive hook so it cannot consume the next unrelated keystroke.
; ============================================================================== 

#Requires AutoHotkey v2.0

_MKC_CaptureCommitsMaxResultAndStopsOnClose() {
    Body := _DriverFuncBody("MagicKeyEditor")
    CloseBody := _DriverFuncBody("_MagicKeyEditorClose")

    Assert(Body != "", "MagicKeyEditor() must exist in ui/editors.ahk")
    Assert(CloseBody != "", "MagicKeyEditor Close handler must exist")
    Assert(InStr(Body, 'InputHook("L1 I", "{Escape}")') > 0,
        "MagicKeyEditor must use its single-key suppressive capture hook")
    Assert(InStr(Body, 'GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))') > 0,
        "MagicKeyEditor must wire Close to stop the active capture hook")
    Assert(InStr(Body, 'IH.EndReason = "Max" && IH.Input != ""') > 0,
        "MagicKeyEditor must persist a non-empty character captured through the Max end reason")
    Assert(InStr(Body, 'IH.EndReason = "Stopped" && IH.Input != ""') = 0,
        "MagicKeyEditor must not gate persistence on Stopped: L1 capture completes with Max")
    Assert(InStr(CloseBody, "_MagicKeyEditorStopOwned(IH)") > 0,
        "Closing MagicKeyEditor must stop its suppressive InputHook before the next key arrives")
}

Test("ui: Magic Key capture persists Max result and stops on dialog close",
    _MKC_CaptureCommitsMaxResultAndStopsOnClose)

class _MKC_StopRetryHook {
	StopCalls := 0

	Stop() {
		this.StopCalls += 1
		if this.StopCalls == 1
			throw Error("injected magic-key Stop refusal")
	}
}

_MKC_RefusedStopRetainsExactOwner() {
	global _MagicKeyEditorInputHook, _MagicKeyEditorStopDebt
	SavedHook := _MagicKeyEditorInputHook
	SavedDebt := _MagicKeyEditorStopDebt
	Hook := _MKC_StopRetryHook()
	try {
		_MagicKeyEditorInputHook := Hook
		AssertTrue(_MagicKeyEditorClose(Hook, 0),
			"a refused magic-key Stop must cancel the native dialog Close")
		AssertTrue(_MagicKeyEditorInputHook == Hook,
			"a refused magic-key Stop must retain the exact suppressive owner")
		AssertFalse(_MagicKeyEditorClose(Hook, 0),
			"a proved cleanup retry must allow the native dialog Close")
		AssertFalse(IsObject(_MagicKeyEditorInputHook),
			"the magic-key owner may clear only after native Stop succeeds")
		AssertEqual(2, Hook.StopCalls,
			"the cleanup retry must target the original magic-key hook")
	} finally {
		_MagicKeyEditorInputHook := SavedHook
		_MagicKeyEditorStopDebt := SavedDebt
	}
}
Test("ui: Magic Key retains a refused suppressive hook for retry (AHK-170)",
	_MKC_RefusedStopRetainsExactOwner)
