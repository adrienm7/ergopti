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
; is load-bearing: DeadKey unregisters its exact shared-owner token before
; emitting its own result but leaves the sequence flag set until afterwards,
; so gating on the flag would suppress the push for the one character that IS
; visible.
;
; SCOPE: source introspection of the keymap emit paths.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ Every emit path gates its ring push =======
; ======================================================
; ======================================================

; Checked as a class: every emit path advances the ring, all of them fire from
; hotkeys that stay live during the wait, and all of them were wrong the same
; way. _RemapEmit and _DigitShiftSend were fixed first; _DigitRowDown sat ten
; lines above the second of those and was missed, and SendNewResult — the
; primitive every Shift/CapsLock/AltGr layer emit goes through — was missed
; entirely, which is the path composition plus a Shift capital actually takes.
_DKR_EmitPathsGateTheRingPush() {
	Checked := 0
	for Name in ["_RemapEmit", "_DigitShiftSend", "_DigitRowDown", "SendNewResult"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		if (InStr(Body, "UpdateLastSentCharacter(") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "_EmitReachedScreen()") > 0,
			Name . " must not advance the last-sent ring for a character an armed dead-key hook will consume — that hook runs with VisibleText off, so the character never reaches the application, and recording it left every ring consumer off by one for the rest of the composition")
	}
	Assert(Checked >= 4,
		"expected every keymap emit path to be policed (found " . Checked . ")")
}

; True when a ring record is reachable on the SAME straight-line path as a
; preceding SendNewResult. Branch-aware on purpose: a record that sits on the
; other side of an `else` (WrapTextIfSelected's SendInstant success path, where
; nothing recorded it because SendInstant does not) is legitimate, and a check
; that merely looked for a record anywhere after the send would forbid it.
; Scanning stops at the first return, else, or dedent — the points at which the
; record is provably no longer on the send's path.
_DKR_RecordsAfterSendInSameBranch(Body) {
	Lines := StrSplit(Body, "`n", "`r")
	for Idx, Line in Lines {
		if !InStr(Line, "SendNewResult(")
			continue
		SendDepth := StrLen(Line) - StrLen(LTrim(Line, " `t"))
		Cursor := Idx + 1
		while (Cursor <= Lines.Length) {
			Next := Lines[Cursor]
			Trimmed := Trim(Next, " `t")
			Cursor += 1
			if (Trimmed == "" or SubStr(Trimmed, 1, 1) == ";")
				continue
			Depth := StrLen(Next) - StrLen(LTrim(Next, " `t"))
			; Left the send's block, or the path ended.
			if (Depth < SendDepth)
				break
			if RegExMatch(Trimmed, "i)^(return\b|else\b|\})")
				break
			if InStr(Trimmed, "UpdateLastSentCharacter(")
				return true
		}
	}
	return false
}

; No emit path may push the ring twice for one visible character. SendNewResult
; records what it sent, so a caller that also records pushes the same character
; again — and a doubled entry shifts every GetLastSentCharacterAt(-N) lookup by
; one, which is exactly what the roll handlers and the quote guards read.
_DKR_NoCallerDoublePushesAfterSendNewResult() {
	for Name in ["_RollEmitCritical", "WrapTextIfSelected"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		if (InStr(Body, "SendNewResult(") == 0)
			continue
		Assert(!_DKR_RecordsAfterSendInSameBranch(Body),
			Name . " records the ring again after SendNewResult on the SAME path, and SendNewResult already recorded the character it sent. One visible character then occupies two ring slots and every GetLastSentCharacterAt(-N) lookup is off by one")
	}
}

; The predicate must key off the HOOKS, not the sequence flag — and on ALL of
; them. Three suppressive L1 hooks exist and they consume an emitted character
; identically; gating on only the dead-key one left the other two desyncing the
; ring in exactly the way this whole test file exists to prevent.
_DKR_GateKeysOffTheArmedHook() {
	Body := _DriverFuncBody("_EmitReachedScreen")
	Assert(Body != "", "_EmitReachedScreen() must exist")
	Assert(InStr(Body, "_EMIT_SUPPRESSING_HOOKS") > 0,
		"the gate must consult the enumerated set of suppressing hooks rather than naming one inline, so a fourth hook is added next to its siblings instead of silently bypassing the gate")
	Assert(InStr(Body, "SIHO_HasActive()") > 0,
		"the gate must include every concurrently owned suppressive hook")
	Assert(InStr(Body, "InDeadKeySequence") == 0,
		"the gate must NOT test InDeadKeySequence — DeadKey clears the hook before emitting its composed result but leaves the sequence flag set until afterwards, so gating on the flag would suppress the ring push for the one character that IS visible")
}

; Every suppressive InputHook in the driver must be in the gate's set. This is
; the assertion that makes the class closed: a new "L1"-armed hook added in some
; other module would otherwise reintroduce the same desync with nothing failing.
_DKR_EverySuppressingHookIsGated() {
	Src := _DriverSourceNoComments()
	if !RegExMatch(Src, "m)^global\s+_EMIT_SUPPRESSING_HOOKS\s*:=\s*\[([^\]]*)\]", &Decl)
		Assert(false, "_EMIT_SUPPRESSING_HOOKS must be declared as a module-level array")
	if !RegExMatch(Src, "m)^global\s+_EMIT_NONSUPPRESSING_HOOKS\s*:=\s*\[([^\]]*)\]", &Exempt)
		Assert(false, "_EMIT_NONSUPPRESSING_HOOKS must be declared alongside it, so a hook that genuinely does not suppress is recorded as triaged rather than merely absent")
	; Both sets together: a hook must be classified, and the exemption list is
	; where the reason for not gating lives.
	Listed := Decl[1] . "," . Exempt[1]

	; Every global whose name ends in InputHook is a candidate: that suffix is
	; the driver's own convention for a live, armed capture hook.
	Found := Map()
	Pos := 1
	while (P := RegExMatch(Src, "m)^global\s+(_\w*InputHook)\s*:=", &G, Pos)) {
		Pos := P + G.Len
		Found[G[1]] := true
	}
	Count := 0
	for _, _ in Found
		Count++
	Assert(Count >= 3,
		"the scan must find the driver's capture hooks (found only " . Count . ") — a scan that matches nothing cannot fail")

	for Name, _ in Found
		Assert(InStr(Listed, Name) > 0,
			"'" . Name . "' is an armed capture hook and appears in NEITHER _EMIT_SUPPRESSING_HOOKS nor _EMIT_NONSUPPRESSING_HOOKS. Decide which it is: a hook armed without VisibleText consumes the character an emit just produced, so the ring records something that never reached the screen and every consumer reading it as 'what is on screen' goes off by one. A hook armed with V observes instead and belongs in the exemption list with that reason")
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

	ClearPos := InStr(Body, "SIHO_StopOwned(")
	Assert(ClearPos > 0,
		"DeadKey must stop and unregister its exact owner transactionally")

	EmitPos := InStr(Body, "SendNewResult(", , ClearPos)
	Assert(EmitPos > ClearPos,
		"DeadKey must settle the hook BEFORE emitting its composed result — otherwise the emit gate would treat the one visible character as consumed and skip its ring push")
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
Test("meta keymap: no caller double-pushes the ring after SendNewResult",
	_DKR_NoCallerDoublePushesAfterSendNewResult)
Test("meta keymap: every armed capture hook is in the visibility gate",
	_DKR_EverySuppressingHookIsGated)
Test("meta keymap: DeadKey clears its hook before emitting", _DKR_DeadKeyClearsHookBeforeEmitting)
Test("meta keymap: the dead-key wait runs with Critical released", _DKR_WaitRunsWithCriticalReleased)
