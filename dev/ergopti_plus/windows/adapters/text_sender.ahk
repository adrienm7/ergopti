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
; clipboard payload. Each request captures its snapshot only when it owns the
; FIFO head, so an intervening user copy is never restored to an older value.
global _TEXT_CLIPBOARD_QUEUE := []
global _TEXT_CLIPBOARD_BUSY := false
global _TEXT_CLIPBOARD_OWNER_TOKEN := 0
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
		; AltGr is Ctrl + right Alt, so it needs its own prefix: it previously fell
		; through to default and returned "", dropping the modifier entirely. Kept
		; separate from "ralt" on purpose — a caller asking for right Alt is not
		; asking for AltGr, and changing that would alter existing behaviour.
		case "altgr":                    return "<^>!"
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

; Whether this request carries the private two-phase hooks used by an owner
; whose in-memory ledger must change atomically with the OS output. The public
; TextSender port deliberately stays three-arity; these hooks live inside Opts
; so clipboard FIFO requests can carry them without widening that contract.
_TextSenderHasAtomicHooks(Opts) {
	if !(Opts is Map)
		return false
	for Name in ["admission", "atomic_prepare", "atomic_journal",
			"atomic_commit", "commit_failure"] {
		if Opts.Has(Name) and HasMethod(Opts[Name], "Call")
			return true
	}
	return false
}

; Evaluate an optional admission predicate without logging or throwing. This
; helper is safe inside a short Critical region; the LLM predicate uses only
; in-memory generations and bounded User32 focus probes. A malformed predicate
; fails closed instead of letting old output reach an unverifiable target.
_TextSenderAdmissionCurrent(Opts, &Failure := "") {
	Failure := ""
	if !(Opts is Map) or !Opts.Has("admission")
		return true
	Admission := Opts["admission"]
	if !HasMethod(Admission, "Call") {
		Failure := "output admission is not callable"
		return false
	}
	try {
		Admitted := Admission.Call()
		; Do not use loose equality here: AHK v2 considers the string "0"
		; equal to false. Admission is a strictly typed Boolean contract.
		if !(Admitted is Integer) or Admitted != true {
			Failure := "output admission rejected"
			return false
		}
		return true
	} catch as Err {
		Failure := "output admission failed: " . Err.Message
		return false
	}
}

; Emit one direct or clipboard operation together with its owner-provided RAM
; journal and state commit. Potentially yielding privacy/flush preparation runs
; first on the open thread. Admission is still checked at the last possible
; instant; sender, canonical RAM journal and mirrors then share one Critical
; boundary so visible output cannot race Suspend or physical input. GUI/file
; work returned by atomic_commit remains outside the transaction.
; @return {Object} { Ok, ErrorMessage, Rejected }.
_TextSenderRunAtomicOutput(SenderFn, Opts, Operation) {
	AtomicPrepare := (Opts is Map) ? Opts.Get("atomic_prepare", 0) : 0
	AtomicJournal := (Opts is Map) ? Opts.Get("atomic_journal", 0) : 0
	AtomicCommit := (Opts is Map) ? Opts.Get("atomic_commit", 0) : 0
	CommitFailure := (Opts is Map) ? Opts.Get("commit_failure", 0) : 0
	PreparedJournal := 0
	Finalizer := 0
	RecoveryFinalizer := 0
	ErrorMessage := ""
	PrepareError := ""
	JournalError := ""
	JournalRejected := false
	CommitError := ""
	RecoveryError := ""
	Rejected := false
	Emitted := false
	if HasMethod(AtomicPrepare, "Call") {
		try
			PreparedJournal := AtomicPrepare.Call()
		catch as Err
			PrepareError := Err.Message
	}
	PreviousCritical := Critical("On")
	try {
		if !_TextSenderAdmissionCurrent(Opts, &ErrorMessage)
			Rejected := true
		if !Rejected {
			SenderFn.Call()
			Emitted := true
			if (PrepareError = "" and HasMethod(AtomicJournal, "Call")) {
				try {
					JournalResult := AtomicJournal.Call(PreparedJournal)
					if !(JournalResult is Integer) or JournalResult != true
						JournalRejected := true
				} catch as Err {
					JournalError := Err.Message
				}
			}
			if HasMethod(AtomicCommit, "Call") {
				try
					Finalizer := AtomicCommit.Call()
				catch as Err
					CommitError := Err.Message
			}
		}
	} catch as Err {
		if Emitted
			CommitError := Err.Message
		else
			ErrorMessage := Err.Message
	} finally {
		; A failed RAM commit has already left visible OS output behind. Repair its
		; mirrors before physical input can resume; otherwise a character arriving
		; between Critical("Off") and the reset would be erased by that reset. The
		; recovery hook is therefore RAM-only and may return presentation work for
		; the open-thread phase, exactly like atomic_commit.
		if (CommitError != "" and HasMethod(CommitFailure, "Call")) {
			try
				RecoveryFinalizer := CommitFailure.Call(CommitError)
			catch as Err
				RecoveryError := Err.Message
		}
		Critical(PreviousCritical)
	}

	; Once SenderFn returned, output is visible. A later commit fault is terminal
	; state damage, not "output absent": report it and invoke a fail-safe reset,
	; but keep Ok=true so no caller can retry and duplicate the user's text.
	if (CommitError != "") {
		LoggerError("TextSender", "{1} state commit failed after output was emitted: {2}", Operation, CommitError)
		if (RecoveryError != "")
			LoggerError("TextSender", "{1} fail-safe reset failed: {2}", Operation, RecoveryError)
		if HasMethod(RecoveryFinalizer, "Call") {
			try
				RecoveryFinalizer.Call()
			catch as Err
				LoggerError("TextSender", "{1} fail-safe finalizer failed: {2}", Operation, Err.Message)
		}
	} else if (Emitted and HasMethod(Finalizer, "Call")) {
		try
			Finalizer.Call()
		catch as Err
			LoggerError("TextSender", "{1} finalizer failed: {2}", Operation, Err.Message)
	}
	if (PrepareError != "")
		LoggerError("TextSender", "{1} output journal preparation failed: {2}", Operation, PrepareError)
	if (JournalError != "")
		LoggerError("TextSender", "{1} output journal commit failed after output was emitted: {2}", Operation, JournalError)
	else if JournalRejected
		LoggerWarn("TextSender", "{1} output journal was invalidated at commit.", Operation)
	if (!Emitted and ErrorMessage != "" and !Rejected)
		LoggerError("TextSender", "{1} failed: {2}", Operation, ErrorMessage)
	CallbackError := ErrorMessage
	if (Emitted and CommitError != "")
		CallbackError := "output emitted but state commit failed: " . CommitError
	else if (Emitted and JournalError != "")
		CallbackError := "output emitted but journal commit failed: " . JournalError
	else if (Emitted and PrepareError != "")
		CallbackError := "output emitted but journal preparation failed: " . PrepareError
	else if (Emitted and JournalRejected)
		CallbackError := "output emitted but journal was invalidated"
	return {
		Ok: Emitted,
		ErrorMessage: CallbackError,
		Rejected: Rejected,
		CommitOk: Emitted and CommitError == "",
		JournalOk: Emitted and PrepareError == "" and JournalError == ""
			and !JournalRejected
	}
}

; Calls the injectable SendInput primitive without allowing an OS/injection
; failure to escape from a keyboard-facing adapter method.  A thrown SendInput
; in a timer callback otherwise skips the completion callback and leaves the
; process-wide clipboard FIFO permanently busy; in a hold path it can also
; strand a partially applied modifier transaction.
_TextSenderSendInput(Keys, Operation := "SendInput", LogFailure := true) {
	global _AHK_SendInput

	; Every TextPressKey emission funnels through here at SendLevel 0, and the
	; prefix watcher's InputHook is armed "V L0 I1" — so it filters these out by
	; construction and neither hotstring buffer ever learns that a synthetic
	; Ctrl+Backspace just deleted a whole word. The declaration channel was wired
	; at three call sites and ~40 others reach this funnel without it, so declare
	; HERE instead of chasing the call sites: the default-on AltGr+LAlt shortcut
	; alone left both buffers describing text no longer on screen, and the next
	; expansion then backspaced over characters that had nothing to do with it.
	;
	; Deliberately restricted to the two real key-press operations:
	;   - "erase character" is the engine backspacing over its OWN trigger mid
	;     expansion. It already accounts for those, so declaring would decrement
	;     both buffers a second time — corruption in the opposite direction.
	;   - "clipboard paste" is that same expansion machinery injecting its
	;     replacement, likewise already accounted for.
	;   - the modifier Down/Up and rollback operations change modifier state
	;     only; they touch neither the caret nor the document.
	try {
		; Declaration and OS output are one transaction. HS_DeclareSyntheticEffect
		; used to restore Critical and run tooltip effects before this call, which
		; let a physical OnChar enter the future buffer state before the caret move
		; reached Windows. The canonical owner keeps only RAM mutation + SendInput
		; under Critical and finishes GUI/analytics work after restoring it.
		; IsSet-guarded because headless adapter runners may omit the hotstring layer.
		if ((Operation == "key press" or Operation == "modified key press")
			and IsSet(HS_RunSyntheticInputTransaction)) {
			HS_RunSyntheticInputTransaction(Keys, _AHK_SendInput.Bind(Keys))
		} else {
			_AHK_SendInput.Call(Keys)
		}
		return true
	} catch as Err {
		; Synthetic ownership calls defer this ERROR until after their short
		; Critical ledger/send commit. LoggerError flushes synchronously to disk,
		; so logging it here would put file I/O under Critical and starve input.
		if LogFailure
			LoggerError("TextSender", "{1} failed for '{2}': {3}", Operation, Keys, Err.Message)
		return false
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
_TextSendClipboard(Text, Saved, Callback := 0, Opts := 0) {
	global TEXT_CLIPBOARD_RESTORE_DELAY_MS, TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC, _TEXT_CLIPBOARD_GENERATION
	global _AHK_SendInput

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
		_TextSenderInvokeCallback(Callback, false, "clipboard write failed")
		return
	}
	OwnedSequence := CB_GetSequenceNumber()
	if !OwnedSequence {
		LoggerError("TextSender", "TextSend: clipboard sequence is unavailable - skipping paste because ownership cannot be proven.")
		; CB_Write above SUCCEEDED, so the payload is already sitting in the user's
		; clipboard. Every other bail-out hands this to _TextSendRestoreClipboard,
		; which refuses to act without a sequence number — so on this one path the
		; injected text would survive until the user next copied something, which is
		; how a password or an expansion ends up pasted into an unrelated window.
		; Restore directly. The sequence guard exists to avoid clobbering a NEWER
		; user copy and cannot answer here; leaving our own payload behind is the
		; certain harm, a user copy landing in the microseconds since CB_Write is
		; the speculative one.
		_TextSendForceRestoreClipboard(Saved, Generation)
		_TextSenderInvokeCallback(Callback, false, "clipboard ownership unavailable")
		return
	}

	; Wait for the clipboard to actually hold our text before pasting. On timeout
	; we MUST NOT paste — Ctrl+V would inject the previous clipboard content. Bail
	; loudly and restore the saved snapshot instead of pasting blindly.
	if !ClipWait(TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC) {
		LoggerError("TextSender", "TextSend: clipboard did not settle within {1}s - skipping paste to avoid injecting stale content.", TEXT_CLIPBOARD_WAIT_TIMEOUT_SEC)
		_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
		_TextSenderInvokeCallback(Callback, false, "clipboard did not settle")
		return
	}

	; A newer injection may have taken over the clipboard slot while we were
	; blocked inside ClipWait; pasting now would clobber its content.
	if (Generation != _TEXT_CLIPBOARD_GENERATION) {
		_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
		_TextSenderInvokeCallback(Callback, false, "clipboard ownership superseded")
		return
	}
	if (CB_GetSequenceNumber() != OwnedSequence) {
		LoggerWarn("TextSender", "TextSend: clipboard ownership changed before paste - skipping stale Ctrl+V.")
		_TextSenderInvokeCallback(Callback, false, "clipboard ownership changed before paste")
		return
	}
	; ClipWait yields. A pause requested while it was blocked must win before the
	; observable Ctrl+V, even though the earlier entry guard already passed.
	if A_IsSuspended {
		_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
		_TextSenderInvokeCallback(Callback, false, "driver suspended before clipboard paste")
		return
	}

	CompletionError := ""
	if _TextSenderHasAtomicHooks(Opts) {
		Result := _TextSenderRunAtomicOutput(
			_AHK_SendInput.Bind("^v"), Opts, "clipboard paste")
		if !Result.Ok {
			_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
			_TextSenderInvokeCallback(Callback, false, Result.ErrorMessage)
			return
		}
		CompletionError := Result.ErrorMessage
	} else if !_TextSenderSendInput("^v", "clipboard paste") {
		_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
		_TextSenderInvokeCallback(Callback, false, "clipboard paste failed")
		return
	}

	; Fire the completion callback now that the paste keystroke has been emitted.
	; Placed before the restore timer so callers can inspect A_Clipboard while it
	; still holds the injected text, but after ^v so the paste is guaranteed to land.
	_TextSenderInvokeCallback(Callback, true, CompletionError)

	; Restore after a short delay so the paste completes before we overwrite.
	; The closure no-ops if a newer injection advanced the generation counter,
	; so two rapid clipboard sends never let an earlier restore clobber the later.
	SavedForTimer := Saved
	GenerationForTimer := Generation
	OwnedSequenceForTimer := OwnedSequence
	SetTimer(() => _TextSendRestoreClipboard(SavedForTimer, GenerationForTimer, OwnedSequenceForTimer), -TEXT_CLIPBOARD_RESTORE_DELAY_MS)
}

; Restores a clipboard snapshot taken by _TextSendClipboard, but only if no newer
; clipboard-mode injection has started since. Serialises overlapping restores so a
; stale restore can never overwrite a clipboard a later injection just populated.
; @param Saved      {ClipboardAll|String} Snapshot returned by CB_SaveAll().
; @param Generation {Integer}             Counter value captured at scheduling.
_TextSendRestoreClipboard(Saved, Generation, OwnedSequence) {
	global _TEXT_CLIPBOARD_GENERATION, _TEXT_CLIPBOARD_OWNER_TOKEN
	; Also a SetTimer callback — bypasses native Suspend() like its sibling
	; above. Restoring the clipboard is harmless while paused (it undoes the
	; write _TextSendClipboard already made before any pause could have
	; started), so this still runs; only a NEW clipboard write is guarded.
	if (Generation != _TEXT_CLIPBOARD_GENERATION)
		return
	; The user may have copied something after this request pasted. Restore only
	; while this transaction still owns the exact clipboard sequence; otherwise
	; any restore would silently overwrite the user's newer clipboard content.
	if (!OwnedSequence or CB_GetSequenceNumber() != OwnedSequence)
		return
	CB_RestoreOwnedAllEventually(Saved, OwnedSequence,
		_TEXT_CLIPBOARD_OWNER_TOKEN, "text_sender", false)
}

; Restores the pre-injection snapshot WITHOUT the ownership proof its sibling
; requires. Reserved for the one bail-out where CB_GetSequenceNumber() itself
; failed: no proof can exist there, and the sibling would therefore no-op and
; leave the injected payload in the user's clipboard. The generation check is
; kept — a newer injection owning the slot must still win.
; @param Saved      {ClipboardAll|String} Snapshot returned by CB_SaveAll().
; @param Generation {Integer}             Counter value captured before the write.
_TextSendForceRestoreClipboard(Saved, Generation) {
	global _TEXT_CLIPBOARD_GENERATION, _TEXT_CLIPBOARD_OWNER_TOKEN
	if (Generation != _TEXT_CLIPBOARD_GENERATION)
		return
	CB_RestoreOwnedAllEventually(Saved, 0, _TEXT_CLIPBOARD_OWNER_TOKEN,
		"text_sender_force", false, true)
}

; Starts exactly one queued clipboard transaction. The next request is not
; started until the preceding restore window has elapsed, so its write cannot
; replace a payload that has not yet been pasted by the foreground application.
_TextSenderStartClipboard() {
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_OWNER_TOKEN
	if _TEXT_CLIPBOARD_BUSY or (_TEXT_CLIPBOARD_QUEUE.Length = 0)
		return
	_TEXT_CLIPBOARD_BUSY := true
	Request := _TEXT_CLIPBOARD_QUEUE.RemoveAt(1)
	RequestOpts := Request.HasOwnProp("Opts") ? Request.Opts : 0
	AdmissionCritical := Critical("On")
	try {
		Admitted := _TextSenderAdmissionCurrent(RequestOpts, &AdmissionFailure)
	} finally {
		Critical(AdmissionCritical)
	}
	if !Admitted {
		_TextSenderClipboardCompleted(Request.Callback, false, AdmissionFailure)
		return
	}
	OwnerToken := CB_TryBeginOwnedTransaction("text_sender", true)
	if !OwnerToken {
		_TEXT_CLIPBOARD_QUEUE.InsertAt(1, Request)
		_TEXT_CLIPBOARD_BUSY := false
		SetTimer(_TextSenderStartClipboard, -CB_RESTORE_RETRY_MS)
		return
	}
	_TEXT_CLIPBOARD_OWNER_TOKEN := OwnerToken
	; Snapshot only after process-wide clipboard admission. A user copy made
	; between queued requests is then the value restored after this request.
	Saved := CB_SaveAll()
	if (Type(Saved) == "String" and Saved == "__CB_SAVE_ERROR__") {
		LoggerError("TextSender", "TextSend: clipboard snapshot failed - skipping clipboard injection.")
		_TextSenderClipboardCompleted(Request.Callback, false, "clipboard snapshot failed")
		return
	}
	; Clipboard notifications and the synthetic Ctrl+V outlive the function
	; which writes the payload. Keep the shared owner through the restore window;
	; _TextSenderFinishClipboard releases it on every terminal path.
	_TextSendClipboard(Request.Text, Saved,
		_TextSenderClipboardCompleted.Bind(Request.Callback), RequestOpts)
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
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TEXT_CLIPBOARD_OWNER_TOKEN
	OwnerToken := _TEXT_CLIPBOARD_OWNER_TOKEN
	if OwnerToken and CB_HasRestoreDebtForOwner(OwnerToken) {
		SetTimer(_TextSenderFinishClipboard, -CB_RESTORE_RETRY_MS)
		return
	}
	_TEXT_CLIPBOARD_OWNER_TOKEN := 0
	if OwnerToken
		CB_EndOwnedTransaction(OwnerToken)
	_TEXT_CLIPBOARD_BUSY := false
	if (_TEXT_CLIPBOARD_QUEUE.Length = 0) {
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
	global TEXT_CLIPBOARD_THRESHOLD, _TEXT_CLIPBOARD_QUEUE
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
		; CB_SaveAll() runs only after this request owns the FIFO head. Capturing on
		; the keyboard caller would make its later restore clobber a user copy made
		; while this request waited behind an earlier transaction.
		; Callback is passed into _TextSendClipboard and fired there after Ctrl+V, so
		; callers that depend on the callback being synchronised with injection completion
		; are never notified before the paste actually lands.
		RequestOpts := (Opts is Map) ? Opts.Clone() : Opts
		_TEXT_CLIPBOARD_QUEUE.Push({ Text: Text, Callback: Callback, Opts: RequestOpts })
		SetTimer(_TextSenderStartClipboard, -1)
	} else {
		; SendText uses the "Text" mode that bypasses hotkey triggers and sends
		; Unicode characters as raw keystrokes — the safest injection path.
		; Wrapped in try/catch matching this adapter's own convention (every
		; other OS-level call in this file is defensively guarded) — currently
		; masked by both production callers' own outer guards, but a contested
		; low-level hook can still throw here.
		if _TextSenderHasAtomicHooks(Opts) {
			AtomicInput := (Opts is Map) ? Opts.Get("atomic_input", false) : false
			if !(AtomicInput is Integer) or AtomicInput != true {
				_TextSenderInvokeCallback(Callback, false,
					"atomic direct output requires SendInput text mode")
				return
			}
			Result := _TextSenderRunAtomicOutput(
				_AHK_SendInput.Bind("{Text}" . Text), Opts, "direct-mode SendInput text")
			_TextSenderInvokeCallback(Callback, Result.Ok, Result.ErrorMessage)
		} else {
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
}

; Emits Count Backspace keystrokes synchronously.
; @param Count {Integer} Number of Backspace keystrokes to emit.
TextEraseChars(Count) {
	; Explicitly true: erasing nothing SUCCEEDED. A bare return yields "", and
	; every other path here returns a boolean, so a caller testing the result
	; would read a legitimate zero-count call as a failure.
	if Count < 1
		return true
	loop Count
		if !_TextSenderSendInput("{Backspace}", "erase character")
			return false
	return true
}

; Emits a keystroke with optional modifiers, or a key-down/key-up event.
; @param Key       {String} Key name (e.g., "LCtrl", "Return", "Escape").
; @param Modifiers {Array|String} Array of modifier name strings for a full
;                  keystroke, OR the string "Down"/"Up" to emit a sustained
;                  press/release event (e.g. hold a modifier across a KeyWait).
; @param LogFailure {Boolean} True to log sender failures synchronously. The
;                   synthetic owner passes false while its ledger is Critical
;                   and emits one terminal ERROR after restoring Critical.
; @param Transaction {Object|unset} Optional mutable result for a sustained
;                   Array transaction. SentKeys records proven Downs,
;                   FailedKey identifies the rejected transition, and
;                   RollbackFailedKeys retains every earlier Down whose
;                   compensating Up was not proven. The tap-hold owner uses
;                   that last field to keep release ownership after failure.
TextPressKey(Key, Modifiers, LogFailure := true, Transaction := unset) {
	; "Down" / "Up" — sustained press or release for hold-modifier patterns.
	if (Modifiers == "Down" or Modifiers == "Up") {
		; An empty Key here means an upstream hold_modifier resolver already
		; logged a WARNING and bailed to "" (see ResolveHoldModifierKey in
		; platform/remap/tap_hold_loader.ahk). Sending "{ Down}" / "{ Up}" would
		; silently arm nothing while still consuming the keystroke — refuse it
		; here too as a second line of defense instead of a blind SendInput
		; with a blank key name.
		if (Key == "") {
			LoggerError("TextSender", "TextPressKey: refusing to send '{1}' with an empty Key — caller must resolve the key name before calling.", Modifiers)
			return false
		}
		; Hold modifiers can now be a combo represented as an Array (e.g.
		; ["LCtrl", "LShift"]) or a scalar key name for legacy paths.
		if (IsObject(Key) and Type(Key) == "Array") {
			SentKeys := []
			RollbackFailedKeys := []
			for _, ModKey in Key {
				if (ModKey == "")
					continue
				if !_TextSenderSendInput("{" . ModKey . " " . Modifiers . "}", "modifier " . Modifiers, LogFailure) {
					; A failed multi-key Down must not leave the keys already sent
					; logically held by the driver.  Release them in reverse order;
					; each release is guarded/logged independently because the
					; original injection provider may be transiently unavailable.
					if (Modifiers == "Down") {
						loop SentKeys.Length {
							SentKey := SentKeys[SentKeys.Length - A_Index + 1]
							if !_TextSenderSendInput("{" . SentKey . " Up}", "modifier rollback", LogFailure)
								RollbackFailedKeys.Push(SentKey)
						}
					}
					if IsSet(Transaction) {
						Transaction.SentKeys := SentKeys.Clone()
						Transaction.FailedKey := ModKey
						Transaction.RollbackFailedKeys := RollbackFailedKeys
					}
					return false
				}
				SentKeys.Push(ModKey)
			}
			if IsSet(Transaction) {
				Transaction.SentKeys := SentKeys.Clone()
				Transaction.FailedKey := ""
				Transaction.RollbackFailedKeys := RollbackFailedKeys
			}
			return true
		}
		return _TextSenderSendInput("{" . Key . " " . Modifiers . "}", "sustained key " . Modifiers, LogFailure)
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
			; An empty INPUT array is the shortcuts cluster's documented "no modifiers"
			; convention — every dispatcher calls TextPressKey(Key, []) — so it is not an
			; anomaly and must not spam the errors log. Warn only when a NON-empty array
			; had all its tokens fail normalization, the case this guard was written for.
			if (Modifiers.Length > 0)
				LoggerWarn("TextSender", "TextPressKey: modifier array for key '{1}' is empty after normalization.", Key)
			return _TextSenderSendInput("{" . Key . "}", "key press")
		}
		; A one-modifier array is still a regular shortcut.  `{Ctrl c}` is
		; parsed as a single brace token by AHK rather than as Ctrl+C; use the
		; same prefix form as multi-modifier arrays (`^+{Tab}`) for every size.
		Prefix := _TextSenderModifierPrefixFromArray(Mods)
		return _TextSenderSendInput(Prefix . "{" . Key . "}", "modified key press")
	}
	Prefix := ""
	if (Modifiers is String) and (Modifiers != "") {
		; AHK-style space-delimited modifier string ("Shift", "Ctrl Shift",
		; "Blind", ...). Previously this fell through with Prefix "" and the bare
		; key was emitted, silently dropping the modifier.
		Prefix := _TextSenderModifierString(Modifiers)
	}
	return _TextSenderSendInput(Prefix . "{" . Key . "}", "key press")
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TEXT_SENDER := Map(
    "send",       TextSend,
    "eraseChars", TextEraseChars,
    "pressKey",   TextPressKey,
)
