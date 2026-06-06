; static/ergopti_plus/windows/tests/test_llm_menu_regressions.ahk
;
; Non-regression guards for fixed LLM tray/menu bugs (AHK). Each test maps to
; an incident in the persistence workstream; keep in sync with
; macos/tests/unit/menu/test_llm_menu_regressions.lua where applicable.

; ============================================
; Shared helpers (reuse persistence test utils when loaded after persist.ahk)
; ============================================

_LLM_Regress_FrameworkPath() {
	return A_ScriptDir . "\test_framework.ahk"
}

_LLM_Regress_MenuModelsPath() {
	return A_ScriptDir . "\..\ui\tray_llm\menu_models.ahk"
}

_LLM_Regress_MenuSettingsPath() {
	return A_ScriptDir . "\..\ui\tray_llm\menu_settings.ahk"
}

_LLM_Regress_ActionsPath() {
	return A_ScriptDir . "\..\ui\tray_llm\actions.ahk"
}

_LLM_Regress_PersistPath() {
	return A_ScriptDir . "\..\ui\tray_llm\persist.ahk"
}

_LLM_Regress_RecordN(n) {
	global _LLM_Regress_LastN
	_LLM_Regress_LastN := n
}

; Production-equivalent factory (must match menu_models.ahk _LLM_Tray_MakeSetNHandler).
_LLM_Regress_MakeSetNHandler(n) {
	return (name, pos, menu) => _LLM_Regress_RecordN(n)
}

; Broken AHK v2 pattern: ``captured := n`` inside a for-loop does not scope per iteration.
_LLM_Regress_MakeBadNHandlers() {
	handlers := []
	for n in [1, 3, 10] {
		captured := n
		handlers.Push((*) => _LLM_Regress_RecordN(captured))
	}
	return handlers
}




; ============================================
; 1/ test_framework — _AHK_DRY_RUN + callback.Call()
; ============================================

Test_LLM_Regression_FrameworkInitializesDryRun() {
	body := FileRead(_LLM_Regress_FrameworkPath(), "UTF-8")
	AssertContains(body, "if !IsSet(_AHK_DRY_RUN)",
		"test_framework must default _AHK_DRY_RUN when unset (isolated runners)")
	AssertContains(body, "global _AHK_DRY_RUN := false",
		"test_framework must assign false when _AHK_DRY_RUN is missing")
}
Test("LLM regression: test_framework defaults _AHK_DRY_RUN when unset",
	Test_LLM_Regression_FrameworkInitializesDryRun)

Test_LLM_Regression_RunTestsGuardsDryRun() {
	body := FileRead(_LLM_Regress_FrameworkPath(), "UTF-8")
	AssertContains(body, "RunTests()",
		"RunTests must exist")
	; Second guard inside RunTests (run_llm_menu_persistence used to crash here).
	Assert(InStr(body, "if !IsSet(_AHK_DRY_RUN)") >= 2,
		"RunTests must re-check IsSet(_AHK_DRY_RUN) before use")
}
Test("LLM regression: RunTests re-guards _AHK_DRY_RUN",
	Test_LLM_Regression_RunTestsGuardsDryRun)

Test_LLM_Regression_FrameworkUsesCallbackCall() {
	body := FileRead(_LLM_Regress_FrameworkPath(), "UTF-8")
	AssertContains(body, "TestEntry.callback.Call()",
		"runner must invoke tests via .Call() (AHK v2 Func objects)")
	Assert(!InStr(body, "TestEntry.callback()"),
		"runner must not use TestEntry.callback() — causes Too many parameters")
}
Test("LLM regression: test runner invokes callbacks with .Call()",
	Test_LLM_Regression_FrameworkUsesCallbackCall)

Test_LLM_Regression_IsolatedRunnerSetsDryRun() {
	body := FileRead(A_ScriptDir . "\run_llm_menu_persistence.ahk", "UTF-8")
	AssertContains(body, "global _AHK_DRY_RUN := false",
		"run_llm_menu_persistence must predeclare _AHK_DRY_RUN")
}
Test("LLM regression: isolated LLM runner predeclares _AHK_DRY_RUN",
	Test_LLM_Regression_IsolatedRunnerSetsDryRun)




; ============================================
; 2/ persist.ahk — val_modifiers comma-separated round-trip
; ============================================

Test_LLM_Regression_ValModifiersAltCtrlRoundTrip() {
	global _LLM_Tray, Features
	Features := _LLM_Persist_CloneFeatures(Features)
	_LLM_Tray := _LLM_Persist_MakeDefaultTray()
	_LLM_Tray["val_modifiers"] := "alt,ctrl"

	_LLM_Tray_SyncToFeatures()
	got := Features["llm"]["navigation"]["val_modifiers"]
	Assert(_LLM_Persist_ValuesEqual(["alt", "ctrl"], got, Map("toml_array", true)),
		"Sync must split alt,ctrl into a two-element array")

	updates := _LLM_Persist_CollectUpdates()
	path := A_Temp . "\ergopti_llm_regress_val_mods.toml"
	TOML_BatchWrite(path, updates)
	cache := ParseTomlFile(path)
	opts := LLM_Tray_BuildSavedOpts(cache)
	Assert(_LLM_Persist_ValuesEqual("alt,ctrl", opts["val_modifiers"], Map("toml_array", true)),
		"BuildSavedOpts must reload alt,ctrl from TOML cache, not a single token")
}
Test("LLM regression: val_modifiers alt,ctrl round-trips via cache",
	Test_LLM_Regression_ValModifiersAltCtrlRoundTrip)




; ============================================
; 3/ actions.ahk — no nested #Include persist.ahk
; ============================================

Test_LLM_Regression_PersistWiringUsesPersistAhk() {
	AssertEqual(_LLM_Persist_PersistSource(), _LLM_Regress_PersistPath(),
		"persistence tests must read ui/tray_llm/persist.ahk, not actions.ahk")
	body := FileRead(_LLM_Regress_ActionsPath(), "UTF-8")
	Assert(!InStr(body, "#Include tray_llm/persist.ahk", false),
		"actions.ahk must not #Include tray_llm/persist.ahk")
}
Test("LLM regression: persist wiring lives in persist.ahk only",
	Test_LLM_Regression_PersistWiringUsesPersistAhk)




; ============================================
; 4/ menu — AHK v2 for-loop closure (N suggestions always 10)
; ============================================

Test_LLM_Regression_MenuModelsDocumentsClosureFix() {
	body := FileRead(_LLM_Regress_MenuModelsPath(), "UTF-8")
	AssertContains(body, "_LLM_Tray_MakeSetNHandler(n)",
		"menu_models must expose per-N factory")
	AssertContains(body, "AHK v2 closes over outer-scope variables by reference",
		"menu_models must document the closure pitfall")
}
Test("LLM regression: menu_models documents and exposes MakeSetNHandler",
	Test_LLM_Regression_MenuModelsDocumentsClosureFix)

Test_LLM_Regression_MenuSettingsUsesNHandlerFactory() {
	body := FileRead(_LLM_Regress_MenuSettingsPath(), "UTF-8")
	AssertContains(body, "_LLM_Tray_MakeSetNHandler(n)",
		"menu_settings must register N handlers via factory, not bare loop closure")
	Assert(!RegExMatch(body, "i)for\s+n\s+in\s+LLM_TRAY_N_OPTIONS[^\n]*\n[^\n]*\(\*\)\s*=>\s*LLM_Tray_SetN\(n\)"),
		"menu_settings must not bind LLM_Tray_SetN(n) inline inside the N loop")
}
Test("LLM regression: menu_settings wires N via _LLM_Tray_MakeSetNHandler",
	Test_LLM_Regression_MenuSettingsUsesNHandlerFactory)

Test_LLM_Regression_MakeSetNHandlerCapturesEachN() {
	global _LLM_Regress_LastN
	good := []
	for n in [1, 3, 10]
		good.Push(_LLM_Regress_MakeSetNHandler(n))
	loop good.Length {
		_LLM_Regress_LastN := -1
		expected := [1, 3, 10][A_Index]
		good[A_Index].Call("", 0, "")
		AssertEqual(expected, _LLM_Regress_LastN,
			"factory handler " . A_Index . " must capture its own n")
	}

	bad := _LLM_Regress_MakeBadNHandlers()
	loop bad.Length
		bad[A_Index].Call("", 0, "")
	AssertEqual(10, _LLM_Regress_LastN,
		"bad captured:= pattern must leave all handlers at last loop value (10)")
}
Test("LLM regression: MakeSetNHandler captures 1/3/10 not last N only",
	Test_LLM_Regression_MakeSetNHandlerCapturesEachN)