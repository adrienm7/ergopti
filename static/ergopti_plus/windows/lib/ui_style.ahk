; lib/ui_style.ahk

; ==============================================================================
; MODULE: UI Style Constants
; DESCRIPTION:
; AHK-side consumer of the cross-driver tooltip visual constants.  The canonical
; source of truth is static/ergopti_plus/_shared/modules/tooltip/constants.toml — all
; values are loaded at boot by UiStyle_LoadSharedConst() (fail-fast; any missing
; key aborts startup).  Do NOT edit the numbers below; edit constants.toml.
;
; FEATURES & RATIONALE:
; 1. Cross-driver parity: every constant here has a named equivalent in
;    constants.toml and in ui/tooltip/config.lua (Hammerspoon side).
;    Divergences between these three files are bugs.
; 2. No magic numbers: every tooltip.ahk layout value must originate here,
;    never be inlined at the call site.
; 3. Future-proof: Linux/WebKitGTK host will also read constants.toml directly,
;    exactly as AHK does via UiStyle_LoadSharedConst() at boot.
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
;   [llm_colors]  cursor_hex             → UI_LLM_CURSOR_HEX
;   [llm_colors]  cmd_sel_hex            → UI_LLM_CMD_SEL_HEX
;   [llm_colors]  cmd_dim_hex            → UI_LLM_CMD_DIM_HEX
;   [llm_ui]      active_prefix          → UI_LLM_ACTIVE_PREFIX
;   [llm_ui]      slot_placeholder       → UI_LLM_SLOT_PLACEHOLDER
;   [llm_ui]      footer_space_divider   → UI_LLM_FOOTER_SPACE_DIV
;   [llm_ui]      hint_accept_single     → UI_LLM_HINT_ACCEPT_SINGLE
;   [positioning] caret_offset_y         → UI_OFFSET_BELOW
;   [positioning] caret_offset_x         → UI_OFFSET_RIGHT
;   [positioning] max_caret_height       → UI_MAX_CARET_HEIGHT_PX
;   [positioning] window_bottom_inset_ahk→ UI_WINDOW_BOTTOM_INSET_PX
; ==============================================================================

; All globals below are uninitialized sentinels — UiStyle_LoadSharedConst()
; MUST run at startup and will overwrite every value from constants.toml.
; If the TOML is absent or any required key is missing the script exits
; immediately (fail fast — no compile-time fallback values).

; ── Typography ──────────────────────────────────────────────────────────────
global UI_FONT_NAME       := "Segoe UI"   ; AHK-only constant, not in TOML
global UI_FONT_SIZE_MAIN  := 0
global UI_FONT_SIZE_HINT  := 0
global UI_FONT_SIZE_INFO  := 0

; ── Layout ──────────────────────────────────────────────────────────────────
global UI_PAD_X           := 0
global UI_PAD_Y           := 0
global UI_LABEL_GAP       := 0
global UI_LINE_SPACING    := 0
global UI_HINT_SPACING    := 0
global UI_CORNER_RADIUS   := 0

; ── Colors ───────────────────────────────────────────────────────────────────
global UI_BG_HEX          := ""
global UI_SEP_COLOR_HEX     := ""   ; blended at runtime from TOML sep_alpha_ahk
global UI_DIM_COLOR_HEX     := ""
global UI_BORDER_COLOR_HEX := "FFFFFF"   ; AHK-only constant, not in TOML
global UI_BORDER_ALPHA     := 0.25
global UI_BORDER_THICKNESS := 1          ; AHK-only constant, not in TOML
global UI_LABEL_COLOR_HEX  := ""
global UI_HINT_COLOR_HEX   := ""
global UI_INFO_COLOR_HEX   := ""

; ── Tint mixing ─────────────────────────────────────────────────────────────
global UI_TINT_LIGHTNESS   := 0
global UI_TINT_SATURATION  := 0

; ── Positioning offsets ──────────────────────────────────────────────────────
; UI_OFFSET_RIGHT is AHK-only (Windows GDI vs macOS canvas coordinate systems).
global UI_OFFSET_BELOW           := 0
global UI_OFFSET_RIGHT           := 15
global UI_MAX_CARET_HEIGHT_PX    := 0
global UI_WINDOW_BOTTOM_INSET_PX := 0

; ── LLM diff-coloring ────────────────────────────────────────────────────────
global UI_LLM_CORR_SEL_HEX   := ""
global UI_LLM_NW_SEL_HEX     := ""
global UI_LLM_UNSEL_GRAY_HEX := ""
global UI_LLM_LOADING_HEX    := ""
global UI_LLM_CURSOR_HEX     := ""
global UI_LLM_CMD_SEL_HEX    := ""
global UI_LLM_CMD_DIM_HEX    := ""
global UI_AI_LOADING_HEX     := ""

; ── LLM tooltip UI chrome (_shared/modules/tooltip/constants.toml [llm_ui]) ───────────
global UI_LLM_ACTIVE_PREFIX         := ""
global UI_LLM_SLOT_PLACEHOLDER      := ""
global UI_LLM_INACTIVE_ALIGN_CHAR   := ""
global UI_LLM_FOOTER_SPACE_DIV      := ""
global UI_LLM_FOOTER_COMBINED_SEP   := ""
global UI_LLM_SHORTCUT_LABEL_GAP    := ""
global UI_LLM_HINT_ACCEPT_SINGLE    := ""
global UI_LLM_HINT_NAV_LEFT         := ""
global UI_LLM_HINT_NAV_RIGHT        := ""
global UI_LLM_HINT_ACCEPT_CENTER    := ""
global UI_LLM_HINT_ARROW_LEFT       := ""
global UI_LLM_HINT_ARROW_RIGHT      := ""
global UI_LLM_HINT_OR               := ""
global UI_LLM_HINT_ARROW_SEP_LEFT   := ""
global UI_LLM_HINT_ARROW_SEP_RIGHT  := ""

; ── Timing ───────────────────────────────────────────────────────────────────
global UI_HOTSTRING_TIMEOUT_SEC := 0
global UI_LLM_TIMEOUT_SEC       := 0
global UI_TIMEOUT_DECREMENT_SEC := 0
global UI_TIMEOUT_FLOOR_SEC     := 0





; =============================================================================
; =============================================================================
; ======= 2/ Runtime loader from _shared/modules/tooltip/constants.toml =======
; =============================================================================
; =============================================================================

_UiStyleFatal(section, key, detail := "") {
	msg := Format(t("dialog.fatal_error.toml_key_missing"), section, key)
	if (detail != "")
		msg .= "`n" . detail
	LoggerError("UiStyle", msg)
	MsgBox(msg . "`n" . t("dialog.fatal_error.cannot_start"), "ErgoptiPlus", 16)
	ExitApp()
}

_UiStyleRequire(c, section, key) {
	val := IniCacheGet(c, section, key)
	if (val = "_")
		_UiStyleFatal(section, key)
	return val
}

_UiStyleRequireHex(c, section, key) {
	val := _UiStyleRequire(c, section, key)
	if (SubStr(val, 1, 1) = "#")
		val := SubStr(val, 2)
	if (StrLen(val) != 6)
		_UiStyleFatal(section, key, "valeur hex invalide : " . val)
	return val
}

/**
 * Reads _shared/modules/tooltip/constants.toml at startup and assigns every tooltip
 * global from the TOML single source of truth. Uses _SharedDir (set by the
 * main entry point) + ParseTomlFile + IniCacheGet.
 * Missing file or missing key → MsgBox + ExitApp (fail fast).
 * @returns void
 */
UiStyle_LoadSharedConst() {
	global _SharedDir
	path := _SharedDir . "\modules\tooltip\constants.toml"
	c := ParseTomlFile(path)
	if !c.Count {
		LoggerError("UiStyle", "_shared/modules/tooltip/constants.toml not found — cannot start.")
		MsgBox(t("dialog.fatal_error.toml_not_found") . "`n" . t("dialog.fatal_error.cannot_start"), "ErgoptiPlus", 16)
		ExitApp()
	}

	; [typography] — platform-specific keys only (font names are AHK-specific)
	global UI_FONT_SIZE_MAIN       := Integer(_UiStyleRequire(c, "typography", "font_size_main_ahk"))
	global UI_FONT_SIZE_HINT       := Integer(_UiStyleRequire(c, "typography", "font_size_hint_ahk"))
	global UI_FONT_SIZE_INFO       := Integer(_UiStyleRequire(c, "typography", "font_size_info_ahk"))

	; [layout]
	global UI_PAD_X                := Integer(_UiStyleRequire(c, "layout", "pad_x"))
	global UI_PAD_Y                := Integer(_UiStyleRequire(c, "layout", "pad_y"))
	global UI_LABEL_GAP            := Integer(_UiStyleRequire(c, "layout", "label_gap"))
	global UI_LINE_SPACING         := Integer(_UiStyleRequire(c, "layout", "line_spacing"))
	global UI_HINT_SPACING         := Integer(_UiStyleRequire(c, "layout", "hint_spacing"))
	; GDI nWidth/nHeight = full ellipse diameter = 2 × corner_radius.
	global UI_CORNER_RADIUS        := Integer(_UiStyleRequire(c, "layout", "corner_radius")) * 2

	; [colors]
	global UI_BG_HEX               := _UiStyleRequireHex(c, "colors", "bg_hex")
	global UI_LABEL_COLOR_HEX      := _UiStyleRequireHex(c, "colors", "label_hex")
	global UI_HINT_COLOR_HEX       := _UiStyleRequireHex(c, "colors", "hint_hex")
	global UI_INFO_COLOR_HEX       := _UiStyleRequireHex(c, "colors", "info_hex")
	global UI_DIM_COLOR_HEX        := _UiStyleRequireHex(c, "colors", "dim_hex")
	global UI_BORDER_ALPHA         := Float(_UiStyleRequire(c, "colors", "border_alpha_ahk"))

	; Separator blending: TOML gives sep_alpha_ahk. AHK cannot do per-control
	; transparency, so we pre-blend white onto the background color here.
	sep_alpha := Float(_UiStyleRequire(c, "colors", "sep_alpha_ahk"))
	bg_v := Integer("0x" . SubStr(UI_BG_HEX, 1, 2))
	sep_v := Round(bg_v * (1 - sep_alpha) + 255 * sep_alpha)
	global UI_SEP_COLOR_HEX := Format("{1:02X}{2:02X}{3:02X}", sep_v, sep_v, sep_v)

	; [tint]
	global UI_TINT_LIGHTNESS       := Float(_UiStyleRequire(c, "tint", "lightness"))
	global UI_TINT_SATURATION      := Float(_UiStyleRequire(c, "tint", "saturation"))

	; [positioning]
	global UI_OFFSET_BELOW           := Integer(_UiStyleRequire(c, "positioning", "caret_offset_y"))
	global UI_MAX_CARET_HEIGHT_PX    := Integer(_UiStyleRequire(c, "positioning", "max_caret_height"))
	global UI_WINDOW_BOTTOM_INSET_PX := Integer(_UiStyleRequire(c, "positioning", "window_bottom_inset_ahk"))

	; [timing]
	global UI_HOTSTRING_TIMEOUT_SEC := Float(_UiStyleRequire(c, "timing", "hotstring_timeout_sec"))
	global UI_LLM_TIMEOUT_SEC       := Float(_UiStyleRequire(c, "timing", "llm_timeout_sec"))
	global UI_TIMEOUT_DECREMENT_SEC := Float(_UiStyleRequire(c, "timing", "timeout_decrement_sec"))
	global UI_TIMEOUT_FLOOR_SEC     := Float(_UiStyleRequire(c, "timing", "timeout_floor_sec"))

	; [llm_colors] — diff-chunk rendering colors for the LLM multi-slot tooltip.
	global UI_LLM_CORR_SEL_HEX   := _UiStyleRequireHex(c, "llm_colors", "corr_sel_hex")
	global UI_LLM_NW_SEL_HEX     := _UiStyleRequireHex(c, "llm_colors", "nw_sel_hex")
	global UI_LLM_UNSEL_GRAY_HEX := _UiStyleRequireHex(c, "llm_colors", "unsel_gray_hex")
	global UI_LLM_LOADING_HEX    := _UiStyleRequireHex(c, "llm_colors", "loading_hex")
	global UI_LLM_CURSOR_HEX     := _UiStyleRequireHex(c, "llm_colors", "cursor_hex")
	global UI_LLM_CMD_SEL_HEX    := _UiStyleRequireHex(c, "llm_colors", "cmd_sel_hex")
	global UI_LLM_CMD_DIM_HEX    := _UiStyleRequireHex(c, "llm_colors", "cmd_dim_hex")
	global UI_AI_LOADING_HEX     := _UiStyleRequireHex(c, "accent_colors", "ai_loading_hex")

	; [llm_ui] — structural LLM tooltip chrome
	global UI_LLM_ACTIVE_PREFIX        := _UiStyleRequire(c, "llm_ui", "active_prefix")
	global UI_LLM_SLOT_PLACEHOLDER     := _UiStyleRequire(c, "llm_ui", "slot_placeholder")
	global UI_LLM_INACTIVE_ALIGN_CHAR  := _UiStyleRequire(c, "llm_ui", "inactive_align_char")
	global UI_LLM_FOOTER_SPACE_DIV     := _UiStyleRequire(c, "llm_ui", "footer_space_divider")
	global UI_LLM_FOOTER_COMBINED_SEP  := _UiStyleRequire(c, "llm_ui", "footer_combined_separator")
	global UI_LLM_SHORTCUT_LABEL_GAP   := _UiStyleRequire(c, "llm_ui", "shortcut_label_gap")
	global UI_LLM_HINT_ACCEPT_SINGLE   := _UiStyleRequire(c, "llm_ui", "hint_accept_single")
	global UI_LLM_HINT_NAV_LEFT        := _UiStyleRequire(c, "llm_ui", "hint_nav_left")
	global UI_LLM_HINT_NAV_RIGHT       := _UiStyleRequire(c, "llm_ui", "hint_nav_right")
	global UI_LLM_HINT_ACCEPT_CENTER   := _UiStyleRequire(c, "llm_ui", "hint_accept_center")
	global UI_LLM_HINT_ARROW_LEFT      := _UiStyleRequire(c, "llm_ui", "hint_arrow_left")
	global UI_LLM_HINT_ARROW_RIGHT     := _UiStyleRequire(c, "llm_ui", "hint_arrow_right")
	global UI_LLM_HINT_OR              := _UiStyleRequire(c, "llm_ui", "hint_or")
	global UI_LLM_HINT_ARROW_SEP_LEFT  := _UiStyleRequire(c, "llm_ui", "hint_arrow_sep_left")
	global UI_LLM_HINT_ARROW_SEP_RIGHT := _UiStyleRequire(c, "llm_ui", "hint_arrow_sep_right")

	LoggerDone("UiStyle", "Shared tooltip constants loaded (pad_x={1} corner_r={2} bg={3} tmo={4}s corr={5} nw={6}).",
		UI_PAD_X, UI_CORNER_RADIUS, UI_BG_HEX, UI_HOTSTRING_TIMEOUT_SEC, UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX)

	; Refresh dependent modules that captured these values at include-time.
	if IsSet(Tooltip_UpdateStyles)
		Tooltip_UpdateStyles()
	if IsSet(Tooltip_LlmUiSyncFromShared)
		Tooltip_LlmUiSyncFromShared()
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
	for _, btn in buttons {
		btn.GetPos(, , &w, )
		if (w > sharedW)
			sharedW := w
	}
	for _, btn in buttons {
		btn.Move(, , sharedW)
	}
	return sharedW
}

/**
 * Centralized factory to create a Gui window with consistent title naming.
 * Enforces the "ErgoptiPlus — <Name>" format mandated by repo conventions.
 * @param {string} Options - Standard AHK Gui options.
 * @param {string} Name - The suffix for the window title.
 * @returns {Gui} The instantiated Gui object.
 */
Gui_Create(Options := "", Name := "") {
    Prefix := "ErgoptiPlus"
    Title := (Name == "") ? Prefix : Prefix . " — " . Name
    return Gui(Options, Title)
}
