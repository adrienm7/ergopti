; tests/meta/test_marker_and_heatmap_completeness.ahk

; ==============================================================================
; MODULE: Regression — data written on one side must be read on the other
;         (marker-and-heatmap-completeness)
; DESCRIPTION:
; Two half-wired pipelines. In both, one side does its job and the other quietly
; does not, so nothing ever fails — the output is simply wrong or absent.
;
; ROOT CAUSE ENCODED:
;   * The magic-key marker is substituted into the TRIGGER at engine
;     registration but not into the REPLACEMENT, while the preview index
;     substitutes both. A replacement containing the marker was therefore
;     previewed with the user's magic key and emitted with a literal star: the
;     tooltip promised one string and the engine typed another.
;   * The scancode heatmap table is written by the walker and read by the live
;     today path, but the RANGE reader declared its "sc_kb" slot, returned it
;     empty, and never queried the table. The dashboard looked populated from
;     the live feed while every historical and range scancode heatmap was blank.
;     The macOS twin keys its heatmap on "kc", which is read, so cross-driver
;     testing could not surface a gap that exists only on Windows.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The marker is substituted on BOTH sides ===============
; ==================================================================
; ==================================================================

; Registration must substitute the marker in the replacement as well as the
; trigger, or the emitted text differs from the previewed text.
_MHC_RegistrationSubstitutesBothSides() {
	Src := _StripFullLineComments(_DriverDirConcat("infra/hotstrings"))
	Assert(Src != "", "the hotstring layer must be locatable")

	At := InStr(Src, "HSE_RegisterFromTomlFlags(Row[6], Row[1],")
	Assert(At > 0, "the cache registration call must exist")

	Window := SubStr(Src, Max(1, At - 400), 500)
	Assert(InStr(Window, "Trigger := StrReplace(Row[2], HS_CACHE_MARKER") > 0,
		"the trigger substitution must stay — it is what makes the trigger match the key the user actually presses")
	Assert(InStr(Window, "Output := StrReplace(Row[3], HS_CACHE_MARKER") > 0,
		"the REPLACEMENT must be substituted too. The preview index already does both, so leaving this side raw previewed the user's magic key and emitted a literal marker — the tooltip promising one string while the engine typed another")

	Assert(InStr(Src, "HSE_RegisterFromTomlFlags(Row[6], Row[1], Trigger, Output,") > 0,
		"and the substituted Output must be the value actually registered, not merely computed")
}

; The preview side must keep substituting both, since agreement is the point.
_MHC_PreviewSubstitutesBothSides() {
	Src := _StripFullLineComments(_DriverDirConcat("infra/hotstrings"))
	Assert(InStr(Src, "Trigger := StrReplace(Row[2], HS_CACHE_MARKER, MagicKey)") > 0,
		"the preview index must substitute the trigger")
	Assert(InStr(Src, "Output := StrReplace(Row[3], HS_CACHE_MARKER, MagicKey)") > 0,
		"and the output — this is the side that was already correct, and the invariant is that the two AGREE")
}




; ==================================================================
; ==================================================================
; ======= 2/ Every declared heatmap slot is filled =================
; ==================================================================
; ==================================================================

; A slot that is declared and returned but never queried is worse than a missing
; one: the consumer sees a well-formed empty map and renders a blank heatmap.
_MHC_RangeReaderFillsScancodeSlot() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	Assert(Src != "", "the keylogger reader must be locatable")

	Assert(InStr(Src, '"sc_kb", Map()') > 0,
		"the range reader must still declare the scancode slot")
	Assert(InStr(Src, "FROM ngram_scancodes") > 0,
		"and it must actually query ngram_scancodes. The walker writes that table and the live today path reads it, so the dashboard looked populated while every historical and range scancode heatmap was blank")

	At := InStr(Src, 'out["sc_kb"][String(r["scancode"])]')
	Assert(At > 0,
		"the range projection must write into the sc_kb slot keyed by scancode, mirroring the keycode projection beside it")
}

; The keycode twin must stay — the two projections are siblings and the bug was
; precisely that one existed without the other.
_MHC_RangeReaderKeepsKeycodeSlot() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	Assert(InStr(Src, 'out["kc"][String(r["keycode"])]') > 0,
		"the keycode projection must remain — it is the one that worked, and the fix is that its scancode sibling now exists too")
}

; The live today path already covered scancodes; that must not regress, or the
; live heatmap goes blank while the historical one works — the same bug mirrored.
_MHC_TodayPathKeepsScancodes() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/keylogger"))
	At := InStr(Src, 'today_idx[app]["sc_kb"][String(r["scancode"])]')
	Assert(At > 0,
		"the today path must keep filling the scancode bucket — it is the half that already worked, and losing it would invert the bug rather than fix it")
}


Test("meta marker-and-heatmap-completeness: registration substitutes the marker on both sides",
	_MHC_RegistrationSubstitutesBothSides)
Test("meta marker-and-heatmap-completeness: the preview index still substitutes both sides",
	_MHC_PreviewSubstitutesBothSides)
Test("meta marker-and-heatmap-completeness: the range reader fills the scancode slot",
	_MHC_RangeReaderFillsScancodeSlot)
Test("meta marker-and-heatmap-completeness: the range reader keeps the keycode slot",
	_MHC_RangeReaderKeepsKeycodeSlot)
Test("meta marker-and-heatmap-completeness: the today path keeps its scancode bucket",
	_MHC_TodayPathKeepsScancodes)
