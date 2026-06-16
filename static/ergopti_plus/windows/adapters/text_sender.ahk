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
; The clipboard path uses CB_SaveAll / CB_Write / CB_RestoreAll from the Clipboard
; port adapter (adapters/clipboard.ahk) instead of accessing A_Clipboard directly.
; CB_SaveAll/CB_RestoreAll use ClipboardAll() so non-text content (images, files,
; RTF) is preserved across the paste cycle. CB_Write is text-only (sets A_Clipboard
; to a string) so the paste content itself is always text, which is correct.
; ==============================================================================

; Payload length threshold above which TextSend switches to clipboard injection.
; Mirrors TextSender.spec.js CLIPBOARD_THRESHOLD = 1000.
global TEXT_CLIPBOARD_THRESHOLD := 1000

; Delay in milliseconds before the clipboard is restored after a paste injection.
; Long enough for the receiving application to process Ctrl+V before we overwrite.
global TEXT_CLIPBOARD_RESTORE_DELAY_MS := 150

; Maximum time (seconds) to wait for CB_Write to settle on the clipboard before
; pasting. Small and finite so the deferred worker never stalls perceptibly: most
; apps fill the clipboard in <100 ms, and on timeout we bail loudly rather than
; pasting stale content (fail-fast, project rule 5.3). A full second here would
; have starved the keyboard hook when the wait ran on the input-gating thread —
; the whole round-trip now runs on a one-shot timer off that thread.
global TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC := 0.2

; Monotonic counter bumped on every clipboard-mode TextSend. Each deferred restore
; captures the value current at its scheduling and no-ops if a later injection has
; advanced the counter — this serialises overlapping save/restore windows so a
; stale restore can never clobber a clipboard a newer injection just wrote.
global _TEXT_CLIPBOARD_GENERATION := 0

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

; Builds an AHK prefix from a space-delimited modifier STRING (the AHK-style form
; that dozens of tap-hold / gesture call sites pass, e.g. "Shift", "Ctrl Shift",
; "Blind"). Without this branch the modifiers were silently dropped and the bare
; key was sent (back-Tab became a forward Tab; Ctrl+BackSpace word-delete degraded
; to a single delete). "Blind" maps to the {Blind} prefix and is kept first so a
; held modifier survives; unknown tokens are logged and skipped rather than
; silently corrupting the emitted keystroke.
_TextSenderModifierString(ModStr) {
	Blind := ""
	Prefix := ""
	for Token in StrSplit(Trim(ModStr), " ") {
		Token := Trim(Token)
		if (Token = "")
			continue
		if (Token = "Blind") {
			Blind := "{Blind}"
			continue
		}
		P := _TextSenderModifierPrefix(Token)
		if (P = "") {
			LoggerWarn("TextSender", "TextPressKey: unknown modifier token '{1}' in '{2}' - ignored.", Token, ModStr)
			continue
		}
		Prefix .= P
	}
	return Blind . Prefix
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Methods ============================
; =======================================================
; =======================================================

; Inserts text at the current insertion point.
; Uses the Clipboard port (CB_SaveAll / CB_Write / CB_RestoreAll) for the clipboard
; path so the interaction is mockable and the driver has one canonical clipboard
; code path.
; @param Text     {String}   The Unicode text to insert.
; @param Opts     {Map|0}    { mode?: "direct"|"clipboard"|"auto" }
; @param Callback {Func|0}   Called with no arguments on completion.
TextSend(Text, Opts, Callback) {
	global TEXT_CLIPBOARD_THRESHOLD
	Mode := "auto"
	if (Opts is Map) and Opts.Has("mode") and Opts["mode"] != ""
		Mode := Opts["mode"]

	; Resolve "auto" to a concrete strategy based on payload length.
	if Mode = "auto"
		Mode := StrLen(Text) > TEXT_CLIPBOARD_THRESHOLD ? "clipboard" : "direct"

	if Mode = "clipboard" {
		; The clipboard round-trip (write + blocking ClipWait + paste) is deferred
		; onto a one-shot timer so it NEVER runs on the input-gating keyboard thread.
		; Blocking there on ClipWait would starve the low-level hook and drop the
		; user's next keystrokes; running it off-thread lets the hotkey return at once.
		SetTimer(() => _TextSendClipboard(Text), -1)
	} else {
		; SendText uses the "Text" mode that bypasses hotkey triggers and sends
		; Unicode characters as raw keystrokes — the safest injection path.
		_AHK_SendText.Call(Text)
	}

	if Callback != 0
		try Callback()
}

; Performs the clipboard save / write / wait / paste / restore round-trip.
; Runs on a one-shot timer (off the keyboard thread) so the blocking ClipWait
; cannot starve the low-level keyboard hook. Bails loudly without pasting if the
; clipboard never settles, and guards the restore with a generation counter so a
; later injection's clipboard is never clobbered by this call's stale restore.
; @param Text {String} The Unicode text to inject via clipboard paste.
_TextSendClipboard(Text) {
	global TEXT_CLIPBOARD_RESTORE_DELAY_MS, TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC, _TEXT_CLIPBOARD_GENERATION

	; Claim this injection's slot. The restore closure below compares against this
	; snapshot and no-ops if a newer clipboard-mode TextSend has since taken over.
	_TEXT_CLIPBOARD_GENERATION += 1
	Generation := _TEXT_CLIPBOARD_GENERATION

	; CB_SaveAll uses ClipboardAll() so non-text content (images, files, RTF)
	; survives the paste cycle — CB_Save()/CB_Restore() are text-only and would
	; silently destroy any non-text clipboard data the user holds.
	Saved := CB_SaveAll()
	CB_Write(Text)

	; Wait for the clipboard to actually hold our text before pasting. On timeout
	; we MUST NOT paste — Ctrl+V would inject the previous clipboard content. Bail
	; loudly and restore the saved snapshot instead of pasting blindly.
	if !ClipWait(TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC) {
		LoggerError("TextSender", "TextSend: clipboard did not settle within {1}s - skipping paste to avoid injecting stale content.", TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC)
		CB_RestoreAll(Saved)
		return
	}

	_AHK_SendInput.Call("^v")

	; Restore after a short delay so the paste completes before we overwrite.
	; The closure no-ops if a newer injection advanced the generation counter,
	; so two rapid clipboard sends never let an earlier restore clobber the later.
	SavedForTimer := Saved
	GenerationForTimer := Generation
	SetTimer(() => _TextSendRestoreClipboard(SavedForTimer, GenerationForTimer), -TEXT_CLIPBOARD_RESTORE_DELAY_MS)
}

; Restores a clipboard snapshot taken by _TextSendClipboard, but only if no newer
; clipboard-mode injection has started since. Serialises overlapping restores so a
; stale restore can never overwrite a clipboard a later injection just populated.
; @param Saved      {ClipboardAll|String} Snapshot returned by CB_SaveAll().
; @param Generation {Integer}             Counter value captured at scheduling.
_TextSendRestoreClipboard(Saved, Generation) {
	global _TEXT_CLIPBOARD_GENERATION
	if (Generation != _TEXT_CLIPBOARD_GENERATION)
		return
	CB_RestoreAll(Saved)
}

; Emits Count Backspace keystrokes synchronously.
; @param Count {Integer} Number of Backspace keystrokes to emit.
TextEraseChars(Count) {
	if Count < 1
		return
	loop Count
		_AHK_SendInput.Call("{Backspace}")
}

; Emits a keystroke with optional modifiers, or a key-down/key-up event.
; @param Key       {String} Key name (e.g., "LCtrl", "Return", "Escape").
; @param Modifiers {Array|String} Array of modifier name strings for a full
;                  keystroke, OR the string "Down"/"Up" to emit a sustained
;                  press/release event (e.g. hold a modifier across a KeyWait).
TextPressKey(Key, Modifiers) {
	; "Down" / "Up" — sustained press or release for hold-modifier patterns.
	if (Modifiers == "Down" or Modifiers == "Up") {
		_AHK_SendInput.Call("{" . Key . " " . Modifiers . "}")
		return
	}
	Prefix := ""
	if (Modifiers is Array) {
		for ModStr in Modifiers
			Prefix .= _TextSenderModifierPrefix(ModStr)
	} else if (Modifiers is String) and (Modifiers != "") {
		; AHK-style space-delimited modifier string ("Shift", "Ctrl Shift",
		; "Blind", ...). Previously this fell through with Prefix "" and the bare
		; key was emitted, silently dropping the modifier.
		Prefix := _TextSenderModifierString(Modifiers)
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
