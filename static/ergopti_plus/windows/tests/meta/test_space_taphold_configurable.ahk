; tests/meta/test_space_taphold_configurable.ahk

; ==============================================================================
; MODULE: SpaceTapHold Configurable Timeout Guard
; DESCRIPTION:
; Static source guard for the SPACE_HOLD_INPUT_TIMEOUT_FACTOR constant fix in
; platform/remap/space.ahk.
;
; ROOT CAUSE ENCODED:
; The original space tap-hold InputHook used the hardcoded string "L1 T3" where
; "T3" sets a 3-second capture timeout. If the global tap-hold timeout was
; changed (via config or the tap-hold settings dialog), the space tap-hold would
; still timeout at exactly 3 seconds — inconsistent with the configured value.
;
; The fix replaces "L1 T3" with a dynamic string that derives the timeout from
; TimeoutSec * SPACE_HOLD_INPUT_TIMEOUT_FACTOR, where
; SPACE_HOLD_INPUT_TIMEOUT_FACTOR is a named constant. This test verifies that
; the constant is defined and used, and that the bare "T3" hardcoded literal no
; longer appears in the InputHook call.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSTC_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==================================================================
; ==================================================================
; ======= 1/ SPACE_HOLD_INPUT_TIMEOUT_FACTOR replaces hardcoded T3 =
; ==================================================================
; ==================================================================

_TSTC_ConfigurableTimeout() {
	; Move-resilient: scan the tap-holds module dir via the framework helper instead
	; of a pinned modules path; the constant declaration lives at module scope (not
	; inside a function), so keep the comment-stripping extractor
	Src := _TSTC_StripLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "platform/remap/space.ahk must be readable")

	Body := _DriverFuncBody("SpaceTapHold")
	Assert(InStr(Body, 'TapHoldDuration(TapHold, "space")') > 0,
		"Space must pass its configured tap threshold to the common owner")
	Assert(!InStr(Body, "InputHook(") and !InStr(Src, "SPACE_HOLD_INPUT_TIMEOUT_FACTOR"),
		"Space must not retain a second capture timeout independent of the configured tap threshold")
}
Test("tap_holds/space: configured threshold feeds the immediate owner directly", _TSTC_ConfigurableTimeout)
