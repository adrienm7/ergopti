; tests/meta/test_llm_app_filter_enforced.ahk

; ==============================================================================
; MODULE: LLM disabled_apps Enforcement Meta Test
; DESCRIPTION:
; Static source guard for finding llm-app-filter-enforced (F-H04).
;
; The LLM "disabled apps" exclusion list (and the disable_url_bars flag) was fully
; configurable from the tray menu and round-tripped through TOML into _LLM_Engine,
; but LLM_Engine_FirePrediction never read it — so typed context was still sent to
; Ollama/the remote API even in apps the user explicitly excluded (a privacy
; breach: the macOS driver enforces this via app_filter.is_blocked). The fix adds a
; gate in the fire path that resolves the focused app (WIGetFocused) and returns
; without dispatching when it is on _LLM_Engine["disabled_apps"].
;
; Meta-static because modules/llm is not in the headless runner's include graph;
; it scans the function body via the move-resilient _DriverFuncBody helper.
; ==============================================================================

#Requires AutoHotkey v2.0


_LAFE_AssertDisabledAppsEnforced() {
	Body := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(Body != "", "LLM_Engine_FirePrediction(buffer) must exist")
	Gate := "if _LLM_Engine_ShouldSuppressForDisabledApps()`n`t`treturn"
	GatePos := InStr(Body, Gate, true)
	DispatchPreparationPos := InStr(Body, "backend_now :=", true)
	Assert(GatePos > 0,
		"LLM_Engine_FirePrediction must call the canonical disabled-app decision "
		. "and return immediately when it suppresses (llm-app-filter-enforced)")
	Assert(DispatchPreparationPos > 0 && GatePos < DispatchPreparationPos,
		"the disabled-app gate must run before any backend dispatch preparation")
}
Test("LLM: prediction is suppressed in user-disabled apps (llm-app-filter-enforced)", _LAFE_AssertDisabledAppsEnforced)
