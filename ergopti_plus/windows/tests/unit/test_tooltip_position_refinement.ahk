; tests/unit/test_tooltip_position_refinement.ahk

#Requires AutoHotkey v2.0+

_TPR_Fixture() {
	Surface := { Generation: 40, LlmPresented: 0,
		Rows: [{ W: 100, H: 20 }], Pos: { X: 0, Y: 0 }, Anchor: 0 }
	Context := Map("Hwnd", 7001, "Control", 8001, "InputEpoch", 10,
		"ProcName", "", "Environment", _TPCR_Receipt(101))
	State := { Surface: Surface, Generation: 40, Serial: 30,
		InputGeneration: 20, Paused: false, Context: Context }
	Fixture := { State: State, Surface: Surface, Items: [], Clock: 1000,
		Idle: 0, Ready: false, Requests: 0, Starts: 0, Moves: 0, Caches: 0,
		Schedules: [], Decisions: true, Callback: 0, Submitted: 0 }
	Fixture.CompleteRefusal := false
	Fixture.Owner := TooltipPositionRefinement(Surface, Fixture.Items, 30,
		() => Fixture.State,
		(Fn, Ms) => Fixture.Schedules.Push(Ms),
		(Context, Fn) => _TPR_Request(Fixture, Context, Fn),
		() => (Fixture.Starts += 1, true),
		(Surface, Pos) => (Fixture.Moves += 1),
		(Hwnd, Anchor) => (Fixture.Caches += 1),
		() => Fixture.Clock, () => Fixture.Idle, (Items) => Fixture.Decisions)
	return Fixture
}

_TPR_Request(Fixture, Context, Fn) {
	Fixture.Requests += 1
	if Fixture.CompleteRefusal {
		Fn.Call("failed", Context, Map())
		return false
	}
	if !Fixture.Ready
		return false
	Fixture.Callback := Fn
	Fixture.Submitted := Context
	return true
}

_TPR_Result(Fixture) {
	return Map("Hwnd", Fixture.Submitted["Hwnd"],
		"Control", Fixture.Submitted["Control"], "Text", "400`n500`n402`n515")
}

_TPR_EarlyPixelsKeepIndependentIdleAdmission() {
	F := _TPR_Fixture()
	AssertTrue(F.Owner.Begin())
	AssertEqual(200, F.Schedules[1])
	F.Idle := 199
	F.Owner.Pump()
	AssertEqual(0, F.Requests, "visible previews must not probe during typing")
	AssertEqual(1, F.Schedules[2])
	; A key-up changes the epoch without starting a new physical input intent.
	F.State.Context := F.State.Context.Clone()
	F.State.Context["InputEpoch"] := 11
	F.Idle := 200
	F.Owner.Pump()
	AssertEqual(1, F.Requests)
	AssertEqual(1, F.Starts)
	AssertEqual(25, F.Schedules[3], "cold worker must retain an owned retry")
	F.Ready := true
	AssertTrue(F.Owner.Pump())
	AssertEqual(11, F.Submitted["InputEpoch"], "freeze the epoch at admission")
	AssertTrue(F.Callback.Call("ok", F.Submitted, _TPR_Result(F)))
	AssertEqual(1, F.Moves, "refine without another character or a new surface")
	AssertEqual(1, F.Caches)
	AssertEqual(40, F.Surface.Generation, "positioning preserves the pixel owner")
	AssertTrue(F.Owner.Stopped)
}

_TPR_StaleTerminalNeverMoves(Kind) {
	F := _TPR_Fixture()
	F.Owner.Begin()
	F.Idle := 200, F.Ready := true
	AssertTrue(F.Owner.Pump())
	Result := _TPR_Result(F)
	switch Kind {
		case "surface": F.State.Surface := { Generation: 40 }
		case "generation": F.State.Generation += 1
		case "serial": F.State.Serial += 1
		case "input": F.State.InputGeneration += 1
		case "pause": F.State.Paused := true
		case "decision": F.Decisions := false
		case "llm": F.Surface.LlmPresented := { Kind: "prediction" }
		case "cancel": F.Owner.Cancel()
		case "deadline": F.Items.Push({ ExpireOriginTick: A_TickCount - 100,
			ExpireDurationMs: 1 })
		default:
			F.State.Context := F.State.Context.Clone()
			switch Kind {
				case "hwnd": F.State.Context["Hwnd"] += 1
				case "control": F.State.Context["Control"] += 1
				case "epoch": F.State.Context["InputEpoch"] += 1
				case "monitor": F.State.Context["Environment"] := _TPCR_Receipt(102)
				case "work": F.State.Context["Environment"] := _TPCR_Receipt(101, 1)
				case "dpi": F.State.Context["Environment"] := _TPCR_Receipt(101,
					0, 0, 1920, 1080, 144)
			}
	}
	AssertFalse(F.Callback.Call("ok", F.Submitted, Result), Kind)
	AssertEqual(0, F.Moves, Kind . " must reject stale position publication")
	AssertEqual(0, F.Caches, Kind . " must reject stale cache publication")
}

_TPR_StartupRetryIsBounded() {
	F := _TPR_Fixture()
	F.Owner.Begin()
	F.Idle := 200
	F.Owner.Pump()
	F.Clock += UIASW_START_DEADLINE_MS
	AssertFalse(F.Owner.Pump())
	AssertTrue(F.Owner.Stopped)
	AssertEqual(1, F.Requests, "a timed-out startup must not retain a retry loop")
}

Test("tooltip position refinement: early pixels retain independent idle admission (tooltip-position-refinement)",
	_TPR_EarlyPixelsKeepIndependentIdleAdmission)
for Kind in ["surface", "generation", "serial", "input", "pause", "decision",
		"llm", "cancel", "deadline", "hwnd", "control", "epoch", "monitor", "work", "dpi"]
	Test("tooltip position refinement: stale " . Kind . " refuses movement (tooltip-position-refinement)",
		_TPR_StaleTerminalNeverMoves.Bind(Kind))
Test("tooltip position refinement: cold startup retry is bounded (tooltip-position-refinement)",
	_TPR_StartupRetryIsBounded)

_TPR_SynchronousRefusalCannotRestartCancelledOwner() {
	F := _TPR_Fixture()
	F.Owner.Begin()
	F.Idle := 200, F.CompleteRefusal := true
	AssertFalse(F.Owner.Pump())
	AssertTrue(F.Owner.Stopped)
	AssertEqual(0, F.Starts, "a terminal refusal must not start another worker")
	for Delay in F.Schedules
		AssertTrue(Delay != 25, "a cancelled owner must not retain a startup retry")
}
Test("tooltip position refinement: synchronous refusal cannot restart a cancelled owner (tooltip-position-refinement)",
	_TPR_SynchronousRefusalCannotRestartCancelledOwner)

_TPR_FirstPreviewNeverRevealsThenMoves(CancelBeforeResult := false) {
	global _TooltipGeneration
	F := _TPR_Fixture()
	Request := { Serial: 30, Items: [], Position: { Done: false, Anchor: 0 },
		TimerFn: (*) => true }
	Renders := []
	Owner := TooltipPreviewPositionRequest(Request, () => F.State,
		(Fn, Ms) => (Fn == Request.TimerFn ? Renders.Push(Ms) : true),
		(Context, Fn) => _TPR_Request(F, Context, Fn),
		() => true, () => F.Idle, (Items) => true)
	F.State.Surface := Owner.Surface
	F.State.Generation := _TooltipGeneration
	AssertTrue(Owner.Begin())
	F.Idle := 199
	Owner.Pump()
	AssertEqual(0, Renders.Length, "no coarse pixels may precede the precise anchor")
	F.Idle := 200, F.Ready := true
	AssertTrue(Owner.Pump())
	if CancelBeforeResult
		Owner.Cancel(false)
	Published := F.Callback.Call("ok", F.Submitted, _TPR_Result(F))
	if CancelBeforeResult {
		AssertFalse(Published)
		AssertEqual(0, Renders.Length, "replacement must not schedule old pixels")
	} else {
		AssertTrue(Published)
		AssertTrue(IsObject(Request.Position.Anchor))
		AssertEqual(1, Renders.Length, "reveal only once, directly at the resolved anchor")
		AssertEqual(TOOLTIP_RENDER_DEBOUNCE_MS, Renders[1])
	}
}
Test("tooltip first position: reveal once after resolution, without a visible move (tooltip-position-refinement)",
	_TPR_FirstPreviewNeverRevealsThenMoves)
Test("tooltip first position: replacement cancels the pending reveal (tooltip-position-refinement)",
	_TPR_FirstPreviewNeverRevealsThenMoves.Bind(true))

_TPR_PrewarmRequiresIdleAndExactControl() {
	global _TooltipPositionWarmStarted, _TooltipPositionRefinement, _TooltipPositionCache
	SavedStarted := _TooltipPositionWarmStarted
	SavedOwner := _TooltipPositionRefinement
	SavedCache := _TooltipPositionCache
	try {
		_TooltipPositionWarmStarted := true
		_TooltipPositionRefinement := 0
		F := _TPR_Fixture()
		Context := F.State.Context
		_TooltipPositionCache := _TPCR_Cache(Context["Environment"],
			Context["Hwnd"], A_TickCount)
		_TooltipPositionCache["control"] := Context["Control"]
		Calls := []
		Pump := (Idle) => _TooltipPositionWarmPump(() => Context,
			(Ctx) => Calls.Push(Ctx), () => false, () => Idle)
		Pump.Call(199)
		AssertEqual(0, Calls.Length)
		Pump.Call(200)
		AssertEqual(0, Calls.Length, "a fresh precise receipt needs no duplicate request")
		Context["Control"] += 1
		Pump.Call(200)
		AssertEqual(1, Calls.Length, "a new edit control requires its own receipt")
		_TooltipPositionRefinement := { Stopped: false }
		Pump.Call(200)
		AssertEqual(1, Calls.Length, "prewarm must yield to a demand position owner")
	} finally {
		_TooltipPositionWarmStarted := SavedStarted
		_TooltipPositionRefinement := SavedOwner
		_TooltipPositionCache := SavedCache
	}
}
Test("tooltip position prewarm: idle and exact-control cache admission (tooltip-position-refinement)",
	_TPR_PrewarmRequiresIdleAndExactControl)

_TPR_PreparedReceiptCannotOutliveItsContext() {
	F := _TPR_Fixture()
	Expected := F.State.Context.Clone()
	AssertTrue(_TooltipPreparedPositionStillCurrent(Expected, () => F.State.Context))
	for Field in ["Hwnd", "Control", "InputEpoch"] {
		Live := Expected.Clone()
		Live[Field] += 1
		AssertFalse(_TooltipPreparedPositionStillCurrent(Expected, () => Live), Field)
	}
	for Environment in [_TPCR_Receipt(102), _TPCR_Receipt(101, 1),
			_TPCR_Receipt(101, 0, 0, 1920, 1080, 144)] {
		Live := Expected.Clone()
		Live["Environment"] := Environment
		AssertFalse(_TooltipPreparedPositionStillCurrent(Expected, () => Live),
			"a post-terminal environment change must refuse the queued reveal")
	}
}
Test("tooltip first position: prepared receipt cannot outlive its context (tooltip-position-refinement)",
	_TPR_PreparedReceiptCannotOutliveItsContext)

_TPR_CancelRetiresOnlyItsExactRequest() {
	global _TooltipPendingRequest
	Saved := _TooltipPendingRequest
	try {
		A := { TimerFn: (*) => true }
		B := { TimerFn: (*) => true }
		_TooltipPendingRequest := A
		AssertTrue(_TooltipRetirePendingPositionRequest(A))
		AssertFalse(IsObject(_TooltipPendingRequest),
			"the old surface expiry must no longer see an abandoned newer request")
		_TooltipPendingRequest := B
		AssertFalse(_TooltipRetirePendingPositionRequest(A))
		AssertTrue(_TooltipPendingRequest == B, "A must never retire replacement B")
	} finally {
		_TooltipPendingRequest := Saved
	}
}
Test("tooltip first position: cancel retires only its exact pending tuple (tooltip-position-refinement)",
	_TPR_CancelRetiresOnlyItsExactRequest)
