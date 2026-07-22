; ui/onboarding/steps_keyboard.ahk

; ==============================================================================
; MODULE: Onboarding / Keyboard Steps
; DESCRIPTION:
; Wizard steps covering the Ergopti keyboard layout choice and the magic-key
; binding selection. These steps let the user opt into the Ergopti layout
; emulation and choose the trigger character for hotstring expansion.
;
; Split from ui/onboarding/steps.ahk; see ui/onboarding/init.ahk for the full
; module overview. Functions and globals are hoisted, so load order across the
; onboarding/*.ahk files is irrelevant.
; ==============================================================================





; ======================================================
; ======================================================
; ======= 4.2/ Keyboard Layout + Magic Key Steps =======
; ======================================================
; ======================================================



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

; True when the key has its own radio on the magic-key page. Only the custom
; Edit needs this, and it is deliberately NOT a test for "did the user choose
; something" — the default has a radio and is also a valid saved answer, so
; conflating the two is what silently rewrote saved keys. Provenance lives in
; _ob_magic_key_explicit; this answers a different question.
_Onboarding_IsPrebakedMagicKey(Key) {
	return (Key == ONBOARDING_DEFAULT_MAGIC_KEY or Key == "ù" or Key == ";")
}

_Onboarding_Step3() {
	global _ob_magic_key, _ob_magic_key_explicit
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
	edInitial := (_ob_magic_key_explicit and _ob_magic_key != ""
		and !_Onboarding_IsPrebakedMagicKey(_ob_magic_key))
		? _ob_magic_key : "*"
	edKey := g.AddEdit("w120 x40 y+4 vMagicKeyEdit", edInitial)

	; Pre-select whichever radio matches the persisted/default value. The
	; user has been through step 2 by now, so we know whether they chose
	; the Ergopti emulation; combined with the system KB layout, that's
	; enough to pick a sensible default per the contract documented in
	; _Onboarding_PickDefaultMagicKey.
	default_key := _Onboarding_PickDefaultMagicKey()
	; Provenance, not value: the default is itself a valid answer, so a saved
	; one is indistinguishable from "nothing loaded" if we test the character.
	current_key := (_ob_magic_key_explicit and _ob_magic_key != "")
		? _ob_magic_key
		: default_key
	; Persist so Back/Next preserves the choice even when the user only
	; navigated past this step without explicitly clicking a radio. Reaching
	; this page is itself the confirmation, so the value is explicit from here.
	_ob_magic_key := current_key
	_ob_magic_key_explicit := true
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
	global _ob_magic_key, _ob_magic_key_explicit
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
	_ob_magic_key := val
	_ob_magic_key_explicit := true
	_Onboarding_Navigate(_Onboarding_Step4)
}
