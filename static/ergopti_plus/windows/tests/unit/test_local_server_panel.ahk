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
