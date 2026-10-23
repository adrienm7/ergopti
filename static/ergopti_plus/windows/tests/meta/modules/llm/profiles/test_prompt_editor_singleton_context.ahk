; tests/meta/modules/llm/profiles/test_prompt_editor_singleton_context.ahk

; ==============================================================================
; MODULE: Prompt Editor Singleton Context
; DESCRIPTION:
; Re-opening the prompt editor for another profile must re-point its
; singleton at that profile before the early return.
; ==============================================================================

#Requires AutoHotkey v2.0

; signals strands the safety fallback.
; F-26  _PromptEdWeb_TryOpen captured the open context BELOW its singleton
; early-return, so re-opening for a different profile kept the previous
_A0720WV_PromptEditorCapturesContextBeforeSingleton() {
	Body := _DriverFuncBody("_PromptEdWeb_TryOpen")
	Assert(Body != "", "_PromptEdWeb_TryOpen must exist in ui/prompt_editor/init.ahk")

	CapturePos := InStr(Body, "Context := _PromptEdWeb_BeginContext(")
	WindowPos := InStr(Body, "Window := _PromptEdWeb_Gui")
	ActivatePos := InStr(Body, "WMPresentWindow(Window)")
	Assert(CapturePos > 0 and WindowPos > 0 and ActivatePos > 0,
		"prerequisite: real context capture, captured singleton and native presentation must be present")
	Assert(CapturePos < WindowPos and WindowPos < ActivatePos,
		"_PromptEdWeb_TryOpen must capture the open context BEFORE the singleton early-return — otherwise re-opening the editor for a different profile keeps the previous _PromptEdWeb_EditId, the window merely gains focus still bound to the old profile, and saving overwrites the WRONG profile with the new one's edits")
}
Test("prompt-editor: the singleton re-points at the new profile (F-26)",
	_A0720WV_PromptEditorCapturesContextBeforeSingleton)
