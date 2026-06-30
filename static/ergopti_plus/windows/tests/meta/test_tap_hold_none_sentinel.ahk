; tests/meta/test_tap_hold_none_sentinel.ahk

; ==============================================================================
; MODULE: Tap-Hold None Sentinel Meta Test
; DESCRIPTION:
; Regression guard for the tap-hold "none" sentinel conventions.
;
; The tap-hold subsystem uses two "none" sentinels:
;   - Hold "none": an entry in _TH_HoldOptions with id="" and kind="none",
;     meaning the key has no hold modifier — it behaves as a tap-only key.
;     Stored as an empty string in TOML (hold_modifier = "").
;   - Tap "none": _TH_TapNoneI18n = "tap_hold.tap.none", returned by
;     TapHoldCurrentTapLabel when the key has no configured tap action
;     (tap_action key absent or empty).
;
; Without these sentinels, the action picker would crash when a key has no hold
; or tap assignment (nil vs empty string mismatch, missing Map key access).
;
; This test asserts:
;   1. _TH_HoldOptions contains a sentinel entry with id="" and kind="none".
;   2. TapHoldTapAction returns "" for a key absent from TapHold["keys"].
;   3. _TH_TapNoneI18n is declared as a global constant.
;
; SCOPE: source introspection of lib/tap_hold/tap_hold_writer.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_THNS_ReadSource() {
	return _DriverDirConcat("lib/tap_hold")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_THNS_HoldOptionsHasNoneSentinel() {
	Src := _THNS_ReadSource()
	Assert(Src != "", "lib/tap_hold/ source must be readable")

	Q := Chr(34)
	; _TH_HoldOptions must contain an entry with id="" and kind="none"
	; The literal form expected in the source is Map("id", "", "kind", "none", ...)
	Assert(InStr(Src, Q . "kind" . Q . ", " . Q . "none" . Q) > 0,
		"_TH_HoldOptions must contain an entry with kind=" . Q . "none" . Q . " — this is the sentinel for tap-only keys that have no hold modifier assigned")
}

Test("tap_hold_writer: _TH_HoldOptions contains a none-sentinel entry (tap-hold-none-sentinel)",
	_THNS_HoldOptionsHasNoneSentinel)


_THNS_NoneHoldIdIsEmptyString() {
	Src := _THNS_ReadSource()
	Assert(Src != "", "lib/tap_hold/ source must be readable")

	; The sentinel is Map("id", "", "kind", "none", ...) — id must be the empty string
	; that the TOML serialiser writes as hold_modifier = ""
	Q := Chr(34)
	HoldSentinelPos := InStr(Src, Q . "kind" . Q . ", " . Q . "none" . Q)
	Assert(HoldSentinelPos > 0, "none sentinel must be present — prerequisite for this test")
	; The "id", "" pair must appear within 80 chars before the sentinel entry
	Nearby := SubStr(Src, Max(1, HoldSentinelPos - 80), 180)
	Assert(InStr(Nearby, Q . "id" . Q . ", " . Q . Q) > 0,
		"The none-sentinel hold option must have id=" . Q . Q . " (empty string) — this is the canonical TOML value for 'no hold modifier'")
}

Test("tap_hold_writer: none-sentinel hold entry has empty-string id (tap-hold-none-sentinel)",
	_THNS_NoneHoldIdIsEmptyString)


_THNS_TapNoneI18nDeclared() {
	Src := _THNS_ReadSource()
	Assert(Src != "", "lib/tap_hold/ source must be readable")

	Assert(InStr(Src, "_TH_TapNoneI18n") > 0,
		"_TH_TapNoneI18n must be declared as a global constant in tap_hold_writer.ahk — it is the single source of truth for the i18n key that the action picker displays when a key has no tap action")
	Assert(InStr(Src, "tap_hold.tap.none") > 0,
		"_TH_TapNoneI18n must be assigned the i18n key 'tap_hold.tap.none' — other modules depend on this exact key being present in the locale JSON")
}

Test("tap_hold_writer: _TH_TapNoneI18n is declared (tap-hold-none-sentinel)",
	_THNS_TapNoneI18nDeclared)


_THNS_TapHoldTapActionReturnsSentinel() {
	Src := _THNS_ReadSource()
	Assert(Src != "", "lib/tap_hold/ source must be readable")

	Body := _DriverFuncBody("TapHoldTapAction")
	Assert(Body != "", "TapHoldTapAction must be defined in lib/tap_hold/tap_hold_loader.ahk or tap_hold_writer.ahk")

	; The function must check Has() before indexing to avoid a missing-key throw
	Assert(InStr(Body, ".Has(") > 0,
		"TapHoldTapAction must use .Has() to guard Map access — a missing 'keys' or missing key_id entry must return the none sentinel (''), not throw a missing-key error")
	; On the absent path it must return "" (the none sentinel)
	Q := Chr(34)
	Assert(InStr(Body, "return " . Q . Q) > 0,
		"TapHoldTapAction must return an empty string when the key is absent — this is the tap-none sentinel that TapHoldCurrentTapLabel maps to the i18n label via _TH_TapNoneI18n")
}

Test("tap_hold_writer: TapHoldTapAction returns empty-string for absent key (tap-hold-none-sentinel)",
	_THNS_TapHoldTapActionReturnsSentinel)
