; adapters/text_sender.ahk

; ==============================================================================
; MODULE: TextSender Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TextSender port contract defined in
; static/drivers/_shared/ports/TextSender.spec.js. Wraps AHK's SendText,
; SendInput, and Clipboard behind the three canonical functions
; (TextSend, TextEraseChars, TextPressKey) so domain modules can inject
; text and keystrokes without coupling to AHK-specific send APIs.
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
; ==============================================================================

; Payload length threshold above which TextSend switches to clipboard injection.
; Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
global TEXT_CLIPBOARD_THRESHOLD := 1000




; =======================================================
; =======================================================
; ======= 1/ Modifier Name → AHK Prefix Mapping =========
; =======================================================
; =======================================================

; Maps the cross-platform modifier names from the spec to their AHK v2 prefix chars.
_TextSenderModifierPrefix(ModName) {
	switch ModName {
		case "Ctrl", "ctrl":  return "^"
		case "Shift", "shift": return "+"
		case "Alt", "alt":    return "!"
		case "Cmd", "Win", "win": return "#"
		default: return ""
	}
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Methods ============================
; =======================================================
; =======================================================

; Inserts text at the current insertion point.
; @param Text     {String}   The Unicode text to insert.
; @param Opts     {Map|0}    { mode?: "direct"|"clipboard"|"auto" }
; @param Callback {Func|0}   Called with no arguments on completion.
TextSend(Text, Opts, Callback) {
	global TEXT_CLIPBOARD_THRESHOLD
	Mode := "auto"
	if (Opts is Map) and Opts.Has("mode") and Opts["mode"] != ""
		Mode := Opts["mode"]

	; Resolve "auto" to a concrete strategy.
	if Mode = "auto"
		Mode := StrLen(Text) > TEXT_CLIPBOARD_THRESHOLD ? "clipboard" : "direct"

	if Mode = "clipboard" {
		Prev := A_Clipboard
		A_Clipboard := Text
		ClipWait(1)
		SendInput("^v")
		; Restore the previous clipboard after a short delay so the paste completes.
		RestorePrev := Prev
		SetTimer(() => (A_Clipboard := RestorePrev), -150)
	} else {
		; SendText uses the "Text" mode that bypasses hotkey triggers and sends
		; Unicode characters as raw keystrokes — the safest injection path.
		SendText(Text)
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
		SendInput("{Backspace}")
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
	SendInput(Prefix . "{" . Key . "}")
}
