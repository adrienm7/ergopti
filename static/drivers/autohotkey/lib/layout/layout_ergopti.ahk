; lib/layout_ergopti.ahk

; ==============================================================================
; MODULE: Ergopti Base-Layer Mapping (single source of truth)
; DESCRIPTION:
; Holds the canonical scancode → character mapping for the Ergopti base
; layer. modules/layout.ahk iterates this table to install the actual
; AutoHotkey remaps; modules/keylogger_prefetch.ahk reads it to label
; the heatmap. Editing the layout in one place propagates to both.
;
; FEATURES & RATIONALE:
; 1. Single source of truth: previously the same characters lived in
;    layout.ahk's RemapKey calls AND in a duplicate table inside the
;    keylogger prefetch — drift was easy. Now there is exactly one
;    authoritative Map.
; 2. Live FeaturesV2 lookup: keys whose output is user-configurable
;    (è / ê / é / à) read their current value from
;    FeaturesV2["shortcuts"][...]["letter"] at call time, so menu changes
;    take effect immediately without any extra wiring.
; 3. Dead-key entries kept separate: the diaeresis / circumflex keys
;    are bound through a custom Hotkey() call (DeadKey state machine),
;    not RemapKey, so they live alongside their handlers in layout.ahk
;    rather than in this purely tabular file.
; ==============================================================================

#Requires Autohotkey v2.0+




; ============================================
; ============================================
; ======= 1/ Canonical mapping =======
; ============================================
; ============================================

; Scancode (decimal) → output character on the Ergopti base layer.
; Hex equivalents shown alongside for cross-reference with the
; ``RemapKey("SC0xx", …)`` calls that used to live in layout.ahk.
;
; Values that read from FeaturesV2["shortcuts"][...]["letter"] are wrapped
; in a tiny object so layout.ahk can pick up the configurable Letter
; AND the historical fallback character that ``RemapKey`` keeps as the
; AlternativeCharacter argument. Plain strings are passed through.
ErgoptiBaseMapping() {
	global FeaturesV2
	; Helper for the configurable letters. Reads the per-feature
	; "letter" slot in FeaturesV2["shortcuts"][<snake_case_id>] —
	; falls back to the historical default when v2 is unset or the
	; entry shape is unexpected.
	letter_or := (key, fallback) => (
		IsSet(FeaturesV2) && FeaturesV2.Has("shortcuts")
			&& FeaturesV2["shortcuts"].Has(key)
			&& IsObject(FeaturesV2["shortcuts"][key])
			&& FeaturesV2["shortcuts"][key].Has("letter")
			? FeaturesV2["shortcuts"][key]["letter"]
			: fallback
	)
	return Map(
		; Top row (number row of physical AZERTY/QWERTY)
		0x10, { c: letter_or("e_grave", "è"), alt: "è" }, ; SC010
		0x11, "y",                                        ; SC011
		0x12, "o",                                        ; SC012
		0x13, "w",                                        ; SC013
		0x14, "b",                                        ; SC014
		0x15, "f",                                        ; SC015
		0x16, "g",                                        ; SC016
		0x17, "h",                                        ; SC017
		0x18, "c",                                        ; SC018
		0x19, "x",                                        ; SC019
		0x1A, "z",                                        ; SC01A
		; Middle row (home row)
		0x1E, "a",                                        ; SC01E
		0x1F, "i",                                        ; SC01F
		0x20, "e",                                        ; SC020
		0x21, "u",                                        ; SC021
		0x22, ".",                                        ; SC022
		0x23, "v",                                        ; SC023
		0x24, "s",                                        ; SC024
		0x25, "n",                                        ; SC025
		0x26, "t",                                        ; SC026
		0x27, "r",                                        ; SC027
		0x28, "q",                                        ; SC028
		; Bottom row
		0x56, { c: letter_or("e_circ",  "ê"), alt: "ê" }, ; SC056
		0x2C, { c: letter_or("e_acute", "é"), alt: "é" }, ; SC02C
		0x2D, { c: letter_or("a_grave", "à"), alt: "à" }, ; SC02D
		0x2E, "j",                                       ; SC02E
		0x2F, ",",                                       ; SC02F
		0x30, "k",                                       ; SC030
		0x31, "m",                                       ; SC031
		0x32, "d",                                       ; SC032
		0x33, "l",                                       ; SC033
		0x34, "p",                                       ; SC034
		0x35, "'",                                       ; SC035
		; Space (the only thumb-row remap on the base layer)
		0x39, " "                                        ; SC039
	)
}

; Convenience: same data flattened to ``sc_int → display_char`` (no
; alternative/fallback wrapping). Used by anything that just wants to
; label a key (heatmap, debug panels, …). Dead-key positions (¨ at
; SC01B, ^ at SC02B) are added so the heatmap shows their resting
; symbol — they have no RemapKey entry because their behaviour goes
; through DeadKey().
ErgoptiBaseLabels() {
	out := Map()
	for sc, v in ErgoptiBaseMapping() {
		if (v is String) {
			out[sc] := v
		} else if IsObject(v) {
			out[sc] := v.HasOwnProp("c") ? v.c : ""
		}
	}
	out[0x1B] := "¨"  ; dead key — diaeresis
	out[0x2B] := "^"  ; dead key — circumflex
	return out
}
