; ui/tooltip/core.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / Core Engine + Public API
; DESCRIPTION:
; Tooltip GUI state, font/style constants, the dequeue + safety timers, style refresh, and the public API (TooltipShow / TooltipHide / TooltipIsVisible).
;
; Split out of the former infra/tooltip.ahk (the module split); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.
; ==============================================================================





; Single publication owner for the visible content, border, raw HWND backstops,
; position and render generation. Builders never touch it: they prepare a
; detached record and _TooltipPresentStack swaps this ONE reference only after
; the final owner/context/deadline checks. That removes the former partial-state
; class where a re-entrant renderer could observe a new Gui with an old border.
; Shape while visible:
;   { Gui, Rows, Border, Pos, ContentHwnds, BorderHwnds, Generation,
;     LlmPresented }
global _TooltipActiveSurface := 0

; Generation counter incremented on every TooltipShow. The timer callback
; compares its captured generation against this value and aborts if they
; differ — prevents a stale timer from hiding a tooltip that was rebuilt
; after the timer was armed but before it fired.
global _TooltipGeneration := 0
global _TooltipTimerGeneration := 0

; Tooltip GUI creation and UIA positioning can take tens of milliseconds. The
; prefix watcher calls TooltipShow on every character, so debounce render work
; until typing is idle instead of running GDI/COM in the keyboard callback.
;
; The pending request is ONE immutable record. Publishing its fields separately
; allowed a re-entrant TooltipShow to splice Items from request B to the
; Duration/Origin of request A, while an older deferred callback could clear B.
; RequestSerial follows the record through the final pixel commit, so an A
; callback that already detached its record still loses after B is requested.
global _TooltipPendingRequest := 0
global _TooltipRequestSerial := 0
global TOOLTIP_RENDER_DEBOUNCE_MS := 75
; A due owner cannot erase a newer request while that request is preparing, but
; consuming the one-shot would leave the old surface immortal if preparation is
; later refused. Retry with the same immutable generation/surface owner.
global _TOOLTIP_OWNER_RETRY_MS := 25
; Carries the caller's safety-deadline choice ACROSS the render debounce. A
; caller that must outlive the 3 s auto-hide (the LLM spinner, whose inference
; legitimately runs longer) cannot express that by cancelling _TooltipTimerFn
; after TooltipShow returns: the timer is not armed until _TooltipPresentStack
; runs, TOOLTIP_RENDER_DEBOUNCE_MS later, so such a cancel is a silent no-op.
; Tick at which the render was REQUESTED, carried across the debounce so a row's
; expiry is anchored at the request instead of at present time.
;
; The engine's time-activation gate is anchored on the keystroke
; (LastSentCharacterKeyTime), while _TooltipShowNow used to anchor the row's
; deadline on A_TickCount read AFTER both debounces AND after the GUI build and
; the UIA position resolve — measured at up to 113 ms on their own. The fixed
; _TOOLTIP_TIMEOUT_DECREMENT_SEC could not absorb a variable latency, so the
; preview outlived the window it was previewing: the user saw the suggestion,
; pressed the magic key, and nothing was emitted.

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

; Minimum physical-input idle before the UIA position probe may run. The render
; debounce above is a COALESCING timer, not an idle gate: it decides when the
; deferred render happens, not whether the user is still mid-burst, and the work
; it defers runs on the one thread that dispatches keystrokes. Same reasoning as
; UIA_SELECTION_IDLE_REQUIRED_MS in modules/keymap/layout.ahk.
;
; MUST STAY BELOW the combined debounce that gates the preview path
; (_PREFIX_RENDER_DEBOUNCE_MS 150 + TOOLTIP_RENDER_DEBOUNCE_MS 75 = ~225 ms).
; The value copied from the selection poll was 250, but that poll has no debounce
; in front of it while this probe does: a preview render cannot happen earlier
; than 225 ms after the last character, so a 250 ms gate rejected EVERY preview.
; Stage 2 of the position cascade — and with it the lazy timeout clamp — was
; structurally unreachable on the only path it exists for, and every preview in a
; caret-less app (Electron/Chromium/UWP) anchored at the bottom of the window
; instead of under the caret. Pinned by test_tooltip_uia_gate_reachable.ahk.
global TOOLTIP_UIA_IDLE_REQUIRED_MS := 200

; How long a process stays marked as not answering UIA usefully. Generous
; re-probe window, mirroring _UIA_NO_TP_TTL_MS in modules/keymap/layout.ahk:
; without it a UIA-hostile app pays a full timeout every cache expiry, forever.
global TOOLTIP_UIA_HOSTILE_TTL_MS := 30000
global _TooltipUiaHostileCache := Map()

; Clamps for UIA's own waits, applied lazily on first probe. Windows defaults
; are 2000 ms (transaction) and 20000 ms (connection); the library notes the
; floor is around 50 ms. The worst stall measured on this driver — 2560 ms in
; Tooltip.ResolvePos — is the 2000 ms default plus overhead, so bounding these
; is what turns an unbounded cross-process wait into a bounded one.
global UIA_TRANSACTION_TIMEOUT_MS := 120
global UIA_CONNECTION_TIMEOUT_MS := 120

; Render accounting. HotPath only ever prints the renders that exceed its 5 ms
; floor, which gives the log a numerator with no denominator: "342 slow
; Tooltip.Present events over four days" cannot be read as good or catastrophic
; without knowing whether the sessions rendered four hundred previews or forty
; thousand. Worse, _TooltipResolvePosition has five distinct exits and the log
; showed which one was taken exactly never — so "the position cache never hits"
; and "UIA never answers" were indistinguishable, and both were guessed at.
; These two counters make the slow-render RATIO and the cascade's real exit
; distribution readable from an ordinary production log with no extra tooling.
; They are bumped only on paths that already cost milliseconds.
global _TooltipRenderCount := 0
global _TooltipResolveExits := Map()
; How many presented renders between two accounting lines. Large enough that the
; line is rare next to the slow-segment warnings it contextualises, small enough
; that a short session still emits one.
global _TOOLTIP_STATS_LOG_EVERY := 100

; Dequeue state — items that have per-row expiry deadlines. Canonical algorithm:
; _shared/modules/tooltip/dequeue.js (SPEC.md § 7.1). When rows carry distinct non-zero
; DurationSec values, TooltipShow stores the full item list here with a
; wrap-safe origin tick plus duration. The dequeue poll timer removes
; expired rows and re-renders the surviving stack so a short row disappears first
; and longer rows stay visible (e.g. output1@1s + output2@2s → both 0.8s, then
; output2 alone for another 1.0s after the 0.2s decrement).
; Shape: Array of { ..item fields.., ExpireOriginTick: integer,
;                   ExpireDurationMs: integer }
; 0 when no dequeue cycle is active (all items have DurationSec = 0).
global _TooltipDequeueItems := 0
; Exact one-shot for the earliest canonical absolute row deadline. It is distinct
; from the always-armed 100 ms watchdog so arming a precise expiry never converts
; that repeating timer into a one-shot. Replaced/cancelled with surface ownership.
global _TooltipDequeueDeadlineTimer := 0

; When true, TooltipHide() calls from external sources (prefix watcher resets,
; lookup misses, renderer) are silently ignored — the dequeue poll timer owns
; the tooltip lifecycle and will hide it at the right time. Only the poll timer
; and the safety timer (via _TooltipTimerFn) are authorised to call
; TooltipHide() during an active dequeue cycle.
global _TooltipDequeueActive := false

; Timer callbacks must have stable identities. Named lifecycle callbacks are
; cancelled by name; each deferred-show request stores its own bound token in
; the immutable request record so replacement/cancellation uses that exact Fn.
_TooltipTimerFn() {
    global _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipActiveSurface
    ; SetTimer bypasses native Suspend, like both sibling timers in this file
    ; already guard against. The suspend reactor has already hidden the tooltip
    ; and reset the engine, so a fire while paused would only tear down a
    ; surface that is already gone.
    if A_IsSuspended
        return
    ExpectedGeneration := 0
    ExpectedSurface := 0
    PreviousCritical := Critical("On")
    try {
        if (_TooltipTimerGeneration != _TooltipGeneration)
            return
        ExpectedGeneration := _TooltipGeneration
        ExpectedSurface := _TooltipActiveSurface
    } finally {
        Critical(PreviousCritical)
    }
	_TooltipTimerHideOrRetry(ExpectedGeneration, ExpectedSurface)
    ; The preview buffer is deliberately NOT reset here.
    ;
    ; This timer means "the tooltip has been on screen a while", not "the user
    ; abandoned the word". Nothing was typed, nothing moved the caret, and the
    ; ENGINE still holds the word — so wiping the preview made the two buffers
    ; describe different text after any mid-word pause longer than the display
    ; duration. The visible symptom was a suggestion that never came back for a
    ; trigger the engine would still have expanded: the preview restarted from
    ; empty while the engine kept accumulating, so no later keystroke could
    ; reproduce the prefix the tooltip needed.
    ;
    ; The preview is reset by the events that genuinely invalidate it — a
    ; terminator, a caret move, a fire — each of which resets the engine too.
}

_TooltipTimerHideOrRetry(ExpectedGeneration, ExpectedSurface) {
	global _TooltipGeneration, _TooltipActiveSurface
	global _TOOLTIP_OWNER_RETRY_MS
	if A_IsSuspended
		return false
	; TooltipHide refuses an exact old-surface timeout while a newer request is
	; pending. That refusal is safe only if the one-shot remains live.
	if TooltipHide("TimerFn", true, ExpectedGeneration, ExpectedSurface)
		return true
	RetryCurrentOwner := false
	PreviousCritical := Critical("On")
	try {
		RetryCurrentOwner := _TooltipSurfaceOwnerMatches(
			ExpectedGeneration, _TooltipGeneration,
			ExpectedSurface, _TooltipActiveSurface)
	} finally {
		Critical(PreviousCritical)
	}
	if RetryCurrentOwner
		SetTimer(_TooltipTimerHideOrRetry.Bind(
			ExpectedGeneration, ExpectedSurface), -_TOOLTIP_OWNER_RETRY_MS)
	return false
}

_TooltipDeferredShowFn(ExpectedSerial) {
	global _TooltipPendingRequest
	Request := 0
	; Snapshot one complete tuple atomically. Keep it globally visible until it
	; either pixel-commits or fails: old surface timers/polls must see that a newer
	; output is pending and may not cancel it during GUI/UIA work.
	PreviousCritical := Critical("On")
	try {
		if !IsObject(_TooltipPendingRequest)
			return
		if (_TooltipPendingRequest.Serial != ExpectedSerial)
			return
		Request := _TooltipPendingRequest
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if A_IsSuspended
			return
		_TooltipShowNow(Request.Items, Request.DurationSec,
			Request.ArmSafety, Request.OriginMs, Request.Serial,
			Request.CommitFn)
	} finally {
		; Failure/refusal retires only this tuple. If B replaced A during a
		; yield, A cannot erase B here.
		PreviousCritical := Critical("On")
		try {
			if (IsObject(_TooltipPendingRequest)
				and ObjPtr(_TooltipPendingRequest) == ObjPtr(Request))
				_TooltipPendingRequest := 0
		} finally {
			Critical(PreviousCritical)
		}
	}
}

; Dequeue poll timer — runs every 100 ms while a dequeue cycle is active.
; Polling avoids the AHK v2 issue where one-shot timers armed from an
; InputHook OnChar thread never fire: the repeating timer is registered
; from the main script body at startup and always runs in the main thread.
_TooltipSurfaceOwnerMatches(ExpectedGeneration, CurrentGeneration,
    ExpectedSurface, CurrentSurface) {
    return (ExpectedGeneration == CurrentGeneration
        and IsObject(ExpectedSurface) and IsObject(CurrentSurface)
        and ObjPtr(ExpectedSurface) == ObjPtr(CurrentSurface)
        and ExpectedSurface.Generation == ExpectedGeneration)
}

; A -1 serial marks a direct/non-debounced presenter. Deferred TooltipShow
; requests carry a non-negative monotonic serial so an old A callback cannot commit
; after request B was published, even while B is still waiting on its debounce.
_TooltipRequestOwnerMatches(ExpectedSerial, CurrentSerial) {
    return ExpectedSerial == -1 or ExpectedSerial == CurrentSerial
}

_TooltipDequeueDeadlineFn(ExpectedGeneration, ExpectedSurface) {
    global _TooltipGeneration, _TooltipActiveSurface
    global _TooltipDequeueDeadlineTimer
	global _TooltipPendingRequest, _TOOLTIP_OWNER_RETRY_MS
    if A_IsSuspended
        return
    PreviousCritical := Critical("On")
    try {
        if !_TooltipSurfaceOwnerMatches(ExpectedGeneration,
            _TooltipGeneration, ExpectedSurface, _TooltipActiveSurface)
            return
		; Preserve this exact owner while request B is between publication and
		; pixel commit. The repeating watchdog is only 100 ms precise; rearming the
		; canonical one-shot prevents a visibly stale interval after B is refused.
		if IsObject(_TooltipPendingRequest) {
			_TooltipDequeueDeadlineTimer :=
				_TooltipDequeueDeadlineFn.Bind(
					ExpectedGeneration, ExpectedSurface)
			SetTimer(_TooltipDequeueDeadlineTimer,
				-_TOOLTIP_OWNER_RETRY_MS)
			return
		}
        ; Clear only this still-current one-shot owner. A newer render has a
        ; distinct surface token and leaves its replacement callback untouched.
        _TooltipDequeueDeadlineTimer := 0
    } finally {
        Critical(PreviousCritical)
    }
    _TooltipDequeuePollFn(ExpectedGeneration, ExpectedSurface)
}

_TooltipDequeuePollFn(ExpectedGeneration := unset, ExpectedSurface := 0) {
    global _TooltipDequeueItems, _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipDequeueActive, _TooltipActiveSurface
    global _TooltipPendingRequest
    ; SetTimer callbacks BYPASS native Suspend (it only disarms hotkeys/hotstrings),
    ; so this 100 ms poll can otherwise rebuild/reveal a tooltip while the driver is
    ; paused — up to ~5 times inside the 500 ms _SuspendStateWatchdog gap when suspend
    ; is toggled OUTSIDE ToggleSuspend. « pause = AHK éteint »: bail out and leave the
    ; items untouched; they are re-evaluated on resume or torn down by the watchdog.
    if A_IsSuspended
        return false
    ItemsSnapshot := 0
    PreviousCritical := Critical("On")
    try {
        if IsObject(_TooltipPendingRequest)
            return false
        if !IsSet(ExpectedGeneration) {
            ExpectedGeneration := _TooltipGeneration
            ExpectedSurface := _TooltipActiveSurface
        }
        if !_TooltipSurfaceOwnerMatches(ExpectedGeneration,
            _TooltipGeneration, ExpectedSurface, _TooltipActiveSurface)
            return false
        if (_TooltipTimerGeneration != ExpectedGeneration
            or _TooltipDequeueItems == 0
            or !IsObject(_TooltipDequeueItems))
            return false
        ItemsSnapshot := _TooltipDequeueItems
    } finally {
        Critical(PreviousCritical)
    }
    Now := A_TickCount
    ; Check if the earliest deadline has passed.
    NeedDequeue := false
    for , Item in ItemsSnapshot {
        if (Item.ExpireDurationMs > 0
            and TickExpired(Item.ExpireOriginTick, Item.ExpireDurationMs, Now)) {
            NeedDequeue := true
            break
        }
    }
    if !NeedDequeue
        return
    Remaining := []
    for , Item in ItemsSnapshot {
        if (Item.ExpireDurationMs == 0
            or !TickExpired(Item.ExpireOriginTick, Item.ExpireDurationMs, Now))
            Remaining.Push(Item)
    }
    if (Remaining.Length == 0) {
        TooltipHide("PollEmpty", true, ExpectedGeneration, ExpectedSurface)
        ; The preview buffer is deliberately NOT reset here — identical reasoning
        ; to _TooltipTimerFn above, of which this is the per-row sibling.
        ;
        ; A row expiring means "this has been on screen long enough", not "the
        ; user abandoned the word". Nothing was typed, nothing moved the caret,
        ; and the ENGINE still holds the word — so wiping the preview alone left
        ; the two buffers describing different text, and no later keystroke in
        ; that word could reproduce the prefix the tooltip needed.
        ;
        ; The preview is reset by the events that genuinely invalidate it — a
        ; terminator, a caret move, a fire — each of which resets the engine too.
        return true
    }
    ; Rebuild without the expired rows. Preserve the origin/duration pair so the poll
    ; timer continues tracking the remaining deadlines correctly.
    RebuildItems := []
    for , Item in Remaining {
        Copy := {}
        for k, v in Item.OwnProps()
            Copy.%k% := v
        Copy.DurationSec := 0
        RebuildItems.Push(Copy)
    }
    _TooltipDequeueRebuild(RebuildItems, ExpectedGeneration, ExpectedSurface)
    return true
}

; TooltipDequeueInit() must be called once at script startup (from ErgoptiPlus.ahk)
; to arm the poll timer. Code at file scope in #Include'd files does not execute
; in AHK v2 when the include appears after the auto-execute section has ended.
TooltipDequeueInit() {
    SetTimer(_TooltipDequeuePollFn, 100)
}

; Style constants — sourced from infra/ui_style.ahk (included before this file
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

; Raw HWND backstops live inside each immutable surface record. The retired
; record therefore carries exactly the handles its deferred disposer owns;
; candidate preparation never appends into the active owner's tracking state.

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
TooltipShow(Items, DurationSec := 0, ArmSafety := true, CommitFn := 0) {
	global _TooltipPendingRequest, _TooltipRequestSerial
	global TOOLTIP_RENDER_DEBOUNCE_MS

    if A_IsSuspended {
        TooltipHide("Suspend", true)
        return
    }
	; Stamp and allocate before the transaction: neither action touches shared
	; state, and no GUI/COM work is allowed under Critical.
	Request := {
		Items: Items,
		DurationSec: DurationSec,
		ArmSafety: ArmSafety,
		CommitFn: CommitFn,
		; Everything after this read (debounce, Gui build, UIA resolve) consumes
		; the row's canonical interval; the render must never re-anchor it.
		OriginMs: A_TickCount,
		Serial: 0,
		TimerFn: 0
	}
	; Each new keystroke supersedes the prior request. State publication and timer
	; ownership are one short transaction; the deferred callback takes the same
	; immutable record under the same barrier.
	PreviousCritical := Critical("On")
	try {
		OldRequest := _TooltipPendingRequest
		if (IsObject(OldRequest) and OldRequest.HasOwnProp("TimerFn")
			and IsObject(OldRequest.TimerFn))
			SetTimer(OldRequest.TimerFn, 0)
		_TooltipRequestSerial += 1
		Request.Serial := _TooltipRequestSerial
		Request.TimerFn := _TooltipDeferredShowFn.Bind(Request.Serial)
		_TooltipPendingRequest := Request
		SetTimer(Request.TimerFn, -TOOLTIP_RENDER_DEBOUNCE_MS)
	} finally {
		Critical(PreviousCritical)
	}
}

; Runs from the debounced timer, never directly from the prefix watcher.
; ArmSafety is threaded from TooltipShow so a caller can opt out of the
; _TOOLTIP_SAFETY_SEC auto-hide deadline across the debounce boundary.
; OriginMs is the tick at which the render was REQUESTED. Row deadlines are
; measured from it, never from present time: the engine's time-activation gate
; runs from the keystroke, so anchoring the preview on the render would let it
; promise an expansion the engine has already refused. An omitted origin falls
; back to present time; tick 0 is a valid request origin at counter rollover.
_TooltipShowNow(Items, DurationSec := 0, ArmSafety := true, OriginMs?,
		RequestSerial := -1, CommitFn := 0) {
	global _TooltipGeneration
	EntryGeneration := _TooltipGeneration
	OwnedPresentation := HasMethod(CommitFn, "Call")

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
    ; (never here), and both prediction/loading candidates carry an owned commit
    ; callback, so neither is blocked; only hotstring previews are deferred until
    ; the prediction is dismissed. NOTE: blocking the NewShow hide alone (in
    ; TooltipHide) is not enough — this function rebuilds the Gui regardless, so the
    ; bail must live here too.
    if (LLM_TooltipOwnsSurface() and !OwnedPresentation)
        return

    ; Normalise to an Array of { Text, ColorHex } objects.
    if !IsObject(Items) {
        Items := [{ Text: Items, ColorHex: "", DurationSec: DurationSec }]
    } else if !Items.HasMethod("Push") {
        Items := [Items]
    }

    ; A canonical FireDecision may arrive with an absolute origin/duration pair.
    ; The render debounce is part of that interval, not permission to restart it:
    ; discard rows that have already expired before doing any GUI/UIA work.
    if !OwnedPresentation
		Items := _TooltipFilterUnexpiredDeadlineItems(Items)
    if (Items.Length == 0) {
        TooltipHide("DeadlineExpiredBeforeBuild", true, EntryGeneration,
            unset, RequestSerial)
        return
    }
    ; The buffer can change while this request waits behind either debounce.
    ; Ask the engine-owned oracle instead of reproducing its matching rules here.
    if !OwnedPresentation {
		DecisionCurrent := false
		try DecisionCurrent := _TooltipDecisionItemsStillCurrent(Items)
		catch Error as Err {
			_UiOracleReportError(
				"Visible-decision freshness check failed: " . Err.Message)
			TooltipHide("DecisionCheckFailBeforeBuild", true, EntryGeneration,
				unset, RequestSerial)
			return
		}
		if !DecisionCurrent {
			TooltipHide("DecisionStaleBeforeBuild", true, EntryGeneration,
				unset, RequestSerial)
			return
		}
    }
	; Convert durations to immutable origin/duration pairs before any GUI/UIA
	; work. The common pixel commit resolves their CURRENT remainder atomically
	; with timer publication; no sampled remainder crosses an interruptible call.
	if !IsSet(OriginMs)
		OriginMs := A_TickCount
	LifecyclePlan := _TooltipCreateLifecyclePlan(
		Items, DurationSec, OriginMs)

    ; Reserve the render without tearing down the current surface. The candidate
    ; is built off-global and the common presenter later swaps one surface record;
    ; if GUI/UIA pumps a newer renderer, this generation loses without touching
    ; either the old owner or the newer winner. Cancel the prior lifecycle timers
    ; now so the old owner cannot disappear halfway through candidate preparation.
    global _TooltipGeneration, _TooltipTimerGeneration, _TooltipRequestSerial
    global _TooltipDequeueItems, _TooltipDequeueActive
    global _TooltipDequeueDeadlineTimer
    PreviousCritical := Critical("On")
    try {
        if (_TooltipGeneration != EntryGeneration)
            return
        if !_TooltipRequestOwnerMatches(RequestSerial, _TooltipRequestSerial)
            return
        _TooltipGeneration += 1
        RenderGeneration := _TooltipGeneration
        _TooltipTimerGeneration := RenderGeneration
        SetTimer(_TooltipTimerFn, 0)
        if IsObject(_TooltipDequeueDeadlineTimer)
            SetTimer(_TooltipDequeueDeadlineTimer, 0)
        _TooltipDequeueDeadlineTimer := 0
        _TooltipDequeueItems := 0
        _TooltipDequeueActive := false
    } finally {
        Critical(PreviousCritical)
    }
    ; A rendering pass owns only the generation it created.  `_TooltipBuildGui`
    ; and `_TooltipResolvePosition` can pump/re-enter through GUI/COM, so a newer
    ; TooltipShow or TooltipHide may complete before this invocation resumes.
    ; Never let the older invocation arm a timer, present, or clean up the newer
    ; surface after that point.
    _hpBuild := HotPath_Now()
    Row := 0
    try {
        Row := _TooltipBuildGui(Items)
    } catch {
        TooltipHide("BuildFail", true, RenderGeneration,
            unset, RequestSerial)
        return
    }
    HotPath_LogIfSlow("Tooltip.Build", _hpBuild, Items.Length . " item(s)")
    if (RenderGeneration != _TooltipGeneration
        or !_TooltipRequestOwnerMatches(
            RequestSerial, _TooltipRequestSerial)) {
        if IsObject(Row)
            _TooltipQueueSurfaceDisposal(
                _TooltipCreateDetachedSurface(Row, RenderGeneration))
        return
    }

    if !IsObject(Row) {
        TooltipHide("NoRows", true, RenderGeneration,
            unset, RequestSerial)
        return
    }

    ; AHK-34: the UIA COM call is the hottest blocking call on this path;
    ; wrap it so a slow resolve surfaces in HotPath slow-segment logs
    _hpResolve := HotPath_Now()
    Pos := _TooltipResolvePosition()
    HotPath_LogIfSlow("Tooltip.ResolvePos", _hpResolve, "")
    if (RenderGeneration != _TooltipGeneration
        or !_TooltipRequestOwnerMatches(
            RequestSerial, _TooltipRequestSerial)) {
        _TooltipQueueSurfaceDisposal(
            _TooltipCreateDetachedSurface(Row, RenderGeneration))
        return
    }
    _hpPresent := HotPath_Now()
    Presented := false
    try {
        Presented := _TooltipPresentStack(Pos, Row, ArmSafety,
			OwnedPresentation ? [] : Items,
			RenderGeneration, OwnedPresentation, RequestSerial, LifecyclePlan,
			CommitFn)
    } catch {
        TooltipHide("ShowFail", true, RenderGeneration,
            unset, RequestSerial)
        return
    }
    ; Drain sub-step attribution even when the final freshness/deadline commit
    ; refuses the reveal; otherwise its marks leak into the next render.
    HotPath_LogIfSlow("Tooltip.Present", _hpPresent, HotPath_BreakdownDetail())
    if !Presented {
        TooltipHide("StaleBeforeReveal", true, RenderGeneration,
            unset, RequestSerial)
        return
    }
    ; Detail carries the per-sub-step attribution _TooltipPresentStack accumulated.
    ; Draining it above (rather than logging each step) is what makes the breakdown
    ; visible at all: every sub-step is below the profiler's 5 ms floor.
    ; Counted here and nowhere else: this is the exact point at which pixels are
    ; on screen, so it is the denominator every "Slow Tooltip.*" line needs.
    _TooltipNoteRenderPresented()
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
_TooltipReportDebug(Message) {
    if A_IsCritical {
        SetTimer(_TooltipReportDebug.Bind(Message), -1)
        return
    }
    try LoggerDebug("LLM.tt", "{1}", Message)
}

TooltipHide(DbgTag := "?", Force := false, ExpectedGeneration := unset,
        ExpectedSurface := unset, ExpectedRequestSerial := unset) {
    global _TooltipActiveSurface
    global _TooltipDequeueItems, _TooltipDequeueActive
    global _TooltipDequeueDeadlineTimer
    global _TooltipGeneration, _TooltipTimerGeneration
    global _TooltipPendingRequest, _TooltipRequestSerial
    RetiredSurface := 0
    DismissedRecord := 0
    RefusedReason := ""
    Authorized := false
    _llm_on_screen := false
    _llm_was_visible := false
    _llm_was_loading := false
    PreviousCritical := Critical("On")
    try {
        LlmRecord := IsSet(_LLM_TooltipPresentedFromSurface)
            ? _LLM_TooltipPresentedFromSurface(_TooltipActiveSurface) : 0
        _llm_on_screen := IsObject(LlmRecord)
        _llm_was_visible := _llm_on_screen
            and LlmRecord.Kind == "prediction"
        _llm_was_loading := _llm_on_screen
            and LlmRecord.Kind == "loading"
        if (IsSet(ExpectedRequestSerial) and ExpectedRequestSerial != -1
            and ExpectedRequestSerial != _TooltipRequestSerial) {
            RefusedReason := "request_owner"
        } else if (IsSet(ExpectedSurface)
            and IsObject(_TooltipPendingRequest)) {
            ; A timer/poll may have captured the old surface immediately before
            ; request B published. The exact surface can still match in that
            ; tiny gap, but B already owns the next output and must not be erased.
            RefusedReason := "pending_request"
        } else if (IsSet(ExpectedSurface)
            and (!IsObject(ExpectedSurface)
                or !IsObject(_TooltipActiveSurface)
                or ObjPtr(ExpectedSurface) != ObjPtr(_TooltipActiveSurface)
                or (IsSet(ExpectedGeneration)
                    and (!ExpectedSurface.HasOwnProp("Generation")
                        or ExpectedSurface.Generation
                            != ExpectedGeneration)))) {
            RefusedReason := "surface_owner"
        } else if (IsSet(ExpectedGeneration)
            and !IsSet(ExpectedSurface)
            and ExpectedGeneration != _TooltipGeneration) {
            RefusedReason := "generation"
        } else if (DbgTag != "LLM" and DbgTag != "Suspend"
            and DbgTag != "TimerFn" and _llm_was_visible) {
            RefusedReason := "llm_owner"
        } else if (!Force and _TooltipDequeueActive) {
            RefusedReason := "dequeue_owner"
        } else {
            Authorized := true
            if IsSet(HotstringPrefixWatcherClearVisibleDecisions) {
                ; Pure detach only. Privacy/keylogger work is emitted below after
                ; restoring the caller's interruptibility.
                try DismissedRecord := HotstringPrefixWatcherClearVisibleDecisions(false)
                catch Error as Err
                    _UiOracleReportError(
                        "Visible-decision clear failed: " . Err.Message)
            }
            if (IsObject(_TooltipPendingRequest)
                and _TooltipPendingRequest.HasOwnProp("TimerFn")
                and IsObject(_TooltipPendingRequest.TimerFn))
                SetTimer(_TooltipPendingRequest.TimerFn, 0)
            _TooltipPendingRequest := 0
            _TooltipRequestSerial += 1
            _TooltipGeneration += 1
            _TooltipTimerGeneration := _TooltipGeneration
            SetTimer(_TooltipTimerFn, 0)
            if IsObject(_TooltipDequeueDeadlineTimer)
                SetTimer(_TooltipDequeueDeadlineTimer, 0)
            _TooltipDequeueDeadlineTimer := 0
            _TooltipDequeueItems := 0
            _TooltipDequeueActive := false
            RetiredSurface := _TooltipActiveSurface
            if IsSet(_LLM_TooltipRetireSurfaceRecord)
                _LLM_TooltipRetireSurfaceRecord(RetiredSurface)
            ; Keep pixels and ownership truthful in one transaction. Deferring
            ; this exact raw hide left a window where the user still saw A while
            ; every semantic probe already reported no tooltip. Destruction and
            ; logging remain deferred; only bounded ShowWindow/GR_Hide calls run
            ; here against the captured owner.
            _TooltipHideSurfaceObjects(RetiredSurface)
            _TooltipActiveSurface := 0
        }
    } finally {
        Critical(PreviousCritical)
    }
    if (RefusedReason == "llm_owner" and _llm_on_screen)
        _TooltipReportDebug(Format(
            "KEPT: hide tag={1} ignored — a prediction owns the surface.",
            DbgTag))
    if !Authorized
        return false
    if _llm_on_screen
        _TooltipReportDebug(Format(
            "HIDE tag={1} force={2} (was visible={3} loading={4}).",
            DbgTag, (Force ? "true" : "false"),
            (_llm_was_visible ? "true" : "false"),
            (_llm_was_loading ? "true" : "false")))
    if (IsObject(DismissedRecord)
        and IsSet(HotstringPrefixWatcherEmitDismissedRecord)) {
        try HotstringPrefixWatcherEmitDismissedRecord(DismissedRecord)
        catch Error as Err
            _UiOracleReportError(
                "Visible-decision dismissal failed: " . Err.Message)
    }
    if IsSet(_LLM_TooltipScheduleMetricDrain)
        _LLM_TooltipScheduleMetricDrain()
    _TooltipQueueSurfaceDisposal(RetiredSurface)
    return true
}

; Releases hidden Gui objects after TooltipHide has returned to the keyboard
; caller. The captured objects are never read from global ownership state, so a
; newer render cannot be disposed by an older hide timer.
_TooltipDisposeRetired(RetiredSurface) {
    if !IsObject(RetiredSurface)
        return
    RetiredGeneration := RetiredSurface.HasOwnProp("Generation")
        ? RetiredSurface.Generation : 0
    try {
        ; Raw HWNDs go first while they are still the captured owner's handles.
        ; Gui.Destroy remains the object-level backstop afterward. Both lists are
        ; bounded by the surface itself, never by session length.
        if (RetiredSurface.BorderHwnds is Array) {
            for , Hwnd in RetiredSurface.BorderHwnds
                try GR_DestroyWindow(Hwnd)
        }
        if (RetiredSurface.ContentHwnds is Array) {
            for , Hwnd in RetiredSurface.ContentHwnds
                try GR_DestroyWindow(Hwnd)
        }
        if RetiredSurface.Border
            try RetiredSurface.Border.Destroy()
        if (RetiredSurface.Rows is Array) {
            for , Row in RetiredSurface.Rows {
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
    global _TooltipActiveSurface
    PreviousCritical := Critical("On")
    try {
        Surface := IsSet(_TooltipActiveSurface) ? _TooltipActiveSurface : 0
        LlmRecord := (IsObject(Surface)
            and IsSet(_LLM_TooltipPresentedFromSurface))
            ? _LLM_TooltipPresentedFromSurface(Surface) : 0
    } finally {
        Critical(PreviousCritical)
    }
    if !IsObject(Surface)
        return false
    return !IsObject(LlmRecord)
}

; Identity fence for post-presentation callbacks that intentionally run outside
; the pixel commit. Object identity closes ABA: even if a later render happens
; to reuse the same integer generation after a test/reset, it is not this owner.
TooltipSurfaceTokenIsCurrent(SurfaceToken) {
    global _TooltipActiveSurface, _TooltipGeneration
    if !IsObject(SurfaceToken)
        return false
    PreviousCritical := Critical("On")
    try {
        return (IsObject(_TooltipActiveSurface)
            and ObjPtr(_TooltipActiveSurface) == ObjPtr(SurfaceToken)
            and SurfaceToken.Generation == _TooltipGeneration)
    } finally {
        Critical(PreviousCritical)
    }
}
