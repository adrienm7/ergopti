; ui/onboarding/webview.ahk

; ==============================================================================
; MODULE: Onboarding / WebView2 Host
; DESCRIPTION:
; Renders the first-run wizard with an embedded WebView2 control that loads the
; cross-driver frontend at _shared/ui/onboarding/ — the SAME HTML/JS/CSS the
; macOS driver uses — instead of the native AHK Gui pages in steps.ahk. The
; native pages remain as a graceful fallback (see _OnbWeb_Available): when
; WebView2 is unavailable or RAM is tight, Onboarding_Run/ShowFromMenu fall back
; to _Onboarding_Step1.
;
; FEATURES & RATIONALE:
; 1. Shared UX: one onboarding frontend for both drivers — fixing a wording or
;    a step there updates Windows and macOS at once. The bridge mirrors the
;    proven model_browser WebView2 host (lib/webview_utils + vendor/WebView2).
; 2. Reuses the existing commit: the frontend collects exactly the six answers
;    the native wizard collects (locale, config_dir, use_ergopti, magic_key,
;    use_metrics, use_gestures). The "finish" handler funnels them into the
;    SAME _ob_* globals and calls _Onboarding_Commit, so the config written to
;    disk is byte-for-byte what the native path produced — no behavior change.
; 3. Blocking contract preserved: the host sets the shared _ob_gui sentinel so
;    Onboarding_Run's "park until the wizard resolves" loop works unchanged.
;
; Functions/globals are hoisted; #Include'd from ui/onboarding/init.ahk.
; ==============================================================================

; French keyboard LANGID (low word of the HKL). When the active OS layout is
; French we hint the frontend (system_layout = "french") so step 3 pre-selects
; the "u-grave" magic key, matching _Onboarding_PickDefaultMagicKey.
global ONBOARDING_LANGID_FRENCH := 0x040C

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
global ONBOARDING_VHOST_ASSETS := "ergopti.assets"       ; -> _StaticDir (flags, layout jpg)
; COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW — let the page load these mapped
; resources, including cross-origin from the assets host.
global WEBVIEW_HOST_ACCESS_ALLOW := 1

; WebView2 host state — kept separate from the native wizard's _ob_gui handle
; usage (the host stores its Gui in _ob_gui too, so the Onboarding_Run loop and
; the close paths behave identically to the native pages).
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
; Chromium may cold-boot slowly under pressure, but that cost is paid once, and
; WebView2.create is still wrapped in a try/catch that degrades to the native
; pages if the control genuinely cannot be created.
_OnbWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader)
}

; Attempts to show the wizard in a WebView2 window. Returns true on success
; (the caller must NOT also launch the native pages), false to fall back to the
; native _Onboarding_Step1 flow. Sets the shared _ob_gui sentinel so the
; Onboarding_Run park-loop and the standard close handling apply unchanged.
_Onboarding_TryWeb() {
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	global _OnbWeb_ResetDone, _OnbWeb_SessionEpoch
	global _ob_gui, _VendorDir, _SharedDir

	if !_OnbWeb_Available() {
		; Log WHY we fall back so the path taken is unambiguous in the logs —
		; identical-looking native pages otherwise hide which renderer ran.
		try LoggerInfo("Onboarding", "WebView2 unavailable ({1}) — using native AHK pages.", _OnbWeb_UnavailableReason())
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
		try WinActivate("ahk_id " . _ob_gui.Hwnd)
		return true
	}

	try LoggerStart("Onboarding", "Launching wizard via WebView2 (shared frontend)…")

	_OnbWeb_Ready := false
	_OnbWeb_Queue := []

	g := Gui("+Resize +MinSize480x520", t("onboarding.welcome.title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w480 h560", "")
	g.OnEvent("Close",  _OnbWeb_OnClose)
	g.OnEvent("Size",   _OnbWeb_OnResize)

	; Show the window BEFORE creating the WebView2 controller and calling Fill().
	; Creating + Fill()-ing against a still-hidden window sizes the control to a
	; zero/placeholder client rect, so it paints the empty gray default and never
	; lays out the navigated page — the model_browser host shows first for exactly
	; this reason.
	g.Show("w480 h560 Center")
	_ob_gui := g

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_OnbWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("Onboarding", "WebView2 create failed: {1} — falling back to native pages.", Err.Message)
		try g.Destroy()
		_OnbWeb_Reset()
		; The window was shown before create() — clear the shared sentinel so the
		; native fallback (which sets its own _ob_gui) starts from a clean slate.
		_ob_gui := 0
		return false
	}

	_OnbWeb_WebView := _OnbWeb_Controller.CoreWebView2
	_OnbWeb_SessionEpoch += 1
	; This controller/webview pair is fresh — re-arm the Reset() guard so this
	; session's close actually tears it down instead of short-circuiting on a
	; flag left behind by an earlier _OnbWeb_Reset() call.
	_OnbWeb_ResetDone := false

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
	global _OnbWeb_MsgSub := _OnbWeb_WebView.WebMessageReceived(_OnbWeb_OnWebMessage)

	; Map virtual hosts BEFORE navigating so the document and every relative
	; asset resolve through a real origin (see ONBOARDING_VHOST comment for why
	; file:// is avoided). The frontend folder serves index.html/script.js/style.css;
	; the static folder serves the flag PNGs + layout JPG injected as absolute URLs.
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
	SetTimer(_OnbWeb_SafetyFlush, -2500)
	return true
}

; Returns a short human-readable reason why the WebView2 path is unavailable,
; used purely for the fallback log line so the cause is visible at a glance.
_OnbWeb_UnavailableReason() {
	global _VendorDir
	if !IsSet(WebView2)
		return "WebView2 binding not loaded"
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	if !FileExist(loader)
		return "WebView2Loader.dll missing"
	return "unknown"
}





; ==============================================================
; ====================================
; ======= 2/ JS <-> AHK bridge =======
; ====================================
; ==============================================================

; Receives messages from the page. The frontend JSON-encodes every payload for
; the WebView2 (chrome.webview) channel, so each message is an object with an
; "action" field. Handled actions: ready, previewLocale, localeSelected,
; pickConfigDir, loadExistingConfig, finish.
_OnbWeb_OnWebMessage(Handler, Args) {
	try Msg := Args.TryGetWebMessageAsString()
	if !IsSet(Msg)
		return
	try Payload := JsonParse(Msg)
	if (!IsSet(Payload) || !IsObject(Payload))
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
		_OnbWeb_InjectInitData()
	} else if (Action == "previewLocale") {
		_OnbWeb_PreviewLocale(Payload.Has("locale") ? Payload["locale"] : "")
	} else if (Action == "localeSelected") {
		global _ob_locale
		if (Payload.Has("locale") && Payload["locale"] != "")
			_ob_locale := Payload["locale"]
	} else if (Action == "pickConfigDir") {
		_OnbWeb_PickConfigDir(Payload.Has("current") ? Payload["current"] : "")
	} else if (Action == "loadExistingConfig") {
		_OnbWeb_LoadExistingConfig(Payload.Has("config_dir") ? Payload["config_dir"] : "")
	} else if (Action == "registerGesturesAuto") {
		; Defer out of the COM callback: the auto-config does a blocking elevated
		; RunWait (UAC + PnP cycle), which must not run inside WebMessageReceived.
		SetTimer(_OnbWeb_RegisterGesturesAuto, -1)
	} else if (Action == "registerGesturesManual") {
		SetTimer(_OnbWeb_RegisterGesturesManual, -1)
	} else if (Action == "finish") {
		_OnbWeb_Finish(Payload.Has("answers") ? Payload["answers"] : Map())
	}
}

; Evaluates JS in the page, queuing until the page signals "ready".
_OnbWeb_Eval(Js) {
	global _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	if (_OnbWeb_Ready && IsSet(_OnbWeb_WebView)) {
		; Run the ExecuteScript OUTSIDE the current call stack via a one-shot
		; timer. ExecuteScript is ExecuteScriptAsync().await(), which spins a
		; NESTED message loop; calling it synchronously from inside the
		; WebMessageReceived COM callback (as the "ready" handler does) re-enters
		; the STA apartment and wedges further WebView2 message delivery — the
		; channel then delivers exactly one message (ready) and goes silent.
		; Deferring lets the callback return first, keeping event delivery alive.
		SetTimer(_OnbWeb_RunScript.Bind(Js), -1)
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
; We do not need the script's return value, so we drop the promise on the floor;
; WebView2 holds the completion handler and still runs the script.
_OnbWeb_RunScript(Js) {
	global _OnbWeb_WebView
	if !IsSet(_OnbWeb_WebView)
		return
	try {
		_OnbWeb_WebView.ExecuteScriptAsync(Js)
	} catch as e {
		try LoggerError("Onboarding", "ExecuteScriptAsync failed (len={1}): {2}.", StrLen(Js), e.Message)
	}
}

_OnbWeb_FlushQueue() {
	global _OnbWeb_Ready, _OnbWeb_Queue, _OnbWeb_WebView
	_OnbWeb_Ready := true
	; Defer each queued script (see _OnbWeb_Eval) so none runs re-entrantly inside
	; the WebMessageReceived callback that typically triggers this flush.
	for _, Js in _OnbWeb_Queue {
		if IsSet(_OnbWeb_WebView)
			SetTimer(_OnbWeb_RunScript.Bind(Js), -1)
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




; ==============================================================
; =====================================
; ======= 3/ Message handlers =========
; =====================================
; ==============================================================

; Builds and injects window.initData(...) — the initial locale, the sorted
; locale list (code/name/flag), pre-filled answers, the OS-default config dir,
; the system-layout hint and the layout-preview image URL, plus the strings for
; the current locale.
_OnbWeb_InjectInitData() {
	global _ob_locale, _ob_config_dir, _DefaultConfigDir
	defaultDir := IsSet(_DefaultConfigDir) ? _DefaultConfigDir : ""
	answers := "{config_dir:" . _OnbWeb_JsStr(IsSet(_ob_config_dir) ? _ob_config_dir : "") . "}"
	js := "window.initData({"
		. "locale:" . _OnbWeb_JsStr(_ob_locale)
		. ",locales:" . _OnbWeb_LocalesJson()
		. ",answers:" . answers
		. ",default_config_dir:" . _OnbWeb_JsStr(defaultDir)
		. ",system_layout:" . _OnbWeb_JsStr(_OnbWeb_SystemLayoutHint())
		. ",layout_image_url:" . _OnbWeb_JsStr(_OnbWeb_LayoutImageUrl())
		; Platform hint: the gestures step (5) renders Windows-only auto/manual
		; registration buttons, whereas macOS shows only the system-gesture warning.
		. ",platform:" . _OnbWeb_JsStr("windows")
		. ",strings:" . _OnbWeb_LocaleStringsExpr(_ob_locale)
		. "})"
	_OnbWeb_Eval(js)
}

; Loads the strings for a previewed locale and pushes them as an envelope so
; the frontend can discard stale rapid-switch replies.
_OnbWeb_PreviewLocale(Code) {
	global _ob_gui
	if (Code == "")
		return
	js := "window.applyStrings({locale:" . _OnbWeb_JsStr(Code)
		. ",strings:" . _OnbWeb_LocaleStringsExpr(Code) . "})"
	try LoggerDebug("Onboarding", "Previewing locale '{1}'.", Code)
	_OnbWeb_Eval(js)
	; Sync the host window caption too: a WebView2 page's document.title does NOT
	; propagate to the AHK Gui title bar, so the previewed locale's title is set
	; here directly. _Onboarding_Translate resolves the key without disturbing the
	; running script's active locale (it returns the key itself on failure).
	title := _Onboarding_Translate(Code, "onboarding.welcome.title")
	if (title != "" && title != "onboarding.welcome.title" && IsSet(_ob_gui) && _ob_gui)
		try _ob_gui.Title := title
}

; Opens the native folder picker and feeds the chosen path back to the page.
; A cancelled dialog leaves the input untouched.
_OnbWeb_PickConfigDir(Current) {
	chosen := ""
	try chosen := DirSelect("*" . Current, 3, t("dialog.config_folder.title"))
	if (chosen != "") {
		global _ob_config_dir := chosen
		_OnbWeb_Eval("window.setConfigDir(" . _OnbWeb_JsStr(chosen) . ")")
	}
}

; Reads an existing config.toml at the chosen directory (if present) and pushes
; the saved answers back so steps 2-5 open pre-selected, mirroring the native
; StepConfigDir pre-fill.
_OnbWeb_LoadExistingConfig(Dir) {
	global _AhkSubDir
	if (Dir == "")
		return
	if !RegExMatch(Dir, "\\$")
		Dir .= "\"
	path := Dir . _AhkSubDir . "config.toml"
	if !FileExist(path)
		return
	c := ParseTomlFile(path)
	if !c.Count
		return
	saved := "{use_ergopti:" . (TomlCacheBool(c, "ahk.layout", "ergopti_base") ? "true" : "false")
		. ",use_metrics:" . (TomlCacheBool(c, "ahk.metrics", "metrics_enabled") ? "true" : "false")
		. ",use_gestures:" . (TomlCacheBool(c, "ahk.gestures", "enabled") ? "true" : "false")
	mk := IniCacheGet(c, "hotstrings", "trigger_char")
	if (mk != "_" && mk != "")
		saved .= ",magic_key:" . _OnbWeb_JsStr(mk)
	saved .= "}"
	_OnbWeb_Eval("window.applyExistingAnswers(" . saved . ")")
}

; Funnels the six collected answers into the shared _ob_* globals and runs the
; existing _Onboarding_Commit (which writes config.toml + paths.toml and
; Reloads). Gesture registry auto-config is intentionally NOT triggered here —
; matching the native path where enabling gestures without clicking the
; "Auto-register" button leaves _ob_register_pending false; the user runs the
; tray "auto configure" action when ready.
_OnbWeb_Finish(answers) {
	global _ob_locale, _ob_config_dir, _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures
	global _ob_register_pending, _OB_ALTGR_PASSTHROUGH, _ob_magic_key_explicit

	if (answers.Has("locale") && answers["locale"] != "")
		_ob_locale := answers["locale"]
	if answers.Has("config_dir")
		_ob_config_dir := answers["config_dir"]
	_ob_layout   := answers.Has("use_ergopti")  && _OnbWeb_Truthy(answers["use_ergopti"])
	_ob_metrics  := answers.Has("use_metrics")  && _OnbWeb_Truthy(answers["use_metrics"])
	_ob_gestures := answers.Has("use_gestures") && _OnbWeb_Truthy(answers["use_gestures"])
	if (answers.Has("magic_key") && answers["magic_key"] != "")
		_ob_magic_key := answers["magic_key"]
		_ob_magic_key_explicit := true
	_ob_register_pending := false
	_OB_ALTGR_PASSTHROUGH := false

	; Do not tear the wizard down until persistence succeeds. Otherwise a failed
	; path/config write would discard the user's answers and leave no retry UI.
	if _Onboarding_Commit() {
		; Close the WebView2 controller before the host window is torn down by
		; Reload (the WebView2 spec requires Controller.Close first).
		_OnbWeb_Reset()
		Reload
	}
}

; Runs the synchronous, elevated touchpad-gesture configuration (same registry
; value set + PnP cycle as the native step's _Step5_AutoRegister) and pushes a
; green/red result back to the page via window.setGestureRegisterStatus. Mirrors
; the native auto-register path so the webview and native wizards configure
; gestures identically. Scheduled out of the WebMessageReceived callback because
; the elevated RunWait blocks while the UAC prompt + touchpad cycle complete.
_OnbWeb_RegisterGesturesAuto() {
	global _OnbWeb_SessionEpoch
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
	try GestureShowManualTutorialDialog()
}





; ==============================================================
; ===================================
; ======= 4/ initData sources =======
; ===================================
; ==============================================================

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

; Returns a JS object EXPRESSION (not just a literal) for ``Code``: the raw
; locale map merged with host-derived keys the frontend expects but that do NOT
; exist verbatim on disk. Currently that is dialog.metrics.enable_warning_formatted,
; whose {1} placeholder is filled with the metrics log path — mirroring the native
; metrics step (steps.ahk) and the macOS webview path (init.lua). Object.assign
; layers the derived keys onto the parsed locale map at injection time.
_OnbWeb_LocaleStringsExpr(Code) {
	global _ConfigDir
	base := _OnbWeb_LocaleStringsJson(Code)
	; Forward-slash the path to match the cross-platform locale text (macOS uses
	; "/"), keeping the red warning block visually identical across drivers.
	metricsPath := StrReplace((IsSet(_ConfigDir) ? _ConfigDir : "") . "metrics", "\", "/")
	tpl := _Onboarding_Translate(Code, "dialog.metrics.enable_warning")
	warn := ""
	if (tpl != "" && tpl != "dialog.metrics.enable_warning")
		try warn := Format(tpl, metricsPath)
	derived := "{" . _OnbWeb_JsStr("dialog.metrics.enable_warning_formatted") . ":" . _OnbWeb_JsStr(warn) . "}"
	return "Object.assign(" . base . "," . derived . ")"
}

; Maps the active OS keyboard layout to the substring the frontend's
; _pickDefaultMagicKey matches: "french" for the French LANGID, "" otherwise
; (so QWERTY-family layouts fall through to ";" and Ergopti users keep "*").
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

; Returns the layout preview JPG URL via the assets virtual host, or "" when the
; asset is missing (the frontend then renders step 2 without the image).
_OnbWeb_LayoutImageUrl() {
	global _StaticDir, ONBOARDING_VHOST_ASSETS
	path := _StaticDir . "\img\ergopti.jpg"
	if !FileExist(path)
		return ""
	return "https://" . ONBOARDING_VHOST_ASSETS . "/img/ergopti.jpg"
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

; Coerces a JSON-decoded value to a boolean — JsonParse may yield real
; booleans, 0/1, or the strings "true"/"false" depending on the parser.
_OnbWeb_Truthy(v) {
	return (v == true || v == 1 || v == "true" || v == "1")
}

; Escapes a string for safe injection into a JS double-quoted literal.
_OnbWeb_JsStr(s) {
	s := StrReplace(s, "\",  "\\")
	s := StrReplace(s, '"',  '\"')
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return '"' . s . '"'
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
