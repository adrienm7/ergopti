; ui/paths_editor/init.ahk

; ==============================================================================
; MODULE: Paths Editor WebView2 Host
; DESCRIPTION:
; Renders the config-folder editor on Windows via WebView2, loading the shared
; frontend at _shared/ui/paths_editor/ so the AHK and Hammerspoon drivers show
; an identical UI. Replaces the single-field native dialog (FilePathsEditor).
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
	global _PathsEdWeb_MsgSub, _PathsEdWeb_NavSub, _PathsEdWeb_ResetDone, _VendorDir, _SharedDir

	if !_PathsEdWeb_Available()
		return false

	; Singleton — bring the existing editor to the front.
	if (_PathsEdWeb_Gui != 0) {
		try WinActivate("ahk_id " . _PathsEdWeb_Gui.Hwnd)
		return true
	}

	g := Gui("+Resize +MinSize560x200", t("menu.paths.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w720 h300", "")
	g.OnEvent("Close", _PathsEdWeb_OnClose)
	g.OnEvent("Size",  _PathsEdWeb_OnResize)

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w720 h300 Center")
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
	_PathsEdWeb_ResetDone := false

	try {
		s := _PathsEdWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _PathsEdWeb_MsgSub := _PathsEdWeb_WebView.WebMessageReceived(_PathsEdWeb_OnWebMessage)
	global _PathsEdWeb_NavSub := _PathsEdWeb_WebView.NavigationCompleted(_PathsEdWeb_OnNavigationCompleted)

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
_PathsEdWeb_OnWebMessage(Handler, Args) {
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
		SetTimer(_PathsEdWeb_PushInitData, -1)
	} else if (Action == "browse") {
		SetTimer(_PathsEdWeb_Browse, -1)
	} else if (Action == "save") {
		Dir := Payload.Has("configDir") ? Payload["configDir"] : ""
		SetTimer(_PathsEdWeb_Save.Bind(Dir), -1)
	} else if (Action == "cancel") {
		SetTimer(_PathsEdWeb_Close, -1)
	}
}

; Push initData once the page has finished loading (the frontend also emits a
; best-effort "ready", so this fires whichever arrives — both are idempotent).
_PathsEdWeb_OnNavigationCompleted(Handler, Args) {
	SetTimer(_PathsEdWeb_PushInitData, -1)
}

_PathsEdWeb_PushInitData() {
	_PathsEdWeb_Eval(_PathsEdWeb_InitDataJs())
}

; Opens the native folder picker and hands the chosen path back to the page.
_PathsEdWeb_Browse() {
	global _ConfigDir
	StartDir := StrReplace(Trim(_ConfigDir), "/", "\")
	Picked := DirSelect("*" . StartDir, 1, t("dialog.config_folder.select_title"))
	if (Picked == "")
		return
	Fwd := StrReplace(Picked, "\", "/")
	if !RegExMatch(Fwd, "/$")
		Fwd .= "/"
	_PathsEdWeb_Eval("if(window.applyBrowseResult)window.applyBrowseResult(" . _PathsEdWeb_JsStr(Fwd) . ")")
}

; Persists the chosen config directory and reloads, mirroring the native dialog.
_PathsEdWeb_Save(ConfigDir) {
	global _ConfigDir, _PathsFile, _DefaultConfigDir
	N := StrReplace(Trim(ConfigDir), "/", "\")
	if (N == "")
		N := _DefaultConfigDir
	if !RegExMatch(N, "\\$")
		N .= "\"
	; No change — just close, never reload for nothing.
	if (N == _ConfigDir) {
		_PathsEdWeb_Close()
		return
	}
	; Fail loudly. FileOpen was unprotected and `if f` had no else, so on a
	; read-only or locked target the user's chosen directory was discarded, the
	; log asserted the opposite, and the Reload() dropped them back into the OLD
	; directory with no error anywhere — the change simply appeared not to happen.
	if !_PathsFile_Write(N)
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
; @returns {Boolean} True when the file was written; false after reporting.
_PathsFile_Write(N) {
	global _PathsFile, ConfigurationFile, _DefaultConfigDir
	PreviousCritical := Critical("Off")
	try {
	N := ConfigTransitionNormalizeConfigDir(N)
	if !(N is String) {
		try LoggerError("PathsEditor", "Refused an invalid or relative configuration directory.")
		try MsgBox(t("paths_editor.save_failed"),
			t("paths_editor.save_failed_title"), "Iconx")
		return false
	}
	AcquireResult := ConfigTransitionAcquireLifecycleBundle(_PathsFile,
		[_PathsFile])
	if !ConfigTransitionResultIs(AcquireResult, "bundle_acquired") {
		ConfigTransitionLogFailure("PathsEditor", AcquireResult)
		try MsgBox(t("paths_editor.save_failed"),
			t("paths_editor.save_failed_title"), "Iconx")
		return false
	}
	OwnerBundle := AcquireResult["bundle"]
	ReleaseBundle := true
	; The WAL is located beside this stable file and names its owner config.toml.
	; Settle native and durable authority before changing the next boot's
	; directory selection, then retain this same owner through Reload. The WAL
	; snapshots the old locator before publishing its replacement, so a crash can
	; never leave a truncated paths.toml or ambiguous directory authority.
	try {
		if !LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle) {
			try LoggerError("PathsEditor", "Could not change the config directory while LLM trigger recovery is incomplete.")
			try MsgBox(t("paths_editor.save_failed"),
				t("paths_editor.save_failed_title"), "Iconx")
			return false
		}
		try DirCreate(SubStr(_PathsFile, 1, InStr(_PathsFile, "\", , -1) - 1))
		NewContent := ConfigTransitionPathsTomlContent(N, _DefaultConfigDir)
		CommitResult := ConfigTransitionCommitOwned(_PathsFile,
			[ConfigTransitionPresentTarget(_PathsFile, NewContent)],
			OwnerBundle)
		if !ConfigTransitionResultIs(CommitResult, "committed_new") {
			ConfigTransitionLogFailure("PathsEditor", CommitResult)
			if CommitResult.Has("barrier_retained")
					&& (CommitResult["barrier_retained"] is Integer)
					&& CommitResult["barrier_retained"] == 1
				ReleaseBundle := false
			try MsgBox(t("paths_editor.save_failed"), t("paths_editor.save_failed_title"), "Iconx")
			return false
		}
		try LoggerInfo("PathsEditor", "Applying new config directory and reloading…")
		Reloaded := ReloadPreservingSuspend(0, OwnerBundle)
		if (Reloaded is Integer) && Reloaded == 1
			return true
		RollbackResult := ConfigTransitionRollbackOwned(_PathsFile,
			OwnerBundle)
		if !ConfigTransitionResultIs(RollbackResult, "recovered_old")
				&& !ConfigTransitionResultIs(RollbackResult, "absent") {
			ConfigTransitionLogFailure("PathsEditorRollback", RollbackResult)
			if ConfigTransitionRetainBarrier(OwnerBundle)
				ReleaseBundle := false
			try MsgBox(t("paths_editor.save_failed"),
				t("paths_editor.save_failed_title"), "Iconx")
		}
		return false
	} finally {
		if ReleaseBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
	}
	} finally Critical(PreviousCritical)
}




; ==============================================================
; ===================================
; ======= 3/ initData source ========
; ===================================
; ==============================================================

; Builds the window.initData({...}) call: the current + default config dir
; (forward-slash for display parity with macOS) plus the localized UI strings.
_PathsEdWeb_InitDataJs() {
	global _ConfigDir, _DefaultConfigDir
	Cur := StrReplace(_ConfigDir, "\", "/")
	Def := StrReplace(_DefaultConfigDir, "\", "/")

	Keys := ["menu.paths.window_title"
		, "paths_editor.heading", "paths_editor.subtitle", "paths_editor.label_config_dir"
		, "paths_editor.tag_default", "paths_editor.tag_modified"
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
	try _PathsEdWeb_WebView.ExecuteScriptAsync(Js)
}

; Returns a quoted, escaped JS string literal for safe interpolation.
_PathsEdWeb_JsStr(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, '"', '\"')
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`t", "\t")
	return '"' . s . '"'
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
	global _PathsEdWeb_ResetDone

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _PathsEdWeb_ResetDone
		return
	_PathsEdWeb_ResetDone := true

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
