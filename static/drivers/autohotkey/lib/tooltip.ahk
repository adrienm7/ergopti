; drivers/autohotkey/lib/tooltip.ahk

; ==============================================================================
; MODULE: Hotstring Tooltip
; DESCRIPTION:
; Floating, frameless tooltip used to preview the expansion of an in-progress
; hotstring trigger while the user is still inside the activation window.
; Mirrors the Hammerspoon tooltip both in look (per-group tinted background)
; and in lifecycle (auto-hide after a configurable duration, hide on click).
;
; FEATURES & RATIONALE:
; 1. Single reused Gui v2 — created on first show, then mutated on subsequent
;    calls. Reduces flicker and keeps allocations bounded for high-frequency
;    updates while the user is still typing the trigger.
; 2. Click-through via WS_EX_TRANSPARENT (E0x20) so the tooltip never steals
;    focus from the editor underneath, and never blocks selection.
; 3. Caret-anchored positioning via CaretGetPos with a fallback to the mouse
;    cursor when the foreground app does not expose its caret position
;    (common in Electron / web UIs without an accessible caret).
; 4. Foreground color computed from background luminance so dark and light
;    group colors both stay readable without the caller doing the math.
; ==============================================================================

; Reused Gui object — lazily created by _TooltipEnsureGui on first show.
global _TooltipGui   := 0
global _TooltipText  := 0
global _TooltipTimer := 0

; Style constants.
global _TOOLTIP_FONT_NAME      := "Segoe UI"
global _TOOLTIP_FONT_SIZE      := 11
global _TOOLTIP_PADDING_X      := 10
global _TOOLTIP_PADDING_Y      := 6
global _TOOLTIP_OFFSET_BELOW   := 18   ; pixels below the anchor (caret / box)
global _TOOLTIP_OFFSET_RIGHT   := 4    ; small horizontal nudge for caret anchor
global _TOOLTIP_DEFAULT_BG_HEX := "303030"

; Mirrors Hammerspoon's max_caret_height = 80 — when the focused element is
; tall (e.g. a multi-line text area, a list, a whole panel) we treat it as
; an "input box" anchor (bottom-centre) rather than a caret anchor, because
; the rectangle no longer represents the cursor itself.
global _TOOLTIP_MAX_CARET_HEIGHT_PX := 80

; Inset from the bottom of the active window when falling back to the
; window-frame anchor. Matches the visual feel of the Hammerspoon fallback.
global _TOOLTIP_WINDOW_BOTTOM_INSET_PX := 60


; ============================================================
; ============================================================
; ======= 1/ Public API =====================================
; ============================================================
; ============================================================

; Show or update the tooltip with the given text and background color.
; ColorHex may be in either "#rrggbb" or "rrggbb" form; an empty string falls
; back to the neutral default. DurationSec is optional — pass 0 (or omit) to
; let the tooltip stay visible until TooltipHide() is called explicitly.
TooltipShow(Text, ColorHex := "", DurationSec := 0) {
    global _TooltipText, _TooltipTimer
    BgHex := _TooltipNormaliseHex(ColorHex)
    FgHex := _TooltipPickForeground(BgHex)

    _TooltipEnsureGui(BgHex, FgHex)
    _TooltipText.Value := Text

    ; Resize the tooltip to fit the new content. Setting Width auto-recomputes
    ; the height because the Text control auto-wraps.
    _TooltipText.Move(, , , )

    Pos := _TooltipResolvePosition()
    _TooltipGui.Show(Format("x{1} y{2} NoActivate", Pos.X, Pos.Y))

    ; Reset the auto-hide timer on every refresh so a flurry of partial-prefix
    ; updates does not race with a stale timer firing mid-update.
    if _TooltipTimer {
        SetTimer(_TooltipTimer, 0)
    }
    if (DurationSec > 0) {
        _TooltipTimer := () => TooltipHide()
        SetTimer(_TooltipTimer, -Round(DurationSec * 1000))
    }
}

; Hide the tooltip immediately and cancel any pending auto-hide timer.
TooltipHide() {
    global _TooltipGui, _TooltipTimer
    if _TooltipTimer {
        SetTimer(_TooltipTimer, 0)
        _TooltipTimer := 0
    }
    if _TooltipGui {
        try _TooltipGui.Hide()
    }
}


; ============================================================
; ============================================================
; ======= 2/ Internal helpers ===============================
; ============================================================
; ============================================================

; Lazily create (or recreate, when the background colour changed) the shared
; Gui v2. Re-creation is needed because AHK v2 only honours BackColor at
; construction time; mutating it on a live Gui has no effect.
_TooltipEnsureGui(BgHex, FgHex) {
    global _TooltipGui, _TooltipText
    global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE
    global _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y

    if _TooltipGui {
        ; Refresh background only when it changes — otherwise we're done.
        if (_TooltipGui.BackColor == BgHex) {
            return
        }
        try _TooltipGui.Destroy()
        _TooltipGui := 0
        _TooltipText := 0
    }

    G := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x20 +LastFound")
    G.BackColor := BgHex
    G.MarginX := _TOOLTIP_PADDING_X
    G.MarginY := _TOOLTIP_PADDING_Y
    G.SetFont("c" . FgHex . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
    Ctrl := G.Add("Text", "BackgroundTrans", "")
    _TooltipGui := G
    _TooltipText := Ctrl
}

; Strip leading "#", upper-case, fall back to default when empty / malformed.
_TooltipNormaliseHex(ColorHex) {
    global _TOOLTIP_DEFAULT_BG_HEX
    H := Trim(ColorHex)
    if (SubStr(H, 1, 1) == "#") {
        H := SubStr(H, 2)
    }
    if !RegExMatch(H, "^[0-9A-Fa-f]{6}$") {
        return _TOOLTIP_DEFAULT_BG_HEX
    }
    return StrUpper(H)
}

; Pick a readable foreground color (white / black) given a background hex
; using a perceptual-luminance threshold — same heuristic Hammerspoon uses
; via NSColor's whitestComponent comparison. The boundary 0.55 yields good
; contrast on the saturated mid-tones we use for group colours (red/green/
; blue/orange) without flipping on edge cases.
_TooltipPickForeground(BgHex) {
    R := Integer("0x" . SubStr(BgHex, 1, 2))
    G := Integer("0x" . SubStr(BgHex, 3, 2))
    B := Integer("0x" . SubStr(BgHex, 5, 2))
    ; Rec.601 luminance, scaled to [0,1].
    L := (0.299 * R + 0.587 * G + 0.114 * B) / 255
    return (L > 0.55) ? "000000" : "FFFFFF"
}

; Resolve the screen position where the tooltip should appear, mirroring the
; Hammerspoon ``ui/tooltip/renderer.lua:resolve_anchor`` cascade:
;
;   1. Native caret via ``CaretGetPos`` — works for most native Win32 controls.
;   2. UIA focused element bounding rectangle — the right answer for Electron,
;      Chromium, UWP and other apps that do not expose a usable caret to
;      ``CaretGetPos``. A small rectangle (height < MAX_CARET_HEIGHT) is
;      treated as a caret anchor; a larger one as an "input box" anchor.
;   3. Active window frame — bottom-centre of the foreground window, used
;      when even UIA cannot identify a focused element.
;   4. Mouse cursor — last-resort fallback.
;
; All positioning maths happen in screen coordinates because the Gui is
; ``+AlwaysOnTop`` and uses absolute Show("xY yZ").
_TooltipResolvePosition() {
    global _TOOLTIP_OFFSET_BELOW, _TOOLTIP_OFFSET_RIGHT
    global _TOOLTIP_MAX_CARET_HEIGHT_PX, _TOOLTIP_WINDOW_BOTTOM_INSET_PX

    ; ----- 1. Native caret -----------------------------------------------
    Cx := 0, Cy := 0
    GotCaret := false
    try GotCaret := CaretGetPos(&Cx, &Cy)
    if (GotCaret and (Cx != 0 or Cy != 0)) {
        return { X: Cx + _TOOLTIP_OFFSET_RIGHT, Y: Cy + _TOOLTIP_OFFSET_BELOW }
    }

    ; ----- 2. UIA focused element bounding rectangle ---------------------
    try {
        if IsSet(UIA) {
            Elem := UIA.GetFocusedElement()
            if Elem {
                Rect := Elem.BoundingRectangle
                ; UIA returns a {l, t, r, b} struct; treat any zero-area or
                ; obviously off-screen rect as unusable.
                W := Rect.r - Rect.l
                H := Rect.b - Rect.t
                if (W > 0 and H > 0) {
                    if (H < _TOOLTIP_MAX_CARET_HEIGHT_PX) {
                        ; Caret-like: anchor under the rect's lower-left.
                        return { X: Rect.l + _TOOLTIP_OFFSET_RIGHT,
                                 Y: Rect.b + _TOOLTIP_OFFSET_BELOW }
                    } else {
                        ; Input-box-like: anchor under the bottom centre.
                        return { X: Rect.l + W // 2,
                                 Y: Rect.b + _TOOLTIP_OFFSET_BELOW }
                    }
                }
            }
        }
    }

    ; ----- 3. Active window frame ----------------------------------------
    try {
        Wx := 0, Wy := 0, Ww := 0, Wh := 0
        WinGetPos(&Wx, &Wy, &Ww, &Wh, "A")
        if (Ww > 0 and Wh > 0) {
            return { X: Wx + Ww // 2,
                     Y: Wy + Wh - _TOOLTIP_WINDOW_BOTTOM_INSET_PX }
        }
    }

    ; ----- 4. Mouse cursor -----------------------------------------------
    Mx := 0, My := 0
    try MouseGetPos(&Mx, &My)
    return { X: Mx, Y: My + _TOOLTIP_OFFSET_BELOW }
}
