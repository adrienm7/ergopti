; tests/unit/test_local_server_menu.ahk

; ==============================================================================
; MODULE: Shared Local Server Menu Policy Tests
; DESCRIPTION:
; Checks existing Lua row behavior with independent literal expectations: ordered
; model identity, authenticated status, selected model and paused action absence.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Shared Policy Cases =======
; ======================================
; ======================================

_LSMR_Options(Paused := false) {
	Servers := Map("lmstudio", Map("label", "LM Studio"), "llamacpp", Map("label", "llama.cpp"))
	Verdicts := Map("lmstudio", Map("status", "up", "base_url", "http://Configured-HOST:1234/custom/v1",
		"models", ["second", "first", "second"]), "llamacpp", Map("status", "needs_key",
		"base_url", "http://127.0.0.1:1235/v1", "models", []))
	Observed := []
	Actions := Map("select", (Id, Model) => Observed.Push(["select", Id, Model]),
		"address", (Id) => Observed.Push(["address", Id]),
		"key", (Id) => Observed.Push(["key", Id]), "rescan", (*) => Observed.Push(["rescan"]))
	return Map("order", ["lmstudio", "llamacpp"], "servers", Servers, "detected", ["lmstudio", "llamacpp"],
		"result", (Id) => Verdicts[Id], "sweeping", false, "paused", Paused,
		"backend", "api", "active", Map("provider", "lmstudio", "model", "first"),
		"tr", (Key) => Key, "format", (Key, Value) => Key . "|" . Value,
		"actions", Actions, "observed", Observed)
}

_LSMR_OrderedIdentityAndAuthRows() {
	Options := _LSMR_Options()
	Rows := LocalServerMenuRows(Options)
	AssertTrue(Rows[1]["separator"])
	AssertEqual("menu.llm.local_servers.header", Rows[2]["label"])
	AssertEqual("LM Studio 🖥️ — Configured-HOST:1234", Rows[3]["label"])
	AssertTrue(Rows[3]["checked"])
	Models := Rows[3]["items"]
	AssertEqual("second", Models[1]["label"])
	AssertEqual("first", Models[2]["label"])
	AssertEqual("second", Models[3]["label"], "duplicate API identifiers retain original order in row data")
	AssertFalse(Models[1]["checked"])
	AssertTrue(Models[2]["checked"])
	AssertFalse(Models[3]["checked"])
	Models[1]["action"].Call()
	Models[2]["action"].Call()
	AssertEqual("lmstudio", Options["observed"][1][2])
	AssertEqual("second", Options["observed"][1][3], "later loop iterations cannot retarget an earlier retained action")
	AssertEqual("first", Options["observed"][2][3])
	AssertEqual("menu.llm.local_servers.address|Configured-HOST:1234", Models[5]["label"])
	AssertEqual("menu.llm.local_servers.api_key", Models[6]["label"])
	AssertEqual("menu.llm.local_servers.needs_key|llama.cpp 🖥️ — 127.0.0.1:1235", Rows[4]["label"])
	AssertEqual("menu.llm.local_servers.api_key", Rows[4]["items"][1]["label"])
	AssertEqual("menu.llm.local_servers.rescan", Rows[5]["label"])
	AssertEqual("LM Studio", Rows[6]["items"][1]["label"])
	AssertEqual("llama.cpp", Rows[6]["items"][2]["label"])
}
Test("local server menu: ordered identity and existing authentication rows", _LSMR_OrderedIdentityAndAuthRows)

_LSMR_PausedActionsAndSearching() {
	Options := _LSMR_Options(true)
	Rows := LocalServerMenuRows(Options)
	for Index in [1, 2, 3, 5, 6] {
		Row := Rows[3]["items"][Index]
		AssertTrue(Row["disabled"])
		AssertFalse(Row.Has("action"), "paused models/address/key rows expose no action")
	}
	AssertTrue(Rows[5]["disabled"])
	AssertFalse(Rows[5].Has("action"))
	for Row in Rows[6]["items"] {
		AssertTrue(Row["disabled"])
		AssertFalse(Row.Has("action"))
	}
	Options["detected"] := []
	Options["sweeping"] := true
	Rows := LocalServerMenuRows(Options)
	AssertEqual("menu.llm.local_servers.searching|LM Studio, llama.cpp", Rows[3]["label"])
	AssertTrue(Rows[3]["disabled"])
	Options["sweeping"] := false
	Rows := LocalServerMenuRows(Options)
	AssertEqual("menu.llm.local_servers.none|LM Studio, llama.cpp", Rows[3]["label"])
}
Test("local server menu: pause suppresses actions and retains honest search status", _LSMR_PausedActionsAndSearching)

_LSMR_GenericCheckedIdentity() {
	Options := _LSMR_Options()
	Options["active"] := Map("id", "generic-selected", "provider", "openai_compat", "model", "first")
	Options["entry_id"] := (Id) => Id == "lmstudio" ? "generic-selected" : ""
	Rows := LocalServerMenuRows(Options)
	AssertTrue(Rows[3]["checked"], "the exact source-owned generic entry checks its catalogue row")
	AssertTrue(Rows[3]["items"][2]["checked"])
	Options["entry_id"] := (Id) => Id == "lmstudio" ? "explicit-precedence" : ""
	Rows := LocalServerMenuRows(Options)
	AssertFalse(Rows[3]["checked"], "an explicit selected target cannot borrow a generic active ID")
	AssertFalse(Rows[3]["items"][2]["checked"])
	Options["active"] := Map("id", "foreign-active", "provider", "lmstudio", "model", "first")
	Rows := LocalServerMenuRows(Options)
	AssertFalse(Rows[3]["checked"], "provider and model equality cannot substitute for the exact target ID")
}
Test("local-server-affinity: checked rows use source-owned entry IDs", _LSMR_GenericCheckedIdentity)


_LSI_MenuUnavailableIsHonest() {
	Options := _LSMR_Options()
	Options["detected"] := []
	Options["result"] := (Id) => Map("status", "unavailable", "models", [])
	for Sweeping in [false, true] {
		Options["sweeping"] := Sweeping
		Rows := LocalServerMenuRows(Options)
		AssertEqual("healthcheck.status.failed", Rows[3]["label"])
		AssertTrue(Rows[3]["disabled"])
		AssertFalse(Rows[3].Has("action"))
		for Row in Rows
			if Row.Has("label") {
				AssertFalse(InStr(Row["label"], "menu.llm.local_servers.none"))
				AssertFalse(InStr(Row["label"], "menu.llm.local_servers.searching"))
			}
	}
	Options["detected"] := ["lmstudio"]
	Options["result"] := (Id) => Id == "lmstudio"
		? Map("status", "up", "models", [], "base_url", "http://127.0.0.1:1234/v1")
		: Map("status", "unavailable", "models", [])
	Rows := LocalServerMenuRows(Options)
	AssertEqual("healthcheck.status.failed", Rows[3]["label"])
	AssertEqual("LM Studio 🖥️ — 127.0.0.1:1234", Rows[4]["label"], "an unavailable peer does not hide a proven available server")
	AssertEqual("menu.llm.local_servers.no_models", Rows[4]["items"][1]["label"])
	AssertTrue(Rows[4]["items"][1]["disabled"])
}
Test("local-server-unavailable: unavailable infrastructure renders a disabled failure instead of no servers", _LSI_MenuUnavailableIsHonest)
