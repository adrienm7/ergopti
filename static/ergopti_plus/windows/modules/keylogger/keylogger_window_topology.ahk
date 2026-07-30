; modules/keylogger/keylogger_window_topology.ahk

; ==============================================================================
; MODULE: Keylogger Window Topology
; DESCRIPTION:
; Tracks window position, size, and state transitions of the active window
; and emits discrete events (window_resize, window_move, window_state_change)
; into the keylogger pipeline. Complements the existing app_switch /
; window_switch events which only fire on focus changes.
;
; FEATURES & RATIONALE:
; 1. Window move — emitted when the active window's screen position shifts
;    by more than MOVE_THRESHOLD_PX between two poll ticks without a size
;    change. This surfaces deliberate window rearrangements vs. snapping.
; 2. Window resize — emitted when width or height changes by more than
;    RESIZE_THRESHOLD_PX. Records old and new dimensions so the dashboard
;    can build a size distribution and flag « very small coding window »
;    patterns.
; 3. Window state change — emitted when the window transitions between
;    normal / maximized / minimized / snapped. Snapped is inferred when
;    the window width is exactly half the monitor width (±2 px).
; 4. Virtual desktop switch — Win10/11 virtual desktops are not exposed
;    via a public WinAPI without COM automation. We use a heuristic:
;    when the active window hwnd changes to a hwnd we have not seen as
;    foreground before within the current poll window, AND the previous
;    foreground hwnd is still alive (just invisible), we tag it as a
;    probable virtual_desktop_switch. This produces false positives on
;    Alt+Tab but is better than nothing for the desktop-switch KPI.
; 5. Monitor focus — emitted when the active window moves to a different
;    monitor (multi-monitor setups). Uses MonitorGetWorkArea to identify
;    which monitor the window's centroid falls in.
;
; IMPLEMENTATION NOTES:
; All detection is polling-based at TOPO_TICK_MS (1500 ms). This gives
; low-latency event detection with near-zero CPU (one WinGetPos call per tick).
; Events are debounced: a transition must be stable for two consecutive
; ticks before being logged (prevents spurious events during drag).
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLTopoConst {
    ; Poll interval (ms). 1500 ms still captures window move/resize events for
    ; metrics while cutting background polling 3x — window geometry is coarse,
    ; so the lower cadence is imperceptible in the recorded data and lightens
    ; the periodic foreground-window probing on the shared AHK thread.
    static TOPO_TICK_MS      := 1500

    ; Minimum position shift (px) to classify as a move rather than jitter.
    static MOVE_THRESHOLD_PX  := 10

    ; Minimum size change (px) to classify as a resize.
    static RESIZE_THRESHOLD_PX := 8

    ; Snap detection: window is considered snapped when its width is within
    ; this tolerance of exactly half the monitor work-area width.
    static SNAP_TOLERANCE_PX   := 4

    ; Debounce ticks — a change must persist this many consecutive ticks
    ; before we log it.
    static DEBOUNCE_TICKS      := 2

    ; Virtual-desktop heuristic: minimum gap (ms) since the INCOMING window was
    ; last seen as foreground before we call the focus change a probable desktop
    ; switch rather than a fast Alt+Tab. Alt+Tab brings a window back almost
    ; immediately, so a long unseen gap is the discriminator.
    static DESKTOP_SWITCH_MIN_GAP_MS := 3000

    ; Maximum number of entries to keep in KLTopo.seen_hwnds. Window handles
    ; are recycled by the OS but in a long session many unique values accumulate.
    ; When the map reaches this cap it is cleared so memory stays bounded.
    static SEEN_HWNDS_CAP := 512
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLTopo {
    ; Last observed window snapshot
    static hwnd         := 0
    static x            := -99999
    static y            := -99999
    static w            := 0
    static h            := 0
    static state        := ""    ; "normal" | "maximized" | "minimized" | "snapped"
    static monitor_idx  := 0

    ; Pending change accumulator (debounce)
    static pending_type := ""
    static pending_data := unset
    static pending_ticks := 0

    ; Virtual desktop heuristic
    static seen_hwnds   := Map()    ; hwnd → last-seen tick
    static prev_hwnd    := 0

    ; Lifecycle
    static tick_fn      := unset
}





; ============================
; ============================
; ======= 3/ Poll tick =======
; ============================
; ============================

KL_Topo_Tick() {
    if !Keylogger.initialized
        return
    if A_IsSuspended
        return
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return

    hwnd := 0
    try hwnd := WinExist("A")
    if (hwnd = 0)
        return

    ; Bound seen_hwnds to SEEN_HWNDS_CAP entries — flush when full so memory
    ; growth stays O(1). Clear before reading so the virtual desktop check below
    ; treats this tick as a cold-start (incoming_last_seen = 0) on cap events.
    if (KLTopo.seen_hwnds.Count >= KLTopoConst.SEEN_HWNDS_CAP)
        KLTopo.seen_hwnds.Clear()

    ; Virtual desktop heuristic — new foreground hwnd that we've seen
    ; recently but not as foreground for > DESKTOP_SWITCH_MIN_GAP_MS (Alt+Tab
    ; brings it back immediately; a desktop switch takes longer). The reference
    ; windows must be captured BEFORE seen_hwnds/prev_hwnd are overwritten:
    ; the alive-check is on the OUTGOING window (prev_hwnd) and the gap is on
    ; the INCOMING window (hwnd). Reading them after the writes below would mix
    ; stale and fresh state and worsen the documented Alt+Tab false positives.
    if (hwnd != KLTopo.prev_hwnd and KLTopo.prev_hwnd != 0) {
        incoming_last_seen := KLTopo.seen_hwnds.Has(hwnd) ? KLTopo.seen_hwnds[hwnd] : 0
        KL_Topo_CheckVirtualDesktop(KLTopo.prev_hwnd, incoming_last_seen)
    }
    KLTopo.prev_hwnd := hwnd
    KLTopo.seen_hwnds[hwnd] := A_TickCount

    ; Get current geometry. WinGetPos with output parameters leaves them
    ; UNSET when the call throws (e.g. window vanished between WinExist and
    ; WinGetPos), so the post-call ``cw = 0`` test must be guarded too —
    ; otherwise reading cw raises "local variable not assigned" and the
    ; whole tick aborts up the call stack.
    cx := 0, cy := 0, cw := 0, ch := 0
    ok := false
    try {
        WinGetPos(&cx, &cy, &cw, &ch, "ahk_id " . hwnd)
        ok := true
    }
    if (!ok or !IsSet(cw) or cw = 0)
        return

    ; Determine window state
    minMax := 0
    try minMax := WinGetMinMax("ahk_id " . hwnd)
    cur_state := "normal"
    if (minMax = 1)
        cur_state := "maximized"
    else if (minMax = -1)
        cur_state := "minimized"
    else {
        ; Snap detection
        mon_w := KL_Topo_MonitorWidth(cx + cw // 2, cy + ch // 2)
        if (mon_w > 0 and Abs(cw - mon_w // 2) <= KLTopoConst.SNAP_TOLERANCE_PX)
            cur_state := "snapped"
    }

    ; Monitor index
    cur_mon := KL_Topo_MonitorIdx(cx + cw // 2, cy + ch // 2)

    app := Keylogger.session_app

    ; Compare with last snapshot
    if (KLTopo.w = 0) {
        ; First observation — seed without emitting
        KLTopo.x := cx, KLTopo.y := cy, KLTopo.w := cw, KLTopo.h := ch
        KLTopo.state := cur_state, KLTopo.monitor_idx := cur_mon
        KLTopo.hwnd := hwnd
        return
    }

    change_type := ""
    change_data := Map("app", app)

    if (cur_state != KLTopo.state) {
        change_type := "window_state_change"
        change_data["from_state"] := KLTopo.state
        change_data["to_state"]   := cur_state
        change_data["x"] := cx, change_data["y"] := cy
        change_data["w"] := cw, change_data["h"] := ch
    } else if (Abs(cw - KLTopo.w) > KLTopoConst.RESIZE_THRESHOLD_PX
                or Abs(ch - KLTopo.h) > KLTopoConst.RESIZE_THRESHOLD_PX) {
        change_type := "window_resize"
        change_data["old_w"] := KLTopo.w, change_data["old_h"] := KLTopo.h
        change_data["new_w"] := cw,       change_data["new_h"] := ch
    } else if (Abs(cx - KLTopo.x) > KLTopoConst.MOVE_THRESHOLD_PX
                or Abs(cy - KLTopo.y) > KLTopoConst.MOVE_THRESHOLD_PX) {
        change_type := "window_move"
        change_data["from_x"] := KLTopo.x, change_data["from_y"] := KLTopo.y
        change_data["to_x"]   := cx,       change_data["to_y"]   := cy
    } else if (cur_mon != KLTopo.monitor_idx and cur_mon > 0) {
        change_type := "monitor_focus_change"
        change_data["from_monitor"] := KLTopo.monitor_idx
        change_data["to_monitor"]   := cur_mon
    }

    if (change_type = "") {
        KLTopo.pending_ticks := 0
        ; Always sync snapshot on no-change tick
        KLTopo.x := cx, KLTopo.y := cy, KLTopo.w := cw, KLTopo.h := ch
        KLTopo.state := cur_state, KLTopo.monitor_idx := cur_mon
        return
    }

    ; Debounce — require DEBOUNCE_TICKS consecutive ticks with same change_type
    if (change_type = KLTopo.pending_type) {
        KLTopo.pending_ticks += 1
        KLTopo.pending_data  := change_data   ; keep the most recent geometry, not the overshoot
    } else {
        KLTopo.pending_type  := change_type
        KLTopo.pending_data  := change_data
        KLTopo.pending_ticks := 1
    }

    if (KLTopo.pending_ticks >= KLTopoConst.DEBOUNCE_TICKS) {
        ; KL_Topo_LogEvent sets the "type" key itself — the inline assignment and
        ; direct KL_AppendLog were redundant, causing every topology event to be
        ; written twice to today.log and data.sql (double-counting all metrics).
        KL_Topo_LogEvent(change_type, KLTopo.pending_data)
        KLTopo.pending_ticks := 0
        KLTopo.pending_type  := ""
        ; Update snapshot after logging
        KLTopo.x := cx, KLTopo.y := cy, KLTopo.w := cw, KLTopo.h := ch
        KLTopo.state := cur_state, KLTopo.monitor_idx := cur_mon
    }
}

KL_Topo_LogEvent(kind, data) {
    e := Map("type", kind)
    for k, v in data
        e[k] := v
    KL_AppendLog(e)
}

; Emits a virtual_desktop_switch event when the focus change looks like a
; desktop switch rather than a fast Alt+Tab. The alive-check is on the OUTGOING
; window (outgoing_hwnd) and the gap is computed on the INCOMING window via
; incoming_last_seen, both captured by the caller before module state is mutated.
KL_Topo_CheckVirtualDesktop(outgoing_hwnd, incoming_last_seen) {
    ; If the previous (outgoing) hwnd is still alive (not destroyed) but we
    ; switched to a different one, it may be a virtual desktop switch.
    try {
        prev_alive := WinExist("ahk_id " . outgoing_hwnd) != 0
        if KL_Topo_IsLikelyDesktopSwitch(prev_alive, incoming_last_seen, A_TickCount) {
            KL_AppendLog(Map(
                "type", "virtual_desktop_switch",
                "app",  Keylogger.session_app
            ))
        }
    }
}

; Pure decision for the virtual-desktop heuristic — no OS calls, no shared
; state, so it is unit-testable in isolation. Returns true only when the
; OUTGOING window is still alive AND the INCOMING window was either never seen
; or last seen longer than DESKTOP_SWITCH_MIN_GAP_MS ago. A recent re-visit
; (small gap) is treated as a plain Alt+Tab and returns false.
KL_Topo_IsLikelyDesktopSwitch(prev_alive, incoming_last_seen, now) {
    if !prev_alive
        return false
    if (incoming_last_seen = 0)
        return true
    return (now - incoming_last_seen) > KLTopoConst.DESKTOP_SWITCH_MIN_GAP_MS
}





; ==================================
; ==================================
; ======= 4/ Monitor helpers =======
; ==================================
; ==================================

KL_Topo_MonitorWidth(cx, cy) {
    n := MonitorGetCount()
    loop n {
        try {
            MonitorGetWorkArea(A_Index, &ml, &mt, &mr, &mb)
            if (cx >= ml and cx < mr and cy >= mt and cy < mb)
                return mr - ml
        }
    }
    return 0
}

KL_Topo_MonitorIdx(cx, cy) {
    n := MonitorGetCount()
    loop n {
        try {
            MonitorGetWorkArea(A_Index, &ml, &mt, &mr, &mb)
            if (cx >= ml and cx < mr and cy >= mt and cy < mb)
                return A_Index
        }
    }
    return 1
}





; ============================
; ============================
; ======= 5/ Lifecycle =======
; ============================
; ============================

KL_Topo_Start() {
    if KLTopo.HasOwnProp("tick_fn") && IsObject(KLTopo.tick_fn)
        return
    KLTopo.tick_fn := KL_Topo_Tick.Bind()
    SetTimer(KLTopo.tick_fn, KLTopoConst.TOPO_TICK_MS)
}

KL_Topo_Stop() {
    if KLTopo.HasOwnProp("tick_fn") && IsObject(KLTopo.tick_fn) {
        try SetTimer(KLTopo.tick_fn, 0)
        KLTopo.tick_fn := unset
    }
    ; Free the hwnd history — it is only meaningful while the tracker is
    ; running and would otherwise accumulate across Stop/Start cycles.
    KLTopo.seen_hwnds.Clear()
    KLTopo.prev_hwnd := 0
}
