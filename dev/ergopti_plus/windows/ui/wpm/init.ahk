; ui/wpm/init.ahk

; ==============================================================================
; MODULE: Real-Time WPM Widget (shim)
; DESCRIPTION:
; Thin entry point that composes the WPM widget sub-modules:
;   - wpm_display.ahk  — constants, state, ring buffer, color helpers,
;                        default position, show/hide, tick rendering loop
;   - wpm_config.ahk   — shared TOML constant loading, config persistence,
;                        position save/reset helpers
;   - wpm_widget.ahk   — compact + graph GUI builders and drag handling
;
; FEATURES & RATIONALE:
; 1. Rolling window: WPM is calculated over a configurable trailing window
;    (default 30 s) of recent keystrokes so the value reacts quickly to
;    speed changes without wild swings from isolated bursts.
; 2. Color coding: the background color encodes keystroke origin —
;      - manual keystrokes  → blue (default, user-configurable)
;      - hotstring expanded → tooltip tint from the group's TOML _meta.color + user override
;      - autocorrection     → tooltip tint from autocorrection TOML + user override
;      - IA suggestion      → purple fallback (no TOML source for AI)
;      - rolls / repeat_key → no color change (stays blue, no tooltip shown)
;    The TOML category is passed through KL_LogHotstring → WPMWidget_Push so the
;    widget color always matches the group color, not a hardcoded "magickey" fallback.
; 3. Two display modes:
;      - Compact: colored pill with large WPM number + small unit label.
;      - Graph: sparkline of recent history rendered natively with GDI+ into a
;        per-pixel-alpha layered window (no WebView2 — no browser cold-start).
; 4. Draggable: click-drag moves the widget anywhere on screen; position
;    is saved to config and restored on next launch.
; 5. Default position: bottom-right corner, above the Windows taskbar.
; 6. Zero-impact when hidden: the SetTimer tick is cancelled when the widget
;    is off — no overhead on the keystroke hot path.
; ==============================================================================

#Include wpm_display.ahk
#Include wpm_gdiplus_ownership.ahk
#Include wpm_widget.ahk
#Include wpm_config.ahk
