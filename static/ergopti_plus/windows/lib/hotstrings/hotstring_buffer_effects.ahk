; lib/hotstrings/hotstring_buffer_effects.ahk

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
; to bypass all eight existing reset sites. Matched as a prefix of the payload's
; key token, so the repetition suffix ("{Volume_Up 3}") is covered.
global HS_BUFFER_NEUTRAL_PAYLOADS := ["{Volume_Up", "{Volume_Down", "{Volume_Mute"]

; A "{BackSpace}" / "{BackSpace N}" payload and nothing else — the only shape
; whose effect on the buffers is exactly known. Anchored so a payload that also
; moves the caret ("{End}{BackSpace 2}") falls through to the reset branch
; instead of being mistaken for a plain deletion.
global HS_BUFFER_BACKSPACE_PAYLOAD := "i)^\{BackSpace(?:\s+(\d+))?\}$"





; =================================================================
; ================================================================
; ======= 1/ Declaring the effect of a synthetic keystroke =======
; ================================================================
; =================================================================

; Tell both hotstring buffers what a synthetic keystroke payload is about to do.
; Call this BEFORE the send: if the send throws, the buffers have already been
; invalidated, which is the safe direction — a lost tooltip preview costs the
; user a suggestion, a stale buffer costs them the characters an expansion
; backspaces over.
;
; @param Payload string The exact Send/SendInput payload about to be emitted.
HS_DeclareSyntheticEffect(Payload) {
	global HS_BUFFER_NEUTRAL_PAYLOADS, HS_BUFFER_BACKSPACE_PAYLOAD

	for Neutral in HS_BUFFER_NEUTRAL_PAYLOADS {
		if InStr(Payload, Neutral) {
			try LoggerDebug("HotstringBuffers", "Synthetic payload '{1}' is text-neutral — buffers untouched.", Payload)
			return
		}
	}

	if RegExMatch(Payload, HS_BUFFER_BACKSPACE_PAYLOAD, &BsMatch) {
		Reps := (BsMatch[1] != "") ? BsMatch[1] + 0 : 1
		loop Reps {
			; IsPhysical := true — this deletion really happened on screen, so it
			; must apply even inside a suppress window, exactly like the watcher's
			; physical VK_BACK branch.
			if IsSet(HSE_FeedBackspace)
				HSE_FeedBackspace(true)
			if IsSet(_PrefixFeedBackspace)
				try _PrefixFeedBackspace()
		}
		try LoggerDebug("HotstringBuffers", "Synthetic backspace ×{1} fed to both buffers.", Reps)
		return
	}

	; Everything else moves the caret, changes focus, or rewrites the line. What
	; sits left of the caret is now unknown, so the next typed run must start
	; fresh — the same verdict the watcher reaches for a physical arrow key.
	; KnownTerminatorBefore := true because the cursor lands at a position the
	; next run may legitimately treat as a word start.
	if IsSet(HSE_FeedReset)
		HSE_FeedReset(true, true)
	if IsSet(_ResetPrefixBuffer)
		try _ResetPrefixBuffer()
	try LoggerDebug("HotstringBuffers", "Synthetic payload '{1}' moved the caret — both buffers reset.", Payload)
}
