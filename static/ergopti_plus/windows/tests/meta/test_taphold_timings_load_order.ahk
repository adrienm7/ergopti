; tests/meta/test_taphold_timings_load_order.ahk

; ==============================================================================
; MODULE: Tap-hold timing constants load-order guard
; DESCRIPTION:
; AHK v2 executes a file's top-level `global X := ...` assignments at its #Include
; POSITION in the auto-execute flow. modules/tap_holds/constants.ahk seeds the
; four tap-hold timing constants (TAP_MIN_DURATION_MS, KEY_REPEAT_INITIAL_DELAY_MS,
; KEY_REPEAT_INTERVAL_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC) to a sentinel 0. lib/boot.ahk
; then loads the real registry values via TapHoldsLoadTimings(). If constants.ahk
; is included AFTER lib/boot.ahk, its sentinel 0s re-zero the loaded values on every
; boot -- disabling the 50 ms anti-misfire floor and turning the key-repeat delays
; into a Sleep(0) tight loop. ErgoptiPlus.ahk must therefore include the constants
; in the early manifest, before lib/boot.ahk. (F12, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_TTLO_ConstantsIncludedBeforeBoot() {
	; Move-resilient: both #Include directives below exist in exactly ONE file
	; (ErgoptiPlus.ahk), and a file's content is contiguous inside the concatenation,
	; so their relative order is preserved without pinning the entry file's path.
	Src := _DriverSourceConcat()
	Assert(Src != "", "driver source must be readable for the tap-hold timings load-order meta-test")

	ConstPos := InStr(Src, "#Include modules/tap_holds/constants.ahk")
	BootPos := InStr(Src, "#Include lib/boot.ahk")
	Assert(ConstPos > 0,
		"ErgoptiPlus.ahk must include modules/tap_holds/constants.ahk in the early manifest (sentinel layer)")
	Assert(BootPos > 0,
		"ErgoptiPlus.ahk must include lib/boot.ahk (which calls TapHoldsLoadTimings)")
	Assert(ConstPos < BootPos,
		"tap-hold constants must be included BEFORE lib/boot.ahk so their include-position sentinel 0s cannot re-zero the values TapHoldsLoadTimings() loads")
}
Test("tap-holds: timing constants load before boot.ahk (no sentinel re-zero)", _TTLO_ConstantsIncludedBeforeBoot)
