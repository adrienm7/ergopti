; ui/prompt_editor/init.ahk

; ==============================================================================
; MODULE: Prompt Editor WebView2 Host
; DESCRIPTION:
; Renders the LLM prompt-profile editor on Windows via WebView2, loading the
; shared frontend at _shared/ui/prompt_editor/ so the AHK and Hammerspoon drivers
; show an identical rich editor (token chips + autocomplete). Replaces the
; two-step native InputBox wizard (LLM_Menu_PromptCreateProfile /
; LLM_Menu_PromptEditProfile), which remain as a fallback when WebView2 is absent.
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir; file:// is an opaque origin
;    that breaks the JS->AHK channel, so the document is served over https.
; 2. Create + edit — opened with no profile creates a new user profile; opened
;    with an existing profile edits it in place by id. The webview's prompt field
;    maps to the Windows profile's system_single, label to label, mode to batch.
; 3. Persist + refresh — on save the profile is written through the same path the
;    native wizard used (LLM_Menu_SaveConfig + LLM_Engine_Init + LLM_Menu_Build +
;    profile-hotkey rebind), so behaviour is identical to the native flow.
; 4. Safe teardown — subscription handles are released BEFORE Controller.Close()
;    (their __Delete unsubscribes on the live controller; reversing the order
;    raises a COM error that, uncaught in the Close thread, quits the script).
; 5. Immutable context — every displayed profile owns an edit id + epoch pair
;    echoed by the page, so deferred callbacks can never mutate or close a newer
;    profile after the singleton editor has been re-pointed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ===================================

; Singleton window + WebView2 plumbing. Subscription handles live in globals so
; the binding does not GC them; they are released BEFORE Controller.Close() in
; _PromptEdWeb_Reset.
global _PromptEdWeb_Gui        := 0
global _PromptEdWeb_Controller := unset
global _PromptEdWeb_WebView    := unset
global _PromptEdWeb_MsgSub     := unset
global _PromptEdWeb_NavSub     := unset
; True once _PromptEdWeb_Reset() has torn the controller down. _PromptEdWeb_Close()
; (and therefore Reset()) is reachable from THREE independent triggers for the
; same window — the native Gui Close event, the frontend "cancel" message, and
; a successful "save" (_PromptEdWeb_Save closes through a context fence). A
; second pass's unsubscribe line calls remove_WebMessageReceived via ComCall
; against a CoreWebView2 pointer already invalidated by the first pass's
; Controller.Close() — a genuine SEH access violation no AHK try/catch can
; intercept (see personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the
; crash this mirrors). The flag makes the second call a true no-op instead.
global _PromptEdWeb_ResetDone  := false

; Open context captured at TryOpen time and consumed by the init push / save.
global _PromptEdWeb_IsEdit     := false
global _PromptEdWeb_EditId     := ""
global _PromptEdWeb_InitName   := ""
global _PromptEdWeb_InitPrompt := ""
global _PromptEdWeb_InitBatch  := false

; The active display context is a scalar pair. Deferred callbacks bind copies
; of both values instead of retaining a mutable Map or consulting the globals
; after yielding. The serial is never reset during process lifetime, so reopening
; the same profile cannot make an old callback current again.
global _PromptEdWeb_ContextEpoch := 0
global _PromptEdWeb_EpochSerial  := 0

; Injectable boundaries keep the scheduler race deterministic in the headless
; suite while production continues to use SetTimer, WebView2 and the real sinks.
global _PromptEdWeb_DeferHook   := 0
global _PromptEdWeb_EvalHook    := 0
global _PromptEdWeb_PersistHook := 0
global _PromptEdWeb_CloseHook   := 0

; Virtual host that maps to _SharedDir so the document and its relative assets
; (style.css, ../i18n.js) and the locale fetch all resolve over https.
global PROMPTED_VHOST             := "ergopti.prompteditor"
global PROMPTED_HOST_ACCESS_ALLOW := 1

; Window geometry — mirrors the macOS editor (550x480) with a little slack.
global PROMPTED_WIDTH  := 560
global PROMPTED_HEIGHT := 500

; Returns true when the WebView2 runtime binding + loader DLL are present.
_PromptEdWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Captures one immutable display identity and its initial form projection.
_PromptEdWeb_BeginContext(Existing) {
	global _PromptEdWeb_IsEdit, _PromptEdWeb_EditId
	global _PromptEdWeb_InitName, _PromptEdWeb_InitPrompt, _PromptEdWeb_InitBatch
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_EpochSerial

	IsEdit := IsObject(Existing)
	_PromptEdWeb_IsEdit     := IsEdit
	_PromptEdWeb_EditId     := (IsEdit && Existing.Has("id")) ? Existing["id"] : ""
	_PromptEdWeb_InitName   := (IsEdit && Existing.Has("label")) ? Existing["label"] : ""
	_PromptEdWeb_InitPrompt := (IsEdit && Existing.Has("system_single"))
		? Existing["system_single"]
		: t("prompt_editor.placeholder_prompt")
	_PromptEdWeb_InitBatch  := (IsEdit && Existing.Has("batch") && Existing["batch"] == true)

	_PromptEdWeb_EpochSerial += 1
	_PromptEdWeb_ContextEpoch := _PromptEdWeb_EpochSerial
	return { EditId: _PromptEdWeb_EditId, Epoch: _PromptEdWeb_ContextEpoch }
}

; Attempts to show the prompt editor in a WebView2 window. Returns true on success
; (the caller must NOT also build the native InputBox wizard), false to fall back.
; Existing is the user profile Map to edit, or 0 for a new profile.
_PromptEdWeb_TryOpen(Existing) {
	global _PromptEdWeb_Gui, _PromptEdWeb_Controller, _PromptEdWeb_WebView
	global _PromptEdWeb_MsgSub, _PromptEdWeb_NavSub, _PromptEdWeb_ResetDone, _VendorDir, _SharedDir
	global _PromptEdWeb_IsEdit, _PromptEdWeb_EditId
	global _PromptEdWeb_InitName, _PromptEdWeb_InitPrompt, _PromptEdWeb_InitBatch

	if !_PromptEdWeb_Available()
		return false

	; Capture the open context FIRST. This used to sit below the singleton
	; early-return, so re-opening the editor for a different profile while one was
	; already open kept the OLD _PromptEdWeb_EditId — the window merely gained
	; focus, still bound to the previous profile, and saving overwrote that one
	; with what the user believed were the new profile's edits. Silent because the
	; title bar was set at first open and never updated.
	; A new profile pre-fills the editor with the placeholder example (mirrors the
	; macOS host); an edit reads system_single.
	Context := _PromptEdWeb_BeginContext(Existing)

	; Singleton — re-point the existing editor at the newly captured context and
	; bring it to the front, rather than silently ignoring the new request.
	if (_PromptEdWeb_Gui != 0) {
		try LoggerDebug("PromptEditor", "Re-using open editor for profile '{1}' (edit={2}).",
			_PromptEdWeb_EditId, _PromptEdWeb_IsEdit ? "yes" : "no")
		try _PromptEdWeb_Gui.Title := _PromptEdWeb_IsEdit
			? t("prompt_editor.title_edit")
			: t("prompt_editor.title_new")
		try _PromptEdWeb_PushInit(Context.EditId, Context.Epoch)
		try WinActivate("ahk_id " . _PromptEdWeb_Gui.Hwnd)
		return true
	}

	g := Gui("+Resize +MinSize480x360", _PromptEdWeb_IsEdit ? t("prompt_editor.title_edit") : t("prompt_editor.title_new"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w" . PROMPTED_WIDTH . " h" . PROMPTED_HEIGHT, "")
	g.OnEvent("Close", _PromptEdWeb_OnClose)
	g.OnEvent("Size",  _PromptEdWeb_OnResize)

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w" . PROMPTED_WIDTH . " h" . PROMPTED_HEIGHT . " Center")
	_PromptEdWeb_Gui := g
	; Re-arm before create so its failure path can invalidate this context even
	; when the prior session left the idempotence flag set.
	_PromptEdWeb_ResetDone := false

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_PromptEdWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("PromptEditor", "WebView2 create failed: {1} — falling back to native wizard.", Err.Message)
		try g.Destroy()
		_PromptEdWeb_Reset()
		_PromptEdWeb_Gui := 0
		return false
	}

	_PromptEdWeb_WebView := _PromptEdWeb_Controller.CoreWebView2

	try {
		s := _PromptEdWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _PromptEdWeb_MsgSub := _PromptEdWeb_WebView.WebMessageReceived(_PromptEdWeb_OnWebMessage)
	global _PromptEdWeb_NavSub := _PromptEdWeb_WebView.NavigationCompleted(_PromptEdWeb_OnNavigationCompleted)

	; Map the virtual host BEFORE navigating; seed the i18n base + active locale
	; before page scripts run so the shared i18n.js fetches the right locale JSON.
	try _PromptEdWeb_WebView.SetVirtualHostNameToFolderMapping(PROMPTED_VHOST, _SharedDir, PROMPTED_HOST_ACCESS_ALLOW)
	try _PromptEdWeb_WebView.AddScriptToExecuteOnDocumentCreated(_PromptEdWeb_I18nSeed())
	try _PromptEdWeb_WebView.Navigate(_PromptEdWeb_HtmlUrl())
	try _PromptEdWeb_Controller.Fill()

	try LoggerSuccess("PromptEditor", "Prompt editor shown via WebView2 (edit={1}).", _PromptEdWeb_IsEdit)
	return true
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}. Work is
; deferred out of the COM callback (SetTimer -1) so persistence + window teardown
; never run re-entrantly inside the event callback.
_PromptEdWeb_OnWebMessage(Handler, Args) {
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
	_PromptEdWeb_HandlePayload(Payload, Action)
}

; Captures the page-owned scalar context before crossing the timer boundary.
_PromptEdWeb_HandlePayload(Payload, Action := "") {
	if (Action == "")
		Action := Payload.Has("action") ? Payload["action"] : ""
	if (Action != "cancel" && Action != "save")
		return

	if !_PromptEdWeb_ReadPayloadContext(Payload, &EditId, &Epoch) {
		try LoggerWarn("PromptEditor", "Ignoring '{1}' without a valid editor context.", Action)
		return
	}

	if (Action == "cancel") {
		_PromptEdWeb_Defer(_PromptEdWeb_CloseForContext.Bind(EditId, Epoch))
		return
	}

	if !_PromptEdWeb_ReadSavePayload(Payload, &Name, &Batch, &Prompt) {
		try LoggerWarn("PromptEditor", "Ignoring save with invalid scalar fields.")
		return
	}
	_PromptEdWeb_Defer(_PromptEdWeb_Save.Bind(EditId, Epoch, Name, Batch, Prompt))
}

; Push the init payload once the page has finished loading.
_PromptEdWeb_OnNavigationCompleted(Handler, Args) {
	global _PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch
	_PromptEdWeb_Defer(_PromptEdWeb_PushInit.Bind(
		_PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch))
}

; Build and push the init({...}) payload consumed by the frontend.
_PromptEdWeb_PushInit(EditId, Epoch) {
	global _PromptEdWeb_IsEdit, _PromptEdWeb_InitName, _PromptEdWeb_InitPrompt, _PromptEdWeb_InitBatch
	global _PromptEdWeb_ContextEpoch

	if !_PromptEdWeb_IsCurrentContext(EditId, Epoch) {
		try LoggerDebug("PromptEditor", "Discarding stale init for profile '{1}' (epoch={2}, current={3}).",
			EditId, Epoch, _PromptEdWeb_ContextEpoch)
		return false
	}

	Title := _PromptEdWeb_IsEdit ? t("prompt_editor.title_edit") : t("prompt_editor.title_new")
	Mode  := _PromptEdWeb_InitBatch ? "batch" : "parallel"
	Js := "if(window.init)window.init({"
		. _PromptEdWeb_Kv("edit_id", EditId) . ","
		. '"epoch":' . Epoch . ","
		. _PromptEdWeb_Kv("title", Title) . ","
		. _PromptEdWeb_Kv("name", _PromptEdWeb_InitName) . ","
		. _PromptEdWeb_Kv("mode", Mode) . ","
		. _PromptEdWeb_Kv("prompt", _PromptEdWeb_InitPrompt)
		. "})"
	_PromptEdWeb_Eval(Js)
	return true
}

; Persist the edited / created profile through the same path the native wizard
; used, then close. Maps the webview fields to the Windows profile shape
; (label, system_single, batch).
_PromptEdWeb_Save(EditId, Epoch, Name, Batch, Prompt) {
	global _PromptEdWeb_ContextEpoch
	if A_IsSuspended
		return false
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _PromptEdWeb_Save(EditId, Epoch, Name, Batch, Prompt)
		finally Critical(InheritedCritical)
	}

	if !_PromptEdWeb_IsCurrentContext(EditId, Epoch) {
		try LoggerDebug("PromptEditor", "Discarding stale save for profile '{1}' (epoch={2}, current={3}).",
			EditId, Epoch, _PromptEdWeb_ContextEpoch)
		return false
	}
	if !_PromptEdWeb_PersistProfile(EditId, Epoch, Name, Batch, Prompt)
		return false

	; Persistence may yield through file I/O and menu rebuilds. A profile switch
	; during that work must not let the old completion tear down the new editor.
	if !_PromptEdWeb_IsCurrentContext(EditId, Epoch) {
		try LoggerDebug("PromptEditor", "Profile '{1}' saved after its editor context advanced; leaving the newer editor open.",
			EditId)
		return true
	}

	return _PromptEdWeb_CloseForContext(EditId, Epoch)
}

; Applies form values to one detached menu candidate. The explicit target keeps
; nested profile Maps isolated until the strict writer has made them durable.
_PromptEdWeb_ApplyProfile(MenuState, EditId, Name, Batch, Prompt) {
	if !(MenuState is Map) || !MenuState.Has("user_profiles")
			|| !(MenuState["user_profiles"] is Array)
		return false
	if (EditId != "") {
		for i, p in MenuState["user_profiles"] {
			if (p.Has("id") && p["id"] == EditId) {
				MenuState["user_profiles"][i]["label"]         := Name
				MenuState["user_profiles"][i]["system_single"] := Prompt
				MenuState["user_profiles"][i]["batch"]         := Batch
				return true
			}
		}
		return false
	} else {
		pid := "user_" . LLM_Menu_Slugify(Name) . "_" . A_TickCount
		new_profile := Map(
			"id",            pid,
			"label",         Name,
			"system_single", Prompt,
			"system_multi",  "",
			"batch",         Batch
		)
		MenuState["user_profiles"].Push(new_profile)
		MenuState["profile_id"] := pid
	}
	return true
}

_PromptEdWeb_ApplyProfileForContext(MenuState, EditId, Epoch, Name, Batch,
		Prompt) {
	if A_IsSuspended or !_PromptEdWeb_IsCurrentContext(EditId, Epoch)
		return false
	return _PromptEdWeb_ApplyProfile(MenuState, EditId, Name, Batch, Prompt)
}

_PromptEdWeb_ApplyCommitted(*) {
	_LLM_Menu_ApplyStandardCommitted()
	return true
}

; Persists a detached context-bound candidate, then publishes it. The epoch is
; checked inside the mutation callback, after terminal acquisition and any WAL
; recovery, so a queued WebView callback cannot pass an early check and mutate
; a newer editor context while admission yields.
_PromptEdWeb_PersistProfile(EditId, Epoch, Name, Batch, Prompt) {
	global _PromptEdWeb_PersistHook, _LLM_Menu

	if IsObject(_PromptEdWeb_PersistHook) {
		; The hook represents the durable writer in behavioural tests. Preserve
		; production ordering: detached mutation -> strict durable result -> live
		; publication. A context repointed by the writer still keeps the accepted
		; disk mutation, but the caller's post-save fence leaves its editor open.
		CandidateMenu := LLM_Menu_DeepClone(_LLM_Menu)
		if !_PromptEdWeb_ApplyProfileForContext(CandidateMenu, EditId, Epoch,
				Name, Batch, Prompt)
			return false
		try Persisted := _PromptEdWeb_PersistHook(EditId, Name, Batch, Prompt)
		catch
			return false
		if !((Persisted is Integer) && Persisted == 1)
			return false
		PreviousCritical := Critical("On")
		try _LLM_Menu := CandidateMenu
		finally Critical(PreviousCritical)
		return true
	}

	return LLM_Menu_CommitMutation("the LLM prompt-editor profile save",
		(Candidate) => _PromptEdWeb_ApplyProfileForContext(Candidate,
			EditId, Epoch, Name, Batch, Prompt), _PromptEdWeb_ApplyCommitted)
}





; =====================================
; =====================================
; ======= 3/ Helpers / teardown =======
; =====================================
; =====================================

; Extracts the exact context pair emitted by the last accepted page init.
_PromptEdWeb_ReadPayloadContext(Payload, &EditId, &Epoch) {
	EditId := ""
	Epoch  := 0
	if !Payload.Has("edit_id") || !Payload.Has("epoch")
		return false

	CandidateId    := Payload["edit_id"]
	CandidateEpoch := Payload["epoch"]
	if !(CandidateId is String) || !(CandidateEpoch is Integer) || CandidateEpoch <= 0
		return false

	EditId := CandidateId
	Epoch  := CandidateEpoch
	return true
}

; Validates the scalar form contract before a COM message crosses the timer
; boundary. JsonParse represents JSON Booleans as Integer values, so only 0/1
; are accepted for batch; strings that merely look Boolean must never coerce.
_PromptEdWeb_ReadSavePayload(Payload, &Name, &Batch, &Prompt) {
	Name   := ""
	Batch  := false
	Prompt := ""
	if !Payload.Has("name") || !Payload.Has("batch") || !Payload.Has("prompt")
		return false

	CandidateName   := Payload["name"]
	CandidateBatch  := Payload["batch"]
	CandidatePrompt := Payload["prompt"]
	if !(CandidateName is String) || !(CandidateBatch is Integer)
			|| !(CandidatePrompt is String)
			|| (CandidateBatch != 0 && CandidateBatch != 1)
		return false

	Name   := Trim(CandidateName)
	Prompt := Trim(CandidatePrompt)
	if (Name == "" || Prompt == "")
		return false
	Batch := CandidateBatch == 1
	return true
}

; Tests both identity fields because the same profile may be reopened later.
_PromptEdWeb_IsCurrentContext(EditId, Epoch) {
	global _PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch
	return (EditId is String) && (Epoch is Integer) && Epoch > 0
		&& Epoch == _PromptEdWeb_ContextEpoch && EditId == _PromptEdWeb_EditId
}

; Defers work out of a WebView2 COM callback without hiding the scheduler seam.
_PromptEdWeb_Defer(Callback) {
	global _PromptEdWeb_DeferHook
	if IsObject(_PromptEdWeb_DeferHook) {
		_PromptEdWeb_DeferHook(Callback)
		return
	}
	SetTimer(Callback, -1)
}

; Builds one JSON key/value pair (key:"value") with the value safely escaped.
_PromptEdWeb_Kv(Key, Value) {
	return '"' . Key . '":' . _PromptEdWeb_JsStr(Value)
}

; Quoted, escaped JSON string literal for safe interpolation.
_PromptEdWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

; i18n seed injected before page scripts run: the locale base (served over the
; virtual host) and the active locale, consumed by the shared i18n.js.
_PromptEdWeb_I18nSeed() {
	global PROMPTED_VHOST, _I18nLocale
	loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
	return "window.__i18n_base='https://" . PROMPTED_VHOST . "/data/locales/';"
		. "window._i18n_locale='" . loc . "';"
}

; Virtual-host URL for the editor's index.html (served from _SharedDir via the
; vhost). A per-open cache-buster forces a fresh document each launch.
_PromptEdWeb_HtmlUrl() {
	global PROMPTED_VHOST
	return "https://" . PROMPTED_VHOST . "/ui/prompt_editor/index.html?cb=" . A_TickCount
}

; Fire-and-forget script eval. ExecuteScript().await() wedges the thread when
; called from inside a WebView2 callback, so never await here.
_PromptEdWeb_Eval(Js) {
	global _PromptEdWeb_WebView, _PromptEdWeb_EvalHook
	if IsObject(_PromptEdWeb_EvalHook) {
		_PromptEdWeb_EvalHook(Js)
		return true
	}
	if !IsSet(_PromptEdWeb_WebView)
		return false
	try _PromptEdWeb_WebView.ExecuteScriptAsync(Js)
	return true
}

_PromptEdWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _PromptEdWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_PromptEdWeb_Controller)
		try _PromptEdWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_PromptEdWeb_OnClose(*) {
	_PromptEdWeb_Close()
}

; Closes only when the deferred page action still owns the displayed context.
_PromptEdWeb_CloseForContext(EditId, Epoch) {
	global _PromptEdWeb_ContextEpoch, _PromptEdWeb_CloseHook
	if !_PromptEdWeb_IsCurrentContext(EditId, Epoch) {
		try LoggerDebug("PromptEditor", "Discarding stale close for profile '{1}' (epoch={2}, current={3}).",
			EditId, Epoch, _PromptEdWeb_ContextEpoch)
		return false
	}
	if IsObject(_PromptEdWeb_CloseHook) {
		_PromptEdWeb_CloseHook(EditId, Epoch)
		return true
	}
	_PromptEdWeb_Close()
	return true
}

_PromptEdWeb_Close() {
	global _PromptEdWeb_Gui
	saved := (_PromptEdWeb_Gui != 0) ? _PromptEdWeb_Gui : 0
	_PromptEdWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_PromptEdWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the native
; Close event firing after "save"/"cancel" already tore the same window down)
; is a true no-op instead of touching the globals again.
_PromptEdWeb_Reset() {
	global _PromptEdWeb_Controller, _PromptEdWeb_WebView, _PromptEdWeb_MsgSub, _PromptEdWeb_NavSub
	global _PromptEdWeb_ResetDone, _PromptEdWeb_EditId, _PromptEdWeb_ContextEpoch

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _PromptEdWeb_ResetDone
		return
	_PromptEdWeb_ResetDone := true
	; Invalidate before any COM teardown can yield so already-queued page actions
	; cannot become current after the window has gone away.
	_PromptEdWeb_EditId       := ""
	_PromptEdWeb_ContextEpoch := 0

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
		_PromptEdWeb_MsgSub := unset
		_PromptEdWeb_NavSub := unset
		if IsSet(_PromptEdWeb_Controller)
			_PromptEdWeb_Controller.Close()
	}
	_PromptEdWeb_Controller := unset
	_PromptEdWeb_WebView    := unset
}
