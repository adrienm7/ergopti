; tests/unit/modules/llm/servers/test_local_server_panel_view_preparation.ahk

; ==============================================================================
; MODULE: Local Server Panel Deferred View Preparation
; DESCRIPTION:
; The deferred private view preparation, local-server affinity, configured
; local views and the retirement of closed owners settle exactly once with
; their native debt.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Delivers only an actually armed private preparation with genuine ready owner. */
_LSPV_DrivePreparation(Fixture) {
	Record := Fixture.Panel.Preparation
	if !(Record is Map) || !Fixture.RepairTimers.Has(ObjPtr(Record["timer"]))
		return false
	global _DriverReady, _LLM_MenuBuildCoordinator
	HadReady := IsSet(_DriverReady), HadCoordinator := IsSet(_LLM_MenuBuildCoordinator)
	Ready := HadReady ? _DriverReady : false
	Coordinator := HadCoordinator ? _LLM_MenuBuildCoordinator : 0
	try {
		_DriverReady := true
		_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(() => true, () => false)
		Fixture.Panel._RepairTick(Record)
		return true
	} finally {
		_DriverReady := HadReady ? Ready : unset
		_LLM_MenuBuildCoordinator := HadCoordinator ? Coordinator : unset
	}
}

_LSPV_DiscoveryRows(Fixture) {
	Rows := Fixture.Panel.Rows()
	_LSPV_DrivePreparation(Fixture)
	return Rows
}

_LSPV_PreparedRows(Fixture) {
	Fixture.Panel.Rows()
	_LSPV_DrivePreparation(Fixture)
	return Fixture.Panel.Rows()
}

class _LSPV_Fixture extends _LSPD_Fixture {
	__New() {
		super.__New()
		this.CaptureCalls := 0
		this.World.Owner.DefineProp("Capture", {Call: ObjBindMethod(this, "ObserveCapture")})
	}

	ObserveCapture(Owner, Args*) {
		this.CaptureCalls += 1
		return LLM_Menu_ApiPrivateSourceOwner.Prototype.Capture.Call(Owner, Args*)
	}

	Dispose() {
		if this.World.Owner.HasOwnProp("Capture")
			this.World.Owner.DeleteProp("Capture")
		super.Dispose()
	}
}

_LSPV_Nominal() {
	Fixture := _LSPV_Fixture()
	try {
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		Rows := Fixture.Panel.Rows()
		FileAppend("# DEFERRED_VIEW_ROWS elapsed_ms=" .
			(DllCall("Kernel32\GetTickCount64", "UInt64") - Started) . "`n", "*")
		AssertTrue(Rows is Array && Rows.Length > 0)
		AssertEqual(0, Fixture.CaptureCalls, "Rows must not read or classify the private source")
		AssertEqual(0, Fixture.RescanCalls)
		AssertEqual(0, Fixture.Requests.Length)
		AssertFalse(Fixture.Panel.LastSnapshot is Map)
		Record := Fixture.Panel.Preparation
		AssertTrue(Record is Map)
		Fixture.Panel.Rows()
		AssertTrue(Fixture.Panel.Preparation == Record)
		AssertEqual(1, Fixture.ArmCalls, "repeated builds must not reset an owned pending one-shot")
		Fixture.Panel._RepairTick(Record)
		AssertEqual(0, Fixture.CaptureCalls, "startup false cannot enter preparation")
		global _DriverReady, _LLM_MenuBuildCoordinator
		_DriverReady := true
		_LLM_MenuBuildCoordinator.Active := true
		Fixture.Panel._RepairTick(Record)
		AssertEqual(0, Fixture.CaptureCalls, "active build cannot enter preparation")
		_LLM_MenuBuildCoordinator.Active := false
		Fixture.Panel._RepairTick(Record)
		AssertTrue(Fixture.CaptureCalls > 0)
		AssertEqual(0, Fixture.RescanCalls, "preparation cannot confuse queued discovery with a result")
		AssertTrue(Fixture.Panel.Discovery is Map)
		Fixture.Panel._RepairTick(Fixture.Panel.Discovery)
		AssertEqual(1, Fixture.Publications.Length)
		_LSPV_PreparedRows(Fixture)
		AssertTrue(Fixture.Panel.LastSnapshot is Map)
		AssertTrue(Fixture.Panel.View is Map)
		AssertEqual(Fixture.Order.Length, Fixture.Panel.View["receipts"].Count)
		for Id, Receipt in Fixture.Panel.View["receipts"]
			AssertTrue(Fixture.Native.IsCurrent(Receipt))
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally Fixture.Dispose()
}
Test("local deferred view: Rows is I/O free and exact ready tick prepares original receipts", _LSPV_Nominal)

_LSPV_Refusal(Kind) {
	Fixture := _LSPV_Fixture()
	WasSuspended := A_IsSuspended
	try {
		Fixture.Panel.Rows()
		Record := Fixture.Panel.Preparation
		AssertTrue(Record is Map)
		global _DriverReady
		_DriverReady := true
		switch Kind {
			case "pause": Suspend(true)
			case "transition": Fixture.Transition("resume")
			case "cancel": AssertTrue(Fixture.Panel.Retire(false))
		}
		Fixture.Panel._RepairTick(Record)
		AssertEqual(0, Fixture.CaptureCalls)
		AssertEqual(0, Fixture.Requests.Length)
		AssertFalse(Fixture.Panel.PreparedRows is Array)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally {
		Suspend(WasSuspended)
		Fixture.Dispose()
	}
}

_LSPV_RegisterRefusals() {
	local Kind
	for Kind in ["pause", "transition", "cancel"]
		Test("local deferred view: " Kind " refuses exact pending preparation", _LSPV_Refusal.Bind(Kind))
}
_LSPV_RegisterRefusals()

_LSPV_StopRefusal() {
	Fixture := _LSPV_Fixture()
	try {
		Fixture.Panel.Rows()
		Record := Fixture.Panel.Preparation
		Fixture.RefuseRepairStop := true
		AssertThrows(() => Fixture.Panel.Retire(false))
		Arms := Fixture.ArmCalls
		AssertThrows(() => Fixture.Panel._RepairTick(Record))
		AssertEqual(Arms, Fixture.ArmCalls)
		AssertEqual(0, Fixture.CaptureCalls)
		AssertTrue(Fixture.Panel.RepairRecords.Get(ObjPtr(Record), 0) == Record)
		Fixture.RefuseRepairStop := false
		AssertTrue(Fixture.Panel.Retire(false))
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally Fixture.Dispose()
}
Test("local deferred view: refused timer retirement retains debt without retry", _LSPV_StopRefusal)

_LSPV_ConsumptionFence() {
	Fixture := _LSPV_Fixture()
	try {
		_LSPV_DiscoveryRows(Fixture)
		global _DriverReady
		_DriverReady := true
		Fixture.Panel._RepairTick(Fixture.Panel.Discovery)
		Fixture.Panel.Rows()
		_LSPV_DrivePreparation(Fixture)
		Prepared := Fixture.Panel.PreparedRows
		AssertTrue(Prepared is Array && Fixture.Panel.PreparedOwner is Map)
		Captures := Fixture.CaptureCalls
		Fixture.Transition("resume")
		Rows := Fixture.Panel.Rows()
		AssertTrue(Rows is Array && Rows != Prepared,
			"a changed lifecycle cannot consume the old actionable prepared array")
		AssertEqual(Captures, Fixture.CaptureCalls, "refused consumption cannot move source work back to Rows")
		AssertFalse(Fixture.Panel.PreparedOwner is Map)
	} finally Fixture.Dispose()
}
Test("local deferred view: lifecycle replacement refuses prepared row consumption", _LSPV_ConsumptionFence)





_LSPN_FixtureSchemaAdmission() {
	Fixture := _LSPN_Fixture()
	try {
		AssertTrue(ConfigSchemaCanPrepareWrite(Fixture.World.ConfigPath))
		Document := TOML_ParseDocument(Fixture.World.ConfigImage)
		AssertEqual(ConfigMigrateCurrentVersion(), Document["_meta"]["schema_version"])
		AssertEqual(Fixture.World.ConfigImage, FSReadUtf8Exact(Fixture.World.ConfigPath))
		Receipt := Fixture.World.Owner.Capture()
		AssertTrue(Receipt is LLM_Menu_ApiPrivateSourceReceipt)
		AssertTrue(Fixture.World.Owner.Current(Receipt))
		Future := StrReplace(Fixture.World.ConfigImage,
			"schema_version = " ConfigMigrateCurrentVersion(),
			"schema_version = " (ConfigMigrateCurrentVersion() + 1))
		AssertTrue(Future != Fixture.World.ConfigImage)
		AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Future))
		AssertFalse(ConfigSchemaCanPrepareWrite(Fixture.World.ConfigPath))
		AssertFalse(Fixture.World.Owner.Admit(), "a supported fixture does not weaken the real future-schema fence")
		AssertFalse(Fixture.World.Owner.Current(Receipt), "the old receipt cannot borrow a future image")
		AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Fixture.World.ConfigImage))
		AssertTrue(Fixture.World.Owner.Admit())
	} finally Fixture.Dispose()
}
Test("local server panel: fixture admits its exact supported image but refuses a future replacement", _LSPN_FixtureSchemaAdmission)





class _LSPN_ReadyChild extends _LSM_ChildReceipt {
	__New(Fixture, OnDone) {
		super.__New()
		this.Fixture := Fixture
		this.OnDone := OnDone
		this.ResponseDelivered := false
		this.ResponseStatus := 0
		this.ResponseBody := ""
	}

	start() {
		super.start()
		Fixture := this.Fixture
		Request := Fixture.Requests[Fixture.Requests.Length]
		Id := Fixture.Order[Mod(Fixture.Children.Length - 1, Fixture.Order.Length) + 1]
		this.ResponseStatus := 200
		this.ResponseBody := Id == "lmstudio"
			? '{"data":[{"id":"independent-joined"},{"id":"other-joined"}]}' : '{"data":[]}'
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 Fixture`r`n`r`n"))
		this.OnDone.Call(0, this.ResponseBody, "")
		this.ResponseDelivered := true
		return true
	}
}

_LSPN_ReadyChildFactory(Fixture, OnDone) {
	return _LSPN_ReadyChild(Fixture, OnDone)
}

_LSPN_CancellationDebtChildFactory(Fixture, Index, OnDone) {
	Child := _LSM_ChildReceipt()
	if Fixture.Children.Length + 1 == Index
		Child.TerminateAllowed := false
	return Child
}

_LSPN_GenericAffinityCheckedView() {
	global _LLM_Menu, Features
	for Explicit in [false, true] {
		Fixture := _LSPN_Fixture()
		try {
			_LSP_AffinitySource(Fixture.World, Explicit)
			_LLM_Menu["backend"] := "api"
			Features["llm"]["models"]["selected"] := "api"
			Fixture.World.ConfigImage := StrReplace(Fixture.World.ConfigImage, 'selected = "ollama"', 'selected = "api"')
			AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Fixture.World.ConfigImage))
			_LSPB_Stamp(Fixture.World)
			Fixture.Prepare()
			Rows := _LSPV_PreparedRows(Fixture)
			Found := 0
			for Row in Rows {
				if Row.Get("label", "") != "" && InStr(Row["label"], "oMLX 🖥️", true) {
					Found := Row
					break
				}
			}
			AssertTrue(Found is Map, "the actual joined native panel must render the canonical configured oMLX target")
			AssertEqual(!Explicit, Found["checked"], "checked state follows exact source-owned target ID and explicit precedence")
			AssertEqual(Explicit ? "explicit-local" : "generic-active", Fixture.Panel.LastSnapshot["entry_ids"]["omlx"])
			if !Explicit {
				AssertEqual("openai", Fixture.Panel.LastSnapshot["active"]["provider"])
				AssertEqual("generic-active", Fixture.Panel.LastSnapshot["active"]["id"])
			}
		} finally Fixture.Dispose()
	}
}
Test("local-server-affinity: actual joined panel checks the original generic entry identity", _LSPN_GenericAffinityCheckedView)

class _LSCF_ConfiguredChild extends _LSPN_ReadyChild {
	start() {
		_LSM_ChildReceipt.Prototype.start.Call(this)
		Fixture := this.Fixture
		Request := Fixture.Requests[Fixture.Requests.Length]
		Config := FSReadUtf8Exact(Request.ConfigPath)
		Configured := InStr(Config, ":19423/custom/v1/models", true) > 0
		this.ResponseStatus := Configured ? Fixture.ConfiguredStatus : 200
		this.ResponseBody := Configured ? Fixture.ConfiguredBody
			: InStr(Config, ":1234/v1/models", true) ? '{"data":[{"id":"independent-joined"},{"id":"other-joined"}]}' : '{"data":[]}'
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 " . this.ResponseStatus . " Fixture`r`n`r`n"))
		this.OnDone.Call(0, this.ResponseBody, "")
		this.ResponseDelivered := true
		return true
	}
}

_LSCF_ConfiguredChildFactory(Fixture, OnDone) {
	return _LSCF_ConfiguredChild(Fixture, OnDone)
}

_LSCF_InstallSource(Fixture) {
	global _LLM_Menu, Features
	_LSP_ConfiguredSource(Fixture.World)
	_LLM_Menu["backend"] := "api"
	Features["llm"]["models"]["selected"] := "api"
	Fixture.World.ConfigImage := StrReplace(Fixture.World.ConfigImage, 'selected = "ollama"', 'selected = "api"')
	AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Fixture.World.ConfigImage))
	_LSPB_Stamp(Fixture.World)
}

_LSCF_JoinedConfiguredView(Status := 200) {
	global _SharedDir, _LLM_Menu, LLM_LOCAL_API_SERVERS, LLM_API_PROVIDERS
	Fixture := _LSPN_Fixture()
	try {
		Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\llm\local_server_affinity.json"))
		_LSCF_InstallSource(Fixture)
		Fixture.ConfiguredStatus := Status
		Fixture.ConfiguredBody := Corpus["omlx_models_body"]
		Fixture.NativeSpawn := _LSCF_ConfiguredChildFactory.Bind(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(5, Fixture.Native.Order.Length)
		AssertEqual(5, Fixture.Requests.Length)
		AssertEqual(4, LLM_LOCAL_API_SERVERS.Count, "ephemeral views cannot register local provider capabilities")
		AssertFalse(LLM_API_PROVIDERS.Has("configured:generic-active"))
		AssertContains(Fixture.Configs[5], "http://127.0.0.1:19423/custom/v1/models")
		AssertFalse(InStr(Fixture.Configs[5], "Authorization:", true), "an explicit empty key must not become a blank Bearer header")
		Verdict := Fixture.Native.Result("configured:generic-active")
		AssertEqual(Status == 200 ? "up" : "needs_key", Verdict["status"])
		Rows := _LSPV_PreparedRows(Fixture)
		Found := 0
		for Row in Rows {
			if InStr(Row.Get("label", ""), "19423", true) {
				Found := Row
				break
			}
		}
		AssertTrue(Found is Map, "the source-owned nondefault endpoint must have a truthful configured row")
		AssertFalse(InStr(Found["label"], "oMLX", true), "a common models payload cannot brand a nondefault configured endpoint")
		AssertTrue(Found["checked"])
		if Status == 200 {
			AssertEqual(Corpus["omlx_model_ids"][1], Found["items"][1]["label"])
			AssertEqual(Corpus["omlx_model_ids"][2], Found["items"][2]["label"])
			Found["items"][1]["action"].Call()
			AssertEqual(3, _LLM_Menu["api_entries"].Length)
			AssertEqual("generic-active", _LLM_Menu["api_entries"][2]["Id"])
			AssertEqual("openai", _LLM_Menu["api_entries"][2]["Provider"])
			AssertEqual("Personal active name", _LLM_Menu["api_entries"][2]["Name"])
			AssertEqual(Corpus["omlx_model_ids"][1], _LLM_Menu["api_entries"][2]["Model"])
		} else {
			AssertEqual(0, Verdict["models"].Length, "401/403 response data cannot admit models")
			AssertFalse(Found["items"][1]["label"] == Corpus["omlx_model_ids"][1])
			AssertEqual("active-model", _LLM_Menu["api_entries"][2]["Model"])
		}
	} finally Fixture.Dispose()
}
Test("configured-local-view: actual joined owners discover, select and persist the original nondefault row", _LSCF_JoinedConfiguredView)
Test("configured-local-view: actual nondefault authentication refusal never admits response models", _LSCF_JoinedConfiguredView.Bind(401))

_LSCF_RemovedViewRetainsDebt() {
	global _LLM_Menu
	Fixture := _LSPN_Fixture()
	try {
		_LSCF_InstallSource(Fixture)
		Fixture.Owner.Options["timeout_ms"] := 60000
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(5, Fixture.Requests.Length)
		Child := Fixture.Children[5]
		Child.TerminateAllowed := false
		Id := "configured:generic-active"
		Job := Fixture.Native.Jobs[Id]
		NativeRecord := Fixture.Owner.Records[Id]
		_LLM_Menu["api_entries"].RemoveAt(2)
		_LLM_Menu["api_entry_id"] := "generic-first"
		Fixture.World.ConfigImage := StrReplace(Fixture.World.ConfigImage, 'api_entry_id = "generic-active"', 'api_entry_id = "generic-first"')
		Fixture.World.ApiImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", _LLM_Menu["api_entries"]))
		AssertTrue(FSWriteDurable(Fixture.World.ConfigPath, Fixture.World.ConfigImage))
		AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage))
		_LSPB_Stamp(Fixture.World)
		Fixture.NativeSpawn := _LSPN_ReadyChildFactory.Bind(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Native.RetryPending()
		AssertEqual(4, Fixture.Native.Order.Length)
		AssertTrue(Fixture.Native.Jobs.Get(Id, 0) == Job, "removed logical membership cannot release the exact unsettled native job")
		AssertTrue(Fixture.Owner.Records.Get(Id, 0) == NativeRecord, "the original child and artifact owner survive cancellation refusal")
		AssertFalse(Fixture.Native.Capture(Id), "removed views cannot mint an action receipt")
		Child.TerminateAllowed := true
		Fixture.Native.RetryPending()
		AssertFalse(Fixture.Native.Jobs.Has(Id))
		AssertFalse(Fixture.Owner.Records.Has(Id))
	} finally Fixture.Dispose()
}
Test("configured-local-view: removal retains exact native cancellation debt until acknowledged", _LSCF_RemovedViewRetainsDebt)


class _LSCI_ReadyChild extends _LSPN_ReadyChild {
	start() {
		_LSM_ChildReceipt.Prototype.start.Call(this)
		Request := this.Fixture.Requests[this.Fixture.Requests.Length]
		this.ResponseStatus := 200
		this.ResponseBody := InStr(Request.Url, ":1942", true)
			? this.Fixture.IdentityBody : '{"data":[]}'
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 Fixture`r`n`r`n"))
		this.OnDone.Call(0, this.ResponseBody, "")
		this.ResponseDelivered := true
		return true
	}
}

_LSCI_ReadyFactory(Fixture, OnDone) {
	return _LSCI_ReadyChild(Fixture, OnDone)
}

_LSCI_PendingFactory(Fixture, OnDone) {
	Request := Fixture.Requests[Fixture.Requests.Length]
	if InStr(Request.Url, ":19423", true) {
		Child := _LSM_ChildReceipt()
		Child.TerminateAllowed := false
		return Child
	}
	return _LSCI_ReadyChild(Fixture, OnDone)
}

_LSCI_ReplaceSource(Fixture, Mode) {
	global _LLM_Menu
	Entry := _LLM_Menu["api_entries"][2]
	if Mode == "url"
		Entry["BaseUrl"] := "http://127.0.0.1:19424/custom/v1"
	else if Mode == "provider"
		Entry["Provider"] := "openai_compat"
	else if Mode == "token"
		Entry["Token"] := "replacement-private-token"
	Fixture.World.ApiImage := _LLM_Menu_SerializeApiEntries(Map("api_entries", _LLM_Menu["api_entries"]))
	AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage))
	_LSPB_Stamp(Fixture.World)
}

_LSCI_FindConfiguredRow(Rows) {
	for Row in Rows
		if InStr(Row.Get("label", ""), ":1942", true)
			return Row
	return false
}

_LSCI_DriveDiscovery(Fixture) {
	Record := Fixture.Panel.Discovery
	AssertTrue(Record is Map && Fixture.RepairTimers.Has(ObjPtr(Record["timer"])))
	global _DriverReady, _LLM_MenuBuildCoordinator
	HadReady := IsSet(_DriverReady), HadCoordinator := IsSet(_LLM_MenuBuildCoordinator)
	Ready := HadReady ? _DriverReady : false
	Coordinator := HadCoordinator ? _LLM_MenuBuildCoordinator : 0
	try {
		_DriverReady := true
		_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(() => true, () => false)
		Fixture.Panel._RepairTick(Record)
	} finally {
		_DriverReady := HadReady ? Ready : unset
		_LLM_MenuBuildCoordinator := HadCoordinator ? Coordinator : unset
	}
}

_LSCI_JoinedPublishedSourceReplacement() {
	global _LLM_Menu
	for Mode in ["url", "provider", "token"] {
		Fixture := _LSPN_Fixture()
		try {
			_LSCF_InstallSource(Fixture)
			Fixture.IdentityBody := '{"data":[{"id":"old-owned"}]}'
			Fixture.NativeSpawn := _LSCI_ReadyFactory.Bind(Fixture)
			AssertTrue(Fixture.Native.Rescan())
			OldRow := _LSCI_FindConfiguredRow(_LSPV_PreparedRows(Fixture))
			AssertTrue(OldRow is Map)
			AssertEqual("old-owned", OldRow["items"][1]["label"])
			OldSelect := OldRow["items"][1]["action"]
			OldCache := Fixture.Native.Cache
			Requests := Fixture.Requests.Length
			_LSCI_ReplaceSource(Fixture, Mode)
			Fixture.IdentityBody := '{"data":[{"id":"new-owned"},{"id":"new-second"}]}'
			AssertFalse(Fixture.Native._CacheCurrent(OldCache), "identical entry IDs cannot borrow old source provenance")
			Image := FSReadUtf8Exact(Fixture.World.ApiPath)
			OldSelect.Call()
			AssertEqual(Image, FSReadUtf8Exact(Fixture.World.ApiPath), "retained model callbacks cannot write under the replacement source")
			Rows := _LSPV_PreparedRows(Fixture)
			AssertFalse(Fixture.Panel.LastSnapshot is Map, "fresh preparation removes stale model labels before deferred discovery")
			AssertFalse(_LSCI_FindConfiguredRow(Rows) is Map)
			_LSCI_DriveDiscovery(Fixture)
			Rows := _LSPV_PreparedRows(Fixture)
			NewRow := _LSCI_FindConfiguredRow(Rows)
			if !(NewRow is Map)
				NewRow := _LSCI_FindConfiguredRow(_LSPV_PreparedRows(Fixture))
			AssertTrue(NewRow is Map)
			AssertEqual("new-owned", NewRow["items"][1]["label"])
			AssertEqual("new-second", NewRow["items"][2]["label"])
			AssertTrue(Fixture.Requests.Length > Requests, "fresh source forces a probe before the old cache age expires")
			AssertEqual("generic-active", _LLM_Menu["api_entries"][2]["Id"])
			AssertEqual("active-model", _LLM_Menu["api_entries"][2]["Model"])
		} finally Fixture.Dispose()
	}
}
Test("local-server-cache-identity: actual joined rows re-probe equal IDs after URL, provider or token replacement", _LSCI_JoinedPublishedSourceReplacement)

_LSCI_JoinedReplacementRetainsOldDebt() {
	Fixture := _LSPN_Fixture()
	try {
		_LSCF_InstallSource(Fixture)
		Fixture.Owner.Options["timeout_ms"] := 60000
		Fixture.IdentityBody := '{"data":[{"id":"old-owned"}]}'
		Fixture.NativeSpawn := _LSCI_ReadyFactory.Bind(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		AssertTrue(_LSCI_FindConfiguredRow(_LSPV_PreparedRows(Fixture)) is Map)
		Fixture.NativeSpawn := _LSCI_PendingFactory.Bind(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		Id := "configured:generic-active"
		Job := Fixture.Native.Jobs[Id], Record := Fixture.Owner.Records[Id]
		Child := Fixture.Children[Fixture.Children.Length]
		AssertFalse(Child.TerminateAllowed)
		Generation := Fixture.Native.Controller.Generation
		_LSCI_ReplaceSource(Fixture, "url")
		Fixture.IdentityBody := '{"data":[{"id":"new-owned"}]}'
		Fixture.NativeSpawn := _LSCI_ReadyFactory.Bind(Fixture)
		Source := Fixture.World.Owner.Capture()
		Projection := Fixture.Native.CaptureView(Source)
		AssertTrue(Projection["stale"], "descriptor replacement revokes an equal-membership in-flight sweep")
		AssertTrue(Fixture.Native.Controller.Generation > Generation)
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(0, Fixture.Native.Controller.Results.Count)
		AssertTrue(Fixture.Native.Rescan())
		Fixture.Native.RetryPending()
		AssertTrue(Fixture.Native.Jobs[Id] == Job)
		AssertTrue(Fixture.Owner.Records[Id] == Record)
		AssertTrue(Record["request"].Handle == Child, "fresh logical ownership cannot release the old native child")
		AssertFalse(Fixture.Native.Result(Id) is Map)
		Child.TerminateAllowed := true
		Fixture.Native.RetryPending()
		Rows := _LSPV_PreparedRows(Fixture)
		Row := _LSCI_FindConfiguredRow(Rows)
		if !(Row is Map)
			Row := _LSCI_FindConfiguredRow(_LSPV_PreparedRows(Fixture))
		AssertTrue(Row is Map)
		AssertEqual("new-owned", Row["items"][1]["label"])
		AssertFalse(Fixture.Owner.Records.Has(Id))
	} finally Fixture.Dispose()
}
Test("local-server-cache-identity: equal-membership source refresh preserves exact old native debt until acknowledged", _LSCI_JoinedReplacementRetainsOldDebt)


; Cancellation can finish between the original cancel result and its final retry.
; Only the controlled child's completion timing changes; both native operations run.
class _LSPN_FinalSettlementOwner extends LocalServersOwner {
	__New(Options) {
		super.__New(Options)
		this.BoundaryChild := 0
		this.ReleaseAtBoundary := false
		this.CancelResults := []
		this.RetryResults := []
	}

	Cancel(Shutdown := false) {
		Result := super.Cancel(Shutdown)
		this.CancelResults.Push(Result)
		if this.ReleaseAtBoundary && this.BoundaryChild is _LSM_ChildReceipt
			this.BoundaryChild.TerminateAllowed := true
		return Result
	}

	RetryPending() {
		Result := super.RetryPending()
		this.RetryResults.Push(Result)
		return Result
	}
}

_LSPN_FinalSettlementRetirement(ReleaseAtBoundary, Shutdown) {
	Fixture := _LSPN_Fixture()
	try {
		AssertEqual(0, Fixture.Native.Jobs.Count)
		AssertEqual(0, Fixture.Owner.Records.Count)
		Native := _LSPN_FinalSettlementOwner(Fixture.Native.Options)
		Fixture.Native := Native
		Fixture.Panel.Native := Native
		Fixture.Prepare()
		Child := Fixture.RescanWithCancellationDebt()
		Native.BoundaryChild := Child
		Native.ReleaseAtBoundary := ReleaseAtBoundary
		Native.CancelResults := []
		Native.RetryResults := []
		Attempt := Fixture.BeginShutdown()
		Retired := Fixture.Panel.Retire(Shutdown)
		AssertEqual(1, Native.CancelResults.Length, "the actual native cancellation runs exactly once")
		AssertFalse(Native.CancelResults[1], "the original cancel boundary retains the exact refused child")
		AssertEqual(1, Native.RetryResults.Length, "the actual native final retry runs exactly once")
		AssertEqual(ReleaseAtBoundary, Native.RetryResults[1], "final native settlement follows only the controlled child's completion")
		AssertEqual(ReleaseAtBoundary, Retired, "final exact native settlement must govern panel retirement")
		AssertEqual(Shutdown, Native.Closed, "shutdown admission remains the original native owner's decision")
		AssertFalse(Fixture.World.Owner.Admit(), "the exact shutdown attempt must still revoke fresh source authority")
		AssertEqual(Attempt, _LLM_Menu_ApiPrivateLifecycleState()["attempt"])
		if ReleaseAtBoundary {
			AssertEqual(0, Fixture.Owner.Records.Count)
			AssertEqual(0, Native.Jobs.Count)
		} else {
			AssertTrue(Fixture.Owner.Records.Count > 0, "unsettled actual HTTP ownership must remain retained")
		}
	} finally Fixture.Dispose()
}
Test("local-server-retire-final-settlement: final retry can complete reversible cancellation", _LSPN_FinalSettlementRetirement.Bind(true, false))
Test("local-server-retire-final-settlement: final retry can complete closed-owner cancellation", _LSPN_FinalSettlementRetirement.Bind(true, true))
Test("local-server-retire-final-settlement: unsettled reversible cancellation remains owned", _LSPN_FinalSettlementRetirement.Bind(false, false))
Test("local-server-retire-final-settlement: unsettled closed-owner cancellation remains owned", _LSPN_FinalSettlementRetirement.Bind(false, true))
