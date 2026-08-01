; tests/meta/test_taphold_timings_load_order.ahk

; ==============================================================================
; MODULE: Tap-hold timing constants load-order guard
; DESCRIPTION:
; AHK v2 executes a file's top-level `global X := ...` assignments at its #Include
; POSITION in the auto-execute flow. modules/tap_holds/constants.ahk seeds the
; four tap-hold timing constants (TAP_MIN_DURATION_MS, KEY_REPEAT_INITIAL_DELAY_MS,
; KEY_REPEAT_INTERVAL_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC) to a sentinel 0. infra/boot.ahk
; then loads the real registry values via TapHoldsLoadTimings(). If constants.ahk
; is included AFTER infra/boot.ahk, its sentinel 0s re-zero the loaded values on every
; boot -- disabling the 50 ms anti-misfire floor and turning the key-repeat delays
; into a Sleep(0) tight loop. ErgoptiPlus.ahk must therefore include the constants
; in the early manifest, before infra/boot.ahk. (F12, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_TTLO_ConstantsIncludedBeforeBoot() {
	; Move-resilient: both #Include directives below exist in exactly ONE file
	; (ErgoptiPlus.ahk), and a file's content is contiguous inside the concatenation,
	; so their relative order is preserved without pinning the entry file's path.
	Src := _DriverSourceConcat()
	Assert(Src != "", "driver source must be readable for the tap-hold timings load-order meta-test")

	ConstPos := InStr(Src, "#Include modules/tap_holds/constants.ahk")
	BootPos := InStr(Src, "#Include infra/boot.ahk")
	Assert(ConstPos > 0,
		"ErgoptiPlus.ahk must include modules/tap_holds/constants.ahk in the early manifest (sentinel layer)")
	Assert(BootPos > 0,
		"ErgoptiPlus.ahk must include infra/boot.ahk (which calls TapHoldsLoadTimings)")
	Assert(ConstPos < BootPos,
		"tap-hold constants must be included BEFORE infra/boot.ahk so their include-position sentinel 0s cannot re-zero the values TapHoldsLoadTimings() loads")
}
Test("tap-holds: timing constants load before boot.ahk (no sentinel re-zero)", _TTLO_ConstantsIncludedBeforeBoot)


; F-18 (audit 2026-07-20, second pass): tap-holds is only ONE of five loaders
; that run from the auto-exec body and depend on this ordering. All five are
; currently correct, so this is latent rather than live — but the invariant was
; pinned for a single site, and a future #Include reorder of any of the other
; four would re-zero their constants SILENTLY. That matters especially for the
; timing loaders: a re-zeroed 0 ms sentinel is a documented CPU-spin hazard, not
; merely a wrong value.
;
; AHK executes an included file's top-level `global X := 0` sentinel at its
; INCLUDE position, so every sentinel-declaring file must precede infra/boot.ahk
; (which calls the loaders) in the include manifest.
_TTLO_EverySentinelFilePrecedesBoot() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "driver source must be readable")

	BootPos := InStr(Src, "#Include infra/boot.ahk")
	Assert(BootPos > 0, "ErgoptiPlus.ahk must include infra/boot.ahk")

	; file -> the loader whose values its include-position sentinels would clobber
	Pairs := Map(
		"modules/tap_holds/constants.ahk",        "TapHoldsLoadTimings",
		"infra/hotstrings/hotstrings_config.ahk",   "HotstringsConfigLoadSharedDefaults",
		"modules/keylogger/keylogger_walker.ahk", "KeyloggerWalkerLoadTimings",
		"modules/llm/api_ollama.ahk",             "LLMApiLoadTimings",
		"infra/ui_style.ahk",                       "UiStyle_LoadSharedConst"
	)
	for RelPath, Loader in Pairs {
		Pos := InStr(Src, "#Include " . RelPath)
		Assert(Pos > 0,
			"ErgoptiPlus.ahk must include " . RelPath . " — if the file moved, update this table rather than dropping it from the invariant")
		Assert(Pos < BootPos,
			RelPath . " must be included BEFORE infra/boot.ahk: its include-position sentinel assignments would otherwise re-zero the values " . Loader . "() loads, silently and with no error — and a 0 ms timing sentinel is a CPU-spin hazard, not just a wrong value")
	}
}
Test("boot: every shared-constant sentinel file loads before boot.ahk (F-18)",
	_TTLO_EverySentinelFilePrecedesBoot)
