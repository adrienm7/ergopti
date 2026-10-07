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

_LMH_ReadyOncePerEpoch() {
	global _LayMgrWeb_SessionEpoch, _LayMgrWeb_ReadyEpoch, _LayoutCatalogueLast
	SavedEpoch := _LayMgrWeb_SessionEpoch
	SavedReady := _LayMgrWeb_ReadyEpoch
	SavedCatalogue := _LayoutCatalogueLast
	Dir := _LMH_TempDir()
	try {
		_LayoutCatalogueLast := Map("index", _LMH_Index(), "source", "network", "error", 0)
		_LayMgrWeb_SessionEpoch := 9876
		_LayMgrWeb_ReadyEpoch := 0
		Log := []
		Deps := _LMH_Deps(Dir, Log)
		AssertTrue(_LayMgrWeb_SessionCall(9876, LayoutManager_HandleMessage, Map("action", "ready"), Deps))
		AssertFalse(_LayMgrWeb_SessionCall(9876, LayoutManager_HandleMessage, Map("action", "ready"), Deps))
		AssertEqual(1, _LMH_Calls(Log).Length, "page and native ready refresh only once")
		_LayMgrWeb_SessionCall(9876, LayoutManager_HandleMessage, Map("action", "refresh"), Deps)
		AssertEqual(2, _LMH_Calls(Log).Length, "explicit refresh remains available")
		_LayMgrWeb_SessionEpoch += 1
		AssertFalse(_LayMgrWeb_SessionCall(9876, LayoutManager_HandleMessage, Map("action", "ready"), Deps))
		AssertTrue(_LayMgrWeb_SessionCall(9877, LayoutManager_HandleMessage, Map("action", "ready"), Deps))
		AssertEqual(3, _LMH_Calls(Log).Length, "replacement window receives its own initial refresh")
	} finally {
		_LayMgrWeb_SessionEpoch := SavedEpoch
		_LayMgrWeb_ReadyEpoch := SavedReady
		_LayoutCatalogueLast := SavedCatalogue
		DirDelete(Dir, true)
	}
}
Test("layout manager: dual ready signals refresh once per epoch (layout-ready-once)", _LMH_ReadyOncePerEpoch)

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

; The status displays the selected emulation only while its category is on;
; its row never acts as a second, ambiguous layout-selection command.
_LMH_EmulationStatusCase(Layout, Enabled, Name) {
	Index := LayoutCatalogue_BundledIndex()
	Assert(Index is Map, "the actual shipped registry must load")
	Rows := _LAY_CustomLayoutRows(Map("layout", Layout), Enabled, Index)
	AssertEqual(1, Rows.Length)
	Expected := Name == "" ? t("menu.layout.emulated_none") : Format(t("menu.layout.emulated_status"), Name)
	AssertEqual(Expected, Rows[1]["label"])
	AssertTrue(Rows[1].Get("disabled", false), "the status must be visibly disabled")
	AssertFalse(Rows[1].Has("action"), "the status must not select or reload anything")
	AssertFalse(Rows[1].Has("checked"), "a disabled status is not an emulation switch")
}

Test("layout menu: no base emulation explicitly reports none (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("ergopti_base", false), true, ""))
Test("layout menu: the built-in Ergopti emulation is named (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("ergopti_base", true, "ergopti_plus", false), true, "Ergopti"))
Test("layout menu: the built-in Ergopti+ variant is distinguished (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("ergopti_base", true, "ergopti_plus", true), true, "Ergopti+"))
Test("layout menu: a selected registry layout takes precedence (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("emulated_layout", "ergol", "ergopti_base", true), true, "Ergo-L"))
Test("layout menu: a disabled category does not claim its saved emulation is active (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("emulated_layout", "ergol", "ergopti_base", true), false, ""))
Test("layout menu: AltGr-only adjustments do not claim base-layout emulation (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("ergopti_base", false, "ergopti_alt_gr", true), true, ""))
Test("layout menu: a selection absent from the catalogue stays identified (layout-menu-emulation-status)",
	() => _LMH_EmulationStatusCase(Map("emulated_layout", "custom-installed-layout"), true, "custom-installed-layout"))

_LMH_NativeEmulationStatus() {
	static PROBE_KEY := "_test_layout_emulation_status"
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the actual menu manifest must load")
	Fragment := []
	for Item in Root["layout_menu"] {
		if _MR_Get(Item, "id") == "custom_layouts" || _MR_Get(Item, "id") == "layout_manager"
			Fragment.Push(Item)
	}
	AssertEqual(2, Fragment.Length, "the actual declaration must contain status and management")
	Root[PROBE_KEY] := Fragment
	try {
		Providers := Map("custom_layouts", () => _LAY_CustomLayoutRows(Map("layout", Map("ergopti_base", false)), true))
		Rendered := MenuRenderer_Build(PROBE_KEY, "Layout", "", "", Providers,
			Map("layout_manager", (*) => 0))
		AssertEqual(2, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"))
		AssertEqual(t("menu.layout.emulated_none"), _SRR_LabelAt(Rendered, 0))
		AssertEqual(t("menu.layout.manage"), _SRR_LabelAt(Rendered, 1))
		State := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF && (State & 3) != 0, "the real Win32 status item must be disabled")
		Manager := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", 1, "uint", 0x400, "uint")
		Assert(Manager != 0xFFFFFFFF && (Manager & 3) == 0, "layout management must remain usable")
	} finally {
		Root.Delete(PROBE_KEY)
	}
}
Test("layout menu: the native status is grayed and management remains usable (layout-menu-emulation-status)",
	_LMH_NativeEmulationStatus)





; ========================================
; ========================================
; ======= 4/ Selection lifecycle =========
; ========================================
; ========================================

; These cases use the real filesystem, sparse writer and native WAL owner.
; Only the replacement-process launch is controlled: a launch is not completion.
_LMH_SelectionFixture() {
	Fixture := _ScopeOwnerFixture()
	Source := '[layout]`nemulated_layout = "ergol"`nergopti_base = false`nergopti_plus = true`nergopti_alt_gr = false`ndirect_access_digits = "symbols"`nfuture_owner = "retain"`n[category_enabled]`nlayout = false`n[private]`nvalue = "unchanged"`n'
	AssertTrue(FSWriteDurable(Fixture.path, Source))
	Fixture.source := Source
	Fixture.options["stamp"] := "layout-selection"
	return Fixture
}

_LMH_SelectionPendingCase(Id, Expected, Base, Plus) {
	global Features
	Fixture := _LMH_SelectionFixture()
	Before := LayoutManager_ActiveId()
	RuntimeLayout := _LayMgrWeb_Json(Features.Get("layout", Map()))
	DesiredLayout := _LayMgrWeb_Json(MasterGateDesiredFeatures(Features).Get("layout", Map()))
	Cached := ParseTomlFile(Fixture.path)
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := LayoutManager_SelectTransition(Id, Fixture.options)
		AssertEqual("pending", Receipt["status"], "launch acceptance cannot acknowledge selected input")
		AssertEqual("keyboard_layout", Receipt["scope"])
		AssertEqual("select", Receipt["mode"])
		AssertEqual(Before, LayoutManager_ActiveId(), "the resident layout stays admitted until the successor takes input")
		AssertEqual(RuntimeLayout, _LayMgrWeb_Json(Features.Get("layout", Map())), "pending handoff cannot publish any resident layer gate")
		AssertEqual(DesiredLayout, _LayMgrWeb_Json(MasterGateDesiredFeatures(Features).Get("layout", Map())), "the old desired generation remains admitted")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		AssertEqual(Expected, Parsed["layout"].Get("emulated_layout", ""))
		AssertEqual(Base, Parsed["layout"].Get("ergopti_base", false))
		AssertEqual(Plus, Parsed["layout"].Get("ergopti_plus", false))
		AssertEqual(false, Parsed["layout"]["ergopti_alt_gr"], "selection does not claim an independent AltGr layer")
		AssertEqual("symbols", Parsed["layout"]["direct_access_digits"])
		AssertEqual("retain", Parsed["layout"]["future_owner"])
		AssertEqual(false, Parsed["category_enabled"]["layout"], "picker selection cannot grant a closed category")
		AssertEqual("unchanged", Parsed["private"]["value"])
		Loaded := Map("layout", Map("emulated_layout", "", "ergopti_base", false, "ergopti_plus", false))
		SuccessorPath := Fixture.directory . "\successor-config.toml"
		AssertTrue(FSWriteCreateDurable(SuccessorPath, FSReadUtf8Exact(Fixture.path)))
		AssertTrue(ApplyConfigToml(Loaded, SuccessorPath) >= 1, "the actual native loader must admit a fresh detached candidate source")
		AssertEqual(Id, LayoutManager_ActiveId(Loaded), "the real detached loader resolves the selected built-in or registry source")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object)
		AssertFalse(_ConfigWriteLeaseTryAcquire(Fixture.path, "foreign layout selection"), "pending selection retains exact configuration authority")
		Refusal.Call("native successor refused the layout handoff")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "late refusal restores the exact previous selection and unrelated bytes")
		AssertEqual(Before, LayoutManager_ActiveId())
		AssertEqual(RuntimeLayout, _LayMgrWeb_Json(Features.Get("layout", Map())))
		AssertEqual(DesiredLayout, _LayMgrWeb_Json(MasterGateDesiredFeatures(Features).Get("layout", Map())))
		AssertTrue(ObjPtr(ParseTomlFile(Fixture.path)) == ObjPtr(Cached), "the candidate never replaces the resident cached image")
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object)
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("layout selection: built-in Ergopti+ owns empty emulation until late refusal (todo96-picker-handoff)",
	_LMH_SelectionPendingCase.Bind("ergopti_plus", "", true, true))
Test("layout selection: built-in Ergopti restores its exact source on refusal (todo96-picker-handoff)",
	_LMH_SelectionPendingCase.Bind("ergopti", "", true, false))
Test("layout selection: a registry source preserves built-in gates on refusal (todo96-picker-handoff)",
	_LMH_SelectionPendingCase.Bind("ergol", "ergol", false, true))

_LMH_SelectionRefusedLaunchCase(Mode) {
	Fixture := _LMH_SelectionFixture()
	Launch(*) {
		if Mode == "throw"
			throw Error("controlled replacement launch failure")
		return Mode == "malformed" ? "1" : false
	}
	Fixture.options["reload"] := Launch
	try {
		AssertFalse(LayoutManager_Select("ergopti_plus", Fixture.options), "a refused or malformed native launch must not accept the selection")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.source, FSReadUtf8Exact(ConfigUnusedKeysBackupPath(Fixture.path, "layout-selection")))
		AssertFalse(_ConfigWriteLeaseState().terminal is Object, "refused launch releases its owned lifecycle barrier")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("layout selection: a false launch restores the previous source (todo96-picker-handoff)",
	_LMH_SelectionRefusedLaunchCase.Bind("false"))
Test("layout selection: a throwing launch restores the previous source (todo96-picker-handoff)",
	_LMH_SelectionRefusedLaunchCase.Bind("throw"))
Test("layout selection: a malformed launch cannot acknowledge selection (todo96-picker-handoff)",
	_LMH_SelectionRefusedLaunchCase.Bind("malformed"))

_LMH_SelectionBusyCase() {
	Fixture := _LMH_SelectionFixture()
	Bundle := _ConfigWriteTerminalTryAcquire([Fixture.path])
	AssertTrue(Bundle is Object)
	Launches := 0
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["reload"] := Launch
	try {
		AssertFalse(LayoutManager_Select("ergopti_plus", Fixture.options))
		AssertEqual(0, Launches, "an occupied lifecycle owner refuses before replacement launch")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertFalse(FileExist(ConfigUnusedKeysBackupPath(Fixture.path, "layout-selection")), "refused admission cannot create a backup")
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object, "foreign lifecycle authority remains owned")
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("layout selection: an occupied native owner refuses before publication (todo96-picker-handoff)", _LMH_SelectionBusyCase)


_LMH_SelectionPreconditionCase(Mode) {
	Fixture := _LMH_SelectionFixture()
	Launches := 0
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["reload"] := Launch
	Backup := ConfigUnusedKeysBackupPath(Fixture.path, "layout-selection")
	Changed := Fixture.source . '`n[external]`nvalue = "new generation"`n'
	if Mode == "backup"
		AssertTrue(FSWriteCreateDurable(Backup, "foreign backup"))
	else {
		BackupAndDrift(Path, Content) {
			AssertTrue(FSWriteCreateDurable(Path, Content))
			AssertTrue(FSWriteDurable(Fixture.path, Changed))
			return true
		}
		Fixture.options["backup"] := BackupAndDrift
	}
	try {
		AssertFalse(LayoutManager_Select("ergopti_plus", Fixture.options))
		AssertEqual(0, Launches, "the exact layout source must be admitted before replacement launch")
		AssertEqual(Mode == "backup" ? Fixture.source : Changed, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Mode == "backup" ? "foreign backup" : Fixture.source, FSReadUtf8Exact(Backup))
		AssertFalse(_ConfigWriteLeaseState().terminal is Object)
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("layout selection: a foreign backup refuses without overwriting its owner (todo96-picker-handoff)",
	_LMH_SelectionPreconditionCase.Bind("backup"))
Test("layout selection: source drift refuses without overwriting the new generation (todo96-picker-handoff)",
	_LMH_SelectionPreconditionCase.Bind("drift"))
