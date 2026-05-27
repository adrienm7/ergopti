; adapters/text_sender.ahk

; ==============================================================================
; MODULE: TextSender Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TextSender port contract defined in
; static/ergopti_plus/shared/ports/TextSender.spec.js. Wraps AHK's SendText,
; SendInput, and the Clipboard port (adapters/clipboard.ahk) behind the three
; canonical functions (TextSend, TextEraseChars, TextPressKey) so domain modules
; can inject text and keystrokes without coupling to AHK-specific send APIs.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   send(text, opts, callback)  → TextSend(Text, Opts, Callback)
;   eraseChars(count)           → TextEraseChars(Count)
;   pressKey(key, modifiers)    → TextPressKey(Key, Modifiers)
;
; CLIPBOARD THRESHOLD:
; Payloads longer than TEXT_CLIPBOARD_THRESHOLD characters (1000, matching
; TextSender.spec.js) are injected via the clipboard to avoid the overhead
; of simulating keystrokes for large expansions.
;
; CLIPBOARD DEPENDENCY:
; The clipboard path uses CB_Save / CB_Write / CB_Restore from the Clipboard
; port adapter (adapters/clipboard.ahk) instead of accessing A_Clipboard directly.
; This keeps clipboard interactions testable via a stub and ensures a single
; code path for all clipboard operations in the driver.
; ==============================================================================

; Payload length threshold above which TextSend switches to clipboard injection.
; Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
global TEXT_CLIPBOARD_THRESHOLD := 1000

; Delay in milliseconds before the clipboard is restored after a paste injection.
; Long enough for the receiving application to process Ctrl+V before we overwrite.
global TEXT_CLIPBOARD_RESTORE_DELAY_MS := 150

; Injectable send primitives — point at the real AHK built-ins by default.
; The test runner replaces these globals with no-op lambdas so no keystroke
; ever reaches the OS during a dry run (mirrors the _SendHook pattern).
global _AHK_SendText  := (Text) => SendText(Text)
global _AHK_SendInput := (Keys) => SendInput(Keys)




; =======================================================
; =======================================================
; ======= 1/ Modifier Name → AHK Prefix Mapping =========
; =======================================================
; =======================================================

; Maps the cross-platform modifier names from the spec to their AHK v2 prefix chars.
_TextSenderModifierPrefix(ModName) {
	switch ModName {
		case "Ctrl", "ctrl":      return "^"
		case "Shift", "shift":    return "+"
		case "Alt", "alt":        return "!"
		case "Cmd", "Win", "win": return "#"
		default:                  return ""
	}
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Methods ============================
; =======================================================
; =======================================================

; Inserts text at the current insertion point.
; Uses the Clipboard port (CB_Save / CB_Write / CB_Restore) for the clipboard
; path so the interaction is mockable and the driver has one canonical clipboard
; code path.
; @param Text     {String}   The Unicode text to insert.
; @param Opts     {Map|0}    { mode?: "direct"|"clipboard"|"auto" }
; @param Callback {Func|0}   Called with no arguments on completion.
TextSend(Text, Opts, Callback) {
	global TEXT_CLIPBOARD_THRESHOLD, TEXT_CLIPBOARD_RESTORE_DELAY_MS
	Mode := "auto"
	if (Opts is Map) and Opts.Has("mode") and Opts["mode"] != ""
		Mode := Opts["mode"]

	; Resolve "auto" to a concrete strategy based on payload length.
	if Mode = "auto"
		Mode := StrLen(Text) > TEXT_CLIPBOARD_THRESHOLD ? "clipboard" : "direct"

	if Mode = "clipboard" {
		; Save the current clipboard via the Clipboard port so we can restore it
		; cleanly after the paste — avoids losing the user's clipboard content.
		Saved := CB_Save()
		CB_Write(Text)
		ClipWait(1)
		_AHK_SendInput.Call("^v")
		; Restore after a short delay so the paste completes before we overwrite.
		; Capture Saved in the closure so the timer lambda is self-contained.
		SavedForTimer := Saved
		SetTimer(() => CB_Restore(SavedForTimer), -TEXT_CLIPBOARD_RESTORE_DELAY_MS)
	} else {
		; SendText uses the "Text" mode that bypasses hotkey triggers and sends
		; Unicode characters as raw keystrokes — the safest injection path.
		_AHK_SendText.Call(Text)
	}

	if Callback != 0
		try Callback()
}

; Emits Count Backspace keystrokes synchronously.
; @param Count {Integer} Number of Backspace keystrokes to emit.
TextEraseChars(Count) {
	if Count < 1
		return
	loop Count
		_AHK_SendInput.Call("{Backspace}")
}

; Emits a single keystroke with optional modifiers.
; @param Key       {String} Key name (e.g., "Return", "Escape", "F1").
; @param Modifiers {Array}  Array of modifier name strings.
TextPressKey(Key, Modifiers) {
	Prefix := ""
	if (Modifiers is Array) {
		for Mod in Modifiers
			Prefix .= _TextSenderModifierPrefix(Mod)
	}
	_AHK_SendInput.Call(Prefix . "{" . Key . "}")
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TEXT_SENDER := Map(
    "send",       TextSend,
    "eraseChars", TextEraseChars,
    "pressKey",   TextPressKey,
)
