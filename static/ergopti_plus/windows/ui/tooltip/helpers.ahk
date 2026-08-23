; ui/tooltip/helpers.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / Internal Rendering Helpers
; DESCRIPTION:
; Surface lifecycle (suspend/reveal), screen clamping, stack presentation, dequeue rebuild, border teardown, GUI building, text measuring, stacked-corner rounding, border-alpha premultiply, the GDI border ring, DWM rounding control, accent resolution, tint mixing and caret-anchored positioning.
;
; Split out of the former infra/tooltip.ahk (the module split); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.

class TooltipNavOwnerRetryError extends Error {
}
class TooltipLlmTerminalOutcomeError extends Error {
}
class TooltipLlmStaleRenderError extends Error {
}
; ==============================================================================





; ============================================================
; ============================================================
; ======= 2/ Internal helpers ===============================
; ============================================================
; ============================================================

; Surface lifecycle — canonical phases in _shared/modules/tooltip/lifecycle.js.
; AHK uses two HWNDs (content + border); PREPARE keeps both hidden until the
; border DIB and content controls are ready, then REVEAL shows them together.

; Show content + border together after PREPARE completed while hidden.
; The content is a normal Gui (background + text controls); the border is a
; separate pre-painted layered window. ShowWindow only QUEUES a WM_PAINT for the
; content, so if the message queue is busy the border (already painted via
; UpdateLayeredWindow) can appear for up to a few hundred ms over a still-blank
; content window — the "border alone without background" flash. UpdateWindow
; flushes the content's paint SYNCHRONOUSLY (it bypasses the queue), so the
; background+text are on screen BEFORE the border is revealed and the two surfaces
; appear as one. This keeps the two-window design but removes the visible seam.
_TooltipRevealPreparedSurfaces(Surface) {
		if (Surface.Rows.Length > 0) {
				try DllCall("User32\ShowWindow", "Ptr", Surface.Rows[1].Gui.Hwnd, "Int", 4)
				try DllCall("User32\UpdateWindow", "Ptr", Surface.Rows[1].Gui.Hwnd)
		}
		if Surface.Border {
				GR_Show(Surface.Border.Hwnd)
		}
}

; Hide only the explicit owner passed by the caller. Never consult the active
; global here: a stale renderer may resume after a newer one has committed.
_TooltipHideSurfaceObjects(Surface) {
		if !IsObject(Surface)
			return
		if Surface.Border
			try GR_Hide(Surface.Border.Hwnd)
		for , Row in Surface.Rows
			try DllCall("User32\ShowWindow", "Ptr", Row.Gui.Hwnd, "Int", 0)
}

; Candidate wrapper shared by stale-build cleanup and the final presenter.
; HWND reads are best-effort because a concurrently destroyed detached Gui can
; already have lost its native window; Gui.Destroy remains the second backstop.
_TooltipCreateDetachedSurface(Row, Generation, Pos := 0) {
		Surface := { Gui: Row.Gui, Rows: [Row], Border: 0, Pos: Pos,
			ContentHwnds: [], BorderHwnds: [], Generation: Generation,
			LlmPresented: 0 }
		try Surface.ContentHwnds.Push(Row.Gui.Hwnd)
		return Surface
}

_TooltipQueueSurfaceDisposal(Surface) {
		if IsObject(Surface)
			SetTimer(_TooltipDisposeRetired.Bind(Surface), -1)
}

; Pure selection used by the production commit and its re-entrance test. A
; candidate that lost its immutable generation never becomes active and never
; retires the surface installed by the newer renderer.
_TooltipChoosePreparedSurface(ExpectedGeneration, CurrentGeneration,
	CurrentSurface, CandidateSurface) {
		if (ExpectedGeneration != CurrentGeneration)
			return { Committed: false, Active: CurrentSurface, Retired: 0 }
		return { Committed: true, Active: CandidateSurface, Retired: CurrentSurface }
}

; PREPARE + REVEAL for a built stack. Pos = { X, Y }, Row = { Gui, W, H }.
; Shift an anchor so the W×H tooltip stays inside the work area of the monitor
; under it (fall back to the primary monitor, then the full virtual screen). Without
; this a wide tooltip anchored near the bottom-right caret overflows the screen and
; is clipped — the truncation reported for long predictions in a corner.
; The clamp maths, with the screen bounds passed IN.
;
; Split out of _TooltipClampToScreen so it can be driven with arbitrary bounds.
; The wrapper below reads the real monitor work area from the OS, which meant no
; test could ever supply the screenFrame the shared corpus carries — so the AHK
; tooltip test validated the corpus's SHAPE and never compared one of its 6
; golden positions. Pure arithmetic, no OS calls, same formula as before.
;
; @param X,Y,W,H  Proposed tooltip rect.
; @param L,Top,R,B  Work-area bounds to clamp within.
; @param Margin  Clearance kept at every edge.
_TooltipClampRect(X, Y, W, H, L, Top, R, B, Margin) {
		; clamp(x, L+margin, R-W-margin); same for y — identical to the macOS renderer.
		return {
				X: Max(L + Margin, Min(X, R - W - Margin)),
				Y: Max(Top + Margin, Min(Y, B - H - Margin))
		}
}

_TooltipClampToScreen(X, Y, W, H) {
		; Margin kept clear of every screen edge — mirrors the shared positioning spec
		; (constants.toml [positioning].screen_margin = 5) that HS clamps with, so the
		; Windows tooltip lands at the same on-screen position as Hammerspoon.
		static MARGIN := 5
		L := 0, Top := 0, R := A_ScreenWidth, B := A_ScreenHeight
		try {
				found := false
				Loop MonitorGetCount() {
						MonitorGet(A_Index, &ml, &mt, &mr, &mb)
						if (X >= ml and X < mr and Y >= mt and Y < mb) {
								MonitorGetWorkArea(A_Index, &L, &Top, &R, &B)
								found := true
								break
						}
				}
				if !found
						MonitorGetWorkArea(MonitorGetPrimary(), &L, &Top, &R, &B)
		}
		return _TooltipClampRect(X, Y, W, H, L, Top, R, B, MARGIN)
}

_TooltipItemHasAbsoluteDeadline(Item) {
		return (IsObject(Item)
			and Item.HasOwnProp("ExpireOriginTick")
			and Item.HasOwnProp("ExpireDurationMs")
			and Item.ExpireDurationMs > 0)
}

; Keep the canonical origin/duration pair intact. In particular, never turn an
; already-expired row into a live one by replacing a zero remainder with an
; arbitrary positive SetTimer floor.
_TooltipFilterUnexpiredDeadlineItems(Items, NowTick?) {
		if !IsSet(NowTick)
			NowTick := A_TickCount
		LiveItems := []
		for , Item in Items {
			if (_TooltipItemHasAbsoluteDeadline(Item)
				and TickExpired(Item.ExpireOriginTick, Item.ExpireDurationMs, NowTick))
				continue
			LiveItems.Push(Item)
		}
		return LiveItems
}

_TooltipAbsoluteDeadlinesStillLive(Items, NowTick?) {
		if !IsSet(NowTick)
			NowTick := A_TickCount
		for , Item in Items {
			if (_TooltipItemHasAbsoluteDeadline(Item)
				and TickExpired(Item.ExpireOriginTick, Item.ExpireDurationMs, NowTick))
				return false
		}
		return true
}

; Build the immutable lifecycle plan before any GUI/UIA work. The plan carries
; origin/duration pairs, never a sampled remainder: a remainder becomes stale as
; soon as an interruptible renderer pumps the message queue.
_TooltipCreateLifecyclePlan(Items, DurationSec, OriginMs) {
		global _TOOLTIP_TIMEOUT_DECREMENT_SEC, _TOOLTIP_TIMEOUT_FLOOR_SEC
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

		HasAbsoluteDeadlines := false
		for , Item in Items {
			if Item.HasOwnProp("ExpireDurationMs") {
				HasAbsoluteDeadlines := true
				break
			}
		}

		Plan := {
			DequeueItems: 0,
			DequeueActive: false,
			DeadlineItems: [],
			ArmExactDeadline: false
		}
		if (HasAbsoluteDeadlines or (HasAnyDur and HasMixedDur)) {
			Plan.DequeueItems := []
			for , Item in Items {
				D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
				HasAbsoluteDeadline := (Item.HasOwnProp("ExpireOriginTick")
					and Item.HasOwnProp("ExpireDurationMs"))
				if (HasAbsoluteDeadlines and HasAbsoluteDeadline) {
					ExpOriginTick := Item.ExpireOriginTick
					ExpDurationMs := Item.ExpireDurationMs
				} else if (D > 0) {
					Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
						D - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
					ExpOriginTick := OriginMs
					ExpDurationMs := Round(Effective * 1000)
				} else {
					ExpOriginTick := OriginMs
					ExpDurationMs := 0
				}
				Copy := {}
				for Key, Value in Item.OwnProps()
					Copy.%Key% := Value
				Copy.ExpireOriginTick := ExpOriginTick
				Copy.ExpireDurationMs := ExpDurationMs
				Plan.DequeueItems.Push(Copy)
				if (ExpDurationMs > 0)
					Plan.DeadlineItems.Push(Copy)
			}
			Plan.DequeueActive := true
			Plan.ArmExactDeadline := Plan.DeadlineItems.Length > 0
			return Plan
		}

		EffectiveDur := DurationSec
		for , Item in Items {
			D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
			if (D > 0 and (EffectiveDur == 0 or D < EffectiveDur))
				EffectiveDur := D
		}
		if (EffectiveDur > 0) {
			Effective := Max(_TOOLTIP_TIMEOUT_FLOOR_SEC,
				EffectiveDur - _TOOLTIP_TIMEOUT_DECREMENT_SEC)
			Plan.DeadlineItems.Push({
				ExpireOriginTick: OriginMs,
				ExpireDurationMs: Round(Effective * 1000)
			})
			Plan.DequeueActive := true
		}
		return Plan
}

; Resolve the plan at the exact publication fence. Both timer owners derive
; from one current tick, so GUI/UIA or callback latency cannot extend either.
_TooltipLifecycleDeadlineBounds(Plan, NowTick?) {
		if !IsSet(NowTick)
			NowTick := A_TickCount
		Bounds := { Expired: false, EarliestMs: 0, LatestMs: 0 }
		if !IsObject(Plan) or !Plan.HasOwnProp("DeadlineItems")
			return Bounds
		for , Item in Plan.DeadlineItems {
			Remaining := TickRemaining(
				Item.ExpireOriginTick, Item.ExpireDurationMs, NowTick)
			if (Remaining <= 0) {
				Bounds.Expired := true
				continue
			}
			if (Bounds.EarliestMs == 0 or Remaining < Bounds.EarliestMs)
				Bounds.EarliestMs := Remaining
			if (Remaining > Bounds.LatestMs)
				Bounds.LatestMs := Remaining
		}
		return Bounds
}

; The watcher owns the single source of truth for whether a decision still
; describes the current engine buffer. Missing integration is legitimate for
; isolated tooltip tests; a present-but-failing integration must fail closed.
_TooltipDecisionItemsStillCurrent(Items) {
		if !IsSet(HotstringPrefixWatcherDecisionItemsStillCurrent)
			return true
		return HotstringPrefixWatcherDecisionItemsStillCurrent(Items)
}

_TooltipPublishVisibleDecisions(Items) {
		if !IsSet(HotstringPrefixWatcherPublishVisibleDecisions)
			return true
		return HotstringPrefixWatcherPublishVisibleDecisions(Items)
}

; Non-transactional follow-up for work that belongs to a successfully visible
; hotstring surface but may schedule more async work (metrics / LLM bridge).
; Publication above remains the in-memory commit. This notification deliberately
; runs only after Critical is restored; the watcher can no-op if its generation
; changed between commit and callback.
_TooltipNotifySurfacePresented(Items, SurfaceToken) {
		if !IsSet(HotstringPrefixWatcherOnSurfacePresented)
			return
		; Restoring an inherited Critical state still leaves this thread critical.
		; Hop to a fresh timer turn so metrics/privacy/LLM follow-up is never invoked
		; under either our transaction or a keyboard caller's outer transaction.
		if A_IsCritical {
			SetTimer(_TooltipNotifySurfacePresented.Bind(Items, SurfaceToken), -1)
			return
		}
		try HotstringPrefixWatcherOnSurfacePresented(Items, SurfaceToken)
		catch Error as Err
			_UiOracleReportError(
				"Visible-decision post-present callback failed: " . Err.Message)
}

; Oracle hooks are intentionally invoked inside short presentation/hide
; transactions. Their exceptional diagnostics must not turn an inherited
; keyboard-path Critical span into synchronous logger I/O.
_UiOracleReportError(Message) {
		if A_IsCritical {
			SetTimer(_UiOracleReportError.Bind(Message), -1)
			return
		}
		try LoggerError("Tooltip", "{1}", Message)
}

; Sub-segmented on purpose. Tooltip.Present is the dominant hot-path offender in
; production (102 of 194 slow lines on the first day after the UIA fix, ~12.9 ms
; mean), but it aggregates steps whose individual costs all sit BELOW the
; profiler's 5 ms reporting floor — so the parent's number never said which of
; them moved, and every optimisation proposed against it was speculation. The
; marks below cost two QPC reads each, accumulate without logging, and are
; rendered into the parent's own already-gated line by HotPath_BreakdownDetail()
; in _TooltipShowNow. This runs on the deferred render timer, never on the
; keystroke callback.
_TooltipPresentStack(Pos, Row, ArmSafety, Items, ExpectedGeneration,
	ClearDequeue := false, ExpectedRequestSerial := -1,
	LifecyclePlan := 0, CommitFn := 0) {
		global _TOOLTIP_SAFETY_SEC
		global _TooltipActiveSurface
		global _TooltipGeneration, _TooltipTimerGeneration
		global _TooltipRequestSerial, _TooltipPendingRequest
		global _TooltipDequeueItems, _TooltipDequeueActive
		global _TooltipDequeueDeadlineTimer
		; Every presenter carries the immutable generation it reserved. All expensive
		; preparation below is detached: it cannot hide, destroy, round or reposition
		; the active surface even if a newer renderer interrupts it.
		HotPath_BreakdownBegin()
		_hpCandidate := HotPath_Now()
		PreparedSurface := _TooltipCreateDetachedSurface(Row,
			ExpectedGeneration, Pos)
		HotPath_BreakdownMark("candidate", _hpCandidate)
		try {
			_hpClamp := HotPath_Now()
			Pos := _TooltipClampToScreen(Pos.X, Pos.Y, Row.W, Row.H)
			PreparedSurface.Pos := Pos
			HotPath_BreakdownMark("clamp", _hpClamp)

			_hpPrepare := HotPath_Now()
			Row.Gui.Show(Format("Hide NoActivate w{1} h{2} x{3} y{4}",
				Row.W, Row.H, Pos.X, Pos.Y))
			_TooltipDisableDwmRounding(Row.Gui.Hwnd)
			if (PreparedSurface.ContentHwnds.Length == 0)
				PreparedSurface.ContentHwnds.Push(Row.Gui.Hwnd)
			HotPath_BreakdownMark("prepare", _hpPrepare)

			_hpCorners := HotPath_Now()
			_TooltipApplyStackedCorners(Row)
			HotPath_BreakdownMark("corners", _hpCorners)

			_hpBorder := HotPath_Now()
			PreparedSurface.Border := _TooltipBuildBorder(
				Pos.X, Pos.Y, Row.W, Row.H)
			if PreparedSurface.Border
				PreparedSurface.BorderHwnds := [PreparedSurface.Border.Hwnd]
			HotPath_BreakdownMark("border", _hpBorder)
		} catch Error as Err {
			SetTimer(_TooltipDisposeRetired.Bind(PreparedSurface), -1)
			throw Err
		}

		CommitError := 0
		CommitAllowed := false
		SurfaceSwapped := false
		NavSwap := 0
		NavSwapCommitted := false
		RetiredSurface := 0
		Selection := { Committed: false }
		PublishItems := IsObject(Items) ? Items : []
		PreviousCritical := Critical("On")
		try {
			; A deferred request has a second owner in addition to its render
			; generation. A may reserve a render, yield in GUI/UIA, then resume after
			; request B was queued but before B's debounce fired; only this serial
			; fence prevents A from repainting stale pixels during that interval.
			_hpRequestOwner := HotPath_Now()
			RequestOwnerCurrent := _TooltipRequestOwnerMatches(
				ExpectedRequestSerial, _TooltipRequestSerial)
			HotPath_BreakdownMark("request_owner", _hpRequestOwner)
			_hpOwner := HotPath_Now()
			if RequestOwnerCurrent {
				Selection := _TooltipChoosePreparedSurface(ExpectedGeneration,
					_TooltipGeneration, _TooltipActiveSurface, PreparedSurface)
			}
			HotPath_BreakdownMark("owner", _hpOwner)
			if Selection.Committed {
				_hpDecision := HotPath_Now()
				DecisionCurrent := _TooltipDecisionItemsStillCurrent(PublishItems)
				HotPath_BreakdownMark("decision", _hpDecision)
				if DecisionCurrent {
					; Deadline is the last predicate before commit/reveal. A row with 1 ms
					; remaining cannot expire while a slower decision oracle runs afterward.
					_hpAbsoluteDeadline := HotPath_Now()
					DeadlinesLive := _TooltipAbsoluteDeadlinesStillLive(
						PublishItems)
					HotPath_BreakdownMark("absolute_deadline",
						_hpAbsoluteDeadline)
					_hpDeadline := HotPath_Now()
					DeadlineBounds := _TooltipLifecycleDeadlineBounds(
						LifecyclePlan)
					if DeadlineBounds.Expired
						DeadlinesLive := false
					HotPath_BreakdownMark("deadline", _hpDeadline)
					if DeadlinesLive {
						RetiredSurface := Selection.Retired

						; Attach all semantic ownership to the detached candidate before
						; the one active-surface publication. LLM candidates provide a
						; pure commit callback; ordinary tooltip candidates retire any
						; LLM lifecycle owned by the surface they replace. The callback
						; must run before the old pixels are hidden so an invalid candidate
						; cannot blank a still-valid visible prediction.
						if HasMethod(CommitFn, "Call")
							CommitFn.Call(PreparedSurface, RetiredSurface)

						; Fence the native hook before changing the one active pointer.
						; While the fence is open every navigation event is passed to
						; Windows unchanged. A receipt committed immediately before the
						; fence retains RetiredSurface by token and can never target B.
						if IsSet(LLM_NavEventOwner_BeginSurfaceSwap) {
							NavSwap := LLM_NavEventOwner_BeginSurfaceSwap(
								RetiredSurface, PreparedSurface)
							if !(NavSwap is Map)
								throw Error("Navigation owner refused the surface fence.")
							if NavSwap.Get("retry", false)
								throw TooltipNavOwnerRetryError(
									"Navigation repaint index changed before its fence.")
						}
						if IsSet(_LLM_TooltipRetireSurfaceRecord) {
							Replacement := IsSet(_LLM_TooltipPresentedFromSurface)
								? _LLM_TooltipPresentedFromSurface(PreparedSurface) : 0
							ReplacementLifecycle := IsObject(Replacement)
								&& Replacement.HasOwnProp("Lifecycle")
								? Replacement.Lifecycle : 0
							_LLM_TooltipRetireSurfaceRecord(RetiredSurface,
								ReplacementLifecycle)
						}

						_hpRetire := HotPath_Now()
						_TooltipHideSurfaceObjects(RetiredSurface)
						HotPath_BreakdownMark("retire", _hpRetire)

						; One assignment publishes content, border, trackers, position and
						; owner generation together. No callback can observe a half-swap.
						_TooltipActiveSurface := PreparedSurface
						SurfaceSwapped := true
						if NavSwap is Map {
							if !LLM_NavEventOwner_CommitSurfaceSwap(NavSwap)
								throw Error("Navigation owner surface commit failed.")
							NavSwapCommitted := true
						}
						; Retire the exact pending request in the same pixel transaction.
						; A newer B tuple has a different serial and remains untouched.
						if (ExpectedRequestSerial != -1
							and IsObject(_TooltipPendingRequest)
							and _TooltipPendingRequest.Serial
								== ExpectedRequestSerial)
							_TooltipPendingRequest := 0
						if ClearDequeue {
							_TooltipDequeueItems := 0
							_TooltipDequeueActive := false
						}
						if IsObject(LifecyclePlan) {
							_TooltipDequeueItems := LifecyclePlan.DequeueItems
							_TooltipDequeueActive := LifecyclePlan.DequeueActive
						}
						; Publish every expiry owner before revealing pixels or running
						; interruptible post-present privacy/focus work.
						_TooltipTimerGeneration := ExpectedGeneration
						LlmPresented := IsSet(_LLM_TooltipPresentedFromSurface)
							? _LLM_TooltipPresentedFromSurface(PreparedSurface) : 0
						if (IsObject(LlmPresented)
							and LlmPresented.Kind == "prediction"
							and LlmPresented.TimeoutRemainingMs > 0) {
							SetTimer(_TooltipTimerFn,
								-Max(1, LlmPresented.TimeoutRemainingMs))
						} else if (DeadlineBounds.LatestMs > 0) {
							SetTimer(_TooltipTimerFn,
								-Max(1, DeadlineBounds.LatestMs))
						} else if ArmSafety {
							SetTimer(_TooltipTimerFn,
								-Round(_TOOLTIP_SAFETY_SEC * 1000))
						}
						if IsObject(_TooltipDequeueDeadlineTimer)
							SetTimer(_TooltipDequeueDeadlineTimer, 0)
						_TooltipDequeueDeadlineTimer := 0
						if (IsObject(LifecyclePlan)
							and LifecyclePlan.ArmExactDeadline
							and DeadlineBounds.EarliestMs > 0) {
							_TooltipDequeueDeadlineTimer :=
								_TooltipDequeueDeadlineFn.Bind(
									ExpectedGeneration, PreparedSurface)
							SetTimer(_TooltipDequeueDeadlineTimer,
								-Max(1, DeadlineBounds.EarliestMs))
						}

						_hpReveal := HotPath_Now()
						_TooltipRevealPreparedSurfaces(PreparedSurface)
						HotPath_BreakdownMark("reveal", _hpReveal)

						_hpPublish := HotPath_Now()
						Published := _TooltipPublishVisibleDecisions(PublishItems)
						HotPath_BreakdownMark("publish", _hpPublish)
						if !Published
							throw Error("Visible-decision publication refused the revealed surface.")
						if IsSet(_LLM_TooltipMarkSurfaceSuggested)
							_LLM_TooltipMarkSurfaceSuggested(PreparedSurface)
						CommitAllowed := true
					}
				}
			}
		} catch Error as Err {
			CommitError := Err
		} finally {
			if (NavSwap is Map) && !NavSwapCommitted && !SurfaceSwapped
				try LLM_NavEventOwner_AbortSurfaceSwap(NavSwap)
			Critical(PreviousCritical)
		}

		; Metrics and LLM scheduling may yield, so they are explicitly post-commit.
		_hpPostPresent := HotPath_Now()
		if CommitAllowed
			_TooltipNotifySurfacePresented(PublishItems, PreparedSurface)
		if IsSet(_LLM_TooltipScheduleMetricDrain)
			_LLM_TooltipScheduleMetricDrain()
		HotPath_BreakdownMark("post_present", _hpPostPresent)

		; Destruction stays outside Critical and owns one detached record. If an
		; exception happened after the swap, retire the OLD record; the caller's
		; fail-closed hide owns the newly active candidate.
		DisposalSurface := SurfaceSwapped ? RetiredSurface : PreparedSurface
		_hpDispose := HotPath_Now()
		_TooltipQueueSurfaceDisposal(DisposalSurface)
		HotPath_BreakdownMark("dispose_schedule", _hpDispose)
		if IsObject(CommitError) {
			if CommitError is TooltipNavOwnerRetryError
					|| CommitError is TooltipLlmTerminalOutcomeError
					|| CommitError is TooltipLlmStaleRenderError
				throw CommitError
			_UiOracleReportError("Presentation commit failed: " . CommitError.Message)
			throw CommitError
		}
		return CommitAllowed
}

; Detached destack rebuild owned by the exact generation/surface snapshot the
; poll observed. A resumed old poll may dispose its own candidate, but it can
; never hide, retire or republish over a newer tooltip.
_TooltipDequeueRebuild(Items, ExpectedGeneration, ExpectedSurface) {
		global _TooltipGeneration, _TooltipTimerGeneration, _TooltipDequeueActive
		global _TooltipDequeueItems, _TooltipActiveSurface
		global _TooltipDequeueDeadlineTimer
		global _TooltipRequestSerial, _TooltipPendingRequest

		if !_TooltipSurfaceOwnerMatches(ExpectedGeneration,
			_TooltipGeneration, ExpectedSurface, _TooltipActiveSurface)
			return false
		; The poll selected these rows before this deferred rebuild began. Drop any
		; row that expired in between, and never build a stack for a stale engine
		; decision. The full-stack abort is intentional: correctness beats a flash
		; of content whose advertised action can no longer fire.
		Items := _TooltipFilterUnexpiredDeadlineItems(Items)
		DecisionCurrent := false
		try DecisionCurrent := _TooltipDecisionItemsStillCurrent(Items)
		catch Error as Err {
			_UiOracleReportError(
				"Visible-decision freshness check failed during destack: " . Err.Message)
			TooltipHide("DequeueDecisionCheckFail", true,
				ExpectedGeneration, ExpectedSurface)
			return false
		}
		if (Items.Length == 0 or !DecisionCurrent) {
			TooltipHide("DequeueStaleBeforeBuild", true,
				ExpectedGeneration, ExpectedSurface)
			return false
		}
		; Preserve the original absolute deadlines through detached preparation.
		; Their remainder is resolved only inside the common pixel commit.
		LifecyclePlan := _TooltipCreateLifecyclePlan(
			Items, 0, A_TickCount)
		; Reserve the rebuild only if the polled owner is still exact. Clearing the
		; old dequeue data prevents the repeating watchdog from starting a sibling
		; rebuild while GUI/UIA preparation pumps messages.
		PreviousCritical := Critical("On")
		try {
			if IsObject(_TooltipPendingRequest)
				return false
			if !_TooltipSurfaceOwnerMatches(ExpectedGeneration,
				_TooltipGeneration, ExpectedSurface, _TooltipActiveSurface)
				return false
			if IsObject(_TooltipDequeueDeadlineTimer)
				SetTimer(_TooltipDequeueDeadlineTimer, 0)
			_TooltipDequeueDeadlineTimer := 0
			_TooltipDequeueItems := 0
			_TooltipDequeueActive := false
			_TooltipGeneration += 1
			RenderGeneration := _TooltipGeneration
			RebuildRequestSerial := _TooltipRequestSerial
			_TooltipTimerGeneration := RenderGeneration
			SetTimer(_TooltipTimerFn, 0)
			Pos := IsObject(ExpectedSurface.Pos)
				? ExpectedSurface.Pos : 0
		} finally {
			Critical(PreviousCritical)
		}

		Row := 0
		try {
				Row := _TooltipBuildGui(Items)
		} catch {
				TooltipHide("DequeueBuildFail", true, RenderGeneration,
					unset, RebuildRequestSerial)
				return false
		}
		if (RenderGeneration != _TooltipGeneration) {
				if IsObject(Row)
					_TooltipQueueSurfaceDisposal(
						_TooltipCreateDetachedSurface(Row, RenderGeneration))
			return false
		}

		if !IsObject(Row) {
				TooltipHide("DequeueNoRows", true, RenderGeneration,
					unset, RebuildRequestSerial)
				return false
		}

		if !IsObject(Pos)
			Pos := _TooltipResolvePosition()
		if (RenderGeneration != _TooltipGeneration) {
				_TooltipQueueSurfaceDisposal(
					_TooltipCreateDetachedSurface(Row, RenderGeneration))
			return false
		}
		; The destack rebuild presents the same stack the render path does, so it must
		; carry the same attribution — otherwise a slow row expiry looks like a slow
		; render and the two are indistinguishable in the log.
		_hpDqPresent := HotPath_Now()
		Presented := false
		try {
				Presented := _TooltipPresentStack(Pos, Row, false, Items,
					RenderGeneration, false, RebuildRequestSerial,
					LifecyclePlan)
		} catch {
				TooltipHide("DequeuePresentFail", true, RenderGeneration,
					unset, RebuildRequestSerial)
				return false
		}
		; Drain even a refused commit so its sub-step marks cannot be attributed
		; to the next unrelated presentation.
		HotPath_LogIfSlow("Tooltip.DequeuePresent", _hpDqPresent, HotPath_BreakdownDetail())
		if !Presented {
			TooltipHide("DequeueStaleBeforeReveal", true, RenderGeneration,
				unset, RebuildRequestSerial)
			return false
		}
		return true
}

; Does a row need its own full-width background band?
;
; The Gui's BackColor is already _TooltipMixTintHex(Items[1].ColorHex), and the
; band spans (0, RowY, TotalW, RowH) — a strict sub-rectangle of the client area
; that brush fills. For row 1 the two are the same pure function over the same
; input, so the control repaints pixels that are already correct; the same is
; true of any later row sharing the first row's tint. Each elided band saves one
; CreateWindowEx plus one SetFont, on the ~97 % of renders that are single-row.
;
; Pure and hex-only so the decision is unit-testable without touching GDI.
_TooltipRowNeedsBand(BgHex, GuiBgHex) {
		return BgHex != GuiBgHex
}

; Build a single Gui that holds the entire tooltip stack.
; Each row is rendered as a full-width background Text control (tinted per group)
; with a smaller foreground Text control overlaid for the content and label.
; A 1 px separator line is drawn between rows using a narrow background band.
; Using one Gui eliminates all inter-window overlap — the only rendered surface
; is a single window with a single GDI region, exactly like the Hammerspoon canvas.
_TooltipBuildGui(Items) {
		global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_LABEL_GAP
		global _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y

		G := 0
		try {
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
		; Resolved once and kept as the reference every row's band is elided against.
		GuiBgHex := _TooltipMixTintHex(FirstColorHex)
		; WS_EX_TOOLWINDOW (0x80) suppresses the DWM drop shadow and rounded-corner
		; treatment that Windows 11 applies to all top-level windows; combined with
		; SetWindowRgn this gives us full control over the visible shape.
		G := Gui("+AlwaysOnTop -Caption +E0x20 +E0x80 +LastFound")
		G.BackColor := GuiBgHex
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

				; Full-width background band for this row's tint color — skipped when the
				; Gui background already paints exactly that colour (see
				; _TooltipRowNeedsBand). The 1 px separator below is a DIFFERENT colour
				; and is never elided.
				if _TooltipRowNeedsBand(BgHex, GuiBgHex) {
						G.SetFont("norm s1", _TOOLTIP_FONT_NAME)
						G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", BgHex, RowY, TotalW, RowH), "")
				}

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

		; Return a detached candidate. Nothing in the shared surface globals is
		; touched until _TooltipPresentStack wins its final generation fence.
		return { Gui: G, H: TotalH, W: TotalW, IsSep: false }
		} catch Error as Err {
			; Once Gui construction starts, the caller cannot see the partial object
			; when a control/font operation throws. Retire it locally so an error can
			; never leave an untracked top-level ghost behind.
			if IsObject(G) {
				try {
					CleanupRow := { Gui: G, H: 0, W: 0, IsSep: false }
					_TooltipQueueSurfaceDisposal(
						_TooltipCreateDetachedSurface(CleanupRow, 0))
				} catch {
					; Best effort after the original build exception.
				}
			}
			throw Err
		}
}

; Cache of measurement HFONTs keyed by device-pixel height. The tooltip only
; ever measures one font name at a couple of sizes, so creating + destroying a
; GDI font on every call (twice per render) is pure waste. The handles live for
; the process — a tiny, bounded GDI cache.
global _TooltipMeasureFontCache := Map()

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

		; Reuse a cached HFONT keyed by device-pixel height (covers DPI changes too).
		global _TooltipMeasureFontCache
		if _TooltipMeasureFontCache.Has(HeightPx) {
				HFont := _TooltipMeasureFontCache[HeightPx]
		} else {
				HFont := DllCall("Gdi32\CreateFontW",
						"Int", HeightPx, "Int", 0, "Int", 0, "Int", 0,
						"Int", 400, "UInt", 0, "UInt", 0, "UInt", 0,
						"UInt", 1, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
						"WStr", _TOOLTIP_FONT_NAME,
						"Ptr")
				if HFont
						_TooltipMeasureFontCache[HeightPx] := HFont
		}
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
		; HFont is cached for reuse — do NOT DeleteObject it here.
		DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", HDC)

		if (Width <= 0 or Height <= 0) {
				return Fallback
		}
		return { W: Width, H: Height }
}

; Apply a fully-rounded region to the single unified tooltip Gui.
; Since the stack is now a single window, all four corners are always
; rounded — no top/middle/bottom split needed.
_TooltipApplyStackedCorners(Row) {
		global _TOOLTIP_CORNER_RADIUS
		if !IsObject(Row)
				return
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

; Rewrite every pixel GDI painted into the 32-bpp DIB to the premultiplied border
; color. GDI RoundRect writes opaque white (alpha byte 0); the layered window needs
; premultiplied alpha, so each painted pixel must be overwritten. The outline is a
; 1 px rounded rect, so the ONLY painted pixels are:
;   - the two horizontal straight edges (rows y=0 and y=Hp-1), spanning the width;
;   - the corner arcs, confined to the left/right corner-column zones of the rows
;     within Diam of the top or bottom edge;
;   - the two vertical straight edges (columns x=0 and x=Wp-1) on the middle rows.
; Every other pixel is transparent. Scanning only those zones keeps the cost at
; ~2*Wp + 4*Diam^2 instead of the former 2*Diam*Wp full-band scan — the win is
; largest for the short 1-2 row preview tooltips, where the corner band spans
; almost the entire height and the old scan re-read the transparent interior of
; nearly every row (the BorderPixelLoop hot-path warnings clustered there).
; Correctness is pinned by test_tooltip_border_alpha.ahk, which compares this
; against a full O(Wp*Hp) reference scan over real GDI RoundRect output.
; @param PixPtr {Ptr} Base pointer of the top-down 32-bpp BGRA DIB.
; @param Wp {Integer} Bitmap width in physical pixels.
; @param Hp {Integer} Bitmap height in physical pixels.
; @param Diam {Integer} Corner diameter passed to RoundRect (0 = square corners).
; @param PremulPx {Integer} Premultiplied BGRA value to write into painted pixels.
_TooltipFixBorderAlpha(PixPtr, Wp, Hp, Diam, PremulPx) {
		if (Wp <= 0 or Hp <= 0)
				return
		BandRows := Min(Diam, Hp)
		CornerCols := Min(Diam, Wp)
		RightZoneStart := Wp - CornerCols   ; first column of the right corner zone
		LastColOff := (Wp - 1) * 4
		loop Hp {
				RowY := A_Index - 1
				RowBase := RowY * Wp * 4
				if (RowY == 0 or RowY == Hp - 1) {
						; Horizontal straight edge — the painted run spans the full width.
						loop Wp {
								Offset := RowBase + (A_Index - 1) * 4
								if (NumGet(PixPtr, Offset, "UInt") != 0)
										NumPut("UInt", PremulPx, PixPtr, Offset)
						}
				} else if (RowY < BandRows or RowY >= Hp - BandRows) {
						; Corner-arc row — only the left and right corner column zones can
						; carry painted pixels (the zones overlap harmlessly when Wp <= 2*Diam).
						loop CornerCols {
								Off := RowBase + (A_Index - 1) * 4
								if (NumGet(PixPtr, Off, "UInt") != 0)
										NumPut("UInt", PremulPx, PixPtr, Off)
						}
						loop CornerCols {
								Off := RowBase + (RightZoneStart + A_Index - 1) * 4
								if (NumGet(PixPtr, Off, "UInt") != 0)
										NumPut("UInt", PremulPx, PixPtr, Off)
						}
				} else {
						; Middle row — only the two vertical edge columns.
						if (NumGet(PixPtr, RowBase, "UInt") != 0)
								NumPut("UInt", PremulPx, PixPtr, RowBase)
						if (NumGet(PixPtr, RowBase + LastColOff, "UInt") != 0)
								NumPut("UInt", PremulPx, PixPtr, RowBase + LastColOff)
				}
		}
}

; Show a 1 px semi-transparent border ring that exactly overlays the tooltip.
; Strategy: create a WS_EX_LAYERED window and call UpdateLayeredWindow with a
; 32-bpp pre-multiplied-alpha DIB.  The DIB is painted via GDI RoundRect (which
; writes opaque pixels), then every non-zero pixel's alpha channel is set to the
; desired opacity (0x40 = 25 %).  No DWM rounding can affect the result because
; the window has zero client area — it is just a bitmap handed to the compositor.
_TooltipBuildBorder(X, Y, W, H) {
		global _TOOLTIP_CORNER_RADIUS

		BorderGui := 0
		try {
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
				; Release whichever handle DID succeed, then always bail. Without explicit
				; braces, AHK v2's single-line `if` would chain the DeleteDC and return under
				; the first `if HBmp`, so the surviving MemDC leaked and the function pressed
				; on with a null bitmap — a slow GDI-handle leak under object pressure.
				if (HBmp)
						DllCall("Gdi32\DeleteObject", "Ptr", HBmp)
				if (MemDC)
						DllCall("Gdi32\DeleteDC", "Ptr", MemDC)
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
		_hpPix := HotPath_Now()
		_TooltipFixBorderAlpha(PixPtr, Wp, Hp, Diam, PremulPx)
		HotPath_LogIfSlow("Tooltip.BorderPixelLoop", _hpPix, TotalPx . " px")

		; ── Create the layered window ─────────────────────────────────────────────
		; WS_EX_TOOLWINDOW (0x80) suppresses DWM automatic corner rounding, same as
		; the content Gui.  UpdateLayeredWindow is called BEFORE ShowWindow so the
		; window is never visible in an unpainted state (no ghost flash).
		BorderGui := Gui("+AlwaysOnTop -Caption +E0x80000 +E0x20 +E0x80 +LastFound")
		Hwnd := BorderGui.Hwnd
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

		; Detached and hidden. The final owner commit decides whether this exact
		; object becomes global or is disposed as a stale candidate.
		return BorderGui
		} catch Error as Err {
			if IsObject(BorderGui) {
				try BorderGui.Destroy()
			}
			throw Err
		}
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
; Has this process recently failed to answer a UIA probe? A hostile app costs a
; full UIA timeout every time the position cache expires, so one failure buys a
; quiet window rather than a repeating stall.
_TooltipUiaProcessIsHostile(ProcName) {
		global _TooltipUiaHostileCache
		if (ProcName == "" or !_TooltipUiaHostileCache.Has(ProcName))
				return false
		Entry := _TooltipUiaHostileCache[ProcName]
		if !TickExpired(Entry.Tick, Entry.DurationMs)
				return true
		_TooltipUiaHostileCache.Delete(ProcName)
		return false
}

; Record that ``ProcName`` did not answer usefully, silencing UIA probes against
; it for TOOLTIP_UIA_HOSTILE_TTL_MS. The map is keyed by process name and
; entries expire, so it cannot grow without bound across a long session.
_TooltipMarkUiaHostile(ProcName) {
		global _TooltipUiaHostileCache, TOOLTIP_UIA_HOSTILE_TTL_MS
		if (ProcName == "")
				return
		_TooltipUiaHostileCache[ProcName] := {
				Tick: A_TickCount,
				DurationMs: TOOLTIP_UIA_HOSTILE_TTL_MS
		}
}

; Record which stage of the position cascade answered this call.
; Counted per STAGE rather than as one "resolved" total: the two failure modes
; this cascade actually has — "the position cache never hits" and "UIA never
; answers" — are invisible in a total, and both have been argued about from the
; log without a single number to settle them.
; @param Stage {String} Cascade exit name (caret, cache, uia_caret, …).
_TooltipCountResolveExit(Stage) {
		global _TooltipResolveExits
		_TooltipResolveExits[Stage] := _TooltipResolveExits.Get(Stage, 0) + 1
}

; Count one presented render and flush the accounting line every
; _TOOLTIP_STATS_LOG_EVERY renders. This is the DENOMINATOR for every
; "Slow Tooltip.*" warning in the same log.
_TooltipNoteRenderPresented() {
		global _TooltipRenderCount, _TOOLTIP_STATS_LOG_EVERY, _TooltipResolveExits
		_TooltipRenderCount += 1
		if (Mod(_TooltipRenderCount, _TOOLTIP_STATS_LOG_EVERY) != 0)
				return
		Parts := ""
		for Stage, Count in _TooltipResolveExits
				Parts .= (Parts == "" ? "" : ", ") . Stage . "=" . Count
		try LoggerInfo("Tooltip", "{1} render(s) presented; position cascade exits: {2}.",
				_TooltipRenderCount, (Parts == "") ? "none" : Parts)
}

; Bound UIA's own waits. The library ships Windows' defaults — 2000 ms
; TransactionTimeout and 20000 ms ConnectionTimeout — so an unresponsive
; foreground app can stall the driver's only message thread for seconds; the
; worst measured stall, 2560 ms, is the 2000 ms default plus overhead. Both
; properties are IUIAutomation2 vtable slots, hence the availability guard and
; the per-assignment try: an older interface must not throw into the caller.
; Idempotent — the static flag keeps this to one pair of ComCalls per session.
_TooltipClampUiaTimeouts() {
		global UIA_TRANSACTION_TIMEOUT_MS, UIA_CONNECTION_TIMEOUT_MS
		static Clamped := false
		; One diagnostic per process: this runs on every tooltip present.
		static Warned := false
		if Clamped
				return
		; Latch AFTER the guards, not before them. Latching first meant an early
		; present — before the UIA include had run, or before the timeout constants
		; were seeded — burned the single attempt and left every later probe on
		; Windows' 2000 ms default. This site also never checked the constants at all,
		; so an unset one turned the two writes below into a swallowed exception.
		if !IsSet(UIA)
				return
		if (!IsSet(UIA_TRANSACTION_TIMEOUT_MS) or !IsSet(UIA_CONNECTION_TIMEOUT_MS)) {
				if !Warned {
						Warned := true
						try LoggerWarn("Tooltip", "UIA timeout constants are unavailable — the position probe would run against Windows' 2000 ms default; skipping the clamp.")
				}
				return
		}
		Supported := false
		try Supported := UIA.IsIUIAutomation2Available ? true : false
		if !Supported {
				Clamped := true
				if !Warned {
						Warned := true
						try LoggerWarn("Tooltip", "IUIAutomation2 is unavailable — the position probe runs against Windows' 2000 ms transaction default and cannot be bounded here.")
				}
				return
		}
		Ok := true
		try UIA.TransactionTimeout := UIA_TRANSACTION_TIMEOUT_MS
		catch
				Ok := false
		try UIA.ConnectionTimeout := UIA_CONNECTION_TIMEOUT_MS
		catch
				Ok := false
		if Ok {
				Clamped := true
				return
		}
		if !Warned {
				Warned := true
				try LoggerWarn("Tooltip", "Could not apply the UIA timeout clamp — the position probe is NOT bounded; retrying on the next present.")
		}
}

_TooltipResolvePosition() {
		global _TOOLTIP_OFFSET_BELOW, _TOOLTIP_OFFSET_RIGHT
		global _TOOLTIP_MAX_CARET_HEIGHT_PX, _TOOLTIP_WINDOW_BOTTOM_INSET_PX
		global _TooltipPositionCache, TOOLTIP_POSITION_CACHE_MS
		global TOOLTIP_UIA_IDLE_REQUIRED_MS

		; ----- 1. Native caret -----------------------------------------------
		Cx := 0
		Cy := 0
		GotCaret := false
		try GotCaret := CaretGetPos(&Cx, &Cy)
		if (GotCaret and (Cx != 0 or Cy != 0)) {
				_TooltipCountResolveExit("caret")
				return _TooltipCachePosition(WinExist("A"),
						{ X: Cx + _TOOLTIP_OFFSET_RIGHT, Y: Cy + _TOOLTIP_OFFSET_BELOW })
		}

		ActiveHwnd := WinExist("A")
		if IsObject(_TooltipPositionCache) {
				Age := TickElapsed(_TooltipPositionCache["tick"])
				if (_TooltipPositionCache["hwnd"] == ActiveHwnd
						and Age <= TOOLTIP_POSITION_CACHE_MS) {
						_TooltipCountResolveExit("cache")
						return { X: _TooltipPositionCache["x"], Y: _TooltipPositionCache["y"] }
				}
		}

		; ----- 2. UIA focused element bounding rectangle ---------------------
		; Three guards stand in front of the COM call, because it is a
		; cross-process round-trip on the one thread that also dispatches
		; keystrokes. Measured worst case before them: 2560 ms
		; ("[HotPath] Slow Tooltip.ResolvePos: 2560.32 ms", 2026-07-16), which is
		; UIA's own 2000 ms TransactionTimeout plus overhead.
		ProcName := ""
		try ProcName := WinGetProcessName("A")
		; (a) Never start the round-trip while the user is physically typing. The
		;     render debounce is a coalescing timer, not an idle gate — it only
		;     decides WHEN the deferred work runs, not whether a burst is still in
		;     flight. Mirrors UIA_SELECTION_IDLE_REQUIRED_MS in keymap/layout.ahk.
		; (b) Skip apps already known not to answer: one timeout buys a quiet
		;     window instead of paying the same stall every cache expiry.
		; The two reasons for skipping the probe are NOT interchangeable downstream,
		; so they are kept apart. "Still mid-burst" is transient — the probe will run
		; within a couple of hundred milliseconds — whereas "hostile app" lasts
		; TOOLTIP_UIA_HOSTILE_TTL_MS. The fallback stages below cache their coarse
		; anchor in the first case only at the cost of suppressing the very probe that
		; would have produced a real caret anchor; see _TooltipCacheUnlessProbePending.
		UiaSkippedForIdle := (A_TimeIdlePhysical < TOOLTIP_UIA_IDLE_REQUIRED_MS)
		UiaAllowed := !UiaSkippedForIdle
				and !_TooltipUiaProcessIsHostile(ProcName)
		; (c) Bound the call itself. Deliberately lazy rather than at boot: the
		;     first touch of UIA initialises the COM object, so clamping at boot
		;     would move that cost onto the startup path. The two properties live
		;     on the UIA singleton, so setting them here bounds every call site in
		;     the driver, not just this one — which is exactly why it must NOT sit
		;     under `if UiaAllowed`. Gated that way, the clamp only ran when this
		;     probe was itself allowed to run, so the sibling probes that share the
		;     singleton (_UIA_SelectionPollTick, SFD_ProbeFocusedUia — both on this
		;     same message thread) kept Windows' 2000 ms / 20000 ms defaults for the
		;     whole session. Reaching stage 2 at all is the right trigger: the caret
		;     stage has already failed, so UIA is about to matter.
		_TooltipClampUiaTimeouts()
		try {
				if (UiaAllowed and IsSet(UIA)) {
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
												_TooltipCountResolveExit("uia_caret")
												return _TooltipCachePosition(ActiveHwnd,
														{ X: Rect.l + _TOOLTIP_OFFSET_RIGHT,
																Y: Rect.b + _TOOLTIP_OFFSET_BELOW })
										} else {
												; Input-box-like: anchor under the bottom centre.
												_TooltipCountResolveExit("uia_box")
												return _TooltipCachePosition(ActiveHwnd,
														{ X: Rect.l + W // 2,
																Y: Rect.b + _TOOLTIP_OFFSET_BELOW })
										}
								}
						}
						; Reached only when UIA answered but gave nothing usable (no
						; focused element, or a zero-area rect). Treat that as "this app
						; does not do UIA" and stop asking for a while.
						_TooltipMarkUiaHostile(ProcName)
				}
		} catch as e {
				; A bare catch-less try here discarded the reason a probe failed, so a
				; UIA-hostile app was indistinguishable from a healthy one that simply
				; had no caret. Matches the uia-error-swallowed-silently precedent in
				; keymap/layout.ahk.
				_TooltipMarkUiaHostile(ProcName)
				try LoggerWarn("Tooltip", "UIA position probe failed for '{1}': {2}.",
						ProcName, e.Message)
		}

		; ----- 3. Active window frame ----------------------------------------
		try {
				Wx := 0
				Wy := 0
				Ww := 0
				Wh := 0
				WinGetPos(&Wx, &Wy, &Ww, &Wh, "A")
				if (Ww > 0 and Wh > 0) {
						_TooltipCountResolveExit("window")
						return _TooltipCacheUnlessProbePending(ActiveHwnd,
								{ X: Wx + Ww // 2,
										Y: Wy + Wh - _TOOLTIP_WINDOW_BOTTOM_INSET_PX },
								UiaSkippedForIdle)
				}
		}

		; ----- 4. Mouse cursor -----------------------------------------------
		Mx := 0
		My := 0
		try MouseGetPos(&Mx, &My)
		_TooltipCountResolveExit("mouse")
		return _TooltipCacheUnlessProbePending(ActiveHwnd,
				{ X: Mx, Y: My + _TOOLTIP_OFFSET_BELOW },
				UiaSkippedForIdle)
}

; Pins a FALLBACK anchor in the position cache only when that anchor is the best
; the driver can currently produce.
;
; Stages 3 and 4 are reached both when UIA genuinely had nothing to offer and
; when its probe never ran because the user was still mid-burst. Those two cases
; deserve opposite treatment. A hostile or silent app will not answer for
; TOOLTIP_UIA_HOSTILE_TTL_MS, so caching the coarse anchor is exactly right —
; it buys a quiet window instead of re-paying a timeout. But when the probe was
; merely deferred for idle, the coarse anchor is a stand-in for a measurement
; that has not been taken yet: caching it would serve it for the whole
; TOOLTIP_POSITION_CACHE_MS window and suppress the probe that would have
; produced the real caret anchor, so the preview would sit at the bottom of the
; window instead of under the caret.
;
; Stages 1 and 2 deliberately do NOT route through here: a native caret and a
; resolved UIA rect are real measurements and must be cached unconditionally.
_TooltipCacheUnlessProbePending(Hwnd, Pos, ProbePending) {
		if ProbePending
				return Pos
		return _TooltipCachePosition(Hwnd, Pos)
}

_TooltipCachePosition(Hwnd, Pos) {
		global _TooltipPositionCache
		_TooltipPositionCache := Map(
				"hwnd", Hwnd,
				"x", Pos.X,
				"y", Pos.Y,
				"tick", A_TickCount
		)
		return Pos
}
