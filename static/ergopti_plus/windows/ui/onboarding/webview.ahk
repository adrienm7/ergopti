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

; WebView2 host state — kept separate from the native wizard's _ob_gui handle
; usage (the host stores its Gui in _ob_gui too, so the Onboarding_Run loop and
; the close paths behave identically to the native pages).
global _OnbWeb_Controller := unset
global _OnbWeb_WebView    := unset
global _OnbWeb_Ready       := false
global _OnbWeb_Queue       := []




; ==============================================================
; =========================================
; ======= 1/ Availability + launch ========
; =========================================
; ==============================================================

; Returns true when the WebView2 runtime + loader DLL are present and there is
; enough free RAM to boot Chromium. Mirrors the model_browser gate.
_OnbWeb_Available() {
	global _VendorDir
	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	return IsSet(WebView2) && FileExist(loader) && !WebView_ShouldUseNativeFallback()
}

; Attempts to show the wizard in a WebView2 window. Returns true on success
; (the caller must NOT also launch the native pages), false to fall back to the
; native _Onboarding_Step1 flow. Sets the shared _ob_gui sentinel so the
; Onboarding_Run park-loop and the standard close handling apply unchanged.
_Onboarding_TryWeb() {
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	global _ob_gui, _VendorDir, _SharedDir

	if !_OnbWeb_Available()
		return false

	_OnbWeb_Ready := false
	_OnbWeb_Queue := []

	g := Gui("+Resize +MinSize480x520", t("onboarding.welcome.title"))
	g.BackColor := "0x1e1e1e"
	g.MarginX   := 0
	g.MarginY   := 0
	Placeholder := g.Add("Text", "x0 y0 w480 h560", "")
	g.OnEvent("Close",  _OnbWeb_OnClose)
	g.OnEvent("Size",   _OnbWeb_OnResize)

	loader := _VendorDir . "\64bit\WebView2Loader.dll"
	try {
		_OnbWeb_Controller := WebView2.create(Placeholder.Hwnd, , WebView_SharedEnvironment(loader))
	} catch as Err {
		try LoggerError("Onboarding", "WebView2 create failed: {1} — falling back to native pages.", Err.Message)
		try g.Destroy()
		_OnbWeb_Reset()
		return false
	}

	_OnbWeb_WebView := _OnbWeb_Controller.CoreWebView2

	; Harden the surface — no devtools, context menu, status bar, accelerators.
	try {
		s := _OnbWeb_WebView.Settings
		s.AreDevToolsEnabled               := false
		s.AreDefaultContextMenusEnabled    := false
		s.IsStatusBarEnabled               := false
		s.AreBrowserAcceleratorKeysEnabled := false
		s.IsSwipeNavigationEnabled         := false
	}

	; JS -> AHK bridge.
	_OnbWeb_WebView.WebMessageReceived(_OnbWeb_OnWebMessage)

	try _OnbWeb_WebView.Navigate(_OnbWeb_HtmlUrl())
	try _OnbWeb_Controller.Fill()

	g.Show("w480 h560 Center")
	_ob_gui := g

	; Safety: if the page never posts "ready" (rare), flush the queue anyway so
	; the wizard is not left blank.
	SetTimer(_OnbWeb_SafetyFlush, -2500)
	return true
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
	} else if (Action == "finish") {
		_OnbWeb_Finish(Payload.Has("answers") ? Payload["answers"] : Map())
	}
}

; Evaluates JS in the page, queuing until the page signals "ready".
_OnbWeb_Eval(Js) {
	global _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	if (_OnbWeb_Ready && IsSet(_OnbWeb_WebView)) {
		try _OnbWeb_WebView.ExecuteScript(Js)
	} else {
		_OnbWeb_Queue.Push(Js)
		if (_OnbWeb_Queue.Length > 50)
			_OnbWeb_Queue.RemoveAt(1)
	}
}

_OnbWeb_FlushQueue() {
	global _OnbWeb_Ready, _OnbWeb_Queue, _OnbWeb_WebView
	_OnbWeb_Ready := true
	for _, Js in _OnbWeb_Queue {
		if IsSet(_OnbWeb_WebView)
			try _OnbWeb_WebView.ExecuteScript(Js)
	}
	_OnbWeb_Queue := []
}

_OnbWeb_SafetyFlush() {
	global _OnbWeb_Ready
	if (!_OnbWeb_Ready) {
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
		. ",strings:" . _OnbWeb_LocaleStringsJson(_ob_locale)
		. "})"
	_OnbWeb_Eval(js)
}

; Loads the strings for a previewed locale and pushes them as an envelope so
; the frontend can discard stale rapid-switch replies.
_OnbWeb_PreviewLocale(Code) {
	if (Code == "")
		return
	js := "window.applyStrings({locale:" . _OnbWeb_JsStr(Code)
		. ",strings:" . _OnbWeb_LocaleStringsJson(Code) . "})"
	_OnbWeb_Eval(js)
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
	saved := "{use_ergopti:" . (_OnbWeb_TomlBool(c, "ahk.layout", "ergopti_base") ? "true" : "false")
		. ",use_metrics:" . (_OnbWeb_TomlBool(c, "ahk.metrics", "metrics_enabled") ? "true" : "false")
		. ",use_gestures:" . (_OnbWeb_TomlBool(c, "ahk.gestures", "enabled") ? "true" : "false")
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
	global _ob_register_pending, _OB_ALTGR_PASSTHROUGH

	if (answers.Has("locale") && answers["locale"] != "")
		_ob_locale := answers["locale"]
	if answers.Has("config_dir")
		_ob_config_dir := answers["config_dir"]
	_ob_layout   := answers.Has("use_ergopti")  && _OnbWeb_Truthy(answers["use_ergopti"])
	_ob_metrics  := answers.Has("use_metrics")  && _OnbWeb_Truthy(answers["use_metrics"])
	_ob_gestures := answers.Has("use_gestures") && _OnbWeb_Truthy(answers["use_gestures"])
	if (answers.Has("magic_key") && answers["magic_key"] != "")
		_ob_magic_key := answers["magic_key"]
	_ob_register_pending := false
	_OB_ALTGR_PASSTHROUGH := false

	; Close the WebView2 controller before the host window is torn down by the
	; upcoming Reload (the WebView2 spec requires Controller.Close first).
	_OnbWeb_Reset()
	_Onboarding_Commit()
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
			. ",flag:" . _OnbWeb_JsStr(flag) . "}"
		out .= (first ? "" : ",") . entry
		first := false
	}
	return "[" . out . "]"
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

; Returns a file:// URL to the Ergopti layout preview JPG, or "" when the asset
; is missing (the frontend then renders step 2 without the image).
_OnbWeb_LayoutImageUrl() {
	global _StaticDir
	path := _StaticDir . "\img\ergopti.jpg"
	if !FileExist(path)
		return ""
	return "file:///" . StrReplace(path, "\", "/")
}

; Returns the file:// URL for _shared/ui/onboarding/index.html.
_OnbWeb_HtmlUrl() {
	global _SharedDir
	base := _SharedDir . "\ui\onboarding\index.html"
	loop files, base
		base := A_LoopFileFullPath
	return "file:///" . StrReplace(base, "\", "/")
}




; ==============================================================
; =============================
; ======= 5/ Utilities ========
; =============================
; ==============================================================

; Reads a TOML boolean via the IniCache, treating only an explicit "true"/"1"
; as true. Missing keys ("_") and "false" both read as false.
_OnbWeb_TomlBool(c, Section, Key) {
	v := IniCacheGet(c, Section, Key)
	return (v == "true" || v == "1" || v == true || v == 1)
}

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
	s := StrReplace(s, "`r", "")
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
; whether to destroy the window). Safe to call repeatedly.
_OnbWeb_Reset() {
	global _OnbWeb_Controller, _OnbWeb_WebView, _OnbWeb_Ready, _OnbWeb_Queue
	if IsSet(_OnbWeb_Controller)
		try _OnbWeb_Controller.Close()
	_OnbWeb_Controller := unset
	_OnbWeb_WebView    := unset
	_OnbWeb_Ready      := false
	_OnbWeb_Queue      := []
}
