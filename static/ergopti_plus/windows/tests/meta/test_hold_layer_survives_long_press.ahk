; tests/meta/test_hold_layer_survives_long_press.ahk

; ==============================================================================
; MODULE: Regression — a held layer must survive a long press
;         (hold-layer-survives-long-press)
; DESCRIPTION:
; Hold a nav layer and navigate for more than five seconds and the layer
; vanished under the user's fingers: base-layer letters started landing in the
; document until the layer re-armed on the next press.
;
; ROOT CAUSE ENCODED: STUCK_MODIFIER_RELEASE_TIMEOUT_SEC is documented, in its
; own declaration, as a failsafe for a KeyWait that holds a SYNTHETIC MODIFIER
; Down — such a wait must never latch the modifier forever if the key-up event
; is lost to a UAC prompt or a mid-press Suspend. A hold LAYER holds no
; synthetic key at all, so it has nothing to latch; the cap was applied to it
; verbatim anyway, and its expiry ran the finally that disables the layer while
; the key was still physically down.
;
; The fix must not simply uncap the wait: an unbounded KeyWait is what
; test_hold_layer_release_bounded.ahk exists to forbid, and removing the cap
; would trade this bug for the stuck-layer bug it replaced. The wait is
; re-armed instead, so every individual wait stays bounded while the layer
; survives as long as the key is genuinely held.
;
; The guard is written over EVERY layer-hold site rather than the one that was
; reported: the same three lines are repeated across a dozen tap-hold files,
; and fixing the reported one would leave eleven identical bugs behind.
;
; SCOPE: source-level. platform/remap/*.ahk register top-level #HotIf
; hotkeys and cannot be included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ Every layer-hold wait re-arms while held ==============
; ==================================================================
; ==================================================================

_HLSL_SharedOwnerBody() {
	Src := _DriverDirConcat("infra")
	Start := InStr(Src, "TapHoldOwnImmediateLayer(")
	Assert(Start > 0, "the shared immediate layer owner must exist")
	return SubStr(Src, Start, 2400)
}

; The fix, asserted per site: the wait is re-armed in a loop, and the loop gives
; up only once the key is no longer physically down or Suspend retires it.
_HLSL_EveryLayerHoldReArms() {
	Body := _HLSL_SharedOwnerBody()
	Assert(InStr(Body, "loop {") > 0
		and InStr(Body, "WaitReleaseFn.Call(KeyName") > 0,
		"the shared layer owner must re-arm its bounded wait while the key remains held")
	Assert(InStr(Body, "KeyIsDownFn.Call(KeyName)") > 0,
		"the shared layer owner must stop re-arming when the physical key is no longer down")
	Assert(InStr(Body, "IsSuspendedFn.Call()") > 0,
		"Suspend must retire a layer owner even when its physical-down sample is stale")
	Assert(InStr(Body, "finally") > 0 and InStr(Body, "DisableFn.Call()") > 0,
		"the shared layer owner must always disable in a finally")
}

; The cap must survive. Uncapping would make the loop unnecessary and reopen
; the stuck-layer bug the cap was introduced to fix.
_HLSL_CapIsNotRemoved() {
	Body := _HLSL_SharedOwnerBody()
	Assert(InStr(Body, "WaitReleaseFn.Call(KeyName, STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)") > 0,
		"each shared release wait must stay capped — an unbounded wait reopens the stuck-layer bug")
}

; The constant itself must keep saying what it is for. Its docstring is the
; reason this misuse was identifiable at all, and the reason a future reader
; will not re-apply it to another wait that holds no synthetic key.
_HLSL_ConstantStillDocumentsItsPurpose() {
	Src := _DriverDirConcat("platform/remap")
	Assert(RegExMatch(Src, "m)^global\s+STUCK_MODIFIER_RELEASE_TIMEOUT_SEC\s*:="),
		"STUCK_MODIFIER_RELEASE_TIMEOUT_SEC must remain a named constant in the tap-holds layer")
	Assert(InStr(Src, "SYNTHETIC modifier") > 0,
		"the constant must keep documenting that it caps waits holding a SYNTHETIC modifier — that scope is precisely what makes applying it to a hold LAYER a bug, and dropping the note invites the same misuse again")
}


Test("meta hold-layer-survives-long-press: every layer-hold wait re-arms while held",
	_HLSL_EveryLayerHoldReArms)
Test("meta hold-layer-survives-long-press: the per-wait cap is not removed",
	_HLSL_CapIsNotRemoved)
Test("meta hold-layer-survives-long-press: the constant still documents its purpose",
	_HLSL_ConstantStillDocumentsItsPurpose)
