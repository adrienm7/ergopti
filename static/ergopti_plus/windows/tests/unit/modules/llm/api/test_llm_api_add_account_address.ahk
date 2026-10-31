; tests/unit/modules/llm/api/test_llm_api_add_account_address.ahk

; ==============================================================================
; MODULE: Per-Account API Address (Windows)
; DESCRIPTION:
; A provider whose address names the user's account (Azure resource, AWS
; region, Cloudflare account id, Databricks workspace, Snowflake account)
; writes a template in api_providers.json. The actual four-step form asks the
; placeholder's value in place of the URL, stores the filled address and needs
; a model; the catalogue loader accepts the row without a default model; the
; request resolver refuses an entry still holding the template. macOS and
; Linux pin the same behaviour (test_api_panel_account_address.lua,
; test_api_account_address.lua). Reuses _WAA_Form of test_llm_api_add_production.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ The add-entry form ===========
; =========================================
; =========================================

/**
 * The production form fixture with a template provider added to the catalogue;
 * Restore puts the original catalogue back.
 * @param {Array} Answers The provider id, the resource, the key and the model.
 * @returns {_WAA_Form}
 */
_LAAA_Form(Answers) {
	global LLM_API_PROVIDERS
	Form := _WAA_Form("openai")
	Providers := LLM_Menu_DeepClone(LLM_API_PROVIDERS)
	Providers["azure"] := Map("Label", "Azure OpenAI", "BaseUrl", "https://{resource}.openai.azure.com/openai/v1",
		"DefaultModel", "", "Format", "openai", "ModelExtras", Map(), "ThinkingDialect", Map())
	LLM_API_PROVIDERS := Providers
	Form.Answers := Answers
	return Form
}

_LAAA_Filled() {
	global _LLM_Menu
	Form := _LAAA_Form(["azure", "  contoso  ", " azure key ", "  my-deployment  "])
	try {
		AssertTrue(Form.Run(), "the form saves the filled address")
		AssertEqual(4, Form.Inputs.Length, "provider, resource, key and model: no URL prompt")
		AssertEqual(t("menu.llm.api_prompt_field.resource"), Form.Inputs[2]["prompt"])
		AssertEqual("", Form.Inputs[2]["default"])
		AssertContains(Form.Inputs[3]["options"], "Password", "the key stays masked")
		AssertEqual("", Form.Inputs[4]["default"], "no catalogue default model")
		Saved := _LLM_Menu["api_entries"][3]
		AssertEqual("azure", Saved["Provider"])
		AssertEqual("https://contoso.openai.azure.com/openai/v1", Saved["BaseUrl"])
		AssertEqual("my-deployment", Saved["Model"])
		Resolved := _LLMRemoteResolveEntry(Saved)
		AssertTrue(Resolved is Map, "the filled entry resolves")
		AssertEqual("https://contoso.openai.azure.com/openai/v1", Resolved["BaseUrl"])
		AssertEqual(0, Form.Notices.Length)
	} finally Form.Restore()
}
Test("Windows API Add: a per-account provider asks its resource and stores the filled address", _LAAA_Filled)

_LAAA_Refused(Answers, Reason) {
	Form := _LAAA_Form(Answers)
	try {
		AssertFalse(Form.Run(), Reason)
		Form.AssertNoSave()
		AssertEqual(1, Form.Notices.Length, Reason . ": one notice")
	} finally Form.Restore()
}
Test("Windows API Add: a value that would change the host is refused",
	_LAAA_Refused.Bind(["azure", "evil.example/x?", "k", "m"], "a slash or a query cannot fill the address"))
Test("Windows API Add: a per-account provider needs a model",
	_LAAA_Refused.Bind(["azure", "contoso", "k", "   "], "no model defaults"))





; =========================================
; =========================================
; ======= 2/ Catalogue and requests =======
; =========================================
; =========================================

_LAAA_Catalogue() {
	Row := Map("label", "Azure OpenAI", "base_url", "https://{resource}.openai.azure.com/openai/v1",
		"default_model", "", "format", "openai")
	AssertTrue(_LLMRemote_CatalogDescriptorIsValid("azure", Row), "a template row needs no default model")
	Row["base_url"] := "https://api.example.com/v1"
	AssertFalse(_LLMRemote_CatalogDescriptorIsValid("azure", Row), "a fixed address still needs one")
	Row["base_url"] := "https://{Resource}.example.com/v1"
	AssertFalse(_LLMRemote_CatalogDescriptorIsValid("azure", Row), "a brace outside a {name} placeholder")
}
Test("Windows API catalogue: a per-account row loads without a default model", _LAAA_Catalogue)

_LAAA_Unfilled() {
	global LLM_API_PROVIDERS
	Prior := LLM_API_PROVIDERS
	try {
		Providers := LLM_Menu_DeepClone(LLM_API_PROVIDERS)
		Providers["azure"] := Map("Label", "Azure OpenAI", "BaseUrl", "https://{resource}.openai.azure.com/openai/v1",
			"DefaultModel", "", "Format", "openai", "ModelExtras", Map(), "ThinkingDialect", Map())
		LLM_API_PROVIDERS := Providers
		AssertEqual("", _LLMRemoteResolveEntry(Map("Provider", "azure", "BaseUrl", "", "Token", "k", "Model", "m")),
			"an entry without its filled address is never sent")
	} finally LLM_API_PROVIDERS := Prior
}
Test("Windows API requests: an unfilled per-account address is refused", _LAAA_Unfilled)
