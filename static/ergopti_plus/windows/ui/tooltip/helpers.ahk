; ui/tooltip/helpers.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / Internal Rendering Helpers
; DESCRIPTION:
; Surface lifecycle (suspend/reveal), screen clamping, stack presentation, dequeue rebuild, border teardown, GUI building, text measuring, stacked-corner rounding, border-alpha premultiply, the GDI border ring, DWM rounding control, accent resolution, tint mixing and caret-anchored positioning.
;
; Split out of the former lib/tooltip.ahk (P5 refactor); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.
; ==============================================================================





; ============================================================
; ============================================================
; ======= 2/ Internal helpers ===============================
; ============================================================
; ============================================================

; Surface lifecycle — canonical phases in _shared/modules/tooltip/lifecycle.js.
; AHK uses two HWNDs (content + border); PREPARE keeps both hidden until the
; border DIB and content controls are ready, then REVEAL shows them together.

; Hide content + border without destroying HWNDs. Used before in-place rebuilds
; (LLM streaming refresh, dequeue destack) so a lone border ring never lingers.
_TooltipSuspendSurfaces() {
    global _TooltipBorderGui, _TooltipRowGuis
    if _TooltipBorderGui {
        try GR_Hide(_TooltipBorderGui.Hwnd)
    }
    for , Row in _TooltipRowGuis {
        try DllCall("User32\ShowWindow", "Ptr", Row.Gui.Hwnd, "Int", 0)
    }
}

; Show content + border together after PREPARE completed while hidden.
; The content is a normal Gui (background + text controls); the border is a
; separate pre-painted layered window. ShowWindow only QUEUES a WM_PAINT for the
; content, so if the message queue is busy the border (already painted via
; UpdateLayeredWindow) can appear for up to a few hundred ms over a still-blank
; content window — the "border alone without background" flash. UpdateWindow
; flushes the content's paint SYNCHRONOUSLY (it bypasses the queue), so the
; background+text are on screen BEFORE the border is revealed and the two surfaces
; appear as one. This keeps the two-window design but removes the visible seam.
_TooltipRevealSurfaces() {
    global _TooltipBorderGui, _TooltipRowGuis
    if (_TooltipRowGuis.Length > 0) {
        try DllCall("User32\ShowWindow", "Ptr", _TooltipRowGuis[1].Gui.Hwnd, "Int", 4)
        try DllCall("User32\UpdateWindow", "Ptr", _TooltipRowGuis[1].Gui.Hwnd)
    }
    if _TooltipBorderGui {
        GR_Show(_TooltipBorderGui.Hwnd)
    }
}

; PREPARE + REVEAL for a built stack. Pos = { X, Y }, Row = { Gui, W, H }.
; Shift an anchor so the W×H tooltip stays inside the work area of the monitor
; under it (fall back to the primary monitor, then the full virtual screen). Without
; this a wide tooltip anchored near the bottom-right caret overflows the screen and
; is clipped — the truncation reported for long predictions in a corner.
_TooltipClampToScreen(X, Y, W, H) {
    ; Margin kept clear of every screen edge — mirrors the shared positioning spec
    ; (constants.toml [positioning].screen_margin = 5) that HS clamps with, so the
    ; Windows tooltip lands at the same on-screen position as Hammerspoon.
    static MARGIN := 5
    L := 0, Top := 0, R := A_ScreenWidth, B := A_ScreenHeight
    try {
        found := false
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &ml, &mt, &mr, &mb)
            if (X >= ml and X < mr and Y >= mt and Y < mb) {
                MonitorGetWorkArea(A_Index, &L, &Top, &R, &B)
                found := true
                break
            }
        }
        if !found
            MonitorGetWorkArea(MonitorGetPrimary(), &L, &Top, &R, &B)
    }
    ; clamp(x, L+margin, R-W-margin); same for y — identical to the macOS renderer.
    X := Max(L + MARGIN, Min(X, R - W - MARGIN))
    Y := Max(Top + MARGIN, Min(Y, B - H - MARGIN))
    return { X: X, Y: Y }
}

_TooltipPresentStack(Pos, Row, ArmSafety := true) {
    global _TooltipShownHwnds, _TOOLTIP_HWND_TRACK_CAP, _TOOLTIP_SAFETY_SEC
    global _TooltipLastPos
    ; Keep the whole tooltip on-screen — a wide prediction near the bottom-right
    ; corner would otherwise overflow and be clipped.
    Pos := _TooltipClampToScreen(Pos.X, Pos.Y, Row.W, Row.H)
    _TooltipLastPos := Pos

    ; PREPARE — hidden at final coordinates (Hwnd valid, nothing painted yet).
    Row.Gui.Show(Format("Hide NoActivate w{1} h{2} x{3} y{4}", Row.W, Row.H, Pos.X, Pos.Y))
    _TooltipDisableDwmRounding(Row.Gui.Hwnd)
    if (_TooltipShownHwnds.Length >= _TOOLTIP_HWND_TRACK_CAP) {
        DroppedHwnd := _TooltipShownHwnds.RemoveAt(1)
        GR_DestroyWindow(DroppedHwnd)
    }
    _TooltipShownHwnds.Push(Row.Gui.Hwnd)
    if ArmSafety
        SetTimer(_TooltipTimerFn, -Round(_TOOLTIP_SAFETY_SEC * 1000))
    _TooltipApplyStackedCorners()
    _TooltipShowBorder(Pos.X, Pos.Y, Row.W, Row.H, false)
    _TooltipRevealSurfaces()
}

; In-place destack rebuild — SUSPEND → build → PREPARE → REVEAL without TEARDOWN.
; Preserves dequeue state and avoids border-only flashes during row expiry.
_TooltipDequeueRebuild(Items) {
    global _TooltipGeneration, _TooltipTimerGeneration, _TooltipDequeueActive
    global _TooltipDequeueItems, _TooltipLastPos
    global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC

    _TooltipGeneration += 1
    _TooltipTimerGeneration := _TooltipGeneration
    SetTimer(_TooltipTimerFn, 0)
    _TooltipSuspendSurfaces()

    try {
        _TooltipBuildGui(Items)
    } catch {
        TooltipHide("DequeueBuildFail", true)
        return
    }

    Rows := _TooltipRowGuis
    if (Rows.Length == 0) {
        TooltipHide("DequeueNoRows", true)
        return
    }

    Pos := IsObject(_TooltipLastPos) ? _TooltipLastPos : _TooltipResolvePosition()
    Row := Rows[1]
    try {
        _TooltipPresentStack(Pos, Row, false)
    } catch {
        TooltipHide("DequeuePresentFail", true)
        return
    }

    MaxMs := 0
    Now := A_TickCount
    ; Snapshot before iterating — _TooltipDequeueItems may have been reset to 0
    ; by a concurrent TooltipHide() (e.g. the safety timer firing between the
    ; _TooltipBuildGui call above and this point). Iterating 0 throws
    ; "Value not enumerable", which is the crash reported by the user.
    DequeueSnapshot := _TooltipDequeueItems
    if IsObject(DequeueSnapshot) {
        for , Item in DequeueSnapshot {
            if (Item.ExpireMs > 0) {
                Remaining := Max(50, Item.ExpireMs - Now)
                if (Remaining > MaxMs)
                    MaxMs := Remaining
            }
        }
    }
    if (MaxMs > 0)
        SetTimer(_TooltipTimerFn, -MaxMs)
    _TooltipDequeueActive := true
}

; Tear down only the border overlay (used before LLM content rebuild).
_TooltipTeardownBorder() {
    global _TooltipBorderGui, _TooltipShownBorderHwnds
    if _TooltipBorderGui {
        try GR_Hide(_TooltipBorderGui.Hwnd)
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }
    for , Hwnd in _TooltipShownBorderHwnds {
        GR_DestroyWindow(Hwnd)
    }
    _TooltipShownBorderHwnds := []
}

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
    _TooltipGui := 0
    _TooltipRowGuis := []

    ; WinGetClientPos returns physical pixels — divide by DpiScale to get logical.
    DpiScale := A_ScreenDPI / 96

    ; ── Measure all text items ──────────────────────────────────────────────
    ; GDI GetTextExtentPoint32W — same path as the LLM renderer. Transient
    ; Probe Guis inherit the OS default minimum client width (~640 logical px
    ; on Windows 11), which made compact rows (e.g. the violet « Génération en
    ; cours… » spinner) stretch far beyond their text.
    Sizes := []
    MaxW := 0
    for , Item in Items {
        S := _TooltipMeasureTextSize(Item.Text, _TOOLTIP_FONT_SIZE)
        Sizes.Push(S)
        if (S.W > MaxW)
            MaxW := S.W
    }

    MaxLabelW := 0
    LabelSizes := []
    for , Item in Items {
        Label := Item.HasOwnProp("TriggerLabel") ? Item.TriggerLabel : ""
        if (Label != "") {
            LS := _TooltipMeasureTextSize(Label, _TOOLTIP_LABEL_FONT_SIZE)
            LabelSizes.Push(LS)
            if (LS.W > MaxLabelW)
                MaxLabelW := LS.W
        } else {
            LabelSizes.Push({ W: 0, H: 0 })
        }
    }

    LabelZone := MaxLabelW > 0 ? (_TOOLTIP_LABEL_GAP + MaxLabelW) : 0
    TotalW := _TOOLTIP_PADDING_X + MaxW + LabelZone + _TOOLTIP_PADDING_X
    Count := Items.Length
    SEP_H := 1   ; 1 px separator between rows, in logical pixels

    ; ── Compute per-row heights and total canvas height ─────────────────────
    RowMeta := []
    TotalH := 0
    for Idx, Item in Items {
        S := Sizes[Idx]
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
    ; WS_EX_TOOLWINDOW (0x80) suppresses the DWM drop shadow and rounded-corner
    ; treatment that Windows 11 applies to all top-level windows; combined with
    ; SetWindowRgn this gives us full control over the visible shape.
    G := Gui("+AlwaysOnTop -Caption +E0x20 +E0x80 +LastFound")
    G.BackColor := _TooltipMixTintHex(FirstColorHex)
    G.MarginX := 0
    G.MarginY := 0

    for Idx, Item in Items {
        ColorHex := Item.HasOwnProp("ColorHex") ? Item.ColorHex : ""
        BgHex := _TooltipMixTintHex(ColorHex)
        S := Sizes[Idx]
        Meta := RowMeta[Idx]
        RowY := Meta.Y
        RowH := Meta.H
        IsDimmed := Item.HasOwnProp("IsDimmed") && Item.IsDimmed

        ; Full-width background band for this row's tint color.
        G.SetFont("norm s1", _TOOLTIP_FONT_NAME)
        G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", BgHex, RowY, TotalW, RowH), "")

        ; Main text overlay. Dimmed alternates (rows beyond the firing one of
        ; their group) get gray text + strikethrough so the user sees what is
        ; available without confusing it with the actual outcome. ``norm``
        ; resets any prior Strike/Bold/Italic before applying this row's style.
        if IsDimmed {
            G.SetFont("norm c" . _TOOLTIP_DIM_COLOR_HEX . " strike s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
        } else {
            G.SetFont("norm cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
        }
        G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
            _TOOLTIP_PADDING_X, RowY + _TOOLTIP_PADDING_Y, MaxW, S.H), Item.Text)

        ; Trigger label on the right.
        Label := Item.HasOwnProp("TriggerLabel") ? Item.TriggerLabel : ""
        if (Label != "" and LabelZone > 0) {
            LS := LabelSizes[Idx]
            LabelX := TotalW - _TOOLTIP_PADDING_X - MaxLabelW
            ; * sits high in its bounding box in Segoe UI — nudge down slightly.
            StarFix      := (Label == "*") ? 1 : 0
            RightFix     := (Label == "↵") ? 3 : 0
            CenterOffset := Max(0, (S.H - LS.H) // 2)
            ; ↵ appears lower than center only when the row is tall enough for
            ; centering to kick in (multi-line text); for single-line rows the
            ; centering offset is 0 and no upward shift is needed.
            DescenderFix := (Label == "↵" and CenterOffset > 0) ? 4 : 0
            LabelY := RowY + _TOOLTIP_PADDING_Y + CenterOffset - DescenderFix + StarFix
            ; Dimmed rows get a darker label so the entire row reads as
            ; "disabled" — same visual treatment as the main text.
            LabelColorHex := IsDimmed ? "707070" : _TOOLTIP_LABEL_COLOR_HEX
            G.SetFont("norm c" . LabelColorHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
                LabelX + RightFix, LabelY, MaxLabelW, LS.H), Label)
        }

        ; 1 px separator — same opacity as the tooltip border (white alpha=0.25).
        ; Colors are pre-blended in UI_SEP_COLOR_HEX during UiStyle_LoadSharedConst.
        if (Idx < Count) {
            SepY := RowY + RowH
            G.SetFont("s1", _TOOLTIP_FONT_NAME)
            G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", _TOOLTIP_SEP_COLOR_HEX, SepY, TotalW, SEP_H), "")
        }
    }

    _TooltipGui := G
    ; Store a single metadata record for the corner/border helper.
    _TooltipRowGuis := [{ Gui: G, H: TotalH, W: TotalW, IsSep: false }]
}

; Cache of measurement HFONTs keyed by device-pixel height. The tooltip only
; ever measures one font name at a couple of sizes, so creating + destroying a
; GDI font on every call (twice per render) is pure waste. The handles live for
; the process — a tiny, bounded GDI cache.
global _TooltipMeasureFontCache := Map()

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

    ; Reuse a cached HFONT keyed by device-pixel height (covers DPI changes too).
    global _TooltipMeasureFontCache
    if _TooltipMeasureFontCache.Has(HeightPx) {
        HFont := _TooltipMeasureFontCache[HeightPx]
    } else {
        HFont := DllCall("Gdi32\CreateFontW",
            "Int", HeightPx, "Int", 0, "Int", 0, "Int", 0,
            "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
            "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
            "WStr", _TOOLTIP_FONT_NAME,
            "Ptr")
        if HFont
            _TooltipMeasureFontCache[HeightPx] := HFont
    }
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
    ; HFont is cached for reuse — do NOT DeleteObject it here.
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
    Rows := _TooltipRowGuis
    if (Rows.Length == 0)
        return

    Row := Rows[1]
    G := Row.Gui

    ; SetWindowRgn operates in physical pixels.
    DpiScale := A_ScreenDPI / 96
    W := Round(Row.W * DpiScale)
    H := Round(Row.H * DpiScale)
    if (W <= 0 or H <= 0)
        return

    ; UI_CORNER_RADIUS is the GDI ellipse *diameter* (nWidth/nHeight).
    ; Hammerspoon uses xRadius=7 (radius), so diameter = 14 → 7 px arc per corner.
    Diam := _TOOLTIP_CORNER_RADIUS
    if (Diam > W)
        Diam := W
    if (Diam > H)
        Diam := H
    Rgn := DllCall("Gdi32\CreateRoundRectRgn",
        "Int", 0, "Int", 0, "Int", W + 1, "Int", H + 1,
        "Int", Diam, "Int", Diam, "Ptr")
    if Rgn
        DllCall("User32\SetWindowRgn", "Ptr", G.Hwnd, "Ptr", Rgn, "Int", 1)
}

; Rewrite every pixel GDI painted into the 32-bpp DIB to the premultiplied border
; color. GDI RoundRect writes opaque white (alpha byte 0); the layered window needs
; premultiplied alpha, so each painted pixel must be overwritten. The outline is a
; 1 px rounded rect, so the ONLY painted pixels are:
;   - the two horizontal straight edges (rows y=0 and y=Hp-1), spanning the width;
;   - the corner arcs, confined to the left/right corner-column zones of the rows
;     within Diam of the top or bottom edge;
;   - the two vertical straight edges (columns x=0 and x=Wp-1) on the middle rows.
; Every other pixel is transparent. Scanning only those zones keeps the cost at
; ~2*Wp + 4*Diam^2 instead of the former 2*Diam*Wp full-band scan — the win is
; largest for the short 1-2 row preview tooltips, where the corner band spans
; almost the entire height and the old scan re-read the transparent interior of
; nearly every row (the BorderPixelLoop hot-path warnings clustered there).
; Correctness is pinned by test_tooltip_border_alpha.ahk, which compares this
; against a full O(Wp*Hp) reference scan over real GDI RoundRect output.
; @param PixPtr {Ptr} Base pointer of the top-down 32-bpp BGRA DIB.
; @param Wp {Integer} Bitmap width in physical pixels.
; @param Hp {Integer} Bitmap height in physical pixels.
; @param Diam {Integer} Corner diameter passed to RoundRect (0 = square corners).
; @param PremulPx {Integer} Premultiplied BGRA value to write into painted pixels.
_TooltipFixBorderAlpha(PixPtr, Wp, Hp, Diam, PremulPx) {
    if (Wp <= 0 or Hp <= 0)
        return
    BandRows := Min(Diam, Hp)
    CornerCols := Min(Diam, Wp)
    RightZoneStart := Wp - CornerCols   ; first column of the right corner zone
    LastColOff := (Wp - 1) * 4
    loop Hp {
        RowY := A_Index - 1
        RowBase := RowY * Wp * 4
        if (RowY == 0 or RowY == Hp - 1) {
            ; Horizontal straight edge — the painted run spans the full width.
            loop Wp {
                Offset := RowBase + (A_Index - 1) * 4
                if (NumGet(PixPtr, Offset, "UInt") != 0)
                    NumPut("UInt", PremulPx, PixPtr, Offset)
            }
        } else if (RowY < BandRows or RowY >= Hp - BandRows) {
            ; Corner-arc row — only the left and right corner column zones can
            ; carry painted pixels (the zones overlap harmlessly when Wp <= 2*Diam).
            loop CornerCols {
                Off := RowBase + (A_Index - 1) * 4
                if (NumGet(PixPtr, Off, "UInt") != 0)
                    NumPut("UInt", PremulPx, PixPtr, Off)
            }
            loop CornerCols {
                Off := RowBase + (RightZoneStart + A_Index - 1) * 4
                if (NumGet(PixPtr, Off, "UInt") != 0)
                    NumPut("UInt", PremulPx, PixPtr, Off)
            }
        } else {
            ; Middle row — only the two vertical edge columns.
            if (NumGet(PixPtr, RowBase, "UInt") != 0)
                NumPut("UInt", PremulPx, PixPtr, RowBase)
            if (NumGet(PixPtr, RowBase + LastColOff, "UInt") != 0)
                NumPut("UInt", PremulPx, PixPtr, RowBase + LastColOff)
        }
    }
}

; Show a 1 px semi-transparent border ring that exactly overlays the tooltip.
; Strategy: create a WS_EX_LAYERED window and call UpdateLayeredWindow with a
; 32-bpp pre-multiplied-alpha DIB.  The DIB is painted via GDI RoundRect (which
; writes opaque pixels), then every non-zero pixel's alpha channel is set to the
; desired opacity (0x40 = 25 %).  No DWM rounding can affect the result because
; the window has zero client area — it is just a bitmap handed to the compositor.
_TooltipShowBorder(X, Y, W, H, Reveal := true) {
    global _TooltipBorderGui, _TOOLTIP_CORNER_RADIUS

    if _TooltipBorderGui {
        try GR_Hide(_TooltipBorderGui.Hwnd)
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }

    DpiScale := A_ScreenDPI / 96
    Wp := Round(W * DpiScale)
    Hp := Round(H * DpiScale)
    if (Wp <= 0 or Hp <= 0)
        return

    Diam := _TOOLTIP_CORNER_RADIUS
    if (Diam > Wp)
        Diam := Wp
    if (Diam > Hp)
        Diam := Hp

    ; ── Build a 32-bpp DIB ───────────────────────────────────────────────────
            BmpInfo := Buffer(40, 0)
    NumPut("UInt", 40, BmpInfo, 0)   ; biSize
    NumPut("Int", Wp, BmpInfo, 4)   ; biWidth
    NumPut("Int", -Hp, BmpInfo, 8)   ; biHeight (top-down)
    NumPut("UShort", 1, BmpInfo, 12)   ; biPlanes
    NumPut("UShort", 32, BmpInfo, 14)   ; biBitCount
    NumPut("UInt", 0, BmpInfo, 16)   ; biCompression = BI_RGB

    ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
    PixPtr := 0
    HBmp := DllCall("Gdi32\CreateDIBSection",
        "Ptr", ScreenDC, "Ptr", BmpInfo, "UInt", 0,
        "Ptr*", &PixPtr, "Ptr", 0, "UInt", 0, "Ptr")
    MemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
    DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)

    if (!HBmp or !MemDC) {
        ; Release whichever handle DID succeed, then always bail. Without explicit
        ; braces, AHK v2's single-line `if` would chain the DeleteDC and return under
        ; the first `if HBmp`, so the surviving MemDC leaked and the function pressed
        ; on with a null bitmap — a slow GDI-handle leak under object pressure.
        if (HBmp)
            DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
        if (MemDC)
            DllCall("Gdi32\DeleteDC", "Ptr", MemDC)
        return
    }
    OldBmp := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HBmp, "Ptr")

    ; Clear to transparent black (all zeroes = BGRA 0,0,0,0).
    DllCall("Gdi32\PatBlt", "Ptr", MemDC,
        "Int", 0, "Int", 0, "Int", Wp, "Int", Hp, "UInt", 0x42)  ; BLACKNESS

    ; Draw the ring with GDI: white pen, null brush, RoundRect.
    ; GDI writes opaque (alpha=0) pixels into the DIB — we fix alpha below.
    HPen := DllCall("Gdi32\CreatePen", "Int", 0, "Int", 1, "UInt", 0xFFFFFF, "Ptr")
    HNull := DllCall("Gdi32\GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH=5
    OldPen := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HPen, "Ptr")
    OldBr := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HNull, "Ptr")
    ; RoundRect with the same Diam as CreateRoundRectRgn — the transparent corner
    ; pixels in the bitmap are what makes the border appear rounded (SetWindowRgn
    ; on a layered window is unreliable; per-pixel alpha is the authoritative shape).
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
    AlphaByte := Round(_TOOLTIP_BORDER_ALPHA * 255)
    PremulPx := (AlphaByte << 24) | (AlphaByte << 16) | (AlphaByte << 8) | AlphaByte
    _hpPix := HotPath_Now()
    _TooltipFixBorderAlpha(PixPtr, Wp, Hp, Diam, PremulPx)
    HotPath_LogIfSlow("Tooltip.BorderPixelLoop", _hpPix, TotalPx . " px")

    ; ── Create the layered window ─────────────────────────────────────────────
    ; WS_EX_TOOLWINDOW (0x80) suppresses DWM automatic corner rounding, same as
    ; the content Gui.  UpdateLayeredWindow is called BEFORE ShowWindow so the
    ; window is never visible in an unpainted state (no ghost flash).
    _TooltipBorderGui := Gui("+AlwaysOnTop -Caption +E0x80000 +E0x20 +E0x80 +LastFound")
    Hwnd := _TooltipBorderGui.Hwnd
    _TooltipDisableDwmRounding(Hwnd)

    ; UpdateLayeredWindow expects screen physical pixels — same coordinate space as
    ; AHK v2 Gui.Show (AHK v2 is per-monitor DPI-aware, so Show("xX yY") already
    ; uses physical px).  No DpiScale multiplication needed here.
    PtDest := Buffer(8, 0)
    NumPut("Int", X, PtDest, 0)
    NumPut("Int", Y, PtDest, 4)
    SizeSrc := Buffer(8, 0)
    NumPut("Int", Wp, SizeSrc, 0)
    NumPut("Int", Hp, SizeSrc, 4)
    PtSrc := Buffer(8, 0)   ; origin (0,0) in MemDC
    Blend := Buffer(4, 0)
    NumPut("UChar", 0, Blend, 0)   ; BlendOp  = AC_SRC_OVER
    NumPut("UChar", 0, Blend, 1)   ; BlendFlags
    NumPut("UChar", 255, Blend, 2)   ; SourceConstantAlpha = 255 (per-pixel alpha)
    NumPut("UChar", 1, Blend, 3)   ; AlphaFormat = AC_SRC_ALPHA
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
    DllCall("Gdi32\DeleteDC", "Ptr", MemDC)
    DllCall("Gdi32\DeleteObject", "Ptr", HBmp)

    ; REVEAL is deferred to _TooltipRevealSurfaces() when Reveal=false so
    ; content and border become visible in the same composition pass.
    if Reveal
        GR_Show(Hwnd)

    global _TooltipShownBorderHwnds, _TOOLTIP_HWND_TRACK_CAP
    if (_TooltipShownBorderHwnds.Length >= _TOOLTIP_HWND_TRACK_CAP) {
        DroppedHwnd := _TooltipShownBorderHwnds.RemoveAt(1)
        GR_DestroyWindow(DroppedHwnd)
    }
    _TooltipShownBorderHwnds.Push(Hwnd)
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

; Resolve the accent hex for an LLM / hotstring tooltip context.
; ``ai_loading`` — violet in-flight tint; user-overridable via the
; ``llm_prediction`` hotstring colour (Delays / settings submenu on Windows).
; Returns "" when no tint should be applied (final predictions by default).
_TooltipResolveAccent(contextKey) {
	global UI_AI_LOADING_HEX
	if (contextKey = "ai_loading") {
		try {
			resolved := HotstringsResolve("llm_prediction", "")
			if (resolved.Color != "")
				return resolved.Color
		}
		if (IsSet(UI_AI_LOADING_HEX) and UI_AI_LOADING_HEX != "")
			return "#" . UI_AI_LOADING_HEX
	}
	return ""
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

    ; Achromatic accent (gray/white/black) — no hue to carry, mirror JS fallback
    if (Delta <= 0.0001) {
        return _TOOLTIP_DEFAULT_BG_HEX
    }

    Hue := 0.0
    if (MaxC == R) {
        Hue := Mod((G - B) / Delta + 6, 6)
    } else if (MaxC == G) {
        Hue := (B - R) / Delta + 2
    } else {
        Hue := (R - G) / Delta + 4
    }
    Hue := Hue / 6

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




