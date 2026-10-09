; ui/action_picker_webview.ahk

; ==============================================================================
; MODULE: Action Picker WebView2 Host
; DESCRIPTION:
; Renders the action chooser on Windows via WebView2, loading the shared frontend
; at _shared/ui/action_picker/ so the AHK and Hammerspoon drivers show an
; identical searchable, categorised picker. Backs ShowActionPicker
; (ui/action_picker/init.ahk), whose native ListBox remains as a fallback.
; fallback when the WebView2 runtime is unavailable.
;
; FEATURES & RATIONALE:
; 1. Shared frontend — same index.html/script.js/style.css as macOS, resolved
;    through a virtual-host mapping over _SharedDir (file:// is an opaque origin
;    that breaks the JS->AHK channel, so the document is served over https).
; 2. Caller-agnostic — _ActPickWeb_TryOpen takes a pre-built action list
;    ({Id,Label,Cat}) + the OnConfirm callback that every ShowActionPicker call
;    site already supplies; the synthetic "native" pick maps back to "" exactly
;    like the native dialog did.
; 3. Safe teardown — subscription handles are released BEFORE Controller.Close()
;    (their __Delete unsubscribes on the live controller; reversing the order
;    raises a COM error that, uncaught in the Close thread, quits the script).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Lifecycle / open =======
; ===================================
; ===================================

; Singleton window + WebView2 plumbing. Subscription handles live in globals so
; the binding does not GC them; they are released BEFORE Controller.Close() in
; _ActPickWeb_Reset.
global _ActPickWeb_Gui        := 0
global _ActPickWeb_Controller := unset
global _ActPickWeb_WebView    := unset
global _ActPickWeb_MsgSub     := unset
global _ActPickWeb_NavSub     := unset
; True once _ActPickWeb_Reset() has torn the controller down. _ActPickWeb_Close()
; (and therefore Reset()) is reachable from THREE independent triggers for the
; same window — the native Gui Close event, the frontend "cancel" message, and
; the frontend "confirm" message (_ActPickWeb_Confirm) — plus a re-open of the
; singleton while one is already showing (_ActPickWeb_TryOpen). A second pass's
; unsubscribe line calls remove_WebMessageReceived via ComCall against a
; CoreWebView2 pointer already invalidated by the first pass's
; Controller.Close() — a genuine SEH access violation no AHK try/catch can
; intercept (see personal_toml_editor_webview.ahk _HsEdWeb_ResetDone for the
; crash this mirrors). The flag makes the second call a true no-op instead.
global _ActPickWeb_ResetDone  := false
global _ActPickWeb_SessionEpoch := 0
global _ActPickWeb_ProgramOwner := 0
global _ActPickWeb_ProgramPacket := Map("unavailable", true)
global _ActPickWeb_ProgramDebt := []
global _ActPickWeb_ProgramCapturing := false
global _ActPickWeb_ProgramRetiring := false
global _ActPickWeb_Confirming := false

; The chosen-action callback + the init payload captured at open time.
global _ActPickWeb_OnConfirm  := 0
global _ActPickWeb_InitJs     := ""

; Virtual host that maps to _SharedDir so the document and its relative assets
; (style.css, ../i18n.js) and the locale fetch all resolve over https.
global ACTPICK_VHOST             := "ergopti.actionpicker"
global ACTPICK_HOST_ACCESS_ALLOW := 1

; Window geometry — mirrors the macOS picker panel.
global ACTPICK_WIDTH  := 460
global ACTPICK_HEIGHT := 560

; Returns true when the WebView2 runtime binding + loader DLL are present.
_ActPickWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the action picker in a WebView2 window. Returns true on success
; (the caller must NOT also build the native ListBox), false to fall back.
; Items is an ordered array of headings ({ Type:"heading", Level, Text }) and
; actions ({ Type:"action", Id, Label }); Current is the assigned id ("" means the
; synthetic native pick); OnConfirm(id) is invoked with the chosen id.
_ActPickWeb_TryOpen(Title, Current, Items, OnConfirm, ShowNative := false, BindingId := "") {
	global _ActPickWeb_Gui, _ActPickWeb_Controller, _ActPickWeb_WebView
	global _ActPickWeb_MsgSub, _ActPickWeb_NavSub, _ActPickWeb_OnConfirm, _ActPickWeb_InitJs
	global _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch
	global _VendorDir, _SharedDir

	if !_ActPickWeb_Available()
		return false

	; Singleton — a second open replaces the previous picker (its callback is
	; superseded), matching the native dialog which only ever shows one.
	if (_ActPickWeb_Gui != 0)
		_ActPickWeb_Close()
	_ActPickWeb_SessionEpoch += 1
	SessionEpoch := _ActPickWeb_SessionEpoch
	_ActPickWeb_ResetDone := false

	_ActPickWeb_OnConfirm := OnConfirm
	_ActPickWeb_ProgramCapture()
	_ActPickWeb_InitJs    := _ActPickWeb_BuildInitJs(Title, Current, Items, ShowNative, BindingId)

	g := Gui_Create("+Resize +MinSize360x360", Title)
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w" . ACTPICK_WIDTH . " h" . ACTPICK_HEIGHT, "")
	g.OnEvent("Close", _ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_OnClose))
	g.OnEvent("Size",  _ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_OnResize))

	; Show BEFORE creating the control — a hidden Gui has a zero client rect, so
	; the control lays out blank and never recovers.
	g.Show("w" . ACTPICK_WIDTH . " h" . ACTPICK_HEIGHT . " Center")
	_ActPickWeb_Gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_ActPickWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("ActionPicker", "WebView2 create failed: {1} — falling back to native dialog.", Err.Message)
		try g.Destroy()
		_ActPickWeb_Reset()
		_ActPickWeb_Gui := 0
		return false
	}

	_ActPickWeb_WebView := _ActPickWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _ActPickWeb_Reset() call.

	try {
		s := _ActPickWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; Store the subscription handles in persistent globals (see header note).
	global _ActPickWeb_MsgSub := _ActPickWeb_WebView.WebMessageReceived(_ActPickWeb_OnWebMessage.Bind(SessionEpoch))
	global _ActPickWeb_NavSub := _ActPickWeb_WebView.NavigationCompleted(_ActPickWeb_OnNavigationCompleted.Bind(SessionEpoch))

	; Map the virtual host BEFORE navigating; seed the i18n base + active locale
	; before page scripts run so the shared i18n.js fetches the right locale JSON.
	try _ActPickWeb_WebView.SetVirtualHostNameToFolderMapping(ACTPICK_VHOST, _SharedDir, ACTPICK_HOST_ACCESS_ALLOW)
	try _ActPickWeb_WebView.AddScriptToExecuteOnDocumentCreated(_ActPickWeb_I18nSeed())
	try _ActPickWeb_WebView.Navigate(_ActPickWeb_HtmlUrl())
	try _ActPickWeb_Controller.Fill()

	try LoggerSuccess("ActionPicker", "Action picker shown via WebView2 ({1} item(s)).", Items.Length)
	return true
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 channel, so each message is an object {action, …}. Work is
; deferred out of the COM callback (SetTimer -1) so the callback + window teardown
; never run re-entrantly inside the event callback.
_ActPickWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	if !_ActPickWeb_SessionCurrent(SessionEpoch)
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
		SetTimer(_ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_PushInit), -1)
	} else if (Action == "cancel") {
		SetTimer(_ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_Close), -1)
	} else if (Action == "confirm") {
		Id := Payload.Has("id") ? Payload["id"] : ""
		; A send_* value the page's own editor collected travels with the pick.
		HasParameter := Payload.Has("parameter") && (Payload["parameter"] is String)
		Parameter := HasParameter ? Payload["parameter"] : ""
		HasProvider := Payload.Has("providerKey")
		Provider := HasProvider ? ProgramProviderMessage(Msg) : false
		SetTimer(_ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_Confirm,
			Id, HasParameter, Parameter, HasProvider, Provider), -1)
	}
}

; Push the init payload once the page has finished loading.
_ActPickWeb_OnNavigationCompleted(SessionEpoch, Handler, Args) {
	SetTimer(_ActPickWeb_SessionCall.Bind(SessionEpoch, _ActPickWeb_PushInit), -1)
}

_ActPickWeb_SessionCurrent(SessionEpoch) {
	global _ActPickWeb_SessionEpoch
	return SessionEpoch == _ActPickWeb_SessionEpoch
}

_ActPickWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_ActPickWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}

_ActPickWeb_PushInit() {
	global _ActPickWeb_InitJs
	_ActPickWeb_Eval(_ActPickWeb_InitJs)
}

; Apply the chosen action: map the synthetic native pick back to "" (as the
; native dialog did), close the window, then invoke the caller's callback.
; A value the page's editor collected is offered to the parameter prompt the
; callback's assignment runs, for this action only, and withdrawn afterwards.
_ActPickWeb_Confirm(Id, HasParameter := false, Parameter := "", HasProvider := false, Provider := false) {
	global _ActPickWeb_OnConfirm, _ActPickWeb_ProgramOwner, _ActPickWeb_SessionEpoch
	global _ActPickWeb_Confirming, _ActPickWeb_ResetDone
	if A_IsSuspended || _ActPickWeb_Confirming
		return false
	_ActPickWeb_Confirming := true
	Epoch := _ActPickWeb_SessionEpoch
	try {
		if HasProvider {
			Owner := _ActPickWeb_ProgramOwner
			if Id != "run_program" || !(Provider is Map) || !(Owner is ProgramProviderSession)
				return false
			Resolved := Owner.Resolve(Provider["key"], Provider["arguments"])
			if !(Resolved is String) || A_IsSuspended || !_ActPickWeb_SessionCurrent(Epoch)
					|| _ActPickWeb_ProgramOwner != Owner {
				if _ActPickWeb_SessionCurrent(Epoch)
					_ActPickWeb_Eval("if(window.programProviderRefused)window.programProviderRefused()")
				return false
			}
			HasParameter := true
			Parameter := Resolved
		}
		; Manual and ordinary picks also retire discovery before assigning anything.
		; Refusal still closes this session; it cannot lend its callback to a new one.
		cb := _ActPickWeb_OnConfirm
		Retired := _ActPickWeb_ProgramRetire()
		if !_ActPickWeb_SessionCurrent(Epoch)
			return false
		Mapped := (Id == "__native__") ? "" : Id
		_ActPickWeb_Close()
		if !Retired || A_IsSuspended || !_ActPickWeb_ResetDone
				|| _ActPickWeb_SessionEpoch != Epoch + 1
			return false
		if (cb == 0 || cb == "")
			return false
		if HasParameter
			GestureOfferPickedParameter(Mapped, Parameter)
		try cb(Mapped)
		finally GestureClearPickedParameter()
		return true
	} catch Any {
		return false
	} finally _ActPickWeb_Confirming := false
}





; ===================================
; ===================================
; ======= 3/ initData builder =======
; ===================================
; ===================================

; Build the `init({...})` call string consumed by the frontend.
_ActPickWeb_BuildInitJs(Title, Current, Items, ShowNative, BindingId := "") {
	ItemsJson := ""
	for _, It in Items {
		if (ItemsJson != "")
			ItemsJson .= ","
		if (It.Type == "heading") {
			ItemsJson .= "{"
				. _ActPickWeb_Kv("type", "heading") . ","
				. '"level":' . It.Level . ","
				. _ActPickWeb_Kv("text", It.Text)
				. "}"
		} else {
			; Every parameterized action carries its kind and the value the binding
			; holds: the page edits text/key/shortcut/llm_prompt itself, and its
			; "edit the current action" button reopens any of them. Other kinds
			; confirm without a value, and the native prompt asks for it.
			Kind := GestureActionParameterSpec(It.Id)
			DisabledProgram := Kind == "program" && (!IsSet(ProgramActions_Available) || !IsSet(ProgramActions_BindingSupported)
				|| !ProgramActions_Available() || !ProgramActions_BindingSupported(BindingId))
			Parameter := (Kind != "")
				? "," . _ActPickWeb_Kv("parameter", Kind) . "," . _ActPickWeb_Kv("parameterValue",
					(BindingId = "") ? "" : GestureGetActionParameter(BindingId, It.Id))
				: ""
			ItemsJson .= "{"
				. _ActPickWeb_Kv("type", "action") . ","
				. _ActPickWeb_Kv("id", It.Id) . ","
				. _ActPickWeb_Kv("label", It.Label)
				. Parameter
				. (DisabledProgram ? ',"disabled":true,"hint":' . JsonStringLiteral(t("platform_reason.program_runner_unavailable")) : "")
				. "}"
		}
	}

	Json := "{"
		. _ActPickWeb_Kv("title", Title) . ","
		. _ActPickWeb_Kv("label", t("dialog.action_picker.label")) . ","
		. _ActPickWeb_Kv("current", Current) . ","
		. '"allowNative":' . (ShowNative ? "true" : "false") . ","
		. _ActPickWeb_Kv("nativeLabel", t("tap_hold.tap.none")) . ","
		. _ActPickWeb_Kv("noneLabel", t("dialog.action_picker.disabled")) . ","
		. _ActPickWeb_Kv("searchPlaceholder", t("dialog.action_picker.search")) . ","
		. _ActPickWeb_Kv("noResults", t("dialog.action_picker.no_results")) . ","
		. _ActPickWeb_Kv("cancelLabel", t("button.cancel")) . ","
		. _ActPickWeb_Kv("platform", "ahk") . ","
		. '"sendVocabulary":' . SendInputVocabularyJson() . ","
		. '"parameterStrings":' . _ActPickWeb_ParameterStringsJson() . ","
		. '"programProviders":' . _ActPickWeb_ProgramPacketJson() . ","
		. '"programProviderStrings":{'
		. _ActPickWeb_Kv("label", t("dialog.action_picker.program_provider_label")) . ","
		. _ActPickWeb_Kv("manual", t("dialog.action_picker.program_provider_manual")) . ","
		. _ActPickWeb_Kv("hint", t("dialog.action_picker.program_provider_hint")) . ","
		. _ActPickWeb_Kv("unavailable", t("dialog.action_picker.program_provider_unavailable")) . ","
		. _ActPickWeb_Kv("changed", t("dialog.action_picker.program_provider_changed")) . ","
		. _ActPickWeb_Kv("empty", t("dialog.action_picker.program_provider_empty")) . ","
		. _ActPickWeb_Kv("truncated", t("dialog.action_picker.program_provider_truncated")) . "},"
		. '"promptChoices":' . _ActPickWeb_PromptChoicesJson() . ","
		. '"visionChoices":' . _ActPickWeb_VisionChoicesJson() . ","
		. '"languageChoices":' . _ActPickWeb_LanguageChoicesJson() . ","
		. '"defaultCount":' . _ActPickWeb_DefaultCount() . ","
		. _ActPickWeb_Kv("editCurrentLabel", t("dialog.action_picker.edit_current")) . ","
		. '"items":[' . ItemsJson . "]"
		. "}"

	return "if(window.init)window.init(" . Json . ")"
}





; =====================================
; =====================================
; ======= 4/ Helpers / teardown =======
; =====================================
; =====================================

; The editor's localized strings: its buttons, its capture hints, and each
; kind's prompt and refusal, the same texts the native prompt shows.
; countDefault and visionModelDefault stay raw, with their {1}: the page puts
; the menu's count, or the backend's default model, in it.
_ActPickWeb_ParameterStringsJson() {
	Prompts := ""
	Errors := ""
	for _, Pair in [["text", "send_text"], ["key", "send_key"], ["shortcut", "send_shortcut"]] {
		Prompts .= (Prompts = "" ? "" : ",") . _ActPickWeb_Kv(Pair[1], GestureActionParameterPrompt(Pair[2]))
		Errors .= (Errors = "" ? "" : ",") . _ActPickWeb_Kv(Pair[1], GestureSendInputErrorText(Pair[1]))
	}
	Prompts .= "," . _ActPickWeb_Kv("llm_prompt", GestureActionParameterPrompt("llm_prompt_prediction"))
	Errors .= "," . _ActPickWeb_Kv("llm_prompt", t("dialog.gestures.param_err_llm_prompt"))
	; Every screen action shares the kind, and so its prompt
	Prompts .= "," . _ActPickWeb_Kv("llm_vision", GestureActionParameterPrompt("llm_screen_region"))
	Errors .= "," . _ActPickWeb_Kv("llm_vision", t("dialog.gestures.param_err_llm_vision"))
	Prompts .= "," . _ActPickWeb_Kv("llm_language", GestureActionParameterPrompt("llm_translate_selection"))
	Errors .= "," . _ActPickWeb_Kv("llm_language", t("dialog.gestures.param_err_llm_language"))
	Prompts .= "," . _ActPickWeb_Kv("program", t("dialog.gestures.param_program"))
	Errors .= "," . _ActPickWeb_Kv("program", t("dialog.gestures.param_err_program"))
	return "{"
		. _ActPickWeb_Kv("save", t("button.save")) . ","
		. _ActPickWeb_Kv("back", t("dialog.action_picker.back")) . ","
		. _ActPickWeb_Kv("captureKey", t("dialog.action_picker.capture_key")) . ","
		. _ActPickWeb_Kv("captureShortcut", t("dialog.action_picker.capture_shortcut")) . ","
		. _ActPickWeb_Kv("promptLabel", t("dialog.action_picker.prompt_label")) . ","
		. _ActPickWeb_Kv("countLabel", t("dialog.action_picker.count_label")) . ","
		. _ActPickWeb_Kv("countDefault", t("dialog.action_picker.count_default")) . ","
		. _ActPickWeb_Kv("visionProviderLabel", t("dialog.action_picker.vision_provider_label")) . ","
		. _ActPickWeb_Kv("visionModelLabel", t("dialog.action_picker.vision_model_label")) . ","
		. _ActPickWeb_Kv("visionModelDefault", t("dialog.action_picker.vision_model_default")) . ","
		. _ActPickWeb_Kv("visionModelRequired", t("dialog.action_picker.vision_model_required")) . ","
		. _ActPickWeb_Kv("languageLabel", t("dialog.action_picker.language_label")) . ","
		. _ActPickWeb_Kv("programExecutableLabel", t("dialog.action_picker.program_executable")) . ","
		. _ActPickWeb_Kv("programArgumentsLabel", t("dialog.action_picker.program_arguments")) . ","
		. _ActPickWeb_Kv("programAddLabel", t("dialog.action_picker.program_add_argument")) . ","
		. _ActPickWeb_Kv("programRemoveLabel", t("dialog.action_picker.program_remove_argument")) . ","
		. '"prompts":{' . Prompts . '},"errors":{' . Errors . "}}"
}

; The prompts a llm_prompt value may name, built-ins in menu order then the
; user's custom ones, each with the label the AI menu shows.
_ActPickWeb_PromptChoicesJson() {
	Json := ""
	for Choice in LLM_Menu_PromptChoices()
		Json .= (Json = "" ? "" : ",") . "{"
			. _ActPickWeb_Kv("value", Choice["value"]) . ","
			. _ActPickWeb_Kv("label", Choice["label"]) . "}"
	return "[" . Json . "]"
}

; The vision backends a llm_vision value may name, with the vision model each
; uses when the value names none ("" when the value must name one).
_ActPickWeb_VisionChoicesJson() {
	Json := ""
	for Choice in LLM_Vision_BackendChoices()
		Json .= (Json = "" ? "" : ",") . "{"
			. _ActPickWeb_Kv("value", Choice["value"]) . ","
			. _ActPickWeb_Kv("label", Choice["label"]) . ","
			. _ActPickWeb_Kv("defaultModel", Choice["defaultModel"]) . "}"
	return "[" . Json . "]"
}

; The target languages a llm_language value may name: the interface language,
; then every shipped locale, as the native prompt lists them.
_ActPickWeb_LanguageChoicesJson() {
	Json := ""
	for Choice in LLM_Translate_ShippedChoices()
		Json .= (Json = "" ? "" : ",") . "{"
			. _ActPickWeb_Kv("value", Choice["value"]) . ","
			. _ActPickWeb_Kv("label", Choice["label"]) . "}"
	return "[" . Json . "]"
}

; The AI menu's prediction count, which a value without a count of its own uses.
_ActPickWeb_DefaultCount() {
	global _LLM_Menu
	Count := _LLM_Menu["n_predictions"]
	if !IsInteger(Count)
		throw TypeError("The AI menu's prediction count must be an integer, got " . Type(Count) . ".")
	return String(Integer(Count))
}

; Builds one JSON key/value pair (key:"value") with the value safely escaped.
_ActPickWeb_Kv(Key, Value) {
	return '"' . Key . '":' . _ActPickWeb_JsStr(Value)
}

; Quoted, escaped JSON string literal for safe interpolation.
_ActPickWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

; i18n seed injected before page scripts run: the locale base (served over the
; virtual host) and the active locale, consumed by the shared i18n.js.
_ActPickWeb_I18nSeed() {
	global ACTPICK_VHOST, _I18nLocale
	loc := IsSet(_I18nLocale) ? _I18nLocale : "en"
	return "window.__i18n_base='https://" . ACTPICK_VHOST . "/data/locales/';"
		. "window._i18n_locale='" . loc . "';"
}

; Virtual-host URL for the picker's index.html (served from _SharedDir via the
; vhost). A per-open cache-buster forces a fresh document each launch.
_ActPickWeb_HtmlUrl() {
	global ACTPICK_VHOST
	return "https://" . ACTPICK_VHOST . "/ui/action_picker/index.html?cb=" . A_TickCount
}

; Fire-and-forget script eval. ExecuteScript().await() wedges the thread when
; called from inside a WebView2 callback, so never await here.
; The host-to-page half of the webview bridge. ExecuteScriptAsync is named async
; but the COM marshalling to the WebView2 process is not free, and this is what
; pushes the init payload — a picker that opens slowly is almost always this call
; rather than the page. It had no segment, so the cost sat between "menu clicked"
; and "picker visible" with nothing measuring it.
_ActPickWeb_Eval(Js) {
	global _ActPickWeb_WebView
	if !IsSet(_ActPickWeb_WebView)
		return
	_hpWebEval := HotPath_Now()
	WebView_RunScriptAsync(_ActPickWeb_WebView, Js, "ActionPicker")
	HotPath_LogIfSlow("Webview.Eval", _hpWebEval, StrLen(Js) . " char(s)")
}

_ActPickWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _ActPickWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_ActPickWeb_Controller)
		try _ActPickWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) and the frontend "cancel" button both land here.
_ActPickWeb_OnClose(*) {
	_ActPickWeb_Close()
}

_ActPickWeb_Close() {
	global _ActPickWeb_Gui
	saved := (_ActPickWeb_Gui != 0) ? _ActPickWeb_Gui : 0
	_ActPickWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_ActPickWeb_Gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. the native
; Close event firing after the frontend's "cancel"/"confirm" message already
; tore the same window down) is a true no-op instead of touching the globals
; again.
_ActPickWeb_Reset() {
	global _ActPickWeb_Controller, _ActPickWeb_WebView, _ActPickWeb_MsgSub, _ActPickWeb_NavSub
	global _ActPickWeb_OnConfirm, _ActPickWeb_ResetDone, _ActPickWeb_SessionEpoch

	; A prior Reset() already released remove_WebMessageReceived/remove_Navigation-
	; Completed against this controller. Re-running the unset lines below would
	; call __Delete's bound ComCall a SECOND time against a COM pointer WebView2
	; has already torn down (Controller.Close() releases CoreWebView2's underlying
	; interfaces) — a genuine SEH access violation that no try/catch can intercept.
	if _ActPickWeb_ResetDone
		return
	_ActPickWeb_ResetDone := true
	_ActPickWeb_SessionEpoch += 1
	_ActPickWeb_ProgramRetire()

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
		_ActPickWeb_MsgSub := unset
		_ActPickWeb_NavSub := unset
		if IsSet(_ActPickWeb_Controller)
			_ActPickWeb_Controller.Close()
	}
	_ActPickWeb_Controller := unset
	_ActPickWeb_WebView    := unset
	_ActPickWeb_OnConfirm  := 0
}

; Discovery closes its resources independently from WebView COM teardown. An
; unknown/refused native receipt retains exact ownership and fences capture.
_ActPickWeb_ProgramRetire() {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramDebt, _ActPickWeb_ProgramPacket
	global _ActPickWeb_ProgramRetiring
	if _ActPickWeb_ProgramRetiring
		return false
	_ActPickWeb_ProgramRetiring := true
	try {
		Owner := _ActPickWeb_ProgramOwner
		_ActPickWeb_ProgramOwner := 0
		_ActPickWeb_ProgramPacket := Map("unavailable", true)
		if Owner is ProgramProviderSession
			_ActPickWeb_ProgramDebt.Push(Owner)
		Index := _ActPickWeb_ProgramDebt.Length
		while Index > 0 {
			Pending := _ActPickWeb_ProgramDebt[Index]
			if Pending.Invalidate()
				_ActPickWeb_ProgramDebt.RemoveAt(Index)
			Index--
		}
		return _ActPickWeb_ProgramDebt.Length == 0
	} finally _ActPickWeb_ProgramRetiring := false
}

_ActPickWeb_ProgramCapture() {
	global _ActPickWeb_ProgramOwner, _ActPickWeb_ProgramPacket
	global _ActPickWeb_ProgramDebt, _ActPickWeb_ProgramCapturing, _ActPickWeb_SessionEpoch
	global _ActPickWeb_ProgramRetiring
	if A_IsSuspended || _ActPickWeb_ProgramCapturing || _ActPickWeb_ProgramRetiring
		return false
	_ActPickWeb_ProgramCapturing := true
	Epoch := _ActPickWeb_SessionEpoch
	try {
		if !_ActPickWeb_ProgramRetire() || A_IsSuspended || !_ActPickWeb_SessionCurrent(Epoch)
			return false
		Owner := ProgramProviders_Create()
		if !(Owner is ProgramProviderSession)
			return false
		; Publish custody before discovery can enter a native acquisition.
		_ActPickWeb_ProgramOwner := Owner
		Packet := Owner.Discover()
		if !(Packet is Map) || !_ActPickWeb_SessionCurrent(Epoch) || A_IsSuspended
				|| _ActPickWeb_ProgramOwner != Owner {
			if _ActPickWeb_ProgramOwner == Owner
				_ActPickWeb_ProgramRetire()
			return false
		}
		_ActPickWeb_ProgramPacket := Packet
		return true
	} catch Any {
		_ActPickWeb_ProgramRetire()
		return false
	} finally _ActPickWeb_ProgramCapturing := false
}

_ActPickWeb_ProgramPacketJson() {
	global _ActPickWeb_ProgramPacket
	Packet := _ActPickWeb_ProgramPacket
	if Packet.Get("unavailable", false)
		return '{"unavailable":true}'
	Choices := "", Providers := ""
	for Choice in Packet["choices"]
		Choices .= (Choices == "" ? "" : ",") . '{"key":' . JsonStringLiteral(Choice["key"])
			. ',"provider":' . JsonStringLiteral(Choice["provider"])
			. ',"label":' . JsonStringLiteral(Choice["label"]) . "}"
	for Provider in Packet["providers"]
		Providers .= (Providers == "" ? "" : ",") . '{"id":' . JsonStringLiteral(Provider["id"])
			. ',"available":' . (Provider["available"] ? "true" : "false") . "}"
	return '{"choices":[' . Choices . '],"providers":[' . Providers . '],"truncated":'
		. (Packet["truncated"] ? "true" : "false") . "}"
}
