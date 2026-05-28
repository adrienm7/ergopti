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

; ── Typography ──────────────────────────────────────────────────────────────
; Mirrors: Config.fonts.main = ".AppleSystemUIFont"  (system UI font on macOS)
global UI_FONT_NAME       := "Segoe UI"   ; system UI font on Windows
; Mirrors: Config.sizes.main = 14
global UI_FONT_SIZE_MAIN  := 11           ; AHK logical px ≈ HS pt 14 on 125 % DPI
; Mirrors: Config.sizes.hint = 11
global UI_FONT_SIZE_HINT  := 11           ; trigger-label / hint font size

; ── Layout ──────────────────────────────────────────────────────────────────
; Mirrors: Config.layout.pad_x = 14
global UI_PAD_X           := 14
; Mirrors: Config.layout.pad_y = 7
global UI_PAD_Y           := 7
; Gap between the expansion text column and the trigger-label column.
; Mirrors: label_gap = 16 in renderer.lua
global UI_LABEL_GAP       := 16

; ── Rounded corners ─────────────────────────────────────────────────────────
; Corner ellipse diameter passed to GDI CreateRoundRectRgn (nWidth/nHeight).
; GDI nWidth/nHeight = full ellipse diameter, so the arc at each corner has a
; radius of UI_CORNER_RADIUS / 2.  Setting this to 14 gives a 7 px radius per
; corner, matching Hammerspoon's xRadius=7 canvas pts exactly.  Fixed size —
; not proportional to window dimensions.
global UI_CORNER_RADIUS   := 14

; ── Colors ───────────────────────────────────────────────────────────────────
; Near-black default background.  Mirrors: Config.colors.bg = { white=0.10 }
global UI_BG_HEX          := "1A1A1A"
; Border ring color and opacity.  Mirrors: strokeColor = { white=1, alpha=0.25 }
global UI_BORDER_COLOR_HEX := "FFFFFF"
global UI_BORDER_ALPHA     := 0.25
; 1 px logical border drawn via a layered Gui overlay.
global UI_BORDER_THICKNESS := 1
; Trigger-label symbol color (★, ↵) — lighter than mid-gray, dimmer than the
; expansion text (FFFFFF) so the symbol reads as secondary information.
global UI_LABEL_COLOR_HEX  := "AAAAAA"

; ── Tint mixing ─────────────────────────────────────────────────────────────
; HSL target when mixing an accent hue into the background.
; Mirrors: renderer.lua — lightness 0.10, saturation 0.40.
global UI_TINT_LIGHTNESS   := 0.10
global UI_TINT_SATURATION  := 0.40

; ── Positioning offsets ──────────────────────────────────────────────────────
; Mirrors: Config.layout.caret_offset_y = 18 (identical on both platforms).
; UI_OFFSET_RIGHT is intentionally different from macOS caret_offset_x = 15:
; Windows GDI positioning uses screen coordinates relative to the caret bounding
; box, whereas macOS canvas offsets are in logical points — 4 px here produces
; the same perceived clearance as 15 pts on macOS at typical display densities.
global UI_OFFSET_BELOW    := 18
global UI_OFFSET_RIGHT    := 4
; Mirrors: Config.layout.max_caret_height = 80
global UI_MAX_CARET_HEIGHT_PX      := 80
; Mirrors: Config.layout.window_bottom_inset = 40  (AHK uses a larger inset)
global UI_WINDOW_BOTTOM_INSET_PX   := 60

; ── LLM diff-coloring (from shared/tooltip/constants.toml [llm_colors]) ────────
; Overwritten by UiStyle_LoadSharedConst() at startup.
; corr_sel  — corrected text in the active slot (green).   Mirrors: corr_sel  { r=0.25 g=0.90 b=0.40 }
; nw_sel    — next-words text in the active slot (orange).  Mirrors: nw_sel   { r=1.00 g=0.62 b=0.10 }
; unsel_gray — all text in non-active slots (mid-gray).     Mirrors: unsel_gray { white=0.50 }
; loading   — placeholder text while a slot is generating.  Mirrors: loading  { r=0.94 g=0.78 b=0.28 }
global UI_LLM_CORR_SEL_HEX   := "40E666"   ; #40E666  ≈ green
global UI_LLM_NW_SEL_HEX     := "FF9E1A"   ; #FF9E1A  ≈ orange
global UI_LLM_UNSEL_GRAY_HEX := "808080"   ; #808080  ≈ mid-gray
global UI_LLM_LOADING_HEX    := "F0C747"   ; #F0C747  ≈ yellow-amber

; ── Timing defaults (from shared/tooltip/constants.toml [timing]) ─────────────
; Overwritten by UiStyle_LoadSharedConst() at startup; hardcoded here as
; compile-time fallbacks in case the TOML file is absent.
global UI_HOTSTRING_TIMEOUT_SEC := 2.5
global UI_LLM_TIMEOUT_SEC       := 12.0
global UI_TIMEOUT_DECREMENT_SEC := 0.2
global UI_TIMEOUT_FLOOR_SEC     := 0.05





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
		LoggerError("UiStyle", "shared/tooltip/constants.toml not found — UI constants remain at compile-time defaults.")
		return
	}

	; [typography] — platform-specific keys only (font names are AHK-specific)
	global UI_FONT_SIZE_MAIN       := Integer(IniCacheGet(c, "typography", "font_size_main_ahk", "11"))
	global UI_FONT_SIZE_HINT       := Integer(IniCacheGet(c, "typography", "font_size_hint_ahk", "11"))

	; [layout]
	global UI_PAD_X                := Integer(IniCacheGet(c, "layout", "pad_x",        "14"))
	global UI_PAD_Y                := Integer(IniCacheGet(c, "layout", "pad_y",         "7"))
	global UI_LABEL_GAP            := Integer(IniCacheGet(c, "layout", "label_gap",    "16"))
	; GDI nWidth/nHeight = full ellipse diameter = 2 × corner_radius.
	global UI_CORNER_RADIUS        := Integer(IniCacheGet(c, "layout", "corner_radius", "7")) * 2

	; [colors]
	global UI_BG_HEX               := SubStr(IniCacheGet(c, "colors", "bg_hex", "#1A1A1A"), 2)   ; strip leading #
	global UI_LABEL_COLOR_HEX      := SubStr(IniCacheGet(c, "colors", "label_hex", "#AAAAAA"), 2)
	global UI_BORDER_ALPHA         := Float(IniCacheGet(c, "colors", "border_alpha_ahk", "0.25"))

	; [tint]
	global UI_TINT_LIGHTNESS       := Float(IniCacheGet(c, "tint", "lightness",  "0.10"))
	global UI_TINT_SATURATION      := Float(IniCacheGet(c, "tint", "saturation", "0.40"))

	; [positioning]
	global UI_OFFSET_BELOW         := Integer(IniCacheGet(c, "positioning", "caret_offset_y",          "18"))
	global UI_MAX_CARET_HEIGHT_PX  := Integer(IniCacheGet(c, "positioning", "max_caret_height",         "80"))
	global UI_WINDOW_BOTTOM_INSET_PX := Integer(IniCacheGet(c, "positioning", "window_bottom_inset_ahk","60"))

	; [timing]
	global UI_HOTSTRING_TIMEOUT_SEC := Float(IniCacheGet(c, "timing", "hotstring_timeout_sec", "2.5"))
	global UI_LLM_TIMEOUT_SEC       := Float(IniCacheGet(c, "timing", "llm_timeout_sec",       "12.0"))
	global UI_TIMEOUT_DECREMENT_SEC := Float(IniCacheGet(c, "timing", "timeout_decrement_sec", "0.2"))
	global UI_TIMEOUT_FLOOR_SEC     := Float(IniCacheGet(c, "timing", "timeout_floor_sec",     "0.05"))

	; [llm_colors] — diff-chunk rendering colors for the LLM multi-slot tooltip.
	; The TOML carries *_hex aliases (no leading #) for drivers that only accept hex.
	global UI_LLM_CORR_SEL_HEX   := SubStr(IniCacheGet(c, "llm_colors", "corr_sel_hex",   "#40E666"), 2)
	global UI_LLM_NW_SEL_HEX     := SubStr(IniCacheGet(c, "llm_colors", "nw_sel_hex",     "#FF9E1A"), 2)
	global UI_LLM_UNSEL_GRAY_HEX := SubStr(IniCacheGet(c, "llm_colors", "unsel_gray_hex", "#808080"), 2)
	global UI_LLM_LOADING_HEX    := SubStr(IniCacheGet(c, "llm_colors", "loading_hex",    "#F0C747"), 2)

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
