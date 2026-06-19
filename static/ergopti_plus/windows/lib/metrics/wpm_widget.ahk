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
;      - Graph: sparkline of recent history rendered natively with GDI+ into a
;        per-pixel-alpha layered window (no WebView2 — no browser cold-start).
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
    ; How long the hotstring source color stays visible after the last fire.
    ; Loaded from shared/timings/constants.toml [ui] wpm_color_hold_ms.
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
    Critical("On")
    if (WPMWidget._ring.Length < cap)
        WPMWidget._ring.Push(entry)
    else
        WPMWidget._ring[head + 1] := entry
    WPMWidget._ring_head := Mod(head + 1, cap)
    Critical("Off")
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
    Critical("On")
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
    Critical("Off")
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
    FilePath := _SharedDir . "\hotstrings\" . StrLower(CategoryName) . ".toml"
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

    WPMWidget._graph_gui := g
}


; Starts GDI+ once and creates the reusable font + centered string format. Held
; for the process lifetime — the graph re-renders every tick, so the per-call
; startup/shutdown the spotlight overlay uses would be pure waste here. Returns
; true when GDI+ is ready to draw.
WPMWidget_EnsureGdip() {
    if WPMWidget._gdip_started
        return true
    DllCall("LoadLibrary", "str", "gdiplus")
    si := Buffer(24, 0)
    NumPut("uint", 1, si)
    if DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0) {
        LoggerError("WPMWidget", "GdiplusStartup failed — graph mode unavailable.")
        return false
    }
    WPMWidget._gdip_token := token

    ; Font is in logical pixels (UnitPixel = 2); the per-render world transform
    ; scales it to the right physical size on any DPI. GRAPH_LABEL_PX mirrors the
    ; old WebView2 canvas (TS = 15). Fall back to Arial if Segoe UI is absent.
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Segoe UI", "ptr", 0, "ptr*", &family := 0)
    if !family
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Arial", "ptr", 0, "ptr*", &family := 0)
    WPMWidget._gdip_family := family
    DllCall("gdiplus\GdipCreateFont", "ptr", family,
        "float", WPMWidgetConst.GRAPH_LABEL_PX, "int", 0, "int", 2, "ptr*", &font := 0)
    WPMWidget._gdip_font := font

    ; Centered string format (horizontal + vertical), so the label sits in the
    ; middle of the top zone exactly like the old canvas textAlign/textBaseline.
    DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt := 0)
    DllCall("gdiplus\GdipSetStringFormatAlign",     "ptr", fmt, "int", 1)   ; StringAlignmentCenter
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", 1)
    WPMWidget._gdip_fmt := fmt

    WPMWidget._gdip_started := true
    return true
}


; Renders the WPM graph into the layered graph window with GDI+ — the native
; replacement for the WebView2 canvas (no ~3-5 s browser cold-start, no per-key
; contention). Delegates the DIB + UpdateLayeredWindow lifecycle to the
; GraphicsRenderer adapter (the same path lib/spotlight.ahk uses); GR_DrawBitmap
; positions the bitmap at the window's current rect, so a drag never causes a jump.
WPMWidget_RenderGraph(Label, AccentHex) {
    g := WPMWidget._graph_gui
    if (!g or !WPMWidget_EnsureGdip())
        return
    ; Snapshot the history so a concurrent WPMWidget_Push can't mutate it mid-draw.
    Hist := WPMWidget._graph_hist.Clone()
    ; The Gui is -DPIScale (physical pixels); render in logical coords scaled by
    ; the DPI factor so the layout matches the old DPI-scaled WebView2 canvas.
    dpi := DllCall("GetDpiForWindow", "ptr", g.Hwnd, "uint")
    if (dpi < 72)
        dpi := 96
    Scale := dpi / 96.0

    DrawFn(MemDC, W, H) {
        DllCall("gdiplus\GdipCreateFromHDC", "ptr", MemDC, "ptr*", &pGfx := 0)
        if !pGfx
            return
        DllCall("gdiplus\GdipSetSmoothingMode",     "ptr", pGfx, "int", 4)   ; AntiAlias
        DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", pGfx, "int", 4)   ; AntiAliasGridFit (sets alpha)
        if (Scale != 1.0)
            DllCall("gdiplus\GdipScaleWorldTransform", "ptr", pGfx, "float", Scale, "float", Scale, "int", 0)
        WPMWidget_DrawGraph(pGfx, W / Scale, H / Scale, Label, AccentHex, Hist)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGfx)
    }
    GR_DrawBitmap(g.Hwnd, DrawFn)
}


; Paints the graph into a GDI+ context in LOGICAL coordinates (W x H): a rounded
; dark pill, a filled + stroked WPM sparkline clipped to the pill, and a centered
; WPM label. Mirrors the old canvas geometry 1:1 (PAD/LH/GH/GW/R/scale).
WPMWidget_DrawGraph(pGfx, W, H, Label, AccentHex, Hist) {
    static PAD := 5, CORNER_R := 8
    static PILL_FILL   := 0xCC000000   ; rgba(0,0,0,0.8)
    static PILL_STROKE := 0x66FFFFFF   ; rgba(255,255,255,0.4)
    static LABEL_COLOR := 0xFFFFFFFF
    static FILL_ALPHA  := 0x33         ; 0.2 x 255 — sparkline fill area
    LH := WPMWidgetConst.GRAPH_LABEL_PX * 2
    GH := H - LH - PAD * 2
    GW := W - PAD * 2

    ; Rounded-rect pill path — reused for fill, stroke and the sparkline clip.
    pPath := WPMWidget_MakeRoundRectPath(0, 0, W, H, CORNER_R)
    DllCall("gdiplus\GdipCreateSolidFill", "uint", PILL_FILL, "ptr*", &bgBrush := 0)
    DllCall("gdiplus\GdipFillPath", "ptr", pGfx, "ptr", bgBrush, "ptr", pPath)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", bgBrush)
    DllCall("gdiplus\GdipCreatePen1", "uint", PILL_STROKE, "float", 1, "int", 2, "ptr*", &bgPen := 0)
    DllCall("gdiplus\GdipDrawPath", "ptr", pGfx, "ptr", bgPen, "ptr", pPath)
    DllCall("gdiplus\GdipDeletePen", "ptr", bgPen)

    N := Hist.Length
    if (N >= 2) {
        DllCall("gdiplus\GdipSetClipPath", "ptr", pGfx, "ptr", pPath, "int", 0)   ; CombineModeReplace
        ScaleMax := WPMWidgetConst.GRAPH_SCALE_MAX
        Step  := GW / (N - 1)
        BaseY := LH + PAD + GH
        Rgb   := WPMWidget_HexToRgbInt(AccentHex)

        ; Filled area under the line: N points + two baseline corners to close it.
        ptsFill := Buffer((N + 2) * 8)
        Loop N {
            i := A_Index - 1
            NumPut("float", PAD + i * Step, ptsFill, i * 8)
            NumPut("float", BaseY - (Hist[A_Index] / ScaleMax) * GH, ptsFill, i * 8 + 4)
        }
        NumPut("float", PAD + (N - 1) * Step, ptsFill, N * 8),       NumPut("float", BaseY, ptsFill, N * 8 + 4)
        NumPut("float", PAD,                  ptsFill, (N + 1) * 8), NumPut("float", BaseY, ptsFill, (N + 1) * 8 + 4)
        DllCall("gdiplus\GdipCreateSolidFill", "uint", (FILL_ALPHA << 24) | Rgb, "ptr*", &fillBrush := 0)
        DllCall("gdiplus\GdipFillPolygon", "ptr", pGfx, "ptr", fillBrush, "ptr", ptsFill, "int", N + 2, "int", 0)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", fillBrush)

        ; Stroked line over the fill.
        ptsLine := Buffer(N * 8)
        Loop N {
            i := A_Index - 1
            NumPut("float", PAD + i * Step, ptsLine, i * 8)
            NumPut("float", BaseY - (Hist[A_Index] / ScaleMax) * GH, ptsLine, i * 8 + 4)
        }
        DllCall("gdiplus\GdipCreatePen1", "uint", 0xFF000000 | Rgb, "float", 2, "int", 2, "ptr*", &linePen := 0)
        DllCall("gdiplus\GdipDrawLines", "ptr", pGfx, "ptr", linePen, "ptr", ptsLine, "int", N)
        DllCall("gdiplus\GdipDeletePen", "ptr", linePen)
        DllCall("gdiplus\GdipResetClip", "ptr", pGfx)
    }

    ; WPM label, centered in the top zone.
    DllCall("gdiplus\GdipCreateSolidFill", "uint", LABEL_COLOR, "ptr*", &txtBrush := 0)
    rect := Buffer(16)
    NumPut("float", 0, rect, 0), NumPut("float", 0, rect, 4)
    NumPut("float", W, rect, 8), NumPut("float", LH, rect, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", pGfx, "wstr", Label, "int", -1,
        "ptr", WPMWidget._gdip_font, "ptr", rect, "ptr", WPMWidget._gdip_fmt, "ptr", txtBrush)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", txtBrush)

    DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
}


; Builds a rounded-rectangle GraphicsPath (four 90-degree corner arcs). Caller
; owns the returned path and must GdipDeletePath it.
WPMWidget_MakeRoundRectPath(X, Y, W, H, R) {
    d := R * 2
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &path := 0)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X,         "float", Y,         "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X + W - d, "float", Y,         "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X + W - d, "float", Y + H - d, "float", d, "float", d, "float", 0,   "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X,         "float", Y + H - d, "float", d, "float", d, "float", 90,  "float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "ptr", path)
    return path
}


; Parses a 6-hex color string ("#rrggbb" or "rrggbb") into a 0xRRGGBB integer for
; GDI+ ARGB construction. Falls back to the manual blue accent on bad input.
WPMWidget_HexToRgbInt(Hex) {
    H := Trim(Hex)
    if (SubStr(H, 1, 1) == "#")
        H := SubStr(H, 2)
    if !RegExMatch(H, "^[0-9A-Fa-f]{6}$")
        H := "4499FF"
    return (Integer("0x" . SubStr(H, 1, 2)) << 16)
        | (Integer("0x" . SubStr(H, 3, 2)) << 8)
        | Integer("0x" . SubStr(H, 5, 2))
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

; Pre-create the graph window + warm GDI+ during a quiet boot slot (armed earlier
; than WPMWidget_Show), so the one-time DWM window-allocation and GdiplusStartup
; cost is paid OFF the typing path. Previously that cost was absorbed by the first
; tooltip render after the widget appeared, surfacing as a ~110 ms Tooltip.Present
; blip (message-pump reentrancy while DWM composited the brand-new window). One
; hidden render forces the layered surface allocation; the window stays hidden, so
; the normal tick still reveals it only once the user actually types.
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
        ; Allocate the HWND + size WHILE HIDDEN, start GDI+, then run one hidden
        ; render so UpdateLayeredWindow creates the layered surface now, not on the
        ; first reveal. Leave it hidden — the tick reveals it when typing starts.
        g.Show("Hide NoActivate x" . show_x . " y" . show_y
            . " w" . WPMWidgetConst.GRAPH_W . " h" . WPMWidgetConst.GRAPH_H)
        WPMWidget_EnsureGdip()
        WPMWidget_RenderGraph("0 " . t("menu.metrics.wpm_unit"), WPMWidgetConst.COLOR_GRAPH_MANUAL)
        LoggerDone("WPMWidget", "Graph window pre-warmed off the typing path.")
    } catch as e {
        LoggerError("WPMWidget", "Graph pre-warm failed: {1}", e.Message)
    }
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
    MouseGetPos(&mx, &my)
    if (mx == WPMWidget._last_mouse_x and my == WPMWidget._last_mouse_y)
        return
    WPMWidget._last_mouse_x := mx
    WPMWidget._last_mouse_y := my
    gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
    if gui_ref
        try _WPMWidget_HideSurface(gui_ref)
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
    if tim_c.Count {
        WPMWidgetConst.IDLE_HIDE_MS  := Integer(IniCacheGet(tim_c, "ui", "wpm_widget_idle_hide_ms", "3000"))
        WPMWidgetConst.COLOR_HOLD_MS := Integer(IniCacheGet(tim_c, "ui", "wpm_color_hold_ms",       "1000"))
    } else {
        LoggerError("WPMWidget", "shared/timings/constants.toml not found — IDLE_HIDE_MS and COLOR_HOLD_MS defaulting.")
        WPMWidgetConst.IDLE_HIDE_MS  := 3000
        WPMWidgetConst.COLOR_HOLD_MS := 1000
    }

    LoggerDone("WPMWidget", "Shared constants loaded (W={1} H={2} darken={3} idle={4}ms color_hold={5}ms).",
        WPMWidgetConst.W, WPMWidgetConst.H, WPMWidgetConst.UNIT_DARKEN, WPMWidgetConst.IDLE_HIDE_MS, WPMWidgetConst.COLOR_HOLD_MS)
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
    LoggerDone("WPMWidget", "Config loaded — raw_vis=[{1}] visible={2}, x={3}, y={4}, colors={5}, graph={6}.",
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
