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
;      - manual keystrokes  → blue
;      - hotstring expanded → red
;      - autocorrection     → green
;      - IA suggestion      → purple
;    Colors match the Hammerspoon widget color scheme for consistency.
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
    ; Rolling window over which WPM is averaged.
    static WINDOW_MS          := 30000
    ; Timer tick — how often the display refreshes (ms).
    static TICK_MS            := 500
    ; Compact mode pill dimensions (px).
    static W                  := 80
    static H                  := 56
    ; Graph mode dimensions (wider to show history).
    static GRAPH_W            := 220
    static GRAPH_H            := 80
    ; Margin from screen edges (px).
    static EDGE_MARGIN        := 12
    ; How long (ms) after the last keystroke to show the idle state.
    static IDLE_AFTER_MS      := 4000
    ; Source background colors (RRGGBB for AHK BackColor / canvas).
    static COLOR_BG_MANUAL    := "0055cc"   ; Blue
    static COLOR_BG_HS        := "cc2200"   ; Red (hotstring)
    static COLOR_BG_AC        := "1a8a3a"   ; Green (autocorrection)
    static COLOR_BG_AI        := "7a30b0"   ; Purple (IA)
    static COLOR_BG_IDLE      := "1a1a2e"   ; Near-black when idle
    ; Text colors.
    static COLOR_TXT_ACTIVE   := "ffffff"
    static COLOR_TXT_IDLE     := "555577"
    ; Graph accent colors (same palette, slightly brighter for lines).
    static COLOR_GRAPH_MANUAL := "4499ff"
    static COLOR_GRAPH_HS     := "ff6644"
    static COLOR_GRAPH_AC     := "44dd77"
    static COLOR_GRAPH_AI     := "cc88ff"
    ; Transparency (0-255, 255=opaque).
    static ALPHA_ACTIVE       := 220
    static ALPHA_IDLE         := 140
    ; Config key names written to config.toml under [Script].
    static CFG_VISIBLE        := "WpmWidgetVisible"
    static CFG_X              := "WpmWidgetX"
    static CFG_Y              := "WpmWidgetY"
    static CFG_COLORS         := "WpmWidgetColors"
    static CFG_GRAPH          := "WpmWidgetGraph"
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

; Called by the keylogger hook after each accepted keystroke.
WPMWidget_Push(is_hs := false, is_ai := false, is_ac := false) {
    if !WPMWidget.visible
        return
    cap  := WPMWidgetConst.RING_CAP
    head := WPMWidget._ring_head
    entry := Map("t", A_TickCount, "hs", is_hs, "ai", is_ai, "ac", is_ac)
    if (WPMWidget._ring.Length < cap)
        WPMWidget._ring.Push(entry)
    else
        WPMWidget._ring[head + 1] := entry
    WPMWidget._ring_head := Mod(head + 1, cap)
    WPMWidget._last_tick := A_TickCount
    WPMWidget._last_hs   := is_hs
    WPMWidget._last_ai   := is_ai
    WPMWidget._last_ac   := is_ac
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
    elapsed_ms := latest - earliest
    if (elapsed_ms < 50)
        return Map("wpm", 0, "has_hs", has_hs, "has_ai", has_ai, "has_ac", has_ac)
    wpm := (count / 5) / (elapsed_ms / 60000)
    return Map("wpm", Round(wpm), "has_hs", has_hs, "has_ai", has_ai, "has_ac", has_ac)
}


; Resolve the background color for the current source state.
WPMWidget_ResolveBgColor(idle, has_hs, has_ai, has_ac, use_colors) {
    if idle
        return WPMWidgetConst.COLOR_BG_IDLE
    if use_colors {
        if has_ai
            return WPMWidgetConst.COLOR_BG_AI
        if has_hs
            return WPMWidgetConst.COLOR_BG_HS
        if has_ac
            return WPMWidgetConst.COLOR_BG_AC
    }
    return WPMWidgetConst.COLOR_BG_MANUAL
}


; Resolve the graph accent color hex string.
WPMWidget_ResolveGraphColor(has_hs, has_ai, has_ac, use_colors) {
    if use_colors {
        if has_ai
            return WPMWidgetConst.COLOR_GRAPH_AI
        if has_hs
            return WPMWidgetConst.COLOR_GRAPH_HS
        if has_ac
            return WPMWidgetConst.COLOR_GRAPH_AC
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
    w := WPMWidgetConst.GRAPH_W
    h := WPMWidgetConst.GRAPH_H

    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM Graph")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
    g.MarginX   := 0
    g.MarginY   := 0

    lbl := g.AddText("x0 y0 w" . w . " h" . h . " BackgroundTrans", "")
    lbl.OnEvent("Click", WPMWidget_DragStart)

    g.OnEvent("Close", (*) => WPMWidget_Hide())

    WPMWidget._graph_gui      := g
    WPMWidget._graph_wv       := false
    WPMWidget._graph_wv_ready := false

    ; Attempt to embed WebView2 for canvas rendering.
    try {
        wvc := WebView2.CreateControllerAsync(g.Hwnd).Await()
        wv  := wvc.CoreWebView2

        ; Opaque dark background matching the Gui — avoids white flash on load.
        try wvc.DefaultBackgroundColor := 0xFF1a1a2e

        wvc.Bounds := { X: 0, Y: 0, Width: w, Height: h }

        ; Set _graph_wv_ready only after the page has fully loaded so that
        ; ExecuteScriptAsync calls don't race against page initialization.
        ; Force a first render immediately so the canvas is not blank while
        ; waiting for the next tick interval.
        wv.add_NavigationCompleted(WPMWidget_OnNavCompleted)
        wv.NavigateToString(WPMWidget_GraphHtml(w, h))

        WPMWidget._graph_wv := wvc
    }

    WPMWidget._gui := g
}


WPMWidget_OnNavCompleted(_wv, _args) {
    WPMWidget._graph_wv_ready := true
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
    return "<!DOCTYPE html><html><head><meta charset='utf-8'><style>"
        . "html,body{margin:0;padding:0;background:#1a1a2e;overflow:hidden}"
        . "canvas{display:block}"
        . "</style></head><body>"
        . "<canvas id='c' width='" . w . "' height='" . h . "'></canvas>"
        . "<script>"
        . "const c=document.getElementById('c'),ctx=c.getContext('2d');"
        . "const W=c.width,H=c.height,R=10;"
        . "const PAD=6,LH=22,GH=H-LH-PAD*2,GW=W-PAD*2;"
        . "function drawBg(col){"
        . "  ctx.fillStyle=col;"
        . "  ctx.beginPath();"
        . "  ctx.roundRect(0,0,W,H,R);"
        . "  ctx.fill();"
        . "}"
        . "function drawLabel(txt,col){"
        . "  ctx.fillStyle=col;ctx.font='bold 13px Segoe UI,Arial';"
        . "  ctx.textAlign='center';ctx.textBaseline='middle';"
        . "  ctx.fillText(txt,W/2,LH/2);"
        . "}"
        . "window.updateGraph=function(data){"
        . "  const d=JSON.parse(data);"
        . "  ctx.clearRect(0,0,W,H);"
        . "  drawBg('#1a1a2e');"
        . "  const n=d.hist.length;"
        . "  if(n<2){drawLabel(d.label,'#'+d.txt);return;}"
        . "  const mx=d.scale||120,step=GW/(n-1),col='#'+d.color;"
        . "  ctx.save();"
        . "  ctx.beginPath();ctx.roundRect(0,0,W,H,R);ctx.clip();"
        . "  ctx.beginPath();"
        . "  ctx.moveTo(PAD,LH+PAD+GH);"
        . "  for(let i=0;i<n;i++)ctx.lineTo(PAD+i*step,LH+PAD+GH-(d.hist[i]/mx)*GH);"
        . "  ctx.lineTo(PAD+(n-1)*step,LH+PAD+GH);ctx.closePath();"
        . "  ctx.fillStyle=col+'44';ctx.fill();"
        . "  ctx.beginPath();"
        . "  for(let i=0;i<n;i++){"
        . "    const x=PAD+i*step,y=LH+PAD+GH-(d.hist[i]/mx)*GH;"
        . "    i===0?ctx.moveTo(x,y):ctx.lineTo(x,y);"
        . "  }"
        . "  ctx.strokeStyle=col;ctx.lineWidth=2;ctx.stroke();"
        . "  ctx.restore();"
        . "  drawLabel(d.label,'#'+d.txt);"
        . "}"
        . "drawBg('#1a1a2e');drawLabel('...',  '#555577');"
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

    gui_ref.Show("x" . WPMWidget.pos_x . " y" . WPMWidget.pos_y
        . " w" . w . " h" . h . " NoActivate")
    WinSetTransparent(WPMWidgetConst.ALPHA_ACTIVE, gui_ref)
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
    has_hs := result["has_hs"]
    has_ai := result["has_ai"]
    has_ac := result["has_ac"]

    ; Update graph history.
    WPMWidget._graph_hist.Push(wpm)
    while (WPMWidget._graph_hist.Length > WPMWidgetConst.GRAPH_HISTORY)
        WPMWidget._graph_hist.RemoveAt(1)

    is_idle  := idle || wpm = 0
    bg_color := WPMWidget_ResolveBgColor(is_idle, has_hs, has_ai, has_ac, WPMWidget.use_colors)
    alpha    := is_idle ? WPMWidgetConst.ALPHA_IDLE : WPMWidgetConst.ALPHA_ACTIVE
    wpm_str  := is_idle ? "—" : String(wpm)
    txt_col  := is_idle ? WPMWidgetConst.COLOR_TXT_IDLE : WPMWidgetConst.COLOR_TXT_ACTIVE

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

    try WPMWidget._graph_wv.CoreWebView2.ExecuteScriptAsync(
        "if(window.updateGraph)window.updateGraph(" . JSON_Escape(json) . ")")
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
