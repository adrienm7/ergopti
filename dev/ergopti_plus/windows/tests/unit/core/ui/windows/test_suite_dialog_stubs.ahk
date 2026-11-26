; tests/unit/core/ui/windows/test_suite_dialog_stubs.ahk

; ==============================================================================
; MODULE: Suite Native Dialog Stubs Tests
; DESCRIPTION:
; A test path that reaches a native modal must not show it on the desktop: the
; suite answers MsgBox and InputBox itself (maintainer report 2026-11-21, the
; LLM provider prompt appeared during agents' runs).
; ==============================================================================

#Requires AutoHotkey v2.0

_TSDS_InputBoxAnswersCancel() {
	Before := TestInputBoxCount()
	Started := A_TickCount
	; A real InputBox would show here and block until its 5 s timeout.
	Result := Ui_InputBox("Provider id (openai):", "API endpoint", "w520 h150 T5", "openai")
	AssertTrue(A_TickCount - Started < 2000, "no native prompt may wait for a person")
	AssertEqual("Cancel", Result.Result, "the unanswered stub reads as the user closing the prompt")
	AssertEqual("", Result.Value)
	AssertEqual(Before + 1, TestInputBoxCount(), "the stub counts the prompt it absorbed")
}
Test("Suite dialog stubs: an unanswered InputBox opens no window and reads as Cancel (suite-native-dialog-stubs)",
	_TSDS_InputBoxAnswersCancel)

_TSDS_InputBoxResponder() {
	Calls := []
	TestInputBoxResponder((Prompt, Title, Options, Default) => (Calls.Push({Prompt: Prompt, Title: Title,
		Options: Options, Default: Default}), {Result: "OK", Value: "mistral"}))
	try Result := Ui_InputBox("Provider id:", "API endpoint", "w520 h150", "openai")
	finally TestInputBoxResponder("")
	AssertEqual("OK", Result.Result)
	AssertEqual("mistral", Result.Value, "a test may answer in the user's place")
	AssertEqual(1, Calls.Length)
	AssertEqual(WindowTitle("API endpoint"), Calls[1].Title, "the production caption reaches the stub")
	AssertEqual("openai", Calls[1].Default)
}
Test("Suite dialog stubs: a test can answer the InputBox in the user's place (suite-native-dialog-stubs)",
	_TSDS_InputBoxResponder)
