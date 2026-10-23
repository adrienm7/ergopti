; tests/fixtures/tooltip_hostile_native64_body.ahk

; ==============================================================================
; MODULE: Tooltip Hostile Process Native64 Child
; DESCRIPTION:
; A real public prewarm timer requests a logical worker. Actual WM_COPYDATA
; delivers failure after the pump returns. No provider, browser or pixels run.
; ==============================================================================

#Requires AutoHotkey v2.0

_HUCT_Require(Value, Message) {
	if !Value
		throw Error(Message)
}

_HUCT_Remember(Failure) {
	global _HUCT
	if !IsObject(_HUCT.Failure)
		_HUCT.Failure := Failure
}

_HUCT_OnError(Failure, Mode) {
	_HUCT_Remember(Failure)
	return true
}

LoggerError(Category, Message, Values*) {
	_HUCT_Remember(Error("Production logger error: " . Category . ": " . (Values.Length ? Format(Message, Values*) : Message)))
}
LoggerWarn(Category, Message, Values*) {
	_HUCT_Remember(Error("Production logger warning: " . Category . ": " . (Values.Length ? Format(Message, Values*) : Message)))
}
LoggerDebug(*) => 0
LoggerInfo(*) => 0
LoggerStart(*) => 0
LoggerSuccess(*) => 0

_HUCT_Clock(Site) {
	global _HUCT
	_HUCT_Require(_HUCT.Now is Integer && _HUCT.Now >= 0, "The controlled tick must be a full nonnegative Integer.")
	_HUCT.Reads[Site] := _HUCT.Reads.Get(Site, 0) + 1
	return _HUCT.Now
}

; Only the two warm-adapter builtin sites route here. Other SUT timers stay native.
_HUCT_Timer(Callback, Period := unset, Priority := unset) {
	global _HUCT
	_HUCT_Require(Callback == _TooltipPositionWarmPump, "Only the actual supplied warm callback may be observed.")
	if !IsObject(_HUCT.Warm) {
		Record := {Callback: Callback, Calls: 0, Returned: 0, InFlight: false, Wrapper: 0}
		Record.Wrapper := _HUCT_Warm.Bind(Record)
		_HUCT.Warm := Record
	}
	Record := _HUCT.Warm
	_HUCT_Require(Record.Callback == Callback && IsSet(Period), "Timer identity and period presence must be retained.")
	if Period == 0
		_HUCT_Require(!IsSet(Priority), "Native cancellation must preserve omitted priority.")
	else
		_HUCT_Require(Period == TOOLTIP_POSITION_WARM_PERIOD_MS && IsSet(Priority) && Priority == -1,
			"The actual native warm period and priority must be forwarded.")
	SetTimer(Record.Wrapper, Period?, Priority?)
}

_HUCT_Warm(Record) {
	Record.Calls += 1, Record.InFlight := true
	try Record.Callback.Call()
	catch as Failure {
		_HUCT_Remember(Failure)
		throw
	} finally {
		Record.InFlight := false
		Record.Returned += 1
	}
}

_HUCT_NoSpawn(*) {
	Failure := Error("The valid ready-worker path must never spawn a process.")
	_HUCT_Remember(Failure)
	throw Failure
}

class _HUCT_WorkerHandle {
	terminateAsync() {
		global _HUCT
		_HUCT.Terminations += 1
		return true
	}
}

_HUCT_Context() {
	global _HUCT, _TooltipPositionCache, TOOLTIP_UIA_IDLE_REQUIRED_MS
	_HUCT_Require(!A_IsSuspended && !A_IsCritical, "Native warm delivery requires an active interruptible thread.")
	_HUCT_Require(WinExist("ahk_id " . _HUCT.Host.Hwnd) && WinGetPID("ahk_id " . _HUCT.Host.Hwnd) == _HUCT.Pid,
		"Only the private native host may be the target.")
	_HUCT_Require(WIGetForegroundHwnd() == _HUCT.Host.Hwnd && WIGetFocusedControlToken() == _HUCT.Button.Hwnd,
		"The exact private host and non-edit control must own focus.")
	_HUCT_Require(!TooltipRHasNativeCaret() && A_TimeIdlePhysical >= TOOLTIP_UIA_IDLE_REQUIRED_MS,
		"The actual no-caret and physical-idle gates must permit a query.")
	_HUCT_Require(!IsObject(_TooltipPositionCache), "No test may seed or publish a position receipt.")
	Context := _TooltipCurrentUiaContext()
	_HUCT_Require(Context is Map && Context["Hwnd"] == _HUCT.Host.Hwnd
		&& Context["Control"] == _HUCT.Button.Hwnd && Context["ProcName"] == _HUCT.Proc
		&& Context["Environment"] is Map, "The genuine native context and monitor receipt must be available.")
	return Context
}

_HUCT_Post(WorkerHwnd, RequestGeneration, RequestCode) {
	global _HUCT, UIASW_BOUNDS_REQUEST_CODE
	try {
		_HUCT_Require(WorkerHwnd == _HUCT.Worker.Hwnd && RequestCode == UIASW_BOUNDS_REQUEST_CODE,
			"Only the actual bounds request may enter the logical transport.")
		Pending := UIASWState.pending
		_HUCT_Require(Pending is Map && Pending["request_generation"] == RequestGeneration
			&& Pending["worker_generation"] == UIASWState.worker_generation,
			"The real request registry must own this exact transport tag.")
		Context := Pending["context"]
		Record := {Tag: RequestGeneration, Worker: WorkerHwnd, Context: Context,
			Pending: Pending, ReturnGoal: _HUCT.Warm.Returned + 1, Ack: -1, Delivered: 0, Timer: 0}
		Record.Timer := _HUCT_Deliver.Bind(Record)
		_HUCT.Posts.Push(Record)
		SetTimer(Record.Timer, -1)
		return true
	} catch as Failure {
		_HUCT_Remember(Failure)
		throw
	}
}

; Transport is real WM_COPYDATA, while the worker/provider itself is logical.
_HUCT_Send(Record) {
	global _HUCT
	PreviousHidden := DetectHiddenWindows(true)
	try {
		_HUCT_Require(Record.Worker == UIASWState.worker_hwnd
			&& WinExist("ahk_id " . Record.Worker) && WinGetPID("ahk_id " . Record.Worker) == _HUCT.Pid
			&& WinGetPID("ahk_id " . A_ScriptHwnd) == _HUCT.Pid,
			"Sender and receiver must be live exact private HWNDs in this native child.")
		Payload := "failed`n" . Record.Context["Hwnd"] . "`n" . Record.Context["Control"] . "`n"
		Data := Buffer(StrPut(Payload, "UTF-16") * 2, 0)
		StrPut(Payload, Data, "UTF-16")
		Structure := Buffer(A_PtrSize == 8 ? 24 : 12, 0)
		NumPut("UPtr", Record.Tag, Structure, 0)
		NumPut("UInt", Data.Size, Structure, A_PtrSize)
		NumPut("Ptr", Data.Ptr, Structure, A_PtrSize == 8 ? 16 : 8)
		return DllCall("User32\SendMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x004A,
			"Ptr", Record.Worker, "Ptr", Structure.Ptr, "Ptr")
	} finally DetectHiddenWindows(PreviousHidden)
}

_HUCT_Deliver(Record) {
	global _HUCT
	try {
		if _HUCT.Warm.InFlight || _HUCT.Warm.Returned < Record.ReturnGoal {
			SetTimer(Record.Timer, -1)
			return
		}
		_HUCT_Require(!A_IsCritical && UIASWState.pending == Record.Pending,
			"The failed frame must arrive after the real pump returns against its exact still-pending request.")
		if _HUCT.Mode == "stale-reply" && _HUCT.Posts.Length == 2 {
			Old := _HUCT.Posts[1]
			_HUCT_Require(Old.Tag < Record.Tag, "Actual request tags must advance monotonically.")
			_HUCT.StaleAck := _HUCT_Send(Old)
			_HUCT_Require(_HUCT.StaleAck == 0 && UIASWState.pending == Record.Pending,
				"An old native reply must not consume the exact newer request.")
		}
		Record.Ack := _HUCT_Send(Record)
		Record.Delivered += 1
		_HUCT_Require(Record.Ack == 1 && !IsObject(UIASWState.pending),
			"A genuine failed WM_COPYDATA frame must settle exactly once; timeout cannot seed this test.")
		_HUCT_Require(UIASWState.handle == _HUCT.Handle && UIASWState.worker_hwnd == _HUCT.Worker.Hwnd
			&& UIASWState.worker_generation == _HUCT.Generation,
			"Failed transport completion must preserve the same ready logical worker.")
	} catch as Failure {
		_HUCT_Remember(Failure)
		throw
	}
}

_HUCT_ExpiryReads() {
	global _HUCT
	return _HUCT.Reads.Get("TickExpired", 0) + _HUCT.Reads.Get("TickElapsed64", 0) + _HUCT.Reads.Get("query", 0)
}

_HUCT_Query(Seed := false) {
	global _HUCT, _TooltipUiaProbePending, _TooltipPositionWarmStarted
	_HUCT_Context()
	_HUCT_Require(!_TooltipPositionWarmStarted && !IsObject(_TooltipUiaProbePending)
		&& !IsObject(UIASWState.pending) && UIASWState.start_failure_tick == 0,
		"Each public query must begin without another pending or startup owner.")
	Before := _HUCT.Posts.Length, Returns := IsObject(_HUCT.Warm) ? _HUCT.Warm.Returned : 0
	Reads := _HUCT_ExpiryReads(), Started := A_TickCount
	_HUCT_Require(TooltipPositionWarmStart(), "The real public warm service must start once.")
	try {
		Loop {
			if IsObject(_HUCT.Failure)
				throw _HUCT.Failure
			Finished := IsObject(_HUCT.Warm) && _HUCT.Warm.Returned > Returns && !_HUCT.Warm.InFlight
			if Finished && _HUCT.Posts.Length > Before
				Finished := _HUCT.Posts[_HUCT.Posts.Length].Delivered == 1
			if Finished
				break
			_HUCT_Require(A_TickCount - Started < 1500, "The actual warm callback and transport must settle within the bounded observation.")
			Sleep(5)
		}
	} finally TooltipPositionWarmStop()
	if IsObject(_HUCT.Failure)
		throw _HUCT.Failure
	_HUCT_Context()
	_HUCT_Require(!IsObject(UIASWState.pending) && !IsObject(_TooltipUiaProbePending)
		&& UIASWState.handle == _HUCT.Handle && UIASWState.worker_generation == _HUCT.Generation,
		"Native query completion must preserve readiness with no request/deadline owner.")
	if Seed
		_HUCT_Require(_HUCT.Posts.Length == Before + 1, "The initial genuine failed terminal must actually publish the cache.")
	else
		_HUCT_Require(_HUCT_ExpiryReads() > Reads, "The actual hostile predicate must consume a clock observation before any no-request conclusion.")
	return _HUCT.Posts.Length - Before
}

_HUCT_Report() {
	global _HUCT, _TooltipUiaHostileCache, _TooltipPositionCache
	Entry := _TooltipUiaHostileCache.Get(_HUCT.Proc, 0)
	FileAppend("RECEIPT tooltip-hostile-native64 mode=" . _HUCT.Mode
		. " seed_tick=" . _HUCT.Seed . " now=" . _HUCT.Now . " age=" . (_HUCT.Now - _HUCT.Seed)
		. " ttl=" . TOOLTIP_UIA_HOSTILE_TTL_MS . " posts=" . _HUCT.Posts.Length
		. " query_posts=" . _HUCT.QueryPosts . " warm_calls=" . (IsObject(_HUCT.Warm) ? _HUCT.Warm.Calls : 0)
		. " warm_returned=" . (IsObject(_HUCT.Warm) ? _HUCT.Warm.Returned : 0)
		. " mark_reads=" . _HUCT.Reads.Get("mark", 0) . " expiry_reads=" . _HUCT_ExpiryReads()
		. " entry_tick=" . (IsObject(Entry) ? Entry.Tick : -1) . " stale_ack=" . _HUCT.StaleAck
		. " pending=" . IsObject(UIASWState.pending) . " position=" . IsObject(_TooltipPositionCache)
		. " boundary_failure=" . IsObject(_HUCT.Failure) . "`n", "*", "UTF-8")
}

_HUCT_Main() {
	global _HUCT, _TooltipUiaHostileCache, TOOLTIP_UIA_HOSTILE_TTL_MS
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	_HUCT := {Mode: A_Args[1], Now: 0, Seed: 0, Reads: Map(), Posts: [], Warm: 0,
		Failure: 0, Terminations: 0, QueryPosts: -1, StaleAck: -1}
	_HUCT.Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	Primary := 0, Reported := false, AcquiredHandler := false
	OnError(_HUCT_OnError)
	Critical("Off")
	try {
		_HUCT_Require(!A_IsSuspended && _TooltipUiaHostileCache.Count == 0,
			"The new child must begin with the authentic empty cache.")
		_HUCT.Host := Gui(, "Private tooltip cache target")
		_HUCT.Button := _HUCT.Host.AddButton("w220 h35", "Native non-edit focus")
		_HUCT.Host.Show("w250 h65")
		_HUCT.Button.Focus()
		WinActivate("ahk_id " . _HUCT.Host.Hwnd)
		FocusStarted := A_TickCount
		while (WIGetForegroundHwnd() != _HUCT.Host.Hwnd || WIGetFocusedControlToken() != _HUCT.Button.Hwnd)
			&& A_TickCount - FocusStarted < 1000
			Sleep(5)
		_HUCT.Worker := Gui(, "Private logical UIA sender")
		_HUCT.Worker.Show("Hide w60 h40")
		_HUCT.Proc := WinGetProcessName("ahk_id " . _HUCT.Host.Hwnd)
		Started := A_TickCount
		while A_TimeIdlePhysical < TOOLTIP_UIA_IDLE_REQUIRED_MS && A_TickCount - Started < 1500
			Sleep(5)
		_HUCT.Handle := _HUCT_WorkerHandle()
		UIASWState.worker_generation += 1
		_HUCT.Generation := UIASWState.worker_generation
		UIASWState.handle := _HUCT.Handle, UIASWState.worker_hwnd := _HUCT.Worker.Hwnd
		UIASWState.post_fn := _HUCT_Post, UIASWState.spawn_fn := _HUCT_NoSpawn
		UIASW_EnsureHandlers(), AcquiredHandler := true
		_HUCT.Seed := _HUCT.Mode == "modern-fresh" ? 0x200000000 + 1000 : 0x100000000 + 1000
		_HUCT.Now := _HUCT.Seed
		_HUCT_Query(true)
		Entry := _TooltipUiaHostileCache.Get(_HUCT.Proc, 0)
		_HUCT_Require(IsObject(Entry) && Entry.Tick == _HUCT.Seed
			&& Entry.DurationMs == TOOLTIP_UIA_HOSTILE_TTL_MS && _HUCT.Reads.Get("mark", 0) == 1,
			"Only the real failed terminal may seed the exact typed timestamp and actual TTL.")
		switch _HUCT.Mode {
			case "before": Age := TOOLTIP_UIA_HOSTILE_TTL_MS - 1, Expected := 0
			case "modern-fresh": Age := 1, Expected := 0
			case "long-gap": Age := 0x100000001, Expected := 1
			case "exact", "stale-reply": Age := TOOLTIP_UIA_HOSTILE_TTL_MS, Expected := 1
			default: throw ValueError("Unknown bounded tooltip cache mode.")
		}
		_HUCT.Now += Age
		_HUCT.QueryPosts := _HUCT_Query()
		_HUCT_Report(), Reported := true
		_HUCT_Require(_HUCT.QueryPosts == Expected,
			"The public tooltip query must honor the full native64 hostile-process lifetime.")
		if _HUCT.Mode == "stale-reply" {
			_HUCT_Require(_HUCT.StaleAck == 0, "Only the newer request may consume its actual native reply.")
			_HUCT.Now += 1
			_HUCT_Require(_HUCT_Query() == 0, "The genuinely refreshed modern cache must remain fresh after an old reply.")
		}
	} catch as Failure {
		Primary := IsObject(_HUCT.Failure) ? _HUCT.Failure : Failure
	} finally {
		if !Reported {
			try _HUCT_Report()
			catch as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		try {
			TooltipPositionWarmStop()
			for Record in _HUCT.Posts {
				SetTimer(Record.Timer, 0)
				Record.Timer := 0
			}
			UIASW_Stop("canceled")
			_HUCT_Require(!IsObject(UIASWState.handle) && !IsObject(UIASWState.pending)
				&& !IsObject(UIASWState.start_deadline_fn) && UIASWState.cleanup_debt.Length == 0
				&& UIASWState.process_cleanup_debt.Length == 0 && !UIASWState.cleanup_retry_armed,
				"Exact child worker/request/timer ownership and cleanup debts must actually retire.")
			if IsObject(_HUCT.Warm) {
				SetTimer(_HUCT.Warm.Wrapper, 0)
				_HUCT_Require(!_HUCT.Warm.InFlight && _HUCT.Warm.Returned == _HUCT.Warm.Calls,
					"The real callback must return before its observer can be released.")
				_HUCT.Warm.Callback := 0, _HUCT.Warm.Wrapper := 0
			}
			if AcquiredHandler {
				OnMessage(0x004A, UIASW_OnCopyData, 0)
				UIASWState.handlers_registered := false
			}
			if _HUCT.HasOwnProp("Worker")
				_HUCT.Worker.Destroy()
			if _HUCT.HasOwnProp("Host")
				_HUCT.Host.Destroy()
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_HUCT_OnError, 0)
	}
	if !IsObject(Primary) && IsObject(_HUCT.Failure)
		Primary := _HUCT.Failure
	if IsObject(Primary) {
		FileAppend("FAIL tooltip-hostile-native64 " . Primary.Message . " file=" . Primary.File . " line=" . Primary.Line . "`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS tooltip-hostile-native64 " . _HUCT.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_HUCT_Main()
