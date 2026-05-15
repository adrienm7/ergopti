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
;    Rounded-corner DllCalls fire on every Gui rebuild (required since the
;    window handle changes each time the Gui is destroyed and recreated).
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
global _TOOLTIP_PADDING_X      := 14
global _TOOLTIP_PADDING_Y      := 8
global _TOOLTIP_OFFSET_BELOW   := 18   ; pixels below the anchor (caret / box)
global _TOOLTIP_OFFSET_RIGHT   := 4    ; small horizontal nudge for caret anchor
global _TOOLTIP_DEFAULT_BG_HEX := "1A1A1A"
; Pixel radius for the rounded corners. Capped at runtime to half of the
; smallest gui dimension so a small tooltip (e.g. just "c'") does not have
; its content clipped by overlapping corner arcs.
global _TOOLTIP_CORNER_RADIUS  := 8

; Tint mixing — mirrors Hammerspoon's renderer.lua (lightness 0.10, saturation
; 0.40). The accent colour only contributes its hue; the background stays a
; near-black with a subtle wash so the text remains readable on every group.
global _TOOLTIP_LIGHTNESS  := 0.10
global _TOOLTIP_SATURATION := 0.40

; Auto-hide is shortened by this many seconds (with a hard floor) so the
; tooltip vanishes a beat before the actual expansion window closes —
; otherwise the user can still see the preview and press the magic key
; just past the deadline, where the expansion silently does not fire.
; Mirrors Hammerspoon's TIMEOUT_DECREMENT_SEC / TIMEOUT_FLOOR_SEC.
global _TOOLTIP_TIMEOUT_DECREMENT_SEC := 0.15
global _TOOLTIP_TIMEOUT_FLOOR_SEC     := 0.05

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
    global _TooltipTimer
    ; The accent only contributes its hue — the actual background is a near-
    ; black tinted with that hue (mirrors Hammerspoon's renderer behaviour).
    BgHex := _TooltipMixTintHex(ColorHex)
    FgHex := "FFFFFF"   ; always white on the dark mixed background

    ; Cancel any pending auto-hide timer BEFORE rebuilding the Gui. If the
    ; timer fires between Destroy() and the new Gui being shown, _TooltipGui
    ; is 0 and the hide is silently skipped — leaving the new window orphaned
    ; with no timer to ever dismiss it (ghost tooltip).
    if _TooltipTimer {
        SetTimer(_TooltipTimer, 0)
        _TooltipTimer := 0
    }

    ; Recreate the Gui (and its Text control) on every show so the control
    ; auto-sizes to the new content. AHK v2 does not resize a Text control
    ; when its `.Value` changes, so reusing the previous Gui produced a
    ; truncated tooltip ("c'" instead of "c'était").
    _TooltipBuildGui(BgHex, FgHex, Text)

    Pos := _TooltipResolvePosition()
    _TooltipGui.Show(Format("AutoSize x{1} y{2} NoActivate", Pos.X, Pos.Y))
    _TooltipApplyRoundedCorners()

    if (DurationSec > 0) {
        global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC
        Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
            DurationSec - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
        _TooltipTimer := () => TooltipHide()
        SetTimer(_TooltipTimer, -Round(Effective * 1000))
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

; Build a fresh Gui + Text control sized for the given content. We rebuild
; on every show because AHK v2 does not resize a Text control after its
; `.Value` is set; reusing the previous Gui truncated the visible string.
;
; The Static (Text) control's auto-sizing in AHK v2 does not always pick up
; the gui's SetFont when measuring the natural width — short strings can
; end up clipped because the measurement is done with a smaller fallback
; font. We therefore measure the text ourselves with GetTextExtentPoint32W
; against a font handle matching what the control will actually render with,
; then pass explicit `w` / `h` options so the control is the right size.
_TooltipBuildGui(BgHex, FgHex, Text) {
    global _TooltipGui, _TooltipText
    global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE
    global _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y

    ; Destroy the old window only after the new one is fully built, so that
    ; any TooltipHide() call arriving during construction still targets a valid
    ; handle (the old one) rather than 0, which would let the old window leak.
    OldGui := _TooltipGui

    G := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x20 +LastFound")
    G.BackColor := BgHex
    G.MarginX := _TOOLTIP_PADDING_X
    G.MarginY := _TOOLTIP_PADDING_Y
    G.SetFont("c" . FgHex . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)

    Size := _TooltipMeasureText(Text)
    ; +4 px horizontal slack — Windows kerning / italic overhang sometimes
    ; needs a hair more pixels than GetTextExtentPoint32W reports.
    Opts := "BackgroundTrans 0xC w" . (Size.W + 4) . " h" . Size.H
    _TooltipText := G.Add("Text", Opts, Text)
    _TooltipGui := G

    if OldGui {
        try OldGui.Destroy()
    }
}

; Measure ``Text`` width and height in pixels using a transient GDI font
; that mirrors the one ``Gui.SetFont`` will apply to the control. Returns
; { W, H } with sensible fallbacks if any DllCall fails (the tooltip
; should never crash the script over a measurement glitch).
_TooltipMeasureText(Text) {
    global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE

    Fallback := { W: Max(80, StrLen(Text) * Round(_TOOLTIP_FONT_SIZE * 0.75)),
                  H: _TOOLTIP_FONT_SIZE + 8 }

    HDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
    if !HDC {
        return Fallback
    }

    ; Convert point size to device units. CreateFont expects a negative
    ; lfHeight in pixels for character-cell height matching SetFont points.
    DPI := DllCall("Gdi32\GetDeviceCaps", "Ptr", HDC, "Int", 90, "Int")  ; LOGPIXELSY
    if (DPI <= 0) {
        DPI := 96
    }
    HeightPx := -Round(_TOOLTIP_FONT_SIZE * DPI / 72)

    HFont := DllCall("Gdi32\CreateFontW",
        "Int", HeightPx, "Int", 0, "Int", 0, "Int", 0,
        "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
        "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
        "WStr", _TOOLTIP_FONT_NAME,
        "Ptr")
    if !HFont {
        DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", HDC)
        return Fallback
    }

    OldFont := DllCall("Gdi32\SelectObject", "Ptr", HDC, "Ptr", HFont, "Ptr")
    Size := Buffer(8, 0)
    Ok := DllCall("Gdi32\GetTextExtentPoint32W",
        "Ptr", HDC, "WStr", Text, "Int", StrLen(Text), "Ptr", Size)

    Width := Ok ? NumGet(Size, 0, "Int") : Fallback.W
    Height := Ok ? NumGet(Size, 4, "Int") : Fallback.H

    DllCall("Gdi32\SelectObject", "Ptr", HDC, "Ptr", OldFont)
    DllCall("Gdi32\DeleteObject", "Ptr", HFont)
    DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", HDC)

    if (Width <= 0 or Height <= 0) {
        return Fallback
    }
    return { W: Width, H: Height }
}

; Apply a rounded-rectangle clipping region to the tooltip window so the
; final shape matches the Hammerspoon look (12 px radius). Done after
; Show() because the window must already exist for SetWindowRgn to apply.
; CreateRoundRectRgn is owned by the system once we hand it to SetWindowRgn
; (last argument bDelete = 1), so we never call DeleteObject ourselves.
_TooltipApplyRoundedCorners() {
    global _TooltipGui, _TOOLTIP_CORNER_RADIUS
    if !_TooltipGui {
        return
    }
    W := 0
    H := 0
    try _TooltipGui.GetClientPos(, , &W, &H)
    if (W <= 0 or H <= 0) {
        return
    }
    ; Cap the radius so the corner arcs never overlap and clip the content.
    ; Without this guard, a small tooltip (W or H < 2 * radius) ends up with
    ; opposing corners eating into the same pixels and the text is cut.
    Radius := _TOOLTIP_CORNER_RADIUS
    if (Radius * 2 > W) {
        Radius := W // 2
    }
    if (Radius * 2 > H) {
        Radius := H // 2
    }
    Rgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0,
        "Int", W + 1, "Int", H + 1,
        "Int", Radius * 2,
        "Int", Radius * 2,
        "Ptr")
    if Rgn {
        DllCall("User32\SetWindowRgn", "Ptr", _TooltipGui.Hwnd, "Ptr", Rgn, "Int", 1)
    }
}

; Mix an accent colour with a near-black background, mirroring Hammerspoon's
; renderer.lua: only the hue of the accent contributes — lightness is fixed
; at _TOOLTIP_LIGHTNESS and saturation at _TOOLTIP_SATURATION, producing the
; characteristic "dark grey with a coloured wash" look. An empty / invalid
; hex falls back to the neutral default background. Returns a hex string
; without the leading '#', upper-case (the form Gui.BackColor expects).
_TooltipMixTintHex(AccentHex) {
    global _TOOLTIP_DEFAULT_BG_HEX, _TOOLTIP_LIGHTNESS, _TOOLTIP_SATURATION

    H := Trim(AccentHex)
    if (SubStr(H, 1, 1) == "#") {
        H := SubStr(H, 2)
    }
    if !RegExMatch(H, "^[0-9A-Fa-f]{6}$") {
        return _TOOLTIP_DEFAULT_BG_HEX
    }

    R := Integer("0x" . SubStr(H, 1, 2)) / 255.0
    G := Integer("0x" . SubStr(H, 3, 2)) / 255.0
    B := Integer("0x" . SubStr(H, 5, 2)) / 255.0

    MaxC := Max(R, G, B)
    MinC := Min(R, G, B)
    Delta := MaxC - MinC
    Hue := 0.0
    if (Delta > 0.0001) {
        if (MaxC == R) {
            Hue := Mod((G - B) / Delta + 6, 6)
        } else if (MaxC == G) {
            Hue := (B - R) / Delta + 2
        } else {
            Hue := (R - G) / Delta + 4
        }
        Hue := Hue / 6
    }

    L := _TOOLTIP_LIGHTNESS
    S := _TOOLTIP_SATURATION
    C := (1 - Abs(2 * L - 1)) * S
    H6 := Hue * 6
    X := C * (1 - Abs(Mod(H6, 2) - 1))
    M := L - C / 2

    Nr := 0.0
    Ng := 0.0
    Nb := 0.0
    if (H6 < 1) {
        Nr := C
        Ng := X
        Nb := 0
    } else if (H6 < 2) {
        Nr := X
        Ng := C
        Nb := 0
    } else if (H6 < 3) {
        Nr := 0
        Ng := C
        Nb := X
    } else if (H6 < 4) {
        Nr := 0
        Ng := X
        Nb := C
    } else if (H6 < 5) {
        Nr := X
        Ng := 0
        Nb := C
    } else {
        Nr := C
        Ng := 0
        Nb := X
    }

    R8 := Round((Nr + M) * 255)
    G8 := Round((Ng + M) * 255)
    B8 := Round((Nb + M) * 255)
    R8 := Max(0, Min(255, R8))
    G8 := Max(0, Min(255, G8))
    B8 := Max(0, Min(255, B8))
    return Format("{1:02X}{2:02X}{3:02X}", R8, G8, B8)
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
    Cx := 0
    Cy := 0
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
        Wx := 0
        Wy := 0
        Ww := 0
        Wh := 0
        WinGetPos(&Wx, &Wy, &Ww, &Wh, "A")
        if (Ww > 0 and Wh > 0) {
            return { X: Wx + Ww // 2,
                     Y: Wy + Wh - _TOOLTIP_WINDOW_BOTTOM_INSET_PX }
        }
    }

    ; ----- 4. Mouse cursor -----------------------------------------------
    Mx := 0
    My := 0
    try MouseGetPos(&Mx, &My)
    return { X: Mx, Y: My + _TOOLTIP_OFFSET_BELOW }
}
