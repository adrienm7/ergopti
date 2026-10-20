; tests/meta/modules/llm/menu/test_llm_menu_caller_child_full_root.ahk

; ==============================================================================
; MODULE: LLM Menu Caller Child Survives a Full Root Rebuild
; DESCRIPTION:
; An AI toggle builds the IA submenu once (LLM_Menu_Build) and asks the tray
; root to attach it through a narrow worker. While the root is busy or its boot
; details are still pending, the queue replaces that worker with a full
; rebuild, and the full rebuild used to stage the AI row through its default
; builder, which resets the in-tray flag and constructs the IA submenu a second
; time (llm-caller-child-survives-full-root). The real root queue, root
; projection and AI builder run here in an isolated child process, with only
; the menu leaves recorded, so the count of IA constructions is the genuine one.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMCC_Quote(Value) {
	return Chr(34) StrReplace(StrReplace(Value, Chr(96), Chr(96) Chr(96)), Chr(34), Chr(96) Chr(34)) Chr(34)
}

; The genuine inline IA branch of LLM_Menu_Init, which a full root reaches
; through _MI_StageLlm; the rest of the initializer (settings, probes) is not
; part of the root composition.
_LMCC_InlineInit() {
	Init := _DriverFuncBodyOrEmpty("LLM_Menu_Init")
	AssertTrue(Init != "", "LLM_Menu_Init must remain source-visible")
	Code := _DriverMaskNonCode(&Init)
	Start := InStr(Code, "if !_LLM_Menu_InTray {")
	AssertTrue(Start > 0, "default root staging must retain its inline IA construction branch")
	Open := InStr(Code, "{", , Start), Depth := 1, Position := Open + 1
	while Position <= StrLen(Code) && Depth > 0 {
		Char := SubStr(Code, Position++, 1)
		if Char == "{"
			Depth += 1
		else if Char == "}"
			Depth -= 1
	}
	AssertEqual(0, Depth)
	; The else branch re-attaches a submenu already in the tray.
	Rest := SubStr(Code, Position)
	AssertTrue(RegExMatch(Rest, "^\s*else if IsObject\(_TrayMenuStage\) \{"),
		"the inline branch must keep its re-attachment sibling")
	Open := InStr(Code, "{", , Position), Depth := 1, Position := Open + 1
	while Position <= StrLen(Code) && Depth > 0 {
		Char := SubStr(Code, Position++, 1)
		if Char == "{"
			Depth += 1
		else if Char == "}"
			Depth -= 1
	}
	AssertEqual(0, Depth)
	return "LLM_Menu_Init(Options, Activate) {`n"
		. "global _LLM_Menu_InTray, _LLM_Menu_Handle, _LLM_Menu, _TrayMenuStage`n"
		. SubStr(Init, Start, Position - Start) "`n}`n"
}

_LMCC_Script(Framework, Receipt) {
	Sources := ""
	for Name in ["LLM_Menu_Build", "_LLM_Menu_PublishRoot",
			"_LLM_Menu_PreparedRootCurrent", "_LLM_Menu_ReplacePublishedRow",
			"initMenu", "_MI_TopLevelBuilders", "_MI_StageTopLevel",
			"_MI_StageLlm", "_MI_StagePrebuiltLlm",
			"TrayMenuItemCount", "TrayMenuItemCaption", "TrayMenuSubmenuHandle",
			"TrayMenuRebindSubmenu",
			"RebuildTrayMenu", "_TrayRootRequestAndTryAcquire", "_TrayRootClaimLatest",
			"_TrayRootDrain", "_TrayRootBuildOnce", "_TrayRootPublishAuthorized",
			"_TrayRootRelease", "_TrayRootTryReleaseFailed",
			"_TrayRootFinishReportableFailure", "_TrayRootFinishOrdinaryFailure",
			"_TrayRootReportTerminalFailure", "_TrayRootRetireFatal",
			"_TrayRootFirstPublicationPending"] {
		Body := _DriverFuncBodyOrEmpty(Name)
		AssertTrue(Body != "", "the actual root composition subject must exist: " Name)
		Sources .= Body "`n"
	}
	Sources := StrReplace(Sources, "A_TrayMenu.Check(", "_LMCC_TrayCheck(")
	Sources := StrReplace(Sources, "A_TrayMenu.Uncheck(", "_LMCC_TrayCheck(")
	Sources .= _LMCC_InlineInit()
	Header := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
		. 'EnvSet("ERGOPTI_AHK_RESULTS_FILE", ' _LMCC_Quote(Receipt) ')`n'
		. "#Include " Framework "`n"
	Harness := '
(
global _LMCC := 0
global _LLM_Menu := Map("enabled", true)
global _LLM_Menu_Handle := 0, _LLM_Menu_InTray := true
global _DriverInputInitPending := false, _IniCache := Map()
global _TrayMenuStage := false
global _TrayTitleCache := Map(), _FmtCountCache := Map(), _I18nSortedLocalesCache := false
global _TrayRootRequestedGeneration := 0, _TrayRootPublishedGeneration := 0
global _TrayRootActive := false, _TrayRootBootDetailsPending := false
global _TrayRootLifecycleEpoch := 0
global _TrayRootLatestAuthorizeFn := 0, _TrayRootLatestWorkerFn := 0
global _TrayRootLatestCallerLlm := 0
global _TrayRootRetryGeneration := 0, _TrayRootAutomaticRetryCount := 0
global _TRAY_ROOT_AUTOMATIC_RETRY_LIMIT := 3
class TrayRootRetryPendingError extends Error {
}
class TrayRootFatalContextError extends Error {
}
LoggerInfo(Args*) => 0
LoggerDebug(Args*) => 0
LoggerWarn(Args*) => 0
LoggerError(Args*) {
 global _LMCC
 _LMCC["errors"].Push(Args[2])
}
TickElapsed(Args*) => 0
t(Key, Args*) => Key
BootProfile_Mark(Args*) => 0
BootProfile_StageBegin(Args*) => 0
BootProfile_StageEnd(Args*) => 0
BootProfile_StageAbort(Args*) => 0
ErrorNet_Describe(Err) => Err.Message
_HS_InvalidateCaches() => 0
_HS_InvalidatePersonalCache() => 0
MenuManifest_InvalidateCache() => 0
LLM_Menu_BuildSavedOpts(Cache) => Map()
_LLM_Menu_LoadAppProfileOverridesFromCache(Args*) => 0
_LMCC_TrayCheck(Args*) => 0
_MR_IsForAhk(Entry) => true
MenuRenderer_StageDisabledTopLevel(Args*) => 0
MenuDispatcher_PruneMenu(Args*) => 0
MenuDispatcher_BeginReplacement(Args*) => 0
MenuPopulation_Publish(Args*) => 0
TrayMenu_ApplyPauseGreying(Args*) => 0
InitSubMenus() {
 global _LMCC
 _LMCC["full_rebuilds"] += 1
}
TrayMenuStage_Begin() {
 global _TrayMenuStage
 _TrayMenuStage := []
}
TrayMenuStage_Abort() {
 global _TrayMenuStage
 _TrayMenuStage := false
}
TrayMenuStage_Add() => 0
TrayMenuStage_Check(Args*) => 0
TrayMenuStage_AddFeature(Label, Target) {
 global _TrayMenuStage
 _TrayMenuStage.Push(Map("label", Label, "target", Target))
}
TrayMenuStage_Publish(AuthorizeFn) {
 global _TrayMenuStage, _LMCC
 Stage := _TrayMenuStage
 _TrayMenuStage := false
 Accepted := AuthorizeFn.Call()
 if !((Accepted is Integer) && Accepted == 1)
  return false
 for Row in Stage
  if Row["label"] == "menu.llm.title"
   _LMCC["published_ai"].Push(Row["target"])
 return true
}
MenuManifest_LoadTopLevel() => [Map("id", "metrics"), Map("id", "llm")]
_MI_StageLayout() => 0
_MI_StageHotstrings() => 0
_MI_StageAgent() => 0
_MI_StageShortcuts() => 0
_MI_StageTapHolds() => 0
_MI_StageGestures() => 0
_MI_StageConfiguration() => 0
_MI_StageLanguage() => 0
_MI_StageAbout() => 0
_MI_StageSuspend() => 0
_MI_StageReload() => 0
_MI_StageQuit() => 0
_MI_StageDebug() => 0
_MI_StageMetrics() => TrayMenuStage_AddFeature("metrics", Menu())
LLM_Menu_BuildSubmenu() {
 global _LMCC
 Candidate := Menu()
 _LMCC["constructed"].Push(Candidate)
 return Candidate
}
_LMCC_Reset(Busy, DetailsPending) {
 global _LMCC, _LLM_Menu_Handle, _LLM_Menu_InTray
 global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
 global _TrayRootActive, _TrayRootBootDetailsPending
 _LMCC := Map("constructed", [], "published_ai", [], "full_rebuilds", 0, "errors", [])
 ; The boot root is already published; the AI row holds the boot child.
 _LLM_Menu_Handle := Menu(), _LLM_Menu_InTray := true
 _TrayRootRequestedGeneration := 1, _TrayRootPublishedGeneration := 1
 _TrayRootActive := Busy, _TrayRootBootDetailsPending := DetailsPending
}
; Boot details still pending, root idle: the toggle thread runs the full rebuild.
_LMCC_PendingRootAttachesTheBuiltChild() {
 global _LMCC, _LLM_Menu_Handle, _TrayRootBootDetailsPending
 _LMCC_Reset(false, true)
 AssertTrue(LLM_Menu_Build())
 AssertEqual(1, _LMCC["constructed"].Length, "one AI toggle constructs the IA submenu once")
 AssertEqual(1, _LMCC["full_rebuilds"], "the pending root takes over as one full rebuild")
 AssertEqual(1, _LMCC["published_ai"].Length)
 AssertTrue(_LMCC["published_ai"][1] == _LMCC["constructed"][1],
  "the full root attaches the exact child the AI build constructed")
 AssertTrue(_LLM_Menu_Handle == _LMCC["constructed"][1])
 AssertFalse(_TrayRootBootDetailsPending, "the full root settles the pending boot details")
 AssertEqual(0, _LMCC["errors"].Length)
}
; A full rebuild in flight: the AI request queues and the owner drains it.
_LMCC_BusyRootDrainAttachesTheBuiltChild() {
 global _LMCC, _TrayRootActive, _TrayRootPublishedGeneration
 _LMCC_Reset(true, false)
 AssertTrue(LLM_Menu_Build(), "a queued AI request is accepted")
 AssertEqual(1, _LMCC["constructed"].Length)
 AssertEqual(0, _LMCC["published_ai"].Length, "nothing publishes while the owner is busy")
 AssertTrue(_TrayRootDrain(), "the busy owner drains the latest request")
 AssertEqual(1, _LMCC["constructed"].Length, "draining the queue constructs no second IA submenu")
 AssertEqual(1, _LMCC["full_rebuilds"])
 AssertTrue(_LMCC["published_ai"][1] == _LMCC["constructed"][1])
 AssertEqual(2, _TrayRootPublishedGeneration)
 AssertFalse(_TrayRootActive)
}
; A later request that lends no child (a language change) must not reuse it.
_LMCC_LaterRequestWithoutChildBuildsItsOwn() {
 global _LMCC
 _LMCC_Reset(true, false)
 AssertTrue(LLM_Menu_Build())
 AssertTrue(RebuildTrayMenu())
 AssertTrue(_TrayRootDrain())
 AssertEqual(2, _LMCC["constructed"].Length, "a request without a child stages a fresh IA submenu")
 AssertTrue(_LMCC["published_ai"][1] == _LMCC["constructed"][2])
}
; A child replaced before the drain is never attached.
_LMCC_WithdrawnChildIsNotAttached() {
 global _LMCC, _LLM_Menu_Handle
 _LMCC_Reset(true, false)
 AssertTrue(LLM_Menu_Build())
 _LLM_Menu_Handle := Menu()
 AssertTrue(_TrayRootDrain())
 AssertEqual(2, _LMCC["constructed"].Length)
 AssertTrue(_LMCC["published_ai"][1] == _LMCC["constructed"][2],
  "the root stages the live IA submenu, never the withdrawn one")
 AssertEqual(0, _LMCC["errors"].Length)
}
Test("caller child: pending root attaches the built child", _LMCC_PendingRootAttachesTheBuiltChild)
Test("caller child: busy root drain attaches the built child", _LMCC_BusyRootDrainAttachesTheBuiltChild)
Test("caller child: later request without child builds its own", _LMCC_LaterRequestWithoutChildBuildsItsOwn)
Test("caller child: withdrawn child is not attached", _LMCC_WithdrawnChildIsNotAttached)
SUBJECTS
RunTests()
)'
	return Header StrReplace(Harness, "SUBJECTS", Sources)
}

_LMCC_FullRootReusesTheCallerChild() {
	static Retained := []
	Directory := A_Temp "\ergopti-llm-caller-child-" A_ScriptHwnd "-" A_TickCount "-" Random(100000, 999999)
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int"))
	State := Map("done", false, "exit", -1, "output", "", "errors", "")
	Completed(ExitCode, Output, Errors) {
		State["done"] := true, State["exit"] := ExitCode
		State["output"] := Output, State["errors"] := Errors
	}
	Task := 0, Quiesced := true
	try {
		Script := Directory "\caller_child.ahk", Receipt := Directory "\results.tap"
		AssertTrue(FSWriteCreateDurable(Script, _LMCC_Script(A_ScriptDir "\test_framework.ahk", Receipt)))
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Completed, , , 65536)
		Quiesced := false
		AssertTrue(Task.start())
		Started := A_TickCount
		while !State["done"] && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		AssertTrue(State["done"], "the isolated root queue child must exit naturally")
		AssertEqual(0, State["exit"], State["output"])
		AssertEqual("", State["errors"])
		Result := FileRead(Receipt, "UTF-8")
		AssertContains(Result, "# 4 passed, 0 failed.", Result)
		for Name in ["pending root attaches", "busy root drain attaches",
				"later request without child", "withdrawn child is not attached"]
			AssertContains(Result, "caller child: " Name)
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
			throw Error("The caller child root queue process retains exact retirement debt.")
		}
	}
}
Test("llm root queue: a full rebuild attaches the AI child the toggle built (llm-caller-child-survives-full-root)",
	_LMCC_FullRootReusesTheCallerChild)
