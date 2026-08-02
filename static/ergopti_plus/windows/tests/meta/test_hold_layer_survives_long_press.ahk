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

; A layer-hold wait is a capped KeyWait whose failure path disables a layer.
; Returns one record per site: the wait line and the few lines that follow it,
; which is where both the re-arm and the DisableLayer live.
_HLSL_LayerHoldSites() {
	Sites := []
	Src := _DriverDirConcat("platform/remap")
	Lines := StrSplit(_StripFullLineComments(Src), "`n", "`r")
	for Idx, Line in Lines {
		if !InStr(Line, "KeyWait(")
			continue
		if !InStr(Line, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC")
			continue
		; Look ahead for the DisableLayer that makes this a LAYER hold rather
		; than a synthetic-modifier hold (which legitimately keeps the plain cap).
		Window := ""
		Loop 6 {
			Ahead := Idx + A_Index - 1
			if (Ahead <= Lines.Length)
				Window .= Lines[Ahead] . "`n"
		}
		if !InStr(Window, "DisableLayer()")
			continue
		Sites.Push({ Wait: Trim(Line, " `t"), Window: Window })
	}
	return Sites
}

; The fix, asserted per site: the wait is re-armed in a loop, and the loop only
; gives up once the key is no longer physically down.
_HLSL_EveryLayerHoldReArms() {
	Sites := _HLSL_LayerHoldSites()
	; Non-vacuity floor: a dozen tap-hold files carry this shape. A scan that
	; matched nothing would pass every assertion below.
	Assert(Sites.Length >= 8,
		"the scan must reach the real layer-hold waits (found only " . Sites.Length . ") — a scan that matches nothing cannot fail")

	for Site in Sites {
		Assert(RegExMatch(Site.Wait, "i)^while\s*!\s*KeyWait\("),
			"a layer-hold wait must be re-armed while the key is still held, not run once: '" . Site.Wait . "'. Run once, its cap expires after five seconds of legitimate navigation and the finally disables the layer under the user's fingers")
		Assert(InStr(Site.Window, "GetKeyState") > 0,
			"the re-armed wait must stop on the physical key state — without that check the loop never ends and the cap's real purpose (releasing after a genuinely lost key-up) is defeated: '" . Site.Wait . "'")
		Assert(InStr(Site.Window, '"P"') > 0,
			"the key-state probe must read the PHYSICAL state, not the logical one: the logical state is exactly what a lost key-up event corrupts, so a logical probe would loop forever: '" . Site.Wait . "'")
	}
}

; The cap must survive. Uncapping would make the loop unnecessary and reopen
; the stuck-layer bug the cap was introduced to fix.
_HLSL_CapIsNotRemoved() {
	Sites := _HLSL_LayerHoldSites()
	for Site in Sites
		Assert(InStr(Site.Wait, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
			"each individual wait must stay capped — an unbounded KeyWait trades this bug for the stuck-layer bug the cap exists to prevent: '" . Site.Wait . "'")
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
