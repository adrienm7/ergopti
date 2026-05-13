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
;      - manual keystrokes  → neutral (dark grey text on semi-transparent bg)
;      - hotstring expanded → orange tint (immediate visual feedback)
;      - IA suggestion (future) → purple tint
;    Colors match the HS bubble color scheme for consistency.
; 3. Draggable: click-drag moves the widget anywhere on screen; position
;    is saved to config and restored on next launch.
; 4. Zero-impact when hidden: the SetTimer tick is cancelled when the widget
;    is off — no overhead on the keystroke hot path.
; 5. Menu bar integration: a checkmark toggle in the metrics submenu controls
;    the widget; the state is persisted in config.toml alongside other prefs.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class WPMWidgetConst {
    ; Rolling window over which WPM is averaged.
    static WINDOW_MS        := 30000
    ; Timer tick — how often the display refreshes (ms).
    static TICK_MS          := 500
    ; Visual — widget dimensions (px).
    static W                := 110
    static H                := 44
    ; How long (ms) after the last keystroke to show the fade-to-idle state.
    static IDLE_AFTER_MS    := 4000
    ; Default screen-corner position when no saved position exists.
    static DEFAULT_X        := 20
    static DEFAULT_Y        := 60
    ; Background colors (RRGGBB, AHK control format 0xRRGGBB).
    static COLOR_BG_NORMAL  := "1e1e2e"   ; Dark neutral
    static COLOR_BG_HS      := "7c3e00"   ; Orange-brown (hotstring)
    static COLOR_BG_AI      := "3a005e"   ; Purple (IA — future)
    static COLOR_BG_IDLE    := "111118"   ; Almost black when idle
    ; Text colors.
    static COLOR_TXT_NORMAL := "e0e0f0"
    static COLOR_TXT_HS     := "ffbb66"
    static COLOR_TXT_AI     := "cc88ff"
    static COLOR_TXT_IDLE   := "444455"
    ; Transparency (0-255, 255=opaque).
    static ALPHA_ACTIVE     := 210
    static ALPHA_IDLE       := 130
    ; Config key names written to config.toml under [Script].
    static CFG_VISIBLE      := "WpmWidgetVisible"
    static CFG_X            := "WpmWidgetX"
    static CFG_Y            := "WpmWidgetY"
    ; Ring buffer capacity for recent keystrokes.
    static RING_CAP         := 2000
}




; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class WPMWidget {
    ; Gui handle — false means not yet built.
    static _gui         := false
    static _lbl_wpm     := false   ; main WPM number
    static _lbl_unit    := false   ; "MPM" label

    ; Visibility + position.
    static visible      := false
    static pos_x        := WPMWidgetConst.DEFAULT_X
    static pos_y        := WPMWidgetConst.DEFAULT_Y

    ; Ring buffer of recent keystrokes: [{t: tick_ms, hs: bool, ai: bool}, …]
    static _ring        := []
    static _ring_head   := 0      ; next write index (mod RING_CAP)

    ; Derived state refreshed by the tick.
    static _last_wpm    := 0
    static _last_tick   := 0      ; A_TickCount of last keystroke seen
    static _last_hs     := false  ; most recent keystroke was a HS expansion
    static _last_ai     := false  ; most recent keystroke was an AI suggestion

    ; Drag state.
    static _drag_start_x := 0
    static _drag_start_y := 0
    static _drag_win_x   := 0
    static _drag_win_y   := 0
}




; ============================================
; ============================================
; ======= 3/ Ring buffer helpers =======
; ============================================
; ============================================

; Called by the keylogger hook after each accepted keystroke.
; is_hs: true when the character is a hotstring synthetic output.
; is_ai: true when from an AI suggestion (future).
WPMWidget_Push(is_hs := false, is_ai := false) {
    if !WPMWidget.visible
        return
    ; Grow ring array up to capacity, then overwrite oldest slot.
    cap := WPMWidgetConst.RING_CAP
    head := WPMWidget._ring_head
    entry := Map("t", A_TickCount, "hs", is_hs, "ai", is_ai)
    if (WPMWidget._ring.Length < cap) {
        WPMWidget._ring.Push(entry)
    } else {
        WPMWidget._ring[head + 1] := entry   ; 1-based
    }
    WPMWidget._ring_head := Mod(head + 1, cap)
    WPMWidget._last_tick := A_TickCount
    WPMWidget._last_hs   := is_hs
    WPMWidget._last_ai   := is_ai
}


; Compute current WPM from the ring buffer using a trailing WINDOW_MS window.
; Returns {wpm, has_hs, has_ai} reflecting events inside the window.
WPMWidget_Calc() {
    now      := A_TickCount
    cutoff   := now - WPMWidgetConst.WINDOW_MS
    count    := 0
    has_hs   := false
    has_ai   := false
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
        if (t < earliest)
            earliest := t
        if (t > latest)
            latest := t
    }
    if (count < 2) {
        return Map("wpm", 0, "has_hs", has_hs, "has_ai", has_ai)
    }
    elapsed_ms := latest - earliest
    if (elapsed_ms < 50)
        return Map("wpm", 0, "has_hs", has_hs, "has_ai", has_ai)
    ; Standard WPM formula: characters ÷ 5 ÷ minutes.
    wpm := (count / 5) / (elapsed_ms / 60000)
    return Map("wpm", Round(wpm), "has_hs", has_hs, "has_ai", has_ai)
}




; ============================================
; ============================================
; ======= 4/ GUI construction =======
; ============================================
; ============================================

WPMWidget_Build() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale",
        "ErgoptiPlus WPM")
    g.BackColor := WPMWidgetConst.COLOR_BG_IDLE

    ; Main WPM number — large and centered.
    g.SetFont("s18 w700 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_wpm := g.AddText("x0 y4 w" . WPMWidgetConst.W . " h28 Center", "—")

    ; "MPM" unit label below.
    g.SetFont("s8 w400 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
    lbl_unit := g.AddText("x0 y30 w" . WPMWidgetConst.W . " h12 Center",
        t("menu.metrics.wpm_unit"))

    ; Make the window draggable by clicking anywhere.
    g.OnEvent("Close",   (*) => WPMWidget_Hide())
    lbl_wpm.OnEvent("Click", WPMWidget_DragStart)
    lbl_unit.OnEvent("Click", WPMWidget_DragStart)
    g.OnEvent("Size", (*) => "")   ; prevent resize

    WPMWidget._gui      := g
    WPMWidget._lbl_wpm  := lbl_wpm
    WPMWidget._lbl_unit := lbl_unit
}


; ── Drag support ──────────────────────────────────────────────────────────────

WPMWidget_DragStart(ctrl, info, *) {
    ; Record initial mouse + window position for drag computation.
    MouseGetPos(&mx, &my)
    WPMWidget._gui.GetPos(&wx, &wy)
    WPMWidget._drag_start_x := mx
    WPMWidget._drag_start_y := my
    WPMWidget._drag_win_x   := wx
    WPMWidget._drag_win_y   := wy
    ; Poll mouse movement until button released.
    SetTimer(WPMWidget_DragPoll, 16)
    KeyWait("LButton", "U")
    SetTimer(WPMWidget_DragPoll, 0)
    ; Persist final position.
    WPMWidget._gui.GetPos(&fx, &fy)
    WPMWidget.pos_x := fx
    WPMWidget.pos_y := fy
    WPMWidget_SavePosition()
}

WPMWidget_DragPoll() {
    MouseGetPos(&mx, &my)
    dx := mx - WPMWidget._drag_start_x
    dy := my - WPMWidget._drag_start_y
    WPMWidget._gui.Move(WPMWidget._drag_win_x + dx, WPMWidget._drag_win_y + dy)
}




; ============================================
; ============================================
; ======= 5/ Show / Hide =======
; ============================================
; ============================================

WPMWidget_Show() {
    if !WPMWidget._gui
        WPMWidget_Build()
    WPMWidget.visible := true
    WPMWidget._gui.Show("x" . WPMWidget.pos_x . " y" . WPMWidget.pos_y
        . " w" . WPMWidgetConst.W . " h" . WPMWidgetConst.H . " NoActivate")
    WinSetTransparent(WPMWidgetConst.ALPHA_IDLE, WPMWidget._gui)
    ; Start the refresh tick.
    SetTimer(WPMWidget_Tick, WPMWidgetConst.TICK_MS)
    try LoggerDone("WPMWidget", "Widget shown at (%d, %d).", WPMWidget.pos_x, WPMWidget.pos_y)
}

WPMWidget_Hide() {
    WPMWidget.visible := false
    SetTimer(WPMWidget_Tick, 0)
    if WPMWidget._gui {
        try WPMWidget._gui.Hide()
    }
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
; ======= 6/ Tick — refresh display =======
; ============================================
; ============================================

WPMWidget_Tick() {
    if !WPMWidget.visible
        return
    now     := A_TickCount
    idle    := (now - WPMWidget._last_tick) > WPMWidgetConst.IDLE_AFTER_MS
    result  := WPMWidget_Calc()
    wpm     := result["wpm"]
    has_hs  := result["has_hs"]
    has_ai  := result["has_ai"]

    ; Select color scheme.
    if idle || wpm = 0 {
        bg_color  := WPMWidgetConst.COLOR_BG_IDLE
        txt_color := WPMWidgetConst.COLOR_TXT_IDLE
        alpha     := WPMWidgetConst.ALPHA_IDLE
        wpm_str   := "—"
    } else if has_ai {
        bg_color  := WPMWidgetConst.COLOR_BG_AI
        txt_color := WPMWidgetConst.COLOR_TXT_AI
        alpha     := WPMWidgetConst.ALPHA_ACTIVE
        wpm_str   := String(wpm)
    } else if has_hs {
        bg_color  := WPMWidgetConst.COLOR_BG_HS
        txt_color := WPMWidgetConst.COLOR_TXT_HS
        alpha     := WPMWidgetConst.ALPHA_ACTIVE
        wpm_str   := String(wpm)
    } else {
        bg_color  := WPMWidgetConst.COLOR_BG_NORMAL
        txt_color := WPMWidgetConst.COLOR_TXT_NORMAL
        alpha     := WPMWidgetConst.ALPHA_ACTIVE
        wpm_str   := String(wpm)
    }

    ; Apply — only redraw when values changed to avoid flicker.
    if (wpm_str != WPMWidget._lbl_wpm.Value) {
        WPMWidget._lbl_wpm.Value := wpm_str
    }
    WPMWidget._gui.BackColor := bg_color
    WPMWidget._lbl_wpm.SetFont("c" . txt_color)
    WPMWidget._lbl_unit.SetFont("c" . txt_color)
    WinSetTransparent(alpha, WPMWidget._gui)
    WPMWidget._last_wpm := wpm
}




; ============================================
; ============================================
; ======= 7/ Config persistence =======
; ============================================
; ============================================

; Called once at startup to restore position and visibility from config.
WPMWidget_LoadConfig(Cache) {
    raw_vis := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_VISIBLE)
    raw_x   := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_X)
    raw_y   := IniCacheGet(Cache, "Script", WPMWidgetConst.CFG_Y)

    if (raw_x != "_" && raw_x != "" && IsInteger(raw_x))
        WPMWidget.pos_x := Integer(raw_x)
    if (raw_y != "_" && raw_y != "" && IsInteger(raw_y))
        WPMWidget.pos_y := Integer(raw_y)

    ; Auto-show if it was visible on last quit — only when metrics are on.
    if (raw_vis = "1")
        WPMWidget.visible := true
    try LoggerDone("WPMWidget", "Config loaded (visible=%s, x=%d, y=%d).",
        WPMWidget.visible, WPMWidget.pos_x, WPMWidget.pos_y)
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
