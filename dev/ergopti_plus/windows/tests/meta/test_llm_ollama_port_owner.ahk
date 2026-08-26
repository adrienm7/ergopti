; tests/meta/test_llm_ollama_port_owner.ahk

; ==============================================================================
; MODULE: Ollama Port Single-Owner Guard
; DESCRIPTION:
; Pins every production port boundary to the named semantic normalizer and
; proves boot consumes both the shared-default and HTTP-client receipts.
; ==============================================================================

#Requires AutoHotkey v2.0

_AHK022_AllPortBoundariesUseOneOwner() {
	Bodies := Map(
		"option", _DriverFuncBody("LLM_Option_TryNormalize"),
		"set_port", _DriverFuncBody("LLM_Ollama_SetPort"),
		"load_defaults", _DriverFuncBody("LLM_Ollama_LoadDefaults"),
		"shared_defaults", _DriverFuncBody("LLM_Menu_ApplySharedDefaults"),
		"prompt", _DriverFuncBody("LLM_Menu_PromptOllamaPort"),
		"prompt_boundary", _DriverFuncBody("_LLM_Menu_TryNormalizePortPrompt"),
		"prepare", _DriverFuncBody("_LLM_Menu_PrepareOllamaPortCandidate"),
		"boot_apply", _DriverFuncBody("_LLM_Menu_ApplyOllamaPortAtBoot"),
		"menu_init", _DriverFuncBody("LLM_Menu_Init"),
		"installer", _DriverFuncBody("LLM_Deps_RunInstaller"))
	for Name, Body in Bodies
		Assert(Body != "", "AHK-022 source guard must resolve " . Name)

	for Name in ["option", "set_port", "load_defaults", "shared_defaults",
			"prompt_boundary", "prepare", "boot_apply"]
		AssertContains(Bodies[Name], "LLM_Option_TryNormalizeOllamaPort(",
			Name . " must delegate to the canonical port boundary")
	AssertContains(Bodies["prompt"], "_LLM_Menu_TryNormalizePortPrompt(",
		"the native prompt must delegate to the behavior-tested feedback boundary")

	for Name in ["set_port", "prompt", "prepare"] {
		AssertFalse(InStr(Bodies[Name], "< 1024") > 0,
			Name . " must not redeclare the lower port bound")
		AssertFalse(InStr(Bodies[Name], "> 65535") > 0,
			Name . " must not redeclare the upper port bound")
	}
	AssertContains(Bodies["menu_init"], "_LLM_Menu_ApplyOllamaPortAtBoot(",
		"the real menu boot path must consume the strict setter receipt")
	Source := _DriverSourceNoComments()
	Assert(Source != "", "AHK-022 boot guard must inspect a non-empty source")
	AssertContains(Source, "if !LLM_Ollama_LoadDefaults()",
		"driver boot must fail fast when the shared defaults are rejected")
	AssertContains(Bodies["installer"], "LLM_OLLAMA_BASE_URL",
		"poll diagnostics must report the configured endpoint")
	AssertFalse(InStr(Bodies["installer"], "localhost:11434") > 0,
		"poll diagnostics must not lie after a custom port publication")
}
Test("AHK-022 Ollama port: every producer consumes one boundary "
	. "(ahk-022-ollama-port-boundary)",
	_AHK022_AllPortBoundariesUseOneOwner)
