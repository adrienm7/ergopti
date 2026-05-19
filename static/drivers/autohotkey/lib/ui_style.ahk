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
global UI_CORNER_RADIUS   := 14

; ── Colors ───────────────────────────────────────────────────────────────────
; Near-black default background.  Mirrors: Config.colors.bg = { white=0.10 }
global UI_BG_HEX          := "1A1A1A"
; Border ring color and opacity.  Mirrors: strokeColor = { white=1, alpha=0.25 }
global UI_BORDER_COLOR_HEX := "FFFFFF"
global UI_BORDER_ALPHA     := 0.25
; 1 px logical border drawn via a layered Gui overlay.
global UI_BORDER_THICKNESS := 1

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
