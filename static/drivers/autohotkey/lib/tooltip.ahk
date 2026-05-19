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

; Single Gui that holds the entire tooltip stack.
global _TooltipGui     := 0
; Metadata per row (H, W, IsSep) kept for corner/border calculations.
global _TooltipRowGuis := []

; Generation counter incremented on every TooltipShow. The timer callback
; compares its captured generation against this value and aborts if they
; differ — prevents a stale timer from hiding a tooltip that was rebuilt
; after the timer was armed but before it fired.
global _TooltipGeneration         := 0
global _TooltipTimerGeneration    := 0

; Stable function reference used as the auto-hide timer. A single named
; function (not a fresh closure per call) is mandatory so SetTimer can
; cancel it by identity — each closure literal produces a distinct object
; that SetTimer treats as a different timer, making cancellation impossible.
_TooltipTimerFn() {
    global _TooltipGeneration, _TooltipTimerGeneration
    if (_TooltipTimerGeneration != _TooltipGeneration)
        return
    TooltipHide()
}

; Style constants — sourced from lib/ui_style.ahk (included before this file
; in ErgoptiPlus.ahk). All visual values are defined there and mapped to
; module-local aliases below so the rest of this file reads naturally.
global _TOOLTIP_FONT_NAME        := UI_FONT_NAME
global _TOOLTIP_FONT_SIZE        := UI_FONT_SIZE_MAIN
global _TOOLTIP_PADDING_X        := UI_PAD_X
global _TOOLTIP_PADDING_Y        := UI_PAD_Y
global _TOOLTIP_OFFSET_BELOW     := UI_OFFSET_BELOW
global _TOOLTIP_OFFSET_RIGHT     := UI_OFFSET_RIGHT
global _TOOLTIP_DEFAULT_BG_HEX   := UI_BG_HEX
global _TOOLTIP_BORDER_COLOR_HEX := UI_BORDER_COLOR_HEX
global _TOOLTIP_BORDER_ALPHA     := UI_BORDER_ALPHA
global _TOOLTIP_BORDER_THICKNESS := UI_BORDER_THICKNESS
global _TOOLTIP_CORNER_RADIUS    := UI_CORNER_RADIUS
global _TOOLTIP_LABEL_FONT_SIZE  := UI_FONT_SIZE_HINT
global _TOOLTIP_LABEL_GAP        := UI_LABEL_GAP
global _TOOLTIP_LIGHTNESS        := UI_TINT_LIGHTNESS
global _TOOLTIP_SATURATION       := UI_TINT_SATURATION
global _TOOLTIP_MAX_CARET_HEIGHT_PX    := UI_MAX_CARET_HEIGHT_PX
global _TOOLTIP_WINDOW_BOTTOM_INSET_PX := UI_WINDOW_BOTTOM_INSET_PX

; Border overlay Gui — single frameless window covering the entire stack.
global _TooltipBorderGui := 0

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
global _TOOLTIP_SAFETY_SEC := 3.0


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
    ; Normalise to an Array of { Text, ColorHex } objects.
    if !IsObject(Items) {
        Items := [{ Text: Items, ColorHex: "", DurationSec: DurationSec }]
    } else if !Items.HasMethod("Push") {
        Items := [Items]
    }

    ; Bump the generation counter so any in-flight timer from the previous
    ; tooltip knows it is stale and must not call TooltipHide().
    global _TooltipGeneration, _TooltipTimerGeneration
    _TooltipGeneration += 1

    ; Cancel any pending auto-hide timer BEFORE rebuilding the Gui.
    ; _TooltipTimerFn is a stable named function — SetTimer identifies timers
    ; by function reference, so this reliably cancels the previously scheduled
    ; call regardless of how many TooltipShow calls were made before it fired.
    SetTimer(_TooltipTimerFn, 0)

    try {
        _TooltipBuildGui(Items)
    } catch {
        TooltipHide()
        return
    }

    if (_TooltipRowGuis.Length == 0) {
        TooltipHide()
        return
    }

    Pos  := _TooltipResolvePosition()
    ; _TooltipRowGuis[1] holds the single unified Gui metadata.
    Row  := _TooltipRowGuis[1]
    ; Snapshot generation before Show so any exception after Show still arms
    ; the timer correctly and the ghost cannot outlive the safety deadline.
    _TooltipTimerGeneration := _TooltipGeneration
    try {
        _TooltipDisableDwmRounding(Row.Gui.Hwnd)
        Row.Gui.Show(Format("w{1} h{2} x{3} y{4} NoActivate", Row.W, Row.H, Pos.X, Pos.Y))
        _TooltipApplyStackedCorners()
        _TooltipShowBorder(Pos.X, Pos.Y, Row.W, Row.H)
    } catch as e {
        TooltipHide()
        return
    }

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
        SetTimer(_TooltipTimerFn, -Round(Effective * 1000))
    } else {
        ; No caller-specified duration — arm a safety deadline so the tooltip
        ; cannot become a ghost if the normal hide path (expansion fire or
        ; buffer reset) is missed.
        SetTimer(_TooltipTimerFn, -Round(_TOOLTIP_SAFETY_SEC * 1000))
    }
}

; Hide all tooltip rows and the border overlay immediately.
; Destroys the row Guis (not just hides) so stale window handles cannot
; resurface as ghosts if a new TooltipShow fires before the old timer fires.
TooltipHide() {
    global _TooltipGui, _TooltipRowGuis, _TooltipBorderGui
    SetTimer(_TooltipTimerFn, 0)
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

; Build a single Gui that holds the entire tooltip stack.
; Each row is rendered as a full-width background Text control (tinted per group)
; with a smaller foreground Text control overlaid for the content and label.
; A 1 px separator line is drawn between rows using a narrow background band.
; Using one Gui eliminates all inter-window overlap — the only rendered surface
; is a single window with a single GDI region, exactly like the Hammerspoon canvas.
_TooltipBuildGui(Items) {
    global _TooltipGui, _TooltipRowGuis
    global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_LABEL_GAP
    global _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y

    if _TooltipGui {
        try _TooltipGui.Destroy()
    }
    _TooltipGui     := 0
    _TooltipRowGuis := []

    ; WinGetClientPos returns physical pixels — divide by DpiScale to get logical.
    DpiScale := A_ScreenDPI / 96

    ; ── Measure all text items ──────────────────────────────────────────────
    Sizes := []
    MaxW  := 0
    for _, Item in Items {
        ProbeGui := Gui("-Caption +LastFound")
        try {
            ProbeGui.MarginX := 0
            ProbeGui.MarginY := 0
            ProbeGui.SetFont("s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
            ProbeGui.Add("Text", "x0 y0", Item.Text)
            ProbeGui.Show("NoActivate")
            WinGetClientPos(, , &CW, &CH, ProbeGui.Hwnd)
            CW := Round(CW / DpiScale)
            CH := Round(CH / DpiScale)
            Sizes.Push({ W: CW, H: CH })
            if (CW > MaxW)
                MaxW := CW
        } finally {
            ProbeGui.Destroy()
        }
    }

    MaxLabelW := 0
    LabelSizes := []
    for _, Item in Items {
        Label := Item.HasOwnProp("TriggerLabel") ? Item.TriggerLabel : ""
        if (Label != "") {
            ProbeL := Gui("-Caption +LastFound")
            try {
                ProbeL.MarginX := 0
                ProbeL.MarginY := 0
                ProbeL.SetFont("s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
                ProbeL.Add("Text", "x0 y0", Label)
                ProbeL.Show("NoActivate")
                WinGetClientPos(, , &LW, &LH, ProbeL.Hwnd)
                LW := Round(LW / DpiScale)
                LH := Round(LH / DpiScale)
                LabelSizes.Push({ W: LW, H: LH })
                if (LW > MaxLabelW)
                    MaxLabelW := LW
            } finally {
                ProbeL.Destroy()
            }
        } else {
            LabelSizes.Push({ W: 0, H: 0 })
        }
    }

    LabelZone := MaxLabelW > 0 ? (_TOOLTIP_LABEL_GAP + MaxLabelW) : 0
    TotalW    := _TOOLTIP_PADDING_X + MaxW + LabelZone + _TOOLTIP_PADDING_X
    Count     := Items.Length
    SEP_H     := 1   ; 1 px separator between rows, in logical pixels

    ; ── Compute per-row heights and total canvas height ─────────────────────
    RowMeta := []
    TotalH  := 0
    for Idx, Item in Items {
        S    := Sizes[Idx]
        RowH := _TOOLTIP_PADDING_Y + S.H + _TOOLTIP_PADDING_Y
        RowMeta.Push({ H: RowH, Y: TotalH })
        TotalH += RowH
        if (Idx < Count)
            TotalH += SEP_H
    }

    ; ── Build the single unified Gui ────────────────────────────────────────
    ; Default background matches the first item's tint (the Gui BackColor covers
    ; any gap the compositor might paint before controls are drawn).
    FirstColorHex := Items[1].HasOwnProp("ColorHex") ? Items[1].ColorHex : ""
    G := Gui("+AlwaysOnTop -Caption +E0x20 +LastFound")
    G.BackColor := _TooltipMixTintHex(FirstColorHex)
    G.MarginX   := 0
    G.MarginY   := 0

    for Idx, Item in Items {
        ColorHex := Item.HasOwnProp("ColorHex") ? Item.ColorHex : ""
        BgHex    := _TooltipMixTintHex(ColorHex)
        S        := Sizes[Idx]
        Meta     := RowMeta[Idx]
        RowY     := Meta.Y
        RowH     := Meta.H

        ; Full-width background band for this row's tint color.
        G.SetFont("s1", _TOOLTIP_FONT_NAME)
        G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", BgHex, RowY, TotalW, RowH), "")

        ; Main text overlay.
        G.SetFont("cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
        G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
            _TOOLTIP_PADDING_X, RowY + _TOOLTIP_PADDING_Y, MaxW, S.H), Item.Text)

        ; Trigger label on the right.
        Label := Item.HasOwnProp("TriggerLabel") ? Item.TriggerLabel : ""
        if (Label != "" and LabelZone > 0) {
            LS     := LabelSizes[Idx]
            LabelX := TotalW - _TOOLTIP_PADDING_X - MaxLabelW
            LabelY := RowY + _TOOLTIP_PADDING_Y + Max(0, (S.H - LS.H) // 2)
            G.SetFont("c737373 s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
                LabelX, LabelY, MaxLabelW, LS.H), Label)
        }

        ; 1 px separator line between rows (white at low alpha, drawn as a
        ; background band — color approximates Hammerspoon's white 0.09 alpha
        ; over the dark bg: 0x1A * (1-0.09) + 0xFF * 0.09 ≈ 0x28).
        if (Idx < Count) {
            SepY := RowY + RowH
            G.SetFont("s1", _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("Background282828 x0 y{1} w{2} h{3}", SepY, TotalW, SEP_H), "")
        }
    }

    _TooltipGui     := G
    ; Store a single metadata record for the corner/border helper.
    _TooltipRowGuis := [{ Gui: G, H: TotalH, W: TotalW, IsSep: false }]
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

; Apply a fully-rounded region to the single unified tooltip Gui.
; Since the stack is now a single window, all four corners are always
; rounded — no top/middle/bottom split needed.
_TooltipApplyStackedCorners() {
    global _TooltipRowGuis, _TOOLTIP_CORNER_RADIUS
    if (_TooltipRowGuis.Length == 0)
        return

    Row := _TooltipRowGuis[1]
    G   := Row.Gui

    ; SetWindowRgn operates in physical pixels.
    DpiScale := A_ScreenDPI / 96
    W := Round(Row.W * DpiScale)
    H := Round(Row.H * DpiScale)
    if (W <= 0 or H <= 0)
        return

    ; UI_CORNER_RADIUS is the GDI ellipse *diameter* (nWidth/nHeight).
    ; Hammerspoon uses xRadius=7 (radius), so diameter = 14 → 7 px arc per corner.
    Diam := _TOOLTIP_CORNER_RADIUS
    if (Diam > W) Diam := W
    if (Diam > H) Diam := H

    Rgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    if Rgn
        DllCall("User32\SetWindowRgn", "Ptr", G.Hwnd, "Ptr", Rgn, "Int", 1)
}

; Show a 1 px semi-transparent border ring that exactly overlays the tooltip.
; Strategy: create a WS_EX_LAYERED window and call UpdateLayeredWindow with a
; 32-bpp pre-multiplied-alpha DIB.  The DIB is painted via GDI RoundRect (which
; writes opaque pixels), then every non-zero pixel's alpha channel is set to the
; desired opacity (0x40 = 25 %).  No DWM rounding can affect the result because
; the window has zero client area — it is just a bitmap handed to the compositor.
_TooltipShowBorder(X, Y, W, H) {
    global _TooltipBorderGui, _TOOLTIP_CORNER_RADIUS

    if _TooltipBorderGui {
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }

    DpiScale := A_ScreenDPI / 96
    Wp := Round(W * DpiScale)
    Hp := Round(H * DpiScale)
    if (Wp <= 0 or Hp <= 0)
        return

    Diam := _TOOLTIP_CORNER_RADIUS
    if (Diam > Wp) Diam := Wp
    if (Diam > Hp) Diam := Hp

    ; ── Build a 32-bpp DIB ───────────────────────────────────────────────────
    BmpInfo := Buffer(40, 0)
    NumPut("UInt",   40,  BmpInfo,  0)   ; biSize
    NumPut("Int",    Wp,  BmpInfo,  4)   ; biWidth
    NumPut("Int",   -Hp,  BmpInfo,  8)   ; biHeight (top-down)
    NumPut("UShort",  1,  BmpInfo, 12)   ; biPlanes
    NumPut("UShort", 32,  BmpInfo, 14)   ; biBitCount
    NumPut("UInt",    0,  BmpInfo, 16)   ; biCompression = BI_RGB

    ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
    PixPtr   := 0
    HBmp     := DllCall("Gdi32\CreateDIBSection",
        "Ptr", ScreenDC, "Ptr", BmpInfo, "UInt", 0,
        "Ptr*", &PixPtr, "Ptr", 0, "UInt", 0, "Ptr")
    MemDC    := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
    DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)

    if (!HBmp or !MemDC) {
        if HBmp  DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
        if MemDC DllCall("Gdi32\DeleteDC",     "Ptr", MemDC)
        return
    }
    OldBmp := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HBmp, "Ptr")

    ; Clear to transparent black (all zeroes = BGRA 0,0,0,0).
    DllCall("Gdi32\PatBlt", "Ptr", MemDC,
        "Int", 0, "Int", 0, "Int", Wp, "Int", Hp, "UInt", 0x42)  ; BLACKNESS

    ; Draw the ring with GDI: white pen, null brush, RoundRect.
    ; GDI writes opaque (alpha=0) pixels into the DIB — we fix alpha below.
    HPen   := DllCall("Gdi32\CreatePen", "Int", 0, "Int", 1, "UInt", 0xFFFFFF, "Ptr")
    HNull  := DllCall("Gdi32\GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH=5
    OldPen := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HPen,  "Ptr")
    OldBr  := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HNull, "Ptr")
    DllCall("Gdi32\RoundRect",
        "Ptr", MemDC, "Int", 0, "Int", 0, "Int", Wp, "Int", Hp,
        "Int", Diam, "Int", Diam)
    DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldPen)
    DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldBr)
    DllCall("Gdi32\DeleteObject", "Ptr", HPen)

    ; Fix pre-multiplied alpha for every pixel GDI painted (non-zero blue channel).
    ; Hammerspoon: strokeColor white alpha=0.25 → alpha_byte = Round(255*0.25)=64=0x40.
    ; Pre-multiplied: R=G=B = Round(255 * 0.25) = 64 = 0x40.
    ; DIB memory layout: B G R A (little-endian UInt = 0xAARRGGBB).
    TotalPx := Wp * Hp
    AlphaByte := 0x40   ; 25 % opacity
    PremulPx  := (AlphaByte << 24) | (AlphaByte << 16) | (AlphaByte << 8) | AlphaByte
    loop TotalPx {
        Offset := (A_Index - 1) * 4
        Raw := NumGet(PixPtr, Offset, "UInt")
        if (Raw != 0)   ; GDI painted this pixel — set correct alpha
            NumPut("UInt", PremulPx, PixPtr, Offset)
    }

    ; ── Create the layered window ─────────────────────────────────────────────
    _TooltipBorderGui := Gui("+AlwaysOnTop -Caption +E0x80000 +E0x20 +LastFound")
    Hwnd := _TooltipBorderGui.Hwnd
    _TooltipDisableDwmRounding(Hwnd)

    ; Show hidden first so UpdateLayeredWindow can position/paint it atomically.
    DllCall("User32\ShowWindow", "Ptr", Hwnd, "Int", 4)   ; SW_SHOWNOACTIVATE=4

    ; UpdateLayeredWindow: positions the window and uploads the bitmap in one call.
    XPx := Round(X * DpiScale)
    YPx := Round(Y * DpiScale)
    PtDest  := Buffer(8, 0)
    NumPut("Int", XPx, PtDest, 0)
    NumPut("Int", YPx, PtDest, 4)
    SizeSrc := Buffer(8, 0)
    NumPut("Int", Wp, SizeSrc, 0)
    NumPut("Int", Hp, SizeSrc, 4)
    PtSrc   := Buffer(8, 0)   ; origin (0,0) in MemDC
    Blend   := Buffer(4, 0)
    NumPut("UChar",   0, Blend, 0)   ; BlendOp  = AC_SRC_OVER
    NumPut("UChar",   0, Blend, 1)   ; BlendFlags
    NumPut("UChar", 255, Blend, 2)   ; SourceConstantAlpha = 255 (per-pixel alpha)
    NumPut("UChar",   1, Blend, 3)   ; AlphaFormat = AC_SRC_ALPHA
    DllCall("User32\UpdateLayeredWindow",
        "Ptr", Hwnd,
        "Ptr", 0,        ; hdcDst = NULL (use screen)
        "Ptr", PtDest,
        "Ptr", SizeSrc,
        "Ptr", MemDC,
        "Ptr", PtSrc,
        "UInt", 0,
        "Ptr", Blend,
        "UInt", 2)       ; ULW_ALPHA

    DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldBmp)
    DllCall("Gdi32\DeleteDC",     "Ptr", MemDC)
    DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
}


; Tell DWM not to apply Windows 11 automatic corner rounding on this window.
; Without this, DWM rounds every top-level window regardless of SetWindowRgn,
; and the DWM arc (large, OS-controlled) overrides our GDI region corners.
_TooltipDisableDwmRounding(Hwnd) {
    ; DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_DONOTROUND = 1
    Pref := Buffer(4, 0)
    NumPut("UInt", 1, Pref)
    DllCall("Dwmapi\DwmSetWindowAttribute", "Ptr", Hwnd, "UInt", 33, "Ptr", Pref, "UInt", 4)
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

