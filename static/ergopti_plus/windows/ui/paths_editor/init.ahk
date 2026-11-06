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
global _PathsEdWeb_SubscriptionOwner := 0
global _PathsEdWeb_RetiredHosts := []

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
	global _VendorDir, _SharedDir, _PathsEdWeb_SubscriptionOwner

	EntryEpoch := _PathsEdWeb_SessionEpoch
	_PathsEdWeb_RetryRetiredHosts()
	if _PathsEdWeb_SessionEpoch != EntryEpoch
		return true
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

	; Publish the native owner before Show can dispatch Close. Its existing
	; handler must be able to destroy this exact window during the Show pump.
	_PathsEdWeb_Gui := g
	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w720 h440 Center")
	if !_PathsEdWeb_StartupCurrent(SessionEpoch, g) {
		try g.Destroy()
		return true
	}

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	Installed := false, Host := 0
	try {
		try {
			; Both the shared environment and controller await can dispatch Close.
			Environment := WebView_SharedEnvironment(loader)
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			Controller := WebView2.create(Placeholder.Hwnd, , Environment)
		} catch as Err {
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			try LoggerError("PathsEditor", "WebView2 create failed: {1} — falling back to native dialog.", Err.Message)
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			; Capture the exact GUI even though no controller was ever created.
			; The usual retirement queue owns any unacknowledged Destroy.
			Host := _PathsEdWeb_BeginBareHost(g, SessionEpoch)
			if !IsObject(Host)
				return true
			ResetReceipt := false
			_PathsEdWeb_Reset(g, SessionEpoch, &ResetReceipt)
			PreviousCritical := Critical("On")
			try FallbackReady := ResetReceipt && !IsObject(Host.gui) && _PathsEdWeb_Gui == 0 && _PathsEdWeb_ResetDone
				&& _PathsEdWeb_SessionEpoch == SessionEpoch + 1
			finally Critical(PreviousCritical)
			return !FallbackReady
		}
		if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
			return true
		View := Controller.CoreWebView2
		if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
			return true

		try {
			s := View.Settings
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			s.AreDevToolsEnabled := false
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			s.AreDefaultContextMenusEnabled := false
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			s.IsStatusBarEnabled := false
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			s.AreBrowserAcceleratorKeysEnabled := false
			if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
				return true
			s.IsSwipeNavigationEnabled := false
		}
		if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
			return true

		Host := _PathsEdWeb_BeginSubscriptions(g, Controller, View, SessionEpoch)
		if !IsObject(Host)
			return true
		if !_PathsEdWeb_Subscribe(Host, "message", _PathsEdWeb_OnWebMessage.Bind(SessionEpoch))
			return true
		if !_PathsEdWeb_Subscribe(Host, "navigation", _PathsEdWeb_OnNavigationCompleted.Bind(SessionEpoch))
			return true
		try View.SetVirtualHostNameToFolderMapping(PATHSED_VHOST, _SharedDir, PATHSED_HOST_ACCESS_ALLOW)
		PreviousCritical := Critical("On")
		try {
			if _PathsEdWeb_StartupCurrent(SessionEpoch, g) && _PathsEdWeb_SubscriptionOwner == Host && !Host.retired {
				_PathsEdWeb_Controller := Controller
				_PathsEdWeb_WebView := View
				_PathsEdWeb_MsgSub := Host.message
				_PathsEdWeb_NavSub := Host.navigation
				Installed := true
			}
		} finally Critical(PreviousCritical)
		if !Installed || !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
			return true

		; Navigation can synchronously deliver callbacks. Only this frame's
		; captured view and controller may be used after that boundary.
		try View.Navigate(_PathsEdWeb_HtmlUrl())
		if !_PathsEdWeb_StartupCurrent(SessionEpoch, g)
			return true
		try Controller.Fill()
		if _PathsEdWeb_StartupCurrent(SessionEpoch, g)
			try LoggerSuccess("PathsEditor", "Config-folder editor shown via WebView2.")
		return true
	} finally {
		if !Installed {
			RetireDestroy := IsObject(Host) && (!Host.retired || Host.destroy)
			if IsObject(Host) {
				if _PathsEdWeb_Gui == g
					_PathsEdWeb_Reset(g, SessionEpoch)
				; Reset already queued a bare host; leave any failed Destroy debt
				; for the next public request instead of retrying inside this one.
				if !Host.HasOwnProp("bare") || !Host.bare || !Host.retired
					_PathsEdWeb_RetireHost(Host, RetireDestroy, true)
			} else if IsSet(Controller) {
				try Controller.Close()
				catch as Err
					try LoggerError("PathsEditor", "Retired browser cleanup failed: {1}.", Err.Message)
			}
		}
	}
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

; Admission after a browser callout must retain the exact native singleton.
_PathsEdWeb_StartupCurrent(SessionEpoch, Window) {
	global _PathsEdWeb_Gui, _PathsEdWeb_ResetDone
	return _PathsEdWeb_SessionCurrent(SessionEpoch) && !_PathsEdWeb_ResetDone
		&& _PathsEdWeb_Gui == Window
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
_PathsEdWeb_Browse(Target := "config", PickFn := Ui_DirSelect, EvalFn := _PathsEdWeb_Eval) {
	global _ConfigDir, _PathsEdWeb_SessionEpoch
	if A_IsSuspended
		return false
	SessionEpoch := _PathsEdWeb_SessionEpoch
	StartDir := StrReplace(Trim(Target == "logs" ? LoggerLogsDir() : _ConfigDir), "/", "\")
	Picked := PickFn.Call("*" . StartDir, 1, t("dialog.config_folder.select_title"), t("dialog.config_folder.select_title"), 0)
	; Native modals pump close/reopen and pause callbacks before returning.
	if (Picked == "" || A_IsSuspended || !_PathsEdWeb_SessionCurrent(SessionEpoch))
		return false
	Fwd := StrReplace(Picked, "\", "/")
	if !RegExMatch(Fwd, "/$")
		Fwd .= "/"
	EvalFn.Call("if(window.applyBrowseResult)window.applyBrowseResult("
		. _PathsEdWeb_JsStr(Fwd) . "," . _PathsEdWeb_JsStr(Target) . ")")
}

; The default Gui Close action only hides the window and keeps its controls
; alive. Explicit cancellation retires that HWND while a folder modal pumps.
_PathsEdNative_BindCancellation(Window) {
	for EventName in ["Close", "Escape"]
		Window.OnEvent(EventName, _PathsEdNative_Cancel)
}

_PathsEdNative_Cancel(Window, *) {
	Window.Destroy()
	return true
}

; The native fallback owns a concrete control rather than a WebView epoch.
; Closing its window while the picker pumps must not write the dead control.
_PathsEdNative_Browse(Window, Edit, PickFn := Ui_DirSelect, ExistsFn := WMHandleExists) {
	if A_IsSuspended
		return false
	try Hwnd := Window.Hwnd
	catch
		return false
	if !Hwnd || !ExistsFn.Call(Hwnd)
		return false
	Picked := PickFn.Call("*" . StrReplace(Trim(Edit.Value), "/", "\"), 1,
		t("dialog.config_folder.select_title"), t("dialog.config_folder.select_title"), 0)
	if Picked == "" || A_IsSuspended
		return false
	try {
		if Window.Hwnd != Hwnd || !ExistsFn.Call(Hwnd)
			return false
	} catch {
		return false
	}
	Edit.Value := StrReplace(Picked, "\", "/")
	return true
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
		try WebView_FitToWindow(_PathsEdWeb_Controller)
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_PathsEdWeb_OnClose(GuiObj := unset, *) {
	_PathsEdWeb_Close(GuiObj?)
}

_PathsEdWeb_Close(ExpectedGui := unset) {
	global _PathsEdWeb_Gui
	Window := IsSet(ExpectedGui) ? ExpectedGui : _PathsEdWeb_Gui
	Saved := _PathsEdWeb_Reset(Window)
	if Saved
		try Saved.Destroy()
}

; Reset without an exact window retains the native GUI for a later Close.
_PathsEdWeb_Reset(ExpectedGui := unset, ExpectedEpoch := unset, &ResetReceipt := unset) {
	global _PathsEdWeb_Gui, _PathsEdWeb_Controller, _PathsEdWeb_WebView, _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub
	global _PathsEdWeb_ResetDone, _PathsEdWeb_SessionEpoch
	global _PathsEdWeb_SubscriptionOwner, _PathsEdWeb_RetiredHosts
	ResetReceipt := false
	Host := 0, SavedGui := 0, SavedController := 0, SavedMsg := 0, SavedNav := 0
	PreviousCritical := Critical("On")
	try {
		if IsSet(ExpectedGui) && _PathsEdWeb_Gui != ExpectedGui
			return 0
		if IsSet(ExpectedEpoch) && !_PathsEdWeb_SessionCurrent(ExpectedEpoch)
			return 0
		if _PathsEdWeb_ResetDone {
			if !IsSet(ExpectedGui)
				return 0
			SavedGui := _PathsEdWeb_Gui
			_PathsEdWeb_Gui := 0
			for Pending in _PathsEdWeb_RetiredHosts
				if Pending.gui == SavedGui {
					Host := Pending, Host.destroy := true
					break
				}
		} else {
			SavedGui := _PathsEdWeb_Gui
			Host := _PathsEdWeb_SubscriptionOwner
			SavedController := IsSet(_PathsEdWeb_Controller) ? _PathsEdWeb_Controller : 0
			SavedView := IsSet(_PathsEdWeb_WebView) ? _PathsEdWeb_WebView : 0
			SavedMsg := IsSet(_PathsEdWeb_MsgSub) ? _PathsEdWeb_MsgSub : 0
			SavedNav := IsSet(_PathsEdWeb_NavSub) ? _PathsEdWeb_NavSub : 0
			_PathsEdWeb_ResetDone := true
			_PathsEdWeb_SessionEpoch += 1
			_PathsEdWeb_MsgSub := unset, _PathsEdWeb_NavSub := unset
			_PathsEdWeb_Controller := unset, _PathsEdWeb_WebView := unset
			_PathsEdWeb_SubscriptionOwner := 0
			ResetReceipt := true
			if IsSet(ExpectedGui)
				_PathsEdWeb_Gui := 0
			if IsObject(Host) {
				Host.retired := true, Host.destroy := IsSet(ExpectedGui)
				_PathsEdWeb_RetiredHosts.Push(Host)
			}
		}
	} finally Critical(PreviousCritical)
	; Global aliases must be gone before the host releases its own handles.
	SavedMsg := 0, SavedNav := 0
	if IsObject(Host) {
		if Host.destroy
			try Host.gui.Hide()
		_PathsEdWeb_RetryRetiredHosts()
		return 0
	}
	if SavedController
		try SavedController.Close()
	return SavedGui
}

; A native close revokes admission immediately but retains the exact host until
; any add_Event call has returned its handle and that handle is released.
; A factory failure has no controller, but still owns this native window.
_PathsEdWeb_BeginBareHost(Window, Epoch) {
	global _PathsEdWeb_SubscriptionOwner
	PreviousCritical := Critical("On")
	try {
		if !_PathsEdWeb_StartupCurrent(Epoch, Window) || IsObject(_PathsEdWeb_SubscriptionOwner)
			return 0
		Hwnd := Window.Hwnd
		Host := {gui: Window, hwnd: Hwnd, bare: true, controller: 0, view: 0, epoch: Epoch,
			message: 0, navigation: 0, in_flight: false, retired: false, closing: false, closed: true, destroy: false}
		_PathsEdWeb_SubscriptionOwner := Host
		return Host
	} finally Critical(PreviousCritical)
}

; Only a different AHK owner or native absence proves this HWND was retired.
; An extant HWND without a resolvable AHK owner stays debt rather than being adopted.
_PathsEdWeb_BareWindowRetired(Host) {
	if !DllCall("User32\IsWindow", "Ptr", Host.hwnd, "Int")
		return true
	Other := GuiFromHwnd(Host.hwnd)
	return IsObject(Other) && Other != Host.gui
}

_PathsEdWeb_BeginSubscriptions(Window, Controller, View, Epoch) {
	global _PathsEdWeb_SubscriptionOwner, _PathsEdWeb_Gui
	Host := {gui: Window, controller: Controller, view: View, epoch: Epoch,
		message: 0, navigation: 0, in_flight: false, retired: false, closing: false, closed: false, destroy: false}
	PreviousCritical := Critical("On")
	try {
		if !_PathsEdWeb_StartupCurrent(Epoch, Window) || IsObject(_PathsEdWeb_SubscriptionOwner)
			return 0
		_PathsEdWeb_SubscriptionOwner := Host
		return Host
	} finally Critical(PreviousCritical)
}

_PathsEdWeb_Subscribe(Host, Kind, Handler) {
	global _PathsEdWeb_SubscriptionOwner, _PathsEdWeb_Gui
	PreviousCritical := Critical("On")
	try {
		if Host.retired || _PathsEdWeb_SubscriptionOwner != Host || _PathsEdWeb_Gui != Host.gui
				|| !_PathsEdWeb_StartupCurrent(Host.epoch, Host.gui)
			return false
		Host.in_flight := true
	} finally Critical(PreviousCritical)
	Subscription := 0, Failed := false, FailureValue := 0
	try {
		Subscription := Kind == "message" ? Host.view.WebMessageReceived(Handler)
			: Host.view.NavigationCompleted(Handler)
	} catch Any as Failure {
		Failed := true, FailureValue := Failure
	} finally {
		PreviousCritical := Critical("On")
		try {
			Host.%Kind% := Subscription
			Subscription := 0
			Host.in_flight := false
			Current := !Host.retired && _PathsEdWeb_SubscriptionOwner == Host
				&& _PathsEdWeb_StartupCurrent(Host.epoch, Host.gui)
		} finally Critical(PreviousCritical)
	}
	if Host.retired
		_PathsEdWeb_RetryRetiredHosts()
	if Failed
		throw FailureValue
	return Current && !Host.retired
}

_PathsEdWeb_RetireHost(Host, Destroy, RespectExisting := false) {
	global _PathsEdWeb_RetiredHosts, _PathsEdWeb_SubscriptionOwner
	PreviousCritical := Critical("On")
	try {
		if !IsObject(Host.gui)
			return
		; A plumbing Reset can retire the host after the caller's snapshot.
		Host.destroy := Host.destroy || (Destroy && (!RespectExisting || !Host.retired))
		Host.retired := true
		if _PathsEdWeb_SubscriptionOwner == Host
			_PathsEdWeb_SubscriptionOwner := 0
		Found := false
		for Pending in _PathsEdWeb_RetiredHosts
			if Pending == Host
				Found := true
		if !Found
			_PathsEdWeb_RetiredHosts.Push(Host)
	} finally Critical(PreviousCritical)
	if Host.destroy
		try Host.gui.Hide()
	_PathsEdWeb_RetryRetiredHosts()
}

_PathsEdWeb_RetryRetiredHosts() {
	global _PathsEdWeb_RetiredHosts
	PreviousCritical := Critical("On")
	try Pending := _PathsEdWeb_RetiredHosts.Clone()
	finally Critical(PreviousCritical)
	for Host in Pending {
		PreviousCritical := Critical("On")
		try {
			if Host.in_flight || Host.closing
				continue
			Host.closing := true
		} finally Critical(PreviousCritical)
		Settled := false, Destroyed := false, Recheck := false
		try {
			Host.message := 0, Host.navigation := 0
			if !Host.closed {
				Host.controller.Close()
				Host.closed := true
			}
			if Host.destroy {
				if Host.HasOwnProp("bare") && Host.bare {
					if !_PathsEdWeb_BareWindowRetired(Host) {
						if GuiFromHwnd(Host.hwnd) != Host.gui
							throw Error("The failed Paths editor HWND identity is unresolved.")
						; Verify the actual outcome even if the call throws after effect.
						try Host.gui.Destroy()
					}
					if !_PathsEdWeb_BareWindowRetired(Host)
						throw Error("The failed Paths editor native window remains live.")
				} else
					Host.gui.Destroy()
				Destroyed := true
			}
			Settled := true
		} catch Any as Failure {
			try LoggerWarn("PathsEditor", "Browser retirement remains pending (error_type={1}).", Type(Failure))
		} finally {
			; Retain local strong references until after the RAM-only claim.
			Window := Host.gui, Controller := Host.controller, View := Host.view
			PreviousCritical := Critical("On")
			try {
				Host.closing := false
				if Settled && Host.destroy && !Destroyed
					Recheck := true
				else if Settled {
					Host.gui := 0, Host.controller := 0, Host.view := 0
					Count := _PathsEdWeb_RetiredHosts.Length
					Loop Count {
						Index := Count - A_Index + 1
						if _PathsEdWeb_RetiredHosts[Index] == Host
							_PathsEdWeb_RetiredHosts.RemoveAt(Index)
					}
				}
			} finally Critical(PreviousCritical)
		}
		if Recheck
			_PathsEdWeb_RetryRetiredHosts()
	}
}
