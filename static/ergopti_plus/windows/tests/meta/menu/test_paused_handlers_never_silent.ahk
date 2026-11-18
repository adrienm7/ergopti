; tests/meta/menu/test_paused_handlers_never_silent.ahk

; ==============================================================================
; MODULE: Paused Handlers Never Refuse In Silence
; DESCRIPTION:
; A pause stops typing, not configuration (EDD-1, maintainer 2026-11-12): every
; tray row stays live under a pause, so every handler a click reaches runs while
; paused. The Windows editors and menus used to refuse under a pause, most of
; them with a log line only, so a click looked dead (paused-refusal-notice); the
; pause greyed the Layout rows and the hotstring order rows besides.
;
; MECHANISM: a class loop, not a list of the sites that were fixed. Every
; top-level function of the configuration surfaces (the tray menus, the
; settings and the editor pages) that reads A_IsSuspended is either:
; - told: its pause guard opens a block that calls NotifyPausedRefusal, so a
;   click that must wait for the resume says so; or
; - classified below with why the pause is not a click refusal (typing runtime
;   deferred to the resume, a transition fence, a snapshot field).
; A new pause gate in these surfaces fails here until it is told or classified,
; and a classified function that no longer reads the pause must leave the list.
; Methods of classes are not scanned: the ones in these surfaces are runtime
; owners (menu prewarming, boot replay). The local server panel is the one
; class whose rows are configuration: its own case below names its methods.
; The behaviour of each handler made to run paused is exercised by its own unit
; suite under a real Suspend (paths editor, model browser, layout manager, magic
; key capture, hotstring order, physical editor, AI scope restore, local
; server rows).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Classified readers =======
; =====================================
; =====================================

; Function name -> why its pause read refuses no click in silence.
_PHNS_Classified() {
	static Runtime := "serves typing or predictions; deferred to the resume by its owner"
	static Fence := "fences a capture or a build against a pause transition"
	static Snapshot := "records the pause in an intent snapshot that a transition retires"
	static Told := "its refusal is told by a caller or a page reason"
	return Map(
		; The AI runtime: probes, bridge, bootstrap, completions and hotkeys.
		"_LLM_Menu_FireHealthProbe", Runtime, "_LLM_Menu_FireInstalledTagsProbe", Runtime,
		"LLM_Menu_TryStartBridge", Runtime, "LLM_Menu_StartBridge", Runtime,
		"LLM_Menu_OnResume", Runtime, "LLM_Menu_LocalServersOnResume", Runtime,
		"_LLM_Menu_AuxOwnerIsCurrent", Runtime, "_LLM_Menu_ServiceDeleteReconcile", Runtime,
		"_LLM_Menu_AuxBuild", Runtime,
		"_LLM_Menu_OnDeleteCachedModelDone", "a model removal that settles paused is reconciled at the resume",
		"LLM_Menu_RunBackendLifecycle", Runtime, "LLM_Menu_BootstrapOllama", Runtime,
		"LLM_Menu_OnDepsReady", Runtime, "LLM_Menu_OnDepsFailed", Runtime,
		"_LLM_Menu_RequireFirstRestoreHotkeys", Runtime, "LLM_Menu_ActivateDeferredHotkeys", Runtime,
		"_LLM_Menu_SavedApiEntryCurrent", Runtime, "_LLM_Menu_OnApiValidationDone", Runtime,
		"_LLM_Menu_OnApiTestDone", Runtime, "_LLM_Menu_ApiFailureCurrent", Runtime,
		"_LLM_Menu_TestPredictionIsCurrent", Runtime, "_LLM_MBW_NextListing", Runtime,
		"LLM_Menu_TrayTitle", "hides the health dot of a paused prediction runtime",
		"MenuPopulation_Resume", "resumes the menu prewarming, which a menu open replaces",
		"ScriptShortcutLiveChords", "keeps the chords of pause time, as decided on 2026-11-14",
		"ScriptShortcutSlotRunsAction", "keeps the chords of pause time, as decided on 2026-11-14",
		"_MI_StageSuspend", "checks the pause row itself",
		; Fences against a pause transition.
		"_LLM_Menu_BuildHeld", Fence, "_LLM_ModelBrowser_VisibilityClaim", Fence,
		"_LLM_ModelBrowser_VisibilityCurrent", Fence, "MagicKeyEditor", Fence,
		"MagicKeySourceCapture", Fence,
		; Snapshot fields compared by intent owners.
		"_LLM_Menu_EnableSnapshot", Snapshot, "_LLM_Menu_PrivacySnapshot", Snapshot,
		"_LLM_Menu_InfoBarSnapshot", Snapshot, "_LLM_Menu_IndentSnapshot", Snapshot,
		"_LLM_Menu_StreamingSnapshot", Snapshot, "_LAY_NumberRowRuntime", Snapshot,
		"_LLM_Menu_ProfileRows", "passes the pause reader to rows that run while paused",
		"_LLM_Menu_CreateProfileRow", "passes the pause reader to a row that runs while paused",
		"_LLM_Menu_CloneProfileRow", "passes the pause reader to a row that runs while paused",
		; Told elsewhere: the manual prediction refusal and the page reasons.
		"LLM_Menu_TriggerPrediction", Told, "LLM_Menu_TestPrediction", Told,
		"LLM_Menu_TriggerPredictionWith", Told, "LLM_Menu_StartLiveMode", Told,
		"_LLM_MBW_OllamaInstallJson", "greys the runtime install with model_browser.install_paused",
		; The AI switch: turning it on waits for the resume, greyed with
		; menu.llm.save_unavailable (decided by the agent on 2026-11-14, accepted
		; by the coordinator, alike on the three OS).
		"_LLM_Menu_StateGetters", "turning the AI on waits for the resume, greyed with its reason")
}

; The configuration surfaces: the tray menus, the settings and the editors.
_PHNS_Sources() {
	return _DriverDirsConcat("menu", "ui/menu", "hotstrings/ui/menu", "gestures/ui/menu", "settings", "ai/ui", "hotstrings/ui/hotstrings_config_window", "ui/layout_manager", "ui/action_picker", "ui/physical_shortcuts")
		. "`n" . _DriverFileSource("action_picker_webview.ahk")
		. "`n" . _DriverFileSource("editors.ahk")
}

; Every top-level function defined in Src, once.
_PHNS_TopLevelFunctions(Src) {
	Names := Map(), Out := []
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^([A-Za-z_][A-Za-z0-9_]*)\(", &M, Pos)) {
		Name := M[1]
		Pos += StrLen(M[0])
		if Names.Has(Name)
			continue
		Names[Name] := true
		Out.Push(Name)
	}
	return Out
}





; =================================================
; =================================================
; ======= 2/ No pause gate refuses silently =======
; =================================================
; =================================================

_PHNS_EveryPauseReaderIsToldOrClassified() {
	Classified := _PHNS_Classified()
	Readers := 0, Told := 0, Unknown := ""
	Seen := Map()
	for Name in _PHNS_TopLevelFunctions(_PHNS_Sources()) {
		Body := _StripFullLineComments(_DriverFuncBodyOrEmpty(Name))
		if Body == "" || !InStr(Body, "A_IsSuspended")
			continue
		Readers += 1
		Seen[Name] := true
		if RegExMatch(Body, "s)A_IsSuspended[^\n]*\{\s*NotifyPausedRefusal\(") {
			Told += 1
			continue
		}
		if !Classified.Has(Name)
			Unknown .= (Unknown == "" ? "" : ", ") . Name
	}
	AssertEqual("", Unknown,
		"a configuration handler reads the pause without telling the user: run it while paused (EDD-1) or call NotifyPausedRefusal in its guard")
	; A floor against a scan that reads nothing: the AI runtime alone holds
	; more than twenty classified readers, and three refusals are told.
	Assert(Readers >= 30 && Told >= 3,
		"the scan must reach the configuration surfaces (found " . Readers . " readers, " . Told . " told)")
	Stale := ""
	for Name in Classified
		if !Seen.Has(Name)
			Stale .= (Stale == "" ? "" : ", ") . Name
	AssertEqual("", Stale, "a classified function no longer reads the pause in these surfaces: remove it from the list")
}
Test("pause: no configuration handler refuses a click in silence while paused (paused-handlers-never-silent)",
	_PHNS_EveryPauseReaderIsToldOrClassified)

; The handlers made to run while paused read no pause at all: each one is a
; regression of a refusal that the paused driver used to make (EDD-1).
_PHNS_ConfigurationHandlersReadNoPause() {
	for Fn in ["_PromptEdWeb_OnWebMessage", "_PromptEdWeb_Save", "_PromptEdWeb_ApplyProfileForContext",
			"_PathsEdWeb_OnWebMessage", "_PathsEdWeb_Browse", "_PathsEdWeb_Save", "_PathsEdNative_Browse",
			"FilePathsEditor", "_HCWWeb_OnWebMessage", "_HCWWeb_Dispatch",
			"_LayMgrWeb_OnWebMessage", "_LayMgrWeb_CommandCurrent", "_LAY_BuildLayoutMenu",
			"_ActPickWeb_OnWebMessage", "_ActPickWeb_Confirm", "_ActPickWeb_ProgramCapture",
			"_LLM_MBW_OnWebMessage", "_LLM_MBW_RunAction", "_LLM_MBW_ApplyModel",
			"_LLM_ModelBrowser_PickRow", "_LLM_ModelBrowser_NativeCurrent",
			"_LLM_Menu_PromptDeleteCachedModel", "_LLM_Menu_DeleteConfirmationCurrent",
			"_LLM_ApplyScope", "_HS_OrderCommit", "_HS_OrderClick", "_HS_OrderMenu",
			"PhysicalShortcutsMenuPort"]
		AssertEqual(0, InStr(_StripFullLineComments(_DriverFuncBody(Fn)), "A_IsSuspended"),
			Fn . " is a configuration path: a paused driver still applies it (EDD-1)")
}
Test("pause: the configuration handlers made to run while paused read no pause (paused-handlers-never-silent)",
	_PHNS_ConfigurationHandlersReadNoPause)

; The AI menu's local server rows are built by a class, which the scans above
; do not reach. A model choice, an address and a key commit while paused, so the
; methods on their path read no pause, the shared row builder greys no row for a
; pause, and the rescan, which talks to the servers, tells its wait
; (paused-local-server-rows).
_PHNS_LocalServerRowsRunPaused() {
	Panel := _DriverFileSource("local_server_panel.ahk")
	for Method in ["Rows", "_PrepareRows", "_Render", "_Current", "_HeldCurrent", "_PromptAddress",
			"_PromptKey", "_ApplyNonCritical", "_QueuePreparation", "_PreparationFence"] {
		Body := _DriverExtractFunctionBody(&Panel, Method)
		Assert(Body != "", "LLM_LocalServerPanel." . Method . " must exist")
		AssertEqual(0, InStr(Body, "A_IsSuspended"),
			"LLM_LocalServerPanel." . Method . " is on a local server row's configuration path (EDD-1)")
	}
	Rescan := _DriverExtractFunctionBody(&Panel, "_RescanNonCritical")
	Assert(RegExMatch(Rescan, "s)A_IsSuspended[^\n]*\{\s*NotifyPausedRefusal\("),
		"the paused rescan must say it waits for the resume")
	global _SharedDir
	Owner := _DriverProductionFileForSymbol("LocalServerMenuRows", _SharedDir)
	Assert(Owner != "", "the shared local server row builder must exist")
	Builder := FileRead(Owner, "UTF-8")
	AssertEqual(0, InStr(_DriverExtractFunctionBody(&Builder, "LocalServerMenuRows"), "paused"),
		"the shared local server rows must not grey for a pause")
}
Test("pause: the local server rows run while paused and their rescan tells its wait (paused-handlers-never-silent)",
	_PHNS_LocalServerRowsRunPaused)
