; tests/meta/test_master_gate_drifted_subgate_skip.ahk

; ==============================================================================
; MODULE: Master-gate drifted sub-category skip guard
; DESCRIPTION:
; menu_manifest.json declares dynamic_hotstrings -> DynamicHotstrings as a hotstring
; master-gate sub-category, but CategoryEnabled deliberately omits it (it follows
; the Hotstrings master, not a standalone gate) AND its feature-group id
; (dynamic_hotstrings) does not match the Features tree key (dynamic). So
; ApplyMasterGatesToFeatures probed IsCategoryGated("DynamicHotstrings"), which
; logged "unknown category ... " on every single boot (6/6 on 07-19). The fix skips
; a sub-gate whose feature-group key is absent from Features["hotstrings"] BEFORE
; probing the category gate, so a drifted/inert gate is skipped silently rather than
; warned. (F17 + F22, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_MGDS_DriftedSubGateSkippedBeforeProbe() {
	Body := _DriverFuncBody("ApplyMasterGatesToFeatures")
	Assert(Body != "", "ApplyMasterGatesToFeatures must exist in lib/master_gates.ahk")

	LoopPos := InStr(Body, "for SubV1, SubV2 in SubGates")
	Assert(LoopPos > 0, "ApplyMasterGatesToFeatures must iterate the manifest sub-gates")
	Seg := SubStr(Body, LoopPos)

	SkipPos := InStr(Seg, "!FeaturesTarget[")
	ProbePos := InStr(Seg, "CategoryGateFn.Call(SubV1)")
	Assert(SkipPos > 0,
		"the sub-gate loop must skip a sub-gate with no Features['hotstrings'] key (a drifted/inert manifest gate)")
	Assert(ProbePos > 0, "the sub-gate loop must still probe the category gate for real sub-gates")
	Assert(SkipPos < ProbePos,
		"the missing-feature-key skip must run BEFORE CategoryGateFn.Call — otherwise IsCategoryGated logs a spurious 'unknown category' WARNING on every boot")
}
Test("master-gates: drifted hotstring sub-gate is skipped before the category-gate probe",
	_MGDS_DriftedSubGateSkippedBeforeProbe)

; F47 (audit 2026-07-20): the tray menu's category-count loops legitimately query
; IsCategoryGated for every hotstring category, including the ones that deliberately
; own no gate (DynamicHotstrings, Personal — they follow the Hotstrings master). Each
; query logged "unknown category … schema drift", so a normal menu build spammed the
; WARNING log. Answer those from the master instead, in ONE place, rather than
; open-coding an exclusion at each call site.
_MGDS_NoGateCategoriesFollowMaster() {
	Body := _DriverFuncBody("IsCategoryGated")
	Assert(Body != "", "IsCategoryGated must exist in lib/feature_state.ahk")

	PassPos := InStr(Body, "CATEGORY_FOLLOWS_HOTSTRINGS_MASTER.Has(Category)")
	WarnPos := InStr(Body, "schema drift")
	Assert(PassPos > 0,
		"IsCategoryGated must recognise the categories that follow the Hotstrings master instead of warning about them")
	Assert(WarnPos > 0 && PassPos < WarnPos,
		"the follow-the-master pass-through must be checked BEFORE the unknown-category warning, so a normal menu build logs nothing")

	Src := _DriverSourceConcat()
	for Cat in ["DynamicHotstrings", "Personal"] {
		Assert(InStr(Src, Chr(0x22) . Cat . Chr(0x22) . ",") > 0,
			"the follow-the-master set must list " . Cat . " (it has no dedicated CategoryEnabled gate)")
	}
}
Test("master-gates: gate-less hotstring categories follow the master without warning",
	_MGDS_NoGateCategoriesFollowMaster)
