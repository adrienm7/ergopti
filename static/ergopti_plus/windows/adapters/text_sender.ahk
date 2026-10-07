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
; of simulating keystrokes for large expansions. In "auto" mode Windows
; Notepad uses verified native editor messages at any payload length instead.
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

#Include %A_LineFile%\..\..\adapters\editor_replace.ahk

; Metadata only: never retain document, prediction or clipboard text in a log.
_TextSenderReadClipboardDiagnosticState() {
	Hwnd := WinExist("A")
	Pid := Hwnd ? WinGetPID("ahk_id " . Hwnd) : 0
	ProcessName := Hwnd ? WinGetProcessName("ahk_id " . Hwnd) : ""
	WindowClass := Hwnd ? WinGetClass("ahk_id " . Hwnd) : ""
	FocusedControlHwnd := Hwnd ? ControlGetFocus("ahk_id " . Hwnd) : 0
	ControlClass := FocusedControlHwnd ? WinGetClass(FocusedControlHwnd) : ""
	Logical := 0
	Physical := 0
	for Index, Key in ["Ctrl", "Shift", "Alt"] {
		if GetKeyState(Key)
			Logical |= 1 << (Index - 1)
		if GetKeyState(Key, "P")
			Physical |= 1 << (Index - 1)
	}
	ClipboardText := CB_Read()
	return Map("hwnd", Hwnd, "pid", Pid, "process_name", ProcessName, "window_class", WindowClass,
		"control_class", ControlClass, "logical", Logical, "physical", Physical,
		"sequence", CB_GetSequenceNumber(), "clipboard_units",
		(ClipboardText is String) ? StrLen(ClipboardText) : -1,
		"observed_tick", DllCall("GetTickCount64", "UInt64"))
}

; Emit outside both the owned output transaction and any Critical caller.
; The modifier masks use Ctrl=1, Shift=2 and Alt=4. Emitted records only that
; the primitive returned, not that the receiving application processed a paste.
_TextSenderClipboardDiagnostic(Stage, TextUnits, EraseCount, Generation,
		OwnedSequence, Emitted := -1, ReadFn := unset, InfoFn := unset, TimerFn := unset) {
	if !IsSet(ReadFn)
		ReadFn := _TextSenderReadClipboardDiagnosticState
	if !IsSet(InfoFn)
		InfoFn := LoggerInfo
	if !IsSet(TimerFn)
		TimerFn := SetTimer
	if A_IsCritical {
		TimerFn.Call(_TextSenderClipboardDiagnostic.Bind(Stage, TextUnits, EraseCount,
			Generation, OwnedSequence, Emitted, ReadFn, InfoFn, TimerFn), -1)
		return
	}
	State := ReadFn.Call()
	; Stage and generation changes are the news, so the central repeat key
	; must contain the formatted body (logger spec section 4.2).
	Message := Format("Clipboard injection {1}: mode=clipboard, generation={2}, owned_sequence={3}, current_sequence={4}, payload_units={5}, erase_before={6}, hwnd={7}, pid={8}, process_name={9}, window_class={10}, control_class={11}, logical_modifiers={12}, physical_modifiers={13}, clipboard_units={14}, primitive_returned={15}, observed_tick={16}.",
		Stage, Generation, OwnedSequence, State["sequence"], TextUnits, EraseCount,
		State["hwnd"], State["pid"], State["process_name"], State["window_class"], State["control_class"],
		State["logical"], State["physical"], State["clipboard_units"], Emitted,
		State["observed_tick"])
	InfoFn.Call("TextSender", Message)
}

; Diagnostic failures are explicit but cannot turn an emitted edit into a retry.
_TextSenderTryClipboardDiagnostic(Stage, TextUnits, EraseCount, Generation,
		OwnedSequence, Emitted := -1) {
	try {
		if A_IsCritical {
			SetTimer(_TextSenderTryClipboardDiagnostic.Bind(Stage, TextUnits,
				EraseCount, Generation, OwnedSequence, Emitted), -1)
			return
		}
		_TextSenderClipboardDiagnostic(Stage, TextUnits, EraseCount, Generation,
			OwnedSequence, Emitted)
	} catch as Err {
		; A failed deferral cannot safely log on a Critical caller. Diagnostics
		; remain best effort; losing metadata must not interrupt the output owner.
		if !A_IsCritical
			try LoggerWarn("TextSender", "Clipboard diagnostic {1} failed ({2}); output policy is unchanged.", Stage, Type(Err))
	}
}

; Delay in milliseconds before the clipboard is restored after a paste injection.
; A scheduling window only; elapsed time does not acknowledge application paste processing.
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

; SendLevel of every TextSender emission. SendInput hides a script's own keys
; from its own hooks only while no other AutoHotkey keyboard hook runs; with one,
; it falls back to SendEvent and the driver's InputHooks observe them. Level 0
; is below the I1 threshold of the hook dispatcher and the prefix watcher, so
; the output stays invisible to them either way, whatever SendLevel the calling
; hotkey thread runs at (2 for the tap-holds and the physical Tab, which accepts
; an AI prediction from its #InputLevel 2 hotkey thread). Every emission goes
; through _TextSenderAtSendLevel.
global TEXT_SENDER_SEND_LEVEL := 0

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

; Maps the cross-platform modifier names from the spec to their AHK v2 prefix
; chars. AltGr has none: see _TextSenderKeystroke.
_TextSenderModifierPrefix(ModName) {
	switch StrLower(Trim(ModName)) {
		case "ctrl", "lctrl", "rctrl": return "^"
		case "shift", "lshift", "rshift": return "+"
		case "alt", "lalt", "ralt":       return "!"
		case "cmd", "win", "lwin", "rwin": return "#"
		default:                  return ""
	}
}

; Whether key Name is logically down. A global holding a function, as
; _AHK_SendInput is, so tests can stand in for the keyboard state.
global _TextSenderKeyIsDown := (Name) => GetKeyState(Name)

; Send string for one keystroke of Key under the modifier names Mods. AltGr
; is the layout's AltGr key (KS_AltGrKeyName): "<^>!" (LCtrl + right Alt)
; where AltGr is right Alt, but on a Kana-style layout right Alt is a plain Alt
; and "<^>!" typed Ctrl+Alt, so the keystroke is wrapped in a press of that
; layout's AltGr key, by its virtual key (KS_AltGrSendKey): named "SC138", the
; press made AHK add a real right Alt, a plain Alt there, to the keystroke. An
; AltGr key already down (held by the user or a tap-hold) is left alone: the
; wrap's release would end that hold. A modifier name that is neither AltGr
; nor in the prefix map is logged and skipped rather than corrupting the
; keystroke.
; @param Mods {Array} Modifier names ("Ctrl", "Shift", "Alt", "Win", "AltGr").
; @param Key {String} AHK key name.
; @param Blind {Boolean} True to keep the modifiers held around the keystroke.
; @return {String} The SendInput payload, "" when AltGr has no send name.
_TextSenderKeystroke(Mods, Key, Blind := false) {
	global _TextSenderKeyIsDown
	Prefix := ""
	AltGr := false
	for _, KeystrokeModifierName in Mods {
		if (StrLower(Trim(KeystrokeModifierName)) == "altgr") {
			AltGr := true
			continue
		}
		Symbol := _TextSenderModifierPrefix(KeystrokeModifierName)
		if (Symbol == "") {
			LoggerWarn("TextSender", "TextPressKey: unknown modifier token '{1}' for key '{2}' - ignored.", KeystrokeModifierName, Key)
			continue
		}
		Prefix .= Symbol
	}
	Stroke := Prefix . "{" . Key . "}"
	if AltGr {
		AltGrKey := KS_AltGrKeyName()
		if (AltGrKey == "RAlt") {
			Stroke := "<^>!" . Stroke
		} else if !_TextSenderKeyIsDown.Call(AltGrKey) {
			SendKey := KS_AltGrSendKey()
			if (SendKey == "") {
				LoggerError("TextSender", "TextPressKey: the layout's AltGr key has no virtual key to send; '{1}' was not sent.", Key)
				return ""
			}
			Stroke := "{" . SendKey . " down}" . Stroke . "{" . SendKey . " up}"
		}
	}
	return (Blind ? "{Blind}" : "") . Stroke
}

; Send string for a sustained Down or Up of key Key. The layout's AltGr on a
; Kana-style layout goes out by its virtual key (see KS_AltGrSendKey), with
; {Blind}: AHK then treats it as an ordinary key, and without {Blind} it would
; lift the modifiers the user holds around it.
; @param Key {String} AHK key name.
; @param Direction {String} "Down" or "Up".
; @return {String} The SendInput payload, "" when AltGr has no send name (the
;         caller refuses and logs: this can run under the synthetic ledger's Critical).
_TextSenderSustainedKey(Key, Direction) {
	if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP and Key == KS_AltGrKeyName()) {
		SendKey := KS_AltGrSendKey()
		return (SendKey == "") ? "" : "{Blind}{" . SendKey . " " . Direction . "}"
	}
	return "{" . Key . " " . Direction . "}"
}

; Splits a space-delimited modifier STRING (the AHK-style form that dozens of
; tap-hold / gesture call sites pass, e.g. "Shift", "Ctrl Shift", "Blind") into
; its modifier names. Without this parsing the modifiers were silently dropped
; and the bare key was sent (back-Tab became a forward Tab; Ctrl+BackSpace
; word-delete degraded to a single delete). "Blind" is returned separately so a
; held modifier survives.
; @return {Array} The modifier names; Blind receives whether "Blind" appeared.
_TextSenderModifierWords(ModStr, &Blind) {
	Blind := false
	Words := []
	for Token in StrSplit(Trim(ModStr), " ") {
		Token := Trim(Token)
		if (Token = "")
			continue
		if (Token = "Blind") {
			Blind := true
			continue
		}
		Words.Push(Token)
	}
	return Words
}

; Normalizes a modifier name (string or alias) to a TextSender modifier name.
; Returns "" for unknown values so callers can skip them safely.
_TextSenderNormalizeModifierKey(Token) {
	switch StrLower(Trim(Token)) {
		case "ctrl", "lctrl", "rctrl":
			return "Ctrl"
		case "shift", "lshift", "rshift":
			return "Shift"
		case "alt", "lalt", "ralt":
			return "Alt"
		; AltGr is not right Alt: normalizing it to RAlt gave a plain Alt.
		case "altgr":
			return "AltGr"
		case "win", "lwin", "rwin", "cmd":
			return "LWin"
		default:
			return ""
	}
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
; work returned by atomic_commit remains outside the transaction. The output
; goes out at TEXT_SENDER_SEND_LEVEL like every other TextSender emission.
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
			_TextSenderAtSendLevel(SenderFn)
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

; Runs one TextSender OS emission at TEXT_SENDER_SEND_LEVEL and gives the
; calling thread its own SendLevel back, even when the emission throws. This is
; the one owner of the emission level: the text of an accepted AI prediction
; used to reach its send primitive directly, so a physical Tab accepting it from
; its #InputLevel 2 hotkey typed the prediction at SendLevel 2, as input every
; hook below level 2 treats as the user's own typing
; (llm-accept-injects-exact-text).
; @param SendFn {Func} Zero-arity emission.
; @return {Any} What SendFn returned.
_TextSenderAtSendLevel(SendFn) {
	global TEXT_SENDER_SEND_LEVEL
	PreviousSendLevel := A_SendLevel
	SendLevel(TEXT_SENDER_SEND_LEVEL)
	try
		return SendFn.Call()
	finally
		SendLevel(PreviousSendLevel)
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
	;
	; The send runs at TEXT_SENDER_SEND_LEVEL, never at the caller's level.
	try {
		; Declaration and OS output are one transaction. HS_DeclareSyntheticEffect
		; used to restore Critical and run tooltip effects before this call, which
		; let a physical OnChar enter the future buffer state before the caret move
		; reached Windows. The canonical owner keeps only RAM mutation + SendInput
		; under Critical and finishes GUI/analytics work after restoring it.
		; IsSet-guarded because headless adapter runners may omit the hotstring layer.
		if ((Operation == "key press" or Operation == "modified key press")
			and IsSet(HS_RunSyntheticInputTransaction)) {
			_TextSenderAtSendLevel(
				() => HS_RunSyntheticInputTransaction(Keys, _AHK_SendInput.Bind(Keys)))
		} else {
			_TextSenderAtSendLevel(_AHK_SendInput.Bind(Keys))
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
; Callback is invoked after Ctrl+V is emitted (still on the timer thread) so callers
; are notified after the primitive returns, without an application acknowledgement. The direct
; callback previously ran before the deferred timer even started.
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
	EraseCount := (Opts is Map) ? Opts.Get("erase_before", 0) : 0

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
		; Delegate rollback to the central clipboard owner. The process generation
		; excludes newer driver injections, but cannot exclude an external copy.
		; With no recorded ownership sequence, any positive observable sequence
		; wins even on the first attempt. An observed zero retains the existing
		; unfenced rollback policy; it does not prove that this payload is still ours.
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

	; Host probes and logging may yield: keep them before all final guards.
	_TextSenderTryClipboardDiagnostic("write-ready", StrLen(Text), EraseCount,
		Generation, OwnedSequence)

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
			_AHK_SendInput.Bind(_TextSenderErasePrefix(Opts) . "^v"), Opts, "clipboard paste")
		if !Result.Ok {
			_TextSenderTryClipboardDiagnostic("send-refused", StrLen(Text), EraseCount,
				Generation, OwnedSequence, false)
			_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
			_TextSenderInvokeCallback(Callback, false, Result.ErrorMessage)
			return
		}
		CompletionError := Result.ErrorMessage
	} else if !_TextSenderSendInput("^v", "clipboard paste") {
		_TextSenderTryClipboardDiagnostic("send-refused", StrLen(Text), EraseCount,
			Generation, OwnedSequence, false)
		_TextSendRestoreClipboard(Saved, Generation, OwnedSequence)
		_TextSenderInvokeCallback(Callback, false, "clipboard paste failed")
		return
	}

	_TextSenderTryClipboardDiagnostic("send-returned", StrLen(Text), EraseCount,
		Generation, OwnedSequence, true)

	; Fire the completion callback now that the paste keystroke has been emitted.
	; Placed before the restore timer so callers can inspect A_Clipboard while it
	; still holds the injected text. Emission does not acknowledge application processing.
	_TextSenderInvokeCallback(Callback, true, CompletionError)

	; Schedule restoration after the existing delay; this is not an application acknowledgement.
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
	if (Generation != _TEXT_CLIPBOARD_GENERATION) {
		_TextSenderTryClipboardDiagnostic("restore-skipped-generation", 0, 0, Generation, OwnedSequence)
		return
	}
	; The user may have copied something after this request pasted. Restore only
	; while this transaction still owns the exact clipboard sequence; otherwise
	; any restore would silently overwrite the user's newer clipboard content.
	if (!OwnedSequence or CB_GetSequenceNumber() != OwnedSequence) {
		_TextSenderTryClipboardDiagnostic("restore-skipped-sequence", 0, 0, Generation, OwnedSequence)
		return
	}
	RestoreSettled := CB_RestoreOwnedAllEventually(Saved, OwnedSequence,
		_TEXT_CLIPBOARD_OWNER_TOKEN, "text_sender", false)
	; Observe the request after it is owned: logging cannot open a new admission gap.
	_TextSenderTryClipboardDiagnostic(RestoreSettled ? "restore-owner-settled"
		: "restore-owner-pending", 0, 0, Generation, OwnedSequence)
}

; Delegates the ownership-unavailable rollback to the central clipboard owner.
; The generation check rejects newer driver injections, not external copies.
; Without a recorded sequence, a positive observable sequence wins on every
; attempt, including the first. A zero observation preserves the existing
; unfenced rollback policy and remains unresolved ownership risk.
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

; The keystrokes that erase Count characters before the text of an atomic
; output. They lead the SAME SendInput string as the text or the paste, so the
; erasure and its replacement reach the OS as one batch: no physical key can land
; between them, and admission is checked once for both.
; @param Opts {Map|0} TextSend options; "erase_before" is the Backspace count.
; @returns {String} "{Backspace N}", or "" when nothing is erased.
_TextSenderErasePrefix(Opts) {
	Count := (Opts is Map) ? Opts.Get("erase_before", 0) : 0
	if !(Count is Integer) or Count < 0
		throw ValueError("erase_before must be a non-negative integer.")
	return (Count > 0) ? "{Backspace " . Count . "}" : ""
}

; Whether the foreground application must receive a text by paste rather than
; typed: Windows 11's Notepad types the last character of a typed burst in
; place of the others (OutputHostTakesTextByPaste, the rule the hotstring
; engine follows too). An accepted AI prediction typed there as text came out
; as one repeated letter (llm-accept-notepad-paste). IsSet-guarded because
; headless adapter runners may omit the hotstring layer, which owns the
; foreground receipt.
; @return {Boolean} True when "auto" must paste whatever the payload length.
_TextSenderHostTakesTextByPaste() {
	if !IsSet(OutputHostResolve) or !IsSet(OutputHostTakesTextByPaste)
		return false
	return OutputHostTakesTextByPaste(OutputHostResolve())
}

; Inserts text at the current insertion point.
; Uses the Clipboard port (CB_SaveAll / CB_Write / CB_RestoreAll) for the clipboard
; path so the interaction is mockable and the driver has one canonical clipboard
; code path.
; @param Text     {String}   The Unicode text to insert.
; @param Opts     {Map|0}    { mode?: "direct"|"clipboard"|"native"|"auto",
;                              erase_before?: Integer — admission-owned deletion;
;                              deleted_text?: String — exact native deleted suffix }
; @param Callback {Func|0}   Called with the completion Boolean and error message.
TextSend(Text, Opts, Callback) {
	global TEXT_CLIPBOARD_THRESHOLD, _TEXT_CLIPBOARD_QUEUE
	Mode := "auto"
	if (Opts is Map) and Opts.Has("mode") and Opts["mode"] != ""
		Mode := Opts["mode"]
	; Erasing typed text is only safe where admission proves the target is
	; unchanged: without it the Backspaces could land in whatever has focus now.
	try
		ErasePrefix := _TextSenderErasePrefix(Opts)
	catch as Err {
		_TextSenderInvokeCallback(Callback, false, Err.Message)
		return
	}
	if (ErasePrefix != "" and !_TextSenderHasAtomicHooks(Opts)) {
		_TextSenderInvokeCallback(Callback, false,
			"erasing before the text requires an atomic, admission-guarded output")
		return
	}

	; Notepad uses its verified editor worker; other long payloads use the paste FIFO.
	if Mode = "auto"
		Mode := _TextSenderHostTakesTextByPaste() ? "native"
			: (StrLen(Text) > TEXT_CLIPBOARD_THRESHOLD ? "clipboard" : "direct")

	if Mode = "native" {
		_TextSenderQueueNative(Text, Opts, Callback)
		return
	}

	if Mode = "clipboard" {
		; The clipboard round-trip (write + blocking ClipWait + paste) is deferred
		; onto a one-shot timer so it NEVER runs on the input-gating keyboard thread.
		; Blocking there on ClipWait would starve the low-level hook and drop the
		; user's next keystrokes; running it off-thread lets the hotkey return at once.
		; CB_SaveAll() runs only after this request owns the FIFO head. Capturing on
		; the keyboard caller would make its later restore clobber a user copy made
		; while this request waited behind an earlier transaction.
		; Callback is passed into _TextSendClipboard and fired there after Ctrl+V, so
		; callers observe primitive emission, not application consumption of the clipboard.
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
				_AHK_SendInput.Bind(ErasePrefix . "{Text}" . Text), Opts, "direct-mode SendInput text")
			_TextSenderInvokeCallback(Callback, Result.Ok, Result.ErrorMessage)
		} else {
			Ok := true
			ErrorMessage := ""
			try
				_TextSenderAtSendLevel(() => _AHK_SendText.Call(Text))
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

; Selects the Count characters left of the caret: Shift+Left Count times, in
; one SendInput batch. One Left moves over one character, a surrogate pair (an
; emoji) included, so Count is a codepoint count, not a UTF-16 one. The caret
; move is declared to the hotstring buffers like every other key press.
; @param Count {Integer} Number of characters to select.
; @return {Boolean} True when the keystrokes were sent (nothing to select counts).
TextSelectBack(Count) {
	if !(Count is Integer) or Count < 0
		throw ValueError("TextSelectBack expects a non-negative integer count.")
	if (Count == 0)
		return true
	return _TextSenderSendInput("+{Left " . Count . "}", "modified key press")
}

; Sends the menu mask key (A_MenuMaskKey) without releasing held modifiers. A
; lone Alt or Win tap makes Windows put the focused window's menu bar in menu
; mode (or open the Start menu); a keystroke between the modifier's Down and Up
; turns it into a chord that does nothing, which is how AutoHotkey masks its own
; Alt and Win hotkeys. {Blind} keeps the held modifier down around the mask.
; @return {Boolean} True when the mask was sent.
TextSendMenuMask() {
	return _TextSenderSendInput("{Blind}{" . A_MenuMaskKey . "}", "menu mask", false)
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
				Payload := _TextSenderSustainedKey(ModKey, Modifiers)
				if (Payload == "" and LogFailure)
					LoggerError("TextSender", "TextPressKey: the layout's AltGr key has no virtual key to send; '{1}' {2} was not sent.", ModKey, Modifiers)
				if (Payload == "" or !_TextSenderSendInput(Payload, "modifier " . Modifiers, LogFailure)) {
					; A failed multi-key Down must not leave the keys already sent
					; logically held by the driver.  Release them in reverse order;
					; each release is guarded/logged independently because the
					; original injection provider may be transiently unavailable.
					if (Modifiers == "Down") {
						loop SentKeys.Length {
							SentKey := SentKeys[SentKeys.Length - A_Index + 1]
							Rollback := _TextSenderSustainedKey(SentKey, "Up")
							if (Rollback == "" or !_TextSenderSendInput(Rollback, "modifier rollback", LogFailure))
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
		Payload := _TextSenderSustainedKey(Key, Modifiers)
		if (Payload == "") {
			if LogFailure
				LoggerError("TextSender", "TextPressKey: the layout's AltGr key has no virtual key to send; '{1}' {2} was not sent.", Key, Modifiers)
			return false
		}
		return _TextSenderSendInput(Payload, "sustained key " . Modifiers, LogFailure)
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
		Stroke := _TextSenderKeystroke(Mods, Key)
		return (Stroke == "") ? false : _TextSenderSendInput(Stroke, "modified key press")
	}
	Words := []
	Blind := false
	if (Modifiers is String) and (Modifiers != "") {
		; AHK-style space-delimited modifier string ("Shift", "Ctrl Shift",
		; "Blind", ...). Previously this fell through with no prefix and the bare
		; key was emitted, silently dropping the modifier.
		Words := _TextSenderModifierWords(Modifiers, &Blind)
	}
	Stroke := _TextSenderKeystroke(Words, Key, Blind)
	return (Stroke == "") ? false : _TextSenderSendInput(Stroke, "key press")
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TEXT_SENDER := Map(
    "send",       TextSend,
    "eraseChars", TextEraseChars,
    "pressKey",   TextPressKey,
)
