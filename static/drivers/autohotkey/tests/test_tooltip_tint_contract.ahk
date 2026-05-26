; tests/test_tooltip_tint_contract.ahk

; ==============================================================================
; MODULE: Tooltip Tint Contract Tests
; DESCRIPTION:
; Validates the AHK tooltip tint-mixing algorithm against the canonical test
; vectors defined in static/drivers/_shared/tooltip/tint.js. Every vector
; describes an input accent color and its expected tinted output hex string;
; these tests assert that _TooltipMixTintHex() produces exactly that output.
;
; RATIONALE:
; The shared _shared/tooltip/tint.js defines the canonical HSL-based tint
; algorithm used by both AHK and Hammerspoon. Any algorithmic drift between the
; JS reference and the AHK implementation (e.g. a rounding difference, a hue
; computation bug, or an off-by-one in the HSL-to-RGB conversion) is caught
; here, preventing silent visual regressions across driver updates.
;
; TOLERANCE:
; A +-1 per-channel tolerance is accepted to account for floating-point
; rounding differences between the JS reference and the AHK implementation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Canonical Tint Test Vectors =======
; ==============================================
; ==============================================

; Hard-coded cross-driver tint test vectors, mirroring tintTestVectors() from
; static/drivers/_shared/tooltip/tint.js. Values are computed by the JS
; reference at DEFAULT_LIGHTNESS=0.10 / DEFAULT_SATURATION=0.40.
; When the algorithm constants change, regenerate with:
;   node -e "const t=require('./static/drivers/_shared/tooltip/tint.js'); ..."
_GetTintVectors() {
	Vectors := []
	Vectors.Push({ Id: "red_accent",    AccentHex: "#FF0000", ExpectedHex: "240F0F" })
	Vectors.Push({ Id: "green_accent",  AccentHex: "#00CC00", ExpectedHex: "0F240F" })
	Vectors.Push({ Id: "blue_accent",   AccentHex: "#3388FF", ExpectedHex: "0F1824" })
	Vectors.Push({ Id: "purple_accent", AccentHex: "#AE61FF", ExpectedHex: "190F24" })
	Vectors.Push({ Id: "yellow_accent", AccentHex: "#FFCC00", ExpectedHex: "24200F" })
	Vectors.Push({ Id: "achromatic",    AccentHex: "#808080", ExpectedHex: "1A1A1A" })
	; no_accent: empty string triggers the fallback to _TOOLTIP_DEFAULT_BG_HEX
	Vectors.Push({ Id: "no_accent",     AccentHex: "",        ExpectedHex: "1A1A1A" })
	return Vectors
}





; ====================================================
; ====================================================
; ======= 2/ Tolerance-aware Comparison Helper =======
; ====================================================
; ====================================================

; Returns true if two 6-digit uppercase hex color strings are equal within +-1
; per channel. This tolerates the 1-LSB rounding differences that arise from
; floating-point arithmetic differences between the JS reference and AHK.
_TintHexWithinTolerance(Actual, Expected) {
	Ar := Integer("0x" . SubStr(Actual,   1, 2))
	Ag := Integer("0x" . SubStr(Actual,   3, 2))
	Ab := Integer("0x" . SubStr(Actual,   5, 2))
	Er := Integer("0x" . SubStr(Expected, 1, 2))
	Eg := Integer("0x" . SubStr(Expected, 3, 2))
	Eb := Integer("0x" . SubStr(Expected, 5, 2))
	return Abs(Ar - Er) <= 1 and Abs(Ag - Eg) <= 1 and Abs(Ab - Eb) <= 1
}





; ======================================
; ======================================
; ======= 3/ Test Registration =========
; ======================================
; ======================================

_RunTooltipTintContractTests() {
	Vectors := _GetTintVectors()

	for Vec in Vectors {
		Id       := Vec.Id
		InputHex := Vec.AccentHex
		Expected := Vec.ExpectedHex

		_RunOneTintVector(VecId, VecInput, VecExpected) {
			Actual := _TooltipMixTintHex(VecInput)
			Assert(Actual != "", "tint vector [" . VecId . "]: _TooltipMixTintHex returned empty string")
			; Normalise: both values should be 6-char uppercase hex without "#"
			Assert(_TintHexWithinTolerance(Actual, VecExpected),
				"tint vector [" . VecId . "]: got " . Actual . ", expected " . VecExpected . " (+-1 per channel)")
		}

		TestName := "tooltip tint contract: vector [" . Id . "]"
		Test(TestName, _RunOneTintVector.Bind(Id, InputHex, Expected))
	}
}

_RunTooltipTintContractTests()
