; tests/unit/modules/llm/api/test_llm_api_ollama_warmup.ahk

; ==============================================================================
; MODULE: Ollama Auxiliary Results and Warmup Retry
; DESCRIPTION:
; An auxiliary result settles only its exact operation, and the warmup
; retry keeps its in-flight transport through pending, completed and
; disabled states.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Drives the existing public result path through a same-service, same-epoch reentry. */
_G4A_FinalAuxCurrency(Mode, F) {
	Kind := "original_aux_result", Origin := LLM_OllamaRequestOrigin()
	Owner := _LLM_OllamaAuxOwner(0, Kind), Generation := LLM_AuxGeneration()
	OriginalCurrent := F.Flow.Port["current"]
	Successor := 0, Unrelated := 0, Fresh := 0, Reads := 0, Calls := 0, Replaced := false
	try {
		F.Flow.Port["current"] := ReentrantCurrent
		if Mode == "direct"
			_LLM_OllamaInvokeAuxResult(Owner, Observe, false)
		else
			LLM_OllamaDeleteModel_Async("", Observe, 0, Owner)
		Withdrawn := Mode == "first" || Mode == "second" || Mode == "direct"
		AssertEqual(Withdrawn ? 0 : 1, Calls,
			"No retained result may cross its exact operation replacement during either native origin reader.")
		AssertEqual(Generation, LLM_AuxGeneration(), "Same-kind replacement deliberately retains the whole lifecycle epoch.")
		AssertTrue(F.Runtime.HasOwner()), AssertTrue(F.Flow.Ready, "The original service remains ready and unchanged.")
		if Withdrawn {
			AssertTrue(Replaced)
			AssertFalse(LLM_AuxIsCurrent(Owner))
			AssertTrue(LLM_AuxIsCurrent(Successor), "Old settlement must not release the successor's record.")
			_LLM_OllamaInvokeAuxResult(Owner, Observe, false)
			AssertEqual(0, Calls, "Repeated late delivery remains inert.")
		}
		F.Flow.Port["current"] := OriginalCurrent
		Fresh := _LLM_OllamaAuxOwner(0, Kind)
		Before := Calls
		LLM_OllamaDeleteModel_Async("", Observe, 0, Fresh)
		AssertEqual(Before + 1, Calls, "The successor's own public result still settles normally.")
	} finally {
		F.Flow.Port["current"] := OriginalCurrent
		for Exact in [Owner, Successor, Unrelated, Fresh]
			if Exact is Map
				LLM_AuxFinish(Exact)
	}
	ReentrantCurrent() {
		Reads += 1
		Result := OriginalCurrent.Call()
		Boundary := Mode == "second" ? 2 : 1
		if Reads == Boundary && !Replaced && Mode != "unchanged" {
			Replaced := true
			if Mode == "unrelated"
				Unrelated := LLM_AuxBegin("unrelated_inventory_during_reader", Map("endpoint", Origin))
			else
				Successor := LLM_AuxBegin(Kind, Map("endpoint", Origin))
		}
		return Result
	}
	Observe(Value) {
		AssertFalse(Value, "Blank-tag refusal retains its existing Boolean result.")
		Calls += 1
	}
}
for _G4A_FinalAuxMode in ["direct", "first", "second", "unrelated", "unchanged"]
	Test("Ollama auxiliary result: exact operation " . _G4A_FinalAuxMode . " (aux-final-origin-currency)",
		_G4O_WithManaged.Bind(_G4A_FinalAuxCurrency.Bind(_G4A_FinalAuxMode)))


class _OllamaWarmupPendingRetryTransport {
	Completed := false
	Status := 0
	ResponseText := ""
	AbortAccepted := false
	AbortCalls := 0
	SendCalls := 0
	WaitCalls := 0
	CompletedObservations := 0
	DeadlineStart := 0
	DeadlineTimeout := 0

	SetManagedRouting(Settings, Current) {
		this.Current := Current
	}

	SetDeadline(Started, Timeout) {
		this.DeadlineStart := Started
		this.DeadlineTimeout := Timeout
	}

	Open(Method, Url, Async) {
		AssertEqual("POST", Method)
		AssertTrue(Async)
		this.Url := Url
	}

	SetTimeouts(*) {
	}

	SetRequestHeader(Name, Value) {
		AssertEqual("Content-Type", Name)
		AssertEqual("application/json; charset=utf-8", Value)
	}

	Send(Payload) {
		this.SendCalls += 1
		AssertTrue(InStr(Payload, '"num_predict":1') > 0,
			"the real warmup must construct its original one-token request")
		return true
	}

	WaitForResponse(TimeoutSeconds := 0) {
		this.WaitCalls += 1
		AssertEqual(0, TimeoutSeconds, "the retry must never wait for its transport")
		if this.Completed
			this.CompletedObservations += 1
		return this.Completed
	}

	Abort() {
		this.AbortCalls += 1
		return this.AbortAccepted
	}
}

_OllamaWarmupPendingRetryCase(Mode) {
	global _LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupRetryFn
	global _LLM_Ollama_WarmupRetryIntervalMs, _LLM_Ollama_WarmupRetryModel
	global _LLM_Ollama_WarmupStartedTick, _LLM_Ollama_IsReady
	global _LLM_Ollama_WarmupGeneration, _LLM_Ollama_Async, _LLM_Menu
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL, LLM_OLLAMA_WARMUP_TIMEOUT
	global _LLM_Ollama_WarmupPendingFn, _LLM_OLLAMA_WARMUP_POLL_MS
	SavedCritical := Critical("Off")
	HadRetry := IsSet(_LLM_Ollama_WarmupRetryFn)
	SavedRetry := HadRetry ? _LLM_Ollama_WarmupRetryFn : 0
	HadPending := IsSet(_LLM_Ollama_WarmupPendingFn)
	SavedPending := HadPending ? _LLM_Ollama_WarmupPendingFn : 0
	Saved := [_LLM_Ollama_WarmupHttp, _LLM_Ollama_WarmupRetryIntervalMs,
		_LLM_Ollama_WarmupRetryModel, _LLM_Ollama_WarmupStartedTick,
		_LLM_Ollama_IsReady, _LLM_Ollama_WarmupGeneration, _LLM_Ollama_Async, _LLM_Menu,
		_LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL]
	HadCall := CurlAsyncRequest.HasOwnProp("Call")
	SavedCall := HadCall ? CurlAsyncRequest.GetOwnPropDesc("Call") : 0
	SavedBudget := LLM_OLLAMA_WARMUP_TIMEOUT
	SavedPollMs := _LLM_OLLAMA_WARMUP_POLL_MS
	HadLogCall := LoggerInfo.HasOwnProp("Call")
	SavedLogCall := HadLogCall ? LoggerInfo.GetOwnPropDesc("Call") : 0
	TimeoutCallbacks := 0
	Requests := []
	ConstructorReentered := false
	RetryCallback := (*) => 0
	try {
		_LLM_Ollama_WarmupHttp := 0
		_LLM_Ollama_WarmupRetryFn := RetryCallback
		_LLM_Ollama_WarmupPendingFn := 0
		_LLM_Ollama_WarmupRetryIntervalMs := 5000
		_LLM_Ollama_WarmupRetryModel := "qwen3.5:0.8b"
		_LLM_Ollama_WarmupStartedTick := A_TickCount
		_LLM_Ollama_IsReady := false
		_LLM_Ollama_WarmupGeneration += 100
		_LLM_Ollama_Async := Map()
		_LLM_Menu := Map("enabled", true)
		_LLM_ManagedBootstrap := 0
		LLM_OLLAMA_BASE_URL := "http://localhost:16107"
		if Mode == "deadline" {
			LLM_OLLAMA_WARMUP_TIMEOUT := 60
			_LLM_OLLAMA_WARMUP_POLL_MS := 10
			LoggerInfo.DefineProp("Call", {Call: ObserveLog})
		}
		CurlAsyncRequest.DefineProp("Call", {Call: Construct})
		InitialResult := LLM_OllamaWarmup("qwen3.5:0.8b")
		if Mode == "constructor-reentrant" {
			AssertFalse(InitialResult, "the withdrawn outer acquisition must refuse")
			AssertEqual(2, Requests.Length)
			AssertTrue(Requests[1] != Requests[2], "reentrant construction must return distinct candidate instances")
			AssertTrue(_LLM_Ollama_WarmupHttp == Requests[2],
				"the outer constructor must not overwrite or retire its successor")
			AssertEqual(0, Requests[1].SendCalls)
			AssertEqual(1, Requests[2].SendCalls)
			AssertEqual(0, Requests[2].AbortCalls)
			AssertTrue(_LLM_Ollama_WarmupPendingFn.Call("replacement-model"),
				"the successor must retain its genuine pending predicate")
			return
		}
		AssertTrue(InitialResult,
			"the unchanged public warmup must genuinely acquire its controlled transport")
		AssertEqual(1, Requests.Length)
		OriginalRequest := Requests[1]
		AssertTrue(_LLM_Ollama_WarmupHttp == OriginalRequest)
		AssertEqual(1, OriginalRequest.SendCalls)
		AssertEqual(LLM_OLLAMA_WARMUP_TIMEOUT, OriginalRequest.DeadlineTimeout)
		OriginalGeneration := _LLM_Ollama_WarmupGeneration
		OriginalStart := OriginalRequest.DeadlineStart
		OriginalWaits := OriginalRequest.WaitCalls
		if Mode == "complete" {
			OriginalRequest.Completed := true
			OriginalRequest.AbortAccepted := true
		} else if Mode == "disabled"
			_LLM_Menu["enabled"] := false
		else if Mode == "ready"
			_LLM_Ollama_IsReady := true
		if Mode == "model-refusal" {
			_LLM_Ollama_WarmupRetryModel := "replacement-model"
			AssertFalse(LLM_OllamaWarmup("replacement-model"))
			_LLM_Ollama_OnWarmupDone(200, OriginalGeneration)
			AssertFalse(_LLM_Ollama_IsReady,
				"a refused replacement must still invalidate its predecessor's late success")
			AssertEqual(1, OriginalRequest.AbortCalls)
			AssertEqual(1, Requests.Length)
			return
		}
		if Mode == "deadline" {
			loop 2 {
				LLM_Ollama_WarmupRetryTick()
				AssertEqual(0, OriginalRequest.AbortCalls)
				Sleep(10)
			}
			while TimeoutCallbacks == 0 && A_TickCount - OriginalStart < 2000
				Sleep(10)
			AssertEqual(1, TimeoutCallbacks, "the original real poll must reach its unchanged absolute timeout")
			AssertEqual(1, OriginalRequest.AbortCalls)
			TerminalWaits := OriginalRequest.WaitCalls
			Sleep(30)
			AssertEqual(TerminalWaits, OriginalRequest.WaitCalls, "the timed-out anonymous poll must stop")
			LLM_Ollama_WarmupRetryTick()
			AssertEqual(2, OriginalRequest.AbortCalls,
				"an expired request cannot retain a pending-observation lease over its cancellation debt")
			AssertEqual(1, Requests.Length, "refused timeout cleanup must still prevent overlap")
			AssertEqual(60, OriginalRequest.DeadlineTimeout)
			return
		}
		LLM_Ollama_WarmupRetryTick()
		if Mode == "pending" {
			LLM_Ollama_WarmupRetryTick()
			AssertEqual(0, OriginalRequest.AbortCalls,
				"ordinary retries must not cancel their own unfinished request")
			AssertEqual(1, Requests.Length)
			AssertEqual(5000, _LLM_Ollama_WarmupRetryIntervalMs,
				"observing a pending request must not consume attempt backoff")
			AssertEqual(OriginalGeneration, _LLM_Ollama_WarmupGeneration)
			AssertTrue(_LLM_Ollama_WarmupRetryFn == RetryCallback)
			AssertTrue(_LLM_Ollama_WarmupHttp == OriginalRequest)
		} else if Mode == "complete" {
			AssertEqual(1, OriginalRequest.AbortCalls)
			AssertEqual(2, Requests.Length,
				"a completed failure must permit one real successor dispatch")
			AssertTrue(_LLM_Ollama_WarmupHttp == Requests[2])
			AssertEqual(1, Requests[2].SendCalls)
			AssertEqual(10000, _LLM_Ollama_WarmupRetryIntervalMs)
		} else if Mode == "disabled" {
			AssertEqual(1, OriginalRequest.AbortCalls,
				"disabling must still attempt cancellation of the pending request")
			AssertEqual(OriginalWaits, OriginalRequest.WaitCalls)
			AssertEqual(OriginalGeneration + 1, _LLM_Ollama_WarmupGeneration)
			AssertTrue(_LLM_Ollama_WarmupHttp == OriginalRequest)
		} else {
			AssertEqual(0, OriginalRequest.AbortCalls)
			AssertEqual(OriginalWaits, OriginalRequest.WaitCalls)
		}
		AssertEqual(OriginalStart, OriginalRequest.DeadlineStart)
		AssertEqual(LLM_OLLAMA_WARMUP_TIMEOUT, OriginalRequest.DeadlineTimeout)
	} finally {
		PollsDrained := false
		try {
			if IsSet(_LLM_Ollama_WarmupRetryFn) && IsObject(_LLM_Ollama_WarmupRetryFn)
				SetTimer(_LLM_Ollama_WarmupRetryFn, 0)
			SetTimer(RetryCallback, 0)
			; Let the real anonymous poll observe completion under an invalid generation.
			_LLM_Ollama_WarmupGeneration += 1
			for ControlledRequest in Requests
				ControlledRequest.Completed := true
			DrainStarted := A_TickCount
			loop {
				PollsDrained := true
				for ControlledRequest in Requests
					if ControlledRequest.WaitCalls > 0 && ControlledRequest.CompletedObservations == 0 && TimeoutCallbacks == 0
						PollsDrained := false
				if PollsDrained || A_TickCount - DrainStarted >= 2000
					break
				Sleep(10)
			}
		} finally {
			try {
				if HadCall
					CurlAsyncRequest.DefineProp("Call", SavedCall)
				else
					CurlAsyncRequest.DeleteProp("Call")
			} finally {
				try {
					if HadLogCall
						LoggerInfo.DefineProp("Call", SavedLogCall)
					else if LoggerInfo.HasOwnProp("Call")
						LoggerInfo.DeleteProp("Call")
				} finally {
					_LLM_Ollama_WarmupRetryFn := HadRetry ? SavedRetry : unset
					_LLM_Ollama_WarmupPendingFn := HadPending ? SavedPending : unset
					LLM_OLLAMA_WARMUP_TIMEOUT := SavedBudget
					_LLM_OLLAMA_WARMUP_POLL_MS := SavedPollMs
					_LLM_Ollama_WarmupHttp := Saved[1]
					_LLM_Ollama_WarmupRetryIntervalMs := Saved[2]
					_LLM_Ollama_WarmupRetryModel := Saved[3]
					_LLM_Ollama_WarmupStartedTick := Saved[4]
					_LLM_Ollama_IsReady := Saved[5]
					_LLM_Ollama_WarmupGeneration := Saved[6]
					_LLM_Ollama_Async := Saved[7]
					_LLM_Menu := Saved[8]
					_LLM_ManagedBootstrap := Saved[9]
					LLM_OLLAMA_BASE_URL := Saved[10]
					Critical(SavedCritical)
				}
			}
		}
		AssertTrue(PollsDrained, "each scheduled anonymous poll must observe terminal completion before restoration")
	}

	ObserveLog(LoggerFunction, Category, Message, Args*) {
		AssertTrue(LoggerFunction == LoggerInfo)
		if Category == "LLM.ollama" && InStr(Message, "Warmup poll ended") && Args.Length > 0 && Args[1] == "timeout"
			TimeoutCallbacks += 1
	}
	Construct(Factory, Args*) {
		AssertTrue(Factory == CurlAsyncRequest)
		AssertEqual(0, Args.Length)
		local FreshTransport := _OllamaWarmupPendingRetryTransport()
		Requests.Push(FreshTransport)
		if Mode == "constructor-reentrant" && !ConstructorReentered {
			ConstructorReentered := true
			AssertTrue(LLM_OllamaWarmup("replacement-model"),
				"the constructor observer must genuinely acquire the successor first")
		}
		return FreshTransport
	}
}
for _OllamaPendingRetryMode in ["pending", "complete", "disabled", "ready", "model-refusal", "constructor-reentrant", "deadline"]
	Test("warmup-inflight-retry: actual warmup " . _OllamaPendingRetryMode,
		_OllamaWarmupPendingRetryCase.Bind(_OllamaPendingRetryMode))
