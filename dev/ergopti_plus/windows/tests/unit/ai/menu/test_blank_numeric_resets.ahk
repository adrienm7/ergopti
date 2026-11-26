; tests/unit/ai/menu/test_blank_numeric_resets.ahk

; ==============================================================================
; MODULE: Blank Numeric Answer Resets Tests
; DESCRIPTION:
; The maintainer's decision PCK-13 of 21 November 2026: validating an empty
; numeric prompt resets the setting to its default on the three OS, as macOS
; did. Windows refused it as empty. The grammar itself is replayed from
; value_check_vectors.json (test_value_check_vectors.ahk); these cases drive
; the prompts that read it.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBNR_LlmPromptsReset() {
	Notices := [], Normalized := "sentinel"
	Notify := (Body, Title) => Notices.Push(Body)
	for Key, Declared in LLM_Option_IntegerDeclarations() {
		Expected := ManifestDefaultFor(Declared)
		AssertTrue(_LLM_Menu_TryNormalizeIntegerPrompt("OK", "  ", Key, &Normalized, Notify),
			"a blank " . Key . " is accepted")
		AssertEqual(Expected, Normalized, "a blank " . Key . " resets to its default")
	}
	AssertTrue(_LLM_Menu_TryNormalizeTemperaturePrompt("OK", "", &Normalized, Notify),
		"a blank temperature is accepted")
	AssertEqual(ManifestDefaultFor(ConfigKey.LLM_GENERATION_TEMPERATURE), Normalized,
		"a blank temperature resets to its default")
	AssertEqual(0, Notices.Length, "a reset is no refusal")
}
Test("numeric prompts: a blank LLM answer resets the setting to its default (pck-13-2026-11-21)",
	_TBNR_LlmPromptsReset)

; The other numeric prompts pass their setting's default to the shared grammar.
_TBNR_PromptsPassTheirDefault() {
	; The scanned source has its ConfigKey constants resolved to their paths.
	for Entry in [
		["PromptHotstringsIdleResetSeconds", "ManifestDefaultFor("],
		["PromptHotstringsBackspaceRestoreWindowMs", "ManifestDefaultFor("],
		["_HS_PromptDefaultDelay", "ManifestDefaultFor("],
		["_TH_PromptOneShotDelay", "ManifestDefaultFor("],
		["_TH_PromptGlobalDelay", "TAPHOLD_DEFAULT_ACTIVATION_SECONDS)"]] {
		Body := _DriverFuncBody(Entry[1])
		Parse := InStr(Body, "ValueCheckParseEntry(")
		AssertTrue(Parse > 0, Entry[1] . " reads the shared entry grammar")
		AssertTrue(InStr(Body, Entry[2], , Parse) > Parse, Entry[1] . " passes its default for a blank answer")
	}
}
Test("numeric prompts: every setting prompt passes its default for a blank answer (pck-13-2026-11-21)",
	_TBNR_PromptsPassTheirDefault)
