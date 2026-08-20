; infra/hotstrings/hotstring_send.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Low-level Send & Ring Buffer
; DESCRIPTION:
; Low-level send primitives (SendNewResult, SendFinalResult, SendInstant,
; ActivateHotstrings, GetSelection) and the last-sent-character ring buffer
; (_LSC_*) used by time-gated triggers and deadkey sequences.
;
; Included by infra/hotstrings/hotstring_engine.ahk after the constants section.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ Low-level send layer =======
; =======================================
; =======================================

; Internal — the production-lean registration path used by every CreateHotstring
; / CreateCaseSensitiveHotstrings / CreateRawCallbackHotstring call. It hands the
; already-known matching flags (the ``*?C`` subset) straight to HSE_Register,
; skipping the ``:flags:B0O:abbrev`` string build AND the matching
; ``_MirrorRegistrationToHSE`` re-parse that the old per-call path incurred on
; every one of the ~3700 boot registrations.
;
; ``Rec`` is the resolved ``_HotstringRegistrar`` (0 in production). When a test
; has installed a recorder, the caller passes the assembled trigger-spec string
; and a real per-spec callback, which we forward to the recorder so the
; introspection tests (registration counts, spec strings, direct callback
; invocation) keep working byte-for-byte. In production Rec is 0, so callers pass
; "" / 0 for those two: HSE_DispatchMatch dispatches via ``Spec.Replacement`` and
; never invokes the callback, so building either would be pure boot-time waste.
_RegisterHotstringFast(Rec, HseFlags, Abbrev, TrigSpec, Callback, Meta := unset) {
		if Rec {
				Rec(TrigSpec, Callback)
		}
		if IsSet(Meta) {
				HSE_Register(HseFlags, Abbrev, Callback, Meta)
		} else {
				HSE_Register(HseFlags, Abbrev, Callback)
		}
}

; Extract just the matching-relevant flag letters (``*``, ``?``, ``C``) in
; canonical order from an AHK option string — the exact subset HSE_Register
; needs, identical to what ``_MirrorRegistrationToHSE`` recovered by re-parsing
; the assembled spec. Computing it directly at the call site is what lets the
; production path skip building and re-parsing the ``:flags:B0O:abbrev`` string.
_HseFlagSubset(Flags) {
		Out := ""
		if InStr(Flags, "*") {
				Out .= "*"
		}
		if InStr(Flags, "?") {
				Out .= "?"
		}
		if InStr(Flags, "C") {
				Out .= "C"
		}
		return Out
}

; Parse the AHK ``:flags:abbrev`` trigger spec and forward to HSE_Register.
; Flag letters that HSE understands (``*``, ``?``, ``C``) are passed
; through verbatim; the rest (``B0``, ``O`` — both irrelevant to matching)
; are dropped. Abbreviations are registered as-is so the HSE bucket
; index stays in lockstep with the upstream registration call.
_MirrorRegistrationToHSE(TriggerSpec, Callback, Meta := unset) {
		; Parse the ``:<flags>:<abbrev>`` spec with InStr rather than a per-call
		; RegExMatch: this runs once for EVERY hotstring registered at boot (~5400
		; calls), and the abbreviation was just assembled by the caller — a regex to
		; pull it back apart is pure overhead on the startup hot path. Semantics match
		; the old ``^:([^:]*):(.+)$``: flags hold no colon, the abbreviation is
		; everything after the second colon and must be non-empty.
		if (SubStr(TriggerSpec, 1, 1) != ":") {
				return
		}
		SecondColon := InStr(TriggerSpec, ":", true, 2)
		if (!SecondColon) {
				return
		}
		RawFlags := SubStr(TriggerSpec, 2, SecondColon - 2)
		Abbrev := SubStr(TriggerSpec, SecondColon + 1)
		if (Abbrev == "") {
				return
		}
		HseFlags := ""
		if InStr(RawFlags, "*") {
				HseFlags .= "*"
		}
		if InStr(RawFlags, "?") {
				HseFlags .= "?"
		}
		if InStr(RawFlags, "C") {
				HseFlags .= "C"
		}
		if IsSet(Meta) {
				HSE_Register(HseFlags, Abbrev, Callback, Meta)
		} else {
				HSE_Register(HseFlags, Abbrev, Callback)
		}
}

; Hotstrings will still be triggered downstream, so SendNewResult("a") can
; cascade a ➜ b ➜ c (final result). OnlyText=true wraps the payload in {Text}
; to avoid modifier side effects on symbols like ', ", accents. UpdateRing
; controls whether Text feeds the last-sent-character ring: pass false for a
; backspace-only call (e.g. the Notepad clipboard branch's pre-paste erase),
; where Text is a control sequence ("{BackSpace 5}") rather than a real
; emitted character — SubStr(Text, -1) on that sequence would record its
; trailing "}" instead of what actually landed on screen.
_SendVerdictSucceeded(Result) {
		; Legacy recorder hooks return an empty string after capturing a send. Only an
		; explicit Boolean false is a failure; type-checking first prevents the AHK v2
		; `"0" = false` coercion from rejecting a string token as a failed injection.
		return !((Result is Integer) and Result = 0)
}

SendNewResult(Text, OnlyText := True, UpdateRing := True) {
		; Every layout/hotstring callback reaches this primitive.  A failed OS send
		; must be contained here and must NOT advance the output ring: advancing it
		; after a failed injection corrupts deadkey/time-gated decisions as though
		; the character reached the foreground application.
		try {
				if _SendHook {
						Hook := _SendHook
						if !_SendVerdictSucceeded(Hook("SendNewResult", Text, OnlyText))
								return false
				} else {
						if OnlyText {
								SendEvent("{Text}" Text)
						} else {
								SendEvent(Text)
						}
				}
		} catch as Err {
				LoggerError("Hotstrings", "SendNewResult failed: {1}", Err.Message)
				return false
		}
		; _EmitReachedScreen for the same reason the catch above returns without
		; advancing the ring: a character that never reached the application must not
		; be recorded as though it had. This is the primitive EVERY Shift/CapsLock/
		; AltGr layer emit goes through, so it is where the gate belongs — the
		; dead-key fix reached the two direct SendEvent emitters and missed this one.
		; Compose "Â" by typing the circumflex dead key then Shift+A and the ring held
		; ['A', 'Â'] for a single visible character; composition plus a Shift capital
		; is the mainline use of that dead key.
		;
		; IsSet-guarded because this primitive is also reachable from contexts where
		; the keymap module is not loaded (tools/, standalone tests), and there the
		; unqualified pre-fix behaviour is correct.
		if UpdateRing and (!IsSet(_EmitReachedScreen) or _EmitReachedScreen()) {
				UpdateLastSentCharacter(SubStr(Text, -1))
		}
		return true
}

; SendInput prevents other hotstrings/hotkeys from activating, so this is the
; "final" result — used when we do not want cascading expansion.
_SendFinalResultUnchecked(Text, OnlyText) {
		if _SendHook {
				Hook := _SendHook
				return _SendVerdictSucceeded(Hook("SendFinalResult", Text, OnlyText))
		}
		if OnlyText
				SendInput("{Text}" Text)
		else
				SendInput(Text)
		return true
}

; @param DeclareBufferEffect {Boolean} True when Text is a caret/document edit
; invisible to the prefix InputHook. The declaration and SendInput then share the
; canonical Critical transaction instead of being two interruptible statements.
SendFinalResult(Text, OnlyText := False, DeclareBufferEffect := false) {
		try {
				if DeclareBufferEffect and IsSet(HS_RunSyntheticInputTransaction)
						return _SendVerdictSucceeded(HS_RunSyntheticInputTransaction(Text,
								_SendFinalResultUnchecked.Bind(Text, OnlyText)))
				return _SendFinalResultUnchecked(Text, OnlyText)
		} catch as Err {
				LoggerError("Hotstrings", "SendFinalResult failed: {1}", Err.Message)
				return false
		}
}

_SendInstant_RestoreClipboard(OldClip, OwnedSequence, OwnerToken) {
	global _SEND_INSTANT_CLIP_BUSY
	try {
		; A delayed restore owns exactly the payload sequence it wrote. A user copy
		; (or another clipboard producer) after Ctrl+V must win over our stale
		; snapshot instead of being silently overwritten by this timer.
		if (OwnedSequence != 0 && CB_GetSequenceNumber() = OwnedSequence)
			CB_RestoreAll(OldClip)
	} finally {
		if OwnerToken
			CB_EndOwnedTransaction(OwnerToken)
		; Release even when the clipboard is locked: a failed restore must not
		; permanently force every later expansion onto the slow text path.
		_SEND_INSTANT_CLIP_BUSY := false
	}
}

SendInstant(Text, Prefix := "") {
	; Sends a large text through the clipboard while keeping Prefix (typically the
	; hotstring erase sequence) in the SAME SendInput burst as Ctrl+V. Splitting
	; these two injections lets a physical key land between erase and paste.
	; Uses try so the user's clipboard is restored even on error/crash.
	global _SEND_INSTANT_CLIP_BUSY
	if _SendHook {
		try {
			Hook := _SendHook
			return _SendVerdictSucceeded(Hook("SendInstant", Text, Prefix))
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant hook failed: {1}", Err.Message)
			return false
		}
	}
	; Reentrancy guard: a previous SendInstant's deferred restore has not run
	; yet, so the clipboard still holds its payload. Touching A_Clipboard now
	; would race the in-flight paste/restore — fall back to the clipboard-free
	; {Text} route so the two dances never interleave.
	; SendInput (not SendEvent) is used here to stay atomic and avoid interleaving
	; with the InputHook, which processes SendEvent characters as physical input.
	if _SEND_INSTANT_CLIP_BUSY {
		try LoggerDebug("Hotstrings", "SendInstant: a restore is still in flight; routing through the clipboard-free path.")
		try {
			SendInput(Prefix . "{Text}" . Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	; The Notepad caller holds Critical across this whole call, so anything slow
	; here starves the keyboard hook rather than merely delaying one expansion.
	; CB_SaveAll snapshots EVERY format, and A_Clipboard retries for
	; #ClipboardTimeout — a full second by default — when another process holds
	; the clipboard open. A remote-desktop client, a clipboard manager or a
	; freshly captured full-screen bitmap can therefore freeze the thread for
	; ~1-2 s. Route those cases through the clipboard-free path instead: it
	; renders slightly worse in Notepad, which is precisely the trade the
	; reentrancy branch above already accepts.
	if (CB_IsBusy() or CB_HasImage()) {
		try LoggerDebug("Hotstrings", "SendInstant: clipboard is contended or holds a bitmap; routing through the clipboard-free path.")
		try {
			SendInput(Prefix . "{Text}" . Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	OldClipboard := CB_SaveAll()
	if (Type(OldClipboard) == "String" && OldClipboard == "__CB_SAVE_ERROR__") {
		try LoggerWarn("Hotstrings", "SendInstant: clipboard snapshot failed; expansion was not injected.")
		return false
	}
	_SEND_INSTANT_CLIP_BUSY := true
	OwnerToken := 0
	RestoreCallback := false
	RestoreTimerArmed := false
	try {
		OwnerToken := CB_BeginOwnedTransaction("hotstring_send_instant", true)
		if !CB_Write(Text)
			throw Error("clipboard write failed")
		OwnedSequence := CB_GetSequenceNumber()
		if !OwnedSequence
			throw Error("clipboard sequence unavailable")
		; Arm every fallible post-paste stage before the irreversible injection. If
		; timer registration fails, no erase/paste has reached the application and
		; the caller can safely leave its engine and preview state untouched.
		RestoreCallback := _SendInstant_RestoreClipboard.Bind(OldClipboard, OwnedSequence, OwnerToken)
		SetTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)
		RestoreTimerArmed := true
		; Prefix and Ctrl+V are one kernel injection transaction. Critical callers
		; therefore cannot be interrupted after the erase but before the paste.
		SendInput(Prefix . "^v")
		return true
	} catch as err {
		; SendInput can fail after the restore timer was armed. Cancel that exact
		; callback before doing the cleanup inline so ownership is ended once.
		if RestoreTimerArmed
			try SetTimer(RestoreCallback, 0)
		try CB_RestoreAll(OldClipboard)
		if OwnerToken
			try CB_EndOwnedTransaction(OwnerToken)
		_SEND_INSTANT_CLIP_BUSY := false
		try LoggerError("Hotstrings", "SendInstant: clipboard injection failed: {1}", err.Message)
		return false
	}
}

; Mirror a literal edit which this module has already proven reached the screen.
; Synthetic sends below the prefix watcher's I1 level never reach its OnChar, so
; callers must publish the same edit to the longer LLM context themselves. Keep
; this helper side-effect-free when the bridge is inactive and require the owner
; to hold the same Critical transaction as the matching HSE mutation.
_HSE_MirrorLiteralEditToLlm(DeleteFromEnd, InsertedText := "") {
		if !A_IsCritical
				throw Error("_HSE_MirrorLiteralEditToLlm requires a Critical buffer transaction.")
		if (IsSet(_LLM_Bridge_Active) and _LLM_Bridge_Active
				and IsSet(_LLM_Bridge_ApplyBufferEdit))
				_LLM_Bridge_ApplyBufferEdit(DeleteFromEnd, InsertedText)
}

; Commit any pending end-char hotstring before the next symbol is emitted.
; The temporary space is first put on screen so an end-char-gated trigger can
; claim it. A successful dispatch is forced to consume that space; only a
; declined/no-match attempt needs the compensating backspace.
;
; The commit itself is NOT a hook round-trip any more. It used to be: the space
; was injected at the caller's send level, the prefix-watcher InputHook observed
; it, and _OnPrefixChar fired the trigger. That design needs the message loop to
; run BETWEEN the two sends — and every caller reaches this function from a
; serialized layer hotkey that holds Critical across both the poke AND the
; following NNBSP+punctuation emit, so no InputHook callback can be delivered
; until all of it has already landed. The queued OnChar(' ') then fired the
; expansion at a caret that had moved past the punctuation, destroying the
; character the user typed, and HSE_ApplyExpansion mirrored the same wrong edit
; into HSE_Buffer so nothing could detect the corruption. Making the poke atomic
; did not break the round-trip — it proved the round-trip was never possible.
;
; So the engine is fed DIRECTLY, and the poke is emitted BELOW the watcher's
; input level so it is not re-ingested as a phantom keystroke on top of that.
; The space is still really sent: it has to be on screen for the expansion's own
; backspace count to be right.
;
; The whole dance is gated on there actually being a pending abbreviation. When
; HSE_Buffer is empty (the common case — punctuation typed at a word boundary or
; after a space) there is nothing to commit, so the pair is skipped entirely on
; a hot, default key set. IsSet guards the load order: the engine buffer global
; lives in hotstring_engine_main.ahk, included alongside this file.
ActivateHotstrings() {
		global HSE_LastEndChar, _PrefixPrivateResidue
		; Nothing to flush — no pending abbreviation, so skip the costly poke.
		if (IsSet(HSE_Buffer) and HSE_Buffer == "") {
				return true
		}
		previous_critical := Critical("On")
		PreviousSendLevel := A_SendLevel
		try {
				; The prefix watcher's InputHook is armed "V L0 I1", so level 0 is below
				; what it accepts: the poke lands on screen without ever coming back as
				; an OnChar the engine would count twice.
				SendLevel(0)
				; The poke is temporary and is therefore not ring history. A successful
				; fire lets the dispatcher record its real final output; a failed cleanup
				; below records the Space only once it becomes permanent.
				if !SendNewResult(" ", true, false)
						return false
				; IsPhysical=true on both feeds: the dispatch below holds HSE_Suppressed
				; for its own send burst (released on a deferred timer), and a
				; non-physical feed is a no-op while it is up.
				PendingMatch := HSE_FeedChar(" ", true)
				_HSE_MirrorLiteralEditToLlm(0, " ")
				Fired := false
				if (PendingMatch != "") {
						; Contained: this runs inside a layer callback that still owes the
						; user its punctuation, so a throwing expansion must not abort the
						; emit that follows.
						try {
								CommittedScreenEffect := 0
								Fired := HSE_DispatchMatch(PendingMatch, HSE_LastEndChar,
										&CommittedScreenEffect, true)
								; Same metrics contract the prefix-watcher fire path follows:
								; only a real expansion is a fire, and the record is queued
								; rather than logged inline so no disk work lands on the
								; keyboard thread.
								if Fired {
										FiredReplacement := PendingMatch.HasOwnProp("Replacement") ? PendingMatch.Replacement : PendingMatch.Trigger
										FiredCategory := PendingMatch.HasOwnProp("Category") ? PendingMatch.Category : ""
										FiredSection := PendingMatch.HasOwnProp("Section") ? PendingMatch.Section : ""
										; Third of the three fire paths, reaching the same sink —
										; the privacy flag has to travel here too, or a personal
										; expansion committed by a punctuation key leaks while the
										; other two paths are clean.
										FiredIsPrivate := PendingMatch.HasOwnProp("IsPrivate") && PendingMatch.IsPrivate
										if FiredIsPrivate and IsSet(_PrefixPrivateResidue)
												_PrefixPrivateResidue := true
										if IsSet(_PrefixCommitPostFireEffect)
												_PrefixCommitPostFireEffect(CommittedScreenEffect)
										if IsSet(_HSE_QueueFireLog)
												try _HSE_QueueFireLog(PendingMatch.Trigger, FiredReplacement, "endchar", FiredCategory, FiredSection, FiredIsPrivate)
								}
						} catch as CommitErr {
								; ERROR is severity 40 — ABOVE the default INFO level — so unlike the
								; DEBUG sites this line reaches the rotating log with no user action
								; at all. The flag is read here rather than reused from the `if Fired`
								; block above because this catch runs on the path where the dispatch
								; THREW: Fired was never assigned, so that block never executed.
								CommitIsPrivate := PendingMatch.HasOwnProp("IsPrivate") && PendingMatch.IsPrivate
								try LoggerError("Hotstrings", "ActivateHotstrings: committing '{1}' failed: {2}",
										CommitIsPrivate ? PersonalInfoRedactForLog(PendingMatch.Trigger) : PendingMatch.Trigger,
										CommitErr.Message)
						}
				}
				; A successful forced commit consumed the temporary Space as part of its
				; canonical edit. Backspacing here would erase the replacement's last
				; character, especially when Space is also a configured consumed delimiter.
				if Fired
						return true
				if !SendNewResult("{BackSpace}", False, false) {
						; Cleanup failed, so the poke is now real screen state. Preserve the
						; already-appended HSE/LLM Space and publish it to the output ring.
						if IsSet(_ResetPrefixBuffer)
								try _ResetPrefixBuffer()
						UpdateLastSentCharacter(" ")
						return false
				}
				HSE_FeedBackspace(true)
				_HSE_MirrorLiteralEditToLlm(1)
				return true
		} finally {
				SendLevel(PreviousSendLevel)
				Critical(previous_critical)
		}
}

; Clipboard copy completion is asynchronous in many applications. Waiting in a
; hotkey thread with ClipWait freezes every low-level hook dispatch behind it.
; Keep one owned capture job and poll with a zero-timeout probe instead; callers
; receive the text only while the original foreground context is still current.
global _SelectionCaptureJob := false
global _SelectionCaptureNextId := 0
global SELECTION_CAPTURE_POLL_MS := 15
global SELECTION_CAPTURE_INPUT_GRACE_MS := 20

GetSelectionAsync(OnReady) {
		global _SelectionCaptureJob, _SelectionCaptureNextId
		global SELECTION_CAPTURE_POLL_MS

		if A_IsSuspended
				return false
		if !IsObject(OnReady)
				throw TypeError("GetSelectionAsync requires a callback object")

		; The newest user command owns the clipboard capture. Finishing the prior
		; job first stops its timer and restores its clipboard snapshot before the
		; new Ctrl+C clears the clipboard.
		if IsObject(_SelectionCaptureJob)
				_SelectionCaptureFinish(_SelectionCaptureJob, "", false, "superseded")

		Job := Map(
				"id", ++_SelectionCaptureNextId,
				"callback", OnReady,
				"started", A_TickCount,
				"foreground", WinExist("A"),
				"clipboard", "",
				"clear_sequence", 0,
				"owner_token", 0,
				"expected_change", 0,
				"timer", 0
		)
		try {
				Job["clipboard"] := ClipboardAll()
				Job["owner_token"] := CB_BeginOwnedTransaction("selection_capture")
				if !CB_Write("")
						throw Error("clipboard clear failed")
				Job["clear_sequence"] := _SelectionClipboardSequence()
				Job["expected_change"] := CB_ExpectOwnedChange()
				SendEvent("^c")
				Job["timer"] := _SelectionCapturePoll.Bind(Job)
				_SelectionCaptureJob := Job
				SetTimer(Job["timer"], SELECTION_CAPTURE_POLL_MS)
				return true
		} catch as Err {
				if Job["expected_change"]
						CB_CancelExpectedChange(Job["expected_change"])
				if Job["owner_token"] {
						try CB_RestoreAll(Job["clipboard"])
						CB_EndOwnedTransaction(Job["owner_token"])
				}
				Job["clipboard"] := ""
				try LoggerError("hotstring_engine", "GetSelectionAsync could not start: {1}", Err.Message)
				return false
		}
}

_SelectionCapturePoll(Job) {
		global _SelectionCaptureJob, GET_SELECTION_TIMEOUT_SEC
		global SELECTION_CAPTURE_INPUT_GRACE_MS

		if !IsObject(_SelectionCaptureJob) || _SelectionCaptureJob["id"] != Job["id"]
				return
	Elapsed := TickElapsed(Job["started"])
		if A_IsSuspended {
				_SelectionCaptureFinish(Job, "", false, "suspended")
				return
		}
		; If a new physical action happened after the shortcut, never inject into
		; its potentially different selection. The small grace absorbs the key-up
		; events that complete the initiating chord.
		if (Elapsed - A_TimeIdlePhysical > SELECTION_CAPTURE_INPUT_GRACE_MS) {
				_SelectionCaptureFinish(Job, "", false, "superseded by input")
				return
		}
		if (WinExist("A") != Job["foreground"]) {
				_SelectionCaptureFinish(Job, "", false, "foreground changed")
				return
		}
		; Zero timeout is a probe, never a blocking wait. Accept every clipboard
		; format so an image selection resolves immediately to an empty text result.
		if ClipWait(0, 1) {
				_SelectionCaptureFinish(Job, A_Clipboard, true, "ready")
				return
		}
		if (Elapsed >= Round(GET_SELECTION_TIMEOUT_SEC * 1000)) {
				try LoggerWarn("hotstring_engine",
						"GetSelectionAsync timed out after {1}s; returning no selection.",
						GET_SELECTION_TIMEOUT_SEC)
				_SelectionCaptureFinish(Job, "", false, "timeout")
		}
}

_SelectionCaptureFinish(Job, Text, Deliver, Reason) {
		global _SelectionCaptureJob

		if !IsObject(_SelectionCaptureJob) || _SelectionCaptureJob["id"] != Job["id"]
				return
		SetTimer(Job["timer"], 0)
		_SelectionCaptureJob := false

		; On a physical-input cancellation, preserve clipboard data which arrived
		; after our clear: it may be the user's own copy, and restoring the old
		; snapshot would silently destroy it. All normal completion paths restore
		; exactly the prior clipboard contents.
		PreserveCurrent := (Reason == "superseded by input"
				and _SelectionClipboardSequence() != Job["clear_sequence"])
		if Job["expected_change"]
				CB_CancelExpectedChange(Job["expected_change"])
		if !PreserveCurrent {
				if !CB_RestoreAll(Job["clipboard"])
						try LoggerError("hotstring_engine", "GetSelectionAsync clipboard restore failed ({1}).", Reason)
		}
		if Job["owner_token"]
				CB_EndOwnedTransaction(Job["owner_token"])
		Job["clipboard"] := ""

		if !Deliver || A_IsSuspended
				return
		try Job["callback"].Call(Text)
		catch as Err {
				try LoggerError("hotstring_engine", "GetSelectionAsync callback failed: {1}", Err.Message)
		}
}

; Kept as a fail-closed compatibility seam. All user-triggered paths must use
; GetSelectionAsync; a synchronous clipboard wait on the hook thread is unsafe.
GetSelection() {
		try LoggerError("hotstring_engine", "GetSelection() is synchronous-only and must not be used on an input path.")
		return ""
}

GetSelectionCancel(*) {
		global _SelectionCaptureJob
		if IsObject(_SelectionCaptureJob)
				_SelectionCaptureFinish(_SelectionCaptureJob, "", false, "cancelled")
}

_SelectionClipboardSequence() {
		try return DllCall("GetClipboardSequenceNumber", "uint")
		catch as Err {
				try LoggerError("hotstring_engine", "GetClipboardSequenceNumber failed: {1}", Err.Message)
				return 0
		}
}

; Set of Microsoft Office (and Teams) executable names.
global MICROSOFT_OFFICE_EXES := Map(
	"Teams.exe", true,
	"ms-teams.exe", true,
	"ONENOTE.exe", true,
	"olk.exe", true,
	"OUTLOOK.EXE", true,
	"WINWORD.EXE", true,
	"EXCEL.EXE", true,
	"POWERPNT.EXE", true,
)

MicrosoftApps() {
		try {
				exe := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
				return MICROSOFT_OFFICE_EXES.Has(exe)
		}
		return false
}





; ==================================================
; ==================================================
; ======= 2/ Last-sent-character ring buffer =======
; ==================================================
; ==================================================

; Fixed-capacity ring of the last N characters emitted by the driver, used by
; hotstrings / rolls / deadkeys to peek at what the user just typed without
; calling back into Win32. The ring avoids the O(n) ``RemoveAt(1)`` memmove
; the previous Array-based implementation performed on every keystroke.
;
; Indexing contract (unchanged for callers of ``GetLastSentCharacterAt``):
;   - Negative offset -k returns the k-th character from the NEWEST
;     (offset -1 = just-pushed char, offset -2 = the one before, …).
;   - Positive offset +k returns the k-th character from the OLDEST
;     still in the buffer (offset +1 = oldest).
;   - Any offset beyond the current fill count returns "".
global _LSC_CAP := 5
global _LSC_RING := ["", "", "", "", ""]
global _LSC_CURSOR := 0  ; 1-based index of the most recently written slot
global _LSC_LEN := 0     ; number of populated slots, saturates at _LSC_CAP

; Push a new character; O(1), no reallocation after boot.
_LSCPush(Char) {
		global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
		_LSC_CURSOR := Mod(_LSC_CURSOR, _LSC_CAP) + 1
		_LSC_RING[_LSC_CURSOR] := Char
		if _LSC_LEN < _LSC_CAP {
				_LSC_LEN += 1
		}
}

; Reset the ring to a known sequence (oldest-first). Kept as a thin wrapper
; so tests can seed state without reaching into globals.
_LSCResetFrom(Chars) {
		global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
		_LSC_RING := []
		loop _LSC_CAP {
				_LSC_RING.Push("")
		}
		_LSC_CURSOR := 0
		_LSC_LEN := 0
		for c in Chars {
				_LSCPush(c)
		}
}
