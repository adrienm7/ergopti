; ui/tooltip/position_refinement.ahk

#Requires AutoHotkey v2.0+

; Preview scheduling and provider admission have separate owners. A normal key-up
; changes the physical epoch but not the input generation: retain the idle
; obligation across that release, then freeze the exact epoch at dispatch.
global _TooltipPositionRefinement := 0
global _TooltipPositionWarmStarted := false

class TooltipPositionRefinement {
	__New(Surface, Items, Serial, StateFn, ScheduleFn, RequestFn, StartFn,
			MoveFn, CacheFn, ClockFn, IdleFn, DecisionFn) {
		this.Surface := Surface
		this.Items := Items
		this.Serial := Serial
		this.StateFn := StateFn
		this.ScheduleFn := ScheduleFn
		this.RequestFn := RequestFn
		this.StartFn := StartFn
		this.MoveFn := MoveFn
		this.CacheFn := CacheFn
		this.ClockFn := ClockFn
		this.IdleFn := IdleFn
		this.DecisionFn := DecisionFn
		Initial := StateFn.Call()
		Context := Initial.Context is Map ? Initial.Context.Clone() : 0
		if (Context is Map) && (Context.Get("Environment", 0) is Map)
			Context["Environment"] := Context["Environment"].Clone()
		this.Intent := { InputGeneration: Initial.InputGeneration,
			Context: Context }
		this.Origin := ClockFn.Call()
		this.Stopped := false
		this.Started := false
		this.Pending := 0
		this.TimerFn := this.Pump.Bind(this)
	}

	Current(Live) {
		return !this.Stopped && !Live.Paused
			&& IsObject(Live.Surface) && Live.Surface == this.Surface
			&& Live.Generation == this.Surface.Generation
			&& Live.Serial == this.Serial
			&& Live.InputGeneration == this.Intent.InputGeneration
			&& _TooltipRefinementContextsMatch(this.Intent.Context, Live.Context)
			&& !this.Surface.LlmPresented
			&& this.DecisionFn.Call(this.Items)
			&& _TooltipAbsoluteDeadlinesStillLive(this.Items)
	}

	Begin() {
		if !this.Current(this.StateFn.Call()) {
			this.Cancel()
			return false
		}
		this.ScheduleFn.Call(this.TimerFn, this.RemainingIdle())
		return true
	}

	RemainingIdle() {
		global TOOLTIP_UIA_IDLE_REQUIRED_MS
		return Max(1, TOOLTIP_UIA_IDLE_REQUIRED_MS - this.IdleFn.Call())
	}

	Cancel(ResumeRender := true) {
		if this.Stopped
			return false
		this.Stopped := true
		this.Pending := 0
		this.ScheduleFn.Call(this.TimerFn, 0)
	}

	Pump() {
		global TOOLTIP_UIA_IDLE_REQUIRED_MS, UIASW_START_DEADLINE_MS
		global _TOOLTIP_OWNER_RETRY_MS
		try {
			Live := this.StateFn.Call()
			if !this.Current(Live)
					|| TickExpired(this.Origin, UIASW_START_DEADLINE_MS,
						this.ClockFn.Call()) {
				this.Cancel()
				return false
			}
			if this.IdleFn.Call() < TOOLTIP_UIA_IDLE_REQUIRED_MS {
				this.ScheduleFn.Call(this.TimerFn, this.RemainingIdle())
				return false
			}
			if IsObject(this.Pending)
				return false
			; Read the physical epoch at admission, after the trigger key's release.
			Context := Live.Context
			this.Pending := Context
			if this.RequestFn.Call(Context, this.Terminal.Bind(this))
				return true
			this.Pending := 0
			if !this.Current(this.StateFn.Call()) {
				this.Cancel()
				return false
			}
			if !this.Started {
				this.Started := !!this.StartFn.Call()
				if !this.Started {
					this.Cancel()
					return false
				}
			}
			; A cold worker rejected the request before becoming ready. Retain the
			; exact visible owner; retry without another character or another render.
			this.ScheduleFn.Call(this.TimerFn, _TOOLTIP_OWNER_RETRY_MS)
			return false
		} catch as Err {
			this.Cancel()
			try LoggerError("Tooltip", "Idle position dispatch failed: {1}.", Err.Message)
			return false
		}
	}

	Terminal(Status, Context, Result) {
		try return this.Finish(Status, Context, Result)
		catch as Err {
			this.Cancel()
			try LoggerError("Tooltip", "Idle position commit failed: {1}.", Err.Message)
			TooltipHide("PositionRefinementFail", true, this.Surface.Generation,
				this.Surface, this.Serial)
			return false
		}
	}

	Finish(Status, Context, Result) {
		if this.Stopped || !IsObject(this.Pending) || this.Pending != Context
			return false
		this.Pending := 0
		if !this.Current(this.StateFn.Call()) {
			this.Cancel()
			return false
		}
		Rect := _TooltipParseUiaBounds(Status, Result)
		if !IsObject(Rect) {
			if Status = "timeout" || Status = "failed" || Status = "ok"
				_TooltipMarkUiaHostile(Context.Get("ProcName", ""))
			this.Cancel()
			return false
		}
		Anchor := _TooltipPositionFromUiaBounds(Rect)
		Pos := _TooltipPlaceOnScreen(Anchor, this.Surface.Rows[1].W,
			this.Surface.Rows[1].H)
		Moved := false
		PreviousCritical := Critical("On")
		try {
			Live := this.StateFn.Call()
			if !this.Current(Live)
					|| !UIASW_ContextMatches(Context, Result, Live.Context)
				return false
			; Move the existing content and border together. No new presentation,
			; expiry origin, accounting entry or LLM ownership is created here.
			this.MoveFn.Call(this.Surface, Pos)
			this.Surface.Anchor := Anchor
			this.Surface.Pos := Pos
			this.TerminalContext := Context
			this.CacheFn.Call(Context["Hwnd"], Anchor)
			Moved := true
		} finally {
			Critical(PreviousCritical)
			this.Cancel()
		}
		return Moved
	}
}

_TooltipRefinementContextsMatch(Left, Right) {
	return (Left is Map) && (Right is Map)
		&& Left.Get("Hwnd", 0) == Right.Get("Hwnd", 0)
		&& Left.Get("Control", 0) == Right.Get("Control", 0)
		&& _TooltipPositionReceiptsEqual(Left.Get("Environment", 0),
			Right.Get("Environment", 0))
}

_TooltipRefinementState() {
	global _TooltipActiveSurface, _TooltipGeneration, _TooltipRequestSerial
	return { Surface: _TooltipActiveSurface, Generation: _TooltipGeneration,
		Serial: _TooltipRequestSerial, Paused: A_IsSuspended,
		InputGeneration: KS_GetPhysicalInputGeneration(),
		Context: _TooltipCurrentUiaContext() }
}

_TooltipCancelPositionRefinement() {
	global _TooltipPositionRefinement
	if IsObject(_TooltipPositionRefinement)
		_TooltipPositionRefinement.Cancel(false)
	_TooltipPositionRefinement := 0
}

; Keep the first caret-less preview hidden until its precise anchor arrives.
; Subsequent requests use the idle prewarm receipt without moving visible pixels.
class TooltipPreviewPositionRequest extends TooltipPositionRefinement {
	__New(Request, StateFn := 0, ScheduleFn := TooltipRScheduleRefinement,
			RequestFn := UIASW_RequestBounds, StartFn := UIASW_Start,
			IdleFn := 0, DecisionFn := _TooltipDecisionItemsStillCurrent) {
		global _TooltipGeneration
		this.Request := Request
		this.RenderScheduleFn := ScheduleFn
		Surface := { Generation: _TooltipGeneration, LlmPresented: 0,
			Rows: [{ W: 1, H: 1 }], Anchor: 0, Pos: 0 }
		super.__New(Surface, Request.Items, Request.Serial,
			HasMethod(StateFn, "Call") ? StateFn
				: () => _TooltipPendingPositionState(Request, Surface),
			ScheduleFn, RequestFn, StartFn,
			(Surface, Pos) => true,
			(Hwnd, Anchor) => this.StoreAnchor(Hwnd, Anchor),
			() => A_TickCount,
			HasMethod(IdleFn, "Call") ? IdleFn : () => A_TimeIdlePhysical,
			DecisionFn)
	}

	Cancel(ResumeRender := true) {
		if this.Stopped
			return false
		CanContinue := ResumeRender && this.Current(this.StateFn.Call())
		super.Cancel()
		this.Request.Position.Done := true
		if CanContinue
			this.RenderScheduleFn.Call(this.Request.TimerFn, TOOLTIP_RENDER_DEBOUNCE_MS)
		else
			_TooltipRetirePendingPositionRequest(this.Request)
		HotPath_RecordLatency("Tooltip.PositionWait",
			TickElapsed(this.Origin, this.ClockFn.Call()), TOOLTIP_UIA_IDLE_REQUIRED_MS)
	}

	StoreAnchor(Hwnd, Anchor) {
		this.Request.Position.Anchor := Anchor
		this.Request.Position.Context := this.TerminalContext
		_TooltipCachePosition(Hwnd, Anchor, this.TerminalContext)
	}
}

_TooltipRetirePendingPositionRequest(Request) {
	global _TooltipPendingRequest
	PreviousCritical := Critical("On")
	try {
		if IsObject(_TooltipPendingRequest) && _TooltipPendingRequest == Request {
			_TooltipPendingRequest := 0
			TooltipRScheduleRefinement(Request.TimerFn, 0)
			return true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return false
}

_TooltipPreparedPositionStillCurrent(Context, ContextFn := _TooltipCurrentUiaContext) {
	if !IsObject(Context)
		return true
	Live := ContextFn.Call()
	return _TooltipRefinementContextsMatch(Context, Live)
		&& UIASW_ContextMatches(Context, Context, Live)
}

_TooltipPendingPositionState(Request, Surface) {
	global _TooltipPendingRequest
	State := _TooltipRefinementState()
	State.Surface := IsObject(_TooltipPendingRequest)
		&& _TooltipPendingRequest == Request ? Surface : 0
	return State
}

_TooltipPreparePreviewPosition(Request) {
	global _TooltipPositionRefinement
	global _TooltipPositionCache, TOOLTIP_POSITION_CACHE_MS
	Items := Request.Items
	if !(Items is Array) || !Items.Length
			|| !Items[1].HasOwnProp("PreviewStartedWallMs")
			|| Request.Position.Done || TooltipRHasNativeCaret()
		return false
	Context := _TooltipCurrentUiaContext()
	if !(Context is Map) || _TooltipUiaProcessIsHostile(Context.Get("ProcName", ""))
		return false
	; A plain global argument can read a newer object after a later call.
	; Pair one local receipt with the native sample and keep its fields.
	CachedPosition := _TooltipPositionCache
	CacheNowTick := A_TickCount
	if _TooltipPositionCacheCanReuse(CachedPosition, Context["Hwnd"],
			Context["Environment"], CacheNowTick, TOOLTIP_POSITION_CACHE_MS,
			Context["Control"])
		return false
	Owner := TooltipPreviewPositionRequest(Request)
	PreviousCritical := Critical("On")
	try {
		if !Owner.Current(Owner.StateFn.Call())
			return false
		_TooltipCancelPositionRefinement()
		_TooltipPositionRefinement := Owner
		return Owner.Begin()
	} finally {
		Critical(PreviousCritical)
	}
}

TooltipPositionWarmStart() {
	global _TooltipPositionWarmStarted
	if _TooltipPositionWarmStarted
		return false
	_TooltipPositionWarmStarted := true
	TooltipRSetPositionWarm(true)
	return true
}

TooltipPositionWarmStop() {
	global _TooltipPositionWarmStarted
	_TooltipPositionWarmStarted := false
	TooltipRSetPositionWarm(false)
	_TooltipCancelPositionRefinement()
}

_TooltipPositionWarmPump(ContextFn := _TooltipCurrentUiaContext,
		ScheduleFn := _TooltipScheduleUiaBounds,
		CaretFn := TooltipRHasNativeCaret, IdleFn := 0) {
	global _TooltipPositionWarmStarted, _TooltipPositionRefinement
	global _TooltipPositionCache, TOOLTIP_POSITION_CACHE_MS
	global TOOLTIP_UIA_IDLE_REQUIRED_MS
	IdleMs := HasMethod(IdleFn, "Call") ? IdleFn.Call() : A_TimeIdlePhysical
	if !_TooltipPositionWarmStarted || A_IsSuspended
			|| IdleMs < TOOLTIP_UIA_IDLE_REQUIRED_MS
			|| (IsObject(_TooltipPositionRefinement) && !_TooltipPositionRefinement.Stopped)
		return
	try {
		if CaretFn.Call()
			return
		Context := ContextFn.Call()
		if !(Context is Map) || _TooltipUiaProcessIsHostile(Context.Get("ProcName", ""))
			return
		; A plain global argument can read a newer object after a later call.
		; Pair one local receipt with the native sample and keep its fields.
		CachedPosition := _TooltipPositionCache
		CacheNowTick := A_TickCount
		if _TooltipPositionCacheCanReuse(CachedPosition, Context["Hwnd"],
				Context["Environment"], CacheNowTick, TOOLTIP_POSITION_CACHE_MS // 2,
				Context["Control"])
			return
		ScheduleFn.Call(Context)
	} catch as Err {
		try LoggerError("Tooltip", "Idle position prewarm failed: {1}.", Err.Message)
	}
}
