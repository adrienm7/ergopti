; ui/onboarding/webview.ahk

; ==============================================================================
; MODULE: Onboarding / WebView2 Host
; DESCRIPTION:
; Renders the first-run wizard with an embedded WebView2 control that loads the
; cross-driver frontend at _shared/ui/onboarding/ — the SAME HTML/JS/CSS the
; macOS and Linux drivers use. It is the only renderer: without WebView2 the
; wizard cannot be shown, and the entry points say so instead of asking fewer
; questions in a second, native wizard.
;
; FEATURES & RATIONALE:
; 1. Shared UX: one onboarding frontend for every driver — fixing a wording or
;    a page there updates them all. The bridge mirrors the proven
;    model_browser WebView2 host (infra/webview_utils + vendor/WebView2).
; 2. Manifest answers: the page answers with manifest paths and values from
;    the generated catalogue; ui/onboarding/answers.ahk validates them and
;    _Onboarding_Commit writes them in one transaction before a single Reload.
; 3. Re-runs start from the configuration in force, and from the chosen
;    folder's configuration when the user picks another one.
; 4. Blocking contract preserved: the host sets the shared _ob_gui sentinel so
;    Onboarding_Run's "park until the wizard resolves" loop works unchanged.
;
; Functions/globals are hoisted; #Include'd from ui/onboarding/init.ahk.
; ==============================================================================

; French keyboard LANGID (low word of the HKL). When the active OS layout is
; French we hint the frontend (system_layout = "french") so the hotstrings page
; proposes the "u-grave" trigger character when no configuration names one.
global ONBOARDING_LANGID_FRENCH := 0x040C

; The wizard's id in _shared/ui/apps.manifest.json, which sizes it.
global ONBOARDING_APP_ID := "onboarding"

; Virtual host names mapped to local folders so the wizard loads from a stable
; origin (https://<host>/…) instead of an opaque file:// origin. Chromium treats
; every file:// document as a UNIQUE security origin, which logs "unsafe attempt
; to load URL" warnings AND made the chrome.webview JS->AHK channel silently drop
; every message (the host never received "ready"/previewLocale/finish). Mapping to
; a virtual host gives the page a normal web origin where postMessage and
; same-origin resource loading both behave — Microsoft's recommended pattern for
; packaged local web UI. Mappings are per-CoreWebView2 instance, so this does not
; affect the model_browser host that shares the same environment.
global ONBOARDING_VHOST        := "ergopti.onboarding"   ; -> _SharedDir\ui\onboarding
global ONBOARDING_VHOST_ASSETS := "ergopti.assets"       ; -> _StaticDir (language flags)
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW — let the page load these mapped
; resources, including cross-origin from the assets host.
global WEBVIEW_HOST_ACCESS_ALLOW := 1

; WebView2 host state. The host stores its Gui in the shared _ob_gui sentinel,
; which the Onboarding_Run loop parks on.
global _OnbWeb_Controller := unset
global _OnbWeb_WebView    := unset
global _OnbWeb_Ready       := false
global _OnbWeb_Queue       := []
; Subscription handle returned by WebView2.WebMessageReceived(). The thqby
; binding ties the event subscription to this object's LIFETIME: when it is
; garbage-collected its __Delete calls remove_WebMessageReceived(token),
; silently unsubscribing the handler. It MUST be kept alive in a persistent
; global for the JS->AHK channel to keep delivering messages.
global _OnbWeb_MsgSub      := unset
; True once _OnbWeb_Reset() has torn the controller down. _OnbWeb_Reset is
; reachable from BOTH _OnbWeb_Finish (JS "finish" -> _Onboarding_Commit ->
; Reload, which restarts the whole process and can itself surface the Gui's
; native Close event for _ob_gui) and _OnbWeb_OnClose (X / Alt+F4) — so the
; SAME teardown can run twice. A second pass's `_OnbWeb_MsgSub := unset` calls
; remove_WebMessageReceived via ComCall against a CoreWebView2 pointer already
; invalidated by the first pass's Controller.Close(): a genuine SEH access
; violation no AHK try/catch can intercept (see personal_toml_editor_webview.ahk
; _HsEdWeb_ResetDone for the crash this mirrors). The flag makes the second
; call a true no-op before that ComCall is ever reached.
global _OnbWeb_ResetDone   := false
; Each host controller gets a distinct epoch. Completion callbacks from an
; elevated background job must never publish into a newer WebView2 session.
global _OnbWeb_SessionEpoch := 0




; ==============================================================
; =========================================
; ======= 1/ Availability + launch ========
; =========================================
; ==============================================================

; Returns true when the WebView2 runtime binding + loader DLL are present.
; Unlike the model_browser gate, onboarding intentionally does NOT apply the
; low-RAM native fallback (WebView_ShouldUseNativeFallback): the first-run wizard
; is a one-off and the shared webview UX is wanted even on a RAM-starved machine.
; Chromium may cold-boot slowly under pressure, but that cost is paid once.
_OnbWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; The wizard's size from _shared/ui/apps.manifest.json, as every driver reads
; it, bounded by the primary monitor's work area so the footer buttons stay on
; screen: the page scrolls its content instead.
; @returns {Object} { w, h, min_w, min_h } in DPI-independent pixels.
_OnbWeb_Geometry() {
	global _SharedDir, ONBOARDING_APP_ID
	Apps := JsonParse(FileRead(_SharedDir . "\ui\apps.manifest.json", "UTF-8"))["apps"]
	Entry := Apps[ONBOARDING_APP_ID]
	MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top, &Right, &Bottom)
	Scale := A_ScreenDPI / 96
	W := Min(Entry["width"], Floor((Right - Left) / Scale))
	H := Min(Entry["height"], Floor((Bottom - Top - SysGet(4) - 2 * SysGet(33)) / Scale))
	return { w: W, h: H, min_w: Min(Entry["min_width"], W), min_h: Min(Entry["min_height"], H) }
}

; Attempts to show the wizard in a WebView2 window. Returns true on success,
; false when it cannot be shown (the caller tells the user). Sets the shared
; _ob_gui sentinel so the Onboarding_Run park-loop and the standard close
; handling apply.
_Onboarding_TryWeb() {
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	global _OnbWeb_ResetDone, _OnbWeb_SessionEpoch
	global _ob_gui, _ob_locale, _VendorDir, _SharedDir

	if !_OnbWeb_Available() {
		try LoggerError("Onboarding", "The wizard cannot be shown: WebView2 is unavailable ({1}).", _OnbWeb_UnavailableReason())
		return false
	}
	; Singleton — bring the existing wizard window to the front instead of
	; opening a second one. Every sibling WebView2 host (paths_editor,
	; personal_info_editor, prompt_editor, hotstrings_config_window) has this
	; guard; without it here, a second tray-menu click while the wizard is open
	; silently overwrites the shared _ob_gui sentinel below with a NEW window,
	; orphaning the first one — and on close, _OnbWeb_OnClose always reads
	; whichever Gui _ob_gui currently points to, so it tears down the SECOND
	; (live) window instead of the orphaned first one.
	if (_ob_gui != 0) {
		WMPresentWindow(_ob_gui)
		return true
	}
	; A duplicate request must leave the live session's callbacks and teardown
	; owner untouched. Allocate a fresh epoch only when constructing a new host.
	_OnbWeb_SessionEpoch += 1
	SessionEpoch := _OnbWeb_SessionEpoch
	_OnbWeb_ResetDone := false

	try LoggerStart("Onboarding", "Launching wizard via WebView2 (shared frontend)…")

	_OnbWeb_Ready := false
	_OnbWeb_Queue := []

	try Geo := _OnbWeb_Geometry()
	catch as Err {
		try LoggerError("Onboarding", "The wizard cannot be sized from apps.manifest.json: {1}.", Err.Message)
		return false
	}
	; The title follows the wizard's language, as the page's own title does.
	g := Gui_Create("+Resize +MinSize" . Geo.min_w . "x" . Geo.min_h, _Onboarding_Translate(_ob_locale, "onboarding.window_title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w" . Geo.w . " h" . Geo.h, "")
	g.OnEvent("Close",  _OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_OnClose))
	g.OnEvent("Size",   _OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_OnResize))

	; Show the window BEFORE creating the WebView2 controller and calling Fill().
	; Creating + Fill()-ing against a still-hidden window sizes the control to a
	; zero/placeholder client rect, so it paints the empty gray default and never
	; lays out the navigated page — the model_browser host shows first for exactly
	; this reason.
	g.Show("w" . Geo.w . " h" . Geo.h . " Center")
	_ob_gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_OnbWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("Onboarding", "WebView2 create failed: {1} — the wizard cannot be shown.", Err.Message)
		try g.Destroy()
		_OnbWeb_Reset()
		; The window was shown before create(): clear the shared sentinel so the
		; caller's park-loop and a later retry start from a clean slate.
		_ob_gui := 0
		return false
	}

	_OnbWeb_WebView := _OnbWeb_Controller.CoreWebView2
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _OnbWeb_Reset() call.

	; Harden the surface — no devtools, context menu, status bar, accelerators.
	try {
		s := _OnbWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; JS -> AHK bridge. Store the subscription handle in a persistent global —
	; discarding it lets the binding GC it and silently unsubscribe the handler.
	global _OnbWeb_MsgSub := _OnbWeb_WebView.WebMessageReceived(_OnbWeb_OnWebMessage.Bind(SessionEpoch))

	; Map virtual hosts BEFORE navigating so the document and every relative
	; asset resolve through a real origin (see ONBOARDING_VHOST comment for why
	; file:// is avoided). The frontend folder serves index.html/script.js/style.css;
	; the static folder serves the flag PNGs injected as absolute URLs.
	; Map the SHARED-UI parent folder (not just onboarding/) so relative paths
	; like ../host_bridge.js resolve correctly inside the mapped origin. WebView2
	; blocks any path that escapes the VHOST root — mapping the parent keeps
	; every shared ui/ asset reachable without duplicating host_bridge.js.
	try _OnbWeb_WebView.SetVirtualHostNameToFolderMapping(ONBOARDING_VHOST, _SharedDir . "\ui", WEBVIEW_HOST_ACCESS_ALLOW)
	try _OnbWeb_WebView.SetVirtualHostNameToFolderMapping(ONBOARDING_VHOST_ASSETS, _StaticDir, WEBVIEW_HOST_ACCESS_ALLOW)

	try _OnbWeb_WebView.Navigate(_OnbWeb_HtmlUrl())
	try _OnbWeb_Controller.Fill()

	try LoggerSuccess("Onboarding", "Wizard shown via WebView2 — rendering shared frontend at {1}.", _OnbWeb_HtmlUrl())

	; Safety: if the page never posts "ready" (rare), flush the queue anyway so
	; the wizard is not left blank.
	SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_SafetyFlush), -2500)
	return true
}

; Returns a short human-readable reason why the WebView2 path is unavailable,
; used purely for the log line so the cause is visible at a glance.
_OnbWeb_UnavailableReason() {
	global _VendorDir
	if !IsSet(WebView2)
		return "WebView2 binding not loaded"
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	if !FileExist(loader)
		return "WebView2Loader.dll missing"
	return "unknown"
}





; ====================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ====================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 (chrome.webview) channel, so each message is an object with an
; "action" field. Handled actions: ready, previewLocale, localeSelected,
; pickConfigDir, resolveMetricsPath, loadExistingConfig, registerGesturesAuto,
; registerGesturesManual, finish.
_OnbWeb_OnWebMessage(SessionEpoch, Handler, Args) {
	if !_OnbWeb_SessionCurrent(SessionEpoch)
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
		_OnbWeb_FlushQueue()
		; Reading the configuration and the catalogue, and closing the window when
		; they cannot be read, must not run on the WebMessageReceived stack.
		SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_InjectInitData), -1)
	} else if (Action == "previewLocale") {
		_OnbWeb_PreviewLocale(Payload.Has("locale") ? Payload["locale"] : "")
	} else if (Action == "localeSelected") {
		global _ob_locale
		Locale := Payload.Get("locale", "")
		if _OnbWeb_LocaleShipped(Locale)
			_ob_locale := Locale
	} else if (Action == "pickConfigDir") {
		_OnbWeb_PickConfigDir(Payload.Has("current") ? Payload["current"] : "")
	} else if (Action == "resolveMetricsPath") {
		if (!Payload.Has("request") || !(Payload["request"] is Number)) {
			try LoggerError("Onboarding", "resolveMetricsPath refused: request number missing.")
			return
		}
		_OnbWeb_ResolveMetricsPath(Payload.Has("config_dir") ? Payload["config_dir"] : "", Payload["request"])
	} else if (Action == "loadExistingConfig") {
		; The request number lets the page drop a reply for a folder it left.
		if (!Payload.Has("request") || !(Payload["request"] is Integer)) {
			try LoggerError("Onboarding", "loadExistingConfig refused: request number missing.")
			return
		}
		SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_LoadExistingConfig,
			Payload.Get("config_dir", ""), Payload["request"]), -1)
	} else if (Action == "registerGesturesAuto") {
		; Defer out of the COM callback: launching the elevated worker shows the
		; UAC prompt, which must not run inside WebMessageReceived.
		SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_RegisterGesturesAuto), -1)
	} else if (Action == "registerGesturesManual") {
		SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_RegisterGesturesManual), -1)
	} else if (Action == "finish") {
		if !Payload.Has("answers") || !(Payload["answers"] is Map)
			return
		Answers := Payload["answers"]
		SetTimer(_OnbWeb_SessionCall.Bind(SessionEpoch, _OnbWeb_Finish, Answers), -1)
	}
}

; Evaluates JS in the page, queuing until the page signals "ready".
_OnbWeb_Eval(Js) {
	global _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue, _OnbWeb_SessionEpoch
	if (_OnbWeb_Ready && IsSet(_OnbWeb_WebView)) {
		; Run the ExecuteScript OUTSIDE the current call stack via a one-shot
		; timer. ExecuteScript is ExecuteScriptAsync().await(), which spins a
		; NESTED message loop; calling it synchronously from inside the
		; WebMessageReceived COM callback (as the "ready" handler does) re-enters
		; the STA apartment and wedges further WebView2 message delivery — the
		; channel then delivers exactly one message (ready) and goes silent.
		; Deferring lets the callback return first, keeping event delivery alive.
		SetTimer(_OnbWeb_RunScript.Bind(_OnbWeb_SessionEpoch, Js), -1)
	} else {
		_OnbWeb_Queue.Push(Js)
		if (_OnbWeb_Queue.Length > 50)
			_OnbWeb_Queue.RemoveAt(1)
	}
}

; Executes a queued script on a fresh call stack (scheduled by _OnbWeb_Eval via a
; -1 timer). Uses ExecuteScriptAsync FIRE-AND-FORGET (no .await()): the convenience
; ExecuteScript() is ExecuteScriptAsync().await(), and that .await() spins a nested
; message loop waiting for the script result. Under live message traffic (e.g. the
; 135 KB locale-string injection on every language switch) that nested loop can
; fail to complete and wedge the AHK thread — the channel then stops delivering.
; The shared observer consumes native completion without waiting for its value.
_OnbWeb_RunScript(SessionEpoch, Js) {
	global _OnbWeb_WebView
	if !_OnbWeb_SessionCurrent(SessionEpoch)
		return
	if !IsSet(_OnbWeb_WebView)
		return
	WebView_RunScriptAsync(_OnbWeb_WebView, Js, "Onboarding")
}

_OnbWeb_FlushQueue() {
	global _OnbWeb_Ready, _OnbWeb_Queue, _OnbWeb_WebView, _OnbWeb_SessionEpoch
	_OnbWeb_Ready := true
	; Defer each queued script (see _OnbWeb_Eval) so none runs re-entrantly inside
	; the WebMessageReceived callback that typically triggers this flush.
	for _, Js in _OnbWeb_Queue {
		if IsSet(_OnbWeb_WebView)
			SetTimer(_OnbWeb_RunScript.Bind(_OnbWeb_SessionEpoch, Js), -1)
	}
	_OnbWeb_Queue := []
}

_OnbWeb_SafetyFlush() {
	global _OnbWeb_Ready
	if (!_OnbWeb_Ready) {
		; The page did not post "ready" within the timeout — inject initData anyway
		; so the wizard is never left blank. Reaching here regularly would hint at a
		; JS->AHK channel problem, so log it.
		try LoggerWarn("Onboarding", "Page did not signal ready within timeout — SafetyFlush injecting initData.")
		_OnbWeb_FlushQueue()
		_OnbWeb_InjectInitData()
	}
}

_OnbWeb_SessionCurrent(SessionEpoch) {
	global _OnbWeb_SessionEpoch
	return SessionEpoch == _OnbWeb_SessionEpoch
}

_OnbWeb_SessionCall(SessionEpoch, Callback, Params*) {
	if !_OnbWeb_SessionCurrent(SessionEpoch)
		return false
	Callback(Params*)
	return true
}




; ==============================================================
; =====================================
; ======= 3/ Message handlers =========
; =====================================
; ==============================================================

; Builds and injects window.initData(...): the platform whose catalogue pages
; the page shows, the wizard's locale and the sorted locale list, the OS-default
; and current configuration folders, the values the configuration in force
; holds for every wizard path, the system-layout hint, the metrics store and
; the strings of the current locale. A configuration that cannot be read never
; opens neutral pages: committing them would overwrite answers the user gave.
_OnbWeb_InjectInitData() {
	global _ob_locale, _DefaultConfigDir, ConfigurationFile, ONBOARDING_CATALOGUE_DRIVER
	try Index := OnboardingCatalogue()
	catch as Err {
		_OnbWeb_OpenFailed("the onboarding catalogue is unavailable: " . Err.Message)
		return
	}
	Values := OnboardingReadCurrentValues(Index, ConfigurationFile)
	if !(Values is Map) {
		_OnbWeb_OpenFailed(Values)
		return
	}
	ConfigDir := _OnbWeb_CustomConfigDir()
	js := "window.initData({"
		. "platform:" . _OnbWeb_JsStr(ONBOARDING_CATALOGUE_DRIVER)
		. ",locale:" . _OnbWeb_JsStr(_ob_locale)
		. ",locales:" . _OnbWeb_LocalesJson()
		. ",default_config_dir:" . _OnbWeb_JsStr(_DefaultConfigDir)
		. ",config_dir:" . _OnbWeb_JsStr(ConfigDir)
		. ",current:" . OnboardingValuesJson(Values)
		. ",system_layout:" . _OnbWeb_JsStr(_OnbWeb_SystemLayoutHint())
		; The page fills the metrics consent warning with this path; later folder
		; changes arrive through resolveMetricsPath -> window.setMetricsPath.
		. ",metrics_path:" . _OnbWeb_JsStr(_Onboarding_MetricsPathFor(ConfigDir))
		. ",strings:" . _OnbWeb_LocaleStringsJson(_ob_locale)
		. "})"
	_OnbWeb_Eval(js)
}

; Tells the user the wizard cannot start, then closes it. On a first run the
; park-loop then exits: the driver cannot run on a configuration nobody chose.
; @param Detail string Why, for the log.
_OnbWeb_OpenFailed(Detail) {
	try LoggerError("Onboarding", "The wizard cannot start: {1}.", Detail)
	_Onboarding_ShowError("onboarding.error.open_failed")
	_OnbWeb_OnClose()
}

; Loads the strings for a previewed locale and pushes them as an envelope so
; the frontend can discard stale rapid-switch replies.
_OnbWeb_PreviewLocale(Code) {
	global _ob_gui
	if !_OnbWeb_LocaleShipped(Code)
		return
	js := "window.applyStrings({locale:" . _OnbWeb_JsStr(Code)
		. ",strings:" . _OnbWeb_LocaleStringsJson(Code) . "})"
	try LoggerDebug("Onboarding", "Previewing locale '{1}'.", Code)
	_OnbWeb_Eval(js)
	; Sync the host window caption too: a WebView2 page's document.title does NOT
	; propagate to the AHK Gui title bar, so the previewed locale's title is set
	; here directly. _Onboarding_Translate resolves the key without disturbing the
	; running script's active locale (it returns the key itself on failure).
	title := _Onboarding_Translate(Code, "onboarding.window_title")
	if (title != "" && title != "onboarding.window_title" && IsSet(_ob_gui) && _ob_gui)
		try _ob_gui.Title := WindowTitle(title)
}

; Opens the native folder picker and feeds the chosen path back to the page.
; A cancelled dialog leaves the input untouched.
_OnbWeb_PickConfigDir(Current) {
	chosen := ""
	try chosen := Ui_DirSelect("*" . Current, 3, t("dialog.config_folder.title"), t("dialog.config_folder.window_title"), 0)
	catch as PickerError {
		LoggerError("Onboarding", "Native configuration-folder selection failed: {1}", PickerError.Message)
		return
	}
	if (chosen != "")
		_OnbWeb_Eval("window.setConfigDir(" . _OnbWeb_JsStr(chosen) . ")")
}

; Answers the page with the metrics store of the folder confirmed on the config
; step, so the metrics consent warning names where keystrokes will really go.
; The request number is echoed so the page drops replies for a stale folder.
_OnbWeb_ResolveMetricsPath(Dir, Request) {
	_OnbWeb_Eval(_OnbWeb_MetricsPathJs(Dir, Request))
}

; Builds the window.setMetricsPath(...) call; split out so it is testable
; without a live WebView2.
; @param Dir string Wizard field value.
; @param Request number Page request number.
; @return string JavaScript source.
_OnbWeb_MetricsPathJs(Dir, Request) {
	return "window.setMetricsPath({request:" . Request
		. ",path:" . _OnbWeb_JsStr(_Onboarding_MetricsPathFor(Dir)) . "})"
}

; Answers the page with the configuration of the folder chosen on the config
; page: its values when it holds a config.toml, none when it does not. The
; request number is echoed so the page drops a reply for a folder it left.
; @param Dir string Wizard field value; "" is the OS default.
; @param Request Integer Page request number.
; @returns {Boolean} Whether the values were sent.
_OnbWeb_LoadExistingConfig(Dir, Request) {
	global _AhkSubDir
	Folder := (Dir is String) ? ConfigTransitionNormalizeConfigDir(_Onboarding_ConfigDirFor(Dir)) : false
	if !(Folder is String) {
		try LoggerError("Onboarding", "loadExistingConfig refused: the folder is not a valid absolute path.")
		return false
	}
	try Index := OnboardingCatalogue()
	catch as Err {
		try LoggerError("Onboarding", "loadExistingConfig refused: {1}.", Err.Message)
		return false
	}
	Values := OnboardingReadCurrentValues(Index, Folder . _AhkSubDir . "config.toml")
	if !(Values is Map)
		return false
	_OnbWeb_Eval("window.applyCurrentValues({request:" . Request
		. ",values:" . OnboardingValuesJson(Values) . "})")
	return true
}

; Validates the page's finish payload before anything changes.
; @param Answers any The payload's "answers" value.
; @returns {Map|String} "locale", "config_dir", "rows" and "tap_hold_keys", or
;   why it was refused.
_OnbWeb_FinishPlan(Answers) {
	if !(Answers is Map)
		return "the answers are not an object"
	Locale := Answers.Get("locale", "")
	if !_OnbWeb_LocaleShipped(Locale)
		return "the language is not a shipped locale"
	ConfigDir := Answers.Get("config_dir", "")
	if !(ConfigDir is String)
		return "the configuration folder is not text"
	try Index := OnboardingCatalogue()
	catch as Err
		return "the onboarding catalogue is unavailable: " . Err.Message
	Rows := OnboardingAnswerRows(Index, Answers.Get("operations", ""))
	if !(Rows is Array)
		return Rows
	TapHoldKeys := OnboardingTapHoldKeys(Index, Answers.Get("operations", ""))
	if !(TapHoldKeys is Array)
		return TapHoldKeys
	return Map("locale", Locale, "config_dir", ConfigDir, "rows", Rows,
		"tap_hold_keys", TapHoldKeys)
}

; Commits the validated answers through _Onboarding_Commit (config.toml, the
; imported tap-hold keys' tap_hold.toml and, when the folder moves, paths.toml
; in one transaction, then Reload). A refused payload writes nothing and leaves
; the wizard open.
; @param Answers any The payload's "answers" value.
; @returns {Boolean}
_OnbWeb_Finish(Answers) {
	global _ob_locale, _OB_ALTGR_PASSTHROUGH
	if A_IsSuspended
		return false
	if !(Answers is Map)
		return false
	Plan := _OnbWeb_FinishPlan(Answers)
	if !(Plan is Map) {
		try LoggerError("Onboarding", "Finish refused: {1}.", Plan)
		_Onboarding_ShowError("onboarding.error.invalid_answers")
		return false
	}
	try LoggerInfo("Onboarding", "Committing {1} wizard answer row(s) and {2} tap-hold key(s).",
		Plan["rows"].Length, Plan["tap_hold_keys"].Length)
	_ob_locale := Plan["locale"]
	_OB_ALTGR_PASSTHROUGH := false

	; Do not tear the wizard down until persistence succeeds. Otherwise a failed
	; path/config write would discard the user's answers and leave no retry UI.
	; Close the WebView2 controller only from the accepted reload hand-off. The
	; config/path owners remain held until that callback, and a refused reload
	; leaves this retry surface intact.
	TapHoldKeys := Plan["tap_hold_keys"]
	return _Onboarding_Commit(Plan["locale"], Plan["config_dir"], Plan["rows"], TapHoldKeys, _OnbWeb_Reset)
}

; Starts the elevated touchpad-gesture configuration (registry value set + PnP
; cycle, ui/onboarding/gesture_registration.ahk) and pushes a green/red result
; back to the page via window.setGestureRegisterStatus once the worker publishes
; it. Scheduled out of the WebMessageReceived callback because the launch shows
; the UAC prompt.
_OnbWeb_RegisterGesturesAuto() {
	global _OnbWeb_SessionEpoch
	if A_IsSuspended
		return false
	SessionEpoch := _OnbWeb_SessionEpoch
	if !_Onboarding_StartGestureAuto(_OnbWeb_GestureAutoDone.Bind(SessionEpoch))
		_OnbWeb_Eval("window.setGestureRegisterStatus(false)")
}

_OnbWeb_GestureAutoDone(SessionEpoch, ok) {
	global _OnbWeb_SessionEpoch
	if (SessionEpoch != _OnbWeb_SessionEpoch) {
		try LoggerWarn("Onboarding", "Dropping stale gesture auto-config completion (epoch={1}).", SessionEpoch)
		return
	}
	if A_IsSuspended {
		SetTimer(_OnbWeb_GestureAutoDone.Bind(SessionEpoch, ok), -100)
		return
	}
	try LoggerInfo("Onboarding", "Gesture auto-configuration completed (ok={1}).", ok ? "true" : "false")
	_OnbWeb_Eval("window.setGestureRegisterStatus(" . (ok ? "true" : "false") . ")")
}

; Opens the shared manual-tutorial dialog (single source of truth in
; modules/gestures.ahk) — the same popup the native step's manual button and the
; tray menu show.
_OnbWeb_RegisterGesturesManual() {
	if A_IsSuspended
		return false
	try GestureShowManualTutorialDialog()
}





; ===================================
; ===================================
; ======= 4/ initData sources =======
; ===================================
; ===================================

; Returns the JSON array of supported locales [{code,name,flag}], in the same
; order as the tray language menu (_I18nSortedLocales). The flag emoji is read
; from each locale file's [_meta].flag; missing files contribute an empty flag.
_OnbWeb_LocalesJson() {
	out := "", first := true
	for Loc in _I18nSortedLocales() {
		flag := _OnbWeb_LocaleFlag(Loc.Code)
		entry := "{code:" . _OnbWeb_JsStr(Loc.Code)
			. ",name:" . _OnbWeb_JsStr(Loc.Name)
			. ",flag:" . _OnbWeb_JsStr(flag)
			. ",flag_url:" . _OnbWeb_JsStr(_OnbWeb_FlagUrl(Loc.Code)) . "}"
		out .= (first ? "" : ",") . entry
		first := false
	}
	return "[" . out . "]"
}

; Returns a file:// URL to the locale's PNG flag (static/img/flags/<code>.png),
; or "" when the asset is missing. Windows has no flag-emoji font, so the
; WebView2 frontend renders these PNGs as <img> instead of the emoji glyph the
; macOS WKWebView path displays from [_meta].flag.
_OnbWeb_FlagUrl(Code) {
	global _StaticDir, ONBOARDING_VHOST_ASSETS
	path := _StaticDir . "\img\flags\" . Code . ".png"
	if !FileExist(path)
		return ""
	return "https://" . ONBOARDING_VHOST_ASSETS . "/img/flags/" . Code . ".png"
}

; Reads the [_meta].flag glyph for a locale from its JSON file. Returns "" when
; the file or key is absent so the language list still renders (sans flag).
_OnbWeb_LocaleFlag(Code) {
	global _SharedDir
	path := _SharedDir . "\data\locales\" . Code . ".json"
	if !FileExist(path)
		return ""
	try {
		data := JsonParse(FileRead(path, "UTF-8"))
		if (data.Has("_meta.flag"))
			return data["_meta.flag"]
	}
	return ""
}

; Returns the raw locale JSON object literal for ``Code`` (a flat key->string
; map), suitable for direct injection as a JS object. Falls back to {} so the
; frontend renders keys verbatim rather than crashing on a missing file.
_OnbWeb_LocaleStringsJson(Code) {
	global _SharedDir
	path := _SharedDir . "\data\locales\" . Code . ".json"
	if FileExist(path) {
		try return FileRead(path, "UTF-8")
	}
	return "{}"
}

; Maps the active OS keyboard layout to the substring the page's
; _contextMagicKey matches: "french" for the French LANGID, "" otherwise (so
; QWERTY-family layouts fall through to ";").
_OnbWeb_SystemLayoutHint() {
	global ONBOARDING_LANGID_FRENCH
	try {
		hkl  := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
		lang := hkl & 0xFFFF
		if (lang == ONBOARDING_LANGID_FRENCH)
			return "french"
	}
	return ""
}

; Whether a locale code is one this driver ships.
; @param Code any
; @returns {Boolean}
_OnbWeb_LocaleShipped(Code) {
	if !(Code is String) || Code == ""
		return false
	for Loc in _I18nSortedLocales() {
		if (Loc.Code == Code)
			return true
	}
	return false
}

; The configuration folder the config page starts on: "" while the driver uses
; the OS default, as on the other drivers, else the folder in force.
; @returns {String}
_OnbWeb_CustomConfigDir() {
	global _ConfigDir
	return (_Onboarding_ConfigDirFor(_ConfigDir) = _Onboarding_ConfigDirFor("")) ? "" : _ConfigDir
}

; The config folder a wizard field value commits to. _ConfigDir is deliberately
; NOT updated until the commit succeeds, so any page rendered after the folder
; step must resolve through here — reading _ConfigDir shows the boot folder,
; which is how the keystroke-logging consent text ended up naming a path that
; keystrokes were never going to be written to. An empty field means "use the
; OS default" exactly as _Onboarding_Commit resolves it.
; @param Chosen string Wizard field value.
; @return string Folder with a trailing backslash.
_Onboarding_ConfigDirFor(Chosen) {
	global _DefaultConfigDir
	Dir := (Chosen != "") ? Chosen : _DefaultConfigDir
	if (Dir != "" and !RegExMatch(Dir, "[/\\]$"))
		Dir .= "\"
	return Dir
}

; Metrics store shown in the keystroke-logging consent text for a wizard field
; value, through the keylogger's own rule (KL_MetricsDirFor). Forward slashes
; match the cross-driver locale text.
; @param Chosen string Wizard field value.
; @return string
_Onboarding_MetricsPathFor(Chosen) {
	return StrReplace(KL_MetricsDirFor(_Onboarding_ConfigDirFor(Chosen)), "\", "/")
}

; Returns the virtual-host URL for _shared/ui/onboarding/index.html. Served from
; a mapped origin (not file://) so the chrome.webview JS->AHK channel works.
; A per-launch cache-buster forces a fresh index.html each open (WebView2 caches
; virtual-host resources); index.html in turn references script.js/style.css with
; their own ?v= so an edited frontend is never served stale during development.
_OnbWeb_HtmlUrl() {
	global ONBOARDING_VHOST
	return "https://" . ONBOARDING_VHOST . "/onboarding/index.html?cb=" . A_TickCount
}




; ==============================================================
; =============================
; ======= 5/ Utilities ========
; =============================
; ==============================================================

; Escapes a string for safe injection into a JS double-quoted literal.
_OnbWeb_JsStr(s) {
	return JsonStringLiteral(s)
}

_OnbWeb_OnResize(GuiObj, MinMax, Width, Height) {
	global _OnbWeb_Controller
	if (MinMax == -1)
		return
	if IsSet(_OnbWeb_Controller)
		try _OnbWeb_Controller.Fill()
}

; Window-close (X / Alt+F4) without committing: restore AltGr, drop the WebView2
; controller, clear the _ob_gui sentinel so Onboarding_Run's park-loop ends and
; the caller exits (first launch) or returns (menu re-run).
_OnbWeb_OnClose(*) {
	global _ob_gui, _OB_ALTGR_PASSTHROUGH
	_OB_ALTGR_PASSTHROUGH := false
	saved := (_ob_gui != 0) ? _ob_gui : 0
	_OnbWeb_Reset()
	try {
		if saved
			saved.Destroy()
	}
	_ob_gui := 0
}

; Tears down the WebView2 controller + host state (NOT the Gui — callers decide
; whether to destroy the window). Idempotent: a second call (e.g. _OnbWeb_Finish
; and _OnbWeb_OnClose both firing for the same teardown) is a true no-op instead
; of touching the globals again.
_OnbWeb_Reset() {
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue, _OnbWeb_MsgSub
	global _OnbWeb_ResetDone, _OnbWeb_SessionEpoch

	; A prior Reset() already released remove_WebMessageReceived against this
	; controller. Re-running the unset line below would call __Delete's bound
	; ComCall a SECOND time against a COM pointer WebView2 has already torn down
	; (Controller.Close() releases CoreWebView2's underlying interfaces) — a
	; genuine SEH access violation that no try/catch can intercept.
	if _OnbWeb_ResetDone
		return
	_OnbWeb_ResetDone := true
	_OnbWeb_SessionEpoch += 1

	; The whole teardown runs under one try: a hard COM access violation can
	; occur mid-sequence (e.g. if the controller was invalidated by the host Gui
	; already being destroyed), and a bare per-line `try` only catches ordinary
	; AHK exceptions — it does NOT catch that class of failure, but wrapping the
	; sequence still protects the *other* lines from a preceding non-fatal COM
	; error so the globals below are always cleared even when the unsubscribe
	; itself fails.
	try {
		; Release the subscription handle FIRST, while the controller is still alive.
		; Its __Delete unsubscribes via remove_WebMessageReceived on the live controller;
		; doing it AFTER Controller.Close() raises a COM error that — uncaught in the
		; window's Close-event thread — terminates the entire AHK script.
		_OnbWeb_MsgSub := unset
		if IsSet(_OnbWeb_Controller)
			_OnbWeb_Controller.Close()
	}
	_OnbWeb_Controller := unset
	_OnbWeb_WebView    := unset
	_OnbWeb_Ready      := false
	_OnbWeb_Queue      := []
}
