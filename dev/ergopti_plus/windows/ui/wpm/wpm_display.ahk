; ui/wpm/wpm_display.ahk

; ==============================================================================
; MODULE: WPM Widget — Display Engine
; DESCRIPTION:
; Constants, module state, ring-buffer helpers, color-resolution utilities,
; default-position helpers, and the show/hide/tick rendering loop for the
; real-time WPM widget. This file owns everything that drives what the user
; sees on screen; configuration persistence lives in wpm_config.ahk.
;
; Split from ui/wpm/init.ahk; see that file for the full module overview.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class WPMWidgetConst {
    ; ── Values loaded at runtime from _shared/modules/wpm_widget/constants.toml ──────────
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

    ; ── Values loaded from _shared/modules/timings/constants.toml ────────────────────────
    static IDLE_HIDE_MS       := 0
    ; How long the hotstring source color stays visible after the last fire.
    ; Loaded from _shared/modules/timings/constants.toml [ui] wpm_color_hold_ms.
    static COLOR_HOLD_MS      := 0

    ; ── AHK-only constants (no shared TOML equivalent needed) ───────────────────
    ; Rolling window over which WPM is averaged (matches Hammerspoon 15 s).
    static WINDOW_MS          := 15000
    ; Timer tick — how often the display refreshes (ms).
    static TICK_MS            := 500
    ; Fast cursor-movement poll (ms). The display TICK_MS is far too coarse to get
    ; the widget out of the way: it would sit over text the user is trying to read
    ; for up to half a second after they grab the mouse. This dedicated poll hides
    ; the surface within MOUSE_WATCH_MS of the slightest cursor movement. Polling
    ; MouseGetPos keeps it hook-free (no global WH_MOUSE_LL install).
    static MOUSE_WATCH_MS     := 50
    ; Delay (ms) after "ready" before the graph widget first appears. The GDI+
    ; renderer has no cold-start (unlike the former WebView2 canvas, whose
    ; msedgewebview2 processes hammered CPU/disk for ~3 s and caused per-keystroke
    ; contention during the warm-up). This delay is now just a small settle so the
    ; widget arrives a beat after boot rather than mid-startup; it could be lowered
    ; safely if desired.
    static BOOT_SHOW_DELAY_MS := 2500
    ; Delay (ms) after "ready" before the graph window is PRE-WARMED (created +
    ; first hidden render + GDI+ startup) off the typing path, so the one-time DWM
    ; window-allocation cost is not absorbed by a tooltip render when the widget
    ; first appears (it showed up as a ~110 ms Tooltip.Present blip). Lands in the
    ; quiet slot after the deferred menu build and before the emoji/symbol pass.
    static PREWARM_DELAY_MS := 900
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
    ; Graph WPM label font size, in LOGICAL pixels (the GDI+ renderer scales it by
    ; the DPI factor). Mirrors the old WebView2 canvas TS constant.
    static GRAPH_LABEL_PX     := 15
}




; Wrap-safe 32-bit TickCount delta: handles the ~49.7-day counter rollover
; that makes a naive (now - last) subtraction return a huge negative number.
_WPMWidget_TickDelta(now, last) => ((now - last + 0x100000000) & 0xFFFFFFFF)





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class WPMWidget {
    ; Compact mode GUI handles.
    static _gui           := false
    static _lbl_wpm       := false
    static _lbl_unit      := false
    static _lbl_strip     := false   ; Darker background strip behind the unit label

    ; Graph mode GUI (a layered window painted with GDI+ — no WebView2).
    static _graph_gui        := false

    ; GDI+ handles, created once and reused for every graph render. The token is
    ; held for the process lifetime (the graph re-renders every tick, so per-call
    ; startup/shutdown would be pure waste). The font is in logical pixels; the
    ; per-render world transform scales it to the correct physical size per DPI.
    static _gdip_started     := false
    static _gdip_token       := 0
    static _gdip_family      := 0
    static _gdip_font        := 0
    static _gdip_fmt         := 0

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

    ; Last observed cursor position for the fast mouse-watch hide. Seeded in
    ; WPMWidget_Show so the very first poll never fires a spurious hide.
    static _last_mouse_x  := 0
    static _last_mouse_y  := 0
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
    ; Guard the ring mutation so the WPMWidget_Calc enumeration (running on the
    ; tick timer) can never observe a half-grown array or a slot written mid-walk.
    ; The region has no Send/Sleep/blocking call, so Critical cannot starve the hook.
    RingCritical := Critical("On")
    try {
        if (WPMWidget._ring.Length < cap)
            WPMWidget._ring.Push(entry)
        else
            WPMWidget._ring[head + 1] := entry
        WPMWidget._ring_head := Mod(head + 1, cap)
    } finally {
        ; Preserve an outer injection transaction. Unconditionally switching
        ; Critical off here would let the next hook callback interleave with it.
        Critical(RingCritical)
    }
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
        ; Per-keystroke hot path — gate the arg-array build behind the cached flag
        ; so nothing is interpolated when DEBUG is off (logger.ahk convention).
        if LoggerIsDebugEnabled()
            LoggerDebug("WPMWidget", "Push hs: category='{1}' section='{2}' stored='{3}'", category, section, WPMWidget._last_hs_category)
    }
    if is_ai
        WPMWidget._last_ai_tick := now_t
    if is_ac
        WPMWidget._last_ac_tick := now_t
}


; Compute current WPM from the ring buffer.
WPMWidget_Calc() {
    now      := A_TickCount
    count    := 0
    has_hs   := false
    has_ai   := false
    has_ac   := false
    earliest := now
    latest   := 0
    ; Walk the ring under Critical so a concurrent WPMWidget_Push (keyboard thread)
    ; cannot grow the array or overwrite a slot mid-enumeration — the loop sees a
    ; consistent snapshot. No Send/Sleep/blocking call here, so the hook is safe.
    RingCritical := Critical("On")
    try {
        for _, ev in WPMWidget._ring {
            t := ev["t"]
            ; Wrap-safe age check: skip events older than the rolling window
            if (_WPMWidget_TickDelta(now, t) > WPMWidgetConst.WINDOW_MS)
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
    } finally {
        Critical(RingCritical)
    }
    if (count < 2)
        return Map("wpm", 0, "has_hs", has_hs, "has_ai", has_ai, "has_ac", has_ac)
    ; Use now as the right edge (mirrors Hammerspoon): as time passes after the
    ; last keystroke the window grows and WPM decays naturally to 0.
    ; latest - earliest would freeze the WPM at the last typed value.
    elapsed_ms := Max(_WPMWidget_TickDelta(now, earliest), WPMWidgetConst.WPM_MIN_DURATION_MS)
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

; Read the [_meta] color for a hotstring category directly from the TOML file,
; bypassing HotstringGroupConfig cache to avoid stale empty entries from early
; init calls before _SharedDir was fully resolved.
; Returns "" when the file is absent or has no color key.
; Results are memoized in a static Map keyed by CategoryName; call
; WPMWidget_InvalidateColorCache() to flush the cache after a TOML save.
_WPMWidget_ReadTomlColor(CategoryName, InvalidateCache := false) {
    static _color_cache := Map()
    if (InvalidateCache) {
        _color_cache.Clear()
        return ""
    }
    if _color_cache.Has(CategoryName)
        return _color_cache[CategoryName]
    global _SharedDir, GLOBAL_DEFAULT_COLOR
    FilePath := _SharedDir . "\modules\hotstrings\" . StrLower(CategoryName) . ".toml"
    if !FileExist(FilePath) {
        LoggerDebug("WPMWidget", "ReadTomlColor: file not found for '{1}': {2}", CategoryName, FilePath)
        _color_cache[CategoryName] := ""
        return ""
    }
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
        if InMeta and RegExMatch(Line, '^color\s*=\s*"([^"]+)"', &M) {
            c := M[1]
            LoggerDebug("WPMWidget", "ReadTomlColor: '{1}' → raw='{2}' default='{3}'", CategoryName, c, GLOBAL_DEFAULT_COLOR)
            ; Skip the global blue fallback — it means "no category color set"
            result := (c != GLOBAL_DEFAULT_COLOR) ? c : ""
            _color_cache[CategoryName] := result
            return result
        }
    }
    LoggerDebug("WPMWidget", "ReadTomlColor: no color key found for '{1}'", CategoryName)
    _color_cache[CategoryName] := ""
    return ""
}

; Invalidate the per-category color cache — call when a hotstring TOML file
; is written (e.g. from the config window) so the next tick re-reads the file.
WPMWidget_InvalidateColorCache() {
    _WPMWidget_ReadTomlColor("", true)
}

; Returns the raw compact-mode background hex for a hotstring category
; (without leading '#'). Reads the color directly from the TOML group file
; via ParseTomlGroupConfig — the same path the tooltip uses — so the widget
; always shows the exact color configured in the hotstring TOML.
; Falls back to FallbackHex if the TOML is absent or has no color.
WPMWidget_CategoryBgColor(CategoryName, FallbackHex, SectionHint := "") {
    try {
        raw := _WPMWidget_ReadTomlColor(CategoryName)
        if (raw != "") {
            result := (SubStr(raw, 1, 1) == "#") ? SubStr(raw, 2) : raw
            LoggerDebug("WPMWidget", "CategoryBgColor '{1}' → '{2}'", CategoryName, result)
            if RegExMatch(result, "^[0-9A-Fa-f]{6}$")
                return result
            ; Falls through to fallback if format is invalid
        }
        if (SectionHint != "") {
            Basecat := _WPMWidget_SectionBaseCategory(SectionHint)
            if (Basecat != "") {
                raw2 := _WPMWidget_ReadTomlColor(Basecat)
                if (raw2 != "") {
                    result2 := (SubStr(raw2, 1, 1) == "#") ? SubStr(raw2, 2) : raw2
                    LoggerDebug("WPMWidget", "CategoryBgColor '{1}' via section '{2}' → '{3}'", CategoryName, Basecat, result2)
                    if RegExMatch(result2, "^[0-9A-Fa-f]{6}$")
                        return result2
                    ; Falls through to fallback if format is invalid
                }
            }
        }
    } catch as e {
        LoggerError("WPMWidget", "CategoryBgColor failed for '{1}': {2}", CategoryName, e.Message)
    }
    LoggerDebug("WPMWidget", "CategoryBgColor '{1}' → fallback '{2}'", CategoryName, FallbackHex)
    return FallbackHex
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
        if has_hs {
            LoggerDebug("WPMWidget", "ResolveBgColor: has_hs cat='{1}'", WPMWidget._last_hs_category)
            return WPMWidget_CategoryBgColor(WPMWidget._last_hs_category, WPMWidgetConst.COLOR_BG_MANUAL, WPMWidget._last_hs_section)
        }
        if has_ac
            return WPMWidget_CategoryBgColor("autocorrection", WPMWidgetConst.COLOR_BG_MANUAL)
    }
    LoggerDebug("WPMWidget", "ResolveBgColor: no color — use_colors={1} has_hs={2} has_ai={3} has_ac={4}", use_colors, has_hs, has_ai, has_ac)
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
; ==============================
; ======= 6/ Show / Hide =======
; ==============================
; ============================================

; No-op draw callback for GR_DrawBitmap: leaves the freshly created DIB untouched.
; CreateDIBSection zero-fills its pixels, so the uploaded layered surface is FULLY
; TRANSPARENT (every ARGB = 0). This is the key to warming the graph window without
; ever flashing: see WPMWidget_PrewarmGraph.
_WPMWidget_WarmDrawTransparent(MemDC, W, H) {
    ; Intentionally draws nothing: the zero-filled DIB uploads as a fully
    ; transparent layered surface. Adding any paint here would defeat the warm
    ; (an opaque surface flashes when Show("Hide") re-applies WS_VISIBLE).
}

; Pre-create the graph window + warm GDI+ and the layered/DWM upload path during a
; quiet boot slot (armed earlier than WPMWidget_Show), so the one-time DWM
; window-allocation and GdiplusStartup cost is paid OFF the typing path. Previously
; that cost was absorbed by the first render after the widget appeared, surfacing as
; a ~110 ms blip (message-pump reentrancy while DWM composited the brand-new window).
;
; The warm MUST upload a TRANSPARENT surface, not a real "0" graph. Gui.Show("Hide")
; leaves WS_VISIBLE set on the window (verified: IsWindowVisible == 1), and a layered
; window with a non-transparent surface displays the instant WS_VISIBLE is applied.
; WPMWidget_Show calls Gui.Show("Hide") AGAIN to reposition the window, re-applying
; WS_VISIBLE — so any opaque surface left here would flash a "0" graph at the real
; position then (an earlier off-screen warm did not help: the reposition brought it
; back on-screen). A transparent surface is invisible regardless of WS_VISIBLE; the
; tick uploads the real opaque content only once the user types.
WPMWidget_PrewarmGraph() {
    if (!WPMWidget.visible or !WPMWidget.show_graph or A_IsSuspended)
        return
    if !WPMWidget._graph_gui
        WPMWidget_BuildGraph()
    g := WPMWidget._graph_gui
    if !g
        return
    if (WPMWidget.pos_x = -1 || WPMWidget.pos_y = -1) {
        WPMWidget_DefaultPos(&def_x, &def_y)
        WPMWidget.pos_x := def_x
        WPMWidget.pos_y := def_y
    }
    WPMWidget_ShowPos(&show_x, &show_y)
    try {
        ; Size the layered window, start GDI+, then upload one TRANSPARENT frame to
        ; warm the CreateDIBSection -> UpdateLayeredWindow -> DWM path. Nothing is ever
        ; visible (transparent surface), so the WS_VISIBLE that Show("Hide") sets is
        ; harmless. GR_Hide leaves it in the clean SW_HIDE resting state.
        g.Show("Hide NoActivate x" . show_x . " y" . show_y
            . " w" . WPMWidgetConst.GRAPH_W . " h" . WPMWidgetConst.GRAPH_H)
        WPMWidget_EnsureGdip()
        GR_DrawBitmap(g.Hwnd, _WPMWidget_WarmDrawTransparent)
        GR_Hide(g.Hwnd)
        LoggerDone("WPMWidget", "Graph window pre-warmed (transparent surface), off the typing path.")
    } catch as e {
        LoggerError("WPMWidget", "Graph pre-warm failed: {1}", e.Message)
    }
}


; Clears the rolling WPM state (keystroke ring, history, input/category
; timestamps). Called by WPMWidget_Show so keystrokes typed during boot/reload --
; before the widget surface is armed -- cannot trigger an immediate reveal: the
; widget must stay hidden until the user actually types after it is shown.
_WPMWidget_ResetRolling() {
    RingCritical := Critical("On")
    try {
        WPMWidget._ring := []
        WPMWidget._ring_head := 0
    } finally {
        Critical(RingCritical)
    }
    WPMWidget._graph_hist    := []
    WPMWidget._last_input_ms := 0
    WPMWidget._last_hs_tick  := 0
    WPMWidget._last_ai_tick  := 0
    WPMWidget._last_ac_tick  := 0
    WPMWidget._last_wpm      := 0
}


WPMWidget_Show() {
    LoggerStart("WPMWidget", "Showing widget (graph={1}, pos_x={2}, pos_y={3})…",
        WPMWidget.show_graph, WPMWidget.pos_x, WPMWidget.pos_y)
    if WPMWidget.show_graph {
        if !WPMWidget._graph_gui
            WPMWidget_BuildGraph()
    } else {
        if !WPMWidget._gui
            WPMWidget_BuildCompact()
    }

    WPMWidget.visible := true

    ; Start from a clean slate -- discard any keystrokes counted during boot or
    ; reload so the surface stays hidden until the user types AFTER it is shown.
    _WPMWidget_ResetRolling()

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

    ; Both modes start invisible; the tick reveals the surface once the user types.
    ; Graph mode is a layered GDI+ window: position + size it WHILE HIDDEN, then the
    ; tick paints it via UpdateLayeredWindow and reveals it (per-pixel alpha rules
    ; out WinSetTransparent here — the two layering modes are mutually exclusive).
    ; Compact mode uses the same "Hide" approach — no flash on startup.
    gui_ref.Show("Hide NoActivate x" . show_x . " y" . show_y . " w" . w . " h" . h)

    SetTimer(WPMWidget_Tick, WPMWidgetConst.TICK_MS)

    ; Seed the cursor position and arm the fast mouse-watch so the widget hides the
    ; instant the cursor moves — it must never cover text the user wants to read.
    MouseGetPos(&_seed_mx, &_seed_my)
    WPMWidget._last_mouse_x := _seed_mx
    WPMWidget._last_mouse_y := _seed_my
    SetTimer(WPMWidget_MouseWatch, WPMWidgetConst.MOUSE_WATCH_MS)

    LoggerSuccess("WPMWidget", "Widget shown at ({1}, {2}) mode={3}.",
        WPMWidget.pos_x, WPMWidget.pos_y, WPMWidget.show_graph ? "graph" : "compact")
}

WPMWidget_Hide() {
    WPMWidget.visible := false
    SetTimer(WPMWidget_Tick, 0)
    SetTimer(WPMWidget_MouseWatch, 0)
    if WPMWidget._gui
        try WPMWidget._gui.Hide()
    if WPMWidget._graph_gui
        try WPMWidget._graph_gui.Hide()
    try LoggerDone("WPMWidget", "Widget hidden.")
}

WPMWidget_Toggle() {
    TargetVisible := !WPMWidget.visible
    if !WPMWidget_SaveVisible(TargetVisible)
        return false
    if WPMWidget.visible
        WPMWidget_Hide()
    else
        WPMWidget_Show()
    return true
}





; ============================================
; =========================================
; ======= 7/ Tick — refresh display =======
; =========================================
; ============================================

WPMWidget_Tick() {
    if !WPMWidget.visible
        return

    ; While the script is paused the widget must show nothing. Hide the surface
    ; directly (not via WPMWidget_Hide, which would clear .visible and stop this
    ; timer) so it reappears on resume with no restore bookkeeping.
    if A_IsSuspended {
        gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
        if gui_ref
            try gui_ref.Hide()
        return
    }

    now    := A_TickCount
    result := WPMWidget_Calc()
    wpm    := result["wpm"]
    ; Source color active for COLOR_HOLD_MS after the last event — long enough
    ; for the 500 ms tick to always catch even very short burst expansions.
    has_hs := _WPMWidget_TickDelta(now, WPMWidget._last_hs_tick) < WPMWidgetConst.COLOR_HOLD_MS
    has_ai := _WPMWidget_TickDelta(now, WPMWidget._last_ai_tick) < WPMWidgetConst.COLOR_HOLD_MS
    has_ac := _WPMWidget_TickDelta(now, WPMWidget._last_ac_tick) < WPMWidgetConst.COLOR_HOLD_MS

    ; Update graph history.
    WPMWidget._graph_hist.Push(wpm)
    while (WPMWidget._graph_hist.Length > WPMWidgetConst.GRAPH_HISTORY)
        WPMWidget._graph_hist.RemoveAt(1)

    ; Hide after IDLE_HIDE_MS of keyboard inactivity.
    keyboard_idle := WPMWidget._last_input_ms > 0
        && _WPMWidget_TickDelta(now, WPMWidget._last_input_ms) > WPMWidgetConst.IDLE_HIDE_MS
    ; Hide immediately if the mouse/touchpad was used more recently than the last keystroke —
    ; A_TimeIdleMouse is built into AHK and requires no hook install.
    mouse_active  := A_TimeIdleMouse < A_TimeIdleKeyboard
    should_show   := !keyboard_idle && !mouse_active && ((wpm > 0) || has_hs || has_ai || has_ac)
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if !gui_ref
        return

    if !should_show {
        try _WPMWidget_HideSurface(gui_ref)
        return
    }

    is_idle := false
    wpm_str := String(wpm)
    txt_col := WPMWidgetConst.COLOR_TXT_ACTIVE

    if WPMWidget.show_graph {
        ; Paint the layered window via GDI+ WHILE still hidden, then reveal it — no
        ; flash and no browser cold-start. The catch clears a stale handle (e.g. the
        ; user closed the window) so the next tick rebuilds cleanly.
        try {
            accent := WPMWidget_ResolveGraphColor(has_hs, has_ai, has_ac, WPMWidget.use_colors)
            label  := wpm_str . " " . t("menu.metrics.wpm_unit")
            WPMWidget_RenderGraph(label, accent)
            GR_Show(WPMWidget._graph_gui.Hwnd)
        } catch {
            WPMWidget._graph_gui := false
        }
    } else {
        bg_color := WPMWidget_ResolveBgColor(is_idle, has_hs, has_ai, has_ac, WPMWidget.use_colors)
        alpha    := WPMWidgetConst.ALPHA_ACTIVE
        try {
            WPMWidget._gui.Show("NoActivate")
            WPMWidget._gui.BackColor := bg_color
            WinSetTransparent(alpha, WPMWidget._gui)
            WinRedraw(WPMWidget._gui)
            dark_bg := _WPMWidget_DarkenHex(bg_color)
            if WPMWidget._lbl_strip
                WPMWidget._lbl_strip.Opt("Background" . dark_bg)
            if WPMWidget._lbl_wpm && (wpm_str != WPMWidget._lbl_wpm.Value)
                WPMWidget._lbl_wpm.Value := wpm_str
            if WPMWidget._lbl_wpm
                WPMWidget._lbl_wpm.SetFont("c" . txt_col)
            if WPMWidget._lbl_unit
                WPMWidget._lbl_unit.SetFont("c" . txt_col)
        } catch as _e {
            try LoggerError("WPMWidget", "Compact mode tick threw — rebuilding widget: {1}.", _e.Message)
            WPMWidget._gui       := false
            WPMWidget._lbl_wpm   := false
            WPMWidget._lbl_unit  := false
            WPMWidget._lbl_strip := false
            try WPMWidget_BuildCompact()
        }
    }
    WPMWidget._last_wpm := wpm
}


; Hide the widget surface. Both modes hide outright now — the graph is a native
; GDI+ layered window with no WebView2 renderer to keep alive. Shared by the
; display tick and the fast mouse-watch so both hide identically.
_WPMWidget_HideSurface(gui_ref) {
    gui_ref.Hide()
}


; Fast cursor-movement watch — armed only while the widget is visible. Costs a
; MouseGetPos plus an integer compare every MOUSE_WATCH_MS; the moment the cursor
; moves, the surface is hidden so it never sits over text the user is reading.
; This only ever drives the HIDE transition: the 500 ms display tick's own
; mouse_active gate keeps it hidden afterwards and re-shows it once the user types
; again, so no re-show bookkeeping is needed here.
WPMWidget_MouseWatch() {
    if !WPMWidget.visible
        return

    ; SetTimer callbacks keep firing under native Suspend() (only Hotkeys/Hotstrings
    ; are disarmed), so this fast watch needs its own guard — mirrors WPMWidget_Tick.
    if A_IsSuspended
        return

    MouseGetPos(&mx, &my)
    if (mx == WPMWidget._last_mouse_x and my == WPMWidget._last_mouse_y)
        return
    WPMWidget._last_mouse_x := mx
    WPMWidget._last_mouse_y := my
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if gui_ref
        try _WPMWidget_HideSurface(gui_ref)
}
