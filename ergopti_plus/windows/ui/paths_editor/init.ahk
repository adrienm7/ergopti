; ui/paths_editor/init.ahk

; ==============================================================================
; MODULE: Paths Editor WebView2 Host
; DESCRIPTION:
; Renders the folders editor (configuration folder and logs folder) on Windows
; via WebView2, loading the shared frontend at _shared/ui/paths_editor/ so every
; driver shows an identical UI. Replaces the single-field native dialog
; (FilePathsEditor).
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir.
; 2. JS<->AHK bridge — the page posts {action} messages (ready/browse/save/
;    cancel); the host pushes initData and folder-pick results back.
; 3. Live reload — saving a changed config directory rewrites paths.toml and
;    reloads the script, exactly like the native dialog did.
; 4. Singleton — a second open focuses the existing window.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ===================================

; Singleton window + WebView2 plumbing. Subscription handles are stored in
; globals so the binding does not GC them (which would silently drop the JS->AHK
; channel); they are released BEFORE Controller.Close() in _PathsEdWeb_Reset.
global _PathsEdWeb_Gui        := 0
global _PathsEdWeb_Controller := unset
global _PathsEdWeb_WebView    := unset
global _PathsEdWeb_MsgSub     := unset
global _PathsEdWeb_NavSub     := unset
; True once _PathsEdWeb_Reset() has torn the controller down. Both the
; frontend "cancel" message and the native Gui Close event route through the
; SAME _PathsEdWeb_Close() -> _PathsEdWeb_Reset() call, and a second pass's
; unsubscribe line calls remove_WebMessageReceived via ComCall against a
; CoreWebView2 pointer already invalidated by the first pass's
; Controller.Close() — a genuine SEH access violation no AHK try/catch can
; intercept (see personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the
; crash this mirrors). The flag makes the second call a true no-op instead.
global _PathsEdWeb_ResetDone  := false
global _PathsEdWeb_SessionEpoch := 0

; Virtual host that maps to _SharedDir so the document and its relative assets
; resolve over https (file:// is an opaque origin and breaks the JS->AHK channel).
global PATHSED_VHOST             := "ergopti.paths"
global PATHSED_HOST_ACCESS_ALLOW := 1

; Returns true when the WebView2 runtime binding + loader DLL are present.
_PathsEdWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the paths editor in a WebView2 window. Returns true on success
; (the caller must NOT also build the native dialog), false to fall back.
_PathsEdWeb_TryOpen() {
	global _PathsEdWeb_Gui, _PathsEdWeb_Controller, _PathsEdWeb_WebView
	global _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub, _PathsEdWeb_ResetDone, _PathsEdWeb_SessionEpoch
	global _VendorDir, _SharedDir

	if !_PathsEdWeb_Available()
		return false

	; Singleton — bring the existing editor to the front.
	if (_PathsEdWeb_Gui != 0) {
		WMPresentWindow(_PathsEdWeb_Gui)
		return true
	}
	_PathsEdWeb_SessionEpoch += 1
	SessionEpoch := _PathsEdWeb_SessionEpoch
	_PathsEdWeb_ResetDone := false

	g := Gui_Create("+Resize +MinSize560x200", t("menu.paths.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w720 h440", "")
	g.OnEvent("Close", _PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_OnClose))
	g.OnEvent("Size",  _PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_OnResize))

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w720 h440 Center")
	_PathsEdWeb_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_PathsEdWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("PathsEditor", "WebView2 create failed: {1} — falling back to native dialog.", Err.Message)
		try g.Destroy()
		_PathsEdWeb_Reset()
		_PathsEdWeb_Gui := 0
		return false
	}

	_PathsEdWeb_WebView := _PathsEdWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _PathsEdWeb_Reset() call.

	try {
		s := _PathsEdWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _PathsEdWeb_MsgSub := _PathsEdWeb_WebView.WebMessageReceived(_PathsEdWeb_OnWebMessage.Bind(SessionEpoch))
	global _PathsEdWeb_NavSub := _PathsEdWeb_WebView.NavigationCompleted(_PathsEdWeb_OnNavigationCompleted.Bind(SessionEpoch))

	try _PathsEdWeb_WebView.SetVirtualHostNameToFolderMapping(PATHSED_VHOST, _SharedDir, PATHSED_HOST_ACCESS_ALLOW)
	try _PathsEdWeb_WebView.Navigate(_PathsEdWeb_HtmlUrl())
	try _PathsEdWeb_Controller.Fill()

	try LoggerSuccess("PathsEditor", "Config-folder editor shown via WebView2.")
	return true
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}.
_PathsEdWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	if !_PathsEdWeb_SessionCurrent(SessionEpoch)
		return
	try Msg := Args.TryGetWebMessageAsString()
	if !IsSet(Msg)
		return
	try Payload := JsonParse(Msg)
	if (!IsSet(Payload) || !(Payload is Map))
		return

	Action := Payload.Has("action") ? Payload["action"] : ""
	; WebMessageReceived is a COM callback: it bypasses native Suspend, which only
	; disarms hotkeys. Without this a paused driver still lets a page click write
	; config, re-register hotstrings or launch an elevated install.
	; Page-lifecycle signals are deliberately NOT gated — dropping `ready` strands
	; the SafetyFlush and leaves the page permanently un-initialised.
	if (A_IsSuspended && Action != "ready")
		return
	if (Action == "ready") {
		SetTimer(_PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_PushInitData), -1)
	} else if (Action == "browse") {
		Target := (Payload.Has("target") && Payload["target"] == "logs") ? "logs" : "config"
		SetTimer(_PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_Browse, Target), -1)
	} else if (Action == "save") {
		Dir := Payload.Has("configDir") ? Payload["configDir"] : ""
		; A page that sends no logs folder keeps the stored one (the 0 sentinel).
		LogsDir := (Payload.Has("logsDir") && Payload["logsDir"] is String) ? Payload["logsDir"] : 0
		SetTimer(_PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_Save, Dir, LogsDir), -1)
	} else if (Action == "cancel") {
		SetTimer(_PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_Close), -1)
	}
}

; Push initData once the page has finished loading (the frontend also emits a
; best-effort "ready", so this fires whichever arrives — both are idempotent).
_PathsEdWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_PathsEdWeb_SessionCall.Bind(SessionEpoch, _PathsEdWeb_PushInitData), -1)
}

_PathsEdWeb_SessionCurrent(SessionEpoch) {
	global _PathsEdWeb_SessionEpoch
	return SessionEpoch == _PathsEdWeb_SessionEpoch
}

_PathsEdWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_PathsEdWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

_PathsEdWeb_PushInitData() {
	_PathsEdWeb_Eval(_PathsEdWeb_InitDataJs())
}

; Opens the native folder picker and hands the chosen path back to the page.
; @param Target {String} "logs" for the logs folder, else the configuration folder.
_PathsEdWeb_Browse(Target := "config") {
	global _ConfigDir
	if A_IsSuspended
		return false
	StartDir := StrReplace(Trim(Target == "logs" ? LoggerLogsDir() : _ConfigDir), "/", "\")
	Picked := Ui_DirSelect("*" . StartDir, 1, t("dialog.config_folder.select_title"), t("dialog.config_folder.select_title"), 0)
	if (Picked == "")
		return
	Fwd := StrReplace(Picked, "\", "/")
	if !RegExMatch(Fwd, "/$")
		Fwd .= "/"
	_PathsEdWeb_Eval("if(window.applyBrowseResult)window.applyBrowseResult("
		. _PathsEdWeb_JsStr(Fwd) . "," . _PathsEdWeb_JsStr(Target) . ")")
}

; The LogsDirPath a save must store: "" for the default, the resolved folder
; otherwise, or 0 to keep the stored one when the page sent no logs folder.
; A folder that is not absolute is refused, as on macOS and Linux: the boot
; resolver would discard it, and replacing it by the default here saved and
; reloaded without the user's entry, with only a log line to say why.
; @param LogsDir {String|Integer} Value from the page, or the 0 sentinel.
; @returns {String|Integer}
; @throws {ValueError} When the page sent a folder that is not absolute.
_PathsEdWeb_LogsOverride(LogsDir) {
	global _DefaultLogsDir
	if (LogsDir is Integer)
		return ConfigTransitionCurrentLogsOverride()
	if (Trim(LogsDir) != "" && !LoggerIsAbsoluteFolder(LogsDir))
		throw ValueError(AppDirsLogsOverrideKey() . " must be an absolute folder, not '" . LogsDir . "'")
	Resolved := LoggerResolveLogsDir(LogsDir, _DefaultLogsDir)
	return (Resolved = _DefaultLogsDir) ? "" : Resolved
}

; Creates the logs folder a save is about to store. The logger creates its
; folder silently at boot, so a stored folder that cannot be created left the
; next session logging nowhere; refusing it here keeps the editor open.
; @param Override {String} Value _PathsEdWeb_LogsOverride returned; "" is the
;   OS default, which the logger creates itself.
; @throws {ValueError} When the folder cannot be created.
_PathsEdWeb_PrepareLogsFolder(Override) {
	if (Override == "" || DirExist(Override))
		return
	try DirCreate(Override)
	catch as Err
		throw ValueError("the logs folder '" . Override . "' cannot be created (" . Err.Message . ")")
}

; Persists the chosen folders and reloads, mirroring the native dialog.
; @param ConfigDir {String} Configuration folder from the page.
; @param LogsDir {String|Integer} Logs folder from the page, or 0 to keep it.
_PathsEdWeb_Save(ConfigDir, LogsDir := 0) {
	global _ConfigDir, _PathsFile, _DefaultConfigDir
	if A_IsSuspended
		return false
	N := StrReplace(Trim(ConfigDir), "/", "\")
	if (N == "")
		N := _DefaultConfigDir
	if !RegExMatch(N, "\\$")
		N .= "\"
	try {
		NewLogs := _PathsEdWeb_LogsOverride(LogsDir)
		_PathsEdWeb_PrepareLogsFolder(NewLogs)
	} catch ValueError as Err {
		; Nothing is written and the editor stays open for another folder.
		try LoggerError("PathsEditor", "Refused the logs folder: {1}.", Err.Message)
		try Ui_MsgBox(t("paths_editor.save_failed"),
			t("paths_editor.save_failed_title"), "Iconx")
		return false
	}
	; No change — just close, never reload for nothing.
	if (N == _ConfigDir && NewLogs = ConfigTransitionCurrentLogsOverride()) {
		_PathsEdWeb_Close()
		return
	}
	; Fail loudly. FileOpen was unprotected and `if f` had no else, so on a
	; read-only or locked target the user's chosen directory was discarded, the
	; log asserted the opposite, and the Reload() dropped them back into the OLD
	; directory with no error anywhere — the change simply appeared not to happen.
	if !_PathsFile_Write(N, NewLogs)
		return
}

; Persist ``N`` as the configured directory in paths.toml. THE single writer.
;
; There used to be two copies of this block — this one, hardened, and a verbatim
; unhardened twin in ui/action_picker/init.ahk's ConfirmPath, which still had the
; original unprotected FileOpen and an `if f` with no else. The drift was the
; real defect: hardening one copy left the other silently discarding the user's
; chosen directory on a read-only or locked target, then Reload()ing them back
; into the OLD directory with no error anywhere. Both callers now share this.
; @param N {String} Target directory, backslash-separated and trailing-slashed.
; @param LogsDir {String|Integer} LogsDirPath to store ("" for the default), or
;   0 to keep the stored one.
; @returns {Boolean} True when the file was written; false after reporting.
_PathsFile_Write(N, LogsDir := 0) {
	global _PathsFile, ConfigurationFile, _DefaultConfigDir, _DefaultLogsDir
	PreviousCritical := Critical("Off")
	try {
	N := ConfigTransitionNormalizeConfigDir(N)
	if !(N is String) {
		try LoggerError("PathsEditor", "Refused an invalid or relative configuration directory.")
		try Ui_MsgBox(t("paths_editor.save_failed"),
			t("paths_editor.save_failed_title"), "Iconx")
		return false
	}
	AcquireResult := ConfigTransitionAcquireLifecycleBundle(_PathsFile,
		[_PathsFile])
	if !ConfigTransitionResultIs(AcquireResult, "bundle_acquired") {
		ConfigTransitionLogFailure("PathsEditor", AcquireResult)
		try Ui_MsgBox(t("paths_editor.save_failed"),
			t("paths_editor.save_failed_title"), "Iconx")
		return false
	}
	OwnerBundle := AcquireResult["bundle"]
	ReleaseBundle := true
	; The WAL is located beside this stable file and names its owner config.toml.
	; Retain this same owner from the locator change through Reload. The WAL
	; snapshots the old locator before publishing its replacement, so a crash can
	; never leave a truncated paths.toml or ambiguous directory authority.
	try {
		try DirCreate(SubStr(_PathsFile, 1, InStr(_PathsFile, "\", , -1) - 1))
		; A configuration-folder change keeps the user's LogsDirPath.
		if (LogsDir is Integer)
			LogsDir := ConfigTransitionCurrentLogsOverride()
		NewContent := ConfigTransitionPathsTomlContent(N, _DefaultConfigDir,
			LogsDir, _DefaultLogsDir)
		CommitResult := ConfigTransitionCommitOwned(_PathsFile,
			[ConfigTransitionPresentTarget(_PathsFile, NewContent)],
			OwnerBundle)
		if !ConfigTransitionResultIs(CommitResult, "committed_new") {
			ConfigTransitionLogFailure("PathsEditor", CommitResult)
			if CommitResult.Has("barrier_retained")
					&& (CommitResult["barrier_retained"] is Integer)
					&& CommitResult["barrier_retained"] == 1
				ReleaseBundle := false
			try Ui_MsgBox(t("paths_editor.save_failed"), t("paths_editor.save_failed_title"), "Iconx")
			return false
		}
		try LoggerInfo("PathsEditor", "Applying new config directory and reloading…")
		; A launched reload owns OwnerBundle until OnExit; a later refusal hands it
		; back to the same rollback this call runs when the launch is refused.
		Reloaded := ReloadPreservingSuspend(0, OwnerBundle,
			ConfigTransitionSettleRefusedReload.Bind(
				_PathsFile_RollbackRefusedReload, OwnerBundle))
		if (Reloaded is Integer) && Reloaded == 1 {
			ReleaseBundle := false
			return true
		}
		if _PathsFile_RollbackRefusedReload(OwnerBundle)
			ReleaseBundle := false
		return false
	} finally {
		if ReleaseBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
	}
	} finally Critical(PreviousCritical)
}

; Restores the previous paths.toml after a refused reload.
; @returns {Boolean} True when the rollback failed and the barrier stays
;   retained around the unresolved transition, so the bundle must not be released.
_PathsFile_RollbackRefusedReload(OwnerBundle) {
	global _PathsFile
	RollbackResult := ConfigTransitionRollbackOwned(_PathsFile, OwnerBundle)
	if ConfigTransitionResultIs(RollbackResult, "recovered_old")
			|| ConfigTransitionResultIs(RollbackResult, "absent")
		return false
	ConfigTransitionLogFailure("PathsEditorRollback", RollbackResult)
	Retained := ConfigTransitionRetainBarrier(OwnerBundle)
	try Ui_MsgBox(t("paths_editor.save_failed"),
		t("paths_editor.save_failed_title"), "Iconx")
	return Retained
}




; ==============================================================
; ===================================
; ======= 3/ initData source ========
; ===================================
; ==============================================================

; Builds the window.initData({...}) call: the current + default config and logs
; folders (forward-slash for display parity with macOS) plus the localized UI
; strings.
_PathsEdWeb_InitDataJs() {
	global _ConfigDir, _DefaultConfigDir, _DefaultLogsDir
	Cur := StrReplace(_ConfigDir, "\", "/")
	Def := StrReplace(_DefaultConfigDir, "\", "/")
	Logs := StrReplace(LoggerLogsDir(), "\", "/")
	DefLogs := StrReplace(_DefaultLogsDir, "\", "/")

	Keys := ["menu.paths.window_title"
		, "paths_editor.heading", "paths_editor.subtitle", "paths_editor.label_config_dir"
		, "paths_editor.label_logs_dir", "paths_editor.hint_logs_dir"
		, "paths_editor.tag_default", "paths_editor.default_label", "paths_editor.tag_modified"
		, "paths_editor.btn_browse", "paths_editor.btn_reset"
		, "paths_editor.btn_cancel", "paths_editor.btn_save"]
	Strings := ""
	for K in Keys {
		if (Strings != "")
			Strings .= ","
		Strings .= _PathsEdWeb_JsStr(K) . ":" . _PathsEdWeb_JsStr(t(K))
	}

	return "if(window.initData)window.initData({"
		. "configDir:" . _PathsEdWeb_JsStr(Cur) . ","
		. "defaultConfigDir:" . _PathsEdWeb_JsStr(Def) . ","
		. "logsDir:" . _PathsEdWeb_JsStr(Logs) . ","
		. "defaultLogsDir:" . _PathsEdWeb_JsStr(DefLogs) . ","
		. "strings:{" . Strings . "}"
		. "})"
}

_PathsEdWeb_HtmlUrl() {
	return "https://" . PATHSED_VHOST . "/ui/paths_editor/index.html?cb=" . A_TickCount
}





; =====================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; =====================================

; Fire-and-forget script eval. ExecuteScript().await() wedges the thread when
; called from inside a WebView2 callback, so never await here.
_PathsEdWeb_Eval(Js) {
	global _PathsEdWeb_WebView
	if !IsSet(_PathsEdWeb_WebView)
		return
	WebView_RunScriptAsync(_PathsEdWeb_WebView, Js, "PathsEditor")
}

; Returns a quoted, escaped JS string literal for safe interpolation.
_PathsEdWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

_PathsEdWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _PathsEdWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_PathsEdWeb_Controller)
		try _PathsEdWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_PathsEdWeb_OnClose(*) {
	_PathsEdWeb_Close()
}

_PathsEdWeb_Close() {
	global _PathsEdWeb_Gui
	saved := (_PathsEdWeb_Gui != 0) ? _PathsEdWeb_Gui : 0
	_PathsEdWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_PathsEdWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the frontend
; "cancel" message and the native Gui Close event both firing for the same
; teardown) is a true no-op instead of touching the globals again.
_PathsEdWeb_Reset() {
	global _PathsEdWeb_Controller, _PathsEdWeb_WebView, _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	global _PathsEdWeb_ResetDone, _PathsEdWeb_SessionEpoch

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _PathsEdWeb_ResetDone
		return
	_PathsEdWeb_ResetDone := true
	_PathsEdWeb_SessionEpoch += 1

	; The whole teardown runs under one try: a hard COM access violation can
	; occur mid-sequence, and a bare per-line `try` only catches ordinary AHK
	; exceptions — it does NOT catch that class of failure, but wrapping the
	; sequence still protects the *other* lines from a preceding non-fatal COM
	; error so the globals below are always cleared even when the unsubscribe
	; itself fails.
	try {
		; Release the subscriptions FIRST, while the controller is still alive. Their
		; __Delete unsubscribes via remove_X on the live controller; doing it AFTER
		; Controller.Close() raises a COM error that — uncaught in the window's
		; Close-event thread — terminates the entire AHK script.
		_PathsEdWeb_MsgSub := unset
		_PathsEdWeb_NavSub := unset
		if IsSet(_PathsEdWeb_Controller)
			_PathsEdWeb_Controller.Close()
	}
	_PathsEdWeb_Controller := unset
	_PathsEdWeb_WebView    := unset
}
