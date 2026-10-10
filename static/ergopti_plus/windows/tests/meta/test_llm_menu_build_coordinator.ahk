; tests/meta/test_llm_menu_build_coordinator.ahk

; ==============================================================================
; MODULE: LLM Menu Build Coordinator Wiring
; DESCRIPTION:
; AHK-010 source-boundary guard. Runtime behavior is covered by the companion
; unit test; this guard proves every production producer transfers work to that
; owner and none calls the raw detached builder directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMBCM_AllProducersUseTheCoordinator() {
	RequestProducers := [
		"_LLM_Menu_ApplyToggleCommitted",
		"_LLM_Menu_ApplyBackendCommitted",
		"_LLM_Menu_ApplyModelRuntimeCommitted",
		"_LLM_Menu_ApplyStandardCommitted",
		"_LLM_Menu_ApplyCurrentDepsFailure",
		"_LLM_Menu_ApplyOllamaPortCommitted",
		"_LLM_Menu_AuxBuild",
		"_LLM_Menu_PullModel"
	]
	for _, Name in RequestProducers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must remain source-visible")
		Assert(InStr(Body, "LLM_Menu_RequestBuild") > 0,
			Name . " must transfer its dirty state to the retained build owner")
		Assert(InStr(Body, "LLM_Menu_Build()") == 0,
			Name . " must never call the raw detached builder")
	}

	for _, Name in ["_LLM_Menu_OnHealthProbeDone",
			"_LLM_Menu_OnInstalledTagsProbeDone",
			"_LLM_Menu_OnDeleteCachedModelDone"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_LLM_Menu_AuxBuild(") > 0,
			Name . " must transfer changed auxiliary state to the retained owner")
		Assert(InStr(Body, "LLM_Menu_Build()") == 0,
			Name . " must never call the raw detached builder")
	}
	DeletePromptBody := _DriverFuncBody("_LLM_Menu_PromptDeleteCachedModel")
	Assert(InStr(DeletePromptBody, "_LLM_Menu_RecordDeleteReconcile") > 0,
		"delete dispatch must retain reconciliation before suspension can cancel it")

	ResumeBody := _DriverFuncBody("LLM_Menu_OnResume")
	Assert(InStr(ResumeBody, "_LLM_Menu_ServiceDeleteReconcile()") > 0,
		"resume must consume retained delete reconciliation")
	Assert(InStr(ResumeBody, "LLM_Menu_ServiceBuilds()") > 0,
		"resume must drain retained work without inventing a new generation")
	Assert(InStr(ResumeBody, "LLM_Menu_Build()") == 0)
}

_LMBCM_BootAndPostPullScheduleOwnedRequests() {
	Source := _DriverSourceNoComments()
	BootWorker := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(InStr(BootWorker,
		"_TrayRootScheduleBootProjectionIfDisabled(") > 0
		&& InStr(BootWorker,
		'LLM_Menu_RequestBuild.Bind("boot")') > 0,
		"the published cold root must schedule an owned request, not the raw builder")
	PullBody := _DriverFuncBody("_LLM_Menu_PullModel")
	Assert(InStr(PullBody,
		'LLM_Menu_RequestBuild.Bind("post_pull")') > 0,
		"post-pull completion must retain its request across Suspend")
	Assert(InStr(Source, "SetTimer(LLM_Menu_Build,") == 0,
		"no timer may bypass the menu build owner")
}

_LMBCM_RawBuilderIsSinglePassAndCoordinatorOwned() {
	RawBody := _DriverFuncBody("LLM_Menu_Build")
	RootWorkerBody := _DriverFuncBody("_LLM_Menu_PublishRoot")
	FactoryBody := _DriverFuncBody("_LLM_Menu_GetBuildCoordinator")
	RequestBody := _DriverFuncBody("LLM_Menu_RequestBuild")
	Assert(RawBody != "" && RootWorkerBody != ""
		&& FactoryBody != "" && RequestBody != "")
	Assert(InStr(RawBody, "static _Building") == 0
		&& InStr(RawBody, "_RequestedGeneration") == 0,
		"the raw builder must be one pass; generation ownership belongs to the coordinator")
	Assert(InStr(FactoryBody, "LLMMenuBuildCoordinator(") > 0
		&& InStr(FactoryBody, "LLM_Menu_Build") > 0,
		"only the coordinator factory may receive the raw builder callback")
	Assert(InStr(RequestBody, ".Request(Reason)") > 0,
		"the public request boundary must delegate to the generation owner")
	Assert(InStr(RawBody,
		"RebuildTrayMenu(0, _LLM_Menu_PublishRoot, true, true)") > 0,
		"the detached LLM builder must request a narrow projection that promotes to a full rebuild on contention")
	Assert(InStr(RootWorkerBody, "initMenu(PublishAuthorizeFn)") > 0,
		"the LLM root projection must attach the staged submenu through the root publication fence")
	Assert(InStr(RootWorkerBody, "InitSubMenus(") == 0
		&& InStr(RootWorkerBody, "_HS_InvalidatePersonalCache(") == 0,
		"an LLM-only repaint must reuse sibling submenus instead of repeating the full personal/extensions scan")
}

Test("llm menu coordinator: every producer transfers to one owner (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_AllProducersUseTheCoordinator)
Test("llm menu coordinator: boot and post-pull timers schedule owned requests (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_BootAndPostPullScheduleOwnedRequests)
Test("llm menu coordinator: raw builder is single-pass and owner-only (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_RawBuilderIsSinglePassAndCoordinatorOwned)


; Receive only the genuine committed callback through controlled effect producers.
_LMBCM_ToggleRecordingScript(Source, Framework, Receipt) {
	Source := _StripFullLineComments(Source)
	Code := _DriverMaskNonCode(&Source)
	Allowed := Map("_LLM_Menu_ApplyToggleCommitted", true, "Candidate", true, "ShowUi", true,
		"global", true, "LLM_HEALTH_PROBE_INTERVAL_MS", true, "LoggerInfo", true,
		"if", true, "else", true, "true", true, "false", true, "return", true,
		"SetTimer", true, "_LLM_Menu_FireHealthProbe", true,
		"LLM_Menu_ScheduleBackendLifecycle", true, "LLM_Menu_BackendLifecycleInvalidate", true,
		"LLM_Bridge_Stop", true, "LLM_Menu_RequestBuild", true)
	Position := 1, Scanned := 0
	while Found := RegExMatch(Code, "[A-Za-z_][A-Za-z0-9_]*", &Word, Position) {
		AssertTrue(Allowed.Has(Word[0]), "the exact toggle recorder refuses an uncontrolled effect: " Word[0])
		Scanned += 1
		Position := Found + StrLen(Word[0])
	}
	AssertTrue(Scanned > 0, "the controlled callback must contain executable tokens")
	AssertFalse(InStr(Code, "%") || InStr(Code, "#"), "computed effects and directives are not recording ports")
	StrReplace(Code, "SetTimer(", "", , &TimerCount)
	AssertEqual(2, TimerCount, "both exact timer effects must be recorded")
	Source := StrReplace(Source, "SetTimer(", "_LMTO_RecordTimer(")
	Quote(Value) {
		return Chr(34) StrReplace(StrReplace(Value, Chr(96), Chr(96) Chr(96)), Chr(34), Chr(96) Chr(34)) Chr(34)
	}
	Header := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
		. 'EnvSet("ERGOPTI_AHK_RESULTS_FILE", ' Quote(Receipt) ')`n'
		. "#Include " Framework "`n"
	Harness := '
(
global LLM_HEALTH_PROBE_INTERVAL_MS := 1750
global _LMTO_State := 0
LoggerInfo(Args*) {
	global _LMTO_State
	_LMTO_State["events"].Push("log")
}
_LLM_Menu_FireHealthProbe() {
	throw Error("A recording callback must not run the health probe.")
}
_LMTO_RecordTimer(Callback, Period) {
	global _LMTO_State
	AssertTrue(Callback == _LLM_Menu_FireHealthProbe, "the exact callback identity remains deferred")
	_LMTO_State["timer"] := Period
	_LMTO_State["events"].Push("timer")
}
LLM_Menu_ScheduleBackendLifecycle(ShowUi) {
	global _LMTO_State
	_LMTO_State["scheduled"] += 1
	_LMTO_State["show_ui"] := ShowUi
	_LMTO_State["events"].Push("schedule")
}
LLM_Menu_BackendLifecycleInvalidate(Stop) {
	global _LMTO_State
	AssertEqual(true, Stop)
	_LMTO_State["invalidated"] += 1
	_LMTO_State["events"].Push("invalidate")
}
LLM_Bridge_Stop() {
	global _LMTO_State
	_LMTO_State["stopped"] += 1
	_LMTO_State["events"].Push("stop")
}
LLM_Menu_RequestBuild(Reason) {
	global _LMTO_State, LLM_HEALTH_PROBE_INTERVAL_MS
	State := _LMTO_State
	State["builds"] += 1
	AssertEqual("toggle_committed", Reason)
	if State["enabled"] {
		AssertEqual(LLM_HEALTH_PROBE_INTERVAL_MS, State["timer"], "health ownership is armed before repaint")
		AssertEqual(1, State["scheduled"], "backend lifecycle is scheduled before repaint")
		AssertEqual(State["expected_ui"], State["show_ui"])
		AssertEqual(0, State["stopped"])
		AssertEqual(0, State["invalidated"])
	} else {
		AssertEqual(0, State["timer"], "even a held repaint observes the timer already cancelled")
		AssertEqual(1, State["invalidated"], "repaint cannot delay exact lifecycle invalidation")
		AssertEqual(1, State["stopped"], "bridge retirement precedes entry into the repaint")
		AssertEqual(0, State["scheduled"])
	}
	State["events"].Push("build")
	if State["throw_build"]
		throw Error("Controlled repaint refusal.")
	return true
}
_LMTO_Case(Enabled, ShowUi, ThrowBuild) {
	global _LMTO_State
	_LMTO_State := Map("enabled", Enabled, "expected_ui", ShowUi, "throw_build", ThrowBuild,
		"events", [], "timer", -1, "scheduled", 0, "show_ui", -1,
		"invalidated", 0, "stopped", 0, "builds", 0)
	Observed := "", Accepted := false
	try Accepted := _LLM_Menu_ApplyToggleCommitted(Map("enabled", Enabled), ShowUi)
	catch as Err
		Observed := Err.Message
	AssertEqual(ThrowBuild ? "Controlled repaint refusal." : "", Observed)
	AssertEqual(!ThrowBuild, Accepted)
	AssertEqual(1, _LMTO_State["builds"])
	Expected := Enabled ? ["log", "timer", "schedule", "build"] : ["log", "timer", "invalidate", "stop", "build"]
	AssertEqual(Expected.Length, _LMTO_State["events"].Length)
	for Index, Event in Expected
		AssertEqual(Event, _LMTO_State["events"][Index], "all committed effects keep exact order")
}
TOGGLE_REGISTRATIONS
ACTUAL_CALLBACK
RunTests()
)'
	; Registrations belong only to the isolated recording child.
	Registrations := 'Test("toggle recording: disable is retired at a held repaint boundary", _LMTO_Case.Bind(false, true, false))'
		. "`n" 'Test("toggle recording: disable remains retired after repaint throws", _LMTO_Case.Bind(false, true, true))'
		. "`n" 'Test("toggle recording: enable is scheduled before a held repaint", _LMTO_Case.Bind(true, true, false))'
		. "`n" 'Test("toggle recording: enable keeps lifecycle after repaint throws", _LMTO_Case.Bind(true, true, true))'
		. "`n" 'Test("toggle recording: hidden enable preserves captured UI admission", _LMTO_Case.Bind(true, false, false))'
		. "`n" 'Test("toggle recording: hidden enable repaint error stays visible", _LMTO_Case.Bind(true, false, true))'
	Harness := StrReplace(Harness, "TOGGLE_REGISTRATIONS", Registrations)
	return Header StrReplace(Harness, "ACTUAL_CALLBACK", Source)
}

_LMBCM_ToggleRuntimeBeforeRepaint() {
	static Retained := []
	Source := _DriverFuncBody("_LLM_Menu_ApplyToggleCommitted")
	AssertTrue(Source != "", "the actual committed callback must remain available")
	Directory := A_Temp "\ergopti-toggle-order-" A_ScriptHwnd "-" A_TickCount "-" Random(100000, 999999)
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int"))
	Task := 0, Quiesced := true
	State := Map("done", false, "exit", -1, "output", "")
	Completed(ExitCode, Output, Errors) {
		State["exit"] := ExitCode
		State["output"] := Output
		State["done"] := true
	}
	try {
		Script := Directory "\recording.ahk", Receipt := Directory "\results.tap"
		Body := _LMBCM_ToggleRecordingScript(Source, A_ScriptDir "\test_framework.ahk", Receipt)
		AssertTrue(FSWriteCreateDurable(Script, Body))
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Completed, , , 65536)
		Quiesced := false
		AssertTrue(Task.start())
		Started := A_TickCount
		while !State["done"] && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		AssertTrue(State["done"], "the exact six recording states must finish within the child budget")
		AssertEqual(0, State["exit"], State["output"])
		AssertTrue(FileExist(Receipt) != "")
		Result := FileRead(Receipt, "UTF-8")
		AssertContains(Result, "# 6 passed, 0 failed.")
		for Name in ["disable is retired", "disable remains retired", "enable is scheduled",
			"enable keeps lifecycle", "hidden enable preserves", "hidden enable repaint error"]
			AssertContains(Result, Name, "every effect/error vector must execute")
	} finally {
		if IsObject(Task) {
			try Quiesced := Task.requestTerminate() == true
			catch
				Quiesced := false
		}
		if Quiesced
			DirDelete(Directory, true)
		else {
			Retained.Push({ task: Task, directory: Directory, state: State })
			throw Error("The toggle recording child retains exact retirement debt.")
		}
	}
}
Test("llm toggle ordering: committed runtime precedes held or throwing repaint (toggle-runtime-before-repaint)",
	_LMBCM_ToggleRuntimeBeforeRepaint)
