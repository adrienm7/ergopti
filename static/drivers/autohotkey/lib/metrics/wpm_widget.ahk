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
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class WPMWidgetConst {
    ; Rolling window over which WPM is averaged (matches Hammerspoon 15 s for identical feel).
    static WINDOW_MS          := 15000
    ; Timer tick — how often the display refreshes (ms).
    static TICK_MS            := 500
    ; Compact mode pill dimensions (px).
    static W                  := 80
    static H                  := 56
    ; Graph mode dimensions (wider to show history).
    static GRAPH_W            := 220
    static GRAPH_H            := 100
    ; Margin from screen edges (px).
    static EDGE_MARGIN        := 12
    ; How long (ms) after the last keystroke to show the idle state.
    static IDLE_AFTER_MS      := 4000
    ; Compact mode background colors — resolved at runtime from TOML/override,
    ; these fallbacks apply only when no category color is configured.
    static COLOR_BG_MANUAL    := "0055cc"   ; Default blue (manual keystrokes)
    static COLOR_BG_AI        := "7a30b0"   ; Purple fallback for AI (no TOML source)
    static COLOR_BG_IDLE      := "1a1a2e"   ; Near-black when idle
    ; Graph accent line colors — raw hue, used directly as canvas stroke colors.
    static COLOR_GRAPH_MANUAL := "4499ff"   ; Default blue graph line
    static COLOR_GRAPH_AI     := "cc88ff"   ; Purple fallback for AI graph line
    ; Text colors.
    static COLOR_TXT_ACTIVE   := "ffffff"
    static COLOR_TXT_IDLE     := "555577"
    ; Transparency (0-255, 255=opaque).
    static ALPHA_ACTIVE       := 220
    static ALPHA_IDLE         := 140
    ; Config key names written to config.toml under [Script].
    static CFG_VISIBLE        := "WpmWidgetVisible"
    static CFG_X              := "WpmWidgetX"
    static CFG_Y              := "WpmWidgetY"
    static CFG_COLORS         := "WpmWidgetColors"
    static CFG_GRAPH          := "WpmWidgetGraph"
    ; Minimum window for WPM calculation — avoids inflated values from short bursts (mirrors Hammerspoon).
    static WPM_MIN_DURATION_MS := 2000
    ; Ring buffer capacity for recent keystrokes.
    static RING_CAP           := 2000
    ; Number of history ticks kept for the graph.
    static GRAPH_HISTORY      := 40
    ; Maximum WPM assumed for graph scale.
    static GRAPH_SCALE_MAX    := 120
}




; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class WPMWidget {
    ; Compact mode GUI handles.
    static _gui           := false
    static _lbl_wpm       := false
    static _lbl_unit      := false

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
}




; ============================================
; ============================================
; ======= 3/ Ring buffer helpers =======
; ============================================
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
    WPMWidget._last_tick := now_t
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


; Returns the tinted compact-mode background hex for a hotstring category
; (without leading '#'). Delegates to HotstringsResolve for the canonical color
; then passes it through _TooltipMixTintHex so the WPM pill matches the tooltip
; appearance exactly. When the primary resolution returns no color, SectionHint
; (e.g. "autocorrectionJ" from a personal hotstring) is tried as a category name
; so personal hotstrings inherit their group's color. Falls back to FallbackHex.
WPMWidget_CategoryBgColor(CategoryName, FallbackHex, SectionHint := "") {
    try {
        cfg := HotstringsResolve(CategoryName, "")
        if (cfg.Color != "")
            return _TooltipMixTintHex(cfg.Color)
        ; Section names like "autocorrectionJ" mirror standard category names
        ; (prefix before the first uppercase letter). Strip the trailing
        ; PascalCase suffix and try the base name as a category.
        if (SectionHint != "") {
            Basecat := _WPMWidget_SectionBaseCategory(SectionHint)
            if (Basecat != "") {
                cfg2 := HotstringsResolve(Basecat, "")
                if (cfg2.Color != "")
                    return _TooltipMixTintHex(cfg2.Color)
            }
        }
    }
    return FallbackHex
}

; Returns the raw accent hex for a hotstring category (without leading '#'),
; used as the graph sparkline stroke color. Falls back to FallbackHex.
WPMWidget_CategoryGraphColor(CategoryName, FallbackHex, SectionHint := "") {
    try {
        cfg := HotstringsResolve(CategoryName, "")
        raw := cfg.Color
        if (raw != "") {
            if (SubStr(raw, 1, 1) == "#")
                raw := SubStr(raw, 2)
            return raw
        }
        if (SectionHint != "") {
            Basecat := _WPMWidget_SectionBaseCategory(SectionHint)
            if (Basecat != "") {
                cfg2 := HotstringsResolve(Basecat, "")
                raw2 := cfg2.Color
                if (raw2 != "") {
                    if (SubStr(raw2, 1, 1) == "#")
                        raw2 := SubStr(raw2, 2)
                    return raw2
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

; Returns the default bottom-right position, above the Windows taskbar.
WPMWidget_DefaultPos(&out_x, &out_y) {
    ; MonitorGetWorkArea excludes the taskbar from the usable area.
    MonitorGetWorkArea(, &wl, &wt, &wr, &wb)
    w := WPMWidget.show_graph ? WPMWidgetConst.GRAPH_W : WPMWidgetConst.W
    h := WPMWidget.show_graph ? WPMWidgetConst.GRAPH_H : WPMWidgetConst.H
    out_x := wr - w - WPMWidgetConst.EDGE_MARGIN
    out_y := wb - h - WPMWidgetConst.EDGE_MARGIN
}




; ============================================
; ============================================
; ======= 5/ GUI construction =======
; ============================================
; ============================================

WPMWidget_BuildCompact() {
    w := WPMWidgetConst.W
    h := WPMWidgetConst.H

    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
    g.MarginX   := 0
    g.MarginY   := 0

    ; Large WPM number.
    g.SetFont("s20 w700 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_wpm := g.AddText("x0 y6 w" . w . " h30 Center BackgroundTrans", "—")

    ; Small unit label ("mpm" / "wpm") below.
    g.SetFont("s8 w400 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_unit := g.AddText("x0 y36 w" . w . " h14 Center BackgroundTrans",
        t("menu.metrics.wpm_unit"))

    lbl_wpm.OnEvent("Click",  WPMWidget_DragStart)
    lbl_unit.OnEvent("Click", WPMWidget_DragStart)
    g.OnEvent("Close", (*) => WPMWidget_Hide())

    WPMWidget._gui      := g
    WPMWidget._lbl_wpm  := lbl_wpm
    WPMWidget._lbl_unit := lbl_unit
}


WPMWidget_BuildGraph() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM Graph")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
    g.MarginX   := 0
    g.MarginY   := 0

    g.OnEvent("Close", (*) => WPMWidget_Hide())

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

WPMWidget_DragStart(ctrl, info, *) {
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if !gui_ref
        return
    MouseGetPos(&mx, &my)
    gui_ref.GetPos(&wx, &wy)
    WPMWidget._drag_start_x := mx
    WPMWidget._drag_start_y := my
    WPMWidget._drag_win_x   := wx
    WPMWidget._drag_win_y   := wy
    SetTimer(WPMWidget_DragPoll, 16)
    KeyWait("LButton", "U")
    SetTimer(WPMWidget_DragPoll, 0)
    gui_ref.GetPos(&fx, &fy)
    WPMWidget.pos_x := fx
    WPMWidget.pos_y := fy
    WPMWidget_SavePosition()
}

WPMWidget_DragPoll() {
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if !gui_ref
        return
    MouseGetPos(&mx, &my)
    dx := mx - WPMWidget._drag_start_x
    dy := my - WPMWidget._drag_start_y
    gui_ref.Move(WPMWidget._drag_win_x + dx, WPMWidget._drag_win_y + dy)
}




; ============================================
; ============================================
; ======= 6/ Show / Hide =======
; ============================================
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

    ; Show the window fully transparent (alpha=0) so WebView2 can attach and
    ; render without being visible to the user. Hide() suspends the WebView2
    ; renderer, making ExecuteScriptAsync a no-op — transparency avoids that.
    ; The Tick sets the real alpha when the user starts typing.
    gui_ref.Show("x" . WPMWidget.pos_x . " y" . WPMWidget.pos_y
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
; ============================================
; ======= 7/ Tick — refresh display =======
; ============================================
; ============================================

WPMWidget_Tick() {
    if !WPMWidget.visible
        return

    now    := A_TickCount
    idle   := (now - WPMWidget._last_tick) > WPMWidgetConst.IDLE_AFTER_MS
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

    ; Show only while typing — hide when idle, matching Hammerspoon behaviour.
    should_show := (wpm > 0) || has_hs || has_ai || has_ac
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if gui_ref {
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
            WPMWidget._gui.BackColor := bg_color
            WinSetTransparent(alpha, WPMWidget._gui)
            if WPMWidget._lbl_wpm && (wpm_str != WPMWidget._lbl_wpm.Value)
                WPMWidget._lbl_wpm.Value := wpm_str
            if WPMWidget._lbl_wpm
                WPMWidget._lbl_wpm.SetFont("c" . txt_col)
            if WPMWidget._lbl_unit
                WPMWidget._lbl_unit.SetFont("c" . txt_col)
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
; ============================================
; ======= 8/ Config persistence =======
; ============================================
; ============================================

; Called once at startup to restore position and visibility from config.
WPMWidget_LoadConfig(Cache) {
    raw_vis    := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_VISIBLE)
    raw_x      := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_X)
    raw_y      := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_Y)
    raw_colors := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_COLORS)
    raw_graph  := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_GRAPH)

    if (raw_x != "_" && raw_x != "" && IsInteger(raw_x))
        WPMWidget.pos_x := Integer(raw_x)
    if (raw_y != "_" && raw_y != "" && IsInteger(raw_y))
        WPMWidget.pos_y := Integer(raw_y)
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
        [{ Section: "Script", Key: WPMWidgetConst.CFG_VISIBLE, Value: val }])
}

WPMWidget_SavePosition() {
    global ConfigurationFile
    try TOML_BatchWrite(ConfigurationFile, [
        { Section: "Script", Key: WPMWidgetConst.CFG_X, Value: String(WPMWidget.pos_x) },
        { Section: "Script", Key: WPMWidgetConst.CFG_Y, Value: String(WPMWidget.pos_y) },
    ])
}

WPMWidget_SaveConfig() {
    global ConfigurationFile
    try TOML_BatchWrite(ConfigurationFile, [
        { Section: "Script", Key: WPMWidgetConst.CFG_COLORS, Value: WPMWidget.use_colors ? "1" : "0" },
        { Section: "Script", Key: WPMWidgetConst.CFG_GRAPH,  Value: WPMWidget.show_graph  ? "1" : "0" },
    ])
}
