; modules/keystats/keystats_apps_editor.ahk

; ==============================================================================
; MODULE: App Metrics Category Editor
; DESCRIPTION:
; Defers native category prompts beyond WebView2 callbacks and commits only for
; the exact live document and metrics store. UI ports replace native boundaries;
; category snapshots, durable commits and fresh projections retain their owners.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =====================================
; =====================================
; ======= 1/ Document ownership =======
; =====================================
; =====================================

_KLWAE_Owns(Entry, Epoch, Request) {
	return !A_IsSuspended && KLWV_IsCurrent("apps", Epoch)
		&& KLWV.windows["apps"] == Entry
		&& Entry.Get("apps_editor_request", 0) == Request
		&& Request.Get("active", false)
		&& (!(Request.Get("receipt", 0) is Map)
			|| Request["receipt"].Get("state", "") != "retired")
		&& Entry.Get("webview", 0) == Request["webview"]
		&& Entry.Get("navigation_url", "") == Request["url"]
		&& Entry.Get("metrics_dir", "") == Request["root"]
}

; A retained controller can navigate without replacing its native object. Read
; its current URL too, and recheck RAM ownership after that COM call can yield.
_KLWAE_Current(Entry, Epoch, Request) {
	if !_KLWAE_Owns(Entry, Epoch, Request)
		return false
	try Source := Request["webview"].Source
	catch as Err {
		try LoggerWarn("Keystats", "Apps editor could not verify its document: {1}.", Err.Message)
		return false
	}
	return Source == Request["url"] && _KLWAE_Owns(Entry, Epoch, Request)
}

_KLWAE_Port(Request, Name, Default) {
	Ports := Request["ports"]
	if !Ports.Has(Name)
		return Default
	if !HasMethod(Ports[Name], "Call")
		throw TypeError("Apps editor UI ports must be callable.")
	return Ports[Name]
}

_KLWAE_Retire(Entry, Request) {
	PreviousCritical := Critical("On")
	try {
		Request["active"] := false
		if Entry.Get("apps_editor_request", 0) == Request
			Entry.Delete("apps_editor_request")
		Callback := Request.Get("timer", 0)
		if Request.Has("timer")
			Request.Delete("timer")
		NativeGui := Request.Get("native_gui", 0)
		if Request.Has("native_gui")
			Request.Delete("native_gui")
		Receipt := Request.Get("receipt", 0)
		if Request.Has("receipt")
			Request.Delete("receipt")
	} finally Critical(PreviousCritical)
	try {
		if HasMethod(Callback, "Call")
			_KLWAE_Port(Request, "defer", TimerSetCallback).Call(Callback, 0)
	} finally {
		try {
			if Receipt is Map
				AppPicker_RetireReceipt(Receipt)
		} finally {
			if NativeGui is Gui
				NativeGui.Destroy()
		}
	}
}

/** Revokes deferred prompts before releasing or retaining a dashboard host. */
KLWV_RetireAppsEditor(Entry) {
	Request := Entry.Get("apps_editor_request", 0)
	if Request is Map
		_KLWAE_Retire(Entry, Request)
}





; ===================================
; ===================================
; ======= 2/ Bridge admission =======
; ===================================
; ===================================

/** Queues an accepted apps-page command without blocking WebMessageReceived. */
KLWV_QueueAppsEditor(Entry, Epoch, Message) {
	try Payload := JsonParse(Message)
	catch as Err {
		try LoggerWarn("Keystats", "Apps editor rejected malformed JSON: {1}.", Err.Message)
		return false
	}
	if !(Payload is Map)
		return false
	Action := Payload.Get("action", "")
	if !(Action is String) || !(Action == "pick" || Action == "edit")
		return false
	App := Payload.Get("app", "")
	if Action == "edit" && (!(App is String) || Trim(App) == "")
		return false
	Root := Entry.Get("metrics_dir", "")
	Url := Entry.Get("navigation_url", "")
	if !(Root is String) || Root == "" || !(Url is String) || Url == ""
		return false
	Ports := Entry.Get("apps_editor_ports", Map())
	if !(Ports is Map)
		throw TypeError("Apps editor UI ports must be a Map.")
	Request := Map("active", true, "action", Action, "app", App,
		"root", Root, "url", Url, "webview", Entry.Get("webview", 0),
		"ports", Ports.Clone())
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || !KLWV_IsCurrent("apps", Epoch)
				|| KLWV.windows["apps"] != Entry
			return false
		Previous := Entry.Get("apps_editor_request", 0)
		Entry["apps_editor_request"] := Request
	} finally Critical(PreviousCritical)
	if Previous is Map
		_KLWAE_Retire(Entry, Previous)
	if !_KLWAE_Current(Entry, Epoch, Request) {
		_KLWAE_Retire(Entry, Request)
		return false
	}
	Callback := _KLWAE_Run.Bind(Entry, Epoch, Request)
	Request["timer"] := Callback
	try _KLWAE_Port(Request, "defer", TimerSetCallback).Call(Callback, -1)
	catch as Err {
		_KLWAE_Retire(Entry, Request)
		try LoggerError("Keystats", "Apps editor could not defer its command: {1}.", Err.Message)
		return false
	}
	return true
}

_KLWAE_Run(Entry, Epoch, Request) {
	if Request.Has("timer")
		Request.Delete("timer")
	Waiting := false
	try {
		if !_KLWAE_Current(Entry, Epoch, Request)
			return false
		if Request["action"] == "edit"
			return _KLWAE_EditAndRefresh(Entry, Epoch, Request, Request["app"])
		Store := KL_AppCat_EditorStoreSnapshot(Request["root"])
		if !(Store is Map) || !_KLWAE_Current(Entry, Epoch, Request)
			return false
		Options := Map("owner", "metrics:app-categories",
			"title", t("metrics_apps.window_title"),
			"prompt", t("metrics_apps.pick_app_placeholder"), "initial", [],
			"on_save", _KLWAE_Picked.Bind(Entry, Epoch, Request),
			"on_open", _KLWAE_TrackPicker.Bind(Entry, Epoch, Request))
		if !_KLWAE_Current(Entry, Epoch, Request)
			return false
		Receipt := _KLWAE_Port(Request, "picker", AppPicker_Show).Call(Options)
		if !_KLWAE_Current(Entry, Epoch, Request) {
			if Receipt is Map
				AppPicker_RetireReceipt(Receipt)
			return false
		}
		if !(Receipt is Map)
			return false
		Request["receipt"] := Receipt
		Waiting := Receipt.Get("state", "") == "open"
		return Waiting
	} catch as Err {
		try LoggerError("Keystats", "Apps editor failed: {1}.", Err.Message)
		return false
	} finally {
		if !Waiting
			_KLWAE_Retire(Entry, Request)
	}
}





; ===========================================
; ===========================================
; ======= 3/ Confirmed native choices =======
; ===========================================
; ===========================================

; Payload category and score are display data, never authority to write. The
; native snapshot supplies defaults without discovering an app or scheduling a
; save. Both confirmations must complete before the durable backend is called.
_KLWAE_Confirm(Entry, Epoch, Request, App) {
	if !_KLWAE_Current(Entry, Epoch, Request)
		return false
	Snapshot := KL_AppCat_EditorSnapshot(App, Request["root"])
	if !(Snapshot is Map) || !_KLWAE_Current(Entry, Epoch, Request)
		return false
	Input := _KLWAE_Port(Request, "input", _KLWAE_NativeInput.Bind(Entry, Epoch, Request))
	Choice := Input.Call(StrReplace(t("metrics_apps.chooser_placeholder"), "%s", App),
		t("metrics_apps.window_title"), "", Snapshot["current_type"])
	if !_KLWAE_Current(Entry, Epoch, Request) || Choice.Result != "OK"
		return false
	if !(Choice.Value is String) || Trim(Choice.Value) == ""
		return false
	Category := Choice.Value
	ScoreChoice := Input.Call(StrReplace(t("metrics_apps.score_prompt"), "%s", App),
		t("metrics_apps.score_title"), "", String(Snapshot["current_score"]))
	if !_KLWAE_Current(Entry, Epoch, Request) || ScoreChoice.Result != "OK"
		return false
	if !(ScoreChoice.Value is String) || !IsNumber(ScoreChoice.Value)
			|| !(Number(ScoreChoice.Value) >= -2 && Number(ScoreChoice.Value) <= 2) {
		_KLWAE_Port(Request, "message", _KLWAE_NativeMessage.Bind(Entry, Epoch, Request)).Call(t("metrics_apps.score_error"),
			t("common.warning"), "Icon!")
		return false
	}
	Score := Number(ScoreChoice.Value)
	if !_KLWAE_Current(Entry, Epoch, Request)
		return false
	return KL_AppCat_CommitEdit(Snapshot, Category, Score,
		_KLWAE_Current.Bind(Entry, Epoch, Request),
		_KLWAE_Owns.Bind(Entry, Epoch, Request)) == 1
}

_KLWAE_Refresh(Entry, Epoch, Request) {
	if !_KLWAE_Current(Entry, Epoch, Request)
		return false
	PreviousCritical := Critical("On")
	try {
		if !_KLWAE_Owns(Entry, Epoch, Request)
			return false
		; The old full image predates this durable edit. Its successful paint
		; cannot suppress recovery if the replacement worker or delivery fails.
		Entry["full_build_done"] := false
		KLWV_ClaimFullBuild(Entry)
	} finally Critical(PreviousCritical)
	if !_KLWAE_Current(Entry, Epoch, Request)
		return false
	return KLPF_RequestBuild("apps", Request["root"], "full", Epoch,
		KLWV_OnFullBuildTerminal.Bind("apps", Epoch, 0))
}

_KLWAE_EditAndRefresh(Entry, Epoch, Request, App) {
	if !_KLWAE_Confirm(Entry, Epoch, Request, App)
		return false
	; A saved category remains durable if the page closes during the refresh.
	; Only a current page can launch or receive the corresponding projection.
	return _KLWAE_Refresh(Entry, Epoch, Request)
}

_KLWAE_Picked(Entry, Epoch, Request, Selected, Receipt) {
	Changed := false
	try {
		if !_KLWAE_Current(Entry, Epoch, Request) || !(Selected is Array)
			return false
		if Request.Has("receipt") && Request["receipt"] != Receipt
			return false
		if !AppPicker_ClaimReceipt(Receipt, [])
			return false
		for App in Selected {
			if !(App is String) || Trim(App) == ""
				return false
			if !_KLWAE_Confirm(Entry, Epoch, Request, App)
				break
			Changed := true
		}
		return Changed
	} catch as Err {
		try LoggerError("Keystats", "Apps editor selection failed: {1}.", Err.Message)
		return false
	} finally {
		try {
			if Changed
				_KLWAE_Refresh(Entry, Epoch, Request)
		} finally _KLWAE_Retire(Entry, Request)
	}
}





; =======================================
; =======================================
; ======= 4/ Owned native dialogs =======
; =======================================
; =======================================

_KLWAE_TrackPicker(Entry, Epoch, Request, NativeGui, Receipt) {
	if !(NativeGui is Gui) || !(Receipt is Map)
		throw TypeError("Apps editor requires the actual picker GUI and receipt.")
	if !_KLWAE_Current(Entry, Epoch, Request)
		return false
	PreviousCritical := Critical("On")
	try {
		if !_KLWAE_Owns(Entry, Epoch, Request)
			return false
		Request["native_gui"] := NativeGui
		Request["receipt"] := Receipt
	} finally Critical(PreviousCritical)
	return _KLWAE_Current(Entry, Epoch, Request)
}

_KLWAE_NativeInput(Entry, Epoch, Request, Prompt, Title, Options, Default) {
	if Options != ""
		throw ValueError("The apps editor input has no native option overrides.")
	return _KLWAE_NativeDialog(Entry, Epoch, Request, Prompt, Title, Default)
}

_KLWAE_NativeMessage(Entry, Epoch, Request, Text, Title, Options) {
	if Options != "Icon!"
		throw ValueError("The apps editor warning has no native option overrides.")
	return _KLWAE_NativeDialog(Entry, Epoch, Request, Text, Title).Result
}

_KLWAE_Choose(Entry, Epoch, Request, NativeGui, Edit, Result, Accept, *) {
	Value := ""
	if IsObject(Edit) && _KLWAE_Owns(Entry, Epoch, Request) {
		try Value := Edit.Value
		catch as Err {
			if _KLWAE_Owns(Entry, Epoch, Request)
				throw Err
		}
	}
	Result.Value := Value
	Result.Result := Accept && _KLWAE_Owns(Entry, Epoch, Request) ? "OK" : "Cancel"
	Result.Done := true
	NativeGui.Destroy()
	return true
}

; Native InputBox exposes no dialog identity to its caller while it is open.
; This small native GUI retains the same Result/Value boundary while allowing
; Close/Hide to destroy the exact request-owned editor before any late save.
_KLWAE_NativeDialog(Entry, Epoch, Request, Prompt, Title, Default := unset) {
	Result := { Result: "Cancel", Value: "", Done: false }
	if !_KLWAE_Current(Entry, Epoch, Request)
		return Result
	NativeGui := 0
	try {
		NativeGui := Gui_Create("+Owner" . Entry["gui"].Hwnd, Title)
		PreviousCritical := Critical("On")
		try {
			if !_KLWAE_Owns(Entry, Epoch, Request)
				return Result
			Request["native_gui"] := NativeGui
		} finally Critical(PreviousCritical)
		NativeGui.SetFont("s10")
		NativeGui.AddText("w420", Prompt)
		Edit := IsSet(Default) ? NativeGui.AddEdit("w420", Default) : 0
		Accept := NativeGui.AddButton("w90 Default", t("button.ok"))
		Buttons := [Accept]
		if IsSet(Default) {
			Cancel := NativeGui.AddButton("x+8 w90", t("common.cancel"))
			Buttons.Push(Cancel)
			Cancel.OnEvent("Click", _KLWAE_Choose.Bind(Entry, Epoch, Request,
				NativeGui, Edit, Result, false))
		}
		Gui_HarmoniseButtonWidths(Buttons)
		Accept.OnEvent("Click", _KLWAE_Choose.Bind(Entry, Epoch, Request,
			NativeGui, Edit, Result, true))
		CancelFn := _KLWAE_Choose.Bind(Entry, Epoch, Request, NativeGui, Edit, Result, false)
		NativeGui.OnEvent("Close", CancelFn)
		NativeGui.OnEvent("Escape", CancelFn)
		if !_KLWAE_Current(Entry, Epoch, Request)
			return Result
		Hwnd := NativeGui.Hwnd
		NativeGui.Show("AutoSize Center")
		if !Result.Done && _KLWAE_Owns(Entry, Epoch, Request) {
			WaitCritical := Critical("Off")
			try WinWaitClose("ahk_id " . Hwnd)
			finally Critical(WaitCritical)
		}
		return Result
	} catch as Err {
		if _KLWAE_Owns(Entry, Epoch, Request)
			throw Err
		return Result
	} finally {
		if NativeGui is Gui {
			if Request.Get("native_gui", 0) == NativeGui
				Request.Delete("native_gui")
			NativeGui.Destroy()
		}
	}
}
