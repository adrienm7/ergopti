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

; Primary Gui reference (first row). _TooltipRowGuis holds all rows.
global _TooltipGui     := 0
global _TooltipRowGuis := []
global _TooltipTimer   := 0

; Style constants.
global _TOOLTIP_FONT_NAME        := "Segoe UI"
global _TOOLTIP_FONT_SIZE        := 11
global _TOOLTIP_FONT_SIZE_LABEL  := 9     ; smaller dim font for the trigger label
global _TOOLTIP_PADDING_X        := 14
global _TOOLTIP_PADDING_Y        := 8
global _TOOLTIP_LABEL_GAP        := 10    ; gap between output text and badge left edge

; Badge (★ / ⏎) visual pill: fixed-width box so every row is identical
; regardless of which symbol it shows.  The symbol is rendered in the row's
; accent colour on a neutral dark background so it pops on any tint.
global _TOOLTIP_BADGE_W          := 24    ; total badge width (px) — fixed across all rows
global _TOOLTIP_BADGE_BG_HEX     := "2D2D2D"   ; neutral dark grey badge background

; Maximum width of the output text column. Outputs wider than this are
; capped so the badge is always visible regardless of text length.
global _TOOLTIP_MAX_TEXT_W       := 320
global _TOOLTIP_OFFSET_BELOW     := 18   ; pixels below the anchor (caret / box)
global _TOOLTIP_OFFSET_RIGHT     := 4    ; small horizontal nudge for caret anchor
global _TOOLTIP_DEFAULT_BG_HEX   := "1A1A1A"
global _TOOLTIP_BORDER_COLOR_HEX := "FFFFFF"   ; white border
global _TOOLTIP_BORDER_ALPHA     := 0.18        ; subtle transparency
; 1 px logical border drawn via a separate always-on-top Gui layered on top.
global _TOOLTIP_BORDER_THICKNESS := 1
; Pixel radius for the rounded corners. Capped at runtime to half of the
; smallest gui dimension so a small tooltip (e.g. just "c'") does not have
; its content clipped by overlapping corner arcs.
global _TOOLTIP_CORNER_RADIUS    := 8

; Border overlay Gui — single frameless window covering the entire stack.
global _TooltipBorderGui := 0

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

; Safety deadline applied whenever the caller passes DurationSec = 0
; (i.e. "stay until TooltipHide()"). Guards against ghost tooltips that
; linger when the normal hide path (buffer reset, expansion fire, etc.)
; is skipped due to an unhandled exception or a missed timer callback.
global _TOOLTIP_SAFETY_SEC := 10.0

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

; Show or update the tooltip with one or more stacked items.
;
; Items may be:
;   - A plain string  → single item with default color, no auto-hide.
;   - A single object { Text, ColorHex?, DurationSec? }.
;   - An Array of such objects → stacked rows; widths are equalised to the
;     widest row; corners are rounded only at the very top and very bottom
;     (flat borders between adjacent rows).
;
; The shortest DurationSec across all items drives the auto-hide timer
; (0 / omitted means "stay until TooltipHide()").
TooltipShow(Items, DurationSec := 0) {
    global _TooltipTimer

    ; Normalise to an Array of { Text, ColorHex } objects.
    if !IsObject(Items) {
        Items := [{ Text: Items, ColorHex: "", DurationSec: DurationSec }]
    } else if !Items.HasMethod("Push") {
        Items := [Items]
    }

    ; Cancel any pending auto-hide timer BEFORE rebuilding the Gui.
    if _TooltipTimer {
        SetTimer(_TooltipTimer, 0)
        _TooltipTimer := 0
    }

    _TooltipBuildGui(Items)

    Pos := _TooltipResolvePosition()
    CurY := Pos.Y
    TotalH := 0
    StackW := 0
    for Idx, Row in _TooltipRowGuis {
        Row.Gui.Show(Format("w{1} h{2} x{3} y{4} NoActivate",
            Row.W, Row.H, Pos.X, CurY))
        CurY += Row.H
        TotalH += Row.H
        StackW := Row.W
    }
    _TooltipApplyStackedCorners()
    _TooltipShowBorder(Pos.X, Pos.Y, StackW, TotalH)

    ; Use the shortest non-zero DurationSec across all items.
    EffectiveDur := DurationSec
    for _, Item in Items {
        D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
        if (D > 0 and (EffectiveDur == 0 or D < EffectiveDur))
            EffectiveDur := D
    }
    global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC, _TOOLTIP_SAFETY_SEC
    if (EffectiveDur > 0) {
        Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
            EffectiveDur - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
        _TooltipTimer := () => TooltipHide()
        SetTimer(_TooltipTimer, -Round(Effective * 1000))
    } else {
        ; No caller-specified duration — arm a safety deadline so the tooltip
        ; cannot become a ghost if the normal hide path (expansion fire or
        ; buffer reset) is missed.
        _TooltipTimer := () => TooltipHide()
        SetTimer(_TooltipTimer, -Round(_TOOLTIP_SAFETY_SEC * 1000))
    }
}

; Hide all tooltip rows and the border overlay immediately.
; Destroys the row Guis (not just hides) so stale window handles cannot
; resurface as ghosts if a new TooltipShow fires before the old timer fires.
TooltipHide() {
    global _TooltipGui, _TooltipRowGuis, _TooltipBorderGui, _TooltipTimer
    if _TooltipTimer {
        SetTimer(_TooltipTimer, 0)
        _TooltipTimer := 0
    }
    for _, Row in _TooltipRowGuis {
        try Row.Gui.Destroy()
    }
    _TooltipGui     := 0
    _TooltipRowGuis := []
    if _TooltipBorderGui {
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }
}


; ============================================================
; ============================================================
; ======= 2/ Internal helpers ===============================
; ============================================================
; ============================================================

; Build one Gui per row (one row = one item), store them in _TooltipRowGuis.
; All rows are positioned at the same X; Y increments by each row's height.
; Widths are equalised to the widest row so the stack looks uniform.
; The first row's Gui is the "primary" stored in _TooltipGui (used by
; TooltipHide and position queries); all rows are shown/hidden together.
_TooltipBuildGui(Items) {
    global _TooltipGui, _TooltipRowGuis
    global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_SIZE_LABEL
    global _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y, _TOOLTIP_LABEL_GAP
    global _TOOLTIP_BADGE_W, _TOOLTIP_BADGE_BG_HEX, _TOOLTIP_MAX_TEXT_W

    OldGuis := _TooltipGui ? _TooltipRowGuis : []

    ; Determine whether any row has a trigger label — if none do, skip the
    ; badge column entirely so plain tooltips stay compact.
    HasAnyLabel := false
    for _, Item in Items {
        if (Item.HasOwnProp("TriggerLabel") and Item.TriggerLabel != "") {
            HasAnyLabel := true
            break
        }
    }

    ; Measure all rows to find the widest output text.
    Sizes := []
    MaxW := 0
    for _, Item in Items {
        S := _TooltipMeasureText(Item.Text)
        Sizes.Push(S)
        if (S.W + 4 > MaxW)
            MaxW := S.W + 4
    }
    ; Safety margin for GDI under-counts, then hard cap so the badge column
    ; is always visible regardless of output text length.
    MaxW := Min(MaxW + 8, _TOOLTIP_MAX_TEXT_W)

    ; Total width: left padding + output text + gap + badge + right padding.
    ; Right padding (_TOOLTIP_PADDING_X) is added after the badge so the pill
    ; is never clipped by the window edge.
    BadgeColW := HasAnyLabel ? (_TOOLTIP_LABEL_GAP + _TOOLTIP_BADGE_W + _TOOLTIP_PADDING_X) : 0
    TotalW := _TOOLTIP_PADDING_X + MaxW + BadgeColW + _TOOLTIP_PADDING_X

    NewGuis := []
    for Idx, Item in Items {
        ColorHex := Item.HasOwnProp("ColorHex") ? Item.ColorHex : ""
        BgHex := _TooltipMixTintHex(ColorHex)
        S := Sizes[Idx]
        RowH := S.H + _TOOLTIP_PADDING_Y * 2

        G := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x20 +LastFound")
        G.BackColor := BgHex
        G.MarginX := 0
        G.MarginY := 0
        G.SetFont("cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)

        ; Output text — left-aligned with left padding.
        ; 0x1000 = SS_ENDELLIPSIS: truncates with … when text exceeds MaxW.
        TextOpts := Format("BackgroundTrans 0xC 0x1000 x{1} y{2} w{3} h{4}",
            _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y, MaxW, S.H)
        G.Add("Text", TextOpts, Item.Text)

        ; Badge pill — fixed-width neutral box with the symbol in accent colour.
        ; Two overlapping controls: an opaque background rect, then a
        ; BackgroundTrans text control sized to the measured glyph height and
        ; vertically centred inside the badge — this is the only reliable way
        ; to get vertical centering since AHK Text always renders top-aligned.
        HasLabel := Item.HasOwnProp("TriggerLabel") and Item.TriggerLabel != ""
        if HasLabel {
            BadgeX := _TOOLTIP_PADDING_X + MaxW + _TOOLTIP_LABEL_GAP

            ; Measure the actual glyph height at the badge font size.
            GlyphH := _TooltipMeasureTextSize(Item.TriggerLabel, _TOOLTIP_FONT_SIZE_LABEL).H

            ; Badge background: full row height minus symmetric 2 px inset.
            BgY := _TOOLTIP_PADDING_Y - 2
            BgH := S.H + 4

            ; Text rect: glyph-height, centred inside the badge background.
            TextY := BgY + (BgH - GlyphH) // 2

            AccentColor := (ColorHex != "") ? Trim(ColorHex, "#") : "FFFFFF"

            ; 1) Opaque background rectangle (no text).
            G.SetFont("s1", _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("Background{1} x{2} y{3} w{4} h{5}",
                _TOOLTIP_BADGE_BG_HEX, BadgeX, BgY, _TOOLTIP_BADGE_W, BgH), "")

            ; 2) Transparent text control centred over the background.
            G.SetFont("c" . AccentColor . " s" . _TOOLTIP_FONT_SIZE_LABEL, _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("BackgroundTrans 0xC x{1} y{2} w{3} h{4} Center",
                BadgeX, TextY, _TOOLTIP_BADGE_W, GlyphH), Item.TriggerLabel)

            G.SetFont("cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
        }

        NewGuis.Push({ Gui: G, H: RowH, W: TotalW })
    }

    _TooltipGui     := NewGuis[1].Gui
    _TooltipRowGuis := NewGuis

    ; Destroy old Guis after building new ones so any in-flight Hide() calls
    ; still target a valid handle rather than 0.
    for _, OldG in OldGuis {
        try OldG.Gui.Destroy()
    }
}

; Measure ``Text`` at a given font size. Delegates to _TooltipMeasureTextSize.
_TooltipMeasureText(Text) {
    global _TOOLTIP_FONT_SIZE
    return _TooltipMeasureTextSize(Text, _TOOLTIP_FONT_SIZE)
}

; Measure ``Text`` width and height in pixels using a transient GDI font
; at the specified FontSize. Returns { W, H } with sensible fallbacks.
_TooltipMeasureTextSize(Text, FontSize) {
    global _TOOLTIP_FONT_NAME

    Fallback := { W: Max(80, StrLen(Text) * Round(FontSize * 0.75)),
                  H: FontSize + 8 }

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
    HeightPx := -Round(FontSize * DPI / 72)

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

; Apply rounded corners to the tooltip stack:
;   - First row : rounded top-left + top-right, square bottom corners.
;   - Middle rows: all square corners.
;   - Last row  : square top corners, rounded bottom-left + bottom-right.
;   - Single row: fully rounded (all four corners).
;
; Technique: CreateRoundRectRgn produces a rect with all four corners rounded.
; To keep only the desired pair, we CombineRgn-intersect it with a plain
; rectangular region that covers the half we want to keep square.
_TooltipApplyStackedCorners() {
    global _TooltipRowGuis, _TOOLTIP_CORNER_RADIUS
    Count := _TooltipRowGuis.Length
    if (Count == 0) {
        return
    }
    for Idx, Row in _TooltipRowGuis {
        G := Row.Gui
        W := Row.W
        H := Row.H
        if (W <= 0 or H <= 0) {
            continue
        }
        Radius := _TOOLTIP_CORNER_RADIUS
        if (Radius * 2 > W)
            Radius := W // 2
        if (Radius * 2 > H)
            Radius := H // 2
        Diam := Radius * 2

        IsFirst := (Idx == 1)
        IsLast  := (Idx == Count)

        if (Count == 1) {
            ; Single row — fully rounded.
            Rgn := DllCall("Gdi32\CreateRoundRectRgn",
                "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
                "Int", Diam, "Int", Diam, "Ptr")
        } else if IsFirst {
            ; Rounded top, square bottom: intersect round-rect with a rect
            ; that covers the bottom half so the rounded bottom is cropped.
            Rgn := _TooltipMakeTopRoundedRgn(W, H, Diam)
        } else if IsLast {
            ; Square top, rounded bottom.
            Rgn := _TooltipMakeBottomRoundedRgn(W, H, Diam)
        } else {
            ; Middle row — plain rectangle.
            Rgn := DllCall("Gdi32\CreateRectRgn",
                "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1, "Ptr")
        }
        if Rgn {
            DllCall("User32\SetWindowRgn", "Ptr", G.Hwnd, "Ptr", Rgn, "Int", 1)
        }
    }
}

; Rounded top corners only: intersect a full round-rect with a rectangle
; that covers only the top half + Radius pixels so the bottom stays square.
_TooltipMakeTopRoundedRgn(W, H, Diam) {
    ; Full round-rect (all four corners rounded).
    RoundRgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    ; Rectangle covering top half + enough to keep rounded top visible.
    ; Bottom edge at H (full height) but top portion is the interesting bit —
    ; we intersect with a rect from y=0 to y=(H - Radius) as a square cap,
    ; then union with a plain rect for y=(H - Radius) to y=H.
    ; Simpler: combine round-rect (all 4 rounded) ∩ rect(0,0,W,H-Radius)
    ;          then union rect(0, H-Radius, W, H).
    CapRgn := DllCall("Gdi32\CreateRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H - Diam // 2 + 1, "Ptr")
    SquareBottomRgn := DllCall("Gdi32\CreateRectRgn",
        "Int", 0, "Int", H - Diam // 2, "Int", W + 1, "Int", H + 1, "Ptr")
    ; Intersect round-rect with cap → keeps rounded top, clips bottom arc.
    CombinedRgn := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", 1, "Int", 1, "Ptr")
    DllCall("Gdi32\CombineRgn", "Ptr", CombinedRgn, "Ptr", RoundRgn, "Ptr", CapRgn, "Int", 1)   ; RGN_AND=1
    ; Union with square-bottom rect.
    DllCall("Gdi32\CombineRgn", "Ptr", CombinedRgn, "Ptr", CombinedRgn, "Ptr", SquareBottomRgn, "Int", 2)  ; RGN_OR=2
    DllCall("Gdi32\DeleteObject", "Ptr", RoundRgn)
    DllCall("Gdi32\DeleteObject", "Ptr", CapRgn)
    DllCall("Gdi32\DeleteObject", "Ptr", SquareBottomRgn)
    return CombinedRgn
}

; Rounded bottom corners only: symmetric to _TooltipMakeTopRoundedRgn.
_TooltipMakeBottomRoundedRgn(W, H, Diam) {
    RoundRgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    CapRgn := DllCall("Gdi32\CreateRectRgn",
        "Int", 0, "Int", Diam // 2, "Int", W + 1, "Int", H + 1, "Ptr")
    SquareTopRgn := DllCall("Gdi32\CreateRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", Diam // 2 + 1, "Ptr")
    CombinedRgn := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", 1, "Int", 1, "Ptr")
    DllCall("Gdi32\CombineRgn", "Ptr", CombinedRgn, "Ptr", RoundRgn, "Ptr", CapRgn, "Int", 1)
    DllCall("Gdi32\CombineRgn", "Ptr", CombinedRgn, "Ptr", CombinedRgn, "Ptr", SquareTopRgn, "Int", 2)
    DllCall("Gdi32\DeleteObject", "Ptr", RoundRgn)
    DllCall("Gdi32\DeleteObject", "Ptr", CapRgn)
    DllCall("Gdi32\DeleteObject", "Ptr", SquareTopRgn)
    return CombinedRgn
}

; Show a fresh border Gui that overlays the entire stack with a 1 px white
; rounded-rectangle outline. A new Gui is created on every call (and the
; previous one destroyed) so stale geometry never leaks between tooltip
; updates — reusing a layered window and re-calling SetWindowRgn is fragile
; because the region is applied before the window compositor has processed
; the new Show() geometry.
_TooltipShowBorder(X, Y, W, H) {
    global _TooltipBorderGui, _TOOLTIP_CORNER_RADIUS, _TOOLTIP_BORDER_THICKNESS

    ; Destroy any previous border so stale region / size never bleeds through.
    if _TooltipBorderGui {
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }

    ; +E0x80000 = WS_EX_LAYERED  +E0x20 = WS_EX_TRANSPARENT (click-through).
    _TooltipBorderGui := Gui("+AlwaysOnTop +ToolWindow -Caption +E0x80000 +E0x20 +LastFound")
    _TooltipBorderGui.BackColor := "FFFFFF"   ; ring color; interior punched by region
    Hwnd := _TooltipBorderGui.Hwnd

    ; Build a "hollow" region: outer round-rect minus the inset round-rect.
    Radius := _TOOLTIP_CORNER_RADIUS
    if (Radius * 2 > W) Radius := W // 2
    if (Radius * 2 > H) Radius := H // 2
    T := _TOOLTIP_BORDER_THICKNESS
    Diam := Radius * 2
    OuterRgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    InnerRgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", T, "Int", T, "Int", W - T + 1, "Int", H - T + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    BorderRgn := DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", 1, "Int", 1, "Ptr")
    DllCall("Gdi32\CombineRgn", "Ptr", BorderRgn, "Ptr", OuterRgn, "Ptr", InnerRgn, "Int", 4)  ; RGN_DIFF=4
    DllCall("Gdi32\DeleteObject", "Ptr", OuterRgn)
    DllCall("Gdi32\DeleteObject", "Ptr", InnerRgn)

    ; Apply region before Show so the compositor never paints the full rect.
    if BorderRgn {
        DllCall("User32\SetWindowRgn", "Ptr", Hwnd, "Ptr", BorderRgn, "Int", 0)
    }

    _TooltipBorderGui.Show(Format("w{1} h{2} x{3} y{4} NoActivate", W, H, X, Y))
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
