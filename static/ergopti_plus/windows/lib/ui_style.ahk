; drivers/autohotkey/lib/ui_style.ahk

; ==============================================================================
; MODULE: UI Style Constants
; DESCRIPTION:
; AHK-side mirror of the cross-driver tooltip visual constants.  The canonical
; source of truth is static/ergopti_plus/shared/tooltip/constants.toml — every
; value declared here MUST match the corresponding entry in that file.  When
; constants.toml is updated, this file must be updated to match.
;
; FEATURES & RATIONALE:
; 1. Cross-driver parity: every constant here has a named equivalent in
;    constants.toml and in ui/tooltip/config.lua (Hammerspoon side).
;    Divergences between these three files are bugs.
; 2. No magic numbers: every tooltip.ahk layout value must originate here,
;    never be inlined at the call site.
; 3. Future-proof: a Linux or web driver reads constants.toml directly;
;    AHK and HS mirror it here as language-native globals for zero-cost access.
;
; CROSS-REFERENCES (constants.toml key → AHK global):
;   [typography]  font_main_ahk          → UI_FONT_NAME
;   [typography]  font_size_main_ahk     → UI_FONT_SIZE_MAIN
;   [typography]  font_size_hint_ahk     → UI_FONT_SIZE_HINT
;   [layout]      pad_x                  → UI_PAD_X
;   [layout]      pad_y                  → UI_PAD_Y
;   [layout]      label_gap              → UI_LABEL_GAP
;   [layout]      corner_radius × 2      → UI_CORNER_RADIUS (GDI diameter)
;   [colors]      bg_hex                 → UI_BG_HEX
;   [colors]      border_white/alpha_ahk → UI_BORDER_COLOR_HEX / UI_BORDER_ALPHA
;   [colors]      border_width           → UI_BORDER_THICKNESS
;   [colors]      label_hex              → UI_LABEL_COLOR_HEX
;   [tint]        lightness              → UI_TINT_LIGHTNESS
;   [tint]        saturation             → UI_TINT_SATURATION
;   [positioning] caret_offset_y         → UI_OFFSET_BELOW
;   [positioning] caret_offset_x         → UI_OFFSET_RIGHT
;   [positioning] max_caret_height       → UI_MAX_CARET_HEIGHT_PX
;   [positioning] window_bottom_inset_ahk→ UI_WINDOW_BOTTOM_INSET_PX
; ==============================================================================

; All globals below are uninitialized sentinels — UiStyle_LoadSharedConst()
; MUST run at startup and will overwrite every value from constants.toml.
; If the TOML is absent the script exits immediately (fail fast).

; ── Typography ──────────────────────────────────────────────────────────────
global UI_FONT_NAME       := "Segoe UI"   ; AHK-only constant, not in TOML
global UI_FONT_SIZE_MAIN  := 0
global UI_FONT_SIZE_HINT  := 0

; ── Layout ──────────────────────────────────────────────────────────────────
global UI_PAD_X           := 0
global UI_PAD_Y           := 0
global UI_LABEL_GAP       := 0
global UI_CORNER_RADIUS   := 0

; ── Colors ───────────────────────────────────────────────────────────────────
global UI_BG_HEX          := ""
global UI_BORDER_COLOR_HEX := "FFFFFF"   ; AHK-only constant, not in TOML
global UI_BORDER_ALPHA     := 0
global UI_BORDER_THICKNESS := 1          ; AHK-only constant, not in TOML
global UI_LABEL_COLOR_HEX  := ""

; ── Tint mixing ─────────────────────────────────────────────────────────────
global UI_TINT_LIGHTNESS   := 0
global UI_TINT_SATURATION  := 0

; ── Positioning offsets ──────────────────────────────────────────────────────
; UI_OFFSET_RIGHT is AHK-only (Windows GDI vs macOS canvas coordinate systems).
global UI_OFFSET_BELOW           := 0
global UI_OFFSET_RIGHT           := 4
global UI_MAX_CARET_HEIGHT_PX    := 0
global UI_WINDOW_BOTTOM_INSET_PX := 0

; ── LLM diff-coloring ────────────────────────────────────────────────────────
global UI_LLM_CORR_SEL_HEX   := ""
global UI_LLM_NW_SEL_HEX     := ""
global UI_LLM_UNSEL_GRAY_HEX := ""
global UI_LLM_LOADING_HEX    := ""

; ── Timing ───────────────────────────────────────────────────────────────────
global UI_HOTSTRING_TIMEOUT_SEC := 0
global UI_LLM_TIMEOUT_SEC       := 0
global UI_TIMEOUT_DECREMENT_SEC := 0
global UI_TIMEOUT_FLOOR_SEC     := 0





; ====================================================================
; ====================================================================
; ======= 2/ Runtime loader from shared/tooltip/constants.toml =======
; ====================================================================
; =================================================================

/**
 * Reads shared/tooltip/constants.toml at startup and overwrites the compile-
 * time fallback globals declared in section 1. Uses _SharedDir (set by the
 * main entry point) + ParseTomlFile + IniCacheGet (same helpers as WPMWidget).
 * On any read failure the compile-time fallbacks remain active and an error
 * is logged so divergence is immediately visible.
 * @returns void
 */
UiStyle_LoadSharedConst() {
	global _SharedDir
	path := _SharedDir . "\tooltip\constants.toml"
	c := ParseTomlFile(path)
	if !c.Count {
		LoggerError("UiStyle", "shared/tooltip/constants.toml not found — cannot start.")
		MsgBox("Erreur fatale : shared/tooltip/constants.toml introuvable.`nErgopti+ ne peut pas démarrer.", "ErgoptiPlus", 16)
		ExitApp()
	}

	; [typography] — platform-specific keys only (font names are AHK-specific)
	global UI_FONT_SIZE_MAIN       := Integer(IniCacheGet(c, "typography", "font_size_main_ahk", UI_FONT_SIZE_MAIN))
	global UI_FONT_SIZE_HINT       := Integer(IniCacheGet(c, "typography", "font_size_hint_ahk", UI_FONT_SIZE_HINT))

	; [layout]
	global UI_PAD_X                := Integer(IniCacheGet(c, "layout", "pad_x",        UI_PAD_X))
	global UI_PAD_Y                := Integer(IniCacheGet(c, "layout", "pad_y",        UI_PAD_Y))
	global UI_LABEL_GAP            := Integer(IniCacheGet(c, "layout", "label_gap",    UI_LABEL_GAP))
	; GDI nWidth/nHeight = full ellipse diameter = 2 × corner_radius.
	global UI_CORNER_RADIUS        := Integer(IniCacheGet(c, "layout", "corner_radius", UI_CORNER_RADIUS // 2)) * 2

	; [colors]
	global UI_BG_HEX               := SubStr(IniCacheGet(c, "colors", "bg_hex",           "#" . UI_BG_HEX), 2)
	global UI_LABEL_COLOR_HEX      := SubStr(IniCacheGet(c, "colors", "label_hex",        "#" . UI_LABEL_COLOR_HEX), 2)
	global UI_BORDER_ALPHA         := Float(IniCacheGet(c,  "colors", "border_alpha_ahk",  UI_BORDER_ALPHA))

	; [tint]
	global UI_TINT_LIGHTNESS       := Float(IniCacheGet(c, "tint", "lightness",  UI_TINT_LIGHTNESS))
	global UI_TINT_SATURATION      := Float(IniCacheGet(c, "tint", "saturation", UI_TINT_SATURATION))

	; [positioning]
	global UI_OFFSET_BELOW           := Integer(IniCacheGet(c, "positioning", "caret_offset_y",           UI_OFFSET_BELOW))
	global UI_MAX_CARET_HEIGHT_PX    := Integer(IniCacheGet(c, "positioning", "max_caret_height",          UI_MAX_CARET_HEIGHT_PX))
	global UI_WINDOW_BOTTOM_INSET_PX := Integer(IniCacheGet(c, "positioning", "window_bottom_inset_ahk",   UI_WINDOW_BOTTOM_INSET_PX))

	; [timing]
	global UI_HOTSTRING_TIMEOUT_SEC := Float(IniCacheGet(c, "timing", "hotstring_timeout_sec", UI_HOTSTRING_TIMEOUT_SEC))
	global UI_LLM_TIMEOUT_SEC       := Float(IniCacheGet(c, "timing", "llm_timeout_sec",       UI_LLM_TIMEOUT_SEC))
	global UI_TIMEOUT_DECREMENT_SEC := Float(IniCacheGet(c, "timing", "timeout_decrement_sec", UI_TIMEOUT_DECREMENT_SEC))
	global UI_TIMEOUT_FLOOR_SEC     := Float(IniCacheGet(c, "timing", "timeout_floor_sec",     UI_TIMEOUT_FLOOR_SEC))

	; [llm_colors] — diff-chunk rendering colors for the LLM multi-slot tooltip.
	; The TOML carries *_hex aliases (no leading #) for drivers that only accept hex.
	global UI_LLM_CORR_SEL_HEX   := SubStr(IniCacheGet(c, "llm_colors", "corr_sel_hex",   "#" . UI_LLM_CORR_SEL_HEX), 2)
	global UI_LLM_NW_SEL_HEX     := SubStr(IniCacheGet(c, "llm_colors", "nw_sel_hex",     "#" . UI_LLM_NW_SEL_HEX), 2)
	global UI_LLM_UNSEL_GRAY_HEX := SubStr(IniCacheGet(c, "llm_colors", "unsel_gray_hex", "#" . UI_LLM_UNSEL_GRAY_HEX), 2)
	global UI_LLM_LOADING_HEX    := SubStr(IniCacheGet(c, "llm_colors", "loading_hex",    "#" . UI_LLM_LOADING_HEX), 2)

	LoggerDone("UiStyle", "Shared tooltip constants loaded (pad_x={1} corner_r={2} bg={3} tmo={4}s corr={5} nw={6}).",
		UI_PAD_X, UI_CORNER_RADIUS, UI_BG_HEX, UI_HOTSTRING_TIMEOUT_SEC, UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX)
}




; ==============================================
; ==============================================
; ======= 3/ Dynamic button width helper =======
; ==============================================
; ==============================================

; Minimum dynamic button width applied across the codebase. Matches the
; historical `w90` used in onboarding — short labels (OK / Yes / No) keep
; their original heft, longer ones grow to fit.
global UI_BTN_MIN_W := 90

; Equalises the widths of a row of buttons so every button is sized to the
; widest natural text in the set. Intended for symmetric pairs (OK/Cancel,
; Back/Next, Reset/All-grey) where uneven widths look broken AND a too-narrow
; default would clip long localised captions like German "Durchsuchen" or
; "Zurücksetzen".
;
; Each button must already be on the Gui (its X / Y / row layout is preserved
; — only W is updated). Callers should add the buttons with NO explicit ``w``
; option so AHK computes the natural text width first; this helper then
; overrides with the harmonised value.
;
; @param buttons   Array  Button control objects to harmonise (1+ elements).
; @param minWidth  Int    Floor applied to the natural max so short labels
;                         don't shrink below the historical look (~90 px).
; @returns Int     The shared width that was applied to every button.
Gui_HarmoniseButtonWidths(buttons, minWidth := unset) {
	if (buttons.Length == 0)
		return 0
	floorW := IsSet(minWidth) ? minWidth : UI_BTN_MIN_W
	sharedW := floorW
	for btn in buttons {
		btn.GetPos(, , &w, )
		if (w > sharedW)
			sharedW := w
	}
	for btn in buttons {
		btn.Move(, , sharedW)
	}
	return sharedW
}
