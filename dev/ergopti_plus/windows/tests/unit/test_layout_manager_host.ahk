; tests/unit/test_layout_manager_host.ahk

; ==============================================================================
; MODULE: Layout Manager Host Tests (Windows)
; DESCRIPTION:
; The layout manager page may only ask for the allowlisted actions, each
; checked against the catalogue or the installed layouts, and every refresh or
; operation pushes the page the state every driver sends
; (layout-manager-bridge). These tests drive LayoutManager_HandleMessage with
; injected collaborators and a scratch local folder, and pin which layout the
; Windows selection writes: the Ergopti layouts select the built-in emulation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LMH_Index() => JsonParse(FileRead(_StaticDir . "\layouts\registry\index.json", "UTF-8-RAW"))

_LMH_TempDir() {
	Dir := A_Temp . "\ergopti_layout_manager_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

; Collaborators that record every call; install settles when the test says so.
_LMH_Deps(Dir, Log) {
	Pending := []
	return Map(
		"local_dir", Dir,
		"push", (Name, Payload) => Log.Push(Map("push", Name, "payload", Payload)),
		"refresh", (OnDone) => (Log.Push(Map("call", "refresh")), OnDone.Call(LayoutCatalogue_Last())),
		"install", (Id, OnDone) => (Log.Push(Map("call", "install " . Id)), Pending.Push(OnDone)),
		"uninstall", (Id) => (Log.Push(Map("call", "uninstall " . Id)), Map("ok", true)),
		"select", (Id) => Log.Push(Map("call", "select " . Id)),
		"open_url", (Url) => Log.Push(Map("call", "open " . Url)),
		"close", () => Log.Push(Map("call", "close")),
		"pending", Pending
	)
}

_LMH_Calls(Log) {
	Calls := []
	for Item in Log
		if Item.Has("call")
			Calls.Push(Item["call"])
	return Calls
}

_LMH_LastPush(Log) {
	Index := Log.Length
	while (Index > 0) {
		if Log[Index].Has("push")
			return Log[Index]
		Index -= 1
	}
	return 0
}





; ====================================
; ====================================
; ======= 2/ Allowlist and ids =======
; ====================================
; ====================================

Test("layout manager host: only allowlisted actions on known layouts reach the catalogue (layout-manager-bridge)",
	_LMH_AllowlistCase)

_LMH_AllowlistCase() {
	global _LayoutCatalogueLast
	Dir := _LMH_TempDir()
	Saved := _LayoutCatalogueLast
	try {
		_LayoutCatalogueLast := Map("index", _LMH_Index(), "source", "network", "error", 0)
		Log := []
		Deps := _LMH_Deps(Dir, Log)
		for Payload in ["install", Map(), Map("action", "rm -rf"), Map("action", "install"),
				Map("action", "install", "id", "..\evil"), Map("action", "install", "id", "absent"),
				Map("action", "uninstall", "id", "ergol"), Map("action", "select", "id", "ergol")]
			AssertFalse(LayoutManager_HandleMessage(Payload, Deps), "a message outside the allowlist was accepted")
		AssertEqual(0, _LMH_Calls(Log).Length, "no refused message reaches the catalogue")

		AssertTrue(LayoutManager_HandleMessage(Map("action", "install", "id", "ergol"), Deps))
		AssertEqual("install ergol", _LMH_Calls(Log)[1])
		Deps["pending"][1].Call(true, Map("entry", Map("id", "ergol", "version", "1.0.2"), "source", "network"))
		Last := _LMH_LastPush(Log)
		AssertEqual("updateState", Last["push"])
		AssertEqual("ergol", Last["payload"]["result"]["id"])
		AssertTrue(Last["payload"]["result"]["ok"])

		AssertTrue(LayoutManager_HandleMessage(Map("action", "select", "id", "ergopti"), Deps),
			"the built-in Ergopti emulation can be selected without an installation")
		AssertEqual("select ergopti", _LMH_Calls(Log)[2])
		AssertTrue(LayoutManager_HandleMessage(Map("action", "open_homepage", "id", "ergol", "url", "https://evil.test"), Deps))
		AssertEqual("open https://ergol.org", _LMH_Calls(Log)[3], "the page never chooses the URL")
		AssertTrue(LayoutManager_HandleMessage(Map("action", "close"), Deps))
		AssertEqual("close", _LMH_Calls(Log)[4])
	} finally {
		_LayoutCatalogueLast := Saved
		DirDelete(Dir, true)
	}
}

Test("layout manager host: ready sends the strings and the state every driver sends (layout-manager-bridge)",
	_LMH_ReadyCase)

_LMH_ReadyCase() {
	Dir := _LMH_TempDir()
	try {
		Log := []
		AssertTrue(LayoutManager_HandleMessage(Map("action", "ready"), _LMH_Deps(Dir, Log)))
		AssertEqual("initData", Log[1]["push"])
		State := Log[1]["payload"]["state"]
		for Key in ["platform", "index", "source", "error", "installed", "provided", "builtin", "active", "busy",
				"result", "record_error"]
			Assert(State.Has(Key), "the page state lacks " . Key)
		AssertEqual("windows", State["platform"])
		Assert(State["builtin"].Has(ERGOPTI_LAYOUT_ID), "the built-in Ergopti emulation is listed as such")
		Strings := Log[1]["payload"]["strings"]
		Assert(Strings.Count >= 35, "the page receives every string it shows")
		AssertEqual(t("layout_manager.window_title"), Strings["layout_manager.window_title"])
		Json := _LayMgrWeb_Json(Log[1]["payload"])
		Assert(InStr(Json, '"platform":"windows"'), "the state serialises to the page's JSON")
		Assert(InStr(Json, '"busy":null'), "none serialises to null")
	} finally DirDelete(Dir, true)
}

Test("layout manager host: before any refresh the page shows the shipped catalogue as such (layout-manager-shipped-first)",
	_LMH_ShippedFirstCase)

_LMH_ShippedFirstCase() {
	global _LayoutCatalogueLast
	Dir := _LMH_TempDir()
	Saved := _LayoutCatalogueLast
	try {
		_LayoutCatalogueLast := Map("index", 0, "source", "none", "error", 0)
		State := LayoutManager_PageState(Dir)
		Assert(State["index"] is Map, "the index shipped with the driver is listed before the first refresh")
		AssertEqual("bundled", State["source"], "the page must not call the shipped catalogue no catalogue")
	} finally {
		_LayoutCatalogueLast := Saved
		DirDelete(Dir, true)
	}
}

Test("layout manager host: the active layout follows the emulation settings (layout-manager-bridge)", () => (
	AssertEqual("ergol", LayoutManager_ActiveId(Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true)))),
	AssertEqual(ERGOPTI_PLUS_LAYOUT_ID, LayoutManager_ActiveId(Map("layout",
		Map("emulated_layout", "", "ergopti_base", true, "ergopti_plus", true)))),
	AssertEqual(ERGOPTI_LAYOUT_ID, LayoutManager_ActiveId(Map("layout",
		Map("emulated_layout", "", "ergopti_base", true, "ergopti_plus", false)))),
	AssertEqual("", LayoutManager_ActiveId(Map("layout", Map("emulated_layout", "", "ergopti_base", false))),
		"without the Ergopti emulation Windows types its own layout")
))
