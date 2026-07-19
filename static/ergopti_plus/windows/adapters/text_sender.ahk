; adapters/text_sender.ahk

; ==============================================================================
; MODULE: TextSender Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TextSender port contract defined in
; static/ergopti_plus/_shared/core/ports/TextSender.spec.js. Wraps AHK's SendText,
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

; Clipboard mode is a process-wide transaction, not an independently safe
; per-call operation. A second TextSend used to supersede the first while it
; was in ClipWait, silently dropping the first requested output. Queue every
; clipboard payload and keep one original clipboard snapshot for the session.
global _TEXT_CLIPBOARD_QUEUE := []
global _TEXT_CLIPBOARD_BUSY := false
global _TEXT_CLIPBOARD_SESSION_SAVED := false
global TEXT_CLIPBOARD_NEXT_DELAY_MS := TEXT_CLIPBOARD_RESTORE_DELAY_MS + 20

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
	switch StrLower(Trim(ModName)) {
		case "ctrl", "lctrl", "rctrl": return "^"
		case "shift", "lshift", "rshift": return "+"
		case "alt", "lalt", "ralt":       return "!"
		case "cmd", "win", "lwin", "rwin": return "#"
		case "blind":    return "{Blind}"
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

; Normalizes a modifier name (string or alias) to an AHK key name.
; Returns "" for unknown values so callers can skip them safely.
_TextSenderNormalizeModifierKey(Token) {
	switch StrLower(Trim(Token)) {
		case "ctrl", "lctrl", "rctrl":
			return "Ctrl"
		case "shift", "lshift", "rshift":
			return "Shift"
		case "alt", "lalt", "ralt":
			return "Alt"
		case "altgr":
			return "RAlt"
		case "win", "lwin", "rwin", "cmd":
			return "LWin"
		default:
			return ""
	}
}

; Builds the modifier down/up prefix set for SendInput from array input.
; Useful for Space/one-shot style handlers that need to send the captured
; character while modifiers are already pressed.
_TextSenderModifierPrefixFromArray(Modifiers) {
	Prefix := ""
	for _, Token in Modifiers {
		Norm := _TextSenderNormalizeModifierKey(Token)
		if (Norm == "")
			continue
		Prefix .= _TextSenderModifierPrefix(Norm)
	}
	return Prefix
}




; =======================================================
; =======================================================
; ======= 2/ Adapter Methods ============================
; =======================================================
; =======================================================

; Invokes an optional completion callback, logging (never propagating) any
; exception it throws. Mirrors the try/catch + LoggerError pattern used by
; sibling adapters (adapters/shell_runner.ahk's on_done wrapper,
; adapters/timer_scheduler.ahk's _OneShot/_Repeating wrappers) so a throwing
; Callback cannot silently vanish — unlike a bare "try Callback()" with no
; catch, which swallows the exception with zero log trace.
; @param Callback {Func|0} Optional zero-arity completion callback.
_TextSenderInvokeCallback(Callback, Ok := true, ErrorMessage := "") {
	if Callback = 0
		return
	try
		Callback(Ok, ErrorMessage)
	catch as Err {
		LoggerError("TextSender", "completion callback threw: {1}", Err.Message)
	}
}

; Performs the clipboard write / wait / paste / restore round-trip.
; Runs on a one-shot timer (off the keyboard thread) so the blocking ClipWait
; cannot starve the low-level keyboard hook. Bails loudly without pasting if the
; clipboard never settles, and guards the restore with a generation counter so a
; later injection's clipboard is never clobbered by this call's stale restore.
; The caller (TextSend) must call CB_SaveAll() synchronously before scheduling
; this timer and pass the resulting snapshot as Saved — this eliminates the TOCTOU
; race where a second rapid injection would capture the first injection's clipboard
; text rather than the user's original clipboard content.
; Callback is invoked after Ctrl+V is sent (still on the timer thread) so callers
; are never notified before the paste lands — fixing the race where the direct
; try Callback() in TextSend would fire before the deferred timer even started.
; @param Text     {String}             The Unicode text to inject via clipboard paste.
; @param Saved    {ClipboardAll|String} Snapshot already captured by the caller.
; @param Callback {Func|0}             Optional zero-arity completion callback.
_TextSendClipboard(Text, Saved, Callback := 0) {
	global TEXT_CLIPBOARD_RESTORE_DELAY_MS, TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC, _TEXT_CLIPBOARD_GENERATION

	; This whole round-trip runs on a SetTimer callback, which native Suspend()
	; never disarms — a pause toggled between TextSend's scheduling and this
	; timer firing must not still write the clipboard and paste. Nothing has
	; been written to the clipboard yet at this point, so there is nothing to
	; restore — the caller's Saved snapshot is simply never consumed.
	;
	; Every bail-out below calls Callback() before returning. Callers such as
	; modules/keymap/llm_bridge.ahk's _InjectCallback own depth-counter guards
	; (PrefixWatcherSuppress/KL_MarkSynthetic) that are released exactly once,
	; by the callback, on any path where TextSend itself did not throw --  a
	; bail-out here that never invokes Callback leaked those guards forever,
	; permanently suppressing normal hotstring/keylogger observation.
	if A_IsSuspended {
		_TextSenderInvokeCallback(Callback, false, "driver suspended before clipboard injection")
		return
	}

	; Claim this injection's slot. The restore closure below compares against this
	; snapshot and no-ops if a newer clipboard-mode TextSend has since taken over.
	_TEXT_CLIPBOARD_GENERATION += 1
	Generation := _TEXT_CLIPBOARD_GENERATION

	; A failed write leaves the previous clipboard content intact. Never continue
	; to ClipWait/^v in that state or the user receives unrelated stale text.
	if !CB_Write(Text) {
		LoggerError("TextSender", "TextSend: clipboard write failed - skipping paste to avoid injecting stale content.")
		CB_RestoreAll(Saved)
		_TextSenderInvokeCallback(Callback, false, "clipboard write failed")
		return
	}

	; Wait for the clipboard to actually hold our text before pasting. On timeout
	; we MUST NOT paste — Ctrl+V would inject the previous clipboard content. Bail
	; loudly and restore the saved snapshot instead of pasting blindly.
	if !ClipWait(TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC) {
		LoggerError("TextSender", "TextSend: clipboard did not settle within {1}s - skipping paste to avoid injecting stale content.", TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC)
		CB_RestoreAll(Saved)
		_TextSenderInvokeCallback(Callback, false, "clipboard did not settle")
		return
	}

	; A newer injection may have taken over the clipboard slot while we were
	; blocked inside ClipWait; pasting now would clobber its content.
	if (Generation != _TEXT_CLIPBOARD_GENERATION) {
		CB_RestoreAll(Saved)
		_TextSenderInvokeCallback(Callback, false, "clipboard ownership superseded")
		return
	}

	_AHK_SendInput.Call("^v")

	; Fire the completion callback now that the paste keystroke has been emitted.
	; Placed before the restore timer so callers can inspect A_Clipboard while it
	; still holds the injected text, but after ^v so the paste is guaranteed to land.
	_TextSenderInvokeCallback(Callback, true)

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
	; Also a SetTimer callback — bypasses native Suspend() like its sibling
	; above. Restoring the clipboard is harmless while paused (it undoes the
	; write _TextSendClipboard already made before any pause could have
	; started), so this still runs; only a NEW clipboard write is guarded.
	if (Generation != _TEXT_CLIPBOARD_GENERATION)
		return
	CB_RestoreAll(Saved)
}

; Starts exactly one queued clipboard transaction. The next request is not
; started until the preceding restore window has elapsed, so its write cannot
; replace a payload that has not yet been pasted by the foreground application.
_TextSenderStartClipboard() {
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_SESSION_SAVED
	if _TEXT_CLIPBOARD_BUSY or (_TEXT_CLIPBOARD_QUEUE.Length = 0)
		return
	_TEXT_CLIPBOARD_BUSY := true
	Request := _TEXT_CLIPBOARD_QUEUE.RemoveAt(1)
	_TextSendClipboard(Request.Text, _TEXT_CLIPBOARD_SESSION_SAVED,
		_TextSenderClipboardCompleted.Bind(Request.Callback))
}

; Called by _TextSendClipboard on every terminal path. It preserves the public
; callback timing (after paste, or on a guarded bailout) while advancing the
; FIFO only after the restore timer has had exclusive ownership of the clipboard.
_TextSenderClipboardCompleted(Callback, Ok := true, ErrorMessage := "") {
	global TEXT_CLIPBOARD_NEXT_DELAY_MS
	_TextSenderInvokeCallback(Callback, Ok, ErrorMessage)
	SetTimer(_TextSenderFinishClipboard, -TEXT_CLIPBOARD_NEXT_DELAY_MS)
}

_TextSenderFinishClipboard() {
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_SESSION_SAVED
	_TEXT_CLIPBOARD_BUSY := false
	if (_TEXT_CLIPBOARD_QUEUE.Length = 0) {
		_TEXT_CLIPBOARD_SESSION_SAVED := false
		return
	}
	SetTimer(_TextSenderStartClipboard, -1)
}

; Inserts text at the current insertion point.
; Uses the Clipboard port (CB_SaveAll / CB_Write / CB_RestoreAll) for the clipboard
; path so the interaction is mockable and the driver has one canonical clipboard
; code path.
; @param Text     {String}   The Unicode text to insert.
; @param Opts     {Map|0}    { mode?: "direct"|"clipboard"|"auto" }
; @param Callback {Func|0}   Called with no arguments on completion.
TextSend(Text, Opts, Callback) {
	global TEXT_CLIPBOARD_THRESHOLD, _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_SESSION_SAVED
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
		; CB_SaveAll() is called synchronously HERE (before the timer fires) so that
		; two rapid TextSend calls cannot race: each captures its own clipboard state
		; before either timer runs, eliminating the TOCTOU window where the second
		; CB_SaveAll would snapshot the first injection's text instead of the original.
		; Callback is passed into _TextSendClipboard and fired there after Ctrl+V, so
		; callers that depend on the callback being synchronised with injection completion
		; are never notified before the paste actually lands.
		; Capture only at the start of a FIFO session. A queued follow-up that
		; snapshots after the first worker wrote its payload would restore the
		; synthetic payload instead of the user's original clipboard.
		if (!_TEXT_CLIPBOARD_BUSY and _TEXT_CLIPBOARD_QUEUE.Length = 0) {
			Saved := CB_SaveAll()
			if (Type(Saved) == "String" and Saved == "__CB_SAVE_ERROR__") {
				LoggerError("TextSender", "TextSend: clipboard snapshot failed - skipping clipboard injection.")
				_TextSenderInvokeCallback(Callback, false, "clipboard snapshot failed")
				return
			}
			_TEXT_CLIPBOARD_SESSION_SAVED := Saved
		}
		_TEXT_CLIPBOARD_QUEUE.Push({ Text: Text, Callback: Callback })
		SetTimer(_TextSenderStartClipboard, -1)
	} else {
		; SendText uses the "Text" mode that bypasses hotkey triggers and sends
		; Unicode characters as raw keystrokes — the safest injection path.
		; Wrapped in try/catch matching this adapter's own convention (every
		; other OS-level call in this file is defensively guarded) — currently
		; masked by both production callers' own outer guards, but a contested
		; low-level hook can still throw here.
		Ok := true
		ErrorMessage := ""
		try
			_AHK_SendText.Call(Text)
		catch as Err {
			LoggerError("TextSender", "TextSend: direct-mode SendText failed: {1}", Err.Message)
			Ok := false
			ErrorMessage := Err.Message
		}
		_TextSenderInvokeCallback(Callback, Ok, ErrorMessage)
	}
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
		; An empty Key here means an upstream hold_modifier resolver already
		; logged a WARNING and bailed to "" (see ResolveHoldModifierKey in
		; lib/tap_hold/tap_hold_loader.ahk). Sending "{ Down}" / "{ Up}" would
		; silently arm nothing while still consuming the keystroke — refuse it
		; here too as a second line of defense instead of a blind SendInput
		; with a blank key name.
		if (Key == "") {
			LoggerError("TextSender", "TextPressKey: refusing to send '{1}' with an empty Key — caller must resolve the key name before calling.", Modifiers)
			return
		}
		; Hold modifiers can now be a combo represented as an Array (e.g.
		; ["LCtrl", "LShift"]) or a scalar key name for legacy paths.
		if (IsObject(Key) and Type(Key) == "Array") {
			for _, ModKey in Key {
				if (ModKey == "")
					continue
				_AHK_SendInput.Call("{" . ModKey . " " . Modifiers . "}")
			}
			return
		}
		_AHK_SendInput.Call("{" . Key . " " . Modifiers . "}")
		return
	}
	if (Modifiers is Array) {
		Mods := []
		for _, Tok in Modifiers {
			Norm := _TextSenderNormalizeModifierKey(Tok)
			if (Norm == "") {
				LoggerWarn("TextSender", "TextPressKey: unknown modifier token '{1}' in '{2}' modifier array — ignored.", Tok, Modifiers)
				continue
			}
			Mods.Push(Norm)
		}
		if (Mods.Length == 0) {
			LoggerWarn("TextSender", "TextPressKey: modifier array for key '{1}' is empty after normalization.", Key)
			_AHK_SendInput.Call("{" . Key . "}")
			return
		}
		; A one-modifier array is still a regular shortcut.  `{Ctrl c}` is
		; parsed as a single brace token by AHK rather than as Ctrl+C; use the
		; same prefix form as multi-modifier arrays (`^+{Tab}`) for every size.
		Prefix := _TextSenderModifierPrefixFromArray(Mods)
		_AHK_SendInput.Call(Prefix . "{" . Key . "}")
		return
	}
	Prefix := ""
	if (Modifiers is String) and (Modifiers != "") {
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
