; tests/unit/test_delay_edit_non_integer_personal_truncation.ahk

; ==============================================================================
; MODULE: Delay Serialisation Single-Source Tests
; DESCRIPTION:
; Regression tests for finding delay-edit-non-integer-personal-truncation.
;
; Two independent serialisers used to encode the SAME logical delay field with
; different precision rules: the shared override store (_SaveOverrides) wrote
; the raw number (e.g. 2.0 -> "2.0") while the config window's personal-TOML
; path (_HCW_TomlValue) quantised to 3 decimals (2.0 -> "2.000"). Same value,
; two on-disk strings -> UI/engine drift waiting to happen.
;
; The fix routes BOTH backends through one helper, HotstringsSerialiseDelay,
; pinning every delay write to a single millisecond-quantised rule.
;
; This is a behavioural test: HotstringsSerialiseDelay lives in
; lib/hotstrings/hotstrings_config.ahk, which IS in the run_all include graph
; and is a pure function (no OS / file / network side effects), so it can be
; called directly. A meta-static guard additionally pins the config-window side
; (_HCW_TomlValue, NOT in the run_all graph) to the same helper.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Behavioural serialiser checks =========
; ==================================================
; ==================================================

; The helper must produce a stable, millisecond-quantised string. 3 decimals of
; a second == whole milliseconds, the rule the whole stack agrees on.
_DENI_SerialiserIsMsQuantised() {
	; Integer ms (the only path the current GUI feeds) must round-trip cleanly.
	AssertEqual("2.000", HotstringsSerialiseDelay(2),
		"HotstringsSerialiseDelay(2) must serialise to 3-decimal seconds")
	AssertEqual("0.000", HotstringsSerialiseDelay(0),
		"HotstringsSerialiseDelay(0) must serialise to 3-decimal seconds")
	; Sub-millisecond input must quantise to the same 3-decimal rule, not leak
	; full float precision into the file.
	AssertEqual("0.750", HotstringsSerialiseDelay(0.7504),
		"HotstringsSerialiseDelay must clamp sub-ms precision to whole milliseconds")
}
Test("hs_config: HotstringsSerialiseDelay is millisecond-quantised (delay-edit-non-integer-personal-truncation)", _DENI_SerialiserIsMsQuantised)

; The defect was two serialisers diverging for the same value. With both
; backends routed through the one helper, the SAME logical delay (whether it
; arrives as a float like 2.0 or as the equivalent number) yields the SAME
; on-disk string. Pin that invariant: equal logical values -> equal strings.
_DENI_BothBackendsAgree() {
	; Personal path used to emit "2.000"; the override store used to emit "2.0".
	; Now both go through HotstringsSerialiseDelay, so the two representations of
	; the identical value must serialise identically.
	FromFloat := HotstringsSerialiseDelay(2.0)
	FromInt   := HotstringsSerialiseDelay(2)
	AssertEqual(FromInt, FromFloat,
		"The same logical delay must serialise to one string regardless of numeric form -- both backends route through HotstringsSerialiseDelay")
	AssertEqual("2.000", FromFloat,
		"Both backends must agree on the canonical 3-decimal delay string")
}
Test("hs_config: both delay backends serialise the same value identically (delay-edit-non-integer-personal-truncation)", _DENI_BothBackendsAgree)




; ==================================================
; ==================================================
; ======= 2/ Config-window source guard ============
; ==================================================
; ==================================================

; A_ScriptDir is the runner dir (tests/); its parent is the windows/ driver root.

; _HCW_TomlValue (config window, not in the run_all graph) must delegate the
; "delay" field to the shared helper rather than re-implement its own Format,
; otherwise the two paths could silently re-diverge.
_DENI_WindowDelegatesToHelper() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Seg := _DriverFuncBody("_HCW_TomlValue")
	Assert(Seg != "", "_HCW_TomlValue must exist in hotstrings_config_window.ahk")
	Assert(InStr(Seg, "HotstringsSerialiseDelay") > 0,
		"_HCW_TomlValue must serialise the delay field via HotstringsSerialiseDelay -- single source of truth shared with the override store")
}
Test("hs_config: _HCW_TomlValue delegates delay serialisation to the shared helper (delay-edit-non-integer-personal-truncation)", _DENI_WindowDelegatesToHelper)
