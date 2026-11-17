; core/ui/engine/style.ahk

; ==============================================================================
; MODULE: UI Style Constants
; DESCRIPTION:
; AHK-side consumer of the cross-driver tooltip visual constants.  The canonical
; source of truth is static/ergopti_plus/_shared/core/ui/data/tooltip/constants.toml — all
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
;   [layout]      llm_max_content_width  → UI_LLM_MAX_CONTENT_WIDTH
;   [layout]      corner_radius × 2      → UI_CORNER_RADIUS (GDI diameter)
;   [colors]      bg_hex                 → UI_BG_HEX
;   [colors]      border_white/alpha_ahk → UI_BORDER_COLOR_HEX / UI_BORDER_ALPHA
;   [colors]      label_hex              → UI_LABEL_COLOR_HEX
;   [colors]      loading_text_hex       → UI_LOADING_TEXT_HEX
;   [layout]      screen_margin          → UI_SCREEN_MARGIN
;   [positioning] window_offset_y        → UI_WINDOW_OFFSET_Y
;   [tint]        lightness              → UI_TINT_LIGHTNESS
;   [tint]        saturation             → UI_TINT_SATURATION
;   [llm_colors]  cursor_hex             → UI_LLM_CURSOR_HEX
;   [llm_colors]  cmd_dim_hex            → UI_LLM_CMD_DIM_HEX
;   [llm_ui]      active_prefix          → UI_LLM_ACTIVE_PREFIX
;   [llm_ui]      slot_placeholder       → UI_LLM_SLOT_PLACEHOLDER
;   [llm_ui]      footer_space_divider   → UI_LLM_FOOTER_SPACE_DIV
;   [llm_ui]      hint_accept_key        → UI_LLM_HINT_ACCEPT_KEY
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
global UI_FONT_NAME       := ""
global UI_FONT_SIZE_MAIN  := 0
global UI_FONT_SIZE_HINT  := 0
global UI_FONT_SIZE_INFO  := 0

; ── Layout ──────────────────────────────────────────────────────────────────
global UI_PAD_X           := 0
global UI_PAD_Y           := 0
global UI_LABEL_GAP       := 0
global UI_LLM_MAX_CONTENT_WIDTH := 0
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
global UI_LOADING_TEXT_HEX := ""
; The main text colour of a tooltip row ([colors] text_white as a grey).
global UI_TEXT_HEX         := ""
; Whether Windows high contrast replaced the colours above with system ones
; (UiStyle_ApplySystemAccessibility); the tint wash is dropped then.
global UI_HIGH_CONTRAST    := false

; ── Tint mixing ─────────────────────────────────────────────────────────────
global UI_TINT_LIGHTNESS   := 0
global UI_TINT_SATURATION  := 0

; ── Positioning offsets ──────────────────────────────────────────────────────
; Layout units: callers scale them by the DPI factor before adding them to
; physical screen coordinates.
global UI_OFFSET_BELOW           := 0
global UI_OFFSET_RIGHT           := 0
global UI_WINDOW_OFFSET_Y        := 0
global UI_SCREEN_MARGIN          := 0
global UI_MAX_CARET_HEIGHT_PX    := 0
global UI_WINDOW_BOTTOM_INSET_PX := 0

; ── LLM diff-coloring ────────────────────────────────────────────────────────
global UI_LLM_CORR_SEL_HEX   := ""
global UI_LLM_NW_SEL_HEX     := ""
global UI_LLM_UNSEL_GRAY_HEX := ""
global UI_LLM_LOADING_HEX    := ""
global UI_LLM_CURSOR_HEX     := ""
global UI_LLM_CMD_DIM_HEX    := ""
global UI_AI_LOADING_HEX     := ""

; ── LLM tooltip UI chrome (_shared/core/ui/data/tooltip/constants.toml [llm_ui]) ───────────
global UI_LLM_ACTIVE_PREFIX         := ""
global UI_LLM_SLOT_PLACEHOLDER      := ""
global UI_LLM_INACTIVE_ALIGN_CHAR   := ""
global UI_LLM_FOOTER_SPACE_DIV      := ""
global UI_LLM_FOOTER_COMBINED_SEP   := ""
global UI_LLM_SHORTCUT_ORDER        := ""
global UI_LLM_SHORTCUT_JOINER       := ""
global UI_LLM_HINT_ACCEPT_KEY       := ""
global UI_LLM_HINT_NAV_LEFT_KEYS    := ""
global UI_LLM_HINT_NAV_RIGHT_KEYS   := ""
global UI_LLM_HINT_ARROW_LEFT       := ""
global UI_LLM_HINT_ARROW_RIGHT      := ""
global UI_LLM_HINT_ARROW_SEP_LEFT   := ""
global UI_LLM_HINT_ARROW_SEP_RIGHT  := ""

; ── Timing ───────────────────────────────────────────────────────────────────
global UI_HOTSTRING_TIMEOUT_SEC := 0
global UI_LLM_TIMEOUT_SEC       := 0
global UI_TIMEOUT_DECREMENT_SEC := 0
global UI_TIMEOUT_FLOOR_SEC     := 0
global UI_TOOLTIP_SAFETY_SEC    := 0





; ==================================================================================
; ==================================================================================
; ======= 2/ Runtime loader from _shared/core/ui/data/tooltip/constants.toml =======
; ==================================================================================
; ==================================================================================

_UiStyleFatal(section, key, detail := "") {
	msg := Format(t("dialog.fatal_error.toml_key_missing"), section, key)
	if (detail != "")
		msg .= "`n" . detail
	LoggerError("UiStyle", msg)
	Ui_MsgBox(msg . "`n" . t("dialog.fatal_error.cannot_start"), "", 16)
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

/** * Reads _shared/core/ui/data/tooltip/constants.toml at startup and assigns every tooltip
 * global from the TOML single source of truth. Uses _SharedDir (set by the
 * main entry point) + ParseTomlFile + IniCacheGet.
 * Missing file or missing key → MsgBox + ExitApp (fail fast).
 * @returns void
 */
UiStyle_LoadSharedConst() {
	global _SharedDir
	path := _SharedDir . "\core\ui\data\tooltip\constants.toml"
	c := ParseTomlFile(path)
	if !c.Count {
		LoggerError("UiStyle", "_shared/core/ui/data/tooltip/constants.toml not found — cannot start.")
		Ui_MsgBox(t("dialog.fatal_error.toml_not_found") . "`n" . t("dialog.fatal_error.cannot_start"), "", 16)
		ExitApp()
	}

	; [typography] — the *_ahk keys; macOS reads the *_hs siblings.
	global UI_FONT_NAME            := _UiStyleRequire(c, "typography", "font_main_ahk")
	global UI_FONT_SIZE_MAIN       := Integer(_UiStyleRequire(c, "typography", "font_size_main_ahk"))
	global UI_FONT_SIZE_HINT       := Integer(_UiStyleRequire(c, "typography", "font_size_hint_ahk"))
	global UI_FONT_SIZE_INFO       := Integer(_UiStyleRequire(c, "typography", "font_size_info_ahk"))

	; [layout]
	global UI_PAD_X                := Integer(_UiStyleRequire(c, "layout", "pad_x"))
	global UI_PAD_Y                := Integer(_UiStyleRequire(c, "layout", "pad_y"))
	global UI_LABEL_GAP            := Integer(_UiStyleRequire(c, "layout", "label_gap"))
	global UI_LLM_MAX_CONTENT_WIDTH := Integer(_UiStyleRequire(c, "layout", "llm_max_content_width"))
	global UI_LINE_SPACING         := Integer(_UiStyleRequire(c, "layout", "line_spacing"))
	global UI_HINT_SPACING         := Integer(_UiStyleRequire(c, "layout", "hint_spacing"))
	; GDI nWidth/nHeight = full ellipse diameter = 2 × corner_radius.
	global UI_CORNER_RADIUS        := Integer(_UiStyleRequire(c, "layout", "corner_radius")) * 2

	; [colors]
	global UI_BG_HEX               := _UiStyleRequireHex(c, "colors", "bg_hex")
	text_v := Round(255 * Float(_UiStyleRequire(c, "colors", "text_white")))
	global UI_TEXT_HEX             := Format("{1:02X}{1:02X}{1:02X}", text_v)
	global UI_LABEL_COLOR_HEX      := _UiStyleRequireHex(c, "colors", "label_hex")
	global UI_HINT_COLOR_HEX       := _UiStyleRequireHex(c, "colors", "hint_hex")
	global UI_INFO_COLOR_HEX       := _UiStyleRequireHex(c, "colors", "info_hex")
	global UI_DIM_COLOR_HEX        := _UiStyleRequireHex(c, "colors", "dim_hex")
	global UI_LOADING_TEXT_HEX     := _UiStyleRequireHex(c, "colors", "loading_text_hex")
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
	global UI_OFFSET_RIGHT           := Integer(_UiStyleRequire(c, "positioning", "caret_offset_x"))
	global UI_WINDOW_OFFSET_Y        := Integer(_UiStyleRequire(c, "positioning", "window_offset_y"))
	global UI_SCREEN_MARGIN          := Integer(_UiStyleRequire(c, "layout", "screen_margin"))
	global UI_MAX_CARET_HEIGHT_PX    := Integer(_UiStyleRequire(c, "positioning", "max_caret_height"))
	global UI_WINDOW_BOTTOM_INSET_PX := Integer(_UiStyleRequire(c, "positioning", "window_bottom_inset_ahk"))

	; [timing]
	global UI_HOTSTRING_TIMEOUT_SEC := Float(_UiStyleRequire(c, "timing", "hotstring_timeout_sec"))
	global UI_LLM_TIMEOUT_SEC       := Float(_UiStyleRequire(c, "timing", "llm_timeout_sec"))
	global UI_TIMEOUT_DECREMENT_SEC := Float(_UiStyleRequire(c, "timing", "timeout_decrement_sec"))
	global UI_TIMEOUT_FLOOR_SEC     := Float(_UiStyleRequire(c, "timing", "timeout_floor_sec"))
	; A preview shown with no delay hides after this, on the three OS (TWD-1).
	global UI_TOOLTIP_SAFETY_SEC    := Float(_UiStyleRequire(c, "timing", "safety_timeout_sec"))

	; [llm_colors] — diff-chunk rendering colors for the LLM multi-slot tooltip.
	global UI_LLM_CORR_SEL_HEX   := _UiStyleRequireHex(c, "llm_colors", "corr_sel_hex")
	global UI_LLM_NW_SEL_HEX     := _UiStyleRequireHex(c, "llm_colors", "nw_sel_hex")
	global UI_LLM_UNSEL_GRAY_HEX := _UiStyleRequireHex(c, "llm_colors", "unsel_gray_hex")
	global UI_LLM_LOADING_HEX    := _UiStyleRequireHex(c, "llm_colors", "loading_hex")
	global UI_LLM_CURSOR_HEX     := _UiStyleRequireHex(c, "llm_colors", "cursor_hex")
	global UI_LLM_CMD_DIM_HEX    := _UiStyleRequireHex(c, "llm_colors", "cmd_dim_hex")
	global UI_AI_LOADING_HEX     := _UiStyleRequireHex(c, "accent_colors", "ai_loading_hex")

	; [llm_ui] — structural LLM tooltip chrome
	global UI_LLM_ACTIVE_PREFIX        := _UiStyleRequire(c, "llm_ui", "active_prefix")
	global UI_LLM_SLOT_PLACEHOLDER     := _UiStyleRequire(c, "llm_ui", "slot_placeholder")
	global UI_LLM_INACTIVE_ALIGN_CHAR  := _UiStyleRequire(c, "llm_ui", "inactive_align_char")
	global UI_LLM_FOOTER_SPACE_DIV     := _UiStyleRequire(c, "llm_ui", "footer_space_divider")
	global UI_LLM_FOOTER_COMBINED_SEP  := _UiStyleRequire(c, "llm_ui", "footer_combined_separator")
	; The modifiers of the order are named by the shared key name table
	; (KeyNameLabel), in the active language.
	global UI_LLM_SHORTCUT_ORDER       := _UiStyleRequire(c, "llm_ui", "shortcut_modifier_order")
	global UI_LLM_SHORTCUT_JOINER      := _UiStyleRequire(c, "llm_ui", "shortcut_joiner_ahk")
	; The footer's keys are key name ids its words name in the active language
	; (_LLM_BuildNavHint); the words themselves are locale text.
	global UI_LLM_HINT_ACCEPT_KEY      := _UiStyleRequire(c, "llm_ui", "hint_accept_key")
	global UI_LLM_HINT_NAV_LEFT_KEYS   := _UiStyleRequire(c, "llm_ui", "hint_nav_left_keys")
	global UI_LLM_HINT_NAV_RIGHT_KEYS  := _UiStyleRequire(c, "llm_ui", "hint_nav_right_keys")
	global UI_LLM_HINT_ARROW_LEFT      := _UiStyleRequire(c, "llm_ui", "hint_arrow_left")
	global UI_LLM_HINT_ARROW_RIGHT     := _UiStyleRequire(c, "llm_ui", "hint_arrow_right")
	global UI_LLM_HINT_ARROW_SEP_LEFT  := _UiStyleRequire(c, "llm_ui", "hint_arrow_sep_left")
	global UI_LLM_HINT_ARROW_SEP_RIGHT := _UiStyleRequire(c, "llm_ui", "hint_arrow_sep_right")

	LoggerDone("UiStyle", "Shared tooltip constants loaded (pad_x={1} corner_r={2} bg={3} tmo={4}s corr={5} nw={6}).",
		UI_PAD_X, UI_CORNER_RADIUS, UI_BG_HEX, UI_HOTSTRING_TIMEOUT_SEC, UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX)

	; The values just read are the base the system's accessibility settings
	; adjust; a later settings change starts again from them.
	global _UiStyleBase := _UiStyleSnapshot()
	global _UiStyleAppliedKey := ""
	if IsSet(A11ySystem_State)
		UiStyle_ApplySystemAccessibility(A11ySystem_State())

	; Refresh dependent modules that captured these values at include-time.
	if IsSet(Tooltip_UpdateStyles)
		Tooltip_UpdateStyles()
	if IsSet(Tooltip_LlmUiSyncFromShared)
		Tooltip_LlmUiSyncFromShared()
}

; The colour globals a high-contrast theme repaints in its tooltip text colour.
global UI_STYLE_TEXT_COLOR_NAMES := ["UI_TEXT_HEX", "UI_LABEL_COLOR_HEX", "UI_HINT_COLOR_HEX",
	"UI_INFO_COLOR_HEX", "UI_DIM_COLOR_HEX", "UI_LOADING_TEXT_HEX", "UI_SEP_COLOR_HEX",
	"UI_BORDER_COLOR_HEX", "UI_LLM_CORR_SEL_HEX", "UI_LLM_NW_SEL_HEX", "UI_LLM_UNSEL_GRAY_HEX",
	"UI_LLM_LOADING_HEX", "UI_LLM_CURSOR_HEX", "UI_LLM_CMD_DIM_HEX"]
; The font sizes « Make text bigger » scales.
global UI_STYLE_FONT_SIZE_NAMES := ["UI_FONT_SIZE_MAIN", "UI_FONT_SIZE_HINT", "UI_FONT_SIZE_INFO"]

; Base values loaded from constants.toml, before the system settings apply.
global _UiStyleBase := 0
; The settings last applied, so a repeated settings broadcast changes nothing.
global _UiStyleAppliedKey := ""

; The current values of the globals the system settings adjust.
; @returns {Map} Global name to value.
_UiStyleSnapshot() {
	global UI_STYLE_TEXT_COLOR_NAMES, UI_STYLE_FONT_SIZE_NAMES, UI_BG_HEX
	Values := Map("UI_BG_HEX", UI_BG_HEX)
	for Name in UI_STYLE_TEXT_COLOR_NAMES
		Values[Name] := _UiStyleRead(Name)
	for Name in UI_STYLE_FONT_SIZE_NAMES
		Values[Name] := _UiStyleRead(Name)
	return Values
}

; The tooltip style for a system state: high contrast paints every text, rule
; and border in the theme's tooltip text colour on its tooltip background, and
; the text scale enlarges the fonts (the tooltip measures its text, so it grows
; with them).
; @param Base {Map} Values from _UiStyleSnapshot.
; @param State {Object} { HighContrast, TextScalePercent, InfoBkHex, InfoTextHex }.
; @returns {Map} Global name to value, UI_HIGH_CONTRAST included.
UiStyle_AccessibleValues(Base, State) {
	global UI_STYLE_TEXT_COLOR_NAMES, UI_STYLE_FONT_SIZE_NAMES
	Values := Base.Clone()
	for Name in UI_STYLE_FONT_SIZE_NAMES
		Values[Name] := Round(Base[Name] * State.TextScalePercent / 100)
	Values["UI_HIGH_CONTRAST"] := State.HighContrast ? true : false
	if State.HighContrast {
		Values["UI_BG_HEX"] := State.InfoBkHex
		for Name in UI_STYLE_TEXT_COLOR_NAMES
			Values[Name] := State.InfoTextHex
	}
	return Values
}

; Applies the system's high contrast and text scale to the tooltip style.
; @param State {Object} As A11ySystem_State returns it.
; @returns {Boolean} Whether the style changed.
UiStyle_ApplySystemAccessibility(State) {
	global _UiStyleBase, _UiStyleAppliedKey
	if !(_UiStyleBase is Map)
		throw Error("UiStyle_ApplySystemAccessibility needs UiStyle_LoadSharedConst first")
	Key := Format("{1}|{2}|{3}|{4}", State.HighContrast ? 1 : 0, State.TextScalePercent,
		State.InfoBkHex, State.InfoTextHex)
	if (Key == _UiStyleAppliedKey)
		return false
	for Name, Value in UiStyle_AccessibleValues(_UiStyleBase, State)
		_UiStyleWrite(Name, Value)
	_UiStyleAppliedKey := Key
	try LoggerInfo("UiStyle", "Tooltip style follows the system: high contrast {1}, text {2} %.",
		State.HighContrast ? "on" : "off", State.TextScalePercent)
	return true
}

; Re-reads the system settings after Windows broadcast a change (a contrast
; theme, colours or text size), on a fresh timer turn: a WM_SETTINGCHANGE
; handler must return at once.
UiStyle_WatchSystemAccessibility() {
	OnMessage(0x001A, _UiStyleOnSystemChange)   ; WM_SETTINGCHANGE
	OnMessage(0x0015, _UiStyleOnSystemChange)   ; WM_SYSCOLORCHANGE
	try LoggerInfo("UiStyle", "Watching the system accessibility settings.")
}

_UiStyleOnSystemChange(*) {
	SetTimer(_UiStyleRefreshFromSystem, -1)
}

_UiStyleRefreshFromSystem() {
	try {
		if UiStyle_ApplySystemAccessibility(A11ySystem_State()) && IsSet(Tooltip_UpdateStyles)
			Tooltip_UpdateStyles()
	} catch as Err {
		try LoggerError("UiStyle", "The system accessibility settings could not be applied: {1}.", Err.Message)
	}
}

; Reads one of the adjusted globals by name; an unknown name is a bug.
_UiStyleRead(Name) {
	global
	switch Name {
		case "UI_BG_HEX": return UI_BG_HEX
		case "UI_TEXT_HEX": return UI_TEXT_HEX
		case "UI_LABEL_COLOR_HEX": return UI_LABEL_COLOR_HEX
		case "UI_HINT_COLOR_HEX": return UI_HINT_COLOR_HEX
		case "UI_INFO_COLOR_HEX": return UI_INFO_COLOR_HEX
		case "UI_DIM_COLOR_HEX": return UI_DIM_COLOR_HEX
		case "UI_LOADING_TEXT_HEX": return UI_LOADING_TEXT_HEX
		case "UI_SEP_COLOR_HEX": return UI_SEP_COLOR_HEX
		case "UI_BORDER_COLOR_HEX": return UI_BORDER_COLOR_HEX
		case "UI_LLM_CORR_SEL_HEX": return UI_LLM_CORR_SEL_HEX
		case "UI_LLM_NW_SEL_HEX": return UI_LLM_NW_SEL_HEX
		case "UI_LLM_UNSEL_GRAY_HEX": return UI_LLM_UNSEL_GRAY_HEX
		case "UI_LLM_LOADING_HEX": return UI_LLM_LOADING_HEX
		case "UI_LLM_CURSOR_HEX": return UI_LLM_CURSOR_HEX
		case "UI_LLM_CMD_DIM_HEX": return UI_LLM_CMD_DIM_HEX
		case "UI_FONT_SIZE_MAIN": return UI_FONT_SIZE_MAIN
		case "UI_FONT_SIZE_HINT": return UI_FONT_SIZE_HINT
		case "UI_FONT_SIZE_INFO": return UI_FONT_SIZE_INFO
		case "UI_HIGH_CONTRAST": return UI_HIGH_CONTRAST
	}
	throw ValueError("Unknown tooltip style global", -1, Name)
}

; Writes one of the adjusted globals by name; an unknown name is a bug.
_UiStyleWrite(Name, Value) {
	global
	switch Name {
		case "UI_BG_HEX": UI_BG_HEX := Value
		case "UI_TEXT_HEX": UI_TEXT_HEX := Value
		case "UI_LABEL_COLOR_HEX": UI_LABEL_COLOR_HEX := Value
		case "UI_HINT_COLOR_HEX": UI_HINT_COLOR_HEX := Value
		case "UI_INFO_COLOR_HEX": UI_INFO_COLOR_HEX := Value
		case "UI_DIM_COLOR_HEX": UI_DIM_COLOR_HEX := Value
		case "UI_LOADING_TEXT_HEX": UI_LOADING_TEXT_HEX := Value
		case "UI_SEP_COLOR_HEX": UI_SEP_COLOR_HEX := Value
		case "UI_BORDER_COLOR_HEX": UI_BORDER_COLOR_HEX := Value
		case "UI_LLM_CORR_SEL_HEX": UI_LLM_CORR_SEL_HEX := Value
		case "UI_LLM_NW_SEL_HEX": UI_LLM_NW_SEL_HEX := Value
		case "UI_LLM_UNSEL_GRAY_HEX": UI_LLM_UNSEL_GRAY_HEX := Value
		case "UI_LLM_LOADING_HEX": UI_LLM_LOADING_HEX := Value
		case "UI_LLM_CURSOR_HEX": UI_LLM_CURSOR_HEX := Value
		case "UI_LLM_CMD_DIM_HEX": UI_LLM_CMD_DIM_HEX := Value
		case "UI_FONT_SIZE_MAIN": UI_FONT_SIZE_MAIN := Value
		case "UI_FONT_SIZE_HINT": UI_FONT_SIZE_HINT := Value
		case "UI_FONT_SIZE_INFO": UI_FONT_SIZE_INFO := Value
		case "UI_HIGH_CONTRAST": UI_HIGH_CONTRAST := Value
		default: throw ValueError("Unknown tooltip style global", -1, Name)
	}
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
 * Refuses a topmost window: an ErgoptiPlus window is focused when it opens,
 * never kept above the windows the user opens afterwards (maintainer rule,
 * 2026-09-29). Overlays that must float build their Gui directly.
 * @param {string} Options - Standard AHK Gui options.
 * @param {string} Name - The suffix for the window title.
 * @returns {Gui} The instantiated Gui object.
 */
Gui_Create(Options := "", Name := "") {
    if InStr(Options, "AlwaysOnTop")
        throw ValueError("Gui_Create: a window is focused, never kept on top", -1, Options)
    Pos := 1
    while RegExMatch(Options, "i)(?:^|\s)\+?E(0x[0-9a-f]+|\d+)", &ExStyle, Pos) {
        ; WS_EX_TOPMOST (0x8) is the same flag spelled as an extended style.
        if (Integer(ExStyle[1]) & 0x8)
            throw ValueError("Gui_Create: a window is focused, never kept on top", -1, Options)
        Pos := ExStyle.Pos + ExStyle.Len
    }
    return Gui(Options, WindowTitle(Name))
}
