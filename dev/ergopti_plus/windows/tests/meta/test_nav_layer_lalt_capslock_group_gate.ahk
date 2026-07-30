; tests/meta/test_nav_layer_lalt_capslock_group_gate.ahk

; ==============================================================================
; MODULE: Nav-layer LAlt+CapsLock rescue gates on the whole action group
; DESCRIPTION:
; While the navigation layer is engaged by holding LAlt (the shipped default:
; defaults.toml puts left_alt on hold_layer = "nav"), pressing CapsLock must
; still reach LAltCapsLockShortcut(). nav_layer.ahk arms a rescue SC03A variant
; for exactly that, but it re-implemented the "is any action of this group
; enabled?" test as a hand-written disjunction of action ids — and that list had
; drifted to 7 of the 10 ids the feature manifest declares. With "enter",
; "escape" or "tab" selected the criterion was false, the rescue variant never
; armed, and the layer's own SC03A mapping took the press: the chord DELETED a
; character instead of emitting the chosen action. Silent, because the default
; action (caps_word) is inside the 7.
;
; ROOT CAUSE ENCODED: a hand-maintained enumeration of feature ids drifts from
; the manifest. The canonical single source, _AnyShortcutEnabled(Group), already
; iterates the sub-map and is what the sibling gate (SC038 & SC03A in
; modules/shortcuts/base_modifier.ahk) uses — the same question asked twice.
; Pinned here as a class invariant over modules/tap_holds: no gate in that tree
; may answer it by naming ids, so an 11th action is covered automatically.
;
; SCOPE: meta-static. The gate is a #HotIf criterion, which the headless runner
; never evaluates (it does not load the hotkey-registering modules), so the
; guarantee is asserted against the driver source through the move-resilient
; _DriverDirConcat / _DriverFuncBody helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Source and manifest extraction =======
; =================================================
; =================================================

; Reads the lalt_caps_lock action ids straight from the shared feature manifest
; so a newly declared action joins this test automatically instead of having to
; be remembered here.
_NLGG_ManifestActionIds() {
	; A_ScriptDir is run_all.ahk's directory (tests/), NOT this file's — every test
	; is #Include-d into the runner. Climbing from it lands one level too high and
	; the read fails with "path not found". _SharedDir is the harness's own resolved
	; root and moves with the tree, so use it rather than re-deriving the path here.
	global _SharedDir
	Toml := FileRead(_SharedDir . "\modules\features\manifest.toml", "UTF-8")
	Ids := []
	InSection := false
	for Line in StrSplit(Toml, "`n", "`r") {
		Trimmed := Trim(Line, " `t")
		if (SubStr(Trimmed, 1, 1) == "[") {
			InSection := (Trimmed == "[[features.ahk.shortcuts.lalt_caps_lock]]")
			continue
		}
		if !InSection
			continue
		if RegExMatch(Trimmed, '^id\s*=\s*"([^"]+)"', &M)
			Ids.Push(M[1])
	}
	return Ids
}

; Returns the #HotIf criterion guarding the nav-layer rescue: the SC03A variant
; that hands the chord to LAltCapsLockShortcut() WHILE the navigation layer is
; engaged. Selected by that semantic property rather than by file or wording —
; every other SC03A dispatcher of the same function is explicitly gated on
; "not LayerEnabled" and is therefore not the rescue.
_NLGG_RescueGate() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/tap_holds"))
	Lines := StrSplit(Src, "`n", "`r")
	Gates := []
	for i, Line in Lines {
		if !InStr(Line, "LAltCapsLockShortcut(")
			continue
		; Walk back to the #HotIf that opened this hotkey's context
		HotIfIdx := 0
		j := i
		while (j >= 1) {
			if InStr(Lines[j], "#HotIf") {
				HotIfIdx := j
				break
			}
			j--
		}
		if (HotIfIdx == 0)
			continue
		; Join the criterion, which spans several lines, stopping at the hotkey label
		Criterion := ""
		k := HotIfIdx
		while (k <= i and !InStr(Lines[k], "::")) {
			Criterion .= " " . Trim(Lines[k], " `t")
			k++
		}
		if (InStr(Criterion, "LayerEnabled") and !InStr(Criterion, "not LayerEnabled"))
			Gates.Push(Criterion)
	}
	Assert(Gates.Length == 1,
		"exactly one SC03A variant in modules/tap_holds must dispatch LAltCapsLockShortcut() while the navigation layer is engaged (found " . Gates.Length . ") — without it the chord falls through to the layer's own BackSpace mapping")
	return Gates[1]
}





; =============================
; =============================
; ======= 2/ Invariants =======
; =============================
; =============================

; The rescue must ask the canonical single source, not its own list of ids.
_NLGG_GateDelegatesToAnyShortcutEnabled() {
	Gate := _NLGG_RescueGate()
	Assert(InStr(Gate, '_AnyShortcutEnabled("lalt_caps_lock")') > 0,
		"the nav-layer LAlt+CapsLock rescue must gate on _AnyShortcutEnabled(" . Chr(0x22) . "lalt_caps_lock" . Chr(0x22) . ") like its base_modifier.ahk sibling — a hand-written list of action ids drifts from the manifest and silently turns the chord into the layer's BackSpace mapping")
}

; Drift backstop: every action the manifest declares must be covered, either
; because the gate delegates or because it names the id explicitly.
_NLGG_EveryManifestActionCovered() {
	Gate := _NLGG_RescueGate()
	Ids := _NLGG_ManifestActionIds()
	Assert(Ids.Length > 0,
		"the manifest scan must find the lalt_caps_lock action ids — a vacuous list would make the coverage assertions below unfalsifiable")
	Dispatcher := _DriverFuncBody("LAltCapsLockShortcut")
	Assert(Dispatcher != "", "LAltCapsLockShortcut must exist in the driver source")
	for Id in Ids {
		Assert(InStr(Dispatcher, '"' . Id . '"') > 0,
			"lalt_caps_lock action '" . Id . "' is declared in the manifest but LAltCapsLockShortcut() has no branch for it")
		Assert(InStr(Gate, "_AnyShortcutEnabled") > 0 or InStr(Gate, '"' . Id . '"') > 0,
			"lalt_caps_lock action '" . Id . "' is not covered by the nav-layer rescue gate — selecting it makes the criterion false and the press falls through to the navigation layer's own SC03A mapping, deleting a character")
	}
}

; Class invariant: no gate anywhere in the tap-holds tree may read the group's
; sub-map by hand. Those reads are both the drift vector and a raw Map[key]
; access, which throws on a key the manifest later renames.
_NLGG_NoHandRolledGroupReadInTapHolds() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/tap_holds"))
	Assert(InStr(Src, '["lalt_caps_lock"][') == 0,
		"modules/tap_holds must not read Features[" . Chr(0x22) . "shortcuts" . Chr(0x22) . "][" . Chr(0x22) . "lalt_caps_lock" . Chr(0x22) . "][<id>] directly — ask _AnyShortcutEnabled(" . Chr(0x22) . "lalt_caps_lock" . Chr(0x22) . ") instead, so the set of actions lives in one place and a raw Map access can never throw inside a #HotIf")
}


Test("nav-layer lalt+capslock: the rescue gate delegates to _AnyShortcutEnabled",
	_NLGG_GateDelegatesToAnyShortcutEnabled)
Test("nav-layer lalt+capslock: every manifest action is covered by the rescue gate and the dispatcher",
	_NLGG_EveryManifestActionCovered)
Test("nav-layer lalt+capslock: no hand-rolled lalt_caps_lock group read in modules/tap_holds",
	_NLGG_NoHandRolledGroupReadInTapHolds)
