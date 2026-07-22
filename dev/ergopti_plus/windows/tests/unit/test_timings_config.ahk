; static/ergopti_plus/windows/tests/unit/test_timings_config.ahk

; ==============================================================================
; MODULE: Timings Config Tests
; DESCRIPTION:
; A3 — the AHK driver now reads its timing constants from the cross-driver
; registry _shared/modules/timings/constants.toml via lib/timings/timings_config.ahk
; instead of hardcoding the same literals the macOS driver also carries. These
; tests pin:
;   1. TimingsGet returns the raw millisecond value and TimingsGetSec is
;      exactly TimingsGet / 1000; both fail fast on an unknown section/key.
;   2. The reassign-at-boot loaders (KeyloggerWalkerLoadTimings,
;      TapHoldsLoadTimings) replace the sentinel 0 with the canonical registry
;      values — a single-source tripwire on every consumed constant, so a drift
;      in constants.toml (which would silently change runtime timings) turns red.
; ==============================================================================

; Load the registry from the real _shared/ dir (test_stubs.ahk points _SharedDir
; at it) exactly as production does at boot, then run the two reassign loaders so
; the consumer-constant assertions below see the values production would.
TimingsLoadShared()
KeyloggerWalkerLoadTimings()
TapHoldsLoadTimings()




; ============================================================
; ============================================================
; ======= 1/ Registry accessors =============================
; ============================================================
; ============================================================

TestTimings_GetReturnsRawMs() {
    AssertEqual(3, TimingsGet("keylogger", "synth_match_delay_ms"), "keylogger.synth_match_delay_ms")
    AssertEqual(700, TimingsGet("gestures", "tap_max_ms"), "gestures.tap_max_ms")
    AssertEqual(500, TimingsGet("llm", "chain_fallback_ms"), "llm.chain_fallback_ms")
}
Test("Timings: TimingsGet returns the raw millisecond value", TestTimings_GetReturnsRawMs)

TestTimings_GetSecIsMsOver1000() {
    AssertEqual(2.0, TimingsGetSec("tap_hold", "one_shot_shift_timeout_ms"), "one_shot_shift sec")
    AssertEqual(0.7, TimingsGetSec("gestures", "tap_max_ms"), "tap_max sec")
}
Test("Timings: TimingsGetSec is exactly TimingsGet / 1000", TestTimings_GetSecIsMsOver1000)

TestTimings_GetFailsFast() {
    AssertThrows(() => TimingsGet("nope", "whatever_ms"), "unknown section throws")
    AssertThrows(() => TimingsGet("keylogger", "does_not_exist_ms"), "unknown key throws")
}
Test("Timings: TimingsGet fails fast on an unknown section/key", TestTimings_GetFailsFast)




; ============================================================
; ============================================================
; ======= 2/ Reassign-at-boot single source =================
; ============================================================
; ============================================================

TestTimings_KeyloggerWalkerSourced() {
    ; KLWConst started at sentinel 0; the loader must have replaced each with the
    ; canonical [keylogger] registry value.
    AssertEqual(5000, KLWConst.MAX_KEYSTROKE_DELAY_MS, "KLWConst.MAX_KEYSTROKE_DELAY_MS")
    AssertEqual(2000, KLWConst.THINK_PAUSE_MS, "KLWConst.THINK_PAUSE_MS")
    AssertEqual(1000, KLWConst.BURST_GAP_MS, "KLWConst.BURST_GAP_MS")
    AssertEqual(300000, KLWConst.SESSION_GAP_MS, "KLWConst.SESSION_GAP_MS")
    AssertEqual(50, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, "KLWConst.AUTO_REPEAT_MAX_DELAY_MS")
    AssertEqual(250, KLWConst.HOLD_THRESHOLD_MS, "KLWConst.HOLD_THRESHOLD_MS")
}
Test("Timings: keylogger-walker constants sourced from the registry", TestTimings_KeyloggerWalkerSourced)

TestTimings_TapHoldsSourced() {
    global TAP_MIN_DURATION_MS, KEY_REPEAT_INITIAL_DELAY_MS
    global KEY_REPEAT_INTERVAL_MS, ONE_SHOT_SHIFT_TIMEOUT_SEC
    AssertEqual(50, TAP_MIN_DURATION_MS, "TAP_MIN_DURATION_MS")
    AssertEqual(50, TapMinDurationMs(), "TapMinDurationMs() accessor")
    AssertEqual(300, KEY_REPEAT_INITIAL_DELAY_MS, "KEY_REPEAT_INITIAL_DELAY_MS")
    AssertEqual(100, KEY_REPEAT_INTERVAL_MS, "KEY_REPEAT_INTERVAL_MS")
    AssertEqual(2.0, ONE_SHOT_SHIFT_TIMEOUT_SEC, "ONE_SHOT_SHIFT_TIMEOUT_SEC")
}
Test("Timings: tap-hold constants sourced from the registry", TestTimings_TapHoldsSourced)

TestTimings_LlmApiSourced() {
    global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS, LLM_INSTALLED_CACHE_TTL_MS
    ; Reassign-at-boot loader; the registry was loaded at this file's top level.
    LLMApiLoadTimings()
    AssertEqual(50, LLM_OLLAMA_POLL_MS, "LLM_OLLAMA_POLL_MS")
    AssertEqual(30000, LLM_REMOTE_TIMEOUT_MS, "LLM_REMOTE_TIMEOUT_MS")
    AssertEqual(50, LLM_REMOTE_POLL_MS, "LLM_REMOTE_POLL_MS")
    AssertEqual(2000, LLM_INSTALLED_CACHE_TTL_MS, "LLM_INSTALLED_CACHE_TTL_MS")
}
Test("Timings: LLM api poll/timeout/cache sourced from the registry", TestTimings_LlmApiSourced)
