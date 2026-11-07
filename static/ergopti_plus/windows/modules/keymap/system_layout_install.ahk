; modules/keymap/system_layout_install.ahk

; ==============================================================================
; MODULE: Ergopti System Layout Install (Windows)
; DESCRIPTION:
; Layout > « Install the Ergopti system layout »: installs the Ergopti keyboard
; layout DLL the release ships (vendor/keyboard_layout, built by
; tools/build/build_windows_keyboard_layout.ps1 from the registry .keylayout)
; as a Windows system layout, adds it to the user's languages and switches to
; it, as the macOS menu installs and selects its .bundle. From then on it is
; one of the user's layouts: Layout > « Input sources » and the pause and
; resume switch (also at the driver start) select it like any other.
;
; FEATURES & RATIONALE:
; 1. The installer is unsigned and writes System32 and HKLM, so it runs only
;    after the user agreed to a dialog that says so, and through UAC
;    (vendor/keyboard_layout/install_keyboard_layout.ps1). Adding the layout to
;    the language list then runs as the user (add_user_keyboard_layout.ps1): an
;    elevated process may be another account.
; 2. Never blocks the menu thread: both steps run as child processes whose JSON
;    outcome a timer polls (timings adapters.system_layout_install_poll_ms).
; 3. The row says where the layout stands: not built into this copy, not
;    installed, installed, or installed from another build (an update).
; 4. Fail fast: a refused elevation, a failed step or a missing outcome is
;    logged and told; nothing reports an install that did not happen. A pause
;    keeps its layout: the live switch is skipped while the driver is paused.
; ==============================================================================

#Requires AutoHotkey v2.0

; The generated menu-command constants; #Include skips a file the entry script
; already loaded.
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk




global SLI_LAYOUTS_KEY := "HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"
global SLI_ARCHITECTURE_KEY := "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
; The running install, "" stage when none: "elevated" then "user".
global _SystemLayoutJob := Map("stage", "", "pid", 0, "result", "", "klid", "", "spec", 0)

; The install record every entry reads. A record that is not a job (no stage)
; is a broken owner, never an idle one: fail fast instead of starting an
; installer or reporting a state nobody owns.
_SystemLayout_Job() {
	global _SystemLayoutJob
	if !(_SystemLayoutJob is Map)
		throw TypeError("The system layout install record is not a job.")
	if (!_SystemLayoutJob.Has("stage"))
		throw ValueError("The system layout install record has no stage.")
	return _SystemLayoutJob
}

/**
 * The shared description of the layout Windows installs.
 * @param {Func} ReadFn Optional port: ReadFn(Path) returns the text or false.
 * @returns {Map} windows_system_layout.json.
 */
SystemLayout_Spec(ReadFn := 0) {
	global _SharedDir
	if !HasMethod(ReadFn, "Call")
		ReadFn := FSRead
	Path := SystemLayout_SpecPath()
	Text := ReadFn.Call(Path)
	if !(Text is String)
		throw Error("the Windows system layout description is unreadable: " . Path)
	Spec := JsonParse(Text)
	if !(Spec is Map)
		throw Error("the Windows system layout description is not an object")
	for Key in ["dll_name", "language_id", "locale_name", "architectures"]
		if !Spec.Has(Key)
			throw Error("the Windows system layout description has no " . Key)
	return Spec
}

; Where the description lives (the elevated installer reads it too).
SystemLayout_SpecPath() {
	global _SharedDir
	return _SharedDir . "\modules\layouts\windows_system_layout.json"
}

; The folder holding the installer scripts and one folder per DLL build.
SystemLayout_VendorDir() {
	global _VendorDir
	return _VendorDir . "\keyboard_layout"
}

; System32 as this process reaches it: a 32-bit AutoHotkey reads SysWOW64 there.
_SystemLayout_System32() => A_WinDir . ((A_Is64bitOS && A_PtrSize == 4) ? "\Sysnative" : "\System32")

; The KLID whose Layout File is DllFile, "" when none.
_SystemLayout_RegistryKlid(DllFile) {
	global SLI_LAYOUTS_KEY
	Loop Reg, SLI_LAYOUTS_KEY, "K" {
		; Not every layout key names a file (an IME may not): absence is ordinary.
		LayoutFile := RegRead(A_LoopRegKey . "\" . A_LoopRegName, "Layout File", "")
		if (StrLower(LayoutFile) == StrLower(DllFile))
			return StrUpper(A_LoopRegName)
	}
	return ""
}

; Whether two files hold the same bytes; an unreadable file throws instead of
; reading as another build.
_SystemLayout_SameFile(PathA, PathB) {
	if (FileGetSize(PathA) != FileGetSize(PathB))
		return false
	return FSSameBytesStrict(PathA, PathB)
}

/**
 * Where the Ergopti system layout stands.
 * @param {Map} Spec SystemLayout_Spec().
 * @param {Map} Ports Optional "architecture", "exists", "klid" and "same" ports
 *   (tests); the live system when omitted.
 * @returns {Map} "status": "unbuilt" (no build for this Windows in this copy),
 *   "not_installed", "outdated" (installed from another build) or "installed";
 *   "klid" when registered.
 */
SystemLayout_Status(Spec, Ports := 0) {
	global SLI_ARCHITECTURE_KEY
	if !(Ports is Map)
		Ports := Map()
	ArchitectureFn := Ports.Get("architecture", () => RegRead(SLI_ARCHITECTURE_KEY, "PROCESSOR_ARCHITECTURE"))
	ExistsFn := Ports.Get("exists", (Path) => FileExist(Path) != "")
	KlidFn := Ports.Get("klid", _SystemLayout_RegistryKlid)
	SameFn := Ports.Get("same", _SystemLayout_SameFile)
	Architecture := ArchitectureFn.Call()
	Placements := Spec["architectures"]
	DllFile := Spec["dll_name"] . ".dll"
	if !(Placements is Map) || !Placements.Has(Architecture)
		return Map("status", "unbuilt", "klid", "")
	Shipped := SystemLayout_VendorDir() . "\" . Placements[Architecture]["system32"] . "\" . DllFile
	if !ExistsFn.Call(Shipped)
		return Map("status", "unbuilt", "klid", "")
	Klid := KlidFn.Call(DllFile)
	Installed := _SystemLayout_System32() . "\" . DllFile
	if (Klid == "") || !ExistsFn.Call(Installed)
		return Map("status", "not_installed", "klid", Klid)
	return Map("status", SameFn.Call(Shipped, Installed) ? "installed" : "outdated", "klid", Klid)
}

/**
 * Layout > « Install the Ergopti system layout »: one row for where the layout
 * stands, a command when there is something to install.
 * @param {Func} StatusFn Optional port: StatusFn() returns SystemLayout_Status.
 * @param {Func} InstallFn Optional port started by the command.
 * @returns {Array} Provider rows.
 */
SystemLayout_MenuRows(StatusFn := 0, InstallFn := 0) {
	if !HasMethod(InstallFn, "Call")
		InstallFn := SystemLayout_Install
	if (_SystemLayout_Job()["stage"] != "")
		return _SystemLayout_DeclaredRows(MenuRenderer_StatusRows("layout_menu", "layout_system_install", "installing"))
	if !HasMethod(StatusFn, "Call")
		StatusFn := () => SystemLayout_Status(SystemLayout_Spec())
	try Status := StatusFn.Call()
	catch as Err {
		try LoggerError("SystemLayout", "The Ergopti system layout state could not be read: {1}.", Err.Message)
		return _SystemLayout_DeclaredRows(MenuRenderer_StatusRows("layout_menu", "layout_system_install", "unreadable"))
	}
	switch Status["status"] {
		case "unbuilt", "installed":
			return _SystemLayout_DeclaredRows(MenuRenderer_StatusRows("layout_menu", "layout_system_install", Status["status"]))
		case "outdated":
			return _SystemLayout_DeclaredRows(MenuRenderer_TemplateRows("layout_system_update_commands",
				Map(MenuCommand.SYSTEM_LAYOUT_UPDATE, (*) => InstallFn.Call()), Map(), Map()))
		case "not_installed":
			return _SystemLayout_DeclaredRows(MenuRenderer_TemplateRows("layout_system_install_commands",
				Map(MenuCommand.SYSTEM_LAYOUT_INSTALL, (*) => InstallFn.Call()), Map(), Map()))
	}
	throw ValueError("unknown system layout status " . Status["status"])
}

; A refused declaration publishes no row rather than a partial one; the
; renderer already logged why.
_SystemLayout_DeclaredRows(Rows) => Rows is Array ? Rows : []

/**
 * Asks, then starts the elevated installer.
 * @param {Func} ConfirmFn Optional port: ConfirmFn() is true when the user agrees.
 * @param {Func} RunFn Optional port: RunFn(Command, &Pid) starts a hidden process
 *   and throws when Windows (or the user, at the UAC prompt) refuses it.
 * @param {Func} TellFn Optional port: TellFn(Message) shows an error.
 * @returns {Boolean} true once the installer runs.
 */
SystemLayout_Install(ConfirmFn := 0, RunFn := 0, TellFn := 0) {
	global _SystemLayoutJob, DriverPid
	if (_SystemLayout_Job()["stage"] != "")
		return false
	if !HasMethod(ConfirmFn, "Call")
		ConfirmFn := () => Ui_MsgBox(t("dialog.system_layout.confirm"), t("dialog.system_layout.window_title"), "YesNo Default2 Icon?") == "Yes"
	if !HasMethod(RunFn, "Call")
		RunFn := _SystemLayout_Run
	if !HasMethod(TellFn, "Call")
		TellFn := (Message) => Ui_MsgBox(Message, t("dialog.system_layout.window_title"), "Icon!")
	if !ConfirmFn.Call() {
		try LoggerInfo("SystemLayout", "The Ergopti system layout install was declined.")
		return false
	}
	Spec := SystemLayout_Spec()
	ResultPath := A_Temp . "\ergopti_system_layout_" . DriverPid . "_" . A_TickCount . ".json"
	FSDelete(ResultPath)
	Command := '*RunAs powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
		. SystemLayout_VendorDir() . '\install_keyboard_layout.ps1" -Action install -SpecPath "' . SystemLayout_SpecPath()
		. '" -SourceDirectory "' . SystemLayout_VendorDir() . '" -ResultPath "' . ResultPath . '"'
	Pid := 0
	try RunFn.Call(Command, &Pid)
	catch as Err {
		try LoggerError("SystemLayout", "The Ergopti system layout installer did not start: {1}.", Err.Message)
		TellFn.Call(t("dialog.system_layout.elevation_refused"))
		return false
	}
	try LoggerInfo("SystemLayout", "Installing the Ergopti system layout (installer pid {1}).", Pid)
	_SystemLayoutJob := Map("stage", "elevated", "pid", Pid, "result", ResultPath, "klid", "", "spec", Spec, "tell", TellFn)
	_SystemLayout_Arm()
	return true
}

_SystemLayout_Run(Command, &Pid) {
	Pid := SystemControl().Launch(Command, "", "Hide")
}

; The poll re-arms under its own callback identity, so one owner coalesces.
_SystemLayout_Arm() {
	TimerArmOneShotMs(SystemLayout_Poll, TimingsGet("adapters", "system_layout_install_poll_ms"))
}

; Reads one step's JSON outcome; false when it wrote none or no valid one.
_SystemLayout_ReadOutcome(Path) {
	Text := FSRead(Path)
	if !(Text is String)
		return false
	try Outcome := JsonParse(Text)
	catch as Err {
		try LoggerError("SystemLayout", "The installer outcome is not valid JSON: {1}.", Err.Message)
		return false
	}
	return (Outcome is Map && Outcome.Has("status")) ? Outcome : false
}

/**
 * Advances the running install once its current step has finished: the user
 * step after the elevated one, then the live switch.
 * @param {Func} RunFn Optional process port (see SystemLayout_Install).
 * @param {Func} FinishFn Optional port: FinishFn(Klid) loads and selects the
 *   layout, then refreshes the menu.
 * @returns {String} The stage left: "elevated", "user" or "" once done.
 */
SystemLayout_Poll(RunFn := 0, FinishFn := 0) {
	global _SystemLayoutJob
	Job := _SystemLayout_Job()
	if (Job["stage"] == "")
		return ""
	if !HasMethod(RunFn, "Call")
		RunFn := _SystemLayout_Run
	if !HasMethod(FinishFn, "Call")
		FinishFn := _SystemLayout_Finish
	; The outcome file is the terminal authority: the PID may be recycled.
	if !FileExist(Job["result"]) && ProcessExist(Job["pid"]) {
		_SystemLayout_Arm()
		return Job["stage"]
	}
	Outcome := _SystemLayout_ReadOutcome(Job["result"])
	FSDelete(Job["result"])
	Tell := Job["tell"]
	if (Job["stage"] == "elevated") {
		if !(Outcome is Map) || Outcome["status"] != "installed" {
			Reason := (Outcome is Map) ? Outcome.Get("message", "") : t("dialog.system_layout.no_outcome")
			try LoggerError("SystemLayout", "The Ergopti system layout was not installed: {1}.", Reason)
			_SystemLayoutJob := Map("stage", "", "pid", 0, "result", "", "klid", "", "spec", 0)
			Tell.Call(Format(t("dialog.system_layout.failed"), Reason))
			return ""
		}
		Klid := Outcome["klid"]
		try LoggerInfo("SystemLayout", "The Ergopti system layout is installed as {1}; adding it to the user's languages.", Klid)
		Spec := Job["spec"]
		ResultPath := Job["result"] . ".user.json"
		Command := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
			. SystemLayout_VendorDir() . '\add_user_keyboard_layout.ps1" -Klid ' . Klid . ' -LanguageId ' . Spec["language_id"]
			. ' -LocaleName "' . Spec["locale_name"] . '" -ResultPath "' . ResultPath . '"'
		Pid := 0
		try RunFn.Call(Command, &Pid)
		catch as Err {
			try LoggerError("SystemLayout", "The language list step did not start: {1}.", Err.Message)
			_SystemLayoutJob := Map("stage", "", "pid", 0, "result", "", "klid", "", "spec", 0)
			Tell.Call(Format(t("dialog.system_layout.not_listed"), Err.Message))
			return ""
		}
		_SystemLayoutJob := Map("stage", "user", "pid", Pid, "result", ResultPath, "klid", Klid, "spec", Spec, "tell", Tell)
		_SystemLayout_Arm()
		return "user"
	}
	Klid := Job["klid"]
	_SystemLayoutJob := Map("stage", "", "pid", 0, "result", "", "klid", "", "spec", 0)
	if !(Outcome is Map) || (Outcome["status"] != "added" && Outcome["status"] != "already_listed") {
		Reason := (Outcome is Map) ? Outcome.Get("message", "") : t("dialog.system_layout.no_outcome")
		try LoggerError("SystemLayout", "Layout {1} is installed but not in the user's languages: {2}.", Klid, Reason)
		Tell.Call(Format(t("dialog.system_layout.not_listed"), Reason))
		return ""
	}
	try LoggerInfo("SystemLayout", "Layout {1} is in the user's languages ({2}).", Klid, Outcome["status"])
	FinishFn.Call(Klid)
	return ""
}

; Loads the new layout into the session's list, switches to it unless the
; driver is paused (the pause layout stays), and redraws the menu.
_SystemLayout_Finish(Klid) {
	try {
		KLS_Load(Klid)
	} catch as Err {
		try LoggerError("SystemLayout", "Windows did not load layout {1}: {2}.", Klid, Err.Message)
	}
	; A try without braces would take the else as its own.
	if A_IsSuspended {
		try LoggerInfo("SystemLayout", "Layout {1} is not selected now: the driver is paused.", Klid)
	} else if !((Result := KLS_Select(Klid)) is Integer && Result == 1) {
		try LoggerError("SystemLayout", "Layout {1} is installed but could not be selected.", Klid)
	}
	RebuildTrayMenu()
	Ui_MsgBox(t("dialog.system_layout.done"), t("dialog.system_layout.window_title"), "Iconi")
}
