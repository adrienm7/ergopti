; lib/metrics/wpm_widget.ahk

; ==============================================================================
; MODULE: Real-Time WPM Widget
; DESCRIPTION:
; Displays a small always-on-top floating window showing the user's current
; typing speed (WPM) updated in real time. The value is computed from the
; keylogger's live buffer — the same formula used at flush time — so it
; reflects the current typing burst rather than the last persisted event.
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
;      - Graph: sparkline of recent history rendered as a WebView2 canvas.
; 4. Draggable: click-drag moves the widget anywhere on screen; position
;    is saved to config and restored on next launch.
; 5. Default position: bottom-right corner, above the Windows taskbar.
; 6. Zero-impact when hidden: the SetTimer tick is cancelled when the widget
;    is off — no overhead on the keystroke hot path.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class WPMWidgetConst {
    ; ── Values loaded at runtime from shared/wpm_widget/constants.toml ──────────
    ; Populated by WPMWidget_LoadSharedConst() — zero fallback values here so a
    ; missing TOML is detected immediately rather than silently using stale data.
    ; [compact]
    static W                  := 0
    static H                  := 0
    static H_NUMBER           := 0
    static H_GAP              := 0
    static H_UNIT             := 0
    static NUMBER_FONT_SIZE   := 0
    static UNIT_FONT_SIZE     := 0
    static UNIT_DARKEN        := 0.0
    ; [colors]  (hex strings without leading '#')
    static COLOR_BG_MANUAL    := ""
    static COLOR_BG_AI        := ""
    static COLOR_BG_IDLE      := ""
    static COLOR_TXT_ACTIVE   := ""
    static COLOR_TXT_IDLE     := ""
    ; [colors] — HSL normalisation target for hotstring accent colors
    static COLOR_WIDGET_L     := 0.0
    static COLOR_WIDGET_S     := 0.0
    ; [transparency]
    static ALPHA_ACTIVE       := 0
    static ALPHA_IDLE         := 0

    ; ── Values loaded from shared/timings/constants.toml ────────────────────────
    static IDLE_HIDE_MS       := 0

    ; ── AHK-only constants (no shared TOML equivalent needed) ───────────────────
    ; Rolling window over which WPM is averaged (matches Hammerspoon 15 s).
    static WINDOW_MS          := 15000
    ; Timer tick — how often the display refreshes (ms).
    static TICK_MS            := 500
    ; Graph mode dimensions (wider to show history).
    static GRAPH_W            := 220
    static GRAPH_H            := 100
    ; Margin from screen edges (px).
    static EDGE_MARGIN        := 12
    ; Graph accent line colors — raw hue, used directly as canvas stroke colors.
    static COLOR_GRAPH_MANUAL := "4499ff"
    static COLOR_GRAPH_AI     := "cc88ff"
    ; Config key names written to config.toml under [Script].
    static CFG_VISIBLE        := "wpm_widget_visible"
    static CFG_X              := "wpm_widget_x"
    static CFG_Y              := "wpm_widget_y"
    static CFG_COLORS         := "wpm_widget_colors"
    static CFG_GRAPH          := "wpm_widget_graph"
    ; Minimum window for WPM calculation.
    static WPM_MIN_DURATION_MS := 2000
    ; Ring buffer capacity for recent keystrokes.
    static RING_CAP           := 2000
    ; Number of history ticks kept for the graph.
    static GRAPH_HISTORY      := 40
    ; Maximum WPM assumed for graph scale.
    static GRAPH_SCALE_MAX    := 120
}





; ===================================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===================================

class WPMWidget {
    ; Compact mode GUI handles.
    static _gui           := false
    static _lbl_wpm       := false
    static _lbl_unit      := false
    static _lbl_strip     := false   ; Darker background strip behind the unit label

    ; Graph mode GUI + WebView2 handles.
    static _graph_gui        := false
    static _graph_wv         := false   ; WebView2 controller
    static _graph_wv_ready   := false   ; true once NavigateToString completed

    ; Visibility + position.
    static visible        := false
    static pos_x          := -1         ; -1 = auto-position on first show
    static pos_y          := -1

    ; Ring buffer of recent keystrokes.
    static _ring          := []
    static _ring_head     := 0

    ; WPM history array for graph (newest last).
    static _graph_hist    := []

    ; Derived state refreshed by the tick.
    static _last_wpm      := 0
    static _last_tick     := 0
    static _last_hs       := false
    static _last_ai       := false
    static _last_ac       := false
    ; Timestamps of the last HS/AI/AC keystroke (for source_color_duration logic).
    static _last_hs_tick      := 0
    static _last_ai_tick      := 0
    static _last_ac_tick      := 0
    ; TOML category of the last HS expansion (e.g. "magickey", "autocorrection").
    ; Used to resolve the widget color from the same pipeline as the tooltip.
    static _last_hs_category  := "magickey"
    ; Section hint for the last HS expansion. When the category is "personal" the
    ; section name mirrors a standard category (e.g. "autocorrectionJ") and is
    ; used as a color fallback so personal hotstrings match their group color.
    static _last_hs_section   := ""

    ; Display options.
    static use_colors     := false
    static show_graph     := false

    ; Drag state.
    static _drag_start_x  := 0
    static _drag_start_y  := 0
    static _drag_win_x    := 0
    static _drag_win_y    := 0
    static _dragging      := false

    ; Idle-hide state: wall clock of the last keyboard event seen by the widget.
    static _last_input_ms := 0
}





; ============================================
; ======================================
; ======= 3/ Ring buffer helpers =======
; ======================================
; ============================================

; Categories whose expansions must not color the widget (no visible tooltip,
; or ergonomic substitutions that should stay at the default blue color).
_WPMWidget_NeutralCategory(category) {
    return (category == "rolls" or category == "repeat_key")
}

; Called by the keylogger hook after each accepted keystroke.
; category: TOML group name of the hotstring ("magickey", "rolls", …).
;   Pass "" for manual keystrokes or when the category is unknown.
;   "rolls" and "repeat_key" are treated as neutral and do not color the widget.
WPMWidget_Push(is_hs := false, is_ai := false, is_ac := false, category := "", section := "") {
    if !WPMWidget.visible
        return
    ; Neutral categories count as keystrokes but must not trigger HS color.
    if (is_hs and _WPMWidget_NeutralCategory(category))
        is_hs := false
    cap  := WPMWidgetConst.RING_CAP
    head := WPMWidget._ring_head
    entry := Map("t", A_TickCount, "hs", is_hs, "ai", is_ai, "ac", is_ac)
    if (WPMWidget._ring.Length < cap)
        WPMWidget._ring.Push(entry)
    else
        WPMWidget._ring[head + 1] := entry
    WPMWidget._ring_head := Mod(head + 1, cap)
    now_t := A_TickCount
    WPMWidget._last_tick     := now_t
    WPMWidget._last_input_ms := now_t
    WPMWidget._last_hs   := is_hs
    WPMWidget._last_ai   := is_ai
    WPMWidget._last_ac   := is_ac
    if is_hs {
        WPMWidget._last_hs_tick     := now_t
        WPMWidget._last_hs_category := (category != "") ? category : "magickey"
        WPMWidget._last_hs_section  := section
    }
    if is_ai
        WPMWidget._last_ai_tick := now_t
    if is_ac
        WPMWidget._last_ac_tick := now_t
}


; Compute current WPM from the ring buffer.
WPMWidget_Calc() {
    now    := A_TickCount
    cutoff := now - WPMWidgetConst.WINDOW_MS
    count  := 0
    has_hs := false
    has_ai := false
    has_ac := false
    earliest := now
    latest   := 0
    for ev in WPMWidget._ring {
        t := ev["t"]
        if (t < cutoff)
            continue
        count++
        if ev["hs"]
            has_hs := true
        if ev["ai"]
            has_ai := true
        if ev["ac"]
            has_ac := true
        if (t < earliest)
            earliest := t
        if (t > latest)
            latest := t
    }
    if (count < 2)
        return Map("wpm", 0, "has_hs", has_hs, "has_ai", has_ai, "has_ac", has_ac)
    ; Use now as the right edge (mirrors Hammerspoon): as time passes after the
    ; last keystroke the window grows and WPM decays naturally to 0.
    ; latest - earliest would freeze the WPM at the last typed value.
    elapsed_ms := Max(now - earliest, WPMWidgetConst.WPM_MIN_DURATION_MS)
    wpm := (count / 5) / (elapsed_ms / 60000)
    return Map("wpm", Round(wpm), "has_hs", has_hs, "has_ai", has_ai, "has_ac", has_ac)
}


; Re-projects AccentHex onto the widget HSL target (L=COLOR_WIDGET_L, S=COLOR_WIDGET_S)
; so every hotstring/AI/AC accent color is as vivid as the manual blue (#0055cc).
; Returns a 6-char uppercase hex without '#'. Falls back to FallbackHex on bad input.
_WPMWidget_NormaliseHex(AccentHex, FallbackHex) {
    H := Trim(AccentHex)
    if (SubStr(H, 1, 1) == "#")
        H := SubStr(H, 2)
    if !RegExMatch(H, "^[0-9A-Fa-f]{6}$")
        return FallbackHex

    R := Integer("0x" . SubStr(H, 1, 2)) / 255.0
    G := Integer("0x" . SubStr(H, 3, 2)) / 255.0
    B := Integer("0x" . SubStr(H, 5, 2)) / 255.0

    MaxC  := Max(R, G, B)
    MinC  := Min(R, G, B)
    Delta := MaxC - MinC

    if (Delta <= 0.0001)
        return FallbackHex   ; achromatic — no hue to preserve

    if (MaxC == R)
        Hue := Mod((G - B) / Delta + 6, 6)
    else if (MaxC == G)
        Hue := (B - R) / Delta + 2
    else
        Hue := (R - G) / Delta + 4
    Hue := Hue / 6

    L := WPMWidgetConst.COLOR_WIDGET_L
    S := WPMWidgetConst.COLOR_WIDGET_S
    C := (1 - Abs(2 * L - 1)) * S
    H6 := Hue * 6
    X  := C * (1 - Abs(Mod(H6, 2) - 1))
    M  := L - C / 2

    if (H6 < 1) {
        Nr := C ; Ng := X ; Nb := 0
    } else if (H6 < 2) {
        Nr := X ; Ng := C ; Nb := 0
    } else if (H6 < 3) {
        Nr := 0 ; Ng := C ; Nb := X
    } else if (H6 < 4) {
        Nr := 0 ; Ng := X ; Nb := C
    } else if (H6 < 5) {
        Nr := X ; Ng := 0 ; Nb := C
    } else {
        Nr := C ; Ng := 0 ; Nb := X
    }

    return Format("{1:02X}{2:02X}{3:02X}",
        Max(0, Min(255, Round((Nr + M) * 255))),
        Max(0, Min(255, Round((Ng + M) * 255))),
        Max(0, Min(255, Round((Nb + M) * 255))))
}

; Returns the raw compact-mode background hex for a hotstring category
; (without leading '#'). Reads the color directly from the TOML group file
; via ParseTomlGroupConfig — the same path the tooltip uses — so the widget
; always shows the exact color configured in the hotstring TOML.
; Falls back to FallbackHex if the TOML is absent or has no color.
WPMWidget_CategoryBgColor(CategoryName, FallbackHex, SectionHint := "") {
    try {
        raw := _WPMWidget_ReadTomlColor(CategoryName)
        LoggerDebug("WPMWidget", "CategoryBgColor('%s'): raw='%s' fallback='%s'", CategoryName, raw, FallbackHex)
        if (raw != "") {
            return (SubStr(raw, 1, 1) == "#") ? SubStr(raw, 2) : raw
        }
        if (SectionHint != "") {
            Basecat := _WPMWidget_SectionBaseCategory(SectionHint)
            if (Basecat != "") {
                raw2 := _WPMWidget_ReadTomlColor(Basecat)
                if (raw2 != "") {
                    return (SubStr(raw2, 1, 1) == "#") ? SubStr(raw2, 2) : raw2
                }
            }
        }
    } catch as e {
        LoggerError("WPMWidget", "CategoryBgColor failed for '%s': %s", CategoryName, e.Message)
    }
    return FallbackHex
}

; Read the [_meta] color for a hotstring category directly from the TOML file,
; bypassing HotstringGroupConfig cache to avoid stale empty entries from early
; init calls before _SharedDir was fully resolved.
; Returns "" when the file is absent or has no color key.
_WPMWidget_ReadTomlColor(CategoryName) {
    global _SharedDir, GLOBAL_DEFAULT_COLOR
    FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
    if !FileExist(FilePath)
        return ""
    FileContent := FileRead(FilePath, "UTF-8")
    InMeta := false
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#")
            continue
        if (SubStr(Line, 1, 2) == "[[")
            break
        if (Line == "[_meta]") {
            InMeta := true
            continue
        }
        if (SubStr(Line, 1, 1) == "[") {
            InMeta := false
            continue
        }
        if InMeta and RegExMatch(Line, "^color\s*=\s*`"([^`"]+)`"", &M) {
            c := M[1]
            ; Skip the global blue fallback — it means "no category color set"
            return (c != GLOBAL_DEFAULT_COLOR) ? c : ""
        }
    }
    return ""
}

; Returns the raw accent hex for a hotstring category (without leading '#'),
; used as the graph sparkline stroke color. Falls back to FallbackHex.
WPMWidget_CategoryGraphColor(CategoryName, FallbackHex, SectionHint := "") {
    try {
        raw := _WPMWidget_ReadTomlColor(CategoryName)
        if (raw != "") {
            return (SubStr(raw, 1, 1) == "#") ? SubStr(raw, 2) : raw
        }
        if (SectionHint != "") {
            Basecat := _WPMWidget_SectionBaseCategory(SectionHint)
            if (Basecat != "") {
                raw2 := _WPMWidget_ReadTomlColor(Basecat)
                if (raw2 != "") {
                    return (SubStr(raw2, 1, 1) == "#") ? SubStr(raw2, 2) : raw2
                }
            }
        }
    }
    return FallbackHex
}

; Derive the standard category name from a section name by stripping the
; trailing PascalCase qualifier (e.g. "autocorrectionJ" → "autocorrection",
; "magickey" → "magickey", "distancesreductionQU" → "distancesreduction").
; Returns "" when no known base category can be derived.
_WPMWidget_SectionBaseCategory(SectionName) {
    static KnownCats := ["autocorrection", "magickey", "distancesreduction",
                         "sfbsreduction", "rolls", "personal"]
    Lower := StrLower(SectionName)
    for _, Cat in KnownCats {
        if (SubStr(Lower, 1, StrLen(Cat)) == Cat)
            return Cat
    }
    return ""
}

; Resolve the compact-mode background color for the current source state.
; HS and AC colors are read live from the TOML/override pipeline so user
; customizations in the hotstrings config window are reflected immediately.
WPMWidget_ResolveBgColor(idle, has_hs, has_ai, has_ac, use_colors) {
    if idle
        return WPMWidgetConst.COLOR_BG_IDLE
    if use_colors {
        if has_ai
            return WPMWidgetConst.COLOR_BG_AI
        if has_hs
            return WPMWidget_CategoryBgColor(WPMWidget._last_hs_category, WPMWidgetConst.COLOR_BG_MANUAL, WPMWidget._last_hs_section)
        if has_ac
            return WPMWidget_CategoryBgColor("autocorrection", WPMWidgetConst.COLOR_BG_MANUAL)
    }
    return WPMWidgetConst.COLOR_BG_MANUAL
}


; Resolve the graph accent color hex string.
; HS and AC colors are sourced from the same TOML pipeline as tooltips.
WPMWidget_ResolveGraphColor(has_hs, has_ai, has_ac, use_colors) {
    if use_colors {
        if has_ai
            return WPMWidgetConst.COLOR_GRAPH_AI
        if has_hs
            return WPMWidget_CategoryGraphColor(WPMWidget._last_hs_category, WPMWidgetConst.COLOR_GRAPH_MANUAL, WPMWidget._last_hs_section)
        if has_ac
            return WPMWidget_CategoryGraphColor("autocorrection", WPMWidgetConst.COLOR_GRAPH_MANUAL)
    }
    return WPMWidgetConst.COLOR_GRAPH_MANUAL
}





; ==================================================
; ==================================================
; ======= 4/ Default position (bottom-right) =======
; ==================================================
; ==================================================

; Returns the default top-left position for the compact widget.
; Bottom-right corner lands at (wr - EDGE_MARGIN, wb - EDGE_MARGIN) so the widget
; sits just above the taskbar with the same margin on both sides.
; pos_x/pos_y always store the compact top-left; WPMWidget_ShowPos() derives the
; actual top-left for the current mode from that anchor via the shared bottom-right corner.
WPMWidget_DefaultPos(&out_x, &out_y) {
    MonitorGetWorkArea(, &wl, &wt, &wr, &wb)
    out_x := wr - WPMWidgetConst.W  - WPMWidgetConst.EDGE_MARGIN
    out_y := wb - WPMWidgetConst.H  - WPMWidgetConst.EDGE_MARGIN
}

; Derives the top-left corner for the current display mode from the saved compact
; top-left (pos_x/pos_y). The bottom-right corner is kept constant across modes.
WPMWidget_ShowPos(&out_x, &out_y) {
    if WPMWidget.show_graph {
        ; bottom-right of compact = pos_x + W, pos_y + H
        ; top-left of graph       = bottom-right - GRAPH_W, bottom-right - GRAPH_H
        out_x := WPMWidget.pos_x + WPMWidgetConst.W - WPMWidgetConst.GRAPH_W
        out_y := WPMWidget.pos_y + WPMWidgetConst.H - WPMWidgetConst.GRAPH_H
    } else {
        out_x := WPMWidget.pos_x
        out_y := WPMWidget.pos_y
    }
}





; ============================================
; ===================================
; ======= 5/ GUI construction =======
; ===================================
; ============================================

; Returns a hex color string darkened by 25% (each RGB channel × 0.75).
; Input and output are 6-character hex strings without leading '#'.
_WPMWidget_DarkenHex(hex) {
    f := WPMWidgetConst.UNIT_DARKEN
    r := Round(Integer("0x" . SubStr(hex, 1, 2)) * f)
    g := Round(Integer("0x" . SubStr(hex, 3, 2)) * f)
    b := Round(Integer("0x" . SubStr(hex, 5, 2)) * f)
    return Format("{:02x}{:02x}{:02x}", r, g, b)
}


WPMWidget_BuildCompact() {
    w       := WPMWidgetConst.W
    h       := WPMWidgetConst.H
    h_num   := WPMWidgetConst.H_NUMBER
    h_gap   := WPMWidgetConst.H_GAP
    h_unit  := WPMWidgetConst.H_UNIT
    strip_y := h_num + h_gap
    dark_bg := _WPMWidget_DarkenHex(WPMWidgetConst.COLOR_BG_IDLE)

    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
    g.MarginX   := 0
    g.MarginY   := 0

    ; Large WPM number — vertically centred in the upper zone.
    g.SetFont("s" . WPMWidgetConst.NUMBER_FONT_SIZE . " w700 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_wpm := g.AddText("x0 y0 w" . w . " h" . h_num . " Center BackgroundTrans +0x200", "—")

    ; Darker strip behind the unit label (drawn before the label so it appears below it).
    g.SetFont("s1", "Segoe UI")
    lbl_strip := g.AddText("x0 y" . strip_y . " w" . w . " h" . h_unit . " Background" . dark_bg, "")

    ; Unit label text drawn on top of the strip.
    g.SetFont("s" . WPMWidgetConst.UNIT_FONT_SIZE . " w600 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_unit := g.AddText("x0 y" . strip_y . " w" . w . " h" . h_unit . " Center BackgroundTrans",
        t("menu.metrics.wpm_unit"))

    lbl_wpm.OnEvent("Click",   WPMWidget_DragStart)
    lbl_unit.OnEvent("Click",  WPMWidget_DragStart)
    lbl_strip.OnEvent("Click", WPMWidget_DragStart)
    g.OnEvent("Close", (*) => WPMWidget_Hide())
    ; WM_EXITSIZEMOVE fires after the OS native move loop completes (PostMessage WM_NCLBUTTONDOWN).
    OnMessage(0x0232, WPMWidget_DragEnd, 1)

    WPMWidget._gui       := g
    WPMWidget._lbl_wpm   := lbl_wpm
    WPMWidget._lbl_unit  := lbl_unit
    WPMWidget._lbl_strip := lbl_strip
}


WPMWidget_BuildGraph() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM Graph")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
    g.MarginX   := 0
    g.MarginY   := 0

    g.OnEvent("Close", (*) => WPMWidget_Hide())
    OnMessage(0x0232, WPMWidget_DragEnd, 1)

    WPMWidget._graph_gui      := g
    WPMWidget._graph_wv       := false
    WPMWidget._graph_wv_ready := false
}


; Attaches WebView2 to the graph Gui after it has been shown.
; WebView2.CreateControllerAsync requires the host window to be visible.
; Uses the callback form of WebView2.create so the controller Ptr is fully
; initialised before we call any methods on it — the await() form can return
; an object whose COM Ptr is still 0 when the Promise resolves.
WPMWidget_AttachWebView() {
    w := WPMWidgetConst.GRAPH_W
    h := WPMWidgetConst.GRAPH_H
    g := WPMWidget._graph_gui
    if !g
        return
    loader := _VendorDir . "\64bit\WebView2Loader.dll"
    udir   := A_Temp . "\ergopti_wpm_wv2_" . A_TickCount
    DirCreate(udir)
    hwnd := g.Hwnd
    LoggerInfo("WPMWidget", "AttachWebView hwnd=" . hwnd . " loader_exists=" . (FileExist(loader) ? "yes" : "no"))
    try {
        WebView2.create(hwnd, WPMWidget_OnControllerReady, 0, udir, "", 0, loader)
    } catch as e {
        LoggerError("WPMWidget", "WebView2 create failed: " . e.Message . " (" . e.File . ":" . e.Line . ")")
    }
}


; Called by WebView2 once the controller is fully ready.
WPMWidget_OnControllerReady(wvc) {
    try {
        ; Opaque dark background — avoids white flash before the canvas renders.
        try wvc.DefaultBackgroundColor := 0xFF1a1a2e

        ; Fill() resizes the WebView to match the host window client rect.
        wvc.Fill()

        ; WebView2 ignores the Gui's -DPIScale flag and applies the system DPI
        ; factor internally, so the logical pixels it renders into are smaller
        ; than the physical pixels we requested. We pass those logical dimensions
        ; to the HTML so the canvas coordinate system matches exactly.
        dpi := DllCall("GetDpiForWindow", "ptr", WPMWidget._graph_gui.Hwnd, "uint")
        if (dpi < 72)
            dpi := 96
        scale := dpi / 96
        w := Round(WPMWidgetConst.GRAPH_W / scale)
        h := Round(WPMWidgetConst.GRAPH_H / scale)
        LoggerInfo("WPMWidget", "DPI=%d scale=%.2f logical w=%d h=%d.", dpi, scale, w, h)

        ; Register WebMessageReceived BEFORE NavigateToString so the handler is
        ; in place before the inline HTML script runs and posts "ready". If the
        ; handler were registered after, the message could be lost on fast loads.
        wvc.CoreWebView2.WebMessageReceived(WPMWidget_OnWebMessage)

        wvc.CoreWebView2.NavigateToString(WPMWidget_GraphHtml(w, h))

        WPMWidget._graph_wv := wvc
        LoggerInfo("WPMWidget", "WebView2 controller ready — page loading.")

        ; Safety fallback: if the web message is never received (e.g. WebView2
        ; processed the inline HTML before the handler was registered), mark
        ; ready after 2 s so the graph is not permanently stuck.
        SetTimer(WPMWidget_FallbackReady, -2000)
    } catch as e {
        LoggerError("WPMWidget", "OnControllerReady failed: " . e.Message . " (" . e.File . ":" . e.Line . ")")
    }
}


WPMWidget_OnWebMessage(sender, args) {
    try msg := args.TryGetWebMessageAsString()
    catch
        msg := ""
    if (msg != "ready")
        return
    if WPMWidget._graph_wv_ready  ; already handled by fallback
        return
    WPMWidget._graph_wv_ready := true
    LoggerInfo("WPMWidget", "Page ready (web message) — pushing first graph update.")
    WPMWidget_PushGraphUpdate("0", WPMWidgetConst.COLOR_TXT_IDLE, false, false, false, true)
}


WPMWidget_FallbackReady() {
    if WPMWidget._graph_wv_ready  ; web message already handled it
        return
    WPMWidget._graph_wv_ready := true
    LoggerInfo("WPMWidget", "Page ready (fallback timer) — pushing first graph update.")
    WPMWidget_PushGraphUpdate("0", WPMWidgetConst.COLOR_TXT_IDLE, false, false, false, true)
}


; Returns the self-contained HTML for the graph canvas.
; Mirrors the Hammerspoon graph style: dark semi-transparent rounded pill,
; colored fill + stroke line, WPM label at the top.
WPMWidget_GraphHtml(w, h) {
    ; The canvas covers the full WebView2 area. roundRect clips all drawing to
    ; a rounded rectangle so the pill shape is preserved without relying on
    ; window-level transparency. Background colour matches COLOR_BG_IDLE so the
    ; Gui backdrop and the canvas surface are visually identical on load.
    ; Hammerspoon style: black semi-transparent rounded pill, white 14px label,
    ; colored fill+stroke graph, label centered at top.
    bgRgba := "rgba(0,0,0,0.8)"
    return "<!DOCTYPE html><html><head><meta charset='utf-8'><style>"
        . "html,body{margin:0;padding:0;width:" . w . "px;height:" . h . "px;overflow:hidden;background:transparent}"
        . "</style></head><body>"
        . "<canvas id='c' width='" . w . "' height='" . h . "' style='position:absolute;left:0;top:0'></canvas>"
        . "<script>"
        . "const c=document.getElementById('c'),ctx=c.getContext('2d');"
        . "const W=" . w . ",H=" . h . ";"
        . "const PAD=5,TS=15,LH=TS*2,GH=H-LH-PAD*2,GW=W-PAD*2,R=8,FA=0.2;"
        . "function rr(x,y,w,h,r){ctx.beginPath();ctx.moveTo(x+r,y);ctx.arcTo(x+w,y,x+w,y+r,r);ctx.arcTo(x+w,y+h,x+w-r,y+h,r);ctx.arcTo(x,y+h,x,y+h-r,r);ctx.arcTo(x,y,x+r,y,r);ctx.closePath();}"
        . "function drawBg(){ctx.fillStyle='" . bgRgba . "';rr(0,0,W,H,R);ctx.fill();ctx.strokeStyle='rgba(255,255,255,0.4)';ctx.lineWidth=1;ctx.stroke();}"
        . "function drawLabel(txt){ctx.save();ctx.fillStyle='rgba(255,255,255,1)';ctx.font=TS+'px Segoe UI,Arial';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(txt,W/2,LH/2);ctx.restore();}"
        . "window.updateGraph=function(d){"
        . "  ctx.clearRect(0,0,W,H);drawBg();"
        . "  const n=d.hist?d.hist.length:0,lbl=d.label||'—';"
        . "  if(n<2){drawLabel(lbl);return;}"
        . "  const mx=d.scale||120,step=GW/(n-1),col='#'+(d.color||'4499ff');"
        . "  ctx.save();rr(0,0,W,H,R);ctx.clip();"
        . "  ctx.beginPath();ctx.moveTo(PAD,LH+PAD+GH);"
        . "  for(let i=0;i<n;i++)ctx.lineTo(PAD+i*step,LH+PAD+GH-(d.hist[i]/mx)*GH);"
        . "  ctx.lineTo(PAD+(n-1)*step,LH+PAD+GH);ctx.closePath();"
        . "  ctx.globalAlpha=0.2;ctx.fillStyle=col;ctx.fill();ctx.globalAlpha=1;"
        . "  ctx.beginPath();"
        . "  for(let i=0;i<n;i++){const x=PAD+i*step,y=LH+PAD+GH-(d.hist[i]/mx)*GH;i===0?ctx.moveTo(x,y):ctx.lineTo(x,y);}"
        . "  ctx.strokeStyle=col;ctx.lineWidth=2;ctx.stroke();"
        . "  ctx.restore();drawLabel(lbl);"
        . "};"
        . "drawBg();drawLabel('—');"
        . "if(window.chrome&&window.chrome.webview)window.chrome.webview.postMessage('ready');"
        . "</script></body></html>"
}




; ── Drag support ──────────────────────────────────────────────────────────────
; Non-blocking drag: WM_NCLBUTTONDOWN tells Windows to handle the move loop
; natively — the window follows the cursor with zero lag and no timer polling.
; WPMWidget_DragEnd (WM_EXITSIZEMOVE) fires when the user releases the button
; and saves the final compact-anchor position to config.

WPMWidget_DragStart(ctrl, info, *) {
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if !gui_ref || WPMWidget._dragging
        return
    WPMWidget._dragging := true
    ; PostMessage WM_NCLBUTTONDOWN with HTCAPTION (2) to let the OS run the
    ; native move loop — eliminates polling jitter entirely.
    PostMessage(0x00A1, 2, 0, , gui_ref)
}

WPMWidget_DragEnd(*) {
    if !WPMWidget._dragging
        return
    WPMWidget._dragging := false
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if !gui_ref
        return
    gui_ref.GetPos(&fx, &fy)
    if WPMWidget.show_graph {
        ; bottom-right = graph top-left + graph size; compact top-left = bottom-right - compact size
        WPMWidget.pos_x := fx + WPMWidgetConst.GRAPH_W - WPMWidgetConst.W
        WPMWidget.pos_y := fy + WPMWidgetConst.GRAPH_H - WPMWidgetConst.H
    } else {
        WPMWidget.pos_x := fx
        WPMWidget.pos_y := fy
    }
    WPMWidget_SavePosition()
}





; ============================================
; ==============================
; ======= 6/ Show / Hide =======
; ==============================
; ============================================

WPMWidget_Show() {
    LoggerStart("WPMWidget", "Showing widget (graph=%s, pos_x=%d, pos_y=%d)…",
        WPMWidget.show_graph, WPMWidget.pos_x, WPMWidget.pos_y)
    if WPMWidget.show_graph {
        if !WPMWidget._graph_gui
            WPMWidget_BuildGraph()
    } else {
        if !WPMWidget._gui
            WPMWidget_BuildCompact()
    }

    WPMWidget.visible := true

    if (WPMWidget.pos_x = -1 || WPMWidget.pos_y = -1) {
        WPMWidget_DefaultPos(&def_x, &def_y)
        WPMWidget.pos_x := def_x
        WPMWidget.pos_y := def_y
    }

    w      := WPMWidget.show_graph ? WPMWidgetConst.GRAPH_W : WPMWidgetConst.W
    h      := WPMWidget.show_graph ? WPMWidgetConst.GRAPH_H : WPMWidgetConst.H
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui

    ; Derive the top-left for the current mode from the compact anchor (pos_x/pos_y).
    WPMWidget_ShowPos(&show_x, &show_y)

    ; Show the window fully transparent (alpha=0) so WebView2 can attach and
    ; render without being visible to the user. Hide() suspends the WebView2
    ; renderer, making ExecuteScriptAsync a no-op — transparency avoids that.
    ; The Tick sets the real alpha when the user starts typing.
    gui_ref.Show("x" . show_x . " y" . show_y
        . " w" . w . " h" . h . " NoActivate")
    WinSetTransparent(0, gui_ref)

    ; WebView2 must be attached after the window is visible.
    if WPMWidget.show_graph && !WPMWidget._graph_wv
        WPMWidget_AttachWebView()

    SetTimer(WPMWidget_Tick, WPMWidgetConst.TICK_MS)
    LoggerSuccess("WPMWidget", "Widget shown at (%d, %d) mode=%s, wv_ready=%s.",
        WPMWidget.pos_x, WPMWidget.pos_y, WPMWidget.show_graph ? "graph" : "compact",
        WPMWidget._graph_wv_ready)
}

WPMWidget_Hide() {
    WPMWidget.visible := false
    SetTimer(WPMWidget_Tick, 0)
    if WPMWidget._gui
        try WPMWidget._gui.Hide()
    if WPMWidget._graph_gui
        try WPMWidget._graph_gui.Hide()
    try LoggerDone("WPMWidget", "Widget hidden.")
}

WPMWidget_Toggle() {
    if WPMWidget.visible
        WPMWidget_Hide()
    else
        WPMWidget_Show()
    WPMWidget_SaveVisible()
}





; ============================================
; =========================================
; ======= 7/ Tick — refresh display =======
; =========================================
; ============================================

WPMWidget_Tick() {
    if !WPMWidget.visible
        return

    now    := A_TickCount
    result := WPMWidget_Calc()
    wpm    := result["wpm"]
    ; Source color only active for 1 s after the last event of that type.
    has_hs := (now - WPMWidget._last_hs_tick) < 1000
    has_ai := (now - WPMWidget._last_ai_tick) < 1000
    has_ac := (now - WPMWidget._last_ac_tick) < 1000

    ; Update graph history.
    WPMWidget._graph_hist.Push(wpm)
    while (WPMWidget._graph_hist.Length > WPMWidgetConst.GRAPH_HISTORY)
        WPMWidget._graph_hist.RemoveAt(1)

    ; Hide after IDLE_HIDE_MS of keyboard inactivity.
    keyboard_idle := WPMWidget._last_input_ms > 0
        && (now - WPMWidget._last_input_ms) > WPMWidgetConst.IDLE_HIDE_MS
    ; Hide immediately if the mouse/touchpad was used more recently than the last keystroke —
    ; A_TimeIdleMouse is built into AHK and requires no hook install.
    mouse_active  := A_TimeIdleMouse < A_TimeIdleKeyboard
    should_show   := !keyboard_idle && !mouse_active && ((wpm > 0) || has_hs || has_ai || has_ac)
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if gui_ref {
        try {
            if should_show {
                gui_ref.Show("NoActivate")
                WinSetTransparent(WPMWidgetConst.ALPHA_ACTIVE, gui_ref)
            } else {
                ; Graph mode: keep window alive (alpha=0) so WebView2 stays active.
                ; Compact mode: Hide() is fine, no WebView2 to preserve.
                if WPMWidget.show_graph
                    WinSetTransparent(0, gui_ref)
                else
                    gui_ref.Hide()
            }
        } catch {
            ; The underlying HWND was destroyed outside our control (e.g. the user
            ; closed the window via the taskbar). Clear the stale handle so the next
            ; tick rebuilds the Gui cleanly instead of looping into the same error.
            if WPMWidget.show_graph
                WPMWidget._graph_gui := false
            else
                WPMWidget._gui := false
        }
    }
    if !should_show
        return

    is_idle  := false
    bg_color := WPMWidget_ResolveBgColor(is_idle, has_hs, has_ai, has_ac, WPMWidget.use_colors)
    alpha    := WPMWidgetConst.ALPHA_ACTIVE
    wpm_str  := String(wpm)
    txt_col  := WPMWidgetConst.COLOR_TXT_ACTIVE

    if WPMWidget.show_graph {
        if WPMWidget._graph_gui {
            WPMWidget_PushGraphUpdate(wpm_str, txt_col, has_hs, has_ai, has_ac, is_idle)
        }
    } else {
        if WPMWidget._gui {
            try {
                WPMWidget._gui.BackColor := bg_color
                WinSetTransparent(alpha, WPMWidget._gui)
                dark_bg := _WPMWidget_DarkenHex(bg_color)
                if WPMWidget._lbl_strip
                    WPMWidget._lbl_strip.Opt("Background" . dark_bg)
                if WPMWidget._lbl_wpm && (wpm_str != WPMWidget._lbl_wpm.Value)
                    WPMWidget._lbl_wpm.Value := wpm_str
                if WPMWidget._lbl_wpm
                    WPMWidget._lbl_wpm.SetFont("c" . txt_col)
                if WPMWidget._lbl_unit
                    WPMWidget._lbl_unit.SetFont("c" . txt_col)
            } catch {
                WPMWidget._gui       := false
                WPMWidget._lbl_wpm   := false
                WPMWidget._lbl_unit  := false
                WPMWidget._lbl_strip := false
            }
        }
    }
    WPMWidget._last_wpm := wpm
}


; Sends updated graph data to the WebView2 canvas via postMessage.
WPMWidget_PushGraphUpdate(wpm_str, txt_col, has_hs, has_ai, has_ac, is_idle) {
    if !WPMWidget._graph_wv_ready
        return

    accent := WPMWidget_ResolveGraphColor(has_hs, has_ai, has_ac, WPMWidget.use_colors)
    ; Build compact JSON array of history values.
    hist_parts := []
    for v in WPMWidget._graph_hist
        hist_parts.Push(String(v))
    hist_json := "[" . StrJoin(hist_parts, ",") . "]"

    label := wpm_str . " " . t("menu.metrics.wpm_unit")
    json  := '{"hist":' . hist_json
        . ',"color":"' . accent . '"'
        . ',"txt":"'   . txt_col . '"'
        . ',"label":"' . label . '"'
        . ',"scale":' . WPMWidgetConst.GRAPH_SCALE_MAX . '}'

    ; Pass the JSON object directly — no extra string wrapping needed.
    try WPMWidget._graph_wv.CoreWebView2.ExecuteScriptAsync(
        "if(window.updateGraph)window.updateGraph(" . json . ")")
}


; Escapes a string for safe embedding in a JS string literal.
JSON_Escape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    return '"' . s . '"'
}


; Joins array elements with a separator.
StrJoin(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") . v
    return out
}





; ============================================
; =====================================
; ======= 8/ Config persistence =======
; =====================================
; ============================================

; Reads shared/wpm_widget/constants.toml and shared/timings/constants.toml at
; startup and populates the zero-initialised fields of WPMWidgetConst.
; Logs an error and leaves the zeros in place if the file cannot be found.
WPMWidget_LoadSharedConst() {
    global _SharedDir
    wpm_path     := _SharedDir . "\wpm_widget\constants.toml"
    timings_path := _SharedDir . "\timings\constants.toml"

    wpm_c := ParseTomlFile(wpm_path)
    if !wpm_c.Count {
        LoggerError("WPMWidget", "shared/wpm_widget/constants.toml not found — widget non-functional.")
        return
    }

    ; [compact]
    WPMWidgetConst.W                := Integer(IniCacheGet(wpm_c, "compact", "width",                  "80"))
    WPMWidgetConst.H                := Integer(IniCacheGet(wpm_c, "compact", "height",                 "68"))
    WPMWidgetConst.H_NUMBER         := Integer(IniCacheGet(wpm_c, "compact", "height_number",          "44"))
    WPMWidgetConst.H_GAP            := Integer(IniCacheGet(wpm_c, "compact", "height_gap",             "4"))
    WPMWidgetConst.H_UNIT           := Integer(IniCacheGet(wpm_c, "compact", "height_unit",            "20"))
    WPMWidgetConst.NUMBER_FONT_SIZE := Integer(IniCacheGet(wpm_c, "compact", "number_font_size",       "20"))
    WPMWidgetConst.UNIT_FONT_SIZE   := Integer(IniCacheGet(wpm_c, "compact", "unit_font_size",         "8"))
    WPMWidgetConst.UNIT_DARKEN      := Float(IniCacheGet(wpm_c, "compact",   "unit_strip_darken_factor","0.40"))

    ; [colors]  — strip leading '#' for AHK Gui compatibility
    _strip := (s) => (SubStr(s, 1, 1) = "#") ? SubStr(s, 2) : s
    WPMWidgetConst.COLOR_BG_MANUAL  := _strip(IniCacheGet(wpm_c, "colors", "bg_manual",   "#0055cc"))
    WPMWidgetConst.COLOR_BG_AI      := _strip(IniCacheGet(wpm_c, "colors", "bg_ai",       "#7a30b0"))
    WPMWidgetConst.COLOR_BG_IDLE    := _strip(IniCacheGet(wpm_c, "colors", "bg_idle",     "#1a1a2e"))
    WPMWidgetConst.COLOR_TXT_ACTIVE := _strip(IniCacheGet(wpm_c, "colors", "text_active", "#ffffff"))
    WPMWidgetConst.COLOR_TXT_IDLE   := _strip(IniCacheGet(wpm_c, "colors", "text_idle",   "#555577"))

    ; [colors] — HSL normalisation target (same brightness as bg_manual)
    WPMWidgetConst.COLOR_WIDGET_L := Float(IniCacheGet(wpm_c, "colors", "widget_hsl_l", "0.40"))
    WPMWidgetConst.COLOR_WIDGET_S := Float(IniCacheGet(wpm_c, "colors", "widget_hsl_s", "1.00"))

    ; [transparency]
    WPMWidgetConst.ALPHA_ACTIVE := Integer(IniCacheGet(wpm_c, "transparency", "alpha_active", "220"))
    WPMWidgetConst.ALPHA_IDLE   := Integer(IniCacheGet(wpm_c, "transparency", "alpha_idle",   "140"))

    ; shared/timings/constants.toml
    tim_c := ParseTomlFile(timings_path)
    if tim_c.Count
        WPMWidgetConst.IDLE_HIDE_MS := Integer(IniCacheGet(tim_c, "", "wpm_widget_idle_hide_ms", "3000"))
    else
        LoggerError("WPMWidget", "shared/timings/constants.toml not found — IDLE_HIDE_MS defaulting to 3000.")

    LoggerDone("WPMWidget", "Shared constants loaded (W=%d H=%d darken=%.2f idle=%dms).",
        WPMWidgetConst.W, WPMWidgetConst.H, WPMWidgetConst.UNIT_DARKEN, WPMWidgetConst.IDLE_HIDE_MS)
}


; Called once at startup to restore position and visibility from config.
WPMWidget_LoadConfig(Cache) {
    WPMWidget_LoadSharedConst()
    raw_vis    := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_VISIBLE)
    raw_x      := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_X)
    raw_y      := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_Y)
    raw_colors := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_COLORS)
    raw_graph  := IniCacheGet(Cache, "ahk.metrics", WPMWidgetConst.CFG_GRAPH)

    if (raw_x != "_" && raw_x != "" && IsInteger(raw_x)) {
        MonitorGetWorkArea(, , , , &wb_check)
        saved_y := Integer(raw_y)
        ; Discard saved position if it places the widget below the work area —
        ; this catches stale coordinates from older versions that used a different anchor.
        if (saved_y + WPMWidgetConst.H <= wb_check) {
            WPMWidget.pos_x := Integer(raw_x)
            WPMWidget.pos_y := saved_y
        }
    }
    if (raw_colors = "1" || raw_colors = true)
        WPMWidget.use_colors := true
    if (raw_graph = "1" || raw_graph = true)
        WPMWidget.show_graph := true

    if (raw_vis = "1" || raw_vis = true)
        WPMWidget.visible := true
    LoggerDone("WPMWidget", "Config loaded — raw_vis=[%s] visible=%s, x=%d, y=%d, colors=%s, graph=%s.",
        raw_vis, WPMWidget.visible, WPMWidget.pos_x, WPMWidget.pos_y,
        WPMWidget.use_colors, WPMWidget.show_graph)
}

WPMWidget_SaveVisible() {
    global ConfigurationFile
    val := WPMWidget.visible ? "1" : "0"
    try TOML_BatchWrite(ConfigurationFile,
        [{ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: val }])
}

WPMWidget_SavePosition() {
    global ConfigurationFile
    try TOML_BatchWrite(ConfigurationFile, [
        { Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X, Value: String(WPMWidget.pos_x) },
        { Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y, Value: String(WPMWidget.pos_y) },
    ])
}

; Resets the widget to its default bottom-right position and saves it to config.
WPMWidget_ResetPosition() {
    WPMWidget_DefaultPos(&def_x, &def_y)
    WPMWidget.pos_x := def_x
    WPMWidget.pos_y := def_y
    WPMWidget_SavePosition()
    if WPMWidget.visible {
        WPMWidget_ShowPos(&show_x, &show_y)
        gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
        if gui_ref
            try gui_ref.Move(show_x, show_y)
    }
}

WPMWidget_SaveConfig() {
    global ConfigurationFile
    try TOML_BatchWrite(ConfigurationFile, [
        { Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS, Value: WPMWidget.use_colors ? "1" : "0" },
        { Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,  Value: WPMWidget.show_graph  ? "1" : "0" },
    ])
}
