; ui/menu/menu_apps.ahk

; ==============================================================================
; MODULE: Applications Submenu
; DESCRIPTION:
; The tray's Applications submenu: the bundled App Cloner and Encryptor, the
; same two apps macOS ships as bundles next to its driver. Each row starts its
; app as a process of its own (windows/apps/bundled_apps.ahk) with the active
; locale and the shared locales folder, as macOS's menu_apps.lua hands them to
; its bundles.
;
; FEATURES & RATIONALE:
; 1. A process of its own: the key derivation and the dialogs would otherwise
;    hold this script's thread, and with it the keyboard hook.
; 2. Opening Encryptor also writes its Send To shortcut, the Windows drop
;    target: files sent to it, or dropped on it, reach the same program. The
;    shortcut is rewritten at each opening, so it follows an update's paths.
; ==============================================================================

#Requires AutoHotkey v2.0+

; The bundled apps, in the order macOS lists its bundles (alphabetical).
global BUNDLED_APPS := [
	Map("id", "app-cloner", "name", "App Cloner", "description_key", "menu.apps.clone_desc"),
	Map("id", "encryptor", "name", "Encryptor", "description_key", "menu.apps.encrypt_desc", "send_to", true)
]




; ==================================
; ==================================
; ======= 1/ Launch ================
; ==================================
; ==================================

/**
 * The program and arguments that start one bundled app.
 * @param {Map} App One of BUNDLED_APPS.
 * @param {Map} Env compiled, script_path (A_ScriptFullPath), ahk_path, entry, locales_dir, locale.
 * @returns {Map} executable and args.
 */
BundledApps_Command(App, Env) {
	Args := ["/force"]
	if !Env["compiled"]
		Args.Push(Env["entry"])
	for Word in ["--bundled-app", App["id"], "--locales-dir", Env["locales_dir"]]
		Args.Push(Word)
	if Env["locale"] != "" {
		Args.Push("--locale")
		Args.Push(Env["locale"])
	}
	return Map("executable", Env["compiled"] ? Env["script_path"] : Env["ahk_path"], "args", Args)
}

/**
 * The real launch environment of this driver.
 * @returns {Map}
 */
BundledApps_Environment() {
	global _SharedDir
	return Map("compiled", A_IsCompiled, "script_path", A_ScriptFullPath, "ahk_path", A_AhkPath,
		"entry", A_ScriptDir . "\apps\bundled_app_entry.ahk",
		"locales_dir", _SharedDir . "\core\i18n\data\locales", "locale", I18nGetLocale())
}

/**
 * Starts one bundled app.
 * @param {Map} App One of BUNDLED_APPS.
 * @param {Map} Env Optional launch environment (a test seam).
 * @param {Func} StartFn Optional starter (a test seam).
 * @param {Func} ShortcutFn Optional shortcut writer (a test seam).
 * @returns {Boolean}
 */
BundledApps_Launch(App, Env := 0, StartFn := 0, ShortcutFn := 0) {
	if !IsObject(Env)
		Env := BundledApps_Environment()
	Command := BundledApps_Command(App, Env)
	if App.Get("send_to", false) {
		; The drop target: Explorer appends the files it is given after "--".
		Fields := Map("target", Command["executable"],
			"arguments", BundledAppsNative_CommandLine(Command["args"]) . " --",
			"description", t(App["description_key"]))
		try (IsObject(ShortcutFn) ? ShortcutFn : BundledAppsNative_WriteShortcut).Call(
			A_AppData . "\Microsoft\Windows\SendTo\" . App["name"] . ".lnk", Fields)
		catch as Err {
			; The app still opens from the tray; only the drop target is missing.
			try LoggerWarn("Menu", "The Send To shortcut of '{1}' could not be written: {2}", App["name"], Err.Message)
		}
	}
	LoggerInfo("Menu", "Opening bundled app '{1}'…", App["name"])
	try {
		(IsObject(StartFn) ? StartFn : BundledAppsNative_Start).Call(Command["executable"], Command["args"])
	} catch as Err {
		LoggerError("Menu", "Bundled app '{1}' could not start: {2}", App["name"], Err.Message)
		return false
	}
	LoggerSuccess("Menu", "Bundled app '{1}' opened.", App["name"])
	return true
}




; ==================================
; ==================================
; ======= 2/ Submenu ===============
; ==================================
; ==================================

/**
 * List provider: one row per bundled app, labelled as on macOS.
 * @returns {Array}
 */
BundledApps_Rows() {
	Rows := []
	for App in BUNDLED_APPS
		Rows.Push(Map("label", App["name"] . " — " . t(App["description_key"]), "action", _BundledApps_Action(App)))
	return Rows
}

; A menu calls its action with (ItemName, ItemPos, Menu): a Bind of the launch
; would hand those to its test seams. Each row gets its own scope, too, so it
; never launches the loop's last app.
_BundledApps_Action(App) {
	return (*) => BundledApps_Launch(App)
}

; Builds the Applications submenu from the manifest's apps_menu.
_MI_BuildAppsMenu() {
	return MenuRenderer_Build("apps_menu", "Applications", "", "", Map("apps_installed", (*) => BundledApps_Rows()))
}

; The manifest marks the row greyed_when_paused, as the macOS and Linux trays
; grey it: a feature row is the one a pause greys and a resume re-enables.
_MI_StageApps() {
	TrayMenuStage_AddFeature(t("menu.apps.title"), _MI_BuildAppsMenu())
}
