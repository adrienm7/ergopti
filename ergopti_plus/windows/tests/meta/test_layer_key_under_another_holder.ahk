; tests/meta/test_layer_key_under_another_holder.ahk

; ==============================================================================
; MODULE: A key whose hold is a layer another key already holds
; DESCRIPTION:
; The cross-driver rule for a tap-hold key K pressed while ANOTHER key holds
; the layer K's own hold would activate (Space held as "nav" while CapsLock
; holds nav): when the layer maps K, the layer's mapping applies; when it does
; not, K is a plain key, whose tap types it and whose hold auto-repeats
; (layer-key-under-another-holder-2026-09-27). Windows is the reference since
; 765f8ae4a: every tap-hold variant is off while the layer is on, the layer
; maps two tap-hold keys (CapsLock is BackSpace, AltGr is Escape), and each
; key's repeat swallower takes only the press its own owner claimed. The Linux
; and macOS drivers pin the same rule in their suites.
; The layer swallows one key instead: LAlt tapping BackSpace with the layer on
; hold (nav_layer.ahk, "Fix when LAlt triggers the layer"). Passed through, it
; is an Alt under every chord of the layer (its Up is Alt+Up, which moves the
; line in VS Code), so the other drivers swallow it too.
; The hotkeys are declared at load in files the harness cannot include, so this
; reads their #HotIf criteria, file by file, over the whole driver tree.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ The hotkeys of the tap-hold keys =======
; ===================================================
; ===================================================

; Scan code -> tap-hold key id, the keys a tap-hold can be configured on.
_LKAH_Keys() {
	return Map("SC001", "escape", "SC00F", "tab", "SC03A", "caps_lock", "SC01D", "left_ctrl",
		"SC02A", "left_shift", "SC15B", "win", "SC038", "left_alt", "SC039", "space",
		"SC138", "alt_gr", "SC11D", "right_ctrl", "SC036", "right_shift", "SC01C", "enter",
		"SC00E", "backspace", "SC153", "delete")
}

; Every hotkey of a bare tap-hold key (no modifier symbol: a key alone, or the
; AltGr that arrives as the fake LCtrl then SC138) in the driver, with the
; #HotIf criterion it is declared under: Array of { Key, Label, Criterion,
; File }. The criterion is read per file, and a parenthesised one spans lines.
_LKAH_Hotkeys() {
	Keys := _LKAH_Keys()
	Found := []
	SplitPath(A_ScriptDir, , &Root)
	Loop Files, Root . "\*.ahk", "FR" {
		P := StrReplace(A_LoopFileFullPath, "\", "/")
		if (InStr(P, "/tests/") or InStr(P, "/vendor/") or InStr(P, "/_generated/"))
			continue
		Criterion := ""
		Open := 0
		for Line in StrSplit(_StripFullLineComments(FileRead(A_LoopFileFullPath, "UTF-8")), "`n", "`r") {
			if (Open > 0) {
				Criterion .= " " . Trim(Line)
				StrReplace(Line, "(", , , &Opened), StrReplace(Line, ")", , , &Closed)
				Open += Opened - Closed
				continue
			}
			if RegExMatch(Line, "^\s*#HotIf\b\s*(.*)$", &HotIf) {
				Criterion := Trim(HotIf[1])
				StrReplace(Criterion, "(", , , &Opened), StrReplace(Criterion, ")", , , &Closed)
				Open := Opened - Closed
				continue
			}
			Key := ""
			if RegExMatch(Line, "^\s*[~*$]*(SC[0-9A-F]{3})(\s+Up)?::", &Label)
				Key := Label[1]
			else if RegExMatch(Line, "^\s*~?SC01D\s*&\s*~?(SC138)::", &Label)
				Key := Label[1]
			if (Key != "" and Keys.Has(Key))
				Found.Push({ Key: Key, Label: Trim(Line), Criterion: Criterion, File: P })
		}
	}
	return Found
}





; =================================================
; =================================================
; ======= 2/ The rule on the Windows driver =======
; =================================================
; =================================================

; The two criteria of the AltGr owners are functions (altgr_criteria.ahk,
; included by the harness): checked below by calling them.
_LKAH_IsAltGrOwnerCriterion(Criterion) {
	return RegExMatch(Criterion, "^AltGrOwner(PassesThrough|Holds)\((true|false)\)$")
}

_LKAH_EveryVariantStandsDownOnTheLayer() {
	Keys := _LKAH_Keys()
	Hotkeys := _LKAH_Hotkeys()
	AssertTrue(Hotkeys.Length >= 60, "the scan must find the tap-hold keys' hotkeys; found " . Hotkeys.Length)
	LayerMapped := Map()
	Swallowed := Map()
	Offenders := []
	for _, Hotkey in Hotkeys {
		C := Hotkey.Criterion
		if RegExMatch(C, "\bnot LayerEnabled\b")
			continue ; the key's tap-hold, off while any key holds the layer
		if (C == 'TapHoldPressIsOwned("' . Keys[Hotkey.Key] . '")')
			continue ; the key's own claimed press, never one made on another key's layer
		if _LKAH_IsAltGrOwnerCriterion(C)
			continue ; called below
		if (C == "CapsWordEnabled")
			continue ; CapsWord's own Space and Enter, a separate mode
		if (C == "KeyCombinationOwnsHotkey()")
			continue ; a key combination the user bound, held first key and all
		if RegExMatch(C, "^\(?\s*LayerEnabled\b") {
			LayerMapped[Keys[Hotkey.Key]] := true
			continue
		}
		; LAlt tapping BackSpace with the layer on hold: swallowed, without ~.
		if (RegExMatch(C, "^\(\s*_LAltIsBackspaceLayer\(\)\s+and\s+LayerEnabled\s*\)$")
				and RegExMatch(Hotkey.Label, "^\*SC038::")) {
			Swallowed[Keys[Hotkey.Key]] := true
			continue
		}
		Offenders.Push(Hotkey.File . ": " . Hotkey.Label . " under #HotIf " . C)
	}
	AssertEqual(0, Offenders.Length, "a tap-hold key's hotkey must stand down while another key holds the layer: "
		. (Offenders.Length ? Offenders[1] : ""))
	; AltGr is registered from the resolved layer instead of a static label.
	Ctx := KeymapLayers_LoadContext(A_ScriptDir . "\..\..\_shared")
	Resolved := KeymapLayers_Load("windows", Ctx, FileRead(A_ScriptDir . "\..\..\_shared\keymap\layers.recommended.toml", "UTF-8"))
	AssertTrue(Resolved["ok"], "the recommended layer must resolve")
	AltGrLabels := Map()
	for Row in NavLayer_BuildTable(Resolved["layers"]["nav"], Ctx) {
		; CapsLock's mapping is the layer's own too, since LAlt then CapsLock
		; became a key combination and left its static label on the layer.
		if (Row["code"] == "CapsLock")
			LayerMapped["caps_lock"] := true
		if (Row["code"] != "AltRight")
			continue
		AssertEqual(NAV_LAYER_CRITERION_LAYER, Row["criterion"], "AltGr must only map while the layer is active")
		AssertEqual("send:{Escape N}", Row["action"], "the recommended AltGr mapping must send Escape")
		AltGrLabels[Row["hotkey"]] := true
	}
	AssertTrue(AltGrLabels.Count == 2 && AltGrLabels.Has("~SC01D & ~SC138") && AltGrLabels.Has("*SC138"),
		"both physical AltGr spellings must be registered by the layer")
	LayerMapped["alt_gr"] := true
	AssertTrue(LayerMapped.Count == 2 && LayerMapped.Has("alt_gr") && LayerMapped.Has("caps_lock"),
		"the navigation layer maps AltGr (Escape) and CapsLock (BackSpace) among the tap-hold keys; every other one"
		. " is a plain key on a layer another key holds: its tap types it, its hold auto-repeats")
	AssertTrue(Swallowed.Count == 1 and Swallowed.Has("left_alt"),
		"the navigation layer swallows LAlt tapping BackSpace with the layer on hold, and no other tap-hold key:"
		. " passed through, it is an Alt under every chord of the layer")
}
Test("layer key under another holder: every tap-hold variant stands down, the layer maps only AltGr and CapsLock and swallows LAlt (layer-key-under-another-holder-2026-09-27)",
	_LKAH_EveryVariantStandsDownOnTheLayer)

; The AltGr owners, the one family of criteria written as functions: whatever
; the AltGr key holds, the layer included, no owner takes a press made while
; the layer is on; nor does any key's repeat swallower take a press nobody
; claimed.
_LKAH_AltGrOwnersAndSwallowersStandDown() {
	global TapHold, LayerEnabled
	Saved := { TapHold: TapHold, Layer: LayerEnabled }
	try {
		LayerEnabled := true
		for _, Hold in [["", "nav"], ["alt_gr", ""], ["ctrl", ""], ["", ""]] {
			Row := Map("time_activation_seconds", 0.2, "tap_action", "tab")
			if (Hold[1] != "")
				Row["hold_modifier"] := Hold[1]
			if (Hold[2] != "")
				Row["hold_layer"] := Hold[2]
			TapHold := Map("keys", Map("alt_gr", Row), "layers", Map())
			for _, Kana in [false, true] {
				AssertFalse(AltGrOwnerPassesThrough(Kana) or AltGrOwnerHolds(Kana),
					"AltGr held as '" . Hold[1] . Hold[2] . "' must not own a press made on the layer")
			}
		}
		for _, Id in _LKAH_Keys()
			AssertFalse(TapHoldPressIsOwned(Id), Id . ": a press nobody claimed is never swallowed")
	} finally {
		TapHold := Saved.TapHold
		LayerEnabled := Saved.Layer
	}
}
Test("layer key under another holder: the AltGr owners and the repeat swallowers stand down (layer-key-under-another-holder-2026-09-27)",
	_LKAH_AltGrOwnersAndSwallowersStandDown)
