; tests/unit/ai/servers/test_local_server_fingerprint.ahk

; ==============================================================================
; MODULE: Local Server Fingerprint Replay (Windows)
; DESCRIPTION:
; Replays the authored shared vectors (local_server_fingerprint.json) against the
; production catalogue: which row of a shared default address a models listing
; belongs to, which rows a sweep keeps, and under which name the menu shows them.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Corpus Helpers ========
; ==================================
; ==================================

_LSF_Corpus() {
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\local_server_fingerprint.json", "UTF-8"))
}

_LSF_CatalogueRoot() {
	return JsonParse(FileRead(_SharedDir . "\ai\data\local_servers.json", "UTF-8"))
}

_LSF_Joined(Values) {
	Text := ""
	for Value in Values
		Text .= (A_Index > 1 ? "|" : "") . Value
	return Text
}

_LSF_Expected(Value) {
	return (Value is String) ? Value : ""
}

_LSF_Label(Key, Values*) {
	return Key . ":" . (Values.Length ? Values[1] : "")
}





; ====================================
; ====================================
; ======= 2/ Catalogue Vectors =======
; ====================================
; ====================================

_LSF_CatalogueGroups() {
	Corpus := _LSF_Corpus(), Root := _LSF_CatalogueRoot()
	Catalogue := LocalServerAuthCatalogue(Root, Map())
	Parsed := LocalServerFingerprintParse(Root, Catalogue["order"])
	AssertEqual(0, Parsed["errors"].Length, "no catalogue fingerprint is refused: " . _LSF_Joined(Parsed["errors"]))
	Fingerprinted := []
	Seen := 0
	for Id in Catalogue["order"] {
		if !Parsed["identities"].Has(Id)
			continue
		Seen += 1
		AssertEqual(_LSF_Joined(Corpus["groups"][Id]), _LSF_Joined(Parsed["identities"][Id]["group"]), Id . " group")
		if Parsed["identities"][Id]["rule"] is Map
			Fingerprinted.Push(Id)
	}
	AssertEqual(Corpus["groups"].Count, Seen, "the authored rows share an address, no other")
	AssertEqual(_LSF_Joined(Corpus["fingerprinted"]), _LSF_Joined(Fingerprinted))
}
Test("local server fingerprint: the catalogue's shared addresses and fingerprints are the authored ones", _LSF_CatalogueGroups)

_LSF_IdentifyVector(Vector) {
	Root := _LSF_CatalogueRoot()
	Identities := LocalServerFingerprintParse(Root, LocalServerAuthCatalogue(Root, Map())["order"])["identities"]
	Verdict := LocalServerFingerprintIdentify(Vector["body"], Vector["server"], Identities)
	AssertEqual(_LSF_Expected(Vector["expected"]), Verdict["server"])
	AssertEqual(Vector["reason"], Verdict["decision"])
}

_LSF_RefusalVector(Vector) {
	Ids := []
	for Id in Vector["servers"]
		Ids.Push(Id)
	Parsed := LocalServerFingerprintParse(Map("servers", Vector["servers"]), Ids)
	Fingerprinted := []
	for Id in Ids
		if Parsed["identities"].Has(Id) && (Parsed["identities"][Id]["rule"] is Map)
			Fingerprinted.Push(Id)
	AssertEqual(_LSF_Joined(Vector["expected"]["fingerprinted"]), _LSF_Joined(Fingerprinted))
	AssertEqual(Vector["expected"]["refused"], Parsed["errors"].Length)
}





; ===================================
; ===================================
; ======= 3/ Sweep Vectors ==========
; ===================================
; ===================================

_LSF_SweepVector(Vector) {
	Root := _LSF_CatalogueRoot()
	Catalogue := LocalServerAuthCatalogue(Root, Map())
	Identities := LocalServerFingerprintParse(Root, Catalogue["order"])["identities"]
	Controller := LocalServerDiscoveryController(Map("order", Catalogue["order"], "identities", Identities,
		"clock", (*) => 0, "max_age", (*) => 1))
	Settles := Map()
	Probe := (Target, Settle, Ticket) => (Settles[Target["id"]] := Settle, true)
	AssertTrue(Controller.Sweep(Vector["targets"], Probe))
	for Target in Vector["targets"] {
		Answer := Vector["answers"][Target["id"]].Clone()
		Answer["ok"] := Answer["ok"] ? true : false
		Settles[Target["id"]].Call(Answer)
	}
	Expected := Vector["expected"]
	AssertEqual(_LSF_Joined(Expected["detected"]), _LSF_Joined(Controller.Detected()))
	if Expected.Has("results") {
		for Id, Want in Expected["results"] {
			Got := Controller.Result(Id)
			for Field in ["status", "base_url"]
				AssertEqual(Want[Field], Got[Field], Id . " " . Field)
			AssertEqual(_LSF_Joined(Want["models"]), _LSF_Joined(Got["models"]), Id . " models")
			for Field in ["server", "shadowed_by"]
				AssertEqual(Want.Get(Field, ""), Got.Get(Field, ""), Id . " " . Field)
		}
	}
	if Expected.Has("rows") {
		Actions := Map("select", (*) => 0, "address", (*) => 0, "key", (*) => 0, "rescan", (*) => 0)
		Rows := LocalServerMenuRows(Map("order", Catalogue["order"], "servers", Catalogue["servers"],
			"detected", Controller.Detected(), "result", ObjBindMethod(Controller, "Result"), "backend", "ollama",
			"active", 0, "sweeping", false, "paused", false, "tr", _LSF_Label, "format", _LSF_Label, "actions", Actions))
		Labels := []
		for Row in Rows
			if Row.Has("items") && !(Row["label"] == "menu.llm.local_servers.other_address:")
				Labels.Push(Row["label"])
		AssertEqual(_LSF_Joined(Expected["rows"]), _LSF_Joined(Labels))
	}
}





; ===================================
; ===================================
; ======= 4/ Registration ===========
; ===================================
; ===================================

_LSF_Register() {
	Corpus := _LSF_Corpus()
	if Corpus["version"] != 1 || Corpus["identify"].Length != 11 || Corpus["sweeps"].Length != 9 || Corpus["refusals"].Length != 3
		throw Error("The independent fingerprint corpus requires explicit review.")
	for Vector in Corpus["identify"]
		Test("local server fingerprint: " . Vector["name"], _LSF_IdentifyVector.Bind(Vector))
	for Vector in Corpus["sweeps"]
		Test("local server sweep at a shared address: " . Vector["name"], _LSF_SweepVector.Bind(Vector))
	for Vector in Corpus["refusals"]
		Test("local server fingerprint refusal: " . Vector["name"], _LSF_RefusalVector.Bind(Vector))
}
_LSF_Register()

_LSF_DriverLoadsTheCatalogueIdentities() {
	global LLM_LOCAL_SERVER_IDENTITIES
	Assert(LLM_LOCAL_SERVER_IDENTITIES is Map, "the provider load publishes the identities")
	Root := _LSF_CatalogueRoot()
	Expected := LocalServerFingerprintParse(Root, LocalServerAuthCatalogue(Root, Map())["order"])["identities"]
	AssertEqual(Expected.Count, LLM_LOCAL_SERVER_IDENTITIES.Count, "every shared row is known to the driver")
	Assert(LLM_LOCAL_SERVER_IDENTITIES["omlx"]["rule"] is Map, "the fingerprint of oMLX reaches the driver")
}
Test("local server fingerprint: the provider load publishes the catalogue's identities", _LSF_DriverLoadsTheCatalogueIdentities)

; The whole owner: a vLLM listing on the oMLX row names vLLM in its views.
_LSF_OwnerNamesTheServerThatAnswered() {
	Identities := Map(
		"lmstudio", Map("group", ["lmstudio", "llamacpp"], "rule", 0),
		"llamacpp", Map("group", ["lmstudio", "llamacpp"], "rule", Map("model_field", "owned_by", "equals", "vllm")))
	Fixture := _LSP_OwnerFixture(Identities)
	try {
		Fixture.ScanResults["lmstudio"] := Map("id", "lmstudio", "running", true, "pids", [42],
			"base_url", "http://127.0.0.1:8000/v1", "port", 8000, "source", "config", "detail", "", "needs_listeners", false)
		Fixture.ScanResults["llamacpp"] := Fixture.Stopped("llamacpp")
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Complete(1, 200, '{"data":[{"id":"qwen3","owned_by":"vllm"}]}')
		AssertEqual("llamacpp", Fixture.Native.Result("lmstudio")["server"], "the listing names the other row")
		AssertEqual(Fixture.Servers["llamacpp"]["label"], Fixture.Native.ServerViews()[1]["display_name"],
			"the row shows the server that answered")
	} finally Fixture.Dispose()
}
Test("local server fingerprint: the owner names the server that answered", _LSF_OwnerNamesTheServerThatAnswered)
