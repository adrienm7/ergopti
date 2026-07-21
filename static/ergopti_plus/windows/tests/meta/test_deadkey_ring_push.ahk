; tests/meta/test_deadkey_ring_push.ahk

; ==============================================================================
; MODULE: Regression — only characters that reach the screen advance the ring
; DESCRIPTION:
; DeadKey arms an InputHook with "L1 T2" and VisibleText at its default (off),
; then blocks in ih.Wait(). It deliberately RELEASES Critical around that wait so
; the message pump keeps running — which means the remap hotkeys stay live and a
; key pressed mid-composition still fires _RemapEmit.
;
; ROOT CAUSE ENCODED:
; _RemapEmit advanced the last-sent ring unconditionally. But the armed hook
; consumes the character that emit produces, so it never reaches the
; application; DeadKey emits the composed result instead once the hook stops.
; The ring therefore recorded a character the user never saw, and then recorded
; the composed one too — two entries for one visible character. Every consumer
; that reads the ring as "what is on screen" was off by one during and just
; after a composition: the roll handlers, the quote/hashtag guards, and the
; time-gated hotstring lookups.
;
; MEASURED, NOT INFERRED. This was filed as SUSPECTED by an audit because the
; hotkey/InputHook interaction is runtime behaviour. A probe settled it: a
; hotkey registered exactly like the remap hotkeys (InputLevel 2), an InputHook
; with DeadKey's own "L1 T2" shape, one injected key. Result — the hotkey FIRED,
; ih.Input held the character the hotkey had EMITTED (not the raw key), and the
; focused edit control received nothing at all.
;
; The gate is on the HOOK rather than on InDeadKeySequence, and that distinction
; is load-bearing: DeadKey clears _DeadKeyInputHook before emitting its own
; result but leaves the sequence flag set until afterwards, so gating on the
; flag would suppress the push for the one character that IS visible.
;
; SCOPE: source introspection of the keymap emit paths.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ Every emit path gates its ring push =======
; ======================================================
; ======================================================

; Checked as a class: both emit paths advance the ring, both fire from hotkeys
; that stay live during the wait, and both were wrong the same way.
_DKR_EmitPathsGateTheRingPush() {
	Checked := 0
	for Name in ["_RemapEmit", "_DigitShiftSend"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		if (InStr(Body, "UpdateLastSentCharacter(") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "_EmitReachedScreen()") > 0,
			Name . " must not advance the last-sent ring for a character an armed dead-key hook will consume — that hook runs with VisibleText off, so the character never reaches the application, and recording it left every ring consumer off by one for the rest of the composition")
	}
	Assert(Checked >= 2,
		"expected both keymap emit paths to be policed (found " . Checked . ")")
}

; The predicate must key off the HOOK, not the sequence flag.
_DKR_GateKeysOffTheArmedHook() {
	Body := _DriverFuncBody("_EmitReachedScreen")
	Assert(Body != "", "_EmitReachedScreen() must exist")
	Assert(InStr(Body, "_DeadKeyInputHook") > 0,
		"the gate must test whether the dead-key hook is ARMED")
	Assert(InStr(Body, "InDeadKeySequence") == 0,
		"the gate must NOT test InDeadKeySequence — DeadKey clears the hook before emitting its composed result but leaves the sequence flag set until afterwards, so gating on the flag would suppress the ring push for the one character that IS visible")
}





; =====================================================
; =====================================================
; ======= 2/ The invariants the gate depends on =======
; =====================================================
; =====================================================

; If DeadKey ever stopped clearing the hook before its own emit, the gate above
; would silently start suppressing the visible character instead.
_DKR_DeadKeyClearsHookBeforeEmitting() {
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey() must exist")

	ClearPos := InStr(Body, '_DeadKeyInputHook := ""')
	Assert(ClearPos > 0,
		"DeadKey must clear _DeadKeyInputHook once its hook is stopped")

	EmitPos := InStr(Body, "SendNewResult(", , ClearPos)
	Assert(EmitPos > ClearPos,
		"DeadKey must clear the hook BEFORE emitting its composed result — otherwise the emit gate would treat the one visible character as consumed and skip its ring push")
}

; And the release of Critical around the wait is what keeps the remap hotkeys
; live in the first place. If that ever changed, this whole interaction would
; too — pin it here so the reasoning above cannot go stale silently.
_DKR_WaitRunsWithCriticalReleased() {
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey() must exist")
	OffPos := InStr(Body, 'Critical("Off")')
	WaitPos := InStr(Body, ".Wait()")
	Assert(OffPos > 0 and WaitPos > OffPos,
		"DeadKey must release Critical before its blocking wait — that release is why remap hotkeys still fire mid-composition, which is the precondition for this whole class of ring corruption")
}


Test("meta keymap: emit paths gate the ring push on visibility", _DKR_EmitPathsGateTheRingPush)
Test("meta keymap: the visibility gate keys off the armed hook", _DKR_GateKeysOffTheArmedHook)
Test("meta keymap: DeadKey clears its hook before emitting", _DKR_DeadKeyClearsHookBeforeEmitting)
Test("meta keymap: the dead-key wait runs with Critical released", _DKR_WaitRunsWithCriticalReleased)
