; tests/unit/modules/llm/servers/test_local_server_panel_discovery.ahk

; ==============================================================================
; MODULE: Local Server Panel Read-Only View and Discovery
; DESCRIPTION:
; The fenced read-only view projection and the deferred automatic discovery
; of the local server panel keep the admitted source image without
; blocking.
; ==============================================================================

#Requires AutoHotkey v2.0





_LSPB_Stamp(World) {
	; The native World already owns its current stamp; a second table is invalid TOML.
	AssertTrue(FSWriteDurable(World.ConfigPath, World.ConfigImage))
	AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath))
}

_LSPB_Current(Observation, Owner, Receipt) {
	Observation["checks"] += 1
	if Observation.Get("ids", 0) is Array && !Observation.Get("changed", false) {
		Observation["changed"] := true
		Observation["ids"].Push("outside-native-catalogue")
	}
	return LLM_Menu_ApiPrivateSourceOwner.Prototype.Current.Call(Owner, Receipt)
}

_LSPB_SourceBatch() {
	AssertTrue(HasMethod(LLM_Menu_ApiPrivateSourceOwner.Prototype, "EntriesBound"))
	Fixture := _LSJ_Fixture()
	World := Fixture.World
	try {
		Before := World.ConfigImage
		AssertTrue(FSUtf8ExactMatches(World.ConfigPath, Before))
		AssertTrue(ConfigSchemaCanPrepareWrite(World.ConfigPath), "the actual parent source is already admitted")
		_LSPB_Stamp(World)
		AssertEqual(Before, World.ConfigImage, "panel admission cannot add a duplicate schema table")
		AssertTrue(FSUtf8ExactMatches(World.ConfigPath, Before), "the physical parent image remains byte exact")
		Source := World.Owner.Capture()
		AssertTrue(Source is LLM_Menu_ApiPrivateSourceReceipt)
		Ids := []
		global LLM_API_PROVIDER_ORDER, LLM_LOCAL_API_SERVERS
		for Id in LLM_API_PROVIDER_ORDER
			if LLM_LOCAL_API_SERVERS.Has(Id)
				Ids.Push(Id)
		Length := Ids.Length
		Observation := Map("checks", 0, "ids", Ids)
		World.Owner.DefineProp("Current", {Call: _LSPB_Current.Bind(Observation)})
		Batch := World.Owner.EntriesBound(Ids, Source)
		AssertTrue(Batch is Map)
		AssertTrue(Observation["changed"], "the provider list must actually mutate during source validation")
		AssertEqual(Length + 1, Ids.Length)
		AssertEqual(Length, Batch["entries"].Count, "projection must use the admitted private list snapshot")
		AssertFalse(Batch["entries"].Has("outside-native-catalogue"))
		AssertEqual(2, Observation["checks"], "all providers share both full source fences")
		AssertFalse(World.Owner.EntriesBound([Ids[1]], LLM_Menu_ApiPrivateSourceReceipt()),
			"a fabricated receipt cannot project private entries")
		AssertThrows(() => World.Owner.EntriesBound([Ids[1], Ids[1]], Source))
		AssertThrows(() => World.Owner.EntriesBound(["outside-native-catalogue"], Source))
	} finally {
		if World.Owner.HasOwnProp("Current")
			World.Owner.DeleteProp("Current")
		Fixture.Dispose()
	}
}
Test("local readonly batch: real source fences snapshot provider arguments", _LSPB_SourceBatch)

_LSPB_CopyMutation(Fixture, Original, Kind, Native, Results) {
	if !Fixture.BatchMutated {
		Fixture.BatchMutated := true
		if Kind == "source" {
			AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage "`n"))
		} else {
			Native.BeginView()
			Fixture.ReentrantViews := Native.Views
			Fixture.ReentrantView := Native.ViewGeneration
		}
	}
	return Original.Call(Native, Results)
}

class _LSPB_CompletedChild extends _LSM_ChildReceipt {
	__New(Fixture, OnDone) {
		this.Fixture := Fixture
		this.OnDone := OnDone
		super.__New()
	}

	start() {
		super.start()
		Fixture := this.Fixture
		Request := Fixture.Requests[Fixture.Requests.Length]
		Id := Fixture.Order[Fixture.Children.Length]
		Body := Id == "lmstudio" ? '{"data":[{"id":"independent-joined"},{"id":"other-joined"}]}' : '{"data":[]}'
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 Fixture`r`n`r`n"))
		this.OnDone.Call(0, Body, "")
		return true
	}
}

_LSPB_CompletedChildFactory(Fixture, OnDone) {
	return _LSPB_CompletedChild(Fixture, OnDone)
}

_LSPB_JoinedView() {
	AssertTrue(HasMethod(LocalServersOwner.Prototype, "CaptureView"))
	Fixture := _LSPN_Fixture()
	try {
		; Complete the controlled child at its owned start, before another slow
		; provider factory can exhaust the real curl deadline against fixture clock0.
		Fixture.NativeSpawn := _LSPB_CompletedChildFactory.Bind(Fixture)
		AssertTrue(Fixture.Native.Rescan())
		AssertEqual(Fixture.Order.Length, Fixture.Requests.Length)
		AssertFalse(Fixture.Native.Controller.IsSweeping())
		AssertEqual(1, Fixture.Publications.Length)
		AssertEqual(0, Fixture.Native.Jobs.Count)
		Observation := Map("checks", 0)
		Fixture.World.Owner.DefineProp("Current", {Call: _LSPB_Current.Bind(Observation)})
		Rows := _LSPV_PreparedRows(Fixture)
		AssertTrue(Rows is Array && Rows.Length > 0)
		AssertTrue(Fixture.Panel.LastSnapshot is Map)
		AssertTrue(Observation["checks"] <= 8,
			"one display projection must bound full source validation independently of provider/model rows")
		AssertEqual(Fixture.Order.Length, Fixture.Panel.View["receipts"].Count)
		AssertEqual("independent-joined", Fixture.Panel.LastSnapshot["results"]["lmstudio"]["models"][1])
		AssertEqual("other-joined", Fixture.Panel.LastSnapshot["results"]["lmstudio"]["models"][2])
		for Id, Receipt in Fixture.Panel.View["receipts"]
			AssertTrue(Fixture.Native.IsCurrent(Receipt), "normal strict callback receipts must remain valid")
		Source := Fixture.World.Owner.Capture()
		Original := LocalServersOwner.Prototype.GetOwnPropDesc("_CopyResults").Call
		for Kind in ["source", "view"] {
			Fixture.BatchMutated := false
			OldViews := Fixture.Native.Views
			Fixture.Native.DefineProp("_CopyResults", {Call: _LSPB_CopyMutation.Bind(Fixture, Original, Kind)})
			try {
				Projection := Fixture.Native.CaptureView(Source)
				AssertFalse(Projection is Map, "a mutation during detached copy must refuse the whole view")
				AssertTrue(Fixture.BatchMutated, "the actual yielding copy boundary must be reached")
				if Kind == "source"
					AssertTrue(Fixture.Native.Views == OldViews, "source refusal cannot emit partial action receipts")
				else {
					AssertTrue(Fixture.Native.Views == Fixture.ReentrantViews,
						"refused predecessor cannot overwrite a reentrant view")
					AssertEqual(Fixture.ReentrantView, Fixture.Native.ViewGeneration)
				}
			} finally {
				Fixture.Native.DeleteProp("_CopyResults")
				AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage))
			}
		}
	} finally {
		if Fixture.Native.HasOwnProp("_CopyResults")
			Fixture.Native.DeleteProp("_CopyResults")
		if Fixture.World.Owner.HasOwnProp("Current")
			Fixture.World.Owner.DeleteProp("Current")
		Fixture.Dispose()
	}
}
Test("local readonly batch: actual joined rows bound reads and reject copy reentry", _LSPB_JoinedView)





; ==================================================
; ==================================================
; ======= 5/ Deferred Automatic Discovery ===========
; ==================================================
; ==================================================

class _LSPD_Fixture extends _LSPN_Fixture {
	__New() {
		super.__New()
		global _DriverReady, _LLM_MenuBuildCoordinator
		this.HadReady := IsSet(_DriverReady)
		this.OldReady := this.HadReady ? _DriverReady : false
		this.HadCoordinator := IsSet(_LLM_MenuBuildCoordinator)
		this.OldCoordinator := this.HadCoordinator ? _LLM_MenuBuildCoordinator : 0
		_DriverReady := false
		_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(() => true, () => false)
		this.RescanCalls := 0
		this.ThrowRescan := false
		this.ArmRetirement := false
		this.ArmCalls := 0
		this.NativeSpawn := _LSPB_CompletedChildFactory.Bind(this)
		this.Native.DefineProp("Rescan", {Call: ObjBindMethod(this, "ObserveRescan")})
	}

	ObserveRescan(Native, Args*) {
		this.RescanCalls += 1
		if this.ThrowRescan
			throw Error("Independent deferred rescan refusal.")
		return LocalServersOwner.Prototype.Rescan.Call(Native, Args*)
	}

	RepairTimer(Callback, Period) {
		if Period < 0
			this.ArmCalls += 1
		Accepted := super.RepairTimer(Callback, Period)
		if Period < 0 && this.ArmRetirement {
			this.ArmRetirement := false
			this.Panel.Retire(false)
		}
		return Accepted
	}

	Dispose() {
		global _DriverReady, _LLM_MenuBuildCoordinator
		try {
			this.ArmRetirement := false
			if this.Native.HasOwnProp("Rescan")
				this.Native.DeleteProp("Rescan")
			super.Dispose()
		} finally {
			_DriverReady := this.HadReady ? this.OldReady : unset
			_LLM_MenuBuildCoordinator := this.HadCoordinator ? this.OldCoordinator : unset
		}
	}
}

_LSPD_Nominal() {
	Fixture := _LSPD_Fixture()
	try {
		RowsStarted := DllCall("Kernel32\GetTickCount64", "UInt64")
		Rows := _LSPV_DiscoveryRows(Fixture)
		FileAppend("# DEFERRED_DISCOVERY_SETUP elapsed_ms=" .
			(DllCall("Kernel32\GetTickCount64", "UInt64") - RowsStarted) . "`n", "*")
		AssertTrue(Rows is Array && Rows.Length > 0)
		AssertEqual(0, Fixture.RescanCalls, "row construction cannot enter managed discovery")
		AssertEqual(0, Fixture.Requests.Length, "no child acquisition occurs on the menu build stack")
		AssertEqual(0, Fixture.Publications.Length, "a queued timer is not a probe result")
		AssertFalse(Fixture.Panel.LastSnapshot is Map)
		Record := Fixture.Panel.Discovery
		AssertTrue(Record is Map)
		DiscoveryStarted := DllCall("Kernel32\GetTickCount64", "UInt64")
		Fixture.Panel._RepairTick(Record)
		FileAppend("# DEFERRED_DISCOVERY_WAIT elapsed_ms=" .
			(DllCall("Kernel32\GetTickCount64", "UInt64") - DiscoveryStarted) . "`n", "*")
		AssertEqual(0, Fixture.RescanCalls, "startup readiness must precede discovery")
		global _DriverReady, _LLM_MenuBuildCoordinator
		_DriverReady := true
		_LLM_MenuBuildCoordinator.Active := true
		Fixture.Panel._RepairTick(Record)
		AssertEqual(0, Fixture.RescanCalls, "an active menu build must not be preempted by discovery")
		_LLM_MenuBuildCoordinator.Active := false
		Fixture.Panel._RepairTick(Record)
		AssertEqual(1, Fixture.RescanCalls)
		AssertEqual(Fixture.Order.Length, Fixture.Requests.Length)
		AssertEqual(1, Fixture.Publications.Length, "the original controller must publish the controlled replies")
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertTrue(_LSPV_PreparedRows(Fixture) is Array)
		AssertTrue(Fixture.Panel.LastSnapshot is Map)
		AssertEqual(2, Fixture.Panel.LastSnapshot["results"]["lmstudio"]["models"].Length)
	} finally Fixture.Dispose()
}
Test("local nonblocking discovery: rows return before ready and inactive original rescan", _LSPD_Nominal)

_LSPD_Refusal(Kind) {
	AssertTrue(HasMethod(LLM_LocalServerPanel.Prototype, "_QueueDiscovery"))
	Fixture := _LSPD_Fixture()
	WasSuspended := A_IsSuspended
	try {
		_LSPV_DiscoveryRows(Fixture)
		Record := Fixture.Panel.Discovery
		AssertTrue(Record is Map)
		global _DriverReady
		_DriverReady := true
		switch Kind {
			case "source": AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage "`n"))
			case "pause": Suspend(true)
			case "transition": Fixture.Transition("resume")
			case "cancel": AssertTrue(Fixture.Panel.Retire(false))
			case "error": Fixture.ThrowRescan := true
		}
		Fixture.Panel._RepairTick(Record)
		AssertEqual(Kind == "error" ? 1 : 0, Fixture.RescanCalls)
		AssertEqual(0, Fixture.Requests.Length)
		AssertEqual(0, Fixture.Publications.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
	} finally {
		Suspend(WasSuspended)
		AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage))
		Fixture.Dispose()
	}
}

_LSPD_RegisterRefusals() {
	local Kind
	for Kind in ["source", "pause", "transition", "cancel", "error"]
		Test("local nonblocking discovery: " Kind " refuses exact queued acquisition", _LSPD_Refusal.Bind(Kind))
}
_LSPD_RegisterRefusals()

_LSPD_TimerReentry() {
	AssertTrue(HasMethod(LLM_LocalServerPanel.Prototype, "_QueueDiscovery"))
	Fixture := _LSPD_Fixture()
	try {
		Fixture.ArmRetirement := true
		AssertTrue(Fixture.Panel._QueueDiscovery(Fixture.World.Owner.Capture()))
		AssertFalse(Fixture.ArmRetirement, "the actual timer arm port must reenter retirement")
		AssertEqual(0, Fixture.RescanCalls)
		AssertEqual(0, Fixture.Requests.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertTrue(Fixture.Panel._QueueDiscovery(Fixture.World.Owner.Capture()))
		Record := Fixture.Panel.Discovery
		AssertTrue(Record is Map)
		Fixture.RefuseRepairStop := true
		AssertThrows(() => Fixture.Panel.Retire(false))
		AssertTrue(Fixture.Panel.RepairRecords.Get(ObjPtr(Record), 0) == Record,
			"timer0 refusal must retain the exact callback debt")
		Arms := Fixture.ArmCalls
		AssertThrows(() => Fixture.Panel._RepairTick(Record))
		AssertEqual(Arms, Fixture.ArmCalls, "retired ownership cannot arm an unowned retry")
		AssertEqual(0, Fixture.RescanCalls)
		Fixture.RefuseRepairStop := false
		AssertTrue(Fixture.Panel.Retire(false))
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
	} finally Fixture.Dispose()
}
Test("local nonblocking discovery: arm reentry and stop refusal retain exact timer debt", _LSPD_TimerReentry)

_LSPD_ArmRefusal() {
	AssertTrue(HasMethod(LLM_LocalServerPanel.Prototype, "_QueueDiscovery"))
	Fixture := _LSPD_Fixture()
	try {
		Fixture.ArmFailure := "refuse"
		AssertThrows(() => Fixture.Panel._QueueDiscovery(Fixture.World.Owner.Capture()))
		AssertEqual(0, Fixture.RescanCalls)
		AssertEqual(0, Fixture.Requests.Length)
		AssertEqual(0, Fixture.Publications.Length)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertTrue(Fixture.Panel.Discovery is Map)
		AssertEqual(1, Fixture.Panel.RepairRecords.Count, "failed acquisition retains its exact cleanup owner")
		Fixture.ArmFailure := ""
		AssertTrue(Fixture.Panel.Retire(false))
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally Fixture.Dispose()
}
Test("local nonblocking discovery: timer arm refusal cannot publish queued success", _LSPD_ArmRefusal)


_LSPD_CoalescenceSource() {
	Fixture := _LSPD_Fixture()
	try {
		_LSPV_DiscoveryRows(Fixture)
		Prior := Fixture.Panel.Discovery
		AssertTrue(Prior is Map)
		AssertTrue(Fixture.Panel._QueueDiscovery(Prior["source"]))
		AssertTrue(Fixture.Panel.Discovery == Prior, "unchanged source coalesces the exact retained callback")
		AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage "`n"))
		Fresh := Fixture.World.Owner.Capture()
		AssertTrue(IsObject(Fresh) && Fixture.World.Owner.Current(Fresh))
		AssertTrue(Fixture.Panel._QueueDiscovery(Fresh))
		Next := Fixture.Panel.Discovery
		AssertTrue(Next is Map && Next != Prior, "new admitted image replaces an obsolete source intent")
		AssertTrue(Next["source"] == Fresh)
		AssertFalse(Fixture.Panel.RepairRecords.Has(ObjPtr(Prior)))
		AssertFalse(Fixture.RepairTimers.Has(ObjPtr(Prior["timer"])))
		Fixture.Panel._RepairTick(Prior)
		AssertTrue(Fixture.Panel.Discovery == Next, "old callback cannot retire its replacement")
		AssertEqual(0, Fixture.RescanCalls)
		global _DriverReady
		_DriverReady := true
		Fixture.Panel._RepairTick(Next)
		AssertEqual(1, Fixture.RescanCalls)
		AssertEqual(1, Fixture.Publications.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally {
		AssertTrue(FSWriteDurable(Fixture.World.ApiPath, Fixture.World.ApiImage))
		Fixture.Dispose()
	}
}
Test("local nonblocking discovery: coalescence retains the admitted source image", _LSPD_CoalescenceSource)
