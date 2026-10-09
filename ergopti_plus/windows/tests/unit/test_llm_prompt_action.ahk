; static/ergopti_plus/windows/tests/unit/test_llm_prompt_action.ahk

; ==============================================================================
; MODULE: llm_prompt Parameter of llm_prompt_prediction (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/action_parameters/llm_prompt_vectors.json, which
; the shared Lua module, the Linux and macOS suites and the action picker page
; replay too, through modules/llm/prompt_action.ahk AND through the real binding
; validator (GestureValidateActionParameter), so the value a binding stores is
; judged by the same rules everywhere it can be typed.
;
; ROOT CAUSE ENCODED:
; The binding editor threw "No validator for parameter kind" on a kind it did
; not know, so a prompt-choosing action could not be bound at all on Windows.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Shared corpus (llm_prompt_vectors) =======
; =====================================================
; =====================================================

_LPA_Vectors() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\action_parameters\llm_prompt_vectors.json"
	AssertTrue(FileExist(Path) != "", "the llm_prompt corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))["vectors"]
}

_LPA_ReplayCorpus() {
	AssertEqual("llm_prompt", GestureActionParameterSpec("llm_prompt_prediction"),
		"llm_prompt_prediction parameter kind")
	Checked := 0
	for Vector in _LPA_Vectors() {
		Valid := !Vector.Has("valid") || Vector["valid"]
		Parsed := LLM_PromptAction_Parse(Vector["value"], &Reason)
		ErrorText := ""
		AssertEqual(Valid ? true : false,
			GestureValidateActionParameter("llm_prompt_prediction", Vector["value"], &ErrorText) ? true : false,
			Vector["id"] . ": the binding validator")
		if Valid {
			AssertTrue(Parsed is Map, Vector["id"] . ": a valid value parses")
			AssertEqual(Vector["profile_id"], Parsed["profile_id"], Vector["id"] . ": profile_id")
			AssertEqual(Vector.Get("translation_target", ""), Parsed.Get("translation_target", ""),
				Vector["id"] . ": target receipt")
			if Vector.Has("num_predictions")
				AssertEqual(Vector["num_predictions"], Parsed.Get("num_predictions", 0),
					Vector["id"] . ": num_predictions")
			else
				AssertFalse(Parsed.Has("num_predictions"),
					Vector["id"] . ": no count of its own means the AI menu's count")
			AssertEqual(Vector["value"], LLM_PromptAction_Format(Parsed["profile_id"],
				Parsed.Get("num_predictions", 0), Parsed.Get("translation_target", "")), Vector["id"] . ": format round-trips")
		} else {
			AssertFalse(Parsed is Map, Vector["id"] . ": an invalid value is refused")
			AssertTrue(Reason != "", Vector["id"] . ": a refusal names its reason")
			AssertEqual(t("dialog.gestures.param_err_llm_prompt"), ErrorText,
				Vector["id"] . ": the binding editor shows the llm_prompt refusal")
		}
		Checked += 1
	}
	AssertTrue(Checked >= 19, "expected at least 19 llm_prompt vectors, found " . Checked)
}
Test("llm_prompt: the parameter replays the shared corpus", _LPA_ReplayCorpus)

; PCRE's $ matches before a final line break; the shared pattern does not.
_LPA_TrailingLineBreakRefused() {
	AssertFalse(LLM_PromptAction_IsValid("rewrite`n"), "a trailing line break is not part of an id")
	AssertFalse(LLM_PromptAction_IsValid("rewrite|3`n"), "nor of a count")
	AssertTrue(LLM_PromptAction_IsValid("rewrite|0003"), "leading zeros are still digits")
	AssertEqual(3, LLM_PromptAction_Parse("rewrite|03")["num_predictions"], "and keep the value")
	AssertFalse(LLM_PromptAction_IsValid("rewrite|100"), "three significant digits are out of range")
	AssertFalse(LLM_PromptAction_IsValid("rewrite|99999999999999999999999"),
		"a count too long for an integer is out of range, not an overflow")
	AssertFalse(LLM_PromptAction_IsValid(3), "a non-string value is refused")
	AssertThrows(() => LLM_PromptAction_Format("my prompt"), "Format refuses an invalid id")
}
Test("llm_prompt: anchors and counts cannot be fooled", _LPA_TrailingLineBreakRefused)





; ======================================================
; ======================================================
; ======= 2/ The native prompt lists the prompts =======
; ======================================================
; ======================================================

_LPA_NativePromptListsEveryPrompt() {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER
	Saved := _LLM_Menu
	_LLM_Menu := Saved.Clone()
	try {
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["user_profiles"] := [Map("id", "user_mon-prompt_1", "label", "Mon prompt",
			"system_single", "x", "batch", false)]
		Choices := LLM_Menu_PromptChoices()
		AssertEqual(LLM_PROFILE_BUILTIN_ORDER.Length + 1, Choices.Length,
			"the built-ins then the custom prompts")
		for Index, Id in LLM_PROFILE_BUILTIN_ORDER
			AssertEqual(Id, Choices[Index]["value"], "built-ins come first, in menu order")
		AssertEqual("user_mon-prompt_1", Choices[Choices.Length]["value"], "the custom prompt comes last")
		AssertEqual(t("llm.profile.rewrite.label"), LLM_Menu_GetProfileLabel("rewrite"),
			"the rewrite built-in is labelled like the others")
		Prompt := GestureActionParameterPrompt("llm_prompt_prediction")
		AssertContains(Prompt, "rewrite — " . t("llm.profile.rewrite.label"),
			"the native prompt shows each id with its menu label")
		AssertContains(Prompt, "user_mon-prompt_1 — Mon prompt", "custom prompts are listed too")
		AssertFalse(InStr(Prompt, "{1}") > 0, "the placeholder is filled")
	} finally {
		_LLM_Menu := Saved
	}
}
Test("llm_prompt: the native prompt lists every prompt with its menu label",
	_LPA_NativePromptListsEveryPrompt)
