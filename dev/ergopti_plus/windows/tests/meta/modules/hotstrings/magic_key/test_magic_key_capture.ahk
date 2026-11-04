; tests/meta/modules/hotstrings/magic_key/test_magic_key_capture.ahk

; ============================================================================== 
; MODULE: Magic Key capture completion regression test
; DESCRIPTION:
; A native scalar completes through literal EndKey membership, while a
; named Escape is cancellation. Closing the dialog must stop the
; suppressive hook so it cannot consume the next unrelated keystroke.
; ============================================================================== 

#Requires AutoHotkey v2.0

_MKC_CaptureCommitsScalarAndStopsOnClose() {
    Body := _DriverFuncBody("MagicKeyEditor")
    CloseBody := _DriverFuncBody("_MagicKeyEditorClose")

    Assert(Body != "", "MagicKeyEditor() must exist in ui/editors.ahk")
    Assert(CloseBody != "", "MagicKeyEditor Close handler must exist")
    Assert(InStr(Body, 'InputHook("L2 E C I", ScalarEndKeys)') > 0,
        "MagicKeyEditor must use its single-key suppressive capture hook")
    Assert(InStr(Body, 'GuiToShow.OnEvent("Close", _MagicKeyEditorClose.Bind(IH))') > 0,
        "MagicKeyEditor must wire Close to stop the active capture hook")
    Prepare := InStr(Body, 'ScalarEndKeys := _SIHO_ScalarEndKeys() . "{Escape}"')
    Create := InStr(Body, 'GuiToShow := Gui_Create(')
    Decode := InStr(Body, 'Capture := _SIHO_ReadScalar(IH, "{Escape}")')
    TextOnly := InStr(Body, 'if Capture.Kind == "text"')
    Persist := InStr(Body, 'ModifyMagicKey(0, Capture.Text)')
    Assert(Prepare > 0 && Create > Prepare && Decode > Create && TextOnly > Decode && Persist > TextOnly,
        "MagicEditor must prepare scalar membership before GUI creation and persist only decoded complete text")
    Assert(InStr(Body, 'ModifyMagicKey(0, IH.Input)') = 0,
        "an incomplete raw input buffer must never reach persistence")
    Assert(InStr(CloseBody, "_MagicKeyEditorStopOwned(IH)") > 0,
        "Closing MagicKeyEditor must stop its suppressive InputHook before the next key arrives")
}

Test("ui: Magic Key capture persists a complete scalar and stops on dialog close",
    _MKC_CaptureCommitsScalarAndStopsOnClose)

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
