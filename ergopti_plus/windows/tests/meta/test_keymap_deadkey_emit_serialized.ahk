; tests/meta/test_keymap_deadkey_emit_serialized.ahk

; ==============================================================================
; MODULE: Regression — every dead-key emit serializes, on every layer
; DESCRIPTION:
; The dead-key keys (SC01B, SC02B) carry the same callback on two layers. On the
; CapsLock layer it is dispatched through LayerDispatch with SerializeSymbols
; true, which wraps it in Critical and restores the caller's level in a finally.
; On the base layer the very same lambda was handed straight to Hotkey() and got
; no serialization at all.
;
; ROOT CAUSE ENCODED:
; SendMode is "Event" driver-wide, so every emit is a non-atomic, interruptible
; SendEvent into one shared OS input queue. Critical is what stops AHK starting
; the NEXT key's remap before this one has drained — that is the entire reason
; _RemapEmit, _DigitShiftSend and LayerDispatch all take it. The chained
; dead-key branch emits too, so an unserialized emit there can interleave with a
; neighbouring remapped key and the two characters come out transposed.
;
; The asymmetry is the finding: identical callback, protected on one layer and
; not the other. That is the invariant-applied-per-site shape this codebase
; keeps hitting, so this guard checks the CLASS — every emit path in the
; keymap layer — rather than the one registration that was wrong.
;
; Why no behavioural test: transposition needs two physical keys racing inside
; the OS input queue, which the suite cannot stage. The invariant is structural,
; so it is asserted structurally.
;
; SCOPE: source introspection of the keymap layer.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ No emit path is registered unserialized =======
; ==========================================================
; ==========================================================

; The exact defect: a callback that emits, handed to Hotkey() as a bare lambda
; so nothing wraps it. Pinned by shape rather than by scancode so re-registering
; the same mistake on another key fails here too.
_DKE_NoInlineEmitLambdaIsRegistered() {
	Src := _DriverDirConcat("modules/keymap")
	Assert(Src != "", "the keymap source must be readable")
	Assert(InStr(Src, "(*) => (InDeadKeySequence ? SendNewResult") == 0,
		"a dead-key callback must not be registered as a bare lambda on Hotkey() — SendMode is Event driver-wide, so an unserialized emit can interleave with a neighbouring remapped key's SendEvent in the OS input queue and the two characters come out transposed. Route it through a named dispatcher that takes Critical, the way the CapsLock layer already does.")
}

; And the positive form, so deleting the lambda is not enough — the replacement
; must actually serialize, and must restore the caller's level rather than
; leaving Critical latched on.
_DKE_DeadKeyDispatcherSerializes() {
	Body := _DriverFuncBody("_DeadKeyDispatch")
	Assert(Body != "", "_DeadKeyDispatch() must exist as the base-layer dead-key entry point")
	Assert(InStr(Body, 'Critical("On")') > 0,
		"_DeadKeyDispatch must take Critical — its chained-sequence branch emits, and every other emit in this layer serializes")
	Assert(InStr(Body, "finally") > 0,
		"_DeadKeyDispatch must restore the caller's Critical level in a finally — latching it on would make the next Sleep-free path uninterruptible for good")
	Assert(InStr(Body, "SendNewResult(") > 0 and InStr(Body, "DeadKey(") > 0,
		"_DeadKeyDispatch must still route both branches: the bare character while a sequence is open, the state machine otherwise")
}





; ============================================================
; ============================================================
; ======= 2/ The class of emit paths, checked together =======
; ============================================================
; ============================================================

; Every function in this layer whose job is to emit. They were written at
; different times and drifted apart once already; checked as a set so the next
; one added is either serialized or fails here.
_DKE_EveryEmitPathTakesCritical() {
	Checked := 0
	for Name in ["_RemapEmit", "_DigitShiftSend", "_DeadKeyDispatch", "LayerDispatch"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist")
		Checked += 1
		Assert(InStr(Body, "Critical(") > 0,
			Name . " emits into the shared OS input queue and must serialize — without it AHK can start the next key's remap before this SendEvent has drained, which reorders the output")
	}
	Assert(Checked >= 4,
		"expected all four keymap emit paths to be policed (found " . Checked . ") — if one was renamed, rename it here rather than letting it fall out of the class")
}

; DeadKey itself must keep doing the opposite: its blocking wait must NOT run
; under Critical, or every dead-key press stalls the whole message pump for up
; to the InputHook timeout. The dispatcher above hands it Critical, so this
; release is now load-bearing for both layers rather than just the CapsLock one.
_DKE_DeadKeyReleasesCriticalAroundItsWait() {
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey() must exist")

	OffPos := InStr(Body, 'Critical("Off")')
	WaitPos := InStr(Body, ".Wait()")
	Assert(OffPos > 0 and WaitPos > 0,
		"DeadKey must arm an InputHook and wait on it")
	Assert(OffPos < WaitPos,
		"DeadKey must release Critical BEFORE its blocking wait — running a message-pumping wait under Critical stalls every hotkey and timer in the process for the InputHook's full timeout")
	Assert(InStr(Body, "finally") > 0,
		"DeadKey must restore the caller's Critical level in a finally, so the composed emit after the wait still serializes as the caller intended")
}


Test("meta keymap: no dead-key emit is registered as a bare lambda", _DKE_NoInlineEmitLambdaIsRegistered)
Test("meta keymap: the dead-key dispatcher serializes and restores", _DKE_DeadKeyDispatcherSerializes)
Test("meta keymap: every emit path in the layer takes Critical", _DKE_EveryEmitPathTakesCritical)
Test("meta keymap: DeadKey still releases Critical around its wait", _DKE_DeadKeyReleasesCriticalAroundItsWait)
