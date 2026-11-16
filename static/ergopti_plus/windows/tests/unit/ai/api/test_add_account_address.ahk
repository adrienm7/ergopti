; tests/unit/ai/api/test_add_account_address.ahk

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
; test_api_account_address.lua). Reuses _WAA_Form of test_add_production.ahk.
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

; DashScope keeps its address; the optional field replaces it, on the real catalogue row.
_LAAA_OptionalForm(Field) {
	Form := _WAA_Form("dashscope")
	Form.Answers := ["dashscope", Field, "key", "qwen3.8-flash"]
	return Form
}

_LAAA_OptionalFilled() {
	global _LLM_Menu
	Form := _LAAA_OptionalForm("  ws-1.ap-southeast-1.maas.aliyuncs.com ")
	try {
		AssertTrue(Form.Run(), "the form saves the workspace address")
		AssertEqual(4, Form.Inputs.Length, "provider, domain, key and model: no URL prompt")
		AssertEqual(t("menu.llm.api_prompt_field.workspace_domain"), Form.Inputs[2]["prompt"])
		AssertEqual("", Form.Inputs[2]["default"], "the field is optional and starts empty")
		Saved := _LLM_Menu["api_entries"][3]
		AssertEqual("https://ws-1.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1", Saved["BaseUrl"])
		AssertEqual(Saved["BaseUrl"], _LLMRemoteResolveEntry(Saved)["BaseUrl"], "requests go to the workspace")
	} finally Form.Restore()
}
Test("Windows API Add: the optional workspace domain replaces the address", _LAAA_OptionalFilled)

_LAAA_OptionalEmpty() {
	global _LLM_Menu, LLM_API_PROVIDERS
	Form := _LAAA_OptionalForm("   ")
	try {
		AssertTrue(Form.Run(), "an empty field is no refusal")
		Saved := _LLM_Menu["api_entries"][3]
		AssertEqual(LLM_API_PROVIDERS["dashscope"]["BaseUrl"], _LLMRemoteResolveEntry(Saved)["BaseUrl"],
			"the default stays the shared address")
		AssertContains(LLM_API_PROVIDERS["dashscope"]["BaseUrl"], "dashscope-intl", "the maintainer's default")
	} finally Form.Restore()
}
Test("Windows API Add: an empty workspace domain keeps the catalogue address", _LAAA_OptionalEmpty)

_LAAA_OptionalRefused() {
	Form := _LAAA_OptionalForm("evil.example")
	try {
		AssertFalse(Form.Run(), "another host is refused")
		Form.AssertNoSave()
		AssertEqual(1, Form.Notices.Length, "one notice")
		AssertContains(Form.Notices[1], ".maas.aliyuncs.com", "it says what the domain must end with")
	} finally Form.Restore()
}
Test("Windows API Add: the workspace domain must be a host of the provider", _LAAA_OptionalRefused)

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





; =========================================
; =========================================
; ======= 3/ Access-token providers =======
; =========================================
; =========================================

; A provider declaring an auth block is added like any other per-account provider;
; its key is exchanged for an access token (test_token_exchange.ahk), and
; the stored key itself is never sent. A pasted credentials file fits one line.
_LAAA_TokenExchange() {
	global LLM_API_PROVIDERS, _LLM_Menu
	Form := _WAA_Form("openai")
	try {
		Providers := LLM_Menu_DeepClone(LLM_API_PROVIDERS)
		Providers["vertex_fixture"] := LLM_Menu_DeepClone(LLM_API_PROVIDERS["vertex"])
		Providers["vertex_fixture"]["BaseUrl"] := "https://{region}.fixture.invalid/v1"
		LLM_API_PROVIDERS := Providers
		Form.Answers := ["vertex_fixture", "us-south", '{`r`n"type": "authorized_user",`n"client_id": "id"`n}', "m"]
		AssertTrue(Form.Run(), "the form saves the provider")
		AssertEqual(4, Form.Inputs.Length, "provider, account field, key and model")
		AssertEqual(0, Form.Notices.Length, "no refusal")
		Saved := _LLM_Menu["api_entries"][3]
		AssertEqual("https://us-south.fixture.invalid/v1", Saved["BaseUrl"])
		AssertEqual('{"type": "authorized_user","client_id": "id"}', Saved["Token"], "the key file on one line")
		AssertEqual(1, Form.Ready.Length, "the save validates the key")
		Resolved := _LLMRemoteResolveEntry(Saved)
		AssertTrue(Resolved is Map, "the entry is usable")
		AssertEqual("", Resolved["Token"], "the stored key is never sent as Bearer")
	} finally Form.Restore()
}
Test("Windows API Add: an access-token provider is saved with its key on one line", _LAAA_TokenExchange)

#Include test_rs256_signer.ahk
#Include test_token_exchange.ahk
