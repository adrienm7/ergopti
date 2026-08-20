; infra/hotstrings/hotstring_buffer_effects.ahk

; ==============================================================================
; MODULE: Hotstring Buffer Effects
; DESCRIPTION:
; Lets a caller that injects keystrokes SYNTHETICALLY declare what those
; keystrokes did to the text left of the caret, so the hotstring engine buffer
; (``HSE_Buffer``) and the tooltip preview buffer (``_PrefixBuffer``) stay
; describing the same screen.
;
; FEATURES & RATIONALE:
; 1. Both buffers exist to answer one question — "what characters sit
;    immediately to the left of the caret?" — and every hotstring expansion
;    backspaces over that many characters before typing its replacement. A
;    caller that moves the caret without telling them makes the next expansion
;    delete whatever happens to be at the NEW position instead.
; 2. Physical navigation keys are already handled: the prefix watcher's
;    InputHook sees them and resets both buffers. Synthetic ones are not. A
;    ``SendInput`` from the nav layer or a Win-shortcut runs at SendLevel 0 and
;    is filtered out by that hook's own ``I1`` input level, so it is invisible
;    to every existing reset site. This module is the declaration channel those
;    callers were missing.
; 3. Backspace is tracked precisely rather than treated as a reset: deleting a
;    typo usually leaves the user back on a live trigger prefix, and that
;    suggestion should reappear. This mirrors what the physical VK_BACK branch
;    of the watcher already does.
; ==============================================================================

#Requires AutoHotkey v2.0

; Synthetic payloads that provably touch neither the caret nor the document, so
; they must NOT invalidate the buffers. Kept as an explicit allowlist rather
; than a denylist of navigation keys: a denylist silently fails open for every
; caret-moving key nobody thought of, which is exactly how the nav layer came
; to bypass all eight existing reset sites.
;
; ANCHORED, exactly like HS_BUFFER_BACKSPACE_PAYLOAD below and for the same
; reason. The previous form was an array tested with InStr(Payload, "{Volume_Up")
; — a substring match ANYWHERE in the payload — while its own comment claimed it
; matched a prefix of the key token. That fails OPEN for a compound payload that
; also moves the caret ("{End}{Volume_Up}"): it would be waved through as
; text-neutral and leave both buffers describing text no longer on screen. No
; caller emits that shape today, so this is a latent hole rather than a live bug
; — and closing a latent hole in the whole class is cheaper than discovering the
; one caller that opens it. The optional count covers "{Volume_Up 3}".
global HS_BUFFER_NEUTRAL_PAYLOAD := "i)^\{(?:Volume_Up|Volume_Down|Volume_Mute)(?:\s+\d+)?\}$"

; A "{BackSpace}" / "{BackSpace N}" payload and nothing else — the only shape
; whose effect on the buffers is exactly known. Anchored so a payload that also
; moves the caret ("{End}{BackSpace 2}") falls through to the reset branch
; instead of being mistaken for a plain deletion.
global HS_BUFFER_BACKSPACE_PAYLOAD := "i)^\{BackSpace(?:\s+(\d+))?\}$"





; ================================================================
; ================================================================
; ======= 1/ Declaring the effect of a synthetic keystroke =======
; ================================================================
; ================================================================

; Commit only the in-memory effect of a synthetic payload. The caller MUST own a
; Critical transaction which continues through the matching OS send. Otherwise a
; queued physical OnChar can enter the future buffer state before the caret move
; reaches Windows, leaving the buffers on the wrong side of the caret.
;
; The returned token owns every tooltip/analytics side effect. Finish it only
; after leaving Critical; those effects may pump the message loop or log to disk.
; @param Payload {String} The exact Send/SendInput payload about to be emitted.
; @return {Object} Post-commit effects token.
HS_CommitSyntheticEffect(Payload) {
	global HS_BUFFER_NEUTRAL_PAYLOAD, HS_BUFFER_BACKSPACE_PAYLOAD
	if !A_IsCritical
		throw Error("HS_CommitSyntheticEffect requires a Critical send transaction.")

	if RegExMatch(Payload, HS_BUFFER_NEUTRAL_PAYLOAD) {
		return { Kind: "neutral", Payload: Payload }
	}

	if RegExMatch(Payload, HS_BUFFER_BACKSPACE_PAYLOAD, &BsMatch) {
		Reps := (BsMatch[1] != "") ? BsMatch[1] + 0 : 1
		HasPreviewCommit := IsSet(_PrefixCommitBackspace)
		BackspaceCommit := 0
		loop Reps {
			; IsPhysical := true — this deletion really happened on screen, so it
			; must apply even inside a suppress window, exactly like the watcher's
			; physical VK_BACK branch.
			; Production commits BOTH mutations through the state-only watcher helper.
			; Engine-only harnesses keep the fallback, but never call both or one
			; emitted backspace would decrement HSE_Buffer twice.
			if HasPreviewCommit {
				BackspaceCommit := _PrefixCommitBackspace()
			} else if IsSet(HSE_FeedBackspace) {
				HSE_FeedBackspace(true)
			}
		}
		return {
			Kind: "backspace",
			Payload: Payload,
			Repetitions: Reps,
			HasPreviewCommit: HasPreviewCommit,
			BackspaceCommit: BackspaceCommit
		}
	}

	; Everything else moves the caret, changes focus, or rewrites the line. What
	; sits left of the caret is now unknown, so the next typed run must start
	; fresh — the same verdict the watcher reaches for a physical arrow key.
	; KnownTerminatorBefore := true because the cursor lands at a position the
	; next run may legitimately treat as a word start.
	if IsSet(_PrefixCommitInputContext) {
		PrefixCommit := _PrefixCommitInputContext(0, true)
		NeedsLegacyPrefixReset := false
	} else {
		; Engine-only/unit harness fallback. Production always has the paired
		; commit above, so no user-reachable path publishes one buffer first.
		if IsSet(HSE_FeedReset)
			HSE_FeedReset(true, true)
		PrefixCommit := 0
		NeedsLegacyPrefixReset := IsSet(_ResetPrefixBuffer)
	}
	return {
		Kind: "reset",
		Payload: Payload,
		PrefixCommit: PrefixCommit,
		NeedsLegacyPrefixReset: NeedsLegacyPrefixReset
	}
}

; Complete tooltip/analytics work for one committed synthetic effect. This phase
; is intentionally best-effort and always runs after the Critical send boundary.
HS_FinishSyntheticEffect(Token) {
	if !IsObject(Token)
		return
	if (Token.Kind == "neutral") {
		try LoggerDebug("HotstringBuffers", "Synthetic payload '{1}' is text-neutral — buffers untouched.", Token.Payload)
		return
	}
	if (Token.Kind == "backspace") {
		if Token.HasPreviewCommit and IsSet(_PrefixFinishBackspace)
			try _PrefixFinishBackspace(Token.BackspaceCommit)
		try LoggerDebug("HotstringBuffers", "Synthetic backspace ×{1} fed to both buffers.", Token.Repetitions)
		return
	}
	if IsObject(Token.PrefixCommit) and IsSet(_PrefixFinishInputContext) {
		try _PrefixFinishInputContext(Token.PrefixCommit)
	} else if Token.NeedsLegacyPrefixReset and IsSet(_ResetPrefixBuffer) {
		try _ResetPrefixBuffer()
	}
	try LoggerDebug("HotstringBuffers", "Synthetic payload '{1}' moved the caret — both buffers reset.", Token.Payload)
}

; Canonical declaration + OS-send owner. Both buffer mutations and the matching
; keystroke are one short Critical transaction; GUI/analytics effects run after
; the caller's previous Critical state is restored. Send exceptions are rethrown
; only after restoration so the caller can log without putting file I/O under the
; keyboard-blocking span.
; @param Payload {String} Exact Send/SendInput payload.
; @param SendFn {Func} Zero-arity function which performs the OS send.
; @return {*} The sender's return value.
HS_RunSyntheticInputTransaction(Payload, SendFn) {
	PreviousCritical := Critical("On")
	Token := 0
	SendError := 0
	Result := false
	try {
		Token := HS_CommitSyntheticEffect(Payload)
		try Result := SendFn.Call()
		catch as Err
			SendError := Err
	} finally {
		Critical(PreviousCritical)
	}
	HS_FinishSyntheticEffect(Token)
	if IsObject(SendError)
		throw SendError
	return Result
}

; Compatibility entry point for callers which only need to update the logical
; buffers (principally behavioural tests). Production senders must use
; HS_RunSyntheticInputTransaction so declaration and OS output cannot interleave.
; @param Payload {String} The exact Send/SendInput payload being modelled.
HS_DeclareSyntheticEffect(Payload) {
	PreviousCritical := Critical("On")
	try {
		Token := HS_CommitSyntheticEffect(Payload)
	} finally {
		Critical(PreviousCritical)
	}
	HS_FinishSyntheticEffect(Token)
}
