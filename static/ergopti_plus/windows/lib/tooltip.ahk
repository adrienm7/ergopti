; drivers/autohotkey/lib/tooltip.ahk
; Requires: GraphicsRenderer

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
global _TooltipGui := 0
; Metadata per row (H, W, IsSep) kept for corner/border calculations.
global _TooltipRowGuis := []

; Generation counter incremented on every TooltipShow. The timer callback
; compares its captured generation against this value and aborts if they
; differ — prevents a stale timer from hiding a tooltip that was rebuilt
; after the timer was armed but before it fired.
global _TooltipGeneration := 0
global _TooltipTimerGeneration := 0

; Dequeue state — items that have per-row expiry deadlines. Canonical algorithm:
; shared/tooltip/dequeue.js (SPEC.md § 7.1). When rows carry distinct non-zero
; DurationSec values, TooltipShow stores the full item list here with absolute
; expiry timestamps (A_TickCount + duration_ms). The dequeue poll timer removes
; expired rows and re-renders the surviving stack so a short row disappears first
; and longer rows stay visible (e.g. output1@1s + output2@2s → both 0.8s, then
; output2 alone for another 1.0s after the 0.2s decrement).
; Shape: Array of { ..item fields.., ExpireMs: integer }
; 0 when no dequeue cycle is active (all items have DurationSec = 0).
global _TooltipDequeueItems := 0

; When true, TooltipHide() calls from external sources (prefix watcher resets,
; lookup misses, renderer) are silently ignored — the dequeue poll timer owns
; the tooltip lifecycle and will hide it at the right time. Only the poll timer
; and the safety timer (via _TooltipTimerFn) are authorised to call
; TooltipHide() during an active dequeue cycle.
global _TooltipDequeueActive := false

; Last items passed to TooltipShow, kept so that after a hotstring fires the
; timer can be re-armed for the full duration from the moment of fire rather
; than counting down from when the preview was first shown.
global _TooltipLastItems := 0

; Stable function references. A single named function per timer is mandatory
; so SetTimer can cancel it by identity — each closure literal produces a
; distinct object that SetTimer treats as a different timer.
_TooltipTimerFn() {
    global _TooltipGeneration, _TooltipTimerGeneration
    if (_TooltipTimerGeneration != _TooltipGeneration)
        return
    TooltipHide("TimerFn", true)
    ; The timer fires when the user has not typed anything new since the
    ; tooltip appeared — they have effectively abandoned the current word.
    ; Reset the prefix buffer so the next keystroke starts a fresh lookup
    ; rather than accumulating onto the stale word (which would prevent any
    ; subsequent tooltip from showing for that trigger).
    if IsSet(_ResetPrefixBuffer)
        try _ResetPrefixBuffer()
}

; Dequeue poll timer — runs every 100 ms while a dequeue cycle is active.
; Polling avoids the AHK v2 issue where one-shot timers armed from an
; InputHook OnChar thread never fire: the repeating timer is registered
; from the main script body at startup and always runs in the main thread.
_TooltipDequeuePollFn() {
    global _TooltipDequeueItems, _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipDequeueActive
    static _PollCount := 0
    _PollCount += 1
    if (_TooltipDequeueItems == 0 or !IsObject(_TooltipDequeueItems))
        return
    if (_TooltipTimerGeneration != _TooltipGeneration) {
        ; Generation mismatch while dequeue is still flagged active — a new
        ; TooltipShow superseded this cycle.  Clear the active flag so
        ; subsequent TooltipHide calls are no longer gated.
        if _TooltipDequeueActive
            _TooltipDequeueActive := false
        return
    }
    Now := A_TickCount
    ; Check if the earliest deadline has passed.
    NeedDequeue := false
    for , Item in _TooltipDequeueItems {
        if (Item.ExpireMs > 0 and Now >= Item.ExpireMs) {
            NeedDequeue := true
            break
        }
    }
    if !NeedDequeue
        return
    Remaining := []
    for , Item in _TooltipDequeueItems {
        if (Item.ExpireMs == 0 or Now < Item.ExpireMs)
            Remaining.Push(Item)
    }
    if (Remaining.Length == 0) {
        TooltipHide("PollEmpty", true)
        if IsSet(_ResetPrefixBuffer)
            try _ResetPrefixBuffer()
        return
    }
    ; Rebuild without the expired rows. Preserve ExpireMs so the poll
    ; timer continues tracking the remaining deadlines correctly.
    RebuildItems := []
    for , Item in Remaining {
        Copy := {}
        for k, v in Item.OwnProps()
            Copy.%k% := v
        Copy.DurationSec := 0
        RebuildItems.Push(Copy)
    }
    _TooltipDequeueItems := Remaining
    _TooltipDequeueRebuild(RebuildItems)
}

; TooltipDequeueInit() must be called once at script startup (from ErgoptiPlus.ahk)
; to arm the poll timer. Code at file scope in #Include'd files does not execute
; in AHK v2 when the include appears after the auto-execute section has ended.
TooltipDequeueInit() {
    SetTimer(_TooltipDequeuePollFn, 100)
}

; Style constants — sourced from lib/ui_style.ahk (included before this file
; in ErgoptiPlus.ahk). All visual values are defined there and mapped to
; module-local aliases below so the rest of this file reads naturally.
;
; NOTE: These aliases are refreshed at runtime by Tooltip_UpdateStyles()
; once UiStyle_LoadSharedConst() has finished reading the shared TOML.
global _TOOLTIP_FONT_NAME := UI_FONT_NAME
global _TOOLTIP_FONT_SIZE := UI_FONT_SIZE_MAIN
global _TOOLTIP_PADDING_X := UI_PAD_X
global _TOOLTIP_PADDING_Y := UI_PAD_Y
global _TOOLTIP_OFFSET_BELOW := UI_OFFSET_BELOW
global _TOOLTIP_OFFSET_RIGHT := UI_OFFSET_RIGHT
global _TOOLTIP_DEFAULT_BG_HEX := UI_BG_HEX
global _TOOLTIP_SEP_COLOR_HEX := UI_SEP_COLOR_HEX
global _TOOLTIP_DIM_COLOR_HEX := UI_DIM_COLOR_HEX
global _TOOLTIP_BORDER_COLOR_HEX := UI_BORDER_COLOR_HEX
global _TOOLTIP_BORDER_ALPHA := UI_BORDER_ALPHA
global _TOOLTIP_BORDER_THICKNESS := UI_BORDER_THICKNESS
global _TOOLTIP_CORNER_RADIUS := UI_CORNER_RADIUS
global _TOOLTIP_LABEL_FONT_SIZE := UI_FONT_SIZE_HINT
global _TOOLTIP_LABEL_GAP := UI_LABEL_GAP
global _TOOLTIP_LABEL_COLOR_HEX := UI_LABEL_COLOR_HEX
global _TOOLTIP_HINT_COLOR_HEX := UI_HINT_COLOR_HEX
global _TOOLTIP_INFO_COLOR_HEX := UI_INFO_COLOR_HEX
global _TOOLTIP_INFO_FONT_SIZE := UI_FONT_SIZE_INFO
global _TOOLTIP_LINE_SPACING := UI_LINE_SPACING
global _TOOLTIP_HINT_SPACING := UI_HINT_SPACING
global _TOOLTIP_LIGHTNESS := UI_TINT_LIGHTNESS
global _TOOLTIP_SATURATION := UI_TINT_SATURATION
global _TOOLTIP_MAX_CARET_HEIGHT_PX := UI_MAX_CARET_HEIGHT_PX
global _TOOLTIP_WINDOW_BOTTOM_INSET_PX := UI_WINDOW_BOTTOM_INSET_PX

/**
 * Refreshes module-local style aliases from the UI_* globals. Called at boot
 * after the shared TOML has been parsed, ensuring that capture-at-include-time
 * doesn't leave the tooltip with zeroed-out defaults.
 */
Tooltip_UpdateStyles() {
    global
    _TOOLTIP_FONT_NAME := UI_FONT_NAME
    _TOOLTIP_FONT_SIZE := UI_FONT_SIZE_MAIN
    _TOOLTIP_PADDING_X := UI_PAD_X
    _TOOLTIP_PADDING_Y := UI_PAD_Y
    _TOOLTIP_OFFSET_BELOW := UI_OFFSET_BELOW
    _TOOLTIP_OFFSET_RIGHT := UI_OFFSET_RIGHT
    _TOOLTIP_DEFAULT_BG_HEX := UI_BG_HEX
    _TOOLTIP_SEP_COLOR_HEX := UI_SEP_COLOR_HEX
    _TOOLTIP_DIM_COLOR_HEX := UI_DIM_COLOR_HEX
    _TOOLTIP_BORDER_COLOR_HEX := UI_BORDER_COLOR_HEX
    _TOOLTIP_BORDER_ALPHA := UI_BORDER_ALPHA
    _TOOLTIP_BORDER_THICKNESS := UI_BORDER_THICKNESS
    _TOOLTIP_CORNER_RADIUS := UI_CORNER_RADIUS
    _TOOLTIP_LABEL_FONT_SIZE := UI_FONT_SIZE_HINT
    _TOOLTIP_LABEL_GAP := UI_LABEL_GAP
    _TOOLTIP_LABEL_COLOR_HEX := UI_LABEL_COLOR_HEX
    _TOOLTIP_HINT_COLOR_HEX := UI_HINT_COLOR_HEX
    _TOOLTIP_INFO_COLOR_HEX := UI_INFO_COLOR_HEX
    _TOOLTIP_INFO_FONT_SIZE := UI_FONT_SIZE_INFO
    _TOOLTIP_LINE_SPACING := UI_LINE_SPACING
    _TOOLTIP_HINT_SPACING := UI_HINT_SPACING
    _TOOLTIP_LIGHTNESS := UI_TINT_LIGHTNESS
    _TOOLTIP_SATURATION := UI_TINT_SATURATION
    _TOOLTIP_MAX_CARET_HEIGHT_PX := UI_MAX_CARET_HEIGHT_PX
    _TOOLTIP_WINDOW_BOTTOM_INSET_PX := UI_WINDOW_BOTTOM_INSET_PX
    _TOOLTIP_TIMEOUT_DECREMENT_SEC := UI_TIMEOUT_DECREMENT_SEC
    _TOOLTIP_TIMEOUT_FLOOR_SEC := UI_TIMEOUT_FLOOR_SEC
}
Tooltip_UpdateStyles()

; Border overlay Gui — single frameless window covering the entire stack.
global _TooltipBorderGui := 0

; Defensive Hwnd tracking — every Gui handle shown by this module is pushed
; here, and TooltipHide drains the arrays via raw Win32 DestroyWindow as a
; last-chance sweep. Without this safety net, a Gui.Destroy that silently
; failed (every Destroy site is wrapped in `try` so a transient Win32 error
; would not propagate) leaked a window onto the screen, and successive
; TooltipShow calls stacked more ghosts — exactly the « plein de tooltips
; sur mon écran » symptom. DestroyWindow on a stale handle is a no-op
; (returns FALSE, no exception) so the sweep is safe to run unconditionally.
global _TooltipShownHwnds := []
global _TooltipShownBorderHwnds := []
; Last resolved screen position — reused by dequeue destack rebuilds so the
; surviving rows do not jump while rows above them expire.
global _TooltipLastPos := 0

; Cap on the tracking arrays so a long typing session cannot grow them
; unbounded. Each entry is a single Ptr (8 B) so the cap is generous;
; the value matters mostly as an upper bound on the sweep iteration.
global _TOOLTIP_HWND_TRACK_CAP := 32

; Auto-hide is shortened by this many seconds (with a hard floor) so the
; tooltip vanishes a beat before the actual expansion window closes —
; otherwise the user can still see the preview and press the magic key
; just past the deadline, where the expansion silently does not fire.
; Mirrors Hammerspoon's TIMEOUT_DECREMENT_SEC / TIMEOUT_FLOOR_SEC.
global _TOOLTIP_TIMEOUT_DECREMENT_SEC := 0.2
global _TOOLTIP_TIMEOUT_FLOOR_SEC := 0.05

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

    ; While the script is suspended nothing may paint — « pause = AHK éteint ».
    ; The per-callback input guards normally prevent reaching here, but the
    ; dequeue poll timer and async LLM callers can still land mid-pause, so tear
    ; down anything still up and refuse the show.
    if A_IsSuspended {
        TooltipHide("Suspend", true)
        return
    }

    ; Normalise to an Array of { Text, ColorHex } objects.
    if !IsObject(Items) {
        Items := [{ Text: Items, ColorHex: "", DurationSec: DurationSec }]
    } else if !Items.HasMethod("Push") {
        Items := [Items]
    }

    ; Destroy any currently visible tooltip before rebuilding — ensures the old
    ; window is gone even if its auto-hide timer has not fired yet. Without this,
    ; a tooltip that was shown at a different screen position can remain visible
    ; as a ghost while the new one appears elsewhere.
    ; Force=true bypasses the dequeue guard — a new TooltipShow always supersedes.
    TooltipHide("NewShow", true)

    ; Bump the generation counter so any in-flight timer from the previous
    ; tooltip knows it is stale and must not call TooltipHide().
    global _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipShownHwnds, _TOOLTIP_HWND_TRACK_CAP
    global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC, _TOOLTIP_SAFETY_SEC
    global _TooltipDequeueItems, _TooltipDequeueActive, _TooltipLastItems
    _TooltipGeneration += 1
    _TooltipLastItems := Items

    ; Timer already cancelled by TooltipHide("NewShow") above — this is a
    ; belt-and-suspenders guard in case TooltipHide returned early for any reason.
    SetTimer(_TooltipTimerFn, 0)

    try {
        _TooltipBuildGui(Items)
    } catch {
        TooltipHide("BuildFail", true)
        return
    }

    ; Cache in a local variable to prevent "Invalid index" crashes if a
    ; concurrent TooltipHide clears the global array during the
    ; _TooltipResolvePosition yield point.
    Rows := _TooltipRowGuis
    if (Rows.Length == 0) {
        TooltipHide("NoRows", true)
        return
    }

    Pos := _TooltipResolvePosition()
    Row := Rows[1]
    ; Snapshot generation before present so any exception still arms the timer
    ; correctly and the ghost cannot outlive the safety deadline.
    _TooltipTimerGeneration := _TooltipGeneration
    try {
        _TooltipPresentStack(Pos, Row, true)
    } catch {
        TooltipHide("ShowFail", true)
        return
    }

    ; Collect per-item durations. When items carry distinct non-zero durations,
    ; we run the dequeue path so each row gets its own lifetime. When all
    ; durations are identical (or zero), we fall back to the simple single-timer
    ; path — which is the LLM tooltip case (all slots share one timeout).
    global _TooltipDequeueItems

    HasAnyDur := false
    HasMixedDur := false
    FirstDur := 0
    for , Item in Items {
        D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
        if (D > 0) {
            HasAnyDur := true
            if (FirstDur == 0)
                FirstDur := D
            else if (D != FirstDur)
                HasMixedDur := true
        }
    }
    ; When rebuilding from the poll timer the items already carry ExpireMs
    ; and DurationSec = 0 — detect that via the ExpireMs field.
    IsDequeueRebuild := false
    for , Item in Items {
        if Item.HasOwnProp("ExpireMs") {
            IsDequeueRebuild := true
            break
        }
    }

    if (IsDequeueRebuild or (HasAnyDur and HasMixedDur)) {
        ; Dequeue path — each item tracks its own absolute expiry.
        ; The poll timer (_TooltipDequeuePollFn, 100 ms) checks these
        ; deadlines and rebuilds the stack when any row expires.
        Now := A_TickCount
        _TooltipDequeueItems := []
        MaxMs := 0
        for , Item in Items {
            D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
            if IsDequeueRebuild and Item.HasOwnProp("ExpireMs") {
                ExpMs := Item.ExpireMs
            } else if (D > 0) {
                Eff := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC, D - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
                ExpMs := Now + Round(Eff * 1000)
            } else {
                ExpMs := 0   ; no expiry for this row
            }
            Copy := {}
            for k, v in Item.OwnProps()
                Copy.%k% := v
            Copy.ExpireMs := ExpMs
            _TooltipDequeueItems.Push(Copy)
            ; MaxMs = latest expiry — drives the safety timer fallback.
            if (ExpMs > 0) {
                Remaining := Max(50, ExpMs - Now)
                if (Remaining > MaxMs)
                    MaxMs := Remaining
            }
        }
        ; Safety net: arm on the LONGEST duration so the tooltip cannot
        ; outlive the last item even if the poll timer never fires.
        if (MaxMs > 0)
            SetTimer(_TooltipTimerFn, -MaxMs)
        _TooltipDequeueActive := true
    } else {
        ; Simple single-timer path (all durations identical, or zero).
        _TooltipDequeueItems := 0
        EffectiveDur := DurationSec
        for , Item in Items {
            D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
            if (D > 0 and (EffectiveDur == 0 or D < EffectiveDur))
                EffectiveDur := D
        }
        if (EffectiveDur > 0) {
            Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
                EffectiveDur - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
            SetTimer(_TooltipTimerFn, -Round(Effective * 1000))
            ; Guard the tooltip for its declared duration — same protection as
            ; the dequeue path. Without this, LookupNoMatch / ResetBuf events
            ; arriving before the timer fires would kill the tooltip instantly.
            _TooltipDequeueActive := true
        } else {
            ; No declared duration — tooltip stays until explicitly hidden,
            ; so no guard is needed (and we must not block future hides).
            _TooltipDequeueActive := false
        }
        ; else: the safety timer armed inside the try block above remains
        ; the auto-hide deadline — no further action needed here.
    }
}

; Hide all tooltip rows and the border overlay immediately.
; Destroys the row Guis (not just hides) so stale window handles cannot
; resurface as ghosts if a new TooltipShow fires before the old timer fires.
;
; Sequence:
;   1. Cancel pending auto-hide timer.
;   2. Hide border first, then rows. The border is a layered window composited
;      on top; hiding rows first leaves a ghost outline for one or more
;      compositor frames. Hiding the border first ensures the worst-case
;      interleave is « content alone » (correct rounded fill), never
;      « border alone » (empty outline floating over the editor).
;   3. Destroy the Gui objects in the same order (border first, then rows).
;   4. Defensive sweep through every tracked Hwnd in case a Gui.Destroy
;      silently failed earlier — DestroyWindow on a stale handle is a
;      harmless no-op so this is safe to run unconditionally.
TooltipHide(DbgTag := "?", Force := false) {
    global _TooltipGui, _TooltipRowGuis, _TooltipBorderGui
    global _TooltipShownHwnds, _TooltipShownBorderHwnds
    global _TooltipDequeueItems, _TooltipDequeueActive
    ; During an active dequeue cycle the poll timer owns the tooltip lifecycle.
    ; External callers (prefix watcher resets, lookup misses) must not interrupt
    ; it — they would hide the post-expansion rows before their time.
    if (!Force and _TooltipDequeueActive)
        return
    SetTimer(_TooltipTimerFn, 0)
    _TooltipDequeueItems := 0
    _TooltipDequeueActive := false

    ; Step 1 — hide border first (direct SW_HIDE), then content via DeferWindowPos.
    ; WS_EX_LAYERED windows do not reliably respond to SWP_HIDEWINDOW inside a
    ; DeferWindowPos batch — the compositor can still composit the border for an
    ; extra frame after EndDeferWindowPos returns, causing a visible ghost outline.
    ; Hiding the border with a direct ShowWindow(SW_HIDE=0) before scheduling the
    ; content hide ensures the border is already invisible when DWM composites the
    ; next frame that removes the content — worst case is "content alone" (rounded
    ; fill, correct), never "border alone" (empty ghost outline).
    if _TooltipBorderGui {
        try GR_Hide(_TooltipBorderGui.Hwnd)
    }
    ; Hide content rows atomically — all rows disappear in the same DWM frame.
    ; SWP flags: NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|HIDEWINDOW.
    SWP_HIDE_FLAGS := 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0080
    HideCount := _TooltipRowGuis.Length
    if HideCount > 0 {
        HDWP := DllCall("User32\BeginDeferWindowPos", "Int", HideCount, "Ptr")
        if HDWP {
            for , Row in _TooltipRowGuis {
                if HDWP
                    ; .Hwnd throws "Gui has no window" if the Gui was already
                    ; destroyed by a concurrent hide (e.g. LLM_TooltipHide ran
                    ; immediately before this call). Skip destroyed Guis silently —
                    ; Destroy() below will confirm they are already gone.
                    try HDWP := DllCall("User32\DeferWindowPos",
                        "Ptr", HDWP, "Ptr", Row.Gui.Hwnd,
                        "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0,
                        "UInt", SWP_HIDE_FLAGS, "Ptr")
            }
            if HDWP
                DllCall("User32\EndDeferWindowPos", "Ptr", HDWP)
        }
    }

    ; Step 2 — release Gui resources: border first, then rows.
    if _TooltipBorderGui {
        try _TooltipBorderGui.Destroy()
        _TooltipBorderGui := 0
    }
    for , Row in _TooltipRowGuis {
        try Row.Gui.Destroy()
    }
    _TooltipGui := 0
    _TooltipRowGuis := []

    ; Step 3 — defensive sweep. Any Hwnd whose Gui.Destroy() silently
    ; failed in the past (Destroy sites are wrapped in `try` so a
    ; transient Win32 error would have leaked the underlying window)
    ; gets a last-chance kill here via the raw Win32 DestroyWindow.
    ; Without this safety net, accumulated ghost tooltips would remain
    ; visible on screen until the script reloads.
    for , Hwnd in _TooltipShownBorderHwnds {
        GR_DestroyWindow(Hwnd)
    }
    for , Hwnd in _TooltipShownHwnds {
        GR_DestroyWindow(Hwnd)
    }
    _TooltipShownHwnds := []
    _TooltipShownBorderHwnds := []
}

; Returns true when a hotstring-style tooltip (built by TooltipShow) is
; currently visible. Used by the LLM bridge to avoid firing predictions while
; a hotstring overlay is on screen — mirrors the HS tooltip.is_visible() check.
TooltipIsVisible() {
    global _TooltipGui
    return IsSet(_TooltipGui) and _TooltipGui != 0
}

; Re-arm the auto-hide timer from zero using the durations stored in
; _TooltipLastItems. Called after a hotstring fires so the timer counts
; from the moment of fire, not from when the preview was first shown
; (which may have been seconds earlier when the user was still typing).
; Only applies to the simple single-timer path — the dequeue path manages
; its own deadlines and is not affected by this call.
TooltipRearmTimer() {
    global _TooltipLastItems
    global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC
    global _TooltipGeneration, _TooltipTimerGeneration

    if (!IsObject(_TooltipLastItems) or _TooltipLastItems.Length == 0)
        return

    ; Find the shortest non-zero duration among the displayed items.
    ; Rows with DurationSec = 0 are "infinite" — if ALL rows are infinite,
    ; no timer is needed and we leave the safety timer in place.
    EffectiveDur := 0
    for , Item in _TooltipLastItems {
        D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
        if (D > 0 and (EffectiveDur == 0 or D < EffectiveDur))
            EffectiveDur := D
    }
    if (EffectiveDur == 0)
        return

    Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
        EffectiveDur - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
    ; Cancel any stale timer and arm a fresh one from now.
    SetTimer(_TooltipTimerFn, 0)
    _TooltipTimerGeneration := _TooltipGeneration
    SetTimer(_TooltipTimerFn, -Round(Effective * 1000))
    if IsSet(LLM_Bridge_ScheduleAfterHotstring)
        try LLM_Bridge_ScheduleAfterHotstring(_TooltipLastItems)
}





; ============================================================
; ============================================================
; ======= 2/ Internal helpers ===============================
; ============================================================
; ============================================================

; Surface lifecycle — canonical phases in shared/tooltip/lifecycle.js.
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
_TooltipRevealSurfaces() {
    global _TooltipBorderGui, _TooltipRowGuis
    if (_TooltipRowGuis.Length > 0) {
        try DllCall("User32\ShowWindow", "Ptr", _TooltipRowGuis[1].Gui.Hwnd, "Int", 4)
    }
    if _TooltipBorderGui {
        GR_Show(_TooltipBorderGui.Hwnd)
    }
}

; PREPARE + REVEAL for a built stack. Pos = { X, Y }, Row = { Gui, W, H }.
_TooltipPresentStack(Pos, Row, ArmSafety := true) {
    global _TooltipShownHwnds, _TOOLTIP_HWND_TRACK_CAP, _TOOLTIP_SAFETY_SEC
    global _TooltipLastPos
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
        if HBmp DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
            if MemDC DllCall("Gdi32\DeleteDC", "Ptr", MemDC)
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
    loop TotalPx {
        Offset := (A_Index - 1) * 4
        Raw := NumGet(PixPtr, Offset, "UInt")
        if (Raw != 0)   ; GDI painted this pixel — set correct alpha
            NumPut("UInt", PremulPx, PixPtr, Offset)
    }

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





; ==========================================
; =========================================
; ======= 3/ LLM Multi-slot Tooltip =======
; =========================================
; ==========================================

; Global state for the LLM multi-slot tooltip — backed by the shared Gui
; engine instead of the monochrome built-in ToolTip() function.
global _LLM_Tooltip_Slots    := []
global _LLM_Tooltip_ActiveIdx := 1
global _LLM_Tooltip_Visible  := false
global _LLM_Tooltip_Loading  := false
; Footer state — mirrors tooltip_llm.lua info/hint rows.
global _LLM_Tooltip_ShowInfoBar := false
global _LLM_Tooltip_InfoModel   := ""
global _LLM_Tooltip_FooterSlots := 1
global _LLM_Tooltip_NavMods     := ""
global _LLM_Tooltip_PredIndent  := 0
global _LLM_Tooltip_ValMods     := "alt"
global _LLM_Tooltip_Chain := {
	StartTick: 0, FirstShowTick: 0, LastUpdateTick: 0, TtftMs: 0, TtltMs: 0,
}

; Show the LLM multi-slot tooltip using the shared Gui engine.
; Each slot may be a plain string (streaming) or a diff object:
;   { Text, Chunks: [{type:"equal"|"insert", text}], NextWords, HasCorrections }
; Active slot: equal chunks in green, NextWords in orange, insert in white.
; Inactive slots: full Text in gray.
LLM_TooltipShow(payload, active := 1, is_final := false) {
	global _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx, _LLM_Tooltip_Visible

	; No prediction tooltip while paused — Ergopti_OnSuspendEnter already hid any
	; visible one, this refuses late async renders.
	if A_IsSuspended
		return

	slots := []
	if (Type(payload) == "Array") {
		for s in payload
			slots.Push(s)
	} else if (Type(payload) == "String") {
		if (payload == "")
			return
		slots.Push(payload)
	} else {
		return
	}

	if is_final {
		while (slots.Length > 0 and _LLM_SlotIsEmpty(slots[slots.Length]))
			slots.Pop()
		filtered := []
		for _, s in slots {
			if !_LLM_SlotIsEmpty(s)
				filtered.Push(s)
		}
		slots := filtered
	}
	if (slots.Length == 0) {
		LLM_TooltipHide()
		return
	}

	; macOS parity: keep the compact violet « Génération en cours… » indicator
	; until at least one slot carries real text. Intermediate placeholder paints
	; (DispatchBatch / variant reveal) used to swap in the full LLM chrome with
	; footer + info-bar width reservation, which stretched a short label across
	; the whole tooltip frame on Windows 11.
	if (!is_final) {
		all_placeholder := true
		for _, s in slots {
			if !_LLM_SlotIsPlaceholder(s) {
				all_placeholder := false
				break
			}
		}
		if all_placeholder {
			LLM_TooltipShowLoading()
			return
		}
	}

	global _LLM_Tooltip_Loading
	_LLM_Tooltip_Loading := false
	_LLM_Tooltip_Slots    := slots
	_LLM_Tooltip_ActiveIdx := Max(1, Min(Integer(active), slots.Length))
	_LLM_Tooltip_Visible  := true

	; Detect whether any slot carries diff chunks — if so use the rich Gui path.
	has_chunks := false
	for _, s in slots {
		if IsObject(s) and s.HasOwnProp("Chunks") and s.Chunks.Length > 0 {
			has_chunks := true
			break
		}
	}

	LLM_TooltipRefreshChainTiming()
	_TooltipBuildGuiLlm(slots, _LLM_Tooltip_ActiveIdx)

	; Arm the LLM-specific auto-hide timer. The duration mirrors the macOS
	; llm_prediction delay: it defaults to UI_LLM_TIMEOUT_SEC (20 s) but is
	; user-overridable from the hotstrings "Delays" submenu, stored as the
	; "llm_prediction" delay override. Resolve it live so a change applies
	; without a restart; fall back to the UI constant if the resolver is absent.
	global _TooltipTimerGeneration, _TooltipGeneration, UI_LLM_TIMEOUT_SEC
	_TooltipTimerGeneration := _TooltipGeneration
	llm_timeout_sec := UI_LLM_TIMEOUT_SEC
	try {
		_llm_ov := HotstringsResolve("llm_prediction", "")
		if _llm_ov.HasOverride
			llm_timeout_sec := _llm_ov.Delay
	}
	timeout_ms := Round(Max(0.05, llm_timeout_sec - 0.2) * 1000)
	SetTimer(_TooltipTimerFn, -timeout_ms)
}

; Purple in-flight indicator — macOS ``show_loading`` parity (ai_loading tint).
; Stays visible until replaced by ``LLM_TooltipShow`` or ``LLM_TooltipHide``.
LLM_TooltipShowLoading() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Loading
	if A_IsSuspended
		return
	_LLM_Tooltip_Loading := true
	_LLM_Tooltip_Visible  := true
	label := (IsSet(t)) ? t("llm.generating") : "⏳ Génération en cours…"
	accent := _TooltipResolveAccent("ai_loading")
	TooltipShow([{ Text: label, ColorHex: accent, IsDimmed: false, DurationSec: 0 }], 0)
	; TooltipShow arms a 3 s safety timer — cancel it so loading survives slow inference.
	SetTimer(_TooltipTimerFn, 0)
	global _TooltipDequeueActive
	_TooltipDequeueActive := false
}

LLM_TooltipHide(accepted := false) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_Loading
	_LLM_Tooltip_Visible := false
	_LLM_Tooltip_Loading := false
	_LLM_Tooltip_Slots   := []
	_LLM_TooltipResetChain()
	TooltipHide("LLM", true)
}

LLM_TooltipGetText() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !_LLM_Tooltip_Visible or _LLM_Tooltip_Slots.Length == 0
		return ""
	idx := _LLM_Tooltip_ActiveIdx
	if (idx < 1 or idx > _LLM_Tooltip_Slots.Length)
		return ""
	text := _LLM_SlotGetText(_LLM_Tooltip_Slots[idx])
	if (text != "")
		return text
	for s in _LLM_Tooltip_Slots {
		SlotText := _LLM_SlotGetText(s)
		if (SlotText != "")
			return SlotText
	}
	return ""
}

LLM_TooltipGetSlots() {
	global _LLM_Tooltip_Slots
	return IsSet(_LLM_Tooltip_Slots) ? _LLM_Tooltip_Slots : []
}

LLM_TooltipGetActiveIdx() {
	global _LLM_Tooltip_ActiveIdx
	return IsSet(_LLM_Tooltip_ActiveIdx) ? _LLM_Tooltip_ActiveIdx : 1
}

LLM_TooltipIsVisible() {
	global _LLM_Tooltip_Visible
	return IsSet(_LLM_Tooltip_Visible) and _LLM_Tooltip_Visible
}

LLM_TooltipIsLoading() {
	global _LLM_Tooltip_Loading
	return IsSet(_LLM_Tooltip_Loading) and _LLM_Tooltip_Loading
}

LLM_TooltipSetActiveIdx(idx) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !_LLM_Tooltip_Visible or _LLM_Tooltip_Slots.Length == 0
		return
	_LLM_Tooltip_ActiveIdx := Max(1, Min(idx, _LLM_Tooltip_Slots.Length))
	LLM_TooltipShow(_LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx, false)
}



; =================================
; ===== 3.1) LLM slot helpers =====
; =================================

_LLM_SlotIsPlaceholder(slot) {
	global UI_LLM_SLOT_PLACEHOLDER, LLM_TOOLTIP_PLACEHOLDER
	ph := UI_LLM_SLOT_PLACEHOLDER != "" ? UI_LLM_SLOT_PLACEHOLDER : LLM_TOOLTIP_PLACEHOLDER
	txt := _LLM_SlotGetText(slot)
	if (txt = "")
		return true
	if (ph != "" and txt = ph)
		return true
	; HS streaming reserve char and common ellipsis variants.
	if (txt = "…" or txt = "...")
		return true
	return !!(txt ~= "^\s+$")
}

_LLM_AllSlotsPlaceholder(slots) {
	for s in slots {
		if !_LLM_SlotIsPlaceholder(s)
			return false
	}
	return slots.Length > 0
}

_LLM_SlotIsEmpty(slot) {
	return _LLM_SlotIsPlaceholder(slot)
}

_LLM_SlotGetText(slot) {
	if (Type(slot) == "String")
		return slot
	if IsObject(slot) and slot.HasOwnProp("Text")
		return slot.Text
	return ""
}

_LLM_RepeatChar(ch, count) {
	if (count <= 0)
		return ""
	out := ""
	loop count
		out .= ch
	return out
}

; Prefixes for active/inactive rows — mirrors tooltip_llm.lua assemble_blocks.
_LLM_GetActivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_ACTIVE_PREFIX
	sparkle := UI_LLM_ACTIVE_PREFIX
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (slotCount >= 2 and indent > 0)
		return _LLM_RepeatChar(" ", indent) . sparkle
	return sparkle
}

_LLM_GetInactivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_INACTIVE_ALIGN_CHAR
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (indent < 0 and indent > -3)
		return _LLM_RepeatChar(" ", -indent)
	if (indent <= -3)
		return _LLM_GetActivePrefix(slotCount) . _LLM_RepeatChar(" ", Max(0, -indent - 3))
	align := UI_LLM_INACTIVE_ALIGN_CHAR
	return (indent > -3) ? align : ""
}

_LLM_FormatValModifiers(valMods) {
	if (valMods = "" or valMods = "none")
		return ""
	sym := valMods
	sym := StrReplace(sym, "cmd", "⌘", , true)
	sym := StrReplace(sym, "ctrl", "⌃", , true)
	sym := StrReplace(sym, "alt", "⌥", , true)
	sym := StrReplace(sym, "shift", "⇧", , true)
	return StrReplace(sym, "+", "")
}

_LLM_BuildShortcutSuffix(idx, slotCount, valMods := "") {
	global UI_LLM_SHORTCUT_LABEL_GAP
	if (slotCount <= 1)
		return ""
	sym := _LLM_FormatValModifiers(valMods)
	if (sym = "")
		return ""
	gap := UI_LLM_SHORTCUT_LABEL_GAP
	if (idx <= 9)
		return gap . sym . idx
	if (idx = 10)
		return gap . sym . "0"
	return ""
}

; Build the display string for a slot row (used by the plain-string path).
_LLM_SlotBuildText(slot, is_active, slotIdx := 1, slotCount := 1) {
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX, _LLM_Tooltip_ValMods
	prefix := is_active ? _LLM_GetActivePrefix(slotCount) : _LLM_GetInactivePrefix(slotCount)
	shortcut := _LLM_BuildShortcutSuffix(slotIdx, slotCount, _LLM_Tooltip_ValMods)
	if _LLM_SlotIsEmpty(slot)
		return prefix . LLM_TOOLTIP_PLACEHOLDER . shortcut
	txt    := _LLM_SlotGetText(slot)
	suffix := is_active ? LLM_TOOLTIP_TAB_SUFFIX : ""
	return prefix . txt . suffix . shortcut
}

LLM_TooltipSetDisplayOpts(opts) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel
	global _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_PredIndent, _LLM_Tooltip_ValMods
	if !(opts is Map)
		return
	_LLM_Tooltip_ShowInfoBar := !!(opts.Has("show_info_bar") and opts["show_info_bar"])
	_LLM_Tooltip_InfoModel := (opts.Has("info_model") and opts["info_model"] != "")
		? opts["info_model"] : ""
	_LLM_Tooltip_FooterSlots := (opts.Has("slot_count") and opts["slot_count"] > 0)
		? Integer(opts["slot_count"]) : 1
	_LLM_Tooltip_NavMods := (opts.Has("nav_modifiers") and opts["nav_modifiers"] != "")
		? opts["nav_modifiers"] : ""
	if opts.Has("pred_indent")
		_LLM_Tooltip_PredIndent := Integer(opts["pred_indent"])
	if opts.Has("val_modifiers")
		_LLM_Tooltip_ValMods := opts["val_modifiers"]
}

LLM_TooltipSetChainStart() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := A_TickCount
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

LLM_TooltipRefreshChainTiming() {
	global _LLM_Tooltip_Chain
	if !_LLM_Tooltip_Chain.StartTick
		return
	now := A_TickCount
	_LLM_Tooltip_Chain.LastUpdateTick := now
	if !_LLM_Tooltip_Chain.FirstShowTick {
		_LLM_Tooltip_Chain.FirstShowTick := now
		_LLM_Tooltip_Chain.TtftMs := now - _LLM_Tooltip_Chain.StartTick
	}
}

LLM_TooltipMarkChainComplete() {
	global _LLM_Tooltip_Chain, _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !_LLM_Tooltip_Chain.StartTick
		return
	final := _LLM_Tooltip_Chain.LastUpdateTick ? _LLM_Tooltip_Chain.LastUpdateTick : A_TickCount
	_LLM_Tooltip_Chain.TtltMs := final - _LLM_Tooltip_Chain.StartTick
	if !_LLM_Tooltip_Chain.TtftMs
		_LLM_Tooltip_Chain.TtftMs := _LLM_Tooltip_Chain.TtltMs
	; Re-render so the info bar picks up TTLT — mirrors HS set_timing().
	if (_LLM_Tooltip_Visible and _LLM_Tooltip_Slots.Length > 0)
		LLM_TooltipShow(_LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx, false)
}

_LLM_TooltipResetChain() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := 0
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

_LLM_FormatInfoLine(modelInfo, ttftMs := "", ttltMs := "", forSizing := false) {
	hasModel := (modelInfo != "")
	hasTtft := (IsNumber(ttftMs) and ttftMs > 0)
	hasTtlt := (IsNumber(ttltMs) and ttltMs > 0)
	if forSizing {
		if !hasTtft
			ttftMs := 9999, hasTtft := true
		if !hasTtlt
			ttltMs := 9999, hasTtlt := true
	}
	if (!hasModel and !hasTtft and !hasTtlt)
		return ""
	pieces := []
	if hasModel
		pieces.Push(modelInfo)
	if hasTtft {
		timing := Format("⏱ {:.2f} s", ttftMs / 1000)
		if hasTtlt
			timing .= Format(" — {:.2f} s", ttltMs / 1000)
		pieces.Push(timing)
	} else if hasTtlt
		pieces.Push(Format("⏱ {:.2f} s", ttltMs / 1000))
	out := ""
	for i, p in pieces
		out .= (i = 1) ? p : " — " . p
	return out
}

_LLM_BuildNavHint(slotCount, navMods := "") {
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_HINT_ACCEPT_SINGLE, UI_LLM_HINT_NAV_LEFT
	global UI_LLM_HINT_NAV_RIGHT, UI_LLM_HINT_ACCEPT_CENTER, UI_LLM_HINT_ARROW_LEFT
	global UI_LLM_HINT_ARROW_RIGHT, UI_LLM_HINT_OR, UI_LLM_HINT_ARROW_SEP_LEFT
	global UI_LLM_HINT_ARROW_SEP_RIGHT
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	acceptSingle := UI_LLM_HINT_ACCEPT_SINGLE
	if (slotCount <= 1)
		return acceptSingle
	navStr := navMods
	if (navStr = "" or navStr = "none")
		navStr := ""
	else
		navStr := _LLM_FormatValModifiers(navStr)
	hintLeft := UI_LLM_HINT_NAV_LEFT
	hintRight := UI_LLM_HINT_NAV_RIGHT
	hintOr := UI_LLM_HINT_OR
	arrL := UI_LLM_HINT_ARROW_LEFT
	arrR := UI_LLM_HINT_ARROW_RIGHT
	if (navStr != "") {
		hintLeft .= hintOr . navStr . " + " . arrL
		hintRight .= hintOr . navStr . " + " . arrR
	}
	sepL := UI_LLM_HINT_ARROW_SEP_LEFT
	sepR := UI_LLM_HINT_ARROW_SEP_RIGHT
	acceptCenter := UI_LLM_HINT_ACCEPT_CENTER
	return hintLeft . spaceDiv . sepL . spaceDiv . acceptCenter . spaceDiv . sepR . spaceDiv . hintRight
}

_LLM_TooltipAppendFooter(G, &TotalH, TotalW, bgHex) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_FooterSlots
	global _LLM_Tooltip_NavMods, _LLM_Tooltip_Chain
	global _TOOLTIP_FONT_NAME, _TOOLTIP_HINT_COLOR_HEX, _TOOLTIP_INFO_COLOR_HEX
	global _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_PADDING_Y
	global _TOOLTIP_PADDING_X, _TOOLTIP_LINE_SPACING, _TOOLTIP_HINT_SPACING, _TOOLTIP_SEP_COLOR_HEX

	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoText := ""
	if _LLM_Tooltip_ShowInfoBar {
		ttft := _LLM_Tooltip_Chain.TtftMs
		ttlt := _LLM_Tooltip_Chain.TtltMs
		infoText := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, ttft, ttlt, false)
	}
	if (hintText == "" and infoText == "")
		return

	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	isCombined := false
	combinedText := ""
	combinedSz := { W: 0, H: 0 }
	if (hintText != "" and infoText != "") {
		combinedText := hintText . spaceDiv . combinedSep . spaceDiv . infoText
		combinedSz := _TooltipMeasureTextSize(combinedText, _TOOLTIP_LABEL_FONT_SIZE)
		if (combinedSz.W <= TotalW - 2 * _TOOLTIP_PADDING_X)
			isCombined := true
	}

	; HS layout: preds → line_spacing → sep → line_spacing → hint/info.
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING
	sepY := TotalH
	G.SetFont("s1", _TOOLTIP_FONT_NAME)
	G.Add("Text", Format("Background{1} x0 y{2} w{3} h1", _TOOLTIP_SEP_COLOR_HEX, sepY, TotalW), "")
	TotalH += 1
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING

	if isCombined {
		rowH := _TOOLTIP_PADDING_Y + combinedSz.H + _TOOLTIP_PADDING_Y
		textY := TotalH + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, rowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		textX := Max(_TOOLTIP_PADDING_X, (TotalW - combinedSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			textX, textY, combinedSz.W + 4, combinedSz.H), combinedText)
		TotalH += rowH
		return
	}

	if (hintText != "") {
		hintSz := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE)
		hintY := TotalH + _TOOLTIP_PADDING_Y
		hintRowH := _TOOLTIP_PADDING_Y + hintSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, hintRowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		hintX := Max(_TOOLTIP_PADDING_X, (TotalW - hintSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			hintX, hintY, hintSz.W + 4, hintSz.H), hintText)
		TotalH += hintRowH
	}

	if (infoText != "") {
		if (hintText != "")
			TotalH += _TOOLTIP_HINT_SPACING
		infoSz := _TooltipMeasureTextSize(infoText, _TOOLTIP_INFO_FONT_SIZE)
		infoY := TotalH + _TOOLTIP_PADDING_Y
		infoRowH := _TOOLTIP_PADDING_Y + infoSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, infoRowH), "")
		G.SetFont("norm c" . _TOOLTIP_INFO_COLOR_HEX . " s" . _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_FONT_NAME)
		infoX := Max(_TOOLTIP_PADDING_X, (TotalW - infoSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			infoX, infoY, infoSz.W + 4, infoSz.H), infoText)
		TotalH += infoRowH
	}
}



; ======================================
; ===== 3.2) Rich Gui LLM renderer =====
; ======================================

; Build a single Gui that renders all LLM slots with per-chunk coloring.
; Active slot: equal chunks in corr_sel (green), insert/NextWords in nw_sel
; (orange). Inactive slots: full text in unsel_gray. Each slot is one row;
; within a row, segment coloring is achieved by multiple Text controls placed
; side-by-side (same Y, X incremented by measured segment width).
_TooltipBuildGuiLlm(slots, active_idx) {
	global _TooltipGui, _TooltipRowGuis
	global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y
	global _TOOLTIP_DEFAULT_BG_HEX, _TOOLTIP_SEP_COLOR_HEX, _TOOLTIP_LABEL_FONT_SIZE
	global _TOOLTIP_INFO_FONT_SIZE, _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_ValMods
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX
	global UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX, UI_LLM_UNSEL_GRAY_HEX, UI_LLM_LOADING_HEX
	global UI_LLM_CURSOR_HEX, UI_LLM_CMD_SEL_HEX, UI_LLM_CMD_DIM_HEX
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP

	_TooltipSuspendSurfaces()
	_TooltipTeardownBorder()
	if _TooltipGui
		try _TooltipGui.Destroy()
	_TooltipGui    := 0
	_TooltipRowGuis := []

	DpiScale := A_ScreenDPI / 96
	SEP_H    := 1
	Count    := slots.Length

	; ── Measure all row texts to find max width ──────────────────────────────
	; Each row's text = prefix + full slot text + suffix (for width budget).
	Sizes := []
	MaxW  := 0
	slotCount := slots.Length
	all_placeholder := _LLM_AllSlotsPlaceholder(slots)
	loading_label := (IsSet(t)) ? t("llm.generating") : "⏳ Génération en cours…"
	for i, slot in slots {
		is_active := (i == active_idx)
		display := all_placeholder ? loading_label : _LLM_SlotBuildText(slot, is_active, i, slotCount)
		S := _TooltipMeasureText(display)
		Sizes.Push(S)
		if (S.W > MaxW)
			MaxW := S.W
	}
	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoSizing := ""
	if _LLM_Tooltip_ShowInfoBar
		infoSizing := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, 9999, 9999, true)
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	if (hintText != "" and infoSizing != "") {
		combinedW := _TooltipMeasureTextSize(
			hintText . spaceDiv . combinedSep . spaceDiv . infoSizing, _TOOLTIP_LABEL_FONT_SIZE).W
		if (combinedW > MaxW)
			MaxW := combinedW
	} else {
		if (hintText != "") {
			hintW := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE).W
			if (hintW > MaxW)
				MaxW := hintW
		}
		if (infoSizing != "") {
			infoW := _TooltipMeasureTextSize(infoSizing, _TOOLTIP_INFO_FONT_SIZE).W
			if (infoW > MaxW)
				MaxW := infoW
		}
	}

	TotalW := _TOOLTIP_PADDING_X + MaxW + _TOOLTIP_PADDING_X
	RowMeta := []
	TotalH  := 0
	for Idx, slot in slots {
		RowH := _TOOLTIP_PADDING_Y + Sizes[Idx].H + _TOOLTIP_PADDING_Y
		RowMeta.Push({ H: RowH, Y: TotalH })
		TotalH += RowH
		if (Idx < Count)
			TotalH += SEP_H
	}

	inflight_bg := _TooltipMixTintHex(_TooltipResolveAccent("ai_loading"))
	has_loading := false
	for , slot in slots {
		if _LLM_SlotIsPlaceholder(slot) {
			has_loading := true
			break
		}
	}
	cursorHex := UI_LLM_CURSOR_HEX
	cmdSelHex := UI_LLM_CMD_SEL_HEX
	cmdDimHex := UI_LLM_CMD_DIM_HEX
	G := Gui("+AlwaysOnTop -Caption +E0x20 +E0x80 +LastFound")
	G.BackColor := has_loading ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
	G.MarginX := 0
	G.MarginY := 0

	for Idx, slot in slots {
		is_active := (Idx == active_idx)
		Meta := RowMeta[Idx]
		RowY := Meta.Y
		RowH := Meta.H
		S    := Sizes[Idx]
		TextY := RowY + _TOOLTIP_PADDING_Y
		row_bg := _LLM_SlotIsPlaceholder(slot) ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
		activePrefix := _LLM_GetActivePrefix(slotCount)
		inactivePrefix := _LLM_GetInactivePrefix(slotCount)
		shortcut := _LLM_BuildShortcutSuffix(Idx, slotCount, _LLM_Tooltip_ValMods)

		; Full-width background band.
		G.SetFont("norm s1", _TOOLTIP_FONT_NAME)
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", row_bg, RowY, TotalW, RowH), "")

		if _LLM_SlotIsEmpty(slot) {
			; In-flight slot — full « Génération en cours… » copy when the whole
			; stack is still waiting; otherwise sparkle + ellipsis per slot (HS).
			color := UI_LLM_LOADING_HEX
			prefix := is_active ? activePrefix : inactivePrefix
			loading_label := (IsSet(t)) ? t("llm.generating") : "⏳ Génération en cours…"
			display := _LLM_AllSlotsPlaceholder(slots) ? loading_label : (prefix . LLM_TOOLTIP_PLACEHOLDER)
			G.SetFont("italic c" . color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				scColor := is_active ? cmdSelHex : cmdDimHex
				G.SetFont("norm c" . scColor . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else if !is_active {
			; Inactive slot: plain gray.
			G.SetFont("norm c" . UI_LLM_UNSEL_GRAY_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			display := inactivePrefix . _LLM_SlotGetText(slot)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdDimHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else {
			; Active slot with per-chunk coloring.
			CurX := _TOOLTIP_PADDING_X
			PrefixSz := _TooltipMeasureText(activePrefix)
			G.SetFont("norm c" . cursorHex . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				CurX, TextY, PrefixSz.W + 2, S.H), activePrefix)
			CurX += PrefixSz.W

			has_chunks := IsObject(slot) and slot.HasOwnProp("Chunks") and slot.Chunks.Length > 0
			if has_chunks {
				for , chunk in slot.Chunks {
					chunk_txt := chunk.HasOwnProp("text") ? chunk.text : ""
					if (chunk_txt == "")
						continue
					chunk_color := (chunk.type == "insert") ? UI_LLM_CORR_SEL_HEX : UI_LLM_UNSEL_GRAY_HEX
					CSz := _TooltipMeasureText(chunk_txt)
					G.SetFont("norm c" . chunk_color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), chunk_txt)
					CurX += CSz.W
				}
				nw := slot.HasOwnProp("NextWords") ? slot.NextWords : ""
				has_insert := false
				for , chunk in slot.Chunks {
					if (chunk.HasOwnProp("type") and chunk.type == "insert")
						has_insert := true
				}
				if (nw != "" and !has_insert) {
					CSz := _TooltipMeasureText(nw)
					G.SetFont("norm c" . UI_LLM_NW_SEL_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), nw)
					CurX += CSz.W
				}
			} else {
				; Plain text active slot (streaming).
				plain := _LLM_SlotGetText(slot)
				G.SetFont("norm cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, MaxW, S.H), plain)
				CurX += _TooltipMeasureText(plain).W
			}

			if (LLM_TOOLTIP_TAB_SUFFIX != "") {
				G.SetFont("norm c" . _TOOLTIP_LABEL_COLOR_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, _TooltipMeasureText(LLM_TOOLTIP_TAB_SUFFIX).W + 4, S.H), LLM_TOOLTIP_TAB_SUFFIX)
			}
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdSelHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		}

		; Separator.
		if (Idx < Count) {
			SepY := RowY + RowH
			G.SetFont("s1", _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", _TOOLTIP_SEP_COLOR_HEX, SepY, TotalW, SEP_H), "")
		}
	}

	row_bg_final := _TOOLTIP_DEFAULT_BG_HEX
	_LLM_TooltipAppendFooter(G, &TotalH, TotalW, row_bg_final)

	_TooltipGui := G
	_TooltipRowGuis := [{ Gui: G, H: TotalH, W: TotalW, IsSep: false }]

	; Show via the same path as TooltipShow.
	global _TooltipGeneration, _TooltipShownHwnds, _TOOLTIP_HWND_TRACK_CAP, _TooltipTimerGeneration
	_TooltipGeneration += 1
	SetTimer(_TooltipTimerFn, 0)

	; Cache in a local variable to prevent "Invalid index" crashes if a
	; concurrent TooltipHide clears the global array during the
	; _TooltipResolvePosition yield point.
	Rows := _TooltipRowGuis
	if (Rows.Length == 0) {
		TooltipHide("LlmLateNoRows", true)
		return
	}

	Pos := _TooltipResolvePosition()
	Row := Rows[1]
	_TooltipTimerGeneration := _TooltipGeneration
	try {
		_TooltipPresentStack(Pos, Row, true)
	} catch {
		TooltipHide("LlmPresentFail", true)
	}
}
