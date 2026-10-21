; ui/personal_info_editor/init.ahk

; ==============================================================================
; MODULE: Personal Information Editor WebView2 Host
; DESCRIPTION:
; Renders the personal-information form on Windows via WebView2, loading the
; shared frontend at _shared/ui/personal_info_editor/ so the AHK and Hammerspoon
; drivers show an identical standalone window. Replaces the native multi-field
; Gui dialog (PersonalInformationEditor).
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir.
; 2. Dynamic fields — the field list is built from the live PersonalInformation
;    map, carrying each entry's "(@letter<MagicKey>)" trigger hint, exactly like
;    the native dialog did.
; 3. JS<->AHK bridge — the page posts {action} messages (ready/save/cancel);
;    saving writes personal_info.toml and reloads, like the native dialog.
; 4. Singleton — a second open focuses the existing window.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ===================================

; Singleton window + WebView2 plumbing. Subscription handles live in globals so
; the binding does not GC them (which would silently drop the JS->AHK channel);
; they are released BEFORE Controller.Close() in _PiEdWeb_Reset.
global _PiEdWeb_Gui        := 0
global _PiEdWeb_Controller := unset
global _PiEdWeb_WebView    := unset
global _PiEdWeb_MsgSub     := unset
global _PiEdWeb_NavSub     := unset
; True once _PiEdWeb_Reset() has torn the controller down. Both the frontend
; "cancel" message and the native Gui Close event route through the SAME
; _PiEdWeb_Close() -> _PiEdWeb_Reset() call, and a second pass's unsubscribe
; line calls remove_WebMessageReceived via ComCall against a CoreWebView2
; pointer already invalidated by the first pass's Controller.Close() — a
; genuine SEH access violation no AHK try/catch can intercept (see
; personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the crash this
; mirrors). The flag makes the second call a true no-op instead.
global _PiEdWeb_ResetDone  := false
global _PiEdWeb_SessionEpoch := 0
global _PiEdWeb_EditorSource := 0

global PIED_VHOST             := "ergopti.personalinfo"
global PIED_HOST_ACCESS_ALLOW := 1

; Returns true when the WebView2 runtime binding + loader DLL are present.
_PiEdWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the editor in a WebView2 window. Returns true on success (the
; caller must NOT also build the native dialog), false to fall back.
_PiEdWeb_TryOpen() {
	global _PiEdWeb_Gui, _PiEdWeb_Controller, _PiEdWeb_WebView
	global _PiEdWeb_MsgSub, _PiEdWeb_NavSub, _PiEdWeb_ResetDone, _PiEdWeb_SessionEpoch
	global _VendorDir, _SharedDir
	global _PiEdWeb_EditorSource

	if !_PiEdWeb_Available()
		return false

	if (_PiEdWeb_Gui != 0) {
		WMPresentWindow(_PiEdWeb_Gui)
		return true
	}
	_PiEdWeb_SessionEpoch += 1
	SessionEpoch := _PiEdWeb_SessionEpoch
	_PiEdWeb_ResetDone := false
	Path := PersonalInfoTomlPath()
	ConfiguredKey := _ConfigWriteLeaseKey(Path)
	ReadPersonalInfoToml(Path)
	EditorSource := _PersonalInfoCaptureEditorSource(Path, true, ConfiguredKey)
	EditorSource["web_epoch"] := SessionEpoch
	PreviousCritical := Critical("On")
	try {
		if !_PiEdWeb_SessionCurrent(SessionEpoch) || _PiEdWeb_ResetDone
			|| !_PersonalInfoEditorPathCurrent(EditorSource)
			return true
		_PiEdWeb_EditorSource := EditorSource
	} finally Critical(PreviousCritical)

	g := Gui_Create("+Resize +MinSize480x400", t("dialog.personal_info.title"))
	Controller := unset, MsgSub := unset, NavSub := unset
	Installed := false
	try {
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		g.BackColor := "0xf5f5f7"
		g.MarginX := 0
		g.MarginY := 0
		Placeholder := g.Add("Text", "x0 y0 w560 h680", "")
		g.OnEvent("Close", _PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_OnClose))
		g.OnEvent("Size", _PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_OnResize))
		PreviousCritical := Critical("On")
		try {
			if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
				return true
			_PiEdWeb_Gui := g
		} finally Critical(PreviousCritical)
		; Show BEFORE creating the control: a hidden Gui has a zero client rect.
		g.Show("w560 h680 Center")
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		View := Controller.CoreWebView2
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		try {
			s := View.Settings
			for Setting in ["AreDevToolsEnabled", "AreDefaultContextMenusEnabled", "IsStatusBarEnabled",
				"AreBrowserAcceleratorKeysEnabled", "IsSwipeNavigationEnabled"] {
				if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
					return true
				s.%Setting% := false
			}
		}
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		MsgSub := View.WebMessageReceived(_PiEdWeb_OnWebMessage.Bind(SessionEpoch))
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		NavSub := View.NavigationCompleted(_PiEdWeb_OnNavigationCompleted.Bind(SessionEpoch))
		PreviousCritical := Critical("On")
		try {
			if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource) || _PiEdWeb_Gui != g
				return true
			_PiEdWeb_Controller := Controller
			_PiEdWeb_WebView := View
			_PiEdWeb_MsgSub := MsgSub
			_PiEdWeb_NavSub := NavSub
			; Move subscription custody before restoring the scheduler. Reset must
			; unsubscribe before Close, without a local alias delaying __Delete.
			MsgSub := unset, NavSub := unset
			Installed := true
		} finally Critical(PreviousCritical)
		try View.SetVirtualHostNameToFolderMapping(PIED_VHOST, _SharedDir, PIED_HOST_ACCESS_ALLOW)
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		try View.Navigate(_PiEdWeb_HtmlUrl())
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return true
		try Controller.Fill()
		try LoggerSuccess("PersonalInfo", "Personal info editor shown via WebView2.")
	} catch as Err {
		try LoggerError("PersonalInfo", "WebView2 create failed: {1} — falling back to native dialog.", Err.Message)
		; A retired opening must not launch a fallback over its successor.
		return Installed || !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
	} finally {
		if !Installed {
			; These locals were never lent to another session. Release subscriptions
			; before their controller; only the exact still-current frame resets RAM.
			MsgSub := unset, NavSub := unset
			if IsSet(Controller)
				try Controller.Close()
			if _PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource) {
				_PiEdWeb_Reset()
				if _PiEdWeb_Gui == g
					_PiEdWeb_Gui := 0
			}
			try g.Destroy()
		}
	}

	return true
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page (each is a JSON-encoded {action, …} object).
_PiEdWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	global _PiEdWeb_EditorSource
	if !_PiEdWeb_SessionCurrent(SessionEpoch)
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
		SetTimer(_PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_PushInitData), -1)
	} else if (Action == "save") {
		Values := (Payload.Has("values") && Payload["values"] is Map) ? Payload["values"] : Map()
		EditorSource := _PiEdWeb_EditorSource
		if !_PiEdWeb_EditorSourceCurrent(SessionEpoch, EditorSource)
			return
		SetTimer(_PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_Save,
			Values, 0, 0, 0, 0, 0, 0, EditorSource), -1)
	} else if (Action == "cancel") {
		SetTimer(_PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_Close), -1)
	}
}

_PiEdWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_PiEdWeb_SessionCall.Bind(SessionEpoch, _PiEdWeb_PushInitData), -1)
}

_PiEdWeb_SessionCurrent(SessionEpoch) {
	global _PiEdWeb_SessionEpoch
	return SessionEpoch == _PiEdWeb_SessionEpoch
}

_PiEdWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_PiEdWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

_PiEdWeb_PushInitData() {
	global _PiEdWeb_EditorSource, _PiEdWeb_WebView, _PiEdWeb_SessionEpoch
	EditorSource := _PiEdWeb_EditorSource, Epoch := _PiEdWeb_SessionEpoch
	if !_PiEdWeb_EditorSourceCurrent(Epoch, EditorSource) || !IsSet(_PiEdWeb_WebView)
		return
	View := _PiEdWeb_WebView
	Script := _PiEdWeb_InitDataJs(EditorSource)
	if !_PiEdWeb_EditorSourceCurrent(Epoch, EditorSource)
		return
	WebView_RunScriptAsync(View, Script, "PersonalInfoEditor")
}

; Pure RAM guard: the retained session, never a newer global receipt, owns Save.
_PiEdWeb_EditorSourceCurrent(Epoch, EditorSource) {
	global _PiEdWeb_EditorSource, _PiEdWeb_SessionEpoch, _PiEdWeb_ResetDone
	return EditorSource is Map && EditorSource == _PiEdWeb_EditorSource
		&& Epoch == _PiEdWeb_SessionEpoch && !_PiEdWeb_ResetDone
		&& EditorSource.Get("web_epoch", 0) == Epoch && _PersonalInfoEditorPathCurrent(EditorSource)
		&& EditorSource.Get("active", 0) is Integer && EditorSource["active"] == 1
}

; Persists the edited values to personal_info.toml and reloads (the engine
; rebuilds its personal-info expansions on load), mirroring the native dialog.
_PiEdWeb_Save(Values, WriterFn := 0, ReplaceFn := 0, DeleteFn := 0,
		AuthorizeFn := 0, NotifyFn := 0, ReloadFn := 0, EditorSource := unset) {
	global ScriptInformation
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; The deferred bridge normally starts non-Critical, but keep injected or
		; future callers from re-wrapping persistence and reload in a long span.
		Critical("Off")
		try return _PiEdWeb_Save(Values, WriterFn, ReplaceFn, DeleteFn,
			AuthorizeFn, NotifyFn, ReloadFn, EditorSource?)
		finally Critical(InheritedCritical)
	}
	; The bridge already checked Suspend before scheduling this callback, but
	; SetTimer yields. PersonalInfoCommitValues re-checks both on entry and in
	; the atomic publish span, so a pause between the message and rename refuses
	; without changing disk or RAM.
	Path := ScriptInformation["PersonalInfoTomlPath"]
	if !IsSet(EditorSource) {
		AdapterSource := _PersonalInfoEditorAdapterSource(Path)
		if AdapterSource is Map
			EditorSource := AdapterSource
	}
	if IsSet(EditorSource) && EditorSource is Map && EditorSource.Get("path", 0) is String
		Path := EditorSource["path"]
	if !PersonalInfoCommitValues(Path,
			Values, WriterFn, ReplaceFn, DeleteFn, AuthorizeFn, EditorSource?) {
		try LoggerError("PersonalInfo", "Personal information NOT saved — keeping the editor open so the values are not lost.")
		return _PersonalInfoReportSaveFailure(NotifyFn)
	}
	try LoggerInfo("PersonalInfo", "Saved personal information — reloading…")
	if !_EditorReloadAfterCommit(ReloadFn)
		return false
	return true
}




; ==============================================================
; ===================================
; ======= 3/ initData source ========
; ===================================
; ==============================================================

; Builds window.initData({fields, strings}). Each field carries the live value
; and, when the key is bound to a personal-info letter, the "(@letter<star>)"
; trigger hint shown beside its label — same affordance as the native dialog.
_PiEdWeb_InitDataJs(EditorSource := unset) {
	global PersonalInformation, PersonalInformationLetters, ScriptInformation
	Star := ScriptInformation.Has("MagicKey") ? ScriptInformation["MagicKey"] : Chr(0x2605)

	; Reverse map: personal-info key -> trigger letter.
	if IsSet(EditorSource) {
		if !(EditorSource is Map) || !(EditorSource.Get("information", 0) is Map)
			|| !(EditorSource.Get("letters", 0) is Map)
			return ""
		Information := EditorSource["information"], Letters := EditorSource["letters"]
	} else {
		Information := PersonalInformation
		Letters := IsSet(PersonalInformationLetters) ? PersonalInformationLetters : Map()
	}
	Reverse := Map()
	if Letters is Map {
		for Letter, MappedKey in Letters
			Reverse[MappedKey] := Letter
	}

	Fields := ""
	for Key, Val in Information {
		Hint := Reverse.Has(Key) ? ("(@" . Reverse[Key] . Star . ")") : ""
		if (Fields != "")
			Fields .= ","
		Fields .= "{key:" . _PiEdWeb_JsStr(Key)
			. ",label:" . _PiEdWeb_JsStr(Key)
			. ",value:" . _PiEdWeb_JsStr(Val)
			. ",hint:" . _PiEdWeb_JsStr(Hint) . "}"
	}

	Strings := _PiEdWeb_JsStr("editor.personal_info.window_title") . ":" . _PiEdWeb_JsStr(t("editor.personal_info.window_title"))
		. "," . _PiEdWeb_JsStr("common.save") . ":" . _PiEdWeb_JsStr(t("common.save"))
		. "," . _PiEdWeb_JsStr("common.cancel") . ":" . _PiEdWeb_JsStr(t("common.cancel"))

	return "if(window.initData)window.initData({fields:[" . Fields . "],strings:{" . Strings . "}})"
}

_PiEdWeb_HtmlUrl() {
	return "https://" . PIED_VHOST . "/ui/personal_info_editor/index.html?cb=" . A_TickCount
}





; =====================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; =====================================

; Fire-and-forget script eval (never await inside a WebView2 callback).
_PiEdWeb_Eval(Js) {
	global _PiEdWeb_WebView
	if !IsSet(_PiEdWeb_WebView)
		return
	WebView_RunScriptAsync(_PiEdWeb_WebView, Js, "PersonalInfoEditor")
}

; Returns a quoted, escaped JS string literal for safe interpolation.
_PiEdWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

_PiEdWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _PiEdWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_PiEdWeb_Controller)
		try _PiEdWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_PiEdWeb_OnClose(*) {
	_PiEdWeb_Close()
}

_PiEdWeb_Close() {
	global _PiEdWeb_Gui
	saved := (_PiEdWeb_Gui != 0) ? _PiEdWeb_Gui : 0
	_PiEdWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_PiEdWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui). Idempotent: a
; second call (e.g. the frontend "cancel" message and the native Gui Close
; event both firing for the same teardown) is a true no-op instead of touching
; the globals again.
_PiEdWeb_Reset() {
	global _PiEdWeb_Controller, _PiEdWeb_WebView, _PiEdWeb_MsgSub, _PiEdWeb_NavSub
	global _PiEdWeb_ResetDone, _PiEdWeb_SessionEpoch
	global _PiEdWeb_EditorSource

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _PiEdWeb_ResetDone
		return
	_PiEdWeb_ResetDone := true
	_PiEdWeb_SessionEpoch += 1
	RetiredSource := _PiEdWeb_EditorSource
	_PiEdWeb_EditorSource := 0
	if RetiredSource is Map
		RetiredSource["active"] := false

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
		_PiEdWeb_MsgSub := unset
		_PiEdWeb_NavSub := unset
		if IsSet(_PiEdWeb_Controller)
			_PiEdWeb_Controller.Close()
	}
	_PiEdWeb_Controller := unset
	_PiEdWeb_WebView    := unset
}
