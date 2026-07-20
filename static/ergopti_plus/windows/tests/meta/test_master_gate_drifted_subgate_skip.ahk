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
