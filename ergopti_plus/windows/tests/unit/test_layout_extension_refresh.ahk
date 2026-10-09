; tests/unit/test_layout_extension_refresh.ahk

; Real installed generations remain opt-in when a nonselected layout refreshes.
_L4RefreshNonselected() {
	Directory := _LCT_TempDir(), Refresh := "_LayMgrWeb_After"
	try {
		LocalDir := LayoutRegistry_LocalDir(Directory)
		Assert(_LCT_Install("ergol", LocalDir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())[1])
		Target := ManifestBuildFeaturesMap()
		Packs := HotstringExtensions_Prepare(Target, HotstringExtensions_Roots(Directory, Directory . "missing", Directory . "missing-registry\"))
		Calls := 0, Writes := 0, Completion := 0, Refusal := 0, Result := "pending"
		Reload(Success, Owner, Refused) {
			Calls += 1
			Completion := Success
			Refusal := Refused
			AssertEqual(Owner, 0)
			return true
		}
		Write(*) {
			Writes += 1
			return true
		}
		Options := Map("local_dir", LocalDir, "selected", (*) => "other", "packs", (*) => [],
			"reload", Reload, "write_selection", Write)
		Done(Ok) => Result := Ok
		Assert(%Refresh%("ergol", "install", Done, Options))
		AssertEqual(Calls, 1, "a nonselected extension requires the same successor discovery")
		AssertEqual(Writes, 0, "install never writes selection or activation preferences")
		AssertEqual(Result, "pending", "accepted launch is not terminal completion")
		Completion.Call()
		AssertEqual(Result, true)
		AssertEqual(HotstringExtensions_RegistrationPlan(Target, Packs, true).Length, 0)
		Assert(LayoutCatalogue_Uninstall("ergol", LocalDir)["ok"])
		Options["packs"] := (*) => Packs
		Result := "pending"
		Assert(%Refresh%("ergol", "uninstall", Done, Options))
		AssertEqual(Calls, 2, "previously loaded content must be removed even after its record disappeared")
		Refusal.Call("native close refused")
		AssertEqual(Result, false)
		AssertEqual(Writes, 0)
		Options["reload"] := (*) => false
		Result := "pending"
		Assert(!%Refresh%("ergol", "uninstall", Done, Options))
		AssertEqual(Result, false, "synchronous launch refusal is terminal too")
		Options["packs"] := (*) => []
		Result := "pending"
		Assert(%Refresh%("ergol", "uninstall", Done, Options))
		AssertEqual(Result, true, "an operation with no selected layout or extension needs no reload")
		Restarted := HotstringExtensions_Prepare(ManifestBuildFeaturesMap(),
			HotstringExtensions_Roots(Directory, Directory . "missing", Directory . "missing-registry\"))
		AssertEqual(Restarted.Length, 0)
	} finally DirDelete(Directory, true)
}
Test("layout-extension-refresh: install and removal refresh nonselected content without enabling it", _L4RefreshNonselected)

_L4RefreshTerminalResult() {
	global _LayMgrWeb_Result, _LayMgrWeb_RuntimeRefresh
	SavedResult := _LayMgrWeb_Result
	SavedRefresh := IsSet(_LayMgrWeb_RuntimeRefresh) ? _LayMgrWeb_RuntimeRefresh : 0
	Directory := _LMH_TempDir(), Log := [], Done := 0
	After(Id, Action, Complete) {
		Done := Complete
		return true
	}
	try {
		_LayMgrWeb_RuntimeRefresh := 0
		Deps := _LMH_Deps(Directory, Log)
		Deps["after"] := After
		_LayMgrWeb_OnDone(Deps, "ergol", "install", true)
		Assert(!(_LayMgrWeb_Result is Map), "the page must not announce success before runtime refresh settles")
		State := LayoutManager_PageState(Directory)
		AssertEqual(State["busy"]["id"], "ergol")
		Assert(!LayoutManager_HandleMessage(Map("action", "select", "id", "ergopti"), Deps))
		AssertEqual(_LMH_Calls(Log).Length, 0, "pending refresh fences a second layout mutation")
		Done.Call(false)
		AssertEqual(_LayMgrWeb_Result["ok"], false)
		AssertEqual(_LayMgrWeb_Result["code"], "other")
		Assert(!(_LayMgrWeb_RuntimeRefresh is Map))
		Done.Call(true)
		AssertEqual(_LayMgrWeb_Result["ok"], false, "a duplicate callback cannot overwrite terminal refusal")
	} finally {
		_LayMgrWeb_Result := SavedResult
		_LayMgrWeb_RuntimeRefresh := SavedRefresh
		DirDelete(Directory, true)
	}
}
Test("layout-extension-refresh: page waits for terminal acknowledgement and reports refusal", _L4RefreshTerminalResult)
