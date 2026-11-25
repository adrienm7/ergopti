; modules/shortcuts/auto_click.ahk

; ==============================================================================
; MODULE: Anti-Sleep Mode and Auto-Clicker (Windows)
; DESCRIPTION:
; The Windows owner of the anti-sleep mode's presets and auto-clicker. Ctrl+M
; (ToggleActivitySimulation) runs the active preset: its keep-awake part is
; the activity simulation of modules/shortcuts/win.ahk, its auto-click part
; the session of modules/shortcuts/auto_click_session.ahk with Windows ports.
; The user's presets document is auto_click\presets.json in the configuration
; folder, edited through modules/shortcuts/keep_awake_presets.ahk.
;
; FEATURES & RATIONALE:
; 1. The click is AutoHotkey's own Click, which the keep-awake cancellation
;    hotkeys ignore (script-generated input at SendLevel 0), so a click never
;    ends the mode; the pointer then goes back where it was.
; 2. Fail closed: a locked session (no input desktop), Suspend or a secure
;    field stops every click.
; 3. The auto-clicker ends with the keep-awake session it started with, so the
;    first physical input still ends the whole mode (agent decision of
;    2026-11-25, as on macOS and Linux).
; 4. The document is written atomically (a sibling file, then FileMove) and
;    only after an edit the store accepted.
; ==============================================================================

#Requires AutoHotkey v2.0

class AutoClickOwner {
	static doc := 0
	static session := 0
	static coupled := false
	static clicks := 0
	static vision_started := false
	static ports := 0
}




; ===================================
; ===================================
; ======= 1/ Library ================
; ===================================
; ===================================

_AutoClickShared(Relative) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\" . Relative, "UTF-8"))
}

; The library folder, its image folder and its document.
AutoClickLibraryPaths(&Folder, &Images, &Index) {
	global _ConfigDir
	Defaults := _AutoClickShared("shortcuts\data\auto_click_defaults.json")
	Folder := RTrim(_ConfigDir, "\") . "\" . Defaults["library_folder"]
	Images := Folder . "\images"
	Index := Folder . "\" . Defaults["library_index"]
}

; The presets document, read once; a broken saved file is reported and left
; on disk, and the starters run meanwhile.
AutoClickDocument() {
	if IsObject(AutoClickOwner.doc)
		return AutoClickOwner.doc
	Starters := _AutoClickShared("shortcuts\data\keep_awake_presets.json")
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	Saved := ""
	if FileExist(Index) {
		try Saved := JsonParse(FileRead(Index, "UTF-8"))
		catch
			Saved := Map("broken", true)
	}
	Doc := KeepAwakePresetsLoad(Starters, Saved, &Reason)
	if !IsObject(Doc) {
		LoggerError("AutoClick", "The presets document is invalid ({1}); the starter presets run until it is fixed.",
			Reason)
		Doc := KeepAwakePresetsLoad(Starters, "")
	}
	AutoClickOwner.doc := Doc
	return Doc
}

; Writes the document atomically.
_AutoClickSave(Doc) {
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	try {
		DirCreate(Images)
		if FileExist(Index . ".partial")
			FileDelete(Index . ".partial")
		FileAppend(KeepAwakeLibraryJson(Doc), Index . ".partial", "UTF-8-RAW")
		FileMove(Index . ".partial", Index, true)
	} catch as Err {
		LoggerError("AutoClick", "The presets document could not be written: {1}.", Err.Message)
		return false
	}
	return true
}

; Applies one edit (a KeepAwakePresets* function taking the document first and
; Reason last) and writes the document after it.
; @returns {Boolean} Saved.
AutoClickEdit(EditFn, Args*) {
	Doc := AutoClickDocument()
	Reason := ""
	; The reason is the edit's last, by-reference parameter.
	CallArgs := [Doc]
	CallArgs.Push(Args*)
	CallArgs.Push(&Reason)
	if !EditFn.Call(CallArgs*) {
		LoggerWarn("AutoClick", "Preset edit refused: reason={1}.", Reason)
		return false
	}
	if !_AutoClickSave(Doc)
		return false
	LoggerInfo("AutoClick", "Preset edit saved.")
	_AutoClickChanged()
	return true
}

_AutoClickChanged() {
	try RebuildTrayMenu()
}

; What the active preset runs on Windows.
AutoClickActivePlan() {
	AutoClickLibraryPaths(&Folder, &Images, &Index)
	return KeepAwakePresetsPlan(KeepAwakePresetsActive(AutoClickDocument()), "windows", Images, "\",
		_AutoClickShared("shortcuts\data\auto_click_defaults.json"))
}




; ===================================
; ===================================
; ======= 2/ Menu rows ==============
; ===================================
; ===================================

_AutoClickPresetName(Preset) {
	return Preset.Has("name") ? Preset["name"] : t(Preset["name_key"])
}

_AutoClickSelect(Id) {
	return (*) => AutoClickEdit(KeepAwakePresetsSetActive, Id)
}

; The rows of the presets list, as _shared/shortcuts/engine/keep_awake_menu.lua builds them.
AutoClickPresetRows() {
	Doc := AutoClickDocument()
	Rows := []
	for Preset in Doc["presets"]
		Rows.Push(Map("label", _AutoClickPresetName(Preset), "checked", Preset["id"] == Doc["active"], "radio", true,
			"action", _AutoClickSelect(Preset["id"])))
	return Rows
}

; The problems the menu shows: capture or OCR unavailable.
_AutoClickProblems() {
	if !AutoClickOwner.vision_started
		return []
	State := ScreenVisionAvailability()
	if !State["capture"]["ok"]
		return [State["capture"]["reason"]]
	if !State["ocr"]["ok"]
		return [State["ocr"]["reason"]]
	return []
}

; Flips one switch of the active preset (the manifest's check rows).
_AutoClickToggleSwitch(Name, *) {
	Doc := AutoClickDocument()
	Preset := KeepAwakePresetsActive(Doc)
	return AutoClickEdit(KeepAwakePresetsSetSwitch, Doc["active"], Name, Preset[Name] ? 0 : 1)
}

; Whether one switch of the active preset is on.
_AutoClickSwitchOn(Name, *) {
	return KeepAwakePresetsActive(AutoClickDocument())[Name] ? true : false
}

; The rows of the status list: the click counter and the problems.
AutoClickStatusRows() {
	Rows := [Map("label", StrReplace(t("menu.keep_awake.click_count"), "{1}", AutoClickOwner.clicks), "disabled", true)]
	for Reason in _AutoClickProblems()
		Rows.Push(Map("label", "🔴 " . t("keepawake.reason." . Reason), "disabled", true))
	return Rows
}

; Builds the « Anti-veille » submenu from the manifest's keep_awake_menu.
_MI_BuildKeepAwakeMenu() {
	; Windows can always click: the auto-click row is never greyed here.
	return MenuRenderer_Build("keep_awake_menu", "Anti-veille", "", "", Map(
		"keep_awake_presets", (*) => AutoClickPresetRows(),
		"keep_awake_status", (*) => AutoClickStatusRows()), Map(
		"keep_awake_switch", _AutoClickToggleSwitch.Bind("keep_awake"),
		"keep_awake_auto_click", _AutoClickToggleSwitch.Bind("auto_click"),
		"keep_awake_library", KeepAwakeLibraryOpen), Map(
		"keep_awake_switch_on", _AutoClickSwitchOn.Bind("keep_awake"),
		"keep_awake_auto_click_on", _AutoClickSwitchOn.Bind("auto_click"),
		"keep_awake_auto_click_available", (*) => true))
}

; The row stays live while paused: choosing a preset changes no input.
_MI_StageKeepAwake() {
	TrayMenuStage_Add(t("menu.keep_awake.title"), _MI_BuildKeepAwakeMenu())
}




; ===================================
; ===================================
; ======= 3/ Ports ==================
; ===================================
; ===================================

; Whether the session's input desktop is locked: no input desktop answers.
_AutoClickLocked() {
	Desktop := DllCall("User32\OpenInputDesktop", "UInt", 0, "Int", 0, "UInt", 0x0100, "Ptr")
	if !Desktop
		return true
	DllCall("User32\CloseDesktop", "Ptr", Desktop)
	return false
}

_AutoClickForeground(*) {
	Hwnd := WinExist("A")
	if !Hwnd
		return ""
	try Exe := WinGetProcessName("ahk_id " . Hwnd)
	catch
		return ""
	return Map("window", Hwnd, "app_id", Exe)
}

_AutoClickState(*) {
	try Secure := SFD_IsSecureField()
	catch
		Secure := true
	return Map("locked", _AutoClickLocked(), "paused", A_IsSuspended, "secure_field", Secure ? 1 : 0)
}

_AutoClickClick(X, Y) {
	CoordMode("Mouse", "Screen")
	MouseGetPos(&OriginX, &OriginY)
	Click(X, Y)
	MouseMove(OriginX, OriginY, 0)
	return true
}

_AutoClickScan(Window, Request, Callback) {
	ScreenVisionScanWindow(Window, Request, Callback)
}

_AutoClickLog(Level, Message, Args*) {
	switch Level {
		case "info": LoggerInfo("AutoClick", Message, Args*)
		case "warn": LoggerWarn("AutoClick", Message, Args*)
		default: LoggerDebug("AutoClick", Message, Args*)
	}
}

_AutoClickOnClick(Count, TargetId) {
	AutoClickOwner.clicks += 1
	_AutoClickChanged()
}

_AutoClickDefaultPorts() {
	return Map("foreground", _AutoClickForeground, "state", _AutoClickState, "scan", _AutoClickScan,
		"click", _AutoClickClick, "now_ms", (*) => DllCall("GetTickCount64", "Int64"), "log", _AutoClickLog,
		"on_click", _AutoClickOnClick)
}





; ===================================
; ===================================
; ======= 4/ Session and mode =======
; ===================================
; ===================================

AutoClickRunning() {
	return IsObject(AutoClickOwner.session)
}

; Starts the screen vision service once; this owner starts it for the
; auto-clicker, the « Capture → texte » action and the workflow screen steps.
AutoClickVision() {
	if !AutoClickOwner.vision_started {
		ScreenVisionInit()
		AutoClickOwner.vision_started := true
	}
	return true
}

; Starts the auto-clicker for a plan.
; @param Coupled {Boolean} Whether it ends with the keep-awake session.
AutoClickStart(Plan, Coupled := false) {
	if IsObject(AutoClickOwner.session)
		return true
	if !Plan["auto_click"]
		return false
	if !IsObject(AutoClickOwner.ports)
		AutoClickVision()
	Ports := IsObject(AutoClickOwner.ports) ? AutoClickOwner.ports : _AutoClickDefaultPorts()
	Defaults := _AutoClickShared("shortcuts\data\auto_click_defaults.json")
	AutoClickOwner.session := AutoClickSession(Ports, Plan, Map("options", Defaults,
		"cooldown_ms", TimingsGet("keep_awake", "auto_click_cooldown_ms"), "ocr", Map("layout", "sparse")))
	AutoClickOwner.coupled := Coupled
	SetTimer(_AutoClickTick, TimingsGet("keep_awake", "auto_click_tick_ms"))
	LoggerInfo("AutoClick", "Auto-click started: {1} image(s), {2} text target(s).", Plan["templates"].Length,
		Plan["text_targets"].Length)
	return true
}

_AutoClickTick() {
	global ActivitySimulation
	if !IsObject(AutoClickOwner.session)
		return
	; The keep-awake session ended (physical input, Suspend): the mode ends.
	if AutoClickOwner.coupled && !(IsSet(ActivitySimulation) && ActivitySimulation) {
		LoggerInfo("AutoClick", "The keep-awake session ended; automatic clicks stop with it.")
		AutoClickStop()
		return
	}
	AutoClickOwner.session.Tick()
}

AutoClickStop() {
	if !IsObject(AutoClickOwner.session)
		return true
	SetTimer(_AutoClickTick, 0)
	AutoClickOwner.session.Stop()
	AutoClickOwner.session := 0
	LoggerInfo("AutoClick", "Auto-click stopped.")
	return true
}

; Toggles the anti-sleep mode with the active preset (Ctrl+M).
; @param StartFn {Func} Starts the keep-awake session; StopFn stops it;
;   ActiveFn tells whether it runs.
AutoClickToggleMode(StartFn, StopFn, ActiveFn) {
	if IsObject(AutoClickOwner.session) || ActiveFn.Call() {
		AutoClickStop()
		if ActiveFn.Call()
			StopFn.Call()
		return true
	}
	Plan := AutoClickActivePlan()
	if !Plan["keep_awake"] && !Plan["auto_click"] {
		LoggerWarn("AutoClick", "The active anti-sleep preset keeps nothing awake and clicks nothing.")
		try NotifierSend(t("keepawake.preset_empty"), Map("title", t("keepawake.title")))
		return false
	}
	Admitted := true
	if Plan["keep_awake"]
		Admitted := StartFn.Call() == true
	if Plan["auto_click"]
		Admitted := AutoClickStart(Plan, Plan["keep_awake"]) && Admitted
	return Admitted
}
