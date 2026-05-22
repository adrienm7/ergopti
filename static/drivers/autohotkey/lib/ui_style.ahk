; drivers/autohotkey/lib/ui_style.ahk

; ==============================================================================
; MODULE: UI Style Constants
; DESCRIPTION:
; Single source of truth for all visual style constants shared across AHK UI
; components. Mirrors the values defined in the Hammerspoon counterpart
; ui/tooltip/config.lua so both drivers produce a visually identical tooltip.
;
; FEATURES & RATIONALE:
; 1. Cross-driver parity: every constant here has a named equivalent in
;    config.lua so divergences are immediately visible during review.
; 2. No magic numbers: every tooltip.ahk layout value must originate here.
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
global UI_CORNER_RADIUS   := 8

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
; Mirrors: Config.layout.caret_offset_y = 18, caret_offset_x = 15
global UI_OFFSET_BELOW    := 18
global UI_OFFSET_RIGHT    := 4
; Mirrors: Config.layout.max_caret_height = 80
global UI_MAX_CARET_HEIGHT_PX      := 80
; Mirrors: Config.layout.window_bottom_inset = 40  (AHK uses a larger inset)
global UI_WINDOW_BOTTOM_INSET_PX   := 60





; ===========================================
; ===========================================
; ======= 2/ Dynamic button width helper ====
; ===========================================
; ===========================================

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
	floor := IsSet(minWidth) ? minWidth : UI_BTN_MIN_W
	sharedW := floor
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
