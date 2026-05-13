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

; Default locale index within I18N_LOCALES (1-based; English is index 2)
global ONBOARDING_DEFAULT_LOCALE_INDEX := 2

; Wizard window dimensions
global ONBOARDING_WIN_W := 480
global ONBOARDING_WIN_H := 340

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
Onboarding_Run() {
	if FileExist(ConfigurationFile) {
		return
	}
	_Onboarding_Step1()
}


; Allow the user to re-run the wizard from the tray menu even when a
; config already exists — useful after a reset or for re-configuration.
Onboarding_ShowFromMenu() {
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

	g := Gui("+AlwaysOnTop", "Welcome / Bienvenue / Willkommen")
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, "Choose your language:")

	; One radio button per locale — English ticked by default
	radios := []
	loop I18N_LOCALES.Length {
		locale := I18N_LOCALES[A_Index]
		label  := locale.Flag " " locale.Name
		opt    := (A_Index = 1) ? "Radio Group vLocaleRadio" : "Radio"
		r      := g.AddRadio(opt, label)
		if (A_Index = ONBOARDING_DEFAULT_LOCALE_INDEX) {
			r.Value := 1
		}
		radios.Push(r)
	}

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+16", "")

	btnNext := g.AddButton("Default w100 x" ONBOARDING_WIN_W - 120, "Next →")
	btnNext.OnEvent("Click", _Step1_Next.Bind(g, radios))

	_Onboarding_Show(g)
	global _ob_gui := g
}

_Step1_Next(g, radios, *) {
	; Identify which radio is selected by iterating the controls
	selectedIndex := ONBOARDING_DEFAULT_LOCALE_INDEX
	loop radios.Length {
		if radios[A_Index].Value {
			selectedIndex := A_Index
			break
		}
	}

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
	rYes := g.AddRadio("Radio Group vLayoutChoice", t("onboarding.layout.yes"))
	rNo  := g.AddRadio("Radio Checked", t("onboarding.layout.no"))

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
	g := Gui("+AlwaysOnTop", t("onboarding.metrics.title"))
	g.SetFont("s10", "Segoe UI")
	g.MarginX := 20
	g.MarginY := 16

	g.AddText("w" ONBOARDING_WIN_W - 40, t("onboarding.metrics.title"))
	g.SetFont("s9")
	g.AddText("w" ONBOARDING_WIN_W - 40 " y+8", t("onboarding.metrics.desc"))
	g.SetFont("s10")

	g.AddText("w" ONBOARDING_WIN_W - 40 " y+12", "")
	rYes := g.AddRadio("Radio Group vMetricsChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Radio Checked", t("onboarding.no"))

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
	rYes := g.AddRadio("Radio Group vGesturesChoice", t("onboarding.yes"))
	rNo  := g.AddRadio("Radio Checked", t("onboarding.no"))

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
	layoutVal := _ob_layout ? "true" : "false"
	metricsVal := _ob_metrics ? "true" : "false"
	gesturesVal := _ob_gestures ? "true" : "false"

	TOML_BatchWrite(ConfigurationFile, [
		{ Section: "Script",    Key: "Locale",           Value: _ob_locale    },
		{ Section: "Layout",    Key: "ErgoptiBase",      Value: layoutVal     },
		{ Section: "Layout",    Key: "ErgoptiAltGr",     Value: layoutVal     },
		{ Section: "Layout",    Key: "ErgoptiPlus",      Value: layoutVal     },
		{ Section: "Hotstrings", Key: "MagicKey",        Value: _ob_magic_key },
		{ Section: "Metrics",   Key: "metrics_enabled",  Value: metricsVal    },
		{ Section: "Gestures",  Key: "Enabled",          Value: gesturesVal   },
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

; Center the wizard window on the primary monitor and show it.
_Onboarding_Show(g) {
	g.Show("w" ONBOARDING_WIN_W " h" ONBOARDING_WIN_H " Center")
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
