; static/ergopti_plus/windows/tests/meta/test_clipboard_history_paste_wiring.ahk

; ==============================================================================
; MODULE: Clipboard-history paste control-layer wiring regression
; DESCRIPTION:
; The behavioural unit test exercises the provenance router without loading
; layout.ahk, whose top-level hotkeys cannot enter the headless runner. This
; move-resilient source check proves the physical Ctrl+SC02F binding actually
; delegates to that tested router instead of restoring the unsafe direct send.
; ==============================================================================

#Requires AutoHotkey v2.0

_ClipboardHistoryPasteHotkeyUsesProvenanceRoute() {
	Src := _DriverDirConcat("modules/keymap")
	Assert(Src != "", "the keymap source set must be readable")
	Assert(InStr(Src, "^SC02F:: ClipboardHistoryPaste()") > 0,
		"Ctrl+SC02F must delegate to the clipboard-history provenance router")
	Assert(InStr(Src, '^SC02F:: SendFinalResult("^v")') == 0,
		"Ctrl+SC02F must never trust the transient logical Ctrl edge directly")
}

Test("clipboard-history paste: control-layer hotkey uses the provenance route",
	_ClipboardHistoryPasteHotkeyUsesProvenanceRoute)
