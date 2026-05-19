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
; 3. Locale-Live-Switch: Selecting a language on step 1 immediately calls
;    I18nSetLocale so that all subsequent pages render in the chosen locale
;    without requiring a reload.
; 4. Atomic Write: All user choices are applied in a single TOML_BatchWrite
;    call at the end, then Reload is called once.
; ==============================================================================




; ================================================
; ================================================
; ======= 1/ Constants and wizard state =======
; ================================================
; ================================================

; Default locale index within I18N_LOCALES (1-based; English is index 4)
global ONBOARDING_DEFAULT_LOCALE_INDEX := 4

; Wizard window width (height is computed automatically from controls)
global ONBOARDING_WIN_W := 400

; Height of the language ListView — fits ~8 rows, scrollable beyond that
global ONBOARDING_LV_H := 220

; Collected answers — populated as the user advances through each step
global _ob_locale       := "en"
global _ob_layout       := false
global _ob_magic_key    := "★"
global _ob_metrics      := false
global _ob_gestures     := false

; Reference to the currently active wizard Gui object
global _ob_gui          := unset




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
	_Onboarding_Step1()
}




; ==========================================
; ==========================================
; ======= 3/ Step implementations =======
; ==========================================
; ==========================================

; ============================================
; ===== 3.1) Step 1 — Language selection =====
; ============================================

_Onboarding_Step1() {
	_Onboarding_DestroyActive()
	global _StaticDir, _ob_layout, _ob_magic_key, _ob_metrics, _ob_gestures
	_ob_layout    := false
	_ob_magic_key := "★"
	_ob_metrics   := false
	_ob_gestures  := false

	g := Gui("+AlwaysOnTop", "Welcome / Bienvenue / Willkommen")
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, "Choose your language / Choisissez votre langue:")

	; Build a 32×24 image list from flag PNGs in static/img/flags/
	FlagsDir := _StaticDir . "\img\flags\"
	IL := IL_Create(I18N_LOCALES.Length, 1, false)
	FlagIndexMap := Map()  ; Code -> 1-based IL index
	loop I18N_LOCALES.Length {
		loc      := I18N_LOCALES[A_Index]
		FlagFile := FlagsDir . loc.Code . ".png"
		idx      := IL_Add(IL, FlagFile)
		FlagIndexMap[loc.Code] := (idx > 0) ? idx : 0
	}

	; Single-select ListView — one row per locale, flag icon + name
	ContentW := ONBOARDING_WIN_W - 40
	lv := g.AddListView("w" ContentW " h" ONBOARDING_LV_H " -Hdr -Multi -HScroll LV0x10 NoSortHdr", ["Language"])
	lv.SetImageList(IL)
	loop I18N_LOCALES.Length {
		loc   := I18N_LOCALES[A_Index]
		iIcon := FlagIndexMap.Has(loc.Code) ? FlagIndexMap[loc.Code] : 0
		lv.Add("Icon" iIcon, loc.Name)
	}
	; Subtract scrollbar width (~17px) so the column never triggers horizontal overflow
	lv.ModifyCol(1, ContentW - 20)
	; Pre-select the default locale row
	lv.Modify(ONBOARDING_DEFAULT_LOCALE_INDEX, "Select Focus Vis")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+10", "")

	; Initialise label in the locale that is already active (user may have set one before)
	btnNext := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, t("onboarding.next"))
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, lv))

	; Re-render the button in the selected locale whenever the selection changes
	lv.OnEvent("ItemSelect", _Step1_UpdateNextBtn.Bind(btnNext))

	; Immediately render the button in the pre-selected locale — Modify(Select) does
	; not fire ItemSelect, so we call the handler manually with the default row index
	_Step1_UpdateNextBtn(btnNext, lv, ONBOARDING_DEFAULT_LOCALE_INDEX, true)

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step1_UpdateNextBtn(btn, lv, row, selected, *) {
	if !selected or row <= 0
		return
	global _I18nLocale, _I18nCache, _I18nCacheLoaded
	PrevLocale  := _I18nLocale
	PrevCache   := _I18nCache
	PrevLoaded  := _I18nCacheLoaded
	_I18nLocale      := I18N_LOCALES[row].Code
	_I18nCacheLoaded := false
	NextLabel        := t("onboarding.next")
	_I18nLocale      := PrevLocale
	_I18nCache       := PrevCache
	_I18nCacheLoaded := PrevLoaded
	btn.Text := NextLabel
}

_Step1_Next(g, lv, *) {
	; Get the selected row index (1-based); fall back to default if none selected
	selectedIndex := ONBOARDING_DEFAULT_LOCALE_INDEX
	row := lv.GetNext(0, "Focused")
	if row > 0
		selectedIndex := row

	locale := I18N_LOCALES[selectedIndex]
	global _ob_locale := locale.Code

	; Switch locale in memory only — avoid Reload during the wizard
	global _I18nLocale, _I18nCacheLoaded
	_I18nLocale := locale.Code
	_I18nCacheLoaded := false

	_Onboarding_DestroyActive()
	_Onboarding_Step2()
}


; ===================================================
; ===== 3.2) Step 2 — Ergopti keyboard layout =====
; ===================================================

_Onboarding_Step2() {
	g := Gui("+AlwaysOnTop", t("onboarding.layout.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.layout.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.layout.desc"))
	g.SetFont("s10")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vLayoutChoice", t("onboarding.layout.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.layout.no"))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w80 x20",                    t("onboarding.back"))
	btnNext := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step2_Back.Bind(g))
	btnNext.OnEvent("Click", _Step2_Next.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step2_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step1()
}

_Step2_Next(g, rYes, *) {
	global _ob_layout := (rYes.Value = 1)
	_Onboarding_DestroyActive()
	_Onboarding_Step3()
}


; =============================================
; ===== 3.3) Step 3 — Magic key binding =====
; =============================================

_Onboarding_Step3() {
	g := Gui("+AlwaysOnTop", t("onboarding.magic_key.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.magic_key.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.magic_key.desc"))
	g.SetFont("s10")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	edKey := g.AddEdit("w60 vMagicKeyEdit", _ob_magic_key)

	g.SetFont("s9 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+6", t("onboarding.magic_key.hint"))
	g.SetFont("s10 norm")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w80 x20",                    t("onboarding.back"))
	btnNext := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, t("onboarding.next"))

	btnBack.OnEvent("Click", _Step3_Back.Bind(g))
	btnNext.OnEvent("Click", _Step3_Next.Bind(g, edKey))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step3_Back(g, *) {
	_Onboarding_DestroyActive()
	_Onboarding_Step2()
}

_Step3_Next(g, edKey, *) {
	val := Trim(edKey.Value)
	; Fall back to the star placeholder so the config always has a non-empty value
	global _ob_magic_key := (val != "") ? val : "★"
	_Onboarding_DestroyActive()
	_Onboarding_Step4()
}


; =============================================
; ===== 3.4) Step 4 — Typing metrics =====
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
	; Show the exact same privacy warning that ToggleMetricsEnabled() displays,
	; so the user sees the full implications before answering yes/no
	metrics_path := _ConfigDir . "metrics"
	g.SetFont("s8 italic")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8 cRed", Format(t("dialog.metrics.enable_warning"), metrics_path))
	g.SetFont("s10 norm")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vMetricsChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.no"))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack := g.AddButton("w80 x20",                    t("onboarding.back"))
	btnNext := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, t("onboarding.next"))

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
; ===== 3.5) Step 5 — Trackpad gestures =====
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

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("vGesturesChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Checked", t("onboarding.no"))

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnBack   := g.AddButton("w80 x20",                    t("onboarding.back"))
	btnFinish := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, t("onboarding.finish"))

	btnBack.OnEvent("Click", _Step5_Back.Bind(g))
	btnFinish.OnEvent("Click", _Step5_Finish.Bind(g, rYes))

	_Onboarding_Show(g)
	global _ob_gui := g
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
; ======= 4/ Config write and reload =======
; ===========================================
; ===========================================

; Write all collected wizard answers to config.toml in one atomic call, then
; reload so ErgoptiPlus boots with a fully-configured environment.
_Onboarding_Commit() {
	; Block strict canonicalisation: SaveFullConfig() reads in-memory feature
	; state which still reflects defaults (the wizard never called Reload).
	; Without this guard, TOML_BatchWrite would immediately trigger
	; SaveFullConfig() which would overwrite the wizard's values with false.
	global _TOML_STRICT_CANON_IN_PROGRESS
	_TOML_STRICT_CANON_IN_PROGRESS := true

	TOML_BatchWrite(ConfigurationFile, [
		{ Section: "Script",     Key: "Locale",          Value: _ob_locale    },
		{ Section: "Layout",     Key: "ErgoptiBase",     Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiAltGr",    Value: _ob_layout    },
		{ Section: "Layout",     Key: "ErgoptiPlus",     Value: _ob_layout    },
		{ Section: "Hotstrings", Key: "MagicKey",        Value: _ob_magic_key },
		{ Section: "Metrics",    Key: "metrics_enabled", Value: _ob_metrics   },
		{ Section: "Gestures",   Key: "Enabled",         Value: _ob_gestures  },
	])

	Reload
}




; =======================================
; =======================================
; ======= 5/ GUI utility helpers =======
; =======================================
; =======================================

; ========================================
; ===== 5.1) Centering and display =====
; ========================================

; Center the wizard window on the primary monitor and show it. Also wire a
; Close handler so the X button does not leave Onboarding_Run() looping on a
; window that is no longer visible — instead it cleanly clears ``_ob_gui``
; and lets the caller decide what to do next.
_Onboarding_Show(g) {
	g.OnEvent("Close", _Onboarding_OnGuiClose)
	g.Show("w" ONBOARDING_WIN_W " AutoSize Center")
}

; Single close handler reused by every wizard page. Triggered when the user
; clicks the window's X button or hits Alt+F4.
_Onboarding_OnGuiClose(g, *) {
	_Onboarding_DestroyActive()
}


; ====================================
; ===== 5.2) Active Gui cleanup =====
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
