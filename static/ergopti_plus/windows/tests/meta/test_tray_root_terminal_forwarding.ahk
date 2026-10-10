; tests/meta/test_tray_root_terminal_forwarding.ahk

; ==============================================================================
; MODULE: Tray-Root Terminal Forwarding Meta Test
; DESCRIPTION:
; Guards every production hop that carries a tray-root generation's exact
; terminal authorization ticket to the irreversible native root replacement.
;
; Injected unit workers receive the authorizer directly, so those tests stay
; green if the real _TrayRootBuildOnce -> initMenu -> TrayMenuStage_Publish
; chain drops it. The class-wide call-site counts below make any new direct
; builder fail until it joins the same coordinator-owned path.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Production terminal forwarding ================
; ==========================================================
; ==========================================================

_TRF_ProductionChainForwardsExactTerminalAuthorization() {
	Drain := _DriverFuncBody("_TrayRootDrain")
	Assert(Drain != "", "_TrayRootDrain() must exist")
	BindPos := InStr(Drain,
		"PublishAuthorizeFn := _TrayRootPublishAuthorized.Bind(")
	BuildPos := InStr(Drain,
		"_TrayRootBuildOnce(PublishAuthorizeFn, WorkerFn)")
	Assert(BindPos > 0 and BuildPos > BindPos,
		"the root owner must bind its exact generation/lifecycle ticket and pass it to the selected worker")

	RootBuild := _DriverFuncBody("_TrayRootBuildOnce")
	Assert(RootBuild != "", "_TrayRootBuildOnce() must exist")
	Assert(InStr(RootBuild,
		"WorkerFn.Call(PublishAuthorizeFn)") > 0,
		"an injected root worker must receive the exact terminal authorizer")
	Assert(InStr(RootBuild,
		"initMenu(PublishAuthorizeFn)") > 0,
		"the canonical production root worker must pass its terminal authorizer to initMenu")

	BootBuild := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(BootBuild != "", "_TrayRootBuildBoot() must exist")
	Assert(InStr(BootBuild,
		"Published := initMenu(PublishAuthorizeFn)") > 0,
		"the deferred boot worker must pass its terminal authorizer to initMenu")
	LlmProjection := _DriverFuncBody("_LLM_Menu_PublishRoot")
	Assert(LlmProjection != "", "_LLM_Menu_PublishRoot() must exist")
	Assert(InStr(LlmProjection,
		"initMenu(_LLM_Menu_PreparedRootCurrent.Bind(Submenu, PublishAuthorizeFn), false, Submenu)") > 0,
		"the narrow LLM projection must pass its terminal authorizer to initMenu")

	CandidateTicket := _DriverFuncBody("_LLM_Menu_PreparedRootCurrent")
	Assert(InStr(CandidateTicket, "Authorized := PublishAuthorizeFn.Call()") > 0
		&& InStr(CandidateTicket, "Authorized == 1 && _LLM_Menu_Handle == Submenu") > 0,
		"the candidate fence must retain the original strict terminal ticket and its post-call identity check")

	Shell := _DriverFuncBody("_TrayRootBuildShell")
	Assert(Shell != "", "the early global-command worker must exist")
	Assert(InStr(Shell, "initMenu(PublishAuthorizeFn, true)") > 0,
		"the global-command root must join the sole authorized native publisher")
	ShellRequest := _DriverFuncBody("BuildReadyTrayShell")
	Assert(ShellRequest != "", "the shell request must exist")
	Assert(InStr(ShellRequest, "RebuildTrayMenu(0, _TrayRootBuildShell, false)") > 0,
		"the shell worker must receive the root coordinator's terminal ticket")

	InitBody := _DriverFuncBody("initMenu")
	Assert(InitBody != "", "initMenu() must exist")
	Assert(InStr(InitBody,
		"TrayMenuStage_Publish(PublishAuthorizeFn)") > 0,
		"initMenu must forward the exact authorizer to staged publication")
	Assert(InStr(InitBody, "TrayMenuStage_Publish()") = 0,
		"initMenu must never publish a root without terminal authorization")

	PublishBody := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(PublishBody != "", "TrayMenuStage_Publish() must exist")
	AuthorizePos := InStr(PublishBody,
		"Authorized := AuthorizeFn.Call()")
	ReplacePos := InStr(PublishBody,
		"MenuDispatcher_BeginReplacement()")
	DeletePos := InStr(PublishBody, "A_TrayMenu.Delete()")
	Assert(AuthorizePos > 0 and ReplacePos > AuthorizePos
		and DeletePos > ReplacePos,
		"terminal authorization must precede dispatcher retirement and root deletion")

	DriverSource := _DriverSourceNoComments()
	Assert(DriverSource != "", "driver source must be readable")
	StrReplace(DriverSource, "initMenu(", "", true, &InitMenuSiteCount)
	AssertEqual(5, InitMenuSiteCount,
		"initMenu may appear only at its declaration and the four coordinator-owned production workers, including the ready shell")
	StrReplace(DriverSource, "TrayMenuStage_Publish(", "", true,
		&PublishSiteCount)
	AssertEqual(2, PublishSiteCount,
		"TrayMenuStage_Publish may appear only at its declaration and inside initMenu")
	BootBody := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(BootBody != "", "the boot publication owner must exist")
	StageClosed := InStr(BootBody, 'BootProfile_StageEnd("tray menu"')
	AdmissionOpen := InStr(BootBody, "_TrayRootBootDetailsPending := false")
	Handoff := InStr(BootBody, "_TrayStartupClick.NotifyReady()")
	Assert(StageClosed > 0 && AdmissionOpen > StageClosed && Handoff > AdmissionOpen,
		"both ordinary clicks and retained navigation must wait until construction timing closes")
}
Test("tray root: production terminal authorization reaches native publication (tray-root-terminal-forwarding)",
	_TRF_ProductionChainForwardsExactTerminalAuthorization)




; ==========================================================
; ==========================================================
; ======= 2/ Lifecycle forwarding ==========================
; ==========================================================
; ==========================================================

_TRF_LifecycleInvalidationAndRetainedServiceAreWired() {
	SuspendEnter := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(SuspendEnter != "", "Ergopti_OnSuspendEnter() must exist")
	ReleasePos := InStr(SuspendEnter, "TapHoldReleaseSyntheticKeys()")
	InvalidatePos := InStr(SuspendEnter, "_TrayRootOnSuspendEnter()")
	FirstLogPos := InStr(SuspendEnter, "LoggerStart(")
	Assert(ReleasePos > 0 and InvalidatePos > ReleasePos
		and FirstLogPos > InvalidatePos,
		"tray-root lifecycle invalidation must run after balancing synthetic keys and before the first yielding suspend log")
	for _, Reactor in ["_HSLR_OnSuspendEnter()",
		"LanguageMenu_OnSuspendEnter()", "LLM_Menu_OnSuspendEnter()"] {
		ReactorPos := InStr(SuspendEnter, Reactor)
		Assert(ReactorPos = 0 or ReactorPos > InvalidatePos,
			"tray-root invalidation must precede sibling suspend reactor " . Reactor)
	}

	Watchdog := _DriverFuncBody("_SuspendStateWatchdog")
	Assert(Watchdog != "", "_SuspendStateWatchdog() must exist")
	GuardPos := InStr(Watchdog, "if !A_IsSuspended {")
	ServicePos := InStr(Watchdog,
		"RootService := _TrayRootServiceRetained", false, GuardPos)
	BoundaryPos := InStr(Watchdog,
		"_TrayRootServiceRetainedWork(", false, ServicePos)
	Assert(GuardPos > 0 and ServicePos > GuardPos
		and BoundaryPos > ServicePos,
		"the active watchdog must drain retained generic roots only after resume")
}
Test("tray root: lifecycle invalidation and retained service are wired (tray-root-lifecycle-forwarding)",
	_TRF_LifecycleInvalidationAndRetainedServiceAreWired)
