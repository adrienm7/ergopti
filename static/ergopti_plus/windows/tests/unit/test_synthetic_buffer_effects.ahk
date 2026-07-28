; static/ergopti_plus/windows/tests/unit/test_synthetic_buffer_effects.ahk

; ==============================================================================
; MODULE: Regression — synthetic navigation must invalidate both hotstring
;         buffers (synthetic-buffer-effects)
; DESCRIPTION:
; Hold the Space nav layer, tap the Up-arrow layer key, release, then press the
; magic key: the expansion fired with its {BackSpace N} at the NEW cursor
; position and deleted characters of the line above.
;
; ROOT CAUSE ENCODED: HSE_Buffer and _PrefixBuffer both answer "what sits
; immediately left of the caret?", and every expansion backspaces over exactly
; that many characters. Eight sites reset them when the caret moves — but all
; eight hang off the prefix watcher's InputHook, which runs at input level I1
; and therefore CANNOT see the nav layer's own SendInput (SendLevel 0). The
; layer moved the caret through a channel that structurally bypassed every
; existing reset, so nothing was missing at any of those eight sites and no
; amount of hardening there would have helped. The caller has to declare.
;
; The class assertion below is the important one: it re-derives the payload of
; EVERY ActionLayer key from nav_layer.ahk's own source and requires each to be
; classified correctly. A new layer key added later is covered the day it is
; written, which is the failure mode this driver keeps hitting — the one missed
; sibling site.
;
; SCOPE: behavioural for the classifier and for every real layer payload;
; positional for the ActionLayer wiring, because ActionLayer's own SendInput is
; a live OS call in this runner and must not be fired at a real desktop.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The classifier's three verdicts =======================
; ==================================================================
; ==================================================================

; Set both buffers to a known state, declare a payload, and report what the
; engine buffer became. The preview buffer is not asserted here: the tooltip
; watcher is not part of this runner's include graph, so _PrefixBuffer does not
; exist and HS_DeclareSyntheticEffect's IsSet guards skip it. Section 3 covers
; that half positionally.
_SBE_FeedFrom(Start, Payload) {
	global HSE_Buffer, HSE_Suppressed
	HSE_Suppressed := 0
	HSE_Buffer := Start
	HS_DeclareSyntheticEffect(Payload)
	return HSE_Buffer
}

; The audit's own repro, reduced: the tooltip offers an expansion for "att",
; the user deletes one character through the layer, and the engine must now
; believe the buffer is "at". Tracking the deletion precisely (rather than
; resetting) is deliberate — after fixing a typo the user is usually back on a
; live trigger and that suggestion should reappear.
_SBE_BackspaceShrinksBuffer() {
	AssertEqual("at", _SBE_FeedFrom("att", "{BackSpace}"),
		"a layer backspace must shrink the engine buffer by one, exactly as the physical VK_BACK branch does")
	AssertEqual("a", _SBE_FeedFrom("att", "{BackSpace 2}"),
		"a repeated layer backspace must shrink the buffer once per repetition — the layer's repetition count is applied by the OS, so feeding it once leaves the buffer one or more characters ahead of the screen")
	AssertEqual("", _SBE_FeedFrom("att", "{BackSpace 9}"),
		"deleting past the start of the buffer must empty it, never underflow")
}

; Every caret-moving payload lands the cursor somewhere the buffers cannot
; describe. The next typed run has to start fresh, which is the same verdict the
; watcher already reaches for a physical arrow key.
_SBE_CaretMoveResetsBuffer() {
	for Payload in ["{Up 1}", "{Down 3}", "{Home}", "{End}", "^{Home}", "^+{End}",
		"!{Up 2}", "{End}{Enter 1}", "{Escape 1}", "+{Left 4}", "{F2}"] {
		AssertEqual("", _SBE_FeedFrom("att", Payload),
			"payload '" . Payload . "' moves the caret or the focus, so the engine buffer must be invalidated — leaving it makes the next expansion backspace over text it never saw")
	}
}

; The allowlist must be real: if everything reset, the layer would destroy a
; live preview on a volume tap and the guard would be indistinguishable from
; wiping the buffer on every layer key.
_SBE_NeutralPayloadIsPreserved() {
	AssertEqual("att", _SBE_FeedFrom("att", "{Volume_Up 1}"),
		"a volume payload touches neither the caret nor the document, so it must leave both buffers alone")
	AssertEqual("att", _SBE_FeedFrom("att", "{Volume_Down 2}"),
		"a volume payload touches neither the caret nor the document, so it must leave both buffers alone")
}

; A payload that deletes AND moves must not be mistaken for a plain deletion —
; the backspace branch is anchored precisely so it cannot swallow one.
_SBE_MixedPayloadIsTreatedAsAMove() {
	AssertEqual("", _SBE_FeedFrom("att", "{End}{BackSpace 2}"),
		"a payload that also moves the caret must fall through to the reset branch — feeding it as two backspaces would leave the buffer describing a position the caret has left")
}





; ==================================================================
; ===================================================================
; ======= 2/ Every real layer payload, enumerated from source =======
; ===================================================================
; ==================================================================

; Rebuild the payload of each ActionLayer key from nav_layer.ahk. The real call
; sites concatenate a repetition count onto a literal prefix
; (``ActionLayer("{Up " . AppState_GetNumberOfRepetitions() . "}")``), so a
; literal ending in a space is closed with a concrete count here.
_SBE_LayerPayloads() {
	Src := _DriverSourceNoComments()
	Payloads := []
	Pos := 1
	while (FoundPos := RegExMatch(Src, 'ActionLayer\("([^"]*)"', &M, Pos)) {
		Pos := FoundPos + M.Len
		Literal := M[1]
		if (Literal == "")
			continue
		if (SubStr(Literal, -1) == " ")
			Literal .= "2}"
		Payloads.Push(Literal)
	}
	return Payloads
}

; The whole-class guard. Every layer key must land in one of the two safe
; verdicts; a payload that leaves a stale buffer behind is the bug itself.
_SBE_EveryLayerPayloadIsClassified() {
	Payloads := _SBE_LayerPayloads()
	; Non-vacuity floor: the nav layer binds well over twenty keys. A regex that
	; silently stopped matching would otherwise make this test unable to fail.
	Assert(Payloads.Length >= 20,
		"the scan must reach the real nav-layer bindings (found only " . Payloads.Length . ") — a scan that matches nothing passes every assertion below")

	for Payload in Payloads {
		Result := _SBE_FeedFrom("att", Payload)
		IsNeutral := false
		for Token in HS_BUFFER_NEUTRAL_PAYLOADS {
			if InStr(Payload, Token)
				IsNeutral := true
		}
		if (IsNeutral) {
			AssertEqual("att", Result,
				"layer payload '" . Payload . "' is on the text-neutral allowlist, so it must leave the buffer intact")
		} else if RegExMatch(Payload, HS_BUFFER_BACKSPACE_PAYLOAD, &BsM) {
			Reps := (BsM[1] != "") ? BsM[1] + 0 : 1
			AssertEqual(SubStr("att", 1, Max(0, 3 - Reps)), Result,
				"layer payload '" . Payload . "' is a pure deletion, so the buffer must shrink by exactly its repetition count rather than reset")
		} else {
			AssertEqual("", Result,
				"layer payload '" . Payload . "' is neither text-neutral nor a pure deletion, so it must invalidate the buffer — this is the one-missed-sibling shape: a new layer key that moves the caret and says nothing")
		}
	}
}





; ==================================================================
; ===================================================================
; ======= 3/ The declaration is actually wired to the senders =======
; ===================================================================
; ==================================================================

; ActionLayer's SendInput is a live OS call here, so the wiring is asserted on
; the source instead of by firing it at whatever window has focus. The ordering
; matters: declaring AFTER the send leaves a window in which a hotstring thread
; can fire against a buffer that already describes the wrong caret position.
_SBE_ActionLayerDeclaresBeforeSending() {
	Body := _DriverFuncBody("ActionLayer")
	Assert(Body != "", "ActionLayer() must exist in the driver source")

	DeclarePos := InStr(Body, "HS_DeclareSyntheticEffect")
	SendPos    := InStr(Body, "SendInput")
	Assert(DeclarePos > 0,
		"ActionLayer must declare its effect on the hotstring buffers — its SendInput runs at SendLevel 0 and is filtered out by the prefix watcher's own input level, so no existing reset site can ever observe it")
	Assert(SendPos > 0, "ActionLayer must still perform the send")
	Assert(DeclarePos < SendPos,
		"the declaration must come BEFORE the send, so no thread can observe a buffer that still describes the old caret position")
}

; The two Win-shortcut siblings named in the same finding. They reach the caret
; through SendFinalResult rather than ActionLayer, so the ActionLayer wiring
; above does not cover them.
_SBE_WinCaretShortcutsDeclare() {
	for FuncName in ["SelectLine", "SurroundLineWithParentheses"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")
		Assert(InStr(Body, "{Home}") > 0,
			FuncName . " must still be the caret-moving shortcut this guard was written for")
		DeclarePos := InStr(Body, "HS_DeclareSyntheticEffect")
		SendPos    := InStr(Body, "SendFinalResult")
		Assert(DeclarePos > 0,
			FuncName . " sends synthetic Home/End, which the prefix watcher cannot see — it must declare the caret move or the next expansion backspaces over the line it just selected")
		Assert(DeclarePos < SendPos, "the declaration must come BEFORE the send in " . FuncName)
	}
}


Test("synthetic-buffer-effects: a layer backspace shrinks the engine buffer",
	_SBE_BackspaceShrinksBuffer)
Test("synthetic-buffer-effects: a caret move invalidates the engine buffer",
	_SBE_CaretMoveResetsBuffer)
Test("synthetic-buffer-effects: a text-neutral payload preserves the buffer",
	_SBE_NeutralPayloadIsPreserved)
Test("synthetic-buffer-effects: a payload that moves and deletes is treated as a move",
	_SBE_MixedPayloadIsTreatedAsAMove)
Test("synthetic-buffer-effects: every nav-layer payload in source is classified",
	_SBE_EveryLayerPayloadIsClassified)
Test("synthetic-buffer-effects: ActionLayer declares before it sends",
	_SBE_ActionLayerDeclaresBeforeSending)
Test("synthetic-buffer-effects: the Win caret shortcuts declare before they send",
	_SBE_WinCaretShortcutsDeclare)
