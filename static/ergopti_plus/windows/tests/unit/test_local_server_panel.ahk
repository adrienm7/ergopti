; tests/unit/test_local_server_panel.ahk

; ==============================================================================
; MODULE: Local Server Panel Authority Tests
; DESCRIPTION:
; Uses the actual JOIN private files/controller/cache/HTTP ownership fixture.
; Only formatting, notification, build observation and timer delivery are ports.
; These controls do not claim physical tray interaction or real loopback HTTP.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Actual Panel Join Fixture =======
; ============================================
; ============================================

class _LSPN_Fixture extends _LSJ_Fixture {
	__New() {
		super.__New()
		global _LLM_LocalServerPanel, _LLM_Menu_RuntimeActivated, _LifecycleTransitionsByPhase
		this.SavedPanel := _LLM_LocalServerPanel
		this.HadActivated := IsSet(_LLM_Menu_RuntimeActivated)
		this.Activated := this.HadActivated ? _LLM_Menu_RuntimeActivated : false
		this.Phases := _LifecycleTransitionsByPhase.Clone()
		this.OwnedTransitions := []
		this.Notifications := []
		this.Builds := []
		this.RepairTimers := Map()
		this.PanelControl := ""
		this.FormatMutated := false
		this.ObserveCritical := []
		this.Attempt := 0
		this.RefuseRepairStop := false
		this.ArmFailure := ""
		this.Panel := LLM_LocalServerPanel(Map("source_owner", this.World.Owner,
			"models_owner", this.Owner, "native_owner", this.Native,
			"format", ObjBindMethod(this, "FormatReport"), "notify", ObjBindMethod(this, "Notify"),
			"build", ObjBindMethod(this, "Build"), "timer", ObjBindMethod(this, "RepairTimer")))
		_LLM_LocalServerPanel := this.Panel
		_LLM_Menu_RuntimeActivated := true
	}

	FormatReport(Key, Values*) {
		this.ObserveCritical.Push(A_IsCritical)
		if !this.FormatMutated && this.PanelControl != "" {
			this.FormatMutated := true
			switch this.PanelControl {
				case "source":
					Records := JsonParse(FSReadUtf8Exact(this.World.ApiPath))
					Records[1]["Name"] := "Independent format-time source replacement"
					if !FSWriteDurable(this.World.ApiPath, _LLM_Menu_SerializeApiEntries(Map("api_entries", Records), (Value) => Value))
						throw Error("The fixture-owned format-time source replacement failed.")
				case "cache":
					this.Native.Rescan()
					for Index, Id in this.Order {
						Body := Id == "lmstudio" ? '{"data":[{"id":"independent-joined"},{"id":"other-joined"}]}' : '{"data":[]}'
						this.Complete(this.Order.Length + Index, 200, Body)
					}
				case "view": this.Native.BeginView()
				case "controller": this.Native.Controller.Invalidate()
			}
		}
		return Format(t(Key), Values*)
	}

	Notify(Body, Title, Icon) {
		this.ObserveCritical.Push(A_IsCritical)
		this.Notifications.Push(Map("body", Body, "title", Title, "icon", Icon))
	}

	Build(Reason) {
		this.ObserveCritical.Push(A_IsCritical)
		this.Builds.Push(Reason)
		return true
	}

	RepairTimer(Callback, Period) {
		this.ObserveCritical.Push(A_IsCritical)
		if Period == 0 {
			if this.RefuseRepairStop
				return false
			if this.RepairTimers.Has(ObjPtr(Callback))
				this.RepairTimers.Delete(ObjPtr(Callback))
		} else {
			if this.ArmFailure == "throw"
				throw Error("Independent repair timer acquisition exception.")
			if this.ArmFailure == "refuse"
				return false
			this.RepairTimers[ObjPtr(Callback)] := Callback
		}
		return true
	}

	Transition(Phase) {
		Transition := LifecycleTransitionBegin(Phase)
		LifecycleTransitionMarkStarted(Transition)
		this.OwnedTransitions.Push(Transition)
		return Transition
	}

	BeginShutdown() {
		this.Attempt := LLM_Menu_ApiPrivateBeginShutdown()
		return this.Attempt
	}

	DriveRepair() {
		Record := this.Panel.Repair
		AssertTrue(Record is Map, "the exact accepted repair must remain observable")
		this.Panel._RepairTick(Record)
	}

	AssertObserverBoundaries() {
		AssertTrue(this.ObserveCritical.Length > 0)
		for Value in this.ObserveCritical
			AssertEqual(0, Value, "foreign panel observers must run outside Critical")
	}

	Dispose() {
		global _LLM_LocalServerPanel, _LLM_Menu_RuntimeActivated, _LifecycleTransitionsByPhase
		try {
			this.RefuseRepairStop := false
			this.ArmFailure := ""
			for Child in this.Children
				if Child is _LSM_ChildReceipt
					Child.TerminateAllowed := true
			State := _LLM_Menu_ApiPrivateLifecycleState()
			if this.Attempt > 0 && State["attempt"] == this.Attempt
				LLM_Menu_ApiPrivateRefuseShutdown(this.Attempt)
			this.Panel.Retire(false)
			AssertEqual(0, this.Panel.RepairRecords.Count)
			AssertEqual(0, this.RepairTimers.Count)
		} finally {
			_LLM_LocalServerPanel := this.SavedPanel
			if this.HadActivated
				_LLM_Menu_RuntimeActivated := this.Activated
			else
				_LLM_Menu_RuntimeActivated := unset
			for Transition in this.OwnedTransitions {
				if _LifecycleTransitionsByPhase.Get(Transition.phase, 0) == Transition {
					if this.Phases.Has(Transition.phase)
						_LifecycleTransitionsByPhase[Transition.phase] := this.Phases[Transition.phase]
					else
						_LifecycleTransitionsByPhase.Delete(Transition.phase)
				}
			}
			super.Dispose()
		}
	}
}





; ===============================================
; ===============================================
; ======= 2/ Originating Report Authority =======
; ===============================================
; ===============================================

_LSPN_Report(Control := "") {
	Fixture := _LSPN_Fixture()
	try {
		Fixture.Prepare()
		Cache := Fixture.Native.Cache
		Models := Fixture.Native.ModelGeneration
		Fixture.PanelControl := Control
		Shown := Fixture.Panel._ReportSweep("lmstudio", false)
		AssertEqual(Control == "", Shown)
		AssertEqual(Control == "" ? 1 : 0, Fixture.Notifications.Length)
		if Control != ""
			AssertTrue(Fixture.FormatMutated, "the causal formatting boundary must really mutate")
		if Control == "cache" {
			AssertTrue(Cache != Fixture.Native.Cache)
			AssertEqual(Models, Fixture.Native.ModelGeneration, "equal-model publication still owns a distinct cache")
			AssertEqual(2, Fixture.Publications.Length)
		}
		Fixture.AssertObserverBoundaries()
	} finally Fixture.Dispose()
}
Test("local server panel: exact accepted result publishes one notification", _LSPN_Report)
Test("local server panel: actual source replacement during format suppresses old notification", _LSPN_Report.Bind("source"))
Test("local server panel: equal-model accepted new cache suppresses old notification", _LSPN_Report.Bind("cache"))
Test("local server panel: newer model view suppresses old notification", _LSPN_Report.Bind("view"))
Test("local server panel: controller invalidation suppresses old notification", _LSPN_Report.Bind("controller"))





; ==========================================
; ==========================================
; ======= 3/ Exact Lifecycle Repairs =======
; ==========================================
; ==========================================

_LSPN_ResumeAfterFinish() {
	Fixture := _LSPN_Fixture()
	try {
		Transition := Fixture.Transition("resume")
		AssertFalse(Fixture.World.Owner.Admit(), "unfinished actual transition must retain source refusal")
		AssertTrue(_LifecycleRunRequiredStep(Transition, "llm-menu", LLM_Menu_LocalServersOnResume, true))
		AssertEqual(0, Fixture.Builds.Length)
		AssertFalse(LLM_Menu_LocalServersResumeFinished(Transition))
		AssertTrue(LifecycleTransitionFinish(Transition))
		AssertTrue(Fixture.World.Owner.Admit())
		AssertTrue(LLM_Menu_LocalServersResumeFinished(Transition))
		AssertEqual(1, Fixture.Builds.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		Body := _DriverFuncBody("Ergopti_OnSuspendResume")
		AssertTrue(Body != "", "the actual native resume hook must be present")
		Finished := InStr(Body, "if !LifecycleTransitionFinish(Transition)")
		Publication := InStr(Body, "LLM_Menu_LocalServersResumeFinished(Transition)")
		AssertTrue(Finished > 0 && Publication > Finished, "actual hook publication must follow successful Finish")
		Fixture.AssertObserverBoundaries()
	} finally Fixture.Dispose()
}
Test("local server panel: actual resume remains unpublished until exact successful Finish", _LSPN_ResumeAfterFinish)

_LSPN_CanceledResume() {
	Fixture := _LSPN_Fixture()
	try {
		Transition := Fixture.Transition("resume")
		AssertTrue(LLM_Menu_LocalServersOnResume())
		AssertTrue(Fixture.Panel.Retire(false))
		AssertTrue(LifecycleTransitionFinish(Transition))
		AssertTrue(LLM_Menu_LocalServersResumeFinished(Transition))
		AssertEqual(0, Fixture.Builds.Length, "retired intent must not borrow a later successful Finish")
	} finally Fixture.Dispose()
}
Test("local server panel: canceled resume intent cannot borrow later Finish", _LSPN_CanceledResume)

_LSPN_ShutdownRepair(PendingDebt := false) {
	Fixture := _LSPN_Fixture()
	try {
		Fixture.Prepare()
		if PendingDebt {
			AssertTrue(Fixture.Native.Rescan())
			Fixture.Children[Fixture.Order.Length + 1].TerminateAllowed := false
		}
		Attempt := Fixture.BeginShutdown()
		AssertEqual(!PendingDebt, LLM_Menu_LocalServersPrepareShutdown())
		AssertFalse(Fixture.World.Owner.Admit())
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		AssertTrue(LLM_Menu_LocalServersShutdownRefused(Attempt))
		AssertEqual(0, Fixture.Builds.Length, "OnExit refusal must only arm post-unwind work")
		AssertEqual(1, Fixture.RepairTimers.Count)
		Fixture.DriveRepair()
		if PendingDebt {
			AssertEqual(0, Fixture.Builds.Length, "unsettled exact HTTP debt still blocks repair")
			AssertEqual(1, Fixture.Panel.RepairRecords.Count)
			Fixture.Children[Fixture.Order.Length + 1].TerminateAllowed := true
			Fixture.DriveRepair()
		}
		AssertEqual(1, Fixture.Builds.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertTrue(Fixture.World.Owner.Admit())
		AssertFalse(Fixture.World.Owner.Current(Fixture.OtherSource), "old source cannot borrow canceled shutdown epoch")
		Fixture.AssertObserverBoundaries()
	} finally Fixture.Dispose()
}
Test("local server panel: canceled shutdown queues exactly one post-unwind fresh build", _LSPN_ShutdownRepair)
Test("local server panel: canceled shutdown waits for exact native HTTP cancellation debt", _LSPN_ShutdownRepair.Bind(true))





; ===========================================
; ===========================================
; ======= 4/ Retained Repair Failures =======
; ===========================================
; ===========================================

_LSPN_RepairRegistrationFailure(Control) {
	Fixture := _LSPN_Fixture()
	try {
		Attempt := Fixture.BeginShutdown()
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		Fixture.ArmFailure := Control
		Failure := 0
		try LLM_Menu_LocalServersShutdownRefused(Attempt)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error, "refused or throwing registration must remain observable to the protected hook")
		AssertEqual(1, Fixture.Panel.RepairRecords.Count, "the exact acquisition receipt survives failed registration")
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertEqual(0, Fixture.Builds.Length)
		Fixture.ArmFailure := ""
		Fixture.DriveRepair()
		AssertEqual(1, Fixture.Builds.Length)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		Fixture.AssertObserverBoundaries()
	} finally Fixture.Dispose()
}
Test("local server panel: refused repair registration retains exact recoverable debt", _LSPN_RepairRegistrationFailure.Bind("refuse"))
Test("local server panel: throwing repair registration retains exact recoverable debt", _LSPN_RepairRegistrationFailure.Bind("throw"))

_LSPN_SourceString(Value) {
	Escaped := StrReplace(StrReplace(Value, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34))
	return Chr(34) . Escaped . Chr(34)
}

_LSPN_ActualExitRefusalKeepsItsResult() {
	Fixture := _LSPN_Fixture()
	try {
		Body := _DriverFuncBody("_LifecycleRefuseShutdown")
		AssertTrue(Body != "", "actual OnExit refusal function must be present")
		ChildPath := Fixture.World.ConfigPath . ".exit-probe.ahk"
		ReceiptPath := Fixture.World.ConfigPath . ".exit-receipt"
		; Execute the exact native function in an isolated interpreter. Unrelated
		; uninstall/reload/input/log ports are inert, so no real driver may exit.
		Probe := "#Requires AutoHotkey v2.0`n#ErrorStdOut`n#Warn All, StdOut`n#NoTrayIcon`n"
		Probe .= 'global _LifecycleShutdownVetoAttempts := 0, _LifecycleShutdownReason := "Exit", _LifecycleAiShutdownAttempt := 1' . "`n"
		Probe .= "global PrivateRefusals := 0, RepairCalls := 0, Logged := 0`n"
		Probe .= "UninstallCancel() {`nreturn true`n}`nLifecycleShutdownVetoHonored() {`nreturn true`n}`n"
		Probe .= "ReloadTerminalHandoffRefuseForShutdown(*) {`nreturn true`n}`n_LifecycleForceReleaseHeldInput() {`nreturn 1`n}`n"
		Probe .= "LLM_Menu_ApiPrivateRefuseShutdown(Attempt) {`nglobal PrivateRefusals`nPrivateRefusals += 1`nreturn true`n}`n"
		Probe .= 'LLM_Menu_LocalServersShutdownRefused(Attempt) {' . "`nglobal RepairCalls`nRepairCalls += 1`n" . 'throw Error("independent repair timer failure")' . "`n}`n"
		Probe .= "LoggerError(*) {`nglobal Logged`nLogged += 1`n}`n"
		; The source helper supplies the full declaration, including its signature.
		Probe .= Body . "`n"
		Probe .= 'Result := _LifecycleRefuseShutdown("independent local discovery debt")' . "`n"
		Probe .= 'FileAppend(Result . ":" . PrivateRefusals . ":" . RepairCalls . ":" . Logged, ' . _LSPN_SourceString(ReceiptPath) . ', "UTF-8-RAW")' . "`nExitApp(0)`n"
		AssertTrue(FSWriteDurable(ChildPath, Chr(0xFEFF) . Probe))
		Command := Chr(34) . A_AhkPath . Chr(34) . " /ErrorStdOut " . Chr(34) . ChildPath . Chr(34)
		AssertEqual(0, RunWait(Command, , "Hide"), "protected actual refusal function must return normally despite repair exception")
		AssertEqual("1:1:1:1", FSReadUtf8Exact(ReceiptPath), "honored veto, exact private retirement, repair failure and diagnostic must each occur once")
	} finally Fixture.Dispose()
}
Test("local server panel: actual native OnExit refusal still returns veto after repair exception", _LSPN_ActualExitRefusalKeepsItsResult)


_LSPN_InheritedCriticalIsRestored() {
	Fixture := _LSPN_Fixture()
	try {
		Fixture.Prepare()
		PreviousCritical := Critical("On")
		try {
			Inherited := A_IsCritical
			AssertTrue(Fixture.Panel._ReportSweep("lmstudio", false))
			AssertEqual(Inherited, A_IsCritical)
			Transition := Fixture.Transition("resume")
			AssertTrue(LLM_Menu_LocalServersOnResume())
			AssertTrue(LifecycleTransitionFinish(Transition))
			AssertTrue(LLM_Menu_LocalServersResumeFinished(Transition))
			AssertEqual(Inherited, A_IsCritical)
			Attempt := Fixture.BeginShutdown()
			AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
			AssertTrue(LLM_Menu_LocalServersShutdownRefused(Attempt))
			AssertEqual(Inherited, A_IsCritical)
			Fixture.DriveRepair()
			AssertEqual(Inherited, A_IsCritical)
		} finally Critical(PreviousCritical)
		Fixture.AssertObserverBoundaries()
	} finally Fixture.Dispose()
}
Test("local server panel: public lifecycle and report ports restore inherited Critical", _LSPN_InheritedCriticalIsRestored)


_LSPN_EarlyBootAbsenceIsNotDebt() {
	Fixture := _LSPN_Fixture()
	global _LLM_LocalServerPanel
	try {
		_LLM_LocalServerPanel := unset
		AssertTrue(LLM_Menu_LocalServersPrepareShutdown())
		AssertTrue(LLM_Menu_LocalServersShutdownRefused(1))
		AssertTrue(LLM_Menu_LocalServersOnSuspend())
		AssertEqual("independent fallback", LLM_Menu_LocalServersBackendLabel("independent fallback"))
		AssertEqual(0, Fixture.Builds.Length)
	} finally {
		_LLM_LocalServerPanel := Fixture.Panel
		Fixture.Dispose()
	}
}
Test("local server panel: early boot unset sentinel is honest absence rather than shutdown debt", _LSPN_EarlyBootAbsenceIsNotDebt)

_LSPN_ExactTimerStopDebt() {
	Fixture := _LSPN_Fixture()
	try {
		Attempt := Fixture.BeginShutdown()
		AssertTrue(LLM_Menu_ApiPrivateRefuseShutdown(Attempt))
		AssertTrue(LLM_Menu_LocalServersShutdownRefused(Attempt))
		Old := Fixture.Panel.Repair
		Fixture.RefuseRepairStop := true
		Failure := 0
		try Fixture.Panel.Retire(false)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertTrue(Fixture.Panel.RepairRecords.Get(ObjPtr(Old), 0) == Old)
		AssertEqual(1, Fixture.RepairTimers.Count, "refused cancellation cannot pretend the old callback retired")
		Fixture.RefuseRepairStop := false
		Fixture.Panel._RepairTick(Old)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.Builds.Length)
		AssertTrue(LLM_Menu_LocalServersShutdownRefused(Attempt))
		Newest := Fixture.Panel.Repair
		Fixture.Panel._RepairTick(Old)
		AssertTrue(Fixture.Panel.Repair == Newest)
		AssertEqual(1, Fixture.RepairTimers.Count, "stale callback cannot borrow the successor cancellation slot")
		Fixture.DriveRepair()
		AssertEqual(1, Fixture.Builds.Length)
	} finally Fixture.Dispose()
}
Test("local server panel: exact timer-stop debt survives retirement and cannot cancel successor", _LSPN_ExactTimerStopDebt)

_LSPN_FailedResumeRetainsExactIntent() {
	Fixture := _LSPN_Fixture()
	try {
		Fixture.Prepare()
		AssertTrue(Fixture.Native.Rescan())
		Child := Fixture.Children[Fixture.Order.Length + 1]
		Child.TerminateAllowed := false
		AssertFalse(Fixture.Panel.Retire(false))
		Transition := Fixture.Transition("resume")
		AssertTrue(LLM_Menu_LocalServersOnResume())
		Intent := Fixture.Panel.ResumeIntent
		AssertTrue(LifecycleTransitionFinish(Transition))
		Fixture.ArmFailure := "throw"
		Failure := 0
		try LLM_Menu_LocalServersResumeFinished(Transition)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertTrue(Fixture.Panel.ResumeIntent == Intent, "failed queue registration must preserve the exact originating intent")
		AssertEqual(1, Fixture.Panel.RepairRecords.Count)
		AssertEqual(0, Fixture.Builds.Length)
		Fixture.ArmFailure := ""
		Child.TerminateAllowed := true
		Fixture.DriveRepair()
		AssertEqual(1, Fixture.Builds.Length)
		AssertFalse(Fixture.Panel.ResumeIntent is Map)
		AssertEqual(0, Fixture.Panel.RepairRecords.Count)
	} finally Fixture.Dispose()
}
Test("local server panel: failed post-Finish registration retains exact intent until actual repair", _LSPN_FailedResumeRetainsExactIntent)





; =========================================
; =========================================
; ======= 3/ Inert Canonical Status =======
; =========================================
; =========================================

_LSPN_InertStatusRows(Mode, Mutate := false) {
	Fixture := _LSPN_Fixture()
	global _LLM_LocalServerPanel, _LLM_LocalServerPanelInitBusy
	Definition := 0, Header := 0, Unavailable := 0, SavedCaption := ""
	SavedBusy := _LLM_LocalServerPanelInitBusy
	try {
		Definition := _MR_FindItemById("llm_menu", "llm_backend")["status_rows"]["unavailable"]
		AssertEqual(3, Definition.Length, "the actual generated declaration must contain exactly three rows")
		Header := Definition[2], Unavailable := Definition[3]
		SavedCaption := Unavailable["i18n"]
		if Mutate {
			Unavailable["i18n"] := "menu.llm.local_servers.rescan"
			Definition[2] := Unavailable
			Definition[3] := Header
		}
		if Mode == "cold" {
			_LLM_LocalServerPanel := unset
			_LLM_LocalServerPanelInitBusy := false
		} else {
			Fixture.BeginShutdown()
			AssertFalse(Fixture.World.Owner.Admit(), "the actual private owner must refuse before requesting unavailable rows")
		}
		; Count actual private-file reads, not a replacement source/HTTP stack.
		Fixture.World.Port["read"] := ObjBindMethod(Fixture.World, "Read")
		Reads := Fixture.World.ReadCalls
		Native := Fixture.Native
		Controller := Native.Controller.Generation
		View := Native.ViewGeneration, Rescan := Native.RescanGeneration
		Configuration := Native.ConfigurationGeneration, Models := Native.ModelGeneration
		PanelGeneration := Fixture.Panel.Generation, PanelView := Fixture.Panel.View
		LastSnapshot := Fixture.Panel.LastSnapshot
		Rows := LLM_Menu_LocalServersRows()
		AssertTrue(Rows is Array)
		AssertEqual(3, Rows.Length, "cold and refused source paths retain exact three-row data")
		AssertEqual(1, Rows[1].Count)
		AssertTrue(Rows[1]["separator"])
		AssertEqual(t(Mutate ? "menu.llm.local_servers.rescan" : "menu.llm.local_servers.header"), Rows[2]["label"])
		AssertEqual(t(Mutate ? "menu.llm.local_servers.header" : "menu.llm.unavailable"), Rows[3]["label"])
		for Index in [2, 3] {
			AssertEqual(2, Rows[Index].Count, "inert labels carry only their caption and disabled state")
			AssertTrue(Rows[Index]["disabled"])
			AssertFalse(Rows[Index].Has("action"))
			AssertFalse(Rows[Index].Has("items"))
			AssertFalse(Rows[Index].Has("submenu"))
		}
		AssertEqual(Reads, Fixture.World.ReadCalls, "inert data must not acquire private source images")
		AssertEqual(0, Fixture.Requests.Length, "inert status cannot acquire an HTTP request")
		AssertEqual(0, Fixture.Children.Length, "inert status cannot acquire a native child")
		AssertEqual(0, Fixture.Configs.Length, "inert status cannot stage private curl configuration")
		AssertEqual(0, Fixture.Builds.Length)
		AssertEqual(0, Fixture.Notifications.Length)
		AssertEqual(0, Fixture.RepairTimers.Count)
		AssertEqual(Controller, Native.Controller.Generation)
		AssertEqual(View, Native.ViewGeneration)
		AssertEqual(Rescan, Native.RescanGeneration)
		AssertEqual(Configuration, Native.ConfigurationGeneration)
		AssertEqual(Models, Native.ModelGeneration)
		AssertEqual(PanelGeneration, Fixture.Panel.Generation)
		AssertTrue(Fixture.Panel.View == PanelView)
		AssertTrue(Fixture.Panel.LastSnapshot == LastSnapshot)
		if Mode == "cold" {
			AssertFalse(IsSet(_LLM_LocalServerPanel), "the cold provider cannot initialize a panel")
			AssertFalse(_LLM_LocalServerPanelInitBusy)
		} else
			AssertTrue(_LLM_LocalServerPanel == Fixture.Panel)
	} finally {
		if Definition is Array && Header is Map && Unavailable is Map {
			Definition[2] := Header
			Definition[3] := Unavailable
			Unavailable["i18n"] := SavedCaption
		}
		_LLM_LocalServerPanelInitBusy := SavedBusy
		_LLM_LocalServerPanel := Fixture.Panel
		Fixture.Dispose()
	}
}
Test("local server panel: cold canonical status creates no runtime source or callbacks", _LSPN_InertStatusRows.Bind("cold"))
Test("local server panel: unavailable canonical status creates no HTTP source or callbacks", _LSPN_InertStatusRows.Bind("unavailable"))
Test("local server panel: cold status reads actual shared caption and order mutations", _LSPN_InertStatusRows.Bind("cold", true))
Test("local server panel: unavailable status reads actual shared caption and order mutations", _LSPN_InertStatusRows.Bind("unavailable", true))





; ===================================================
; ===================================================
; ======= 4/ Fenced Read-Only View Projection =======
; ===================================================
; ===================================================

_LSPB_Stamp(World) {
	World.ConfigImage .= "[_meta]`nschema_version = " ConfigMigrateCurrentVersion() "`n"
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
		_LSPB_Stamp(World)
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
		_LSPB_Stamp(Fixture.World)
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
		_LSPB_Stamp(this.World)
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





; ===============================================
; ===============================================
; ======= 6/ Deferred View Preparation ===========
; ===============================================
; ===============================================

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
