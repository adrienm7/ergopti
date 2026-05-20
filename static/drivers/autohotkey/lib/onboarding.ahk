; drivers/autohotkey/lib/onboarding.ahk

; ==============================================================================
; MODULE: Onboarding Wizard
; DESCRIPTION:
; Displays a multi-step first-run wizard that guides the user through the
; initial configuration of ErgoptiPlus when no config.toml is found.
;
; FEATURES & RATIONALE:
; 1. First-Run Detection: Called by ErgoptiPlus.ahk before any feature is
;    activated — if ConfigurationFile does not exist, the wizard must run
;    before the script can operate.
; 2. Page-as-Destroy Pattern: Each wizard step destroys the current Gui and
;    creates a fresh one. This avoids the complexity of hiding/showing groups
;    of controls and keeps each page self-contained.
; 3. Locale-Live-Switch: Selecting a language on step 1 immediately re-renders
;    the title, heading and Next button in the previewed locale via the
;    transient cache-swap helper, so the user sees the wizard in their language
;    before even reaching step 2.
; 4. Atomic Write: All user choices are applied in a single TOML_BatchWrite
;    call at the end, then Reload is called once.
; ==============================================================================




; ================================================
; ================================================
; ======= 1/ Constants and wizard state =======
; ================================================
; ================================================

; Default locale index within I18N_LOCALES (1-based; English is index 4 — see
; the table in i18n.ahk: ar, cs, da, de, en, …). Pre-selecting English mirrors
; the historical default and reads as the safest fallback for an unknown user.
global ONBOARDING_DEFAULT_LOCALE_INDEX := 5

; Wizard window width (height is computed automatically from controls)
global ONBOARDING_WIN_W := 460

; Step 2 (layout preview) uses a wider canvas so the embedded keyboard
; layout JPG can be rendered closer to its native resolution — a 420 px-
; wide scale-down on the default window made the keys barely legible.
global ONBOARDING_STEP2_W := 820

; Height of the language ListView — fits ~8 rows, scrollable beyond that
global ONBOARDING_LV_H := 240

; Default magic key inserted into the Step 3 input.
; ★ (U+2605 BLACK STAR) is the canonical Ergopti default — it sits on a
; dedicated key in the Ergopti+ layout and the rest of the codebase
; (category.magic_key, dialog.magic_key.prompt, the auto-config menu)
; already labels it as "the magic key". The wizard pre-selects this
; option so a first-run user gets the documented default without any
; extra step; the other radios (``*`` / ``ù`` / ``;``) stay available
; as recommended fallbacks for non-Ergopti layouts.
global ONBOARDING_DEFAULT_MAGIC_KEY := "★"

; Collected answers — populated as the user advances through each step
global _ob_locale            := "en"
global _ob_layout            := false
global _ob_magic_key         := ONBOARDING_DEFAULT_MAGIC_KEY
global _ob_metrics           := false
global _ob_gestures          := false
; Config folder choice. Initialised to the current _ConfigDir so a re-run via
; the tray menu shows the user's existing location pre-filled. The first-run
; path inherits whatever paths.toml resolved at boot — typically the OS default
; (``%USERPROFILE%\.config\ergopti_plus\``) since the wizard runs precisely
; when paths.toml hasn't been customised yet.
global _ob_config_dir        := IsSet(_ConfigDir) ? _ConfigDir : ""
; When the user clicks "Auto-register" on the gestures step at first launch, the
; gestures module has not yet executed its top-level globals (Onboarding_Run is
; called early in ErgoptiPlus.ahk auto-exec, long before ``#Include modules/gestures.ahk``
; runs). Calling ``GestureAutoConfigureRegistry`` directly would crash on unset
; globals — so we record the intent here and flush a one-shot flag to config.toml
; in _Onboarding_Commit. The gestures module picks the flag up on the very next
; reload and performs the actual registry writes there.
global _ob_register_pending  := false

; Reference to the currently active wizard Gui object
global _ob_gui          := unset

; AltGr passthrough switch — read by ``IsRealAltGrPress`` in lib/layout/layout_altgr.ahk
; AND by ``IsOnboardingActive`` below. AHK promotes a key to a "prefix key" the
; moment any ``SC138 & X::`` combo is parsed, which costs SC138 (= AltGr) its
; native function. By making every related #HotIf variant evaluate to false we
; restore native behaviour for the duration of the wizard so the host Windows
; layout still produces its AltGr characters in the wizard's edit boxes (and
; anywhere else the user types while it is up). The wizard always exits via
; Reload or ExitApp so this flag never needs to be cleared by hand.
global _OB_ALTGR_PASSTHROUGH := false

; Public check used by other modules' #HotIf criteria to neutralise any
; AltGr-capturing hotkey (e.g. the RAlt tap-hold in modules/tap_holds.ahk)
; while the wizard is on screen. Standalone hotkeys disappear cleanly when
; their #HotIf returns false, restoring the OS-native AltGr typing path.
IsOnboardingActive() {
	global _OB_ALTGR_PASSTHROUGH
	return IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH
}




; =========================================
; =========================================
; ======= 2/ Public entry points =======
; =========================================
; =========================================

; Run the wizard only when config.toml does not yet exist.
; Called at startup before features are loaded.
;
; BLOCKING contract: this function must NOT return while the wizard is on
; screen. ``g.Show()`` is non-blocking on its own, so without this guard the
; caller would continue with no config and ParseTomlFile() would raise
; cascading errors that crash the GUI within ~1 second. We park here until
; the wizard either commits (calls Reload, which kills the loop) or the user
; dismisses it (in which case there is no usable config and we ExitApp).
Onboarding_Run() {
	if FileExist(ConfigurationFile) {
		return
	}
	global _OB_ALTGR_PASSTHROUGH := true
	_Onboarding_Step1()
	; Loop tick chosen large enough to leave the message pump idle most of
	; the time, small enough to dismiss the script quickly when the user
	; closes the wizard.
	while IsSet(_ob_gui) {
		Sleep(100)
	}
	; Reaching here means the wizard window was closed without committing —
	; the driver cannot operate without a config, so exit cleanly.
	ExitApp(0)
}


; Allow the user to re-run the wizard from the tray menu even when a
; config already exists — useful after a reset or for re-configuration.
Onboarding_ShowFromMenu(*) {
	global _OB_ALTGR_PASSTHROUGH := true
	_Onboarding_Step1()
}




; ===============================================
; ===============================================
; ======= 3/ i18n preview helpers =======
; ===============================================
; ===============================================

; Thin alias kept for backwards-compatibility with existing callers in this
; wizard. The real detector lives in lib/i18n.ahk so I18nInit can use it too.
_Onboarding_DetectSystemLocale() {
	return _I18nDetectSystemLocale()
}

; Resolve a translation key in a target locale WITHOUT touching the active
; locale cache. Used by step 1 so the heading/title/button can be re-rendered
; in the language being previewed while the rest of the running script keeps
; its current locale until the user confirms the choice.
;
; @param Code string Locale code to resolve under (e.g. "fr", "en").
; @param Key  string Translation key to look up.
; @returns string The translated value in Code, or the key itself on failure.
_Onboarding_Translate(Code, Key) {
	global _I18nLocale, _I18nCache, _I18nCacheLoaded
	PrevLocale := _I18nLocale
	PrevCache  := _I18nCache
	PrevLoaded := _I18nCacheLoaded
	_I18nLocale      := Code
	_I18nCacheLoaded := false
	Value := t(Key)
	_I18nLocale      := PrevLocale
	_I18nCache       := PrevCache
	_I18nCacheLoaded := PrevLoaded
	return Value
}




; ==========================================
; ==========================================
; ======= 4/ Step implementations =======
; ==========================================
; ==========================================

; ============================================
; ===== 4.1) Step 1 — Language selection =====
; ============================================

_Onboarding_Step1() {
	_Onboarding_DestroyActive()
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
	DetectedCode := _Onboarding_DetectSystemLocale()
	DefaultIndex := 1
	for _i, _loc in SortedLocales {
		if _loc.Code = DetectedCode {
			DefaultIndex := _i
			break
		}
	}
	; Safety net: if detected code not found (shouldn't happen given the logic
	; in _Onboarding_DetectSystemLocale), fall back to English.
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
	g.MarginY := 16

	; The main heading is the only piece of static text in the welcome screen.
	; We deliberately ship a single language at a time (re-rendered live on
	; selection) rather than the old "Welcome / Bienvenue / Willkommen" salad,
	; because mixing five locales hurt readability and made every line cramped.
	headingText := g.AddText("w" ONBOARDING_WIN_W - 40 " Section",
		_Onboarding_Translate(DefaultCode, "onboarding.welcome.heading"))

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

	; Single-select ListView — one row per locale, flag icon + name
	ContentW := ONBOARDING_WIN_W - 40
	lv := g.AddListView("w" ContentW " h" ONBOARDING_LV_H " -Hdr -Multi -HScroll LV0x10 NoSortHdr y+10", ["Language"])
	lv.SetImageList(IL)
	loop SortedLocales.Length {
		loc   := SortedLocales[A_Index]
		iIcon := FlagIndexMap.Has(loc.Code) ? FlagIndexMap[loc.Code] : 0
		lv.Add("Icon" iIcon, loc.Name)
	}
	; Subtract scrollbar width (~17px) so the column never triggers horizontal overflow
	lv.ModifyCol(1, ContentW - 20)
	; Resize the ListView to the exact size Windows itself uses for N items.
	; LVM_APPROXIMATEVIEWRECT (0x1041) returns the precise outer dimensions
	; (border included) needed to show ``visRows`` items without a partial
	; row at the bottom — historically the source of the "white stripe when
	; scrolled" complaint. We fall back to the manual ``visRows × rowH``
	; calc when the message returns an unusable height (rare; covers OS
	; theme tweaks that intercept the message).
	;
	; wParam = item count, lParam = (cy << 16) | cx with -1 meaning "use
	; the default". The result is (cyOut << 16) | cxOut — we only want the
	; height, masked to 16 bits.
	; Measure the LV's natural row height via LVM_GETITEMRECT and shrink the
	; control to ``visRows × rowH + 2 × SM_CYEDGE`` so it shows exactly N items
	; with no white stripe at the bottom of the scroll. CRITICAL: we ALSO have
	; to relocate the Next button by hand below because AHK's "next control"
	; position tracker is set when the LV is *added* (with the initial h240)
	; and is NOT updated by ``Move()`` — so a relative ``y+16`` on the button
	; would land it on top of the (now-shorter) LV instead of below it.
	RECT := Buffer(16, 0)
	SendMessage(0x100E, 0, RECT.Ptr, lv)  ; LVM_GETITEMRECT, item 0, LVIR_BOUNDS
	rowH := NumGet(RECT, 12, "Int") - NumGet(RECT, 4, "Int")  ; bottom - top
	if (rowH > 0) {
		maxRows := 8
		visRows := Min(SortedLocales.Length, maxRows)
		borderPx := 2 * DllCall("GetSystemMetrics", "Int", 13, "Int")
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
	btnNext.Move(, _lvY + _lvH + 16)
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, lv, SortedLocales, DefaultIndex))

	; Re-render the title, heading and button label in the previewed locale
	; whenever the selection changes
	lv.OnEvent("ItemSelect", _Step1_UpdateUi.Bind(g, headingText, btnNext, SortedLocales))

	; Immediately render in the pre-selected locale — Modify(Select) does not
	; fire ItemSelect, so we invoke the handler manually with the default row.
	_Step1_UpdateUi(g, headingText, btnNext, SortedLocales, lv, DefaultIndex, true)

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step1_UpdateUi(g, headingText, btn, SortedLocales, lv, row, selected, *) {
	if !selected or row <= 0
		return
	Code := SortedLocales[row].Code
	try g.Title       := _Onboarding_Translate(Code, "onboarding.welcome.title")
	try headingText.Text := _Onboarding_Translate(Code, "onboarding.welcome.heading")
	try btn.Text      := _Onboarding_Translate(Code, "onboarding.next")
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

	_Onboarding_DestroyActive()
	_Onboarding_StepConfigDir()
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
	g := Gui("+AlwaysOnTop", t("dialog.config_folder.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("dialog.config_folder.title"))

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

	; Row 3: hint below the input. ``y+10`` measured from the edit's bottom.
	g.SetFont("s9 cGray")
	g.AddText("xm y+10 w" ONBOARDING_WIN_W - 40, t("dialog.config_folder.hint"))
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
	selected := DirSelect("*" . startDir, 1, t("dialog.config_folder.select_title"))
	if (selected != "") {
		selected := StrReplace(selected, "\", "/")
		if !RegExMatch(selected, "/$")
			selected .= "/"
		dirEdit.Value := selected
	}
}

_StepConfigDir_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step1()
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

	_Onboarding_DestroyActive()
	_Onboarding_Step2()
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
	CfgPath := Dir . "ahk\config.toml"
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
	; choice so a partial state (only ErgoptiAltGr on, etc.) still flips Yes.
	LayoutBase  := IniCacheGet(Cache, "Layout", "ErgoptiBase")
	LayoutAltGr := IniCacheGet(Cache, "Layout", "ErgoptiAltGr")
	LayoutPlus  := IniCacheGet(Cache, "Layout", "ErgoptiPlus")
	if (LayoutBase != "_" or LayoutAltGr != "_" or LayoutPlus != "_") {
		_ob_layout := (StrLower(LayoutBase) == "true")
			or (StrLower(LayoutAltGr) == "true")
			or (StrLower(LayoutPlus) == "true")
	}

	; Magic key: TOML strings come in with surrounding quotes already stripped
	; by the parser, so the cache value is the raw character.
	MagicKey := IniCacheGet(Cache, "Hotstrings", "MagicKey")
	if (MagicKey != "_" and MagicKey != "") {
		_ob_magic_key := MagicKey
	}

	; Metrics + gestures: boolean flags. ParseTomlFile preserves TOML's
	; literal "true"/"false" strings so a case-insensitive compare suffices.
	MetricsEnabled := IniCacheGet(Cache, "Metrics", "metrics_enabled")
	if (MetricsEnabled != "_") {
		_ob_metrics := (StrLower(MetricsEnabled) == "true")
	}
	GesturesEnabled := IniCacheGet(Cache, "Gestures", "Enabled")
	if (GesturesEnabled != "_") {
		_ob_gestures := (StrLower(GesturesEnabled) == "true")
	}

	try LoggerDone("onboarding", "Wizard pre-loaded (layout=%s, magic='%s', metrics=%s, gestures=%s).",
		_ob_layout ? "true" : "false", _ob_magic_key,
		_ob_metrics ? "true" : "false", _ob_gestures ? "true" : "false")
}


; ===================================================
; ===== 4.2) Step 2 — Ergopti keyboard layout =====
; ===================================================

_Onboarding_Step2() {
	global _StaticDir
	g := Gui("+AlwaysOnTop", t("onboarding.layout.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	; Step 2 uses the WIDER ``ONBOARDING_STEP2_W`` so the layout preview JPG
	; renders larger — at the default 460 px wizard width, the keys were
	; barely readable.
	contentW := ONBOARDING_STEP2_W - 40
	g.AddText("w" contentW, t("onboarding.layout.title"))
	g.SetFont("s9")
	g.AddText("w" contentW " y+8", t("onboarding.layout.desc"))
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
			g.AddPicture("w" contentW " h-1 y+10", imgPath)
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
	rNo  := g.AddRadio((_ob_layout ? "" : "Checked"), t("onboarding.layout.no"))

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
	_Onboarding_DestroyActive()
	; Back returns to the inserted config-folder step (was Step1 before
	; the picker was added between Step1 and Step2).
	_Onboarding_StepConfigDir()
}

_Step2_Next(g, rYes, *) {
	global _ob_layout := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Step3()
}


; =============================================
; ===== 4.3) Step 3 — Magic key binding =====
; =============================================

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
	g := Gui("+AlwaysOnTop", t("onboarding.magic_key.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	; Heading and short description — kept upright (no italic) so the page
	; reads as a regular form rather than a long block of quoted text.
	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.magic_key.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.magic_key.desc"))
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
	g.AddText("w" ONBOARDING_WIN_W - 40 " x20 y+14", t("onboarding.magic_key.choose_freely"))
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
	_Onboarding_DestroyActive()
	_Onboarding_Step2()
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
	_Onboarding_DestroyActive()
	_Onboarding_Step4()
}


; =============================================
; ===== 4.4) Step 4 — Typing metrics =====
; =============================================

_Onboarding_Step4() {
	global _ConfigDir
	g := Gui("+AlwaysOnTop", t("onboarding.metrics.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.metrics.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.metrics.desc"))

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
	warning := StrReplace(t("dialog.metrics.enable_warning"), "%s", metrics_path)
	g.SetFont("s8 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+10 cRed", warning)
	g.SetFont("s10 norm")

	; Restore the previously-saved Yes/No when the wizard was re-opened over
	; an existing config (pre-load step in _StepConfigDir_Next).  Radios sit
	; right under the red warning with the radio control's natural padding —
	; the empty spacer text used to add a ~12 px gap that pushed the action
	; row off the screen on smaller displays.
	global _ob_metrics
	rYes := g.AddRadio("vMetricsChoice xm y+6" . (_ob_metrics ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((_ob_metrics ? "" : "Checked"), t("onboarding.no"))

	btns := _Onboarding_AddNavButtons(g, t("onboarding.back"), t("onboarding.next"))
	btnBack := btns[1]
	btnNext := btns[2]

	btnBack.OnEvent("Click", _Step4_Back.Bind(g))
	btnNext.OnEvent("Click", _Step4_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step4_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step3()
}

_Step4_Next(g, rYes, *) {
	global _ob_metrics := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Step5()
}


; =============================================
; ===== 4.5) Step 5 — Trackpad gestures =====
; =============================================

_Onboarding_Step5() {
	g := Gui("+AlwaysOnTop", t("onboarding.gestures.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.gestures.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.gestures.desc"))
	g.SetFont("s10")

	; Restore the previously-saved Yes/No when the wizard was re-opened over
	; an existing config (pre-load step in _StepConfigDir_Next).
	global _ob_gestures
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vGesturesChoice" . (_ob_gestures ? " Checked" : ""), t("onboarding.yes"))
	rNo  := g.AddRadio((_ob_gestures ? "" : "Checked"), t("onboarding.no"))

	; Registration panel — only visible when "Yes" is selected. We pre-build
	; every control as hidden so the layout does not jump when the user clicks
	; the radio buttons; visibility is toggled by _Step5_OnRadioChange.
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+14", "")
	regSectionLbl := g.AddText("w" ONBOARDING_WIN_W - 40 " Hidden",
		t("onboarding.gestures.register_section"))

	btnRegAuto := g.AddButton("w" ONBOARDING_WIN_W - 40 " xs y+6 Hidden",
		t("onboarding.gestures.register_auto"))
	g.SetFont("s8 italic")
	autoHint := g.AddText("w" ONBOARDING_WIN_W - 40 " y+4 Hidden",
		t("onboarding.gestures.register_auto_hint"))
	g.SetFont("s10 norm")

	btnRegManual := g.AddButton("w" ONBOARDING_WIN_W - 40 " y+10 Hidden",
		t("onboarding.gestures.register_manual"))
	g.SetFont("s8 italic")
	manualHint := g.AddText("w" ONBOARDING_WIN_W - 40 " y+4 Hidden",
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
	_Onboarding_DestroyActive()
	_Onboarding_Step4()
}

_Step5_Finish(g, rYes, *) {
	global _ob_gestures := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Commit()
}




; ===========================================
; ===========================================
; ======= 5/ Config write and reload =======
; ===========================================
; ===========================================

; Write all collected wizard answers to config.toml in one atomic call, then
; reload so ErgoptiPlus boots with a fully-configured environment.
; Persist the chosen config dir to paths.toml. Same format produced by
; the FilePathsEditor dialog (lib/onboarding-independent helper in
; ErgoptiPlus.ahk) so a wizard pass and a later edit-via-tray produce
; structurally identical files.
_WritePathsToml(NewDir) {
	global _PathsFile, _DefaultConfigDir
	try {
		f := FileOpen(_PathsFile, "w", "UTF-8")
		if !f
			return
		DefaultDirFwd := StrReplace(IsSet(_DefaultConfigDir) ? _DefaultConfigDir : "", "\", "/")
		NewDirFwd := StrReplace(NewDir, "\", "/")
		f.Write("# Custom paths — auto-generated by ErgoptiPlus.`r`n")
		f.Write("# Edit this file to point to your personal configuration folder.`r`n")
		f.Write("# If absent or commented out, files are looked up in: " . DefaultDirFwd . "`r`n")
		f.Write("`r`n")
		f.Write('ConfigDirPath = "' . NewDirFwd . '"`r`n')
		f.Close()
	}
}

_Onboarding_Commit() {
	; Block strict canonicalisation: SaveFullConfig() reads in-memory feature
	; state which still reflects defaults (the wizard never called Reload).
	; Without this guard, TOML_BatchWrite would immediately trigger
	; SaveFullConfig() which would overwrite the wizard's values with false.
	global _TOML_STRICT_CANON_IN_PROGRESS
	_TOML_STRICT_CANON_IN_PROGRESS := true

	; If the user picked a custom config directory in the StepConfigDir
	; wizard step, persist it to paths.toml BEFORE writing config.toml —
	; the boot path resolver will then route ConfigurationFile to the
	; new location on the upcoming Reload. We also rewrite the in-memory
	; ``ConfigurationFile`` so the TOML_BatchWrite below lands in the
	; right spot, not the stale default. An empty ``_ob_config_dir``
	; means "keep the default" — paths.toml is left untouched.
	global _ob_config_dir, _ConfigDir, _DefaultConfigDir, _PathsFile, ConfigurationFile
	if (IsSet(_ob_config_dir) and _ob_config_dir != "") {
		newDir := _ob_config_dir
		if !RegExMatch(newDir, "\\$")
			newDir .= "\"
		if (newDir != _ConfigDir) {
			try DirCreate(newDir)
			_WritePathsToml(newDir)
			_ConfigDir := newDir
			ConfigurationFile := newDir . "ahk\config.toml"
			try DirCreate(newDir . "ahk")
		}
	}

	updates := [
		{ Section: "Script",     Key: "Locale",          Value: _ob_locale    },
		{ Section: "Layout",     Key: "ErgoptiBase",     Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiAltGr",    Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiPlus",     Value: _ob_layout    },
		{ Section: "Hotstrings", Key: "MagicKey",        Value: _ob_magic_key },
		{ Section: "Metrics",    Key: "metrics_enabled", Value: _ob_metrics   },
		{ Section: "Gestures",   Key: "Enabled",         Value: _ob_gestures  },
	]

	; Defer the Precision-Touchpad registry writes to the post-reload pass —
	; the gestures module reads ``AutoConfigureOnNextStart`` after its globals
	; are populated and runs the actual ``GestureAutoConfigureRegistry`` there.
	; The flag is one-shot: the module clears it after a successful (or failed)
	; attempt so subsequent reloads don't keep rewriting the same values.
	if _ob_register_pending {
		updates.Push({ Section: "Gestures", Key: "AutoConfigureOnNextStart", Value: true })
	}

	TOML_BatchWrite(ConfigurationFile, updates)

	Reload
}




; =======================================
; =======================================
; ======= 6/ GUI utility helpers =======
; =======================================
; =======================================

; ========================================
; ===== 6.1) Centering and display =====
; ========================================

; Center the wizard window on the primary monitor and show it. Also wire a
; Close handler so the X button does not leave Onboarding_Run() looping on a
; window that is no longer visible — instead it cleanly clears ``_ob_gui``
; and lets the caller decide what to do next.
;
; @param g       Gui  The wizard window object.
; @param widthW  Int  Optional override width. Defaults to the standard
;                     ONBOARDING_WIN_W — Step 2 passes ONBOARDING_STEP2_W
;                     so the layout preview JPG renders larger.
_Onboarding_Show(g, widthW := unset) {
	g.OnEvent("Close", _Onboarding_OnGuiClose)
	w := IsSet(widthW) ? widthW : ONBOARDING_WIN_W
	g.Show("w" w " AutoSize Center")
}


; =====================================================
; ===== 6.1b) Dynamic-width nav button row helper =====
; =====================================================

; Minimum width applied to every Back / Next / Finish button so the wizard
; keeps its proportions even when the active locale's labels are extremely
; short (e.g. ``OK``/``次``). 90 px matches the historical fixed width.
global ONBOARDING_BTN_MIN_W := 90

; Builds the bottom navigation row (Back + Next, or just Next on step 1) with
; both buttons sized to the longest label so they line up symmetrically across
; locales. Without this, ``w90``/``w110`` clipped long German captions like
; ``Durchsuchen`` or ``Auto-Konfiguration``.
;
; The helper creates both buttons with auto-width first, measures their
; natural widths via GetPos, computes a shared width, then pins Back to the
; left margin and Next to the right margin of the wizard window.
;
; @param g          Gui      The active wizard window.
; @param backLabel  String   Localised Back label, or "" to skip the Back button.
; @param nextLabel  String   Localised Next/Finish label (always shown).
; @param isDefault  Bool     true → Next gets the ``Default`` option (Enter key triggers it).
; @returns          [btnBack | unset, btnNext]   The control objects, ready for OnEvent wiring.
_Onboarding_AddNavButtons(g, backLabel, nextLabel, isDefault := true) {
	; ``y+16`` advances past whatever the previous control on the page was so
	; the row sits visually separated. ``yp`` on the second control keeps both
	; buttons on the same row.
	hasBack := (backLabel != "")
	if hasBack {
		btnBack := g.AddButton("x20 y+16",                       backLabel)
		btnNext := g.AddButton((isDefault ? "Default " : "") . "yp", nextLabel)
	} else {
		btnBack := unset
		btnNext := g.AddButton((isDefault ? "Default " : "") . "x20 y+16", nextLabel)
	}

	; Harmonise widths via the shared GUI helper so this wizard inherits the
	; same dynamic-button policy applied across every other dialog. Pinning
	; Next to the right margin happens AFTER harmonise so the shared width is
	; the one used to compute the right-edge anchor.
	sharedW := Gui_HarmoniseButtonWidths(hasBack ? [btnBack, btnNext] : [btnNext], ONBOARDING_BTN_MIN_W)
	btnNext.Move(ONBOARDING_WIN_W - 20 - sharedW)

	return hasBack ? [btnBack, btnNext] : [unset, btnNext]
}

; Single close handler reused by every wizard page. Triggered when the user
; clicks the window's X button or hits Alt+F4.
_Onboarding_OnGuiClose(g, *) {
	; Restore AltGr behaviour for the rest of the session — the user closed
	; the wizard without committing, so we are about to either ExitApp (first
	; launch) or return control to the running script (menu-triggered relaunch).
	; In the latter case keeping the flag set would silently break AltGr until
	; the next reload.
	global _OB_ALTGR_PASSTHROUGH := false
	_Onboarding_DestroyActive()
}


; ====================================
; ===== 6.2) Active Gui cleanup =====
; ====================================

; Destroy the current wizard Gui if one is open — keeps at most one page alive.
_Onboarding_DestroyActive() {
	global _ob_gui
	try {
		if IsSet(_ob_gui) {
			_ob_gui.Destroy()
		}
	}
	_ob_gui := unset
}
