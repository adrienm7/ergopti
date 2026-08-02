; tests/meta/test_lalt_capslock_tap_min_duration.ahk

; ==============================================================================
; MODULE: Tap-Hold Min-Duration Floor Meta Test
; DESCRIPTION:
; Static source guard for the finding
; lalt-altgr-capslock-no-priorkey-min-duration.
;
; The shift/ctrl tap-hold handlers (rshift.ahk, lshift_lctrl.ahk) gate the tap
; action on BOTH an upper bound (<= TapHoldDuration) and a lower bound
; (>= TapMinDurationMs()) plus an A_PriorKey match. The layer-based handlers
; for CapsLock (capslock.ahk 2.4) and LAlt (lalt.ahk 4.2 tab+layer, 4.8 generic
; hold-layer) previously gated on the upper bound only, so an ultra-fast chord
; brush — under the tap duration but also under the min-duration floor — was
; counted as an intentional tap and fired a spurious action (extra Enter /
; BackSpace / char) mid-word.
;
; The fix applies the same guards uniformly:
;   - capslock.ahk 2.4: add `>= TapMinDurationMs()` floor AND
;     `A_PriorKey == "CapsLock"`.
;   - lalt.ahk 4.2 / 4.8: add `>= TapMinDurationMs()` floor.
;
; This is a meta-static test (scans source text) because capslock.ahk and
; lalt.ahk register top-level hotkeys and are NOT in the run_all.ahk include
; graph — #Including them would be a load-time failure that hangs the headless
; runner. If any handler loses its TapMinDurationMs() floor, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_TMDF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the body of a single #HotIf hotkey block starting at the given hotkey
; declaration. Slices from the declaration to the first flush-left "#HotIf" that
; closes the block, so each variant's tap guard is asserted in isolation.
_TMDF_BlockBody(Src, HotkeyDef) {
	Idx := InStr(Src, HotkeyDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n#HotIf")
	if End
		return SubStr(Rest, 1, End)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Min-duration floor assertions =========
; ==================================================
; ==================================================

; CapsLock hold-layer (2.4): must gate on TapMinDurationMs() AND A_PriorKey.
_TMDF_CapsLockLayerHasFloorAndPriorKey() {
	; Move-resilient: scan the whole tap_holds module instead of a pinned path.
	; The "`n$SC03A:: {" anchor is unique to capslock.ahk in this dir.
	Src := _DriverDirConcat("platform/remap")
	; Newline-anchor the declaration so it matches the flush-left 2.4 hold-layer
	; block ($SC03A) and NOT the 2.3 hold-modifier block (*$SC03A) which shares
	; the trailing "$SC03A:: {" substring.
	Seg := _TMDF_BlockBody(Src, "`n$SC03A:: {")
	Assert(Seg != "", "capslock.ahk hold-layer block ($SC03A) must exist")
	Assert(InStr(Seg, "TapMinDurationMs()") > 0,
		"capslock.ahk 2.4 must apply the >= TapMinDurationMs() lower bound so an ultra-fast chord brush is not counted as an intentional tap")
	Assert(InStr(Seg, "A_PriorKey == " . Chr(34) . "CapsLock" . Chr(34)) > 0,
		"capslock.ahk 2.4 must gate the tap on A_PriorKey == CapsLock so a layer key used mid-chord does not fire the tap action")
}
Test("tap_holds: capslock 2.4 hold-layer has TapMinDurationMs floor + A_PriorKey guard (lalt-altgr-capslock-no-priorkey-min-duration)", _TMDF_CapsLockLayerHasFloorAndPriorKey)

; LAlt tab+layer (4.2): must gate on TapMinDurationMs().
_TMDF_LAltTabLayerHasFloor() {
	Src := _TMDF_ReadSource("platform/remap/lalt.ahk")
	; Anchor on the unique 4.2 #HotIf directive (tap == "tab") so the slice starts
	; at the top of the block and captures the tap-resolution lines (the
	; TapMinDurationMs floor sits just above the LLM_Tooltip_FireTabOrAccept call).
	Seg := _TMDF_BlockBody(Src, "#HotIf TapHoldTapAction(TapHold, " . Chr(34) . "left_alt" . Chr(34) . ") == " . Chr(34) . "tab" . Chr(34))
	Assert(Seg != "", "lalt.ahk tab+layer block (4.2) must exist")
	Assert(InStr(Seg, "LLM_Tooltip_FireTabOrAccept") > 0,
		"lalt.ahk 4.2 slice must reach the tab+layer dispatch")
	Assert(InStr(Seg, "TapMinDurationMs()") > 0,
		"lalt.ahk 4.2 (tab+layer) must apply the >= TapMinDurationMs() lower bound to suppress spurious taps on a fast brush")
}
Test("tap_holds: lalt 4.2 tab+layer has TapMinDurationMs floor (lalt-altgr-capslock-no-priorkey-min-duration)", _TMDF_LAltTabLayerHasFloor)

; LAlt generic hold-layer (4.8): must gate on TapMinDurationMs() AND A_PriorKey.
_TMDF_LAltGenericLayerHasFloor() {
	; Move-resilient: scan the whole tap_holds module instead of a pinned path.
	; The A_PriorKey == "LAlt") { anchor is unique to lalt.ahk in this dir, and the
	; TapMinDurationMs() floor sits on the same line just before it.
	Src := _DriverDirConcat("platform/remap")
	; The generic hold-layer dispatch is the only call to _LAltDispatch() guarded
	; by A_PriorKey == "LAlt"; isolate that statement and assert the floor is present.
	Idx := InStr(Src, "A_PriorKey == " . Chr(34) . "LAlt" . Chr(34) . ") {")
	Assert(Idx > 0, "lalt.ahk 4.8 generic hold-layer dispatch guard must exist")
	Seg := SubStr(Src, Idx - 200, 260)
	Assert(InStr(Seg, "TapMinDurationMs()") > 0,
		"lalt.ahk 4.8 (generic hold-layer) must apply the >= TapMinDurationMs() lower bound alongside the A_PriorKey == LAlt guard")
}
Test("tap_holds: lalt 4.8 generic hold-layer has TapMinDurationMs floor (lalt-altgr-capslock-no-priorkey-min-duration)", _TMDF_LAltGenericLayerHasFloor)
