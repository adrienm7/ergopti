; ui/tooltip/core.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / Core Engine + Public API
; DESCRIPTION:
; Tooltip GUI state, font/style constants, the dequeue + safety timers, style refresh, and the public API (TooltipShow / TooltipHide / TooltipIsVisible / TooltipRearmTimer).
;
; Split out of the former lib/tooltip.ahk (P5 refactor); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.
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

; Tooltip GUI creation and UIA positioning can take tens of milliseconds. The
; prefix watcher calls TooltipShow on every character, so debounce render work
; until typing is idle instead of running GDI/COM in the keyboard callback.
global _TooltipPendingActive := false
global _TooltipPendingItems := 0
global _TooltipPendingDurationSec := 0
global _TooltipPendingGeneration := 0
global TOOLTIP_RENDER_DEBOUNCE_MS := 75
; Carries the caller's safety-deadline choice ACROSS the render debounce. A
; caller that must outlive the 3 s auto-hide (the LLM spinner, whose inference
; legitimately runs longer) cannot express that by cancelling _TooltipTimerFn
; after TooltipShow returns: the timer is not armed until _TooltipPresentStack
; runs, TOOLTIP_RENDER_DEBOUNCE_MS later, so such a cancel is a silent no-op.
global _TooltipPendingArmSafety := true

; Reuse the non-caret anchor briefly for LLM refreshes and repeated preview
; renders in controls without a native caret. The foreground HWND fence makes
; this a position cache, never cross-window stale state.
global _TooltipPositionCache := false
; MUST exceed the combined debounce that gates the preview path
; (_PREFIX_RENDER_DEBOUNCE_MS 150 + TOOLTIP_RENDER_DEBOUNCE_MS 75 = ~225 ms).
; At 150 ms the cache was ALWAYS past its expiry by the time it was consulted, so
; it never hit on the path it exists for: every preview render in a caret-less
; app (Electron/UWP/Chromium — exactly where CaretGetPos fails and UIA is
; slowest) paid a fresh out-of-proc UIA COM round-trip. Pinned by
; test_audit_2026_07_20_batch4.ahk so a future debounce change cannot silently
; make it dead again.
global TOOLTIP_POSITION_CACHE_MS := 600

; Dequeue state — items that have per-row expiry deadlines. Canonical algorithm:
; _shared/modules/tooltip/dequeue.js (SPEC.md § 7.1). When rows carry distinct non-zero
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
    ; SetTimer bypasses native Suspend, like both sibling timers in this file
    ; already guard against. Firing while paused would call _ResetPrefixBuffer()
    ; below and mutate hotstring-engine state behind a driver the user believes
    ; is off — the suspend reactor has already hidden the tooltip and reset the
    ; engine, so there is nothing left for this timer to do.
    if A_IsSuspended
        return
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

_TooltipDeferredShowFn() {
    global _TooltipPendingActive, _TooltipPendingItems, _TooltipPendingDurationSec
    global _TooltipPendingArmSafety
    if !_TooltipPendingActive
        return
    Items := _TooltipPendingItems
    DurationSec := _TooltipPendingDurationSec
    ArmSafety := _TooltipPendingArmSafety
    _TooltipPendingActive := false
    _TooltipPendingItems := 0
    _TooltipPendingDurationSec := 0
    _TooltipPendingArmSafety := true
    if A_IsSuspended
        return
    _TooltipShowNow(Items, DurationSec, ArmSafety)
}

; Dequeue poll timer — runs every 100 ms while a dequeue cycle is active.
; Polling avoids the AHK v2 issue where one-shot timers armed from an
; InputHook OnChar thread never fire: the repeating timer is registered
; from the main script body at startup and always runs in the main thread.
_TooltipDequeuePollFn() {
    global _TooltipDequeueItems, _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipDequeueActive
    ; SetTimer callbacks BYPASS native Suspend (it only disarms hotkeys/hotstrings),
    ; so this 100 ms poll can otherwise rebuild/reveal a tooltip while the driver is
    ; paused — up to ~5 times inside the 500 ms _SuspendStateWatchdog gap when suspend
    ; is toggled OUTSIDE ToggleSuspend. « pause = AHK éteint »: bail out and leave the
    ; items untouched; they are re-evaluated on resume or torn down by the watchdog.
    if A_IsSuspended
        return
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
; Start at the sentinel 0 (not the real 0.2 / 0.05): Tooltip_UpdateStyles() above
; overwrites these from the shared UI_TIMEOUT_* values at boot, so if that copy
; ever fails to run the tooltip dismisses with no decrement/floor — an obvious
; symptom — instead of a plausible hardcoded value masking the missing load.
global _TOOLTIP_TIMEOUT_DECREMENT_SEC := 0
global _TOOLTIP_TIMEOUT_FLOOR_SEC := 0

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
; ArmSafety=false opts this render out of the _TOOLTIP_SAFETY_SEC auto-hide
; deadline. Pass it as an argument — never by cancelling _TooltipTimerFn after
; this call returns: rendering is deferred by TOOLTIP_RENDER_DEBOUNCE_MS, so the
; timer does not exist yet at that point and the cancel silently does nothing.
TooltipShow(Items, DurationSec := 0, ArmSafety := true) {
    global _TooltipPendingActive, _TooltipPendingItems, _TooltipPendingDurationSec
    global _TooltipPendingGeneration, TOOLTIP_RENDER_DEBOUNCE_MS, _TooltipPendingArmSafety

    if A_IsSuspended {
        TooltipHide("Suspend", true)
        return
    }
    ; Each new keystroke supersedes the prior request. Negative SetTimer is a
    ; one-shot debounce: continuous typing keeps the expensive GUI/UIA work off
    ; the hot path, and the newest preview is rendered once the user pauses.
    _TooltipPendingGeneration += 1
    _TooltipPendingItems := Items
    _TooltipPendingDurationSec := DurationSec
    _TooltipPendingArmSafety := ArmSafety
    _TooltipPendingActive := true
    SetTimer(_TooltipDeferredShowFn, -TOOLTIP_RENDER_DEBOUNCE_MS)
}

; Runs from the debounced timer, never directly from the prefix watcher.
; ArmSafety is threaded from TooltipShow so a caller can opt out of the
; _TOOLTIP_SAFETY_SEC auto-hide deadline across the debounce boundary.
_TooltipShowNow(Items, DurationSec := 0, ArmSafety := true) {

    ; While the script is suspended nothing may paint — « pause = AHK éteint ».
    ; The per-callback input guards normally prevent reaching here, but the
    ; dequeue poll timer and async LLM callers can still land mid-pause, so tear
    ; down anything still up and refuse the show.
    if A_IsSuspended {
        TooltipHide("Suspend", true)
        return
    }

    ; While a real prediction OWNS the shared surface, refuse any incidental rebuild
    ; that would clobber it — chiefly the hotstring prefix watcher's per-keystroke
    ; preview lookups. The prediction itself renders through _TooltipBuildGuiLlm
    ; (never here), and the LLM loading spinner sets _LLM_Tooltip_Loading before
    ; calling us, so neither is blocked; only hotstring previews are deferred until
    ; the prediction is dismissed. NOTE: blocking the NewShow hide alone (in
    ; TooltipHide) is not enough — this function rebuilds the Gui regardless, so the
    ; bail must live here too.
    if LLM_TooltipOwnsSurface()
        return

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
    ; A rendering pass owns only the generation it created.  `_TooltipBuildGui`
    ; and `_TooltipResolvePosition` can pump/re-enter through GUI/COM, so a newer
    ; TooltipShow or TooltipHide may complete before this invocation resumes.
    ; Never let the older invocation arm a timer, present, or clean up the newer
    ; surface after that point.
    RenderGeneration := _TooltipGeneration
    _TooltipLastItems := Items

    ; Timer already cancelled by TooltipHide("NewShow") above — this is a
    ; belt-and-suspenders guard in case TooltipHide returned early for any reason.
    SetTimer(_TooltipTimerFn, 0)

    _hpBuild := HotPath_Now()
    try {
        _TooltipBuildGui(Items)
    } catch {
        if (RenderGeneration == _TooltipGeneration)
            TooltipHide("BuildFail", true)
        return
    }
    HotPath_LogIfSlow("Tooltip.Build", _hpBuild, Items.Length . " item(s)")
    if (RenderGeneration != _TooltipGeneration)
        return

    ; Cache in a local variable to prevent "Invalid index" crashes if a
    ; concurrent TooltipHide clears the global array during the
    ; _TooltipResolvePosition yield point.
    Rows := _TooltipRowGuis
    if (Rows.Length == 0) {
        if (RenderGeneration == _TooltipGeneration)
            TooltipHide("NoRows", true)
        return
    }

    ; AHK-34: the UIA COM call is the hottest blocking call on this path;
    ; wrap it so a slow resolve surfaces in HotPath slow-segment logs
    _hpResolve := HotPath_Now()
    Pos := _TooltipResolvePosition()
    HotPath_LogIfSlow("Tooltip.ResolvePos", _hpResolve, "")
    if (RenderGeneration != _TooltipGeneration)
        return
    Row := Rows[1]
    ; Snapshot generation before present so any exception still arms the timer
    ; correctly and the ghost cannot outlive the safety deadline.
    _TooltipTimerGeneration := _TooltipGeneration
    _hpPresent := HotPath_Now()
    try {
        _TooltipPresentStack(Pos, Row, ArmSafety)
    } catch {
        if (RenderGeneration == _TooltipGeneration)
            TooltipHide("ShowFail", true)
        return
    }
    HotPath_LogIfSlow("Tooltip.Present", _hpPresent, "")
    if (RenderGeneration != _TooltipGeneration)
        return

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
;   3. Hand Gui object destruction to a one-shot timer. DWM/GDI resource
;      release is not allowed to extend the keyboard-path critical section.
;
; INVARIANT — MUST STAY NON-BLOCKING: the hotstring fire path reaches here under
; the Critical held by _OnPrefixChar (via HSE_DispatchMatch -> _ResetPrefixBuffer
; -> TooltipHide). Holding Critical across a Sleep/WinWait/ClipWait/MsgSleep would
; yield the thread and freeze the low-level keyboard hook for that duration,
; dropping keys typed right after an expansion. This function performs only the
; immediate visual hide and state hand-off. Gui resource destruction is deferred
; onto a one-shot timer. Do NOT add a fade-out, animation await, or any blocking
; call here. The meta test test_tooltip_hide_non_blocking.ahk pins this contract.
TooltipHide(DbgTag := "?", Force := false) {
    global _TooltipGui, _TooltipRowGuis, _TooltipBorderGui
    global _TooltipShownHwnds, _TooltipShownBorderHwnds
    global _TooltipDequeueItems, _TooltipDequeueActive
    global _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipPendingActive, _TooltipPendingItems, _TooltipPendingDurationSec
    global _TooltipPendingGeneration
    ; Diagnostic (debug-only): whenever an LLM loading/prediction tooltip is on
    ; screen, record WHO hid it. ``DbgTag`` names the caller — TimerFn (auto-hide),
    ; NewShow (a fresh TooltipShow superseded it), PollEmpty (dequeue), LLM
    ; (deliberate LLM_TooltipHide), etc. This is the primary lens for the
    ; "prediction vanished the instant it appeared" class of bug.
    global _LLM_Tooltip_Visible, _LLM_Tooltip_Loading, _LLM_Tooltip_ShownAt
    _llm_on_screen  := IsSet(_LLM_Tooltip_Visible) and (_LLM_Tooltip_Visible or _LLM_Tooltip_Loading)
    _llm_was_visible := IsSet(_LLM_Tooltip_Visible) and _LLM_Tooltip_Visible
    _llm_was_loading := IsSet(_LLM_Tooltip_Loading) and _LLM_Tooltip_Loading
    ; Surface ownership: while a REAL prediction occupies the shared surface, the
    ; hotstring autocomplete lifecycle must never tear it down — not its buffer
    ; resets (ResetBuf), lookup misses (LookupNoMatch/LookupLen0), nor a new lookup
    ; (NewShow). Those fire from the prefix watcher's own timers and per-keystroke
    ; scans, so without this a background reset blanked a prediction the user was
    ; calmly reading ("arrêté, rien touché"). This holds for the WHOLE display, not
    ; just the minimum-display window. Only authoritative hides pass: explicit LLM
    ; accept/dismiss ("LLM"), the prediction's own auto-hide timer ("TimerFn"), and
    ; driver suspension ("Suspend"). A real keystroke / pointer move dismisses via
    ; LLM_TooltipHide, i.e. tag "LLM", so user dismissal is unaffected.
    if (DbgTag != "LLM" and DbgTag != "Suspend" and DbgTag != "TimerFn" and LLM_TooltipOwnsSurface()) {
        ; Diagnostic: the prediction is PROTECTED — it stays on screen. An idle
        ; prediction should emit KEPT for every background hotstring reset and never
        ; a HIDE, so this line is the lens for "did it stay or vanish?".
        if _llm_on_screen
            try LoggerDebug("LLM.tt", "KEPT: hide tag={1} ignored — a prediction owns the surface.", DbgTag)
        return
    }
    ; A "TimerFn"/"Suspend" hide tears the surface down without routing through
    ; LLM_TooltipHide (which is what normally clears ownership). Clear the flags here
    ; so a later hotstring preview is not blocked forever by a stale "visible" flag.
    if ((DbgTag == "TimerFn" or DbgTag == "Suspend") and _llm_was_visible) {
        _LLM_Tooltip_Visible := false
        _LLM_Tooltip_Loading := false
        _LLM_Tooltip_ShownAt := 0
    }
    ; This hide actually proceeds (it passed the ownership guard) — record WHO tore
    ; the surface down. For a shown prediction the only expected tags here are
    ; "LLM" (user keystroke / pointer / accept), "TimerFn" (auto-hide), "Suspend".
    if _llm_on_screen
        try LoggerDebug("LLM.tt", "HIDE tag={1} force={2} (was visible={3} loading={4}).",
            DbgTag, (Force ? "true" : "false"),
            (_llm_was_visible ? "true" : "false"), (_llm_was_loading ? "true" : "false"))
    ; During an active dequeue cycle the poll timer owns the tooltip lifecycle.
    ; External callers (prefix watcher resets, lookup misses) must not interrupt
    ; it — they would hide the post-expansion rows before their time.
    if (!Force and _TooltipDequeueActive)
        return
    ; A hide is authoritative over a queued preview. Stop the debounce before
    ; tearing down the current surface so a stale timer cannot resurrect it.
    _TooltipPendingGeneration += 1
    _TooltipPendingActive := false
    _TooltipPendingItems := 0
    _TooltipPendingDurationSec := 0
    SetTimer(_TooltipDeferredShowFn, 0)
    ; Hiding is a render transition too. Invalidate any renderer currently
    ; waiting in UIA/GUI work before it can resume and resurrect this surface.
    _TooltipGeneration += 1
    _TooltipTimerGeneration := _TooltipGeneration
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

    ; Detach ownership BEFORE scheduling destruction. A subsequent show receives
    ; fresh globals and cannot be torn down by this old generation's worker.
    RetiredBorder := _TooltipBorderGui
    RetiredRows := _TooltipRowGuis
    RetiredGeneration := _TooltipGeneration
    _TooltipBorderGui := 0
    _TooltipGui := 0
    _TooltipRowGuis := []
    _TooltipShownHwnds := []
    _TooltipShownBorderHwnds := []
    SetTimer(_TooltipDisposeRetired.Bind(RetiredBorder, RetiredRows, RetiredGeneration), -1)
}

; Releases hidden Gui objects after TooltipHide has returned to the keyboard
; caller. The captured objects are never read from global ownership state, so a
; newer render cannot be disposed by an older hide timer.
_TooltipDisposeRetired(RetiredBorder, RetiredRows, RetiredGeneration) {
    try {
        if RetiredBorder
            try RetiredBorder.Destroy()
        if (RetiredRows is Array) {
            for , Row in RetiredRows {
                try Row.Gui.Destroy()
            }
        }
    } catch as Err {
        try LoggerWarn("Tooltip", "Deferred tooltip teardown failed for generation {1}: {2}.", RetiredGeneration, Err.Message)
    }
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

