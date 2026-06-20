; ui/onboarding/steps.ahk

; ==============================================================================
; MODULE: Onboarding / Wizard Step Implementations
; DESCRIPTION:
; The five wizard steps and their sub-steps: language selection, config-folder selection, pre-fill from an existing config.toml, Ergopti layout, magic-key binding, typing metrics and trackpad gestures.
;
; Split out of the former lib/onboarding.ahk (P5 refactor); see
; ui/onboarding/init.ahk for the module overview. Functions and globals are
; hoisted, so load order across the onboarding/*.ahk files is irrelevant.
; ==============================================================================





; ==========================================
; =======================================
; ======= 4/ Step implementations =======
; =======================================
; ==========================================



; ============================================
; ===== 4.1) Step 1 — Language selection =====
; ============================================

_Onboarding_Step1() {
	global _StaticDir, _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures, _ob_register_pending
	_ob_layout            := false
	_ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
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
		return
	}
	if Type(Cache) != "Map" {
		try LoggerWarn("onboarding", "Unexpected TOML cache type — wizard keeps defaults.")
		return
	}

	; Layout: any of the three Ergopti switches ON means the user previously
	; enabled the Ergopti emulation. The wizard treats this as a single yes/no
	; choice so a partial state (only ergopti_alt_gr on, etc.) still flips Yes.
	LayoutBase  := IniCacheGet(Cache, "ahk.layout", "ergopti_base")
	LayoutAltGr := IniCacheGet(Cache, "ahk.layout", "ergopti_alt_gr")
	LayoutPlus  := IniCacheGet(Cache, "ahk.layout", "ergopti_plus")
	if (LayoutBase != "_" or LayoutAltGr != "_" or LayoutPlus != "_") {
		_ob_layout := (StrLower(LayoutBase) == "true")
			or (StrLower(LayoutAltGr) == "true")
			or (StrLower(LayoutPlus) == "true")
	}

	; Magic key: TOML strings come in with surrounding quotes already stripped
	; by the parser, so the cache value is the raw character.
	MagicKey := IniCacheGet(Cache, "hotstrings", "trigger_char")
	if (MagicKey != "_" and MagicKey != "") {
		_ob_magic_key := MagicKey
	}

	; Metrics + gestures: boolean flags. ParseTomlFile preserves TOML's
	; literal "true"/"false" strings so a case-insensitive compare suffices.
	MetricsEnabled := IniCacheGet(Cache, "ahk.metrics", "metrics_enabled")
	if (MetricsEnabled != "_") {
		_ob_metrics := (StrLower(MetricsEnabled) == "true")
	}
	GesturesEnabled := IniCacheGet(Cache, "ahk.gestures", "enabled")
	if (GesturesEnabled != "_") {
		_ob_gestures := (StrLower(GesturesEnabled) == "true")
	}

	try LoggerDone("onboarding", "Wizard pre-loaded (layout={1}, magic='{2}', metrics={3}, gestures={4}).",
		_ob_layout ? "true" : "false", _ob_magic_key,
		_ob_metrics ? "true" : "false", _ob_gestures ? "true" : "false")
}



; =================================================
; ===== 4.2) Step 2 — Ergopti keyboard layout =====
; =================================================

_Onboarding_Step2() {
	global _StaticDir
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Step 2 uses the WIDER ``ONBOARDING_STEP2_W`` so the layout preview JPG
	; renders larger — at the default 460 px wizard width, the keys were
	; barely readable.
	contentW := ONBOARDING_STEP2_W - 40
	; Progress dots — step 3 of 6 (centred on the wider canvas).
	_Onboarding_AddProgressDots(g, 3, ONBOARDING_STEP2_W)
	g.SetFont("s12 Bold")
	g.AddText("xm w" contentW " y+12 Center", _Onboarding_StripBrand(t("onboarding.layout.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" contentW " y+8", t("onboarding.layout.desc"))
	g.SetFont("s10")

	; Visual preview of the Ergopti layout — picking it blind from a one-line
	; description ("Yes/No, use Ergopti layout") makes the user guess what they
	; are agreeing to. AHK scales the JPG to the requested width while
	; preserving aspect ratio (``h-1``). The picture is best-effort: if the
	; static dir is unreachable (e.g. an unusual install), we log and skip so
	; the rest of the step still renders. The build_static_bundle ASSET_FILES
	; entry ships ``ergopti.jpg`` next to the EXE in compiled mode.
	imgPath := _StaticDir . "\img\ergopti.jpg"
	if FileExist(imgPath) {
		try {
			g.AddPicture("xm w" contentW " h-1 y+10", imgPath)
		} catch as e {
			try LoggerWarn("onboarding", "Step 2: AddPicture failed for '{1}': {2}.", imgPath, e.Message)
		}
	} else {
		try LoggerWarn("onboarding", "Step 2: layout preview missing at '{1}' — wizard renders without it.", imgPath)
	}

	; Pre-check the radio matching the wizard state. When the user pointed
	; the wizard at an existing config in step 1b, _ob_layout reflects that
	; saved value; otherwise it stays at its boot default (false). Radios sit
	; flush against the image (no spacer text) per the user's preference for
	; a compact action area.
	global _ob_layout
	rYes := g.AddRadio("vLayoutChoice xm y+8" . (_ob_layout ? " Checked" : ""), t("onboarding.layout.yes"))
	rNo  := g.AddRadio((!_ob_layout ? "Checked " : "") . "y+2", t("onboarding.layout.no"))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]
	; The nav-button helper anchored Next to ONBOARDING_WIN_W by default.
	; Override to use the wider Step 2 width so the button sits at the right
	; edge of the larger canvas rather than floating in the middle.
	btnNext.GetPos(, , &_nextW_step2, )
	btnNext.Move(ONBOARDING_STEP2_W - 20 - _nextW_step2)

	btnBack.OnEvent("Click", _Step2_Back.Bind(g))
	btnNext.OnEvent("Click", _Step2_Next.Bind(g, rYes))

	_Onboarding_Show(g, ONBOARDING_STEP2_W)
	global _ob_gui := g
}

_Step2_Back(g, *) {
	; Back returns to the inserted config-folder step (was Step1 before
	; the picker was added between Step1 and Step2).
	_Onboarding_Navigate(_Onboarding_StepConfigDir)
}

_Step2_Next(g, rYes, *) {
	global _ob_layout := (rYes.Value = 1)
	_Onboarding_Navigate(_Onboarding_Step3)
}



; ===========================================
; ===== 4.3) Step 3 — Magic key binding =====
; ===========================================

; Returns the magic-key character that best matches the user's context:
;   - ★ when they enabled the Ergopti emulation on step 2 (the dedicated
;     key sits on the Ergopti+ layout, so ★ is the no-friction pick),
;   - ù when the Windows keyboard layout is AZERTY (LANGID == 0x040C —
;     French France), since ``;`` requires Shift+, on AZERTY and ù has
;     its own dedicated key,
;   - ``;`` otherwise (QWERTY family) — directly typeable on a single key.
; Falls back to the documented Ergopti default (★) when nothing matches.
_Onboarding_PickDefaultMagicKey() {
	global _ob_layout
	if (IsSet(_ob_layout) and _ob_layout)
		return "★"
	; Read the active KB layout. HKL = high 16 bits KLID + low 16 bits LANGID.
	try {
		hkl  := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
		lang := hkl & 0xFFFF
		if (lang == 0x040C)
			return "ù"
	}
	return ";"
}

_Onboarding_Step3() {
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 4 of 6.
	_Onboarding_AddProgressDots(g, 4)

	; Heading and short description — kept upright (no italic) so the page
	; reads as a regular form rather than a long block of quoted text.
	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("onboarding.magic_key.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.magic_key.desc"))
	g.SetFont("s10")

	; Three pre-baked picks (Ergopti+ / AZERTY / QWERTY) plus a free-form
	; "custom input" row whose Edit defaults to ``*`` — the ASCII star that
	; used to live on its own radio. Folding it into the custom slot keeps
	; the radio list shorter without losing the ASCII fallback for users
	; whose font cannot render ★ cleanly.
	;
	; ★ FIRST and pre-selected: it's the canonical Ergopti default (mapped
	; to a dedicated layout key) and the value the rest of the app already
	; calls "the magic key".
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+14", "")
	rBlackStar := g.AddRadio("vMK_BlackStar", t("onboarding.magic_key.option_blackstar"))
	rUGrave    := g.AddRadio("y+4",           t("onboarding.magic_key.option_ugrave"))
	rSemi      := g.AddRadio("y+4",           t("onboarding.magic_key.option_semicolon"))
	rCustom    := g.AddRadio("y+4",           t("onboarding.magic_key.option_custom"))

	; Indent the free-form input under the "Custom" radio so the visual
	; hierarchy makes it obvious the field belongs to that option. The
	; placeholder value is ``*`` because the dedicated ASCII-star radio
	; was retired (folded into this row) and ``*`` remains the canonical
	; fallback when ★ does not render comfortably.
	edInitial := (_ob_magic_key != "" and _ob_magic_key != ONBOARDING_DEFAULT_MAGIC_KEY
		and _ob_magic_key != "ù" and _ob_magic_key != ";")
		? _ob_magic_key : "*"
	edKey := g.AddEdit("w120 x40 y+4 vMagicKeyEdit", edInitial)

	; Pre-select whichever radio matches the persisted/default value. The
	; user has been through step 2 by now, so we know whether they chose
	; the Ergopti emulation; combined with the system KB layout, that's
	; enough to pick a sensible default per the contract documented in
	; _Onboarding_PickDefaultMagicKey.
	default_key := _Onboarding_PickDefaultMagicKey()
	current_key := (_ob_magic_key != "" and _ob_magic_key != ONBOARDING_DEFAULT_MAGIC_KEY)
		? _ob_magic_key
		: default_key
	; Persist so Back/Next preserves the choice even when the user only
	; navigated past this step without explicitly clicking a radio.
	global _ob_magic_key := current_key
	switch current_key {
		case "★": rBlackStar.Value := 1
		case "ù": rUGrave.Value    := 1
		case ";": rSemi.Value      := 1
		default:
			; Anything that is not one of the three pre-baked picks (★ / ù / ;)
			; lands on the custom-input row — including the historical ``*``,
			; which now lives inside the Edit field rather than its own radio.
			rCustom.Value := 1
	}
	; The Edit is only meaningful when "Custom" is selected — disable it
	; otherwise so the user can't accidentally type into an inert field.
	edKey.Enabled := (rCustom.Value = 1)

	; Wire every radio so flipping selection enables/disables the Edit live.
	for r in [rBlackStar, rUGrave, rSemi, rCustom] {
		r.OnEvent("Click", _Step3_OnRadioClick.Bind(rCustom, edKey))
	}

	; Closing reminder — the ONLY italic line on this page, deliberately so it
	; reads as a softer side-note rather than another header.
	g.SetFont("s9 italic")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+14", t("onboarding.magic_key.choose_freely"))
	g.SetFont("s10 norm")

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]

	btnBack.OnEvent("Click", _Step3_Back.Bind(g))
	btnNext.OnEvent("Click", _Step3_Next.Bind(g, rBlackStar, rUGrave, rSemi, rCustom, edKey))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step3_OnRadioClick(rCustom, edKey, *) {
	; Selecting any radio updates the Custom flag implicitly because radios
	; share the same group; we just mirror that into the Edit's Enabled state.
	try edKey.Enabled := (rCustom.Value = 1)
	if (rCustom.Value = 1) {
		try edKey.Focus()
	}
}

_Step3_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step2)
}

_Step3_Next(g, rBlackStar, rUGrave, rSemi, rCustom, edKey, *) {
	val := ""
	if (rBlackStar.Value = 1) {
		val := "★"
	} else if (rUGrave.Value = 1) {
		val := "ù"
	} else if (rSemi.Value = 1) {
		val := ";"
	} else if (rCustom.Value = 1) {
		; The custom Edit defaults to ``*`` so a user who picks "Custom
		; input" but never edits the field still ends up with the historical
		; ASCII-star fallback that used to live on its own radio.
		val := Trim(edKey.Value)
	}
	; Fall back to the ★ default so the config always has a non-empty
	; value — also commits the choice into the wizard state so the next
	; step + the final TOML batch write see the same character.
	if (val == "")
		val := ONBOARDING_DEFAULT_MAGIC_KEY
	global _ob_magic_key := val
	_Onboarding_Navigate(_Onboarding_Step4)
}



; ========================================
; ===== 4.4) Step 4 — Typing metrics =====
; ========================================

_Onboarding_Step4() {
	global _ConfigDir
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 5 of 6.
	_Onboarding_AddProgressDots(g, 5)

	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("onboarding.metrics.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.metrics.desc"))

	; The shared keylogger warning string uses ``%s`` (printf-style) so the same
	; text works on Hammerspoon (Lua's string.format) and AHK. AHK v2's
	; Format() expects {1}-style placeholders and would leave ``%s`` verbatim,
	; so the substitution is done with StrReplace here.
	; Normalise the path with forward slashes — the cross-platform locale string
	; is shared with the Hammerspoon driver, where macOS already uses ``/``;
	; matching that style on Windows keeps the displayed path consistent across
	; both drivers and avoids the visual clutter of Windows backslashes inside
	; the red warning block.
	metrics_path := StrReplace(_ConfigDir . "metrics", "\", "/")
	warning := Format(t("dialog.metrics.enable_warning"), metrics_path)
	; Warning: plain orange text between two horizontal rules — simpler and reliable.
	g.AddText("xm y+10 w" ONBOARDING_WIN_W - 40 " 0x10")  ; SS_ETCHEDHORZ — top separator
	g.SetFont("s9 norm", "Segoe UI")
	g.AddText("xm y+6 w" ONBOARDING_WIN_W - 40 " cFF8C00", Chr(0x26A0) " " warning)
	g.SetFont("s10 norm", "Segoe UI")
	g.AddText("xm y+6 w" ONBOARDING_WIN_W - 40 " 0x10")  ; SS_ETCHEDHORZ — bottom separator

	global _ob_metrics
	rYes := g.AddRadio("vMetricsChoice xm y+10" . (_ob_metrics ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((!_ob_metrics ? "Checked " : "") . "y+2", t("onboarding.no"))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]

	btnBack.OnEvent("Click", _Step4_Back.Bind(g))
	btnNext.OnEvent("Click", _Step4_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step4_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step3)
}

_Step4_Next(g, rYes, *) {
	global _ob_metrics := (rYes.Value = 1)
	_Onboarding_Navigate(_Onboarding_Step5)
}



; ===========================================
; ===== 4.5) Step 5 — Trackpad gestures =====
; ===========================================

_Onboarding_Step5() {
	g := Gui("+AlwaysOnTop", t("onboarding.welcome.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := ONBOARDING_MARGIN_Y

	; Progress dots — step 6 of 6.
	_Onboarding_AddProgressDots(g, 6)

	g.SetFont("s12 Bold")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+12 Center", _Onboarding_StripBrand(t("onboarding.gestures.title")))
	g.SetFont("s9 norm")
	g.AddText("xm w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.gestures.desc"))
	g.SetFont("s10")

	; Restore the previously-saved Yes/No when the wizard was re-opened over
	; an existing config (pre-load step in _StepConfigDir_Next).
	global _ob_gestures
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vGesturesChoice xm" . (_ob_gestures ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((!_ob_gestures ? "Checked " : "") . "y+2", t("onboarding.no"))

	; Registration panel — only visible when "Yes" is selected. We pre-build
	; every control as hidden so the layout does not jump when the user clicks
	; the radio buttons; visibility is toggled by _Step5_OnRadioChange.
	; All controls anchored xm so they align flush with the left margin.
	panelW := ONBOARDING_WIN_W - 40
	g.AddText("xm w" panelW " y+10 Hidden", "")
	regSectionLbl := g.AddText("xm w" panelW " Hidden",
		t("onboarding.gestures.register_section"))

	btnRegAuto := g.AddButton("xm w" panelW " y+6 Hidden",
		t("onboarding.gestures.register_auto"))
	g.SetFont("s8 italic")
	autoHint := g.AddText("xm w" panelW " y+4 Hidden",
		t("onboarding.gestures.register_auto_hint"))
	g.SetFont("s10 norm")

	btnRegManual := g.AddButton("xm w" panelW " y+6 Hidden",
		t("onboarding.gestures.register_manual"))
	g.SetFont("s8 italic")
	manualHint := g.AddText("xm w" panelW " y+4 Hidden",
		t("onboarding.gestures.register_manual_hint"))
	g.SetFont("s10 norm")

	; Status feedback (success / failure) sits below the buttons — also hidden
	; until the user actually triggers a registration attempt.
	statusLbl := g.AddText("w" ONBOARDING_WIN_W - 40 " y+10 Hidden", "")

	regControls := [regSectionLbl, btnRegAuto, autoHint, btnRegManual, manualHint]

	; Toggling visibility on radio change keeps the wizard tidy when the user
	; declines gesture support (the configuration step is irrelevant in that case).
	rYes.OnEvent("Click", _Step5_OnRadioChange.Bind(regControls, statusLbl, true))
	rNo.OnEvent("Click",  _Step5_OnRadioChange.Bind(regControls, statusLbl, false))

	; When the wizard was re-opened over an existing config that had gestures
	; enabled, mirror the auto-checked Yes radio by showing the registration
	; panel right away — otherwise the user sees Yes ticked but no controls.
	if _ob_gestures {
		_Step5_OnRadioChange(regControls, statusLbl, true)
	}

	btnRegAuto.OnEvent("Click",   _Step5_AutoRegister.Bind(statusLbl))
	btnRegManual.OnEvent("Click", _Step5_ShowManualTutorial.Bind(g))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.finish"))
	btnBack   := btns[1]
	btnFinish := btns[2]

	btnBack.OnEvent("Click", _Step5_Back.Bind(g))
	btnFinish.OnEvent("Click", _Step5_Finish.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step5_OnRadioChange(regControls, statusLbl, isYes, *) {
	for ctrl in regControls {
		try ctrl.Visible := isYes
	}
	; Clear any stale success/failure status when the user flips back to No
	if !isYes {
		try statusLbl.Visible := false
		try statusLbl.Text    := ""
	}
}

_Step5_AutoRegister(statusLbl, *) {
	; Run the gesture auto-configuration SYNCHRONOUSLY via PowerShell so the
	; user sees a definitive red/green status the moment they click — no more
	; "will be configured on next start" deferred path. The PS script is
	; self-contained (it hardcodes the same registry value set that
	; modules/gestures.ahk would write) so this works at first-launch BEFORE
	; the gestures module's #Include block has had a chance to assign its
	; GESTURE_REG_* globals.
	;
	; A single elevated PowerShell does both halves (registry writes + the
	; touchpad PnP cycle), so the user sees ONE UAC prompt and the brief
	; ~2 s freeze that follows. We do not pre-update the status label to
	; "Configuring…" because RunWait blocks the message loop — the user
	; would never see the intermediate state.
	;
	; Implementation note: the previous version inlined the PS via
	; ``powershell -Command "…"`` and ran into argv-quoting / backtick
	; pitfalls — the script launched but silently exited without doing any
	; work. We now write the script to a temp ``.ps1`` file and invoke it
	; with ``-File``, which sidesteps every shell-quoting question.
	global _ob_register_pending := false  ; never defer anymore

	ScriptPath := A_Temp . "\ergopti_gesture_config.ps1"
	try {
		if FileExist(ScriptPath)
			FileDelete(ScriptPath)
		FileAppend(_Onboarding_BuildGesturePsScript(), ScriptPath, "UTF-8")
	} catch as e {
		try LoggerError("onboarding", "Could not write gesture PS script to '{1}': {2}.", ScriptPath, e.Message)
		_Step5_ShowGestureStatus(statusLbl, false)
		return
	}

	exitCode := -1
	try {
		exitCode := RunWait('*RunAs powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . ScriptPath . '"', , "Hide")
	} catch as e {
		try LoggerError("onboarding", "Gesture auto-config powershell threw: {1}.", e.Message)
		exitCode := -1
	}

	; Clean up the temp script so the user doesn't accumulate junk in %TEMP%.
	try FileDelete(ScriptPath)

	if (exitCode == 0) {
		try LoggerSuccess("onboarding", "Gesture auto-configuration succeeded.")
		_Step5_ShowGestureStatus(statusLbl, true)
	} else {
		try LoggerWarn("onboarding", "Gesture auto-configuration failed (exitCode={1}).", exitCode)
		_Step5_ShowGestureStatus(statusLbl, false)
	}
}

; Paints the status label red or green and makes it visible. Each call site
; (success / failure) was previously identical bar one constant, so we extract
; the duplication into this helper. The label was created with the ``Hidden``
; option so we explicitly clear that AND set ``.Visible := true`` — relying on
; the property alone has bitten us before when the layout reflowed.
;
; ALSO fires a MsgBox as a guaranteed fallback. Several users have reported
; "PowerShell flashes then nothing happens" — i.e. the status label never
; updated visibly. Whether that is a control-state bug, an autosize edge case
; or just the label being below the fold, the MsgBox makes sure the user
; ALWAYS gets a definitive confirmation that the registration finished.
;
; ``ok = true`` renders the success message in green; ``false`` paints failure
; in red. The translation key — not the literal message — is chosen up front
; so the locale's wording always wins over any cached string.
_Step5_ShowGestureStatus(statusLbl, ok) {
	Key := ok ? "onboarding.gestures.register_success" : "onboarding.gestures.register_failed"
	Color := ok ? "cGreen" : "cRed"
	Msg := t(Key)
	try statusLbl.Opt("-Hidden")
	try statusLbl.SetFont("s9 " . Color)
	try statusLbl.Text    := Msg
	try statusLbl.Visible := true
	try statusLbl.Redraw()
	; Guaranteed visible feedback — see comment above.
	try MsgBox(Msg, t("onboarding.gestures.title"), ok ? "Iconi" : "Icon!")
}

; Builds a self-contained PowerShell script that writes every PrecisionTouchPad
; registry value AND restarts the touchpad PnP device so the new gesture map
; takes effect without a logout. Values are hardcoded inline — they mirror the
; ``GESTURE_REG_*`` maps in modules/gestures.ahk but live here so the wizard
; can call them before that module's auto-execute runs. Keep both copies in
; sync when adding / changing gesture slots.
;
; The returned text is a full .ps1 script (multi-line, comments allowed)
; written to a temp file by the caller — running it via ``-File`` avoids the
; argv-quoting issues that plagued the previous ``-Command`` inline variant.
_Onboarding_BuildGesturePsScript() {
	; KeyParams encoding: (VK << 16) | 0x07 where 0x07 = Ctrl|Shift|Win.
	; F1..F10 = 0x70..0x79. The script is assembled line-by-line instead of
	; via a multi-line continuation section because the latter — combined
	; with embedded ``foreach (...)`` lines — triggers a fail-fast crash
	; (STATUS_STACK_BUFFER_OVERRUN, 0xC0000409) during AHK v2's continuation-
	; section parser. Concatenating with explicit ``\`r\`n`` separators keeps
	; the parser happy AND yields identical .ps1 content on disk.
	CRLF := "`r`n"
	S := ""
	S .= "$ErrorActionPreference = 'Stop'" . CRLF
	S .= "$Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad'" . CRLF
	; Create the PrecisionTouchPad key if missing (machines that never had a
	; precision touchpad driver loaded won't have it). Without this guard,
	; Set-ItemProperty -Force still fails with "Cannot find path" and the
	; whole script bails out before any value is written. -Force on New-Item
	; makes the call idempotent so it's safe when the key already exists.
	S .= "if (-not (Test-Path $Reg)) { New-Item -Path $Reg -Force | Out-Null }" . CRLF
	S .= "$V = @{" . CRLF
	; Master enables — turn the gesture families on
	S .= "  'ThreeFingerSlideEnabled' = 65535" . CRLF
	S .= "  'ThreeFingerTapEnabled'   = 65535" . CRLF
	S .= "  'FourFingerSlideEnabled'  = 65535" . CRLF
	S .= "  'FourFingerTapEnabled'    = 65535" . CRLF
	; Per-direction enables (swipe slots only)
	S .= "  'ThreeFingerUp'    = 65535" . CRLF
	S .= "  'ThreeFingerDown'  = 65535" . CRLF
	S .= "  'ThreeFingerLeft'  = 65535" . CRLF
	S .= "  'ThreeFingerRight' = 65535" . CRLF
	S .= "  'FourFingerUp'     = 65535" . CRLF
	S .= "  'FourFingerDown'   = 65535" . CRLF
	S .= "  'FourFingerLeft'   = 65535" . CRLF
	S .= "  'FourFingerRight'  = 65535" . CRLF
	; CustomXFingerTap = 7 sentinel (user-defined shortcut)
	S .= "  'CustomThreeFingerTap' = 7" . CRLF
	S .= "  'CustomFourFingerTap'  = 7" . CRLF
	; KeyParams — Fn key encoding for each slot (Ctrl+Win+Shift+Fn)
	S .= "  'CustomThreeFingerTapKeyParams' = 7340039"  . CRLF  ; F1
	S .= "  'ThreeFingerUpKeyParams'        = 7405575"  . CRLF  ; F2
	S .= "  'ThreeFingerDownKeyParams'      = 7471111"  . CRLF  ; F3
	S .= "  'ThreeFingerLeftKeyParams'      = 7536647"  . CRLF  ; F4
	S .= "  'ThreeFingerRightKeyParams'     = 7602183"  . CRLF  ; F5
	S .= "  'CustomFourFingerTapKeyParams'  = 7667719"  . CRLF  ; F6
	S .= "  'FourFingerUpKeyParams'         = 7733255"  . CRLF  ; F7
	S .= "  'FourFingerDownKeyParams'       = 7798791"  . CRLF  ; F8
	S .= "  'FourFingerLeftKeyParams'       = 7864327"  . CRLF  ; F9
	S .= "  'FourFingerRightKeyParams'      = 7929863"  . CRLF  ; F10
	; *Action = 65535 disables the new-system actions so KeyParams wins
	S .= "  'ThreeFingerTapAction'        = 65535" . CRLF
	S .= "  'ThreeFingerSlideUpAction'    = 65535" . CRLF
	S .= "  'ThreeFingerSlideDownAction'  = 65535" . CRLF
	S .= "  'ThreeFingerSlideLeftAction'  = 65535" . CRLF
	S .= "  'ThreeFingerSlideRightAction' = 65535" . CRLF
	S .= "  'FourFingerTapAction'         = 65535" . CRLF
	S .= "  'FourFingerSlideUpAction'     = 65535" . CRLF
	S .= "  'FourFingerSlideDownAction'   = 65535" . CRLF
	S .= "  'FourFingerSlideLeftAction'   = 65535" . CRLF
	S .= "  'FourFingerSlideRightAction'  = 65535" . CRLF
	S .= "}" . CRLF
	S .= "try {" . CRLF
	S .= "  foreach ($n in $V.Keys) {" . CRLF
	; New-ItemProperty -Force creates the property OR updates it in place.
	; Set-ItemProperty raises "Property X does not exist" on a first-time
	; PrecisionTouchPad key (one we may have just created above), which
	; aborts the whole script under $ErrorActionPreference='Stop'.
	S .= "    New-ItemProperty -Path $Reg -Name $n -Value $V[$n] -PropertyType DWord -Force | Out-Null" . CRLF
	S .= "  }" . CRLF
	S .= "  $devs = Get-PnpDevice -PresentOnly | Where-Object {" . CRLF
	S .= "    $_.Class -eq 'HIDClass' -and $_.FriendlyName -match 'Input Configuration|I2C HID'" . CRLF
	S .= "  }" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  Start-Sleep -Milliseconds 500" . CRLF
	S .= "  foreach ($d in $devs) {" . CRLF
	S .= "    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue" . CRLF
	S .= "  }" . CRLF
	S .= "  exit 0" . CRLF
	S .= "} catch {" . CRLF
	S .= "  exit 1" . CRLF
	S .= "}" . CRLF
	return S
}

_Step5_ShowManualTutorial(parentGui, *) {
	; Single source of truth lives in modules/gestures.ahk — both the tray
	; menu's "Manual tutorial" item and this wizard button render the same
	; popup (tutorial body + in-panel "Open touchpad settings" button).
	GestureShowManualTutorialDialog()
}

_Step5_Back(g, *) {
	_Onboarding_Navigate(_Onboarding_Step4)
}

_Step5_Finish(g, rYes, *) {
	global _ob_gestures := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Commit()
}





