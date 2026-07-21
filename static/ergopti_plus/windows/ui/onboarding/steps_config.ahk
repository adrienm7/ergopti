; ui/onboarding/steps_config.ahk

; ==============================================================================
; MODULE: Onboarding / Config Steps
; DESCRIPTION:
; Wizard steps covering locale selection, personal config-folder selection, and
; pre-fill from an existing config.toml. These three steps are the first group
; of the onboarding flow: they establish the language and data-directory context
; before any feature choices are offered.
;
; Split from ui/onboarding/steps.ahk; see ui/onboarding/init.ahk for the full
; module overview. Functions and globals are hoisted, so load order across the
; onboarding/*.ahk files is irrelevant.
; ==============================================================================





; =============================================
; =============================================
; ======= 4.1/ Step 1 — Locale + Config =======
; =============================================
; =============================================



; ============================================
; ===== 4.1) Step 1 — Language selection =====
; ============================================

_Onboarding_Step1() {
	global _StaticDir, _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures, _ob_register_pending
	global _ob_magic_key_explicit
	_ob_layout            := false
	_ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
	_ob_magic_key_explicit := false
	_ob_metrics           := false
	_ob_gestures          := false
	_ob_register_pending  := false

	; Sort the locale list alphabetically by Name so the wizard's language
	; picker matches the tray menu's order (both use _I18nSortedLocales) —
	; users who know where English lives in the tray menu now find it in the
	; same spot here. Detect the Windows UI language and pre-select it when
	; it is in our supported list; otherwise fall back to English.
	SortedLocales := _I18nSortedLocales()
	DetectedCode := _I18nDetectSystemLocale()
	DefaultIndex := 1
	for _i, _loc in SortedLocales {
		if _loc.Code = DetectedCode {
			DefaultIndex := _i
			break
		}
	}
	; Safety net: if detected code not found, fall back to English.
	if DefaultIndex = 1 and SortedLocales[1].Code != DetectedCode {
		for _i, _loc in SortedLocales {
			if _loc.Code = "en" {
				DefaultIndex := _i
				break
			}
		}
	}

	; Title and heading initially rendered in the pre-selected locale (English)
	; so the very first frame of the wizard is already in a sensible language.
	DefaultCode := SortedLocales[DefaultIndex].Code
	g := Gui("+AlwaysOnTop", _Onboarding_Translate(DefaultCode, "onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 1 of 6.
	_Onboarding_AddProgressDots(g, 1)

	; The main heading is the only piece of static text in the welcome screen.
	; We deliberately ship a single language at a time (re-rendered live on
	; selection) rather than the old "Welcome / Bienvenue / Willkommen" salad,
	; because mixing five locales hurt readability and made every line cramped.
	; Rendered as the page's large bold section title (s12 Bold), centred.
	; ``xm`` is REQUIRED: the progress glyphs above are positioned with absolute
	; X, and a control with no explicit X inherits the previous control's X — so
	; without ``xm`` the title would inherit the last glyph's X and float to the
	; right of the page instead of spanning it.
	g.SetFont("s12 Bold")
	headingText := g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center Section",
		_Onboarding_Translate(DefaultCode, "onboarding.welcome.heading"))
	g.SetFont("s10 norm")

	; Build a 32×24 image list from flag PNGs in static/img/flags/
	FlagsDir := _StaticDir . "\img\flags\"
	IL := IL_Create(SortedLocales.Length, 1, false)
	FlagIndexMap := Map()  ; Code -> 1-based IL index
	loop SortedLocales.Length {
		loc      := SortedLocales[A_Index]
		FlagFile := FlagsDir . loc.Code . ".png"
		idx      := IL_Add(IL, FlagFile)
		FlagIndexMap[loc.Code] := (idx > 0) ? idx : 0
	}

	; Single-select ListView — one row per locale, flag icon + name. Width is
	; ~half the page (language names are short) and the control is centred
	; horizontally so the list sits in the middle of the page rather than
	; flush-left with a large empty band beside it.
	ContentW := (ONBOARDING_WIN_W - 40) // 2 + 20   ; ~half page + room for flag and scrollbar
	lvX      := (ONBOARDING_WIN_W - ContentW) // 2  ; centre the control on the page
	lv := g.AddListView("x" lvX " y+10 w" ContentW " h" ONBOARDING_LV_H " -Hdr -Multi -HScroll LV0x10 NoSortHdr", ["Language"])
	lv.SetImageList(IL)
	loop SortedLocales.Length {
		loc   := SortedLocales[A_Index]
		iIcon := FlagIndexMap.Has(loc.Code) ? FlagIndexMap[loc.Code] : 0
		lv.Add("Icon" iIcon, loc.Name)
	}
	; Subtract scrollbar width (~17 px) so the column never triggers horizontal overflow
	lv.ModifyCol(1, ContentW - 20)
	; Resize the ListView so it shows exactly min(N, 8) rows with no bottom
	; "white stripe" when scrolled to the end. We measure the control's natural
	; row height via LVM_GETITEMRECT (0x100E), then set the outer height to
	; ``visRows × rowH + 2 × SM_CYEDGE`` so the client area is an exact multiple
	; of the row height (no partial row).
	; ROOT CAUSE of the historical white stripe: the border term used
	; GetSystemMetrics(13) — that is SM_CXCURSOR (~32 px), NOT the 3D client
	; edge. It padded the control by ~64 px instead of ~4 px, leaving a blank
	; band below the last row. The correct index is SM_CYEDGE (46).
	; NOTE: LVM_APPROXIMATEVIEWRECT (0x1041) was also tried for this, but sending
	; it to the not-yet-shown ListView crashed the script on this AHK build — the
	; index fix below removes the stripe without that message.
	; CRITICAL: we ALSO relocate the Next button by hand below because AHK's
	; "next control" position tracker is set when the LV is *added* (with the
	; initial h240) and is NOT updated by ``Move()`` — so a relative ``y+16`` on
	; the button would land it on top of the (now-shorter) LV.
	SM_CYEDGE := 46  ; GetSystemMetrics index for the 3D client-edge height
	RECT := Buffer(16, 0)
	SendMessage(0x100E, 0, RECT.Ptr, lv)  ; LVM_GETITEMRECT, item 0, LVIR_BOUNDS
	rowH := NumGet(RECT, 12, "Int") - NumGet(RECT, 4, "Int")  ; bottom - top
	if (rowH > 0) {
		maxRows := 8
		visRows := Min(SortedLocales.Length, maxRows)
		borderPx := 2 * DllCall("GetSystemMetrics", "Int", SM_CYEDGE, "Int")
		lv.Move(,, , visRows * rowH + borderPx)
	}
	; Pre-select the default locale row
	lv.Modify(DefaultIndex, "Select Focus Vis")

	; Single Next button anchored to the right edge — no Back button on step 1
	; because there is nothing to go back to. We snapshot the LV's actual
	; bottom edge AFTER the Move() above, then override the button's Y so it
	; sits 16 px below the LV regardless of what AHK's stale position tracker
	; might decide. Without this, the button overlaps the last visible row.
	lv.GetPos(, &_lvY, , &_lvH)
	btns := _Onboarding_AddNavButtons(g, "", t("onboarding.next"))
	btnNext := btns[2]
	; Centre the lone Next button under the list (the nav helper right-pins it
	; by default, which looks unbalanced on this single-button page).
	btnNext.GetPos(, , &_nextW, )
	btnNext.Move((ONBOARDING_WIN_W - _nextW) // 2, _lvY + _lvH + 16)
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, lv, SortedLocales, DefaultIndex))

	; Re-render the title, heading and button label in the previewed locale
	; whenever the selection changes. ItemSelect fires on every arrow key and
	; mouse movement (including deselect+select pairs per step), so we debounce:
	; the handler just arms a one-shot timer; the timer re-reads the focused row
	; at fire time, guaranteeing we always render the final resting position.
	global _ob_s1_lv, _ob_s1_refs
	_ob_s1_lv   := lv
	_ob_s1_refs := Map("headingText", headingText, "btn", btnNext, "SortedLocales", SortedLocales)
	lv.OnEvent("ItemSelect", _Step1_OnItemSelect)

	; Remap Left→Up and Right→Down inside the ListView so horizontal arrow
	; keys navigate the list the same way vertical ones do.
	; WM_KEYDOWN = 0x0100, VK_LEFT = 0x25, VK_RIGHT = 0x27,
	; VK_UP = 0x26, VK_DOWN = 0x28.
	global _ob_s1_lv_hwnd := lv.Hwnd
	OnMessage(0x0100, _Step1_LvKeyDown)

	; Immediately render in the pre-selected locale — Modify(Select) does not
	; fire ItemSelect, so we invoke the handler manually with the default row.
	_Step1_RenderLocale(DefaultIndex)

	_Onboarding_Show(g)
	global _ob_gui := g
}

; ItemSelect fires on every arrow key / mouse move (including deselect events).
; We only arm the debounce timer here — never render directly — so rapid
; navigation through the list doesn't trigger a FileRead+JsonParse per step.
_Step1_OnItemSelect(*) {
	global _ob_s1_debounce_ms
	; Negative period = one-shot after the delay; re-arming cancels any pending call.
	SetTimer(_Step1_DebounceRender, -_ob_s1_debounce_ms)
}

; Fired by the debounce timer. Re-reads the focused row from the ListView at
; this moment so we always render whatever row the user actually landed on,
; regardless of how many ItemSelect events were queued before us.
_Step1_DebounceRender(*) {
	global _ob_s1_lv, _ob_s1_refs
	if !IsSet(_ob_s1_lv) or !IsSet(_ob_s1_refs)
		return
	row := _ob_s1_lv.GetNext(0, "Focused")
	if row > 0
		_Step1_RenderLocale(row)
}

; Does the actual translate + assign. Separated so the initial manual call
; (before ItemSelect is wired) and the debounce path share one implementation.
_Step1_RenderLocale(row) {
	global _ob_s1_refs
	if !IsSet(_ob_s1_refs)
		return
	SortedLocales := _ob_s1_refs["SortedLocales"]
	headingText   := _ob_s1_refs["headingText"]
	btn           := _ob_s1_refs["btn"]
	if row <= 0 or row > SortedLocales.Length
		return
	Code := SortedLocales[row].Code
	try _ob_s1_refs["headingText"].Text := _Onboarding_Translate(Code, "onboarding.welcome.heading")
	try _ob_s1_refs["btn"].Text         := _Onboarding_Translate(Code, "onboarding.next")
	; Window title needs the Gui ref — fetch it from the global
	global _ob_gui
	if (_ob_gui != 0)
		try _ob_gui.Title := _Onboarding_Translate(Code, "onboarding.welcome.title")
}

; WM_KEYDOWN handler — translates Left→Up and Right→Down inside the step-1
; ListView so horizontal arrow keys navigate the language list identically to
; the vertical ones. Registered only while step 1 is active; unregistered by
; _Onboarding_DestroyActive before the Gui is torn down.
_Step1_LvKeyDown(wParam, lParam, msg, hwnd) {
	global _ob_s1_lv_hwnd
	; Only act when the message targets our ListView
	if (hwnd != _ob_s1_lv_hwnd)
		return
	; VK_LEFT (0x25) → synthesise VK_UP (0x26); VK_RIGHT (0x27) → VK_DOWN (0x28)
	if (wParam = 0x25 or wParam = 0x27) {
		replacement := (wParam = 0x25) ? 0x26 : 0x28
		PostMessage(0x0100, replacement, lParam, , "ahk_id " _ob_s1_lv_hwnd)
		return 0   ; Suppress the original Left/Right key
	}
}

_Step1_Next(g, lv, SortedLocales, DefaultIndex, *) {
	; Get the selected row index (1-based); fall back to default if none selected
	selectedIndex := DefaultIndex
	row := lv.GetNext(0, "Focused")
	if row > 0
		selectedIndex := row

	locale := SortedLocales[selectedIndex]
	global _ob_locale := locale.Code

	; Switch locale in memory only — avoid Reload during the wizard
	global _I18nLocale, _I18nCacheLoaded
	_I18nLocale := locale.Code
	_I18nCacheLoaded := false

	_Onboarding_Navigate(_Onboarding_StepConfigDir)
}


; ===========================================================
; ===== 4.1b) Step 1b — Config folder selection ==========
; ===========================================================

; New step inserted between locale (step 1) and layout (step 2). Lets the
; user point Ergopti at a custom personal-data folder during first-run,
; instead of accepting the default ``%USERPROFILE%\.config\ergopti_plus\``.
; Useful for users who keep their dotfiles on a synced volume (Dropbox,
; OneDrive, …) — they can route ALL Ergopti data into that volume from
; day one without manually editing paths.toml after the fact.
;
; The selection is committed to paths.toml in _Onboarding_Commit alongside
; the other wizard answers; the subsequent Reload re-evaluates paths.toml
; so every module picks up the new location.
_Onboarding_StepConfigDir() {
	global _ob_config_dir, _ConfigDir
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 2 of 6.
	_Onboarding_AddProgressDots(g, 2)

	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("dialog.config_folder.title")))
	g.SetFont("s10 norm")
	g.SetFont("s8")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+4", t("dialog.config_folder.hint"))
	g.SetFont("s10 norm")

	; Row 1: short label + Browse on the same line. The previous "Personal
	; configuration folder:" label was a near-duplicate of the title above, so
	; we shortened it (``dialog.config_folder.label`` now reads "Path:" or
	; equivalent in each locale) and put Browse next to it. Auto-sized so long
	; localised "Browse" captions (German "Durchsuchen") never clip.
	g.SetFont("s9")
	lblPath := g.AddText("xm y+10", t("dialog.config_folder.label"))
	g.SetFont("s10")
	btnBrowse := g.AddButton("x+8 yp", t("common.browse"))
	; Vertical alignment: the text and the button have different heights
	; (s9 text ~16 px vs default button ~28 px), so ``yp`` only aligns them
	; on their top edge — the smaller text visually floats above the
	; button's center. Move the label down so both controls share a centre
	; line, the optical alignment a reader actually expects.
	btnBrowse.GetPos(, &_alignBtnY, , &_alignBtnH)
	lblPath.GetPos(, , , &_alignLblH)
	lblPath.Move(, _alignBtnY + (_alignBtnH - _alignLblH) // 2)

	; Row 2: full-width edit on its own line so the user sees the entire
	; path even on a narrow window. Forward slashes display cleaner than the
	; native Windows ``\`` and match paths.toml's on-disk format — we swap
	; back to backslashes before persisting.
	current := _ob_config_dir != "" ? _ob_config_dir : (IsSet(_ConfigDir) ? _ConfigDir : "")
	dirEdit := g.AddEdit("xm y+6 w" ONBOARDING_WIN_W - 40, StrReplace(current, "\", "/"))

	g.SetFont("s10")

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]

	btnBrowse.OnEvent("Click", _StepConfigDir_Browse.Bind(g, dirEdit))
	btnBack.OnEvent("Click",   _StepConfigDir_Back.Bind(g))
	btnNext.OnEvent("Click",   _StepConfigDir_Next.Bind(g, dirEdit))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_StepConfigDir_Browse(g, dirEdit, *) {
	; Seed the picker from the current edit value when it's a real folder;
	; otherwise fall back to %USERPROFILE% so the dialog opens somewhere
	; familiar. Convert back to backslashes for DirSelect's native format.
	startDir := StrReplace(Trim(dirEdit.Value), "/", "\")
	if (startDir == "" or !DirExist(startDir))
		startDir := A_MyDocuments
	; The wizard window is +AlwaysOnTop so it never gets occluded by other
	; apps mid-setup. But ``DirSelect`` opens a *system* shell dialog which
	; honours topmost z-order too, and on Windows the parent topmost wins
	; the tie — leaving the picker entirely behind the wizard and the user
	; staring at a frozen UI. Drop the wizard's topmost flag for the
	; duration of the picker, then restore it afterwards (try-wrapped so a
	; user-cancel still re-arms AlwaysOnTop instead of leaving the wizard
	; demoted to a normal window).
	try g.Opt("-AlwaysOnTop")
	selected := ""
	try {
		selected := DirSelect("*" . startDir, 1, t("dialog.config_folder.select_title"))
	}
	try g.Opt("+AlwaysOnTop")
	if (selected != "") {
		selected := StrReplace(selected, "\", "/")
		if !RegExMatch(selected, "/$")
			selected .= "/"
		dirEdit.Value := selected
	}
}

_StepConfigDir_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step1)
}

_StepConfigDir_Next(g, dirEdit, *) {
	global _ob_config_dir
	; Normalise: trim, swap forward slashes to backslashes (AHK-native),
	; ensure trailing slash. An empty input means "use the OS default" —
	; we store "" and the commit step will write a commented-out line to
	; paths.toml so the boot resolver picks the default again.
	val := Trim(dirEdit.Value)
	if (val != "") {
		val := StrReplace(val, "/", "\")
		if !RegExMatch(val, "\\$")
			val .= "\"
	}
	_ob_config_dir := val

	; If the chosen folder already contains a config.toml, pre-fill the
	; remaining wizard answers from it so a user who points the wizard at
	; a previously-configured folder (e.g. after reinstalling on a new
	; machine and selecting their synced Dropbox folder) does not have to
	; re-pick the same options manually. Empty path → keep wizard defaults.
	_Onboarding_PreloadFromExistingConfig(val)

	_Onboarding_Navigate(_Onboarding_Step2)
}


; ===================================================
; ===== 4.1c) Pre-fill from existing config.toml ====
; ===================================================

; Inspect ``<chosen_dir>\ahk\config.toml`` and, if it exists, hydrate the
; wizard globals so steps 2-5 open pre-selected with the user's previous
; choices rather than the bare defaults. Used so a returning user can
; click Next-Next-Next on familiar settings instead of re-picking every
; option from scratch. Best-effort: any parse failure is logged and the
; wizard falls back to the defaults that were set at the top of this file.
;
; @param ChosenDir string Backslash-terminated absolute folder picked on the
;                         config-dir step. Empty → no pre-fill (default path).
_Onboarding_PreloadFromExistingConfig(ChosenDir) {
	global _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures, _DefaultConfigDir
	global _ob_magic_key_explicit
	; Resolve the actual folder we're about to read from: empty input means
	; "use the OS default", so we hydrate from that location too — this lets
	; an existing first-run user re-open the wizard from the tray menu and
	; still see their saved choices.
	Dir := (ChosenDir != "") ? ChosenDir : (IsSet(_DefaultConfigDir) ? _DefaultConfigDir : "")
	if (Dir == "")
		return
	global _AhkSubDir
	CfgPath := Dir . _AhkSubDir . "config.toml"
	if !FileExist(CfgPath) {
		try LoggerDebug("onboarding", "No existing config at '{1}' — wizard keeps defaults.", CfgPath)
		return
	}
	try LoggerTrace("onboarding", "Pre-loading wizard answers from '{1}'…", CfgPath)
	Cache := ""
	try {
		Cache := ParseTomlFile(CfgPath)
	} catch as e {
		try LoggerWarn("onboarding", "Could not parse existing config — wizard keeps defaults: {1}.", e.Message)
		try LoggerDone("onboarding", "Wizard answer preload finished with parse fallback.")
		return
	}
	if Type(Cache) != "Map" {
		try LoggerWarn("onboarding", "Unexpected TOML cache type — wizard keeps defaults.")
		try LoggerDone("onboarding", "Wizard answer preload finished with type fallback.")
		return
	}

	; Layout: any of the three Ergopti switches ON means the user previously
	; enabled the Ergopti emulation. The wizard treats this as a single yes/no
	; choice so a partial state (only ergopti_alt_gr on, etc.) still flips Yes.
	LayoutBase  := IniCacheGet(Cache, "ahk.layout", "ergopti_base")
	LayoutAltGr := IniCacheGet(Cache, "ahk.layout", "ergopti_alt_gr")
	LayoutPlus  := IniCacheGet(Cache, "ahk.layout", "ergopti_plus")
	if (LayoutBase != "_" or LayoutAltGr != "_" or LayoutPlus != "_") {
		_ob_layout := TomlCacheBool(Cache, "ahk.layout", "ergopti_base")
			or TomlCacheBool(Cache, "ahk.layout", "ergopti_alt_gr")
			or TomlCacheBool(Cache, "ahk.layout", "ergopti_plus")
	}

	; Magic key: TOML strings come in with surrounding quotes already stripped
	; by the parser, so the cache value is the raw character.
	MagicKey := IniCacheGet(Cache, "hotstrings", "trigger_char")
	if (MagicKey != "_" and MagicKey != "") {
		_ob_magic_key := MagicKey
		_ob_magic_key_explicit := true
	}

	; Metrics + gestures: boolean flags. ParseTomlFile coerces TOML's `true` to a
	; real AHK boolean, so these must go through TomlCacheBool — a string compare
	; against "true" is always false and would read every enabled setting as off.
	MetricsEnabled := IniCacheGet(Cache, "ahk.metrics", "metrics_enabled")
	if (MetricsEnabled != "_") {
		_ob_metrics := TomlCacheBool(Cache, "ahk.metrics", "metrics_enabled")
	}
	GesturesEnabled := IniCacheGet(Cache, "ahk.gestures", "enabled")
	if (GesturesEnabled != "_") {
		_ob_gestures := TomlCacheBool(Cache, "ahk.gestures", "enabled")
	}

	try LoggerDone("onboarding", "Wizard pre-loaded (layout={1}, magic='{2}', metrics={3}, gestures={4}).",
		_ob_layout ? "true" : "false", _ob_magic_key,
		_ob_metrics ? "true" : "false", _ob_gestures ? "true" : "false")
}
