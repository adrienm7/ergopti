; apps/bundled_apps.ahk

; ==============================================================================
; MODULE: Bundled Apps (Windows)
; DESCRIPTION:
; The Windows App Cloner and Encryptor programs: their dialog flows (ports of
; macOS's ShortcutBuilder and Encryptor main.applescript), the Encryptor drop
; window and the entry that reads the command line. They run in a process of
; their own, started by the tray (ui/menu/menu_apps.ahk) with
; `--bundled-app <id>`: the key derivation and the dialogs never hold the
; driver's keyboard hook.
;
; Command line: --bundled-app encryptor|app-cloner --locales-dir DIR
;               [--locale CODE] [--] [FILE…]
; ==============================================================================

#Requires AutoHotkey v2.0+

; The bundled app ids the tray and the command line name.
global BUNDLED_APP_ENCRYPTOR := "encryptor"
global BUNDLED_APP_CLONER := "app-cloner"




; ==================================
; ==================================
; ======= 1/ Dialogs ===============
; ==================================
; ==================================

/**
 * Asks for one line of text.
 * @returns {String|Boolean} The text, or false when cancelled.
 */
BundledAppUi_Entry(Title, Prompt, Initial := "", Hidden := false) {
	Answer := Ui_InputBox(Prompt, Title, (Hidden ? "Password " : "") . "w480 h190", Initial)
	return Answer.Result == "OK" ? Answer.Value : false
}

/**
 * Asks a question with two labelled buttons.
 * @returns {Boolean} True for the first button.
 */
BundledAppUi_Choice(Title, Text, OkLabel, CancelLabel) {
	State := { answer: false }
	Window := Gui("-MinimizeBox", WindowTitle(Title))
	Window.SetFont("s10")
	Window.AddText("w440", Text)
	Ok := Window.AddButton("Default w200", OkLabel)
	Cancel := Window.AddButton("x+20 w200", CancelLabel)
	Ok.OnEvent("Click", (*) => (State.answer := true, Window.Destroy()))
	Cancel.OnEvent("Click", (*) => Window.Destroy())
	Window.OnEvent("Close", (*) => Window.Destroy())
	Window.OnEvent("Escape", (*) => Window.Destroy())
	Window.Show()
	WinWaitClose("ahk_id " . Window.Hwnd)
	return State.answer
}

/**
 * Shows a message; Kind is "info", "warning" or "error".
 */
BundledAppUi_Message(Kind, Title, Text) {
	Icon := Kind == "error" ? "Iconx" : (Kind == "warning" ? "Icon!" : "Iconi")
	Ui_MsgBox(Text, Title, Icon)
}

/**
 * The dialog ports of a real run.
 * @returns {Map}
 */
BundledAppUi_Ports() {
	return Map("entry", BundledAppUi_Entry, "choice", BundledAppUi_Choice, "message", BundledAppUi_Message,
		"reveal", BundledAppsNative_Reveal)
}




; ==================================
; ==================================
; ======= 2/ Encryptor flow ========
; ==================================
; ==================================

/**
 * Processes one file the way main.applescript's process_file does.
 * @param {String} Path
 * @param {Map} Ports entry, choice, message, reveal, format.
 * @returns {String} "done", "cancelled" or "failed".
 */
Encryptor_ProcessFile(Path, Ports) {
	Envelope := Ports["format"]
	if !FileExist(Path) || InStr(FileExist(Path), "D") {
		Ports["message"].Call("error", AppText("apps.encryptor.title_encrypt"),
			AppText("apps.encryptor.err_file_missing") . "`n`n" . Path)
		return "failed"
	}
	Target := Encryptor_Destination(Envelope, Path)
	Encrypting := Target["mode"] == "encrypt"
	Title := AppText(Encrypting ? "apps.encryptor.title_encrypt" : "apps.encryptor.title_decrypt")
	if FileExist(Target["destination"]) {
		if !Ports["choice"].Call(Title, AppText("apps.encryptor.warn_overwrite") . "`n`n" . Target["destination"],
				AppText("apps.encryptor.btn_overwrite"), AppText("button.cancel"))
			return "cancelled"
	}
	loop {
		Password := Ports["entry"].Call(Title, AppText("apps.encryptor.prompt_password"), "", true)
		if !(Password is String)
			return "cancelled"
		if Password == "" {
			Ports["message"].Call("warning", Title, AppText("apps.encryptor.err_empty_password"))
			continue
		}
		if !Encrypting
			break
		Confirmed := Ports["entry"].Call(Title, AppText("apps.encryptor.prompt_confirm"), "", true)
		if !(Confirmed is String)
			return "cancelled"
		if Confirmed == Password
			break
		Ports["message"].Call("warning", Title, AppText("apps.encryptor.err_password_mismatch"))
	}
	Failure := AppText(Encrypting ? "apps.encryptor.err_encrypt_failed" : "apps.encryptor.err_decrypt_failed")
	try Converted := Encryptor_ConvertFile(Envelope, Target["mode"], Path, Target["destination"], Password)
	catch as Err {
		; A file the system refused to read or write: the reason goes with it.
		Ports["message"].Call("error", Title, Failure . "`n`n" . Err.Message)
		return "failed"
	}
	if !Converted {
		Ports["message"].Call("error", Title, Failure)
		return "failed"
	}
	Summary := AppText(Encrypting ? "apps.encryptor.success_encrypted" : "apps.encryptor.success_decrypted")
		. "`n" . Target["destination"]
	if Ports["choice"].Call(Title, Summary, AppText("apps.encryptor.btn_reveal_folder"), AppText("common.close"))
		Ports["reveal"].Call(Target["destination"])
	return "done"
}

/**
 * Processes every file in order.
 * @param {Array} Files
 * @param {Map} Ports
 * @returns {Array} One outcome per file.
 */
Encryptor_ProcessFiles(Files, Ports) {
	Outcomes := []
	for Path in Files
		Outcomes.Push(Encryptor_ProcessFile(Path, Ports))
	return Outcomes
}

/**
 * Opens the drop window and waits until it closes: files dropped on it, or
 * chosen through Browse, are converted.
 * @param {Map} Ports
 */
Encryptor_ShowDropWindow(Ports) {
	Window := Gui(, WindowTitle(AppText("menu.apps.encrypt_desc")))
	Window.SetFont("s11")
	Window.AddText("w420 h140 Center Border 0x200", AppText("apps.encryptor.drop_hint"))
	Browse := Window.AddButton("w200", AppText("apps.cloner.btn_browse"))
	Browse.OnEvent("Click", (*) => _Encryptor_Browse(Ports))
	Window.OnEvent("DropFiles", (GuiObj, Ctrl, Files, *) => Encryptor_ProcessFiles(Files, Ports))
	Window.OnEvent("Close", (*) => Window.Destroy())
	Window.Show()
	; Drops and Browse run as their own threads while this one waits.
	WinWaitClose("ahk_id " . Window.Hwnd)
}

_Encryptor_Browse(Ports) {
	Chosen := Ui_FileSelect(1, "", AppText("apps.encryptor.lbl_file"))
	if Chosen != ""
		Encryptor_ProcessFile(Chosen, Ports)
}




; ==================================
; ==================================
; ======= 3/ App Cloner flow =======
; ==================================
; ==================================

/**
 * Validates the optional item to open, as macOS validateOpenArg and the Linux
 * invalid_open_item do: « ~ » is the profile folder, a path must exist, and
 * anything else needs « :// » or a Teams « msteams:/l/ » or « msteams:/calendar »
 * link, so « https:/x » and « localhost:3000 » are refused.
 * @param {String} Item The trimmed answer.
 * @param {Func} Exists Path existence port.
 * @param {String} Home The profile folder « ~ » stands for.
 * @param {VarRef} Resolved Receives the item to open, « ~ » expanded.
 * @returns {Array} [] when valid, else [error key, value].
 */
_AppCloner_InvalidOpenItem(Item, Exists, Home, &Resolved) {
	Resolved := Item
	if Item == ""
		return []
	if Item == "~" || RegExMatch(Item, "^~[\\/]")
		Resolved := Home . StrReplace(SubStr(Item, 2), "/", "\")
	if RegExMatch(Resolved, "^[A-Za-z]:[\\/]|^\\\\") {
		if Exists.Call(Resolved)
			return []
		return ["apps.cloner.err_path_missing", Item]
	}
	if InStr(Item, "://") || RegExMatch(Item, "^msteams:/(?:l/|calendar)")
		return []
	return ["apps.cloner.err_url_format", ""]
}

/**
 * Runs the clone dialogs and writes the clone.
 * @param {Map} Ports entry, choice, message, pick_source, pick_icon, read_shortcut,
 *   exists, write, catalogue, data_home, roaming, home, programs, has_marker.
 * @returns {String} "created", "cancelled" or "failed".
 */
AppCloner_Run(Ports) {
	Source := Ports["pick_source"].Call(AppText("apps.cloner.msg_choose_source"))
	if Source == ""
		return "cancelled"
	SplitPath(Source, , , &Extension, &SourceName)
	Program := Source, Arguments := [], Icon := ""
	if Extension = "lnk" {
		Link := Ports["read_shortcut"].Call(Source)
		Program := Link["target"]
		if Link["arguments"] != ""
			Arguments := [Link["arguments"]]
		Icon := Link["icon"]
	}
	if Program == "" || !RegExMatch(Program, "i)\.exe$") {
		Ports["message"].Call("error", AppText("apps.cloner.title_error"), AppText("apps.cloner.err_source_unreadable"))
		return "failed"
	}

	loop {
		Name := Ports["entry"].Call(AppText("apps.cloner.title_clone_name"), AppText("apps.cloner.msg_clone_name_launcher"),
			AppText("apps.cloner.default_clone_name", SourceName))
		if !(Name is String)
			return "cancelled"
		Name := Trim(Name)
		if Name != ""
			break
		Ports["message"].Call("warning", AppText("apps.cloner.title_empty_input"), AppText("apps.cloner.err_open_empty"))
	}
	loop {
		OpenItem := Ports["entry"].Call(AppText("apps.cloner.title_open_arg"), AppText("apps.cloner.msg_open_optional_portable"), "")
		if !(OpenItem is String)
			return "cancelled"
		OpenItem := Trim(OpenItem)
		Invalid := _AppCloner_InvalidOpenItem(OpenItem, Ports["exists"], Ports["home"], &ResolvedItem)
		if Invalid.Length == 0 {
			OpenItem := ResolvedItem
			break
		}
		Ports["message"].Call("warning", AppText("apps.cloner.title_invalid_input"), AppText(Invalid[1], Invalid[2]))
	}
	if !Ports["choice"].Call(AppText("apps.cloner.title_icon_style"), AppText("apps.cloner.msg_icon_style_portable"),
			AppText("apps.cloner.btn_original_icon"), AppText("apps.cloner.btn_custom_icon")) {
		Custom := Ports["pick_icon"].Call(AppText("apps.cloner.prompt_choose_icon"))
		if Custom != ""
			Icon := Custom
	}

	Catalogue := Ports["catalogue"]
	Plan := AppCloner_Plan(Map("program", Program, "arguments", Arguments, "name", Name, "open_item", OpenItem,
		"icon", Icon, "catalogue", Catalogue, "data_home", Ports["data_home"], "roaming", Ports["roaming"],
		"home", Ports["home"], "programs", Ports["programs"], "has_marker", Ports["has_marker"],
		"taken", (Id, Shortcut) => Ports["exists"].Call(Ports["data_home"] . "\Ergopti\" . Catalogue["profile_folder"] . "\" . Id)
			|| Ports["exists"].Call(Shortcut)))
	; Each line is the locale's own label/value pattern (French spaces its colon).
	Summary := AppText("common.label_value", AppText("apps.cloner.summary_source"), Program) . "`n"
		. AppText("common.label_value", AppText("apps.cloner.summary_name"), Name) . "`n"
		. AppText("common.label_value", AppText("apps.cloner.summary_url"), OpenItem != "" ? OpenItem : "—") . "`n"
		. AppText("common.label_value", AppText("apps.cloner.summary_icon"), Plan["icon"])
	if !Plan["isolated"]
		Summary .= "`n`n" . AppText("apps.cloner.msg_no_isolation")
	if !Ports["choice"].Call(AppText("apps.cloner.title_summary"), Summary, AppText("apps.cloner.btn_clone"), AppText("button.cancel"))
		return "cancelled"
	try Ports["write"].Call(Plan)
	catch as Err {
		Ports["message"].Call("error", AppText("apps.cloner.title_error"), Err.Message)
		return "failed"
	}
	Ports["message"].Call("info", AppText("apps.cloner.btn_clone"), AppText("apps.cloner.msg_created", Name, Plan["profile"]))
	Ports["last_plan"] := Plan
	return "created"
}

/**
 * The filesystem ports of a real App Cloner run.
 * @returns {Map}
 */
AppCloner_NativePorts() {
	Ports := BundledAppUi_Ports()
	Ports["pick_source"] := (Title) => Ui_FileSelect(1, A_StartMenuCommon . "\Programs", Title, "(*.exe; *.lnk)")
	Ports["pick_icon"] := (Title) => Ui_FileSelect(1, "", Title, "(*.ico; *.exe; *.dll)")
	Ports["read_shortcut"] := BundledAppsNative_ReadShortcut
	Ports["exists"] := (Path) => FileExist(Path) != ""
	Ports["has_marker"] := (Program, Marker) => (SplitPath(Program, , &Folder), FileExist(Folder . "\" . Marker) != "")
	Ports["write"] := AppCloner_Write
	Ports["data_home"] := EnvGet("LOCALAPPDATA")
	Ports["roaming"] := A_AppData
	Ports["home"] := EnvGet("USERPROFILE")
	Ports["programs"] := A_Programs
	return Ports
}




; ==================================
; ==================================
; ======= 4/ Entry =================
; ==================================
; ==================================

/**
 * Whether this process was started as a bundled app.
 * @returns {Boolean}
 */
BundledApp_IsInvocation() {
	for _, Arg in A_Args {
		if (Arg = "--bundled-app")
			return true
		if (Arg = "--")
			return false
	}
	return false
}

/**
 * Reads the command line.
 * @param {Array} Args
 * @returns {Map} app, locales_dir, locale, files.
 */
BundledApp_ParseArguments(Args) {
	Options := Map("app", "", "locales_dir", "", "locale", "", "files", [])
	Index := 1
	while Index <= Args.Length {
		Word := Args[Index]
		if Word == "--" {
			while ++Index <= Args.Length
				Options["files"].Push(Args[Index])
			break
		}
		if Word == "--bundled-app" || Word == "--locales-dir" || Word == "--locale" {
			if Index == Args.Length || Args[Index + 1] == ""
				throw ValueError(Word . " needs a value.")
			Options[Word == "--bundled-app" ? "app" : (Word == "--locale" ? "locale" : "locales_dir")] := Args[Index + 1]
			Index += 2
			continue
		}
		if SubStr(Word, 1, 1) == "/"
			Index += 1          ; AutoHotkey's own switches (/force, /ErrorStdOut).
		else if SubStr(Word, 1, 2) == "--"
			throw ValueError("Unknown option " . Word . ".")
		else {
			Options["files"].Push(Word)
			Index += 1
		}
	}
	if Options["app"] != BUNDLED_APP_ENCRYPTOR && Options["app"] != BUNDLED_APP_CLONER
		throw ValueError("Unknown bundled app '" . Options["app"] . "'.")
	if Options["locales_dir"] == ""
		throw ValueError("--locales-dir is required.")
	return Options
}

/**
 * Runs a bundled app, then leaves the process.
 * @param {String} SharedDir The _shared folder.
 */
BundledApp_Main(SharedDir) {
	Options := BundledApp_ParseArguments(A_Args)
	BundledAppStrings_Load(Options["locales_dir"], Options["locale"])
	if Options["app"] == BUNDLED_APP_CLONER {
		Ports := AppCloner_NativePorts()
		Ports["catalogue"] := AppCloner_LoadFamilies(SharedDir)
		AppCloner_Run(Ports)
		ExitApp(0)
	}
	Ports := BundledAppUi_Ports()
	Ports["format"] := Encryptor_LoadFormat(SharedDir)
	if Options["files"].Length {
		Encryptor_ProcessFiles(Options["files"], Ports)
		ExitApp(0)
	}
	Encryptor_ShowDropWindow(Ports)
	; Never return: in a compiled release the caller is the driver's own boot.
	ExitApp(0)
}
