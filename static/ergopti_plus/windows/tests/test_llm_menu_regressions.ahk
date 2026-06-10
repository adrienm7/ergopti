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




; ============================================
; 5/ profile labels - printf token never leaks into the menu
; ============================================
;
; THE BUG: the "Batch Advanced" profile label leaked a literal "%d prediction%s"
; into the menu. The locale string carried printf "%d"/"%s" tokens, but the menu
; substitutes brace "{n}"/"{s}" placeholders (LLM_Tray_GetProfileLabel) - so the
; printf tokens were never replaced and showed verbatim. Mirrors the Hammerspoon
; guards in macos/tests/unit/lib/test_locale_profile_labels.lua and
; macos/tests/unit/menu/test_profile_label.lua.

; Resolves ergopti_plus/shared/locales from A_ScriptDir (= windows/tests when the
; suite is #Include-d by run_all.ahk). Same derivation as test_locale_json_valid.
_LLMPL_LocaleDir() {
	SplitPath(A_ScriptDir, , &DriverDir)   ; -> windows
	SplitPath(DriverDir, , &EpDir)         ; -> ergopti_plus
	return EpDir . "\shared\locales"
}

; Key matches the dot-notation profile label keys (llm.profile.<id>.label).
_LLMPL_IsProfileLabelKey(Key) {
	return RegExMatch(Key, "^llm\.profile\.[\w]+\.label$") > 0
}

; Scans every locale file for printf tokens in profile labels. Returns a newline
; list of "<locale>:<key>" offenders (empty string when all clean) plus the count
; of files scanned, so the test can also fail if enumeration found nothing.
_LLMPL_ScanPrintfLeaks(&FilesScanned) {
	global _I18nCache
	Offenders   := ""
	FilesScanned := 0
	Loop Files, _LLMPL_LocaleDir() . "\*.json" {
		FilesScanned += 1
		LocaleName := A_LoopFileName
		_I18nLoadFile(A_LoopFileFullPath)
		for Key, Val in _I18nCache {
			if !_LLMPL_IsProfileLabelKey(Key)
				continue
			if (Type(Val) != "String")
				continue
			if (InStr(Val, "%d") || InStr(Val, "%s") || InStr(Val, "%i"))
				Offenders .= LocaleName . ":" . Key . "  ->  " . Val . "`n"
		}
	}
	return Offenders
}

Test_LLM_Regression_NoPrintfTokenInProfileLabels() {
	FilesScanned := 0
	Offenders := _LLMPL_ScanPrintfLeaks(&FilesScanned)
	Assert(FilesScanned >= 21,
		"expected at least 21 locale files scanned, got " . FilesScanned)
	Assert(Offenders == "",
		"printf token(s) leaked into profile label(s) - locale labels must use "
		. "{n}/{s}, not %d/%s:`n" . Offenders)
}
Test("LLM regression: no printf %d/%s token in any locale profile label",
	Test_LLM_Regression_NoPrintfTokenInProfileLabels)

Test_LLM_Regression_BatchLabelKeepsBracePlaceholders() {
	global _I18nCache
	Missing := ""
	Scanned := 0
	Loop Files, _LLMPL_LocaleDir() . "\*.json" {
		Scanned += 1
		LocaleName := A_LoopFileName
		_I18nLoadFile(A_LoopFileFullPath)
		Key := "llm.profile.batch_advanced.label"
		Val := _I18nCache.Has(Key) ? _I18nCache[Key] : ""
		if (Type(Val) != "String" || Val == "")
			Missing .= LocaleName . ": absent`n"
		else if (!InStr(Val, "{n}") || !InStr(Val, "{s}"))
			Missing .= LocaleName . ": " . Val . "`n"
	}
	Assert(Scanned >= 21, "expected at least 21 locale files, got " . Scanned)
	Assert(Missing == "",
		"batch_advanced label must keep {n} and {s} in every language:`n" . Missing)
}
Test("LLM regression: batch_advanced label keeps {n}/{s} in all locales",
	Test_LLM_Regression_BatchLabelKeepsBracePlaceholders)

; Source guard: LLM_Tray_GetProfileLabel must substitute the brace placeholders.
; If a refactor swaps back to Format()/%d the locale strings stop matching and the
; "%d prediction%s" leak returns - this pins the substitution convention at source.
Test_LLM_Regression_GetProfileLabelUsesBraceSubstitution() {
	body := FileRead(A_ScriptDir . "\..\ui\tray_llm\menu_profiles.ahk", "UTF-8")
	AssertContains(body, '"{n}"',
		"LLM_Tray_GetProfileLabel must StrReplace the {n} placeholder")
	AssertContains(body, '"{s}"',
		"LLM_Tray_GetProfileLabel must StrReplace the {s} placeholder")
	Assert(!InStr(body, 'Format(t("llm.profile.batch_advanced.label")'),
		"profile label must not be routed through Format()/%d - use {n}/{s} StrReplace")
}
Test("LLM regression: GetProfileLabel substitutes {n}/{s}, not printf tokens",
	Test_LLM_Regression_GetProfileLabelUsesBraceSubstitution)

; Behavioural contract: the production substitution (the exact StrReplace pair from
; LLM_Tray_GetProfileLabel) applied to the REAL locale label must leave no leftover
; placeholder of EITHER convention. Synthetic ASCII label covers the plural logic;
; the real fr label covers the end-to-end reproduction (kept ASCII-safe: we only
; assert the count appears and that no token survives, never the translated word).
_LLMPL_FormatBrace(Label, N) {
	S := (N > 1) ? "s" : ""
	return StrReplace(StrReplace(Label, "{n}", N), "{s}", S)
}

Test_LLM_Regression_BraceSubstitutionLeavesNoPlaceholder() {
	; Synthetic plural/singular behaviour.
	AssertEqual("2 items", _LLMPL_FormatBrace("{n} item{s}", 2))
	AssertEqual("1 item",  _LLMPL_FormatBrace("{n} item{s}", 1))

	; Real fr label, end to end - no leftover token, count present.
	global _I18nCache
	_I18nLoadFile(_LLMPL_LocaleDir() . "\fr.json")
	Key := "llm.profile.batch_advanced.label"
	Assert(_I18nCache.Has(Key), "fr.json must define " . Key)
	Label := _I18nCache[Key]

	OutPlural := _LLMPL_FormatBrace(Label, 5)
	Assert(InStr(OutPlural, "5") > 0, "count 5 must appear in: " . OutPlural)
	Assert(!InStr(OutPlural, "{n}") && !InStr(OutPlural, "{s}"),
		"brace placeholder leaked: " . OutPlural)
	Assert(!InStr(OutPlural, "%d") && !InStr(OutPlural, "%s"),
		"printf placeholder leaked: " . OutPlural)

	OutSingular := _LLMPL_FormatBrace(Label, 1)
	Assert(InStr(OutSingular, "1") > 0, "count 1 must appear in: " . OutSingular)
	Assert(!InStr(OutSingular, "{n}") && !InStr(OutSingular, "{s}"),
		"brace placeholder leaked (singular): " . OutSingular)
}
Test("LLM regression: brace substitution on real label leaves no placeholder",
	Test_LLM_Regression_BraceSubstitutionLeavesNoPlaceholder)