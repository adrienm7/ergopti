; tests/unit/test_local_server_models.ahk

; ==============================================================================
; MODULE: Owned Local Models Request Tests
; DESCRIPTION:
; Exercises the actual curl request and owner with controlled child receipts,
; exact Windows artifact locks and a real tree-owned protected native handle.
; Controlled process receipts establish causality, not network E2E evidence.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ Actual Curl Owner Fixture =======
; ============================================
; ============================================

class _LSM_ChildReceipt {
	__New() {
		this.Starts := 0
		this.Terminations := 0
		this.TerminateAllowed := true
	}

	start() {
		this.Starts += 1
		return true
	}

	terminate() {
		this.Terminations += 1
		return this.TerminateAllowed
	}
}

class _LSM_Fixture {
	__New() {
		global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER
		this.SavedAbortTimer := _HTTP_CURL_ABORT_TIMER
		this.SavedCleanupTimer := _HTTP_CURL_CLEANUP_TIMER
		_HTTP_CURL_ABORT_TIMER := {}
		_HTTP_CURL_CLEANUP_TIMER := {}
		this.Generation := 1
		this.Time := 0
		this.Requests := []
		this.Children := []
		this.Configs := []
		this.Timers := Map()
		this.Results := []
		this.Errors := []
		this.CallbackCritical := []
		this.RefuseStop := false
		this.OnFactory := 0
		this.OnLaunch := 0
		this.OnTicket := 0
		this.OnDone := 0
		this.NativeSpawn := 0
		this.Owner := LocalServerModelsOwner(Map("servers", Map("lmstudio", Map("auth", "optional")),
			"timeout_ms", 1000, "poll_ms", 20,
			"clock", ObjBindMethod(this, "Clock"), "timer", ObjBindMethod(this, "Timer"),
			"request", ObjBindMethod(this, "Request"), "on_error", ObjBindMethod(this, "Report")))
	}

	Target(Token := "") {
		return Map("id", "lmstudio", "base_url", "http://127.0.0.1:19273/custom/v1/", "token", Token)
	}

	Ticket() {
		return Map("is_current", ObjBindMethod(this, "Current", this.Generation))
	}

	Current(Generation) {
		this.CallbackCritical.Push(A_IsCritical)
		if HasMethod(this.OnTicket, "Call")
			this.OnTicket.Call()
		return Generation == this.Generation
	}

	Clock() {
		this.CallbackCritical.Push(A_IsCritical)
		return this.Time
	}

	Timer(Callback, Period) {
		this.CallbackCritical.Push(A_IsCritical)
		if Period == 0 {
			if this.RefuseStop
				return false
			if this.Timers.Has(ObjPtr(Callback))
				this.Timers.Delete(ObjPtr(Callback))
		} else {
			this.Timers[ObjPtr(Callback)] := Callback
		}
		return true
	}

	Request() {
		this.CallbackCritical.Push(A_IsCritical)
		Request := CurlAsyncRequest(Map("spawn", ObjBindMethod(this, "Spawn"),
			"before_launch", ObjBindMethod(this, "BeforeLaunch")))
		this.Requests.Push(Request)
		if HasMethod(this.OnFactory, "Call")
			this.OnFactory.Call()
		return Request
	}

	BeforeLaunch(Request) {
		if HasMethod(this.OnLaunch, "Call")
			this.OnLaunch.Call(Request)
	}

	Spawn(Executable, Args, OnDone, OnChunk, BeforeAdopt, MaxBytes) {
		this.CallbackCritical.Push(A_IsCritical)
		Request := this.Requests[this.Requests.Length]
		this.Configs.Push(FileRead(Request.ConfigPath, "UTF-8"))
		if HasMethod(this.NativeSpawn, "Call")
			Child := this.NativeSpawn.Call(OnDone)
		else
			Child := _LSM_ChildReceipt()
		this.Children.Push(Child)
		return Child
	}

	Done(Receipt) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Results.Push(Receipt)
		if HasMethod(this.OnDone, "Call")
			this.OnDone.Call()
	}

	Report(Kind, Err, Id) {
		this.CallbackCritical.Push(A_IsCritical)
		this.Errors.Push(Kind)
	}

	Probe(Token := "") {
		return this.Owner.Probe(this.Target(Token), ObjBindMethod(this, "Done"), this.Ticket())
	}

	Complete(Index, Status, Body) {
		Request := this.Requests[Index]
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 " . Status . " Fixture`r`n`r`n"))
		Request._OnDone(0, Body, "")
		this.Owner.RetryPending()
	}

	Dispose() {
		global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER
		try {
			this.RefuseStop := false
			for Child in this.Children
				if Child is _LSM_ChildReceipt
					Child.TerminateAllowed := true
			this.Owner.Cancel("lmstudio")
			this.Owner.RetryPending()
			for Request in this.Requests {
				AssertTrue(Request.Abort(), "fixture must settle its exact child")
				AssertTrue(Request._Cleanup(), "fixture must settle its private curl artifacts")
			}
			AssertFalse(this.Owner.HasPending("lmstudio"), "fixture must retain no models request")
			AssertEqual(0, this.Timers.Count, "fixture must retain no owner timer")
		} finally {
			_HTTP_CURL_ABORT_TIMER := this.SavedAbortTimer
			_HTTP_CURL_CLEANUP_TIMER := this.SavedCleanupTimer
		}
	}
}





; ================================================
; ================================================
; ======= 2/ Typed Receipts And Stale Work =======
; ================================================
; ================================================

_LSM_Receipt(Status, Body, Admitted, Count) {
	Fixture := _LSM_Fixture()
	try {
		AssertTrue(Fixture.Probe())
		AssertEqual("GET", Fixture.Requests[1].Method)
		AssertEqual("http://127.0.0.1:19273/custom/v1/models", Fixture.Requests[1].Url,
			"the configured endpoint is authoritative")
		AssertFalse(InStr(Fixture.Configs[1], "Authorization:"), "an empty key creates no Authorization header")
		Fixture.Complete(1, Status, Body)
		AssertEqual(1, Fixture.Results.Length)
		Result := Fixture.Results[1]
		AssertTrue(Result["ok"] is Integer)
		AssertEqual(Admitted, Result["ok"])
		AssertEqual(Status, Result["status"])
		AssertEqual(Body, Result["body"])
		AssertEqual(Count, Result["models"].Length)
		if Count == 3 {
			AssertEqual("second", Result["models"][1], "the original first model stays first")
			AssertEqual("first", Result["models"][2], "model receipts preserve source order")
			AssertEqual("second", Result["models"][3], "duplicate model identifiers remain present")
		}
		Fixture.Owner.RetryPending()
		AssertEqual(1, Fixture.Results.Length, "resource retries cannot redeliver the typed receipt")
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		for WasCritical in Fixture.CallbackCritical
			AssertEqual(0, WasCritical, "native and logical ports run outside Critical")
	} finally Fixture.Dispose()
}
Test("local models owner: valid ordered duplicate identifiers", _LSM_Receipt.Bind(200, '{"data":[{"id":"second"},{"id":"first"},{"id":"second"}]}', true, 3))
Test("local models owner: valid empty list", _LSM_Receipt.Bind(200, '{"data":[]}', true, 0))
Test("local models owner: malformed row refuses success", _LSM_Receipt.Bind(200, '{"data":[{"id":""}]}', false, 0))
Test("local models owner: malformed JSON refuses success", _LSM_Receipt.Bind(200, '{', false, 0))
Test("local models owner: authentication-required status remains typed", _LSM_Receipt.Bind(401, '{"error":"key required"}', false, 0))
Test("local models owner: forbidden status remains typed", _LSM_Receipt.Bind(403, '{"error":"forbidden"}', false, 0))
Test("local models owner: a non-200 response is not a model list", _LSM_Receipt.Bind(204, '{"data":[]}', false, 0))

_LSM_ExactKey() {
	Fixture := _LSM_Fixture()
	try {
		Token := " leading-and-trailing "
		AssertTrue(Fixture.Probe(Token))
		AssertEqual("Bearer " . Token, Fixture.Requests[1].Headers["Authorization"])
		AssertContains(Fixture.Configs[1], "Authorization: Bearer " . Token,
			"provided credentials retain their exact bytes in the private curl config")
		Fixture.Complete(1, 200, '{"data":[]}')
	} finally Fixture.Dispose()
}
Test("local models owner: configured credential bytes are exact", _LSM_ExactKey)

_LSM_StaleBeforeDispatch(Boundary) {
	Fixture := _LSM_Fixture()
	MakeStale(*) {
		Fixture.Generation += 1
	}
	try {
		if Boundary == "ticket" {
			Stale := Fixture.Ticket()
			Fixture.Generation += 1
			AssertFalse(Fixture.Owner.Probe(Fixture.Target(), ObjBindMethod(Fixture, "Done"), Stale))
		} else {
			if Boundary == "factory"
				Fixture.OnFactory := MakeStale
			else
				Fixture.OnLaunch := MakeStale
			AssertFalse(Fixture.Probe())
		}
		AssertEqual(0, Fixture.Children.Length, "no child can dispatch after a stale native acquisition boundary")
		AssertEqual(0, Fixture.Results.Length)
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
	} finally Fixture.Dispose()
}
for Boundary in ["ticket", "factory", "launch"]
	Test("local models owner: stale " . Boundary . " cannot dispatch", _LSM_StaleBeforeDispatch.Bind(Boundary))

_LSM_RefusedOldOwner(NaturalCompletion) {
	global _HTTP_CURL_ABORT_DEBTS
	Fixture := _LSM_Fixture()
	try {
		AssertTrue(Fixture.Probe())
		Old := Fixture.Requests[1], Child := Fixture.Children[1]
		Child.TerminateAllowed := false
		Fixture.Generation += 1
		Fixture.Owner.RetryPending()
		AssertTrue(Old.Aborted && !Old.Completed)
		AssertTrue(Old.Handle == Child)
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Get(Old.CleanupDebtId, 0) == Old)
		AssertFalse(Fixture.Probe(), "a refused old child blocks a same-provider successor")
		AssertEqual(1, Fixture.Requests.Length, "successor refusal must not acquire another request")
		AssertEqual(0, Fixture.Results.Length)
		if NaturalCompletion
			Old._OnDone(0, '{"data":[{"id":"discard-old"}]}', "")
		else
			Child.TerminateAllowed := true
		Fixture.Owner.RetryPending()
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Old.CleanupDebtId))
		AssertTrue(Fixture.Probe())
		Old._OnDone(0, '{"data":[{"id":"discard-duplicate"}]}', "")
		AssertTrue(Fixture.Owner.HasPending("lmstudio"), "old completion cannot release its successor's owner")
		Fixture.Complete(2, 200, '{"data":[{"id":"new-model"}]}')
		AssertEqual(1, Fixture.Results.Length)
		AssertEqual("new-model", Fixture.Results[1]["models"][1])
	} finally Fixture.Dispose()
}
Test("local models owner: refused old child settles only through exact retry", _LSM_RefusedOldOwner.Bind(false))
Test("local models owner: refused old child natural completion cannot settle successor", _LSM_RefusedOldOwner.Bind(true))


_LSM_CreatorCancellationDebt() {
	Fixture := _LSM_Fixture()
	Observed := Map("called", false, "cancel", true, "successor", true)
	CancelCreator() {
		Fixture.OnFactory := 0
		Observed["called"] := true
		Observed["cancel"] := Fixture.Owner.Cancel("lmstudio")
		Fixture.Generation += 1
		Observed["successor"] := Fixture.Probe()
	}
	try {
		Fixture.OnFactory := CancelCreator
		AssertFalse(Fixture.Probe())
		AssertTrue(Observed["called"], "the creator boundary must actually execute")
		AssertFalse(Observed["cancel"], "a factory in flight retains creator ownership")
		AssertFalse(Observed["successor"], "a creator cancellation is not physical request settlement")
		AssertEqual(1, Fixture.Requests.Length, "a successor must not enter the retained factory slot")
		AssertEqual(0, Fixture.Children.Length)
		AssertEqual(0, Fixture.Results.Length)
		AssertTrue(Fixture.Requests[1].Completed && Fixture.Requests[1].Aborted,
			"the late factory result must be cancelled by its exact original owner")
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
	} finally Fixture.Dispose()
}
Test("local models owner: reentrant factory cancellation retains creator debt", _LSM_CreatorCancellationDebt)

_LSM_TimerStopRefusal() {
	Fixture := _LSM_Fixture()
	Threw := false
	try {
		AssertTrue(Fixture.Probe())
		Fixture.RefuseStop := true
		try Fixture.Complete(1, 200, '{"data":[]}')
		catch {
			Threw := true
		}
		AssertTrue(Threw, "a timer-stop refusal must report failure rather than retire ownership")
		ReportedTimer := false
		for Kind in Fixture.Errors
			if Kind == "timer"
				ReportedTimer := true
		AssertTrue(ReportedTimer, "the refusal must specifically report the timer operation")
		AssertEqual(1, Fixture.Results.Length)
		AssertTrue(Fixture.Owner.HasPending("lmstudio"))
		AssertEqual(1, Fixture.Timers.Count, "the exact callback remains owned until stop acknowledgement")
		Fixture.RefuseStop := false
		Fixture.Owner.RetryPending()
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		AssertEqual(0, Fixture.Timers.Count)
		AssertEqual(1, Fixture.Results.Length, "timer recovery cannot repeat the observer")
	} finally {
		Fixture.RefuseStop := false
		Fixture.Dispose()
	}
}
Test("local models owner: refused timer stop retains exact callback ownership", _LSM_TimerStopRefusal)

_LSM_ReentrantDeliveryGate() {
	Fixture := _LSM_Fixture()
	try {
		AssertTrue(Fixture.Probe())
		Calls := 0
		SupersedeOnDelivery() {
			Calls += 1
			if Calls == 2 {
				Fixture.OnTicket := 0
				Fixture.Generation += 1
				AssertTrue(Fixture.Probe())
			}
		}
		Fixture.OnTicket := SupersedeOnDelivery
		Fixture.Complete(1, 200, '{"data":[{"id":"old-model"}]}')
		AssertEqual(0, Fixture.Results.Length, "the independent delivery ticket must reject the parsed old response")
		AssertEqual(2, Fixture.Requests.Length, "the delivery boundary must actually acquire the successor")
		Fixture.Complete(2, 200, '{"data":[{"id":"new-model"}]}')
		AssertEqual(1, Fixture.Results.Length)
		AssertEqual("new-model", Fixture.Results[1]["models"][1])
	} finally Fixture.Dispose()
}
Test("local models owner: reentrant delivery ticket cannot publish a stale response", _LSM_ReentrantDeliveryGate)

_LSM_Timeout() {
	Fixture := _LSM_Fixture()
	try {
		AssertTrue(Fixture.Probe())
		Fixture.Children[1].TerminateAllowed := false
		Fixture.Time := 1000
		Fixture.Owner.RetryPending()
		AssertEqual(1, Fixture.Results.Length)
		AssertFalse(Fixture.Results[1]["ok"])
		AssertEqual(0, Fixture.Results[1]["status"])
		AssertTrue(Fixture.Owner.HasPending("lmstudio"), "timeout delivery cannot acknowledge a refused physical stop")
		Fixture.Owner.RetryPending()
		AssertEqual(1, Fixture.Results.Length)
		Fixture.Children[1].TerminateAllowed := true
		Fixture.Owner.RetryPending()
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
	} finally Fixture.Dispose()
}
Test("local models owner: timeout delivery and exact cancellation debt are independent", _LSM_Timeout)

_LSM_PausedDelivery() {
	Fixture := _LSM_Fixture()
	PreviousSuspend := A_IsSuspended
	try {
		Suspend(false)
		AssertTrue(Fixture.Probe())
		Suspend(true)
		Fixture.Complete(1, 200, '{"data":[]}')
		AssertEqual(0, Fixture.Results.Length, "pause defers a completed request's observer")
		AssertTrue(Fixture.Owner.HasPending("lmstudio"))
		Suspend(false)
		Fixture.Owner.RetryPending()
		AssertEqual(1, Fixture.Results.Length)
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
	} finally {
		try Fixture.Dispose()
		finally Suspend(PreviousSuspend)
	}
}
Test("local models owner: pause preserves response delivery ownership", _LSM_PausedDelivery)





; ==========================================
; ==========================================
; ======= 3/ Native Refusal Receipts =======
; ==========================================
; ==========================================

_LSM_PrivateConfigLock() {
	Fixture := _LSM_Fixture()
	Lock := 0
	try {
		AssertTrue(Fixture.Probe())
		Request := Fixture.Requests[1]
		Lock := DllCall("Kernel32\CreateFileW", "WStr", Request.ConfigPath,
			"UInt", 0x80000000, "UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
		AssertTrue(Lock != 0 && Lock != -1, "the fixture must hold a real non-delete-sharing config handle")
		Fixture.Complete(1, 200, '{"data":[]}')
		AssertEqual(1, Fixture.Results.Length, "model delivery does not erase artifact debt")
		AssertTrue(Request.Completed && Request.CleanupPending)
		AssertTrue(Fixture.Owner.HasPending("lmstudio"))
		AssertFalse(Fixture.Probe(), "a same-provider successor cannot replace locked request artifacts")
		AssertEqual(1, Fixture.Requests.Length)
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int"))
		Lock := 0
		Fixture.Owner.RetryPending()
		AssertFalse(Request.CleanupPending)
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		AssertEqual(1, Fixture.Results.Length, "cleanup recovery cannot repeat delivery")
	} finally {
		try {
			if Lock != 0 && Lock != -1
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int"))
		} finally Fixture.Dispose()
	}
}
Test("local models owner: real private curl config lock retains exact artifact debt", _LSM_PrivateConfigLock)

_LSM_NativeProcessCloseRefusal() {
	static ProtectFromClose := 0x0002
	global _HTTP_CURL_ABORT_DEBTS
	Fixture := _LSM_Fixture()
	Native := 0, Protected := 0, GuardJob := 0
	ChildPath := A_Temp . "\ergopti_models_child_" . _HTTP_CurlNextRequestId() . ".ahk"
	Observe(State, Capability) {
		Native := State
		Protected := Capability["ProcessHandle"]
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Protected,
			"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int"))
		Process := DllCall("Kernel32\GetCurrentProcess", "Ptr")
		AssertTrue(DllCall("Kernel32\DuplicateHandle", "Ptr", Process,
			"Ptr", Capability["JobHandle"], "Ptr", Process, "Ptr*", &GuardJob,
			"UInt", 0, "Int", false, "UInt", 2, "Int"))
	}
	SpawnNative(OnDone) {
		return ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", ChildPath], OnDone, , Observe)
	}
	try {
		FileAppend("; support/models_owned_child.ahk`n#Requires AutoHotkey v2.0`nSleep(30000)`n", ChildPath, "UTF-8")
		Fixture.NativeSpawn := SpawnNative
		AssertTrue(Fixture.Probe())
		Request := Fixture.Requests[1]
		AssertTrue(Native is Map && Protected != 0 && GuardJob != 0)
		AssertFalse(Fixture.Owner.Cancel("lmstudio"), "an exact native process close refusal is still ownership debt")
		AssertTrue(Request.Aborted && !Request.Completed)
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Get(Request.CleanupDebtId, 0) == Request)
		AssertTrue(Fixture.Owner.HasPending("lmstudio"))
		Fixture.Generation += 1
		AssertFalse(Fixture.Probe(), "an accepted job termination request cannot authorize a successor")
		AssertEqual(1, Fixture.Requests.Length)
		Flags := 0
		AssertTrue(DllCall("Kernel32\GetHandleInformation", "Ptr", Protected, "UInt*", &Flags, "Int"))
		AssertTrue((Flags & ProtectFromClose) != 0, "the old exact capability stays valid and protected")
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Protected,
			"UInt", ProtectFromClose, "UInt", 0, "Int"))
		Protected := 0
		Fixture.Owner.RetryPending()
		AssertTrue(Request.Completed)
		AssertFalse(Fixture.Owner.HasPending("lmstudio"))
		AssertEqual(0, Fixture.Results.Length, "native cancellation cannot deliver a model receipt")
		Accounting := Buffer(48, 0)
		AssertTrue(DllCall("Kernel32\QueryInformationJobObject", "Ptr", GuardJob,
			"Int", 1, "Ptr", Accounting.Ptr, "UInt", Accounting.Size, "Ptr", 0, "Int"))
		AssertEqual(0, NumGet(Accounting, 40, "UInt"), "the independent exact job reports no surviving process")
	} finally {
		try {
			if Protected {
				AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Protected,
					"UInt", ProtectFromClose, "UInt", 0, "Int"))
				Protected := 0
			}
			Fixture.Dispose()
			_SR_TreePoll()
		} finally {
			try {
				if GuardJob
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", GuardJob, "Int"))
			} finally {
				if FileExist(ChildPath)
					FileDelete(ChildPath)
			}
		}
	}
}
Test("local models owner: real protected process capability blocks successor admission", _LSM_NativeProcessCloseRefusal)
