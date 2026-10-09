; tests/unit/test_local_server_auth.ahk

; ==============================================================================
; MODULE: Local API Optional Authentication Tests
; DESCRIPTION:
; Independent shared receipts and the actual provider resolver, curl config and
; private-entry serializer keep optional authentication catalogue-owned.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Independent Shared Policy =======
; ============================================
; ============================================

_LSA_SharedCorpus() {
	global _SharedDir
	Root := JsonParse(FileRead(_SharedDir . "\modules\llm\local_servers.json", "UTF-8"))
	Catalogue := LocalServerAuthCatalogue(Root, Map("openai", true, "openai_compat", true))
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\local_server_auth.json", "UTF-8"))
	AssertEqual(4, Catalogue["order"].Length, "the four actual descriptors own optional authentication")
	AssertEqual(42, Corpus["auth_cases"].Length, "the independent credential corpus stays complete")
	AssertEqual(16, Corpus["models_cases"].Length, "the independent models corpus stays complete")
	for Vector in Corpus["auth_cases"]
		AssertEqual(Vector["allowed"], LocalServerAuthTokenAllowed(Vector["provider"], Vector["token"], Catalogue["servers"]), Vector["name"])
	for Vector in Corpus["models_cases"] {
		Ids := LocalServerAuthModelsReceipt(Vector["response"])
		AssertEqual(Vector["admitted"], Ids is Array, Vector["name"])
		if Ids is Array {
			AssertEqual(Vector["models"].Length, Ids.Length, Vector["name"])
			for Index, Id in Ids
				AssertEqual(Vector["models"][Index], Id, Vector["name"])
		}
	}
	Root["servers"]["openai"] := Map("label", "Cloud", "base_url", "http://127.0.0.1:1/v1", "auth", "optional")
	Root["server_order"].Push("openai")
	AssertFalse(LocalServerAuthCatalogue(Root, Map("openai", true))["servers"].Has("openai"), "cloud identities cannot acquire a local capability")
}
Test("local API authentication: independent cross-driver credential and models corpus", _LSA_SharedCorpus)





; ==========================================
; ==========================================
; ======= 2/ Actual Native Consumers =======
; ==========================================
; ==========================================

_LSA_ResolverAndPrivateRestart() {
	global LLM_LOCAL_API_SERVERS
	for Id in ["omlx", "lmstudio", "llamacpp", "jan"] {
		AssertTrue(LLM_LOCAL_API_SERVERS.Has(Id), "actual provider boot publishes the shared local capability")
		Entry := Map("Id", "local_" . Id, "Name", Id, "Provider", Id, "BaseUrl", "http://127.0.0.1:19273/v1", "Token", "", "Model", "fixture-model")
		Resolved := _LLMRemoteResolveEntry(Entry)
		AssertTrue(Resolved is Map, "an explicitly keyless known local entry resolves")
		AssertEqual(Entry["BaseUrl"], Resolved["BaseUrl"], "a configured custom URL remains authoritative")
		Config := _LLMRemote_BuildCurlConfig(Resolved["Format"], Resolved["Token"], _LLMRemoteBuildUrl(Resolved["BaseUrl"], Resolved["Format"], "", Resolved["Model"]))
		AssertFalse(InStr(Config, "Authorization:"), "empty credentials never become a blank Bearer header")
		Image := _LLM_Menu_SerializeApiEntries(Map("api_entries", [Entry]))
		Restarted := _LLM_Menu_ParseAndValidateApiEntries(Image)
		AssertTrue(Restarted["ok"], "the actual private-store reader accepts the saved keyless entry")
		Restarted := Restarted["entries"]
		AssertEqual("", Restarted[1]["Token"])
		AssertEqual(Entry["BaseUrl"], Restarted[1]["BaseUrl"])
		AssertTrue(_LLMRemoteResolveEntry(Restarted[1]) is Map)
	}
	for Id in ["openai", "openai_compat", "unknown-provider"]
		AssertEqual("", _LLMRemoteResolveEntry(Map("Provider", Id, "BaseUrl", "http://127.0.0.1:19273/v1", "Token", "", "Model", "fixture-model")), "empty cloud, generic and unknown credentials remain refused")
	Secret := " leading-and-trailing "
	Resolved := _LLMRemoteResolveEntry(Map("Provider", "lmstudio", "BaseUrl", "http://127.0.0.1:19273/v1", "Token", Secret, "Model", "fixture-model"))
	AssertEqual(Secret, Resolved["Token"], "provided credentials retain their exact bytes")
	AssertContains(_LLMRemote_BuildCurlConfig("openai", Secret, "http://127.0.0.1:19273/v1/chat/completions"), "Authorization: Bearer " . Secret)
	for Invalid in [false, 4, Map("future", true), []]
		AssertEqual("", _LLMRemoteResolveEntry(Map("Provider", "lmstudio", "Token", Invalid, "Model", "fixture-model")), "a local capability cannot authorize a token of the wrong type")
}
Test("local API authentication: actual resolver, curl config and private-store restart", _LSA_ResolverAndPrivateRestart)

_LSA_ForeignSourceRefusal() {
	Entry := Map("Id", "local", "Name", "Local", "Provider", "lmstudio", "BaseUrl", "http://127.0.0.1:19273/v1", "Token", "", "Model", "fixture-model")
	Image := _LLM_Menu_SerializeApiEntries(Map("api_entries", [Entry]))
	AssertTrue(_LLM_Menu_ApiSourceOwned(Image), "a keyless owned source can enter the existing transaction")
	Foreign := JsonParse(Image)
	Foreign[1]["future"] := Map("nested", [7, 9])
	AssertFalse(_LLM_Menu_SerializeApiEntries(Map("api_entries", Foreign)), "unsupported fields refuse the detached writer rather than disappear")
	AssertFalse(_LLM_Menu_ApiSourceOwned('[{"Id":"future","Provider":"unknown","Token":"","Model":"m","Name":"Future","BaseUrl":"http://127.0.0.1:1/v1"}]'), "an unknown source row cannot be overwritten after a refused load")
	AssertFalse(_LLM_Menu_ApiSourceOwned("{}"), "a failed source read cannot be treated as an empty collection")
}
Test("local API authentication: unsupported source data refuses replacement", _LSA_ForeignSourceRefusal)


_LSA_DurableForeignRefusal() {
	global _LMT_ApiPath, _LMT_ApplyCalls, ConfigurationFile, _LLM_Menu
	Previous := _LMT_InstallApiFixture()
	try {
		Foreign := '[{"Id":"api_old","Name":"Old","Provider":"openai","BaseUrl":"https://old.invalid","Token":"old","Model":"old-model","future":{"flag":true}}]'
		AssertTrue(FSWrite(_LMT_ApiPath, Foreign))
		BeforeConfig := FSReadUtf8Exact(ConfigurationFile)
		BeforeMenu := _LLM_Menu
		Accepted := _LMT_ApiCommit(ConfigTransitionProductionPort())
		AssertFalse(Accepted, "the actual acquired transaction refuses a future source field")
		AssertEqual(Foreign, FSReadUtf8Exact(_LMT_ApiPath), "unsupported source bytes remain exact")
		AssertEqual(BeforeConfig, FSReadUtf8Exact(ConfigurationFile), "the sibling configuration remains exact")
		AssertTrue(BeforeMenu == _LLM_Menu, "no candidate becomes live after refused publication")
		AssertEqual(0, _LMT_ApplyCalls, "no backend callback runs after source refusal")
		AssertFalse(_ConfigWriteTerminalIsActive(), "refusal settles the actual acquired write owner")
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("local API authentication: actual transaction preserves unsupported source bytes", _LSA_DurableForeignRefusal)
