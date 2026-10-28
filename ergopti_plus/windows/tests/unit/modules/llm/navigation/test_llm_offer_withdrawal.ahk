; tests/unit/modules/llm/navigation/test_llm_offer_withdrawal.ahk

; ==============================================================================
; MODULE: Synchronous LLM Offer Withdrawal
; DESCRIPTION:
; The real surface commit, acceptance reader and native-owner protocol run before
; a deferred visual hide. Only graphics are represented by detached empty rows;
; the test never writes cancellation or lifecycle outcomes on the owner's behalf.
; ==============================================================================

#Requires AutoHotkey v2.0

_OWU_Forward(Target, Self, Args*) => Target.Call(Args*)
_OWU_Hide(Self, Record, Accepted := false) => LLM_TooltipHide(Accepted, unset, unset, Record)

_OWU_Run(Mode) {
	global _TooltipActiveSurface, _TooltipGeneration, _LLM_TooltipMetricQueue
	SavedSurface := _TooltipActiveSurface, SavedGeneration := _TooltipGeneration
	SavedMetrics := _LLM_TooltipMetricQueue
	PreviousCritical := Critical("On")
	Hooks := Map("LLM_Tooltip_GetPresentedToken", _OWU_Forward.Bind(LLM_TooltipGetPresentedToken),
		"LLM_Tooltip_HideExact", _OWU_Hide)
	if IsSet(LLM_Tooltip_WithdrawExact) && IsSet(LLM_TooltipWithdrawExact)
		Hooks["LLM_Tooltip_WithdrawExact"] := _OWU_Forward.Bind(LLM_TooltipWithdrawExact)
	Installed := []
	State := 0
	try {
		State := _LNEO_Setup()
		_LLM_TooltipMetricQueue := []
		for Name, Callback in Hooks {
			Fn := %Name%
			AssertFalse(Fn.HasOwnProp("Call"), "The facade cannot adopt another observer: " . Name)
			Fn.DefineProp("Call", {Call: Callback})
			Installed.Push(Fn)
		}
		A := _LTAV_RenderPrediction(["A", "A2"], 1, true)
		Record := A.LlmPresented
		Snapshot := LLM_TooltipGetAcceptSnapshot()
		AssertTrue(IsObject(Snapshot) && Snapshot.Record == Record,
			"The real UI owner must initially authorize its actual committed record")
		AssertEqual(Record.NavOwnerToken, State.CurrentToken, "Native protocol must own the committed offer")
		if Mode == "admitted" {
			Claim := LLM_TooltipClaimAcceptance(Record, A, 1)
			AssertTrue(IsObject(Claim), "An admitted unchanged offer must still claim")
			AssertEqual("claimed", Claim.Outcome)
			return
		}
		if Mode == "claimed-output" {
			AssertTrue(IsObject(LLM_TooltipClaimAcceptance(Record, A, 1)))
			AssertTrue(LLM_Bridge_DeferTooltipHide(false, Record))
			AssertEqual("claimed", Record.Lifecycle.Outcome, "Withdrawal cannot rewrite the sender's existing claim")
			_OWU_AssertTerminalRender(Record, A, false)
			AssertTrue(LLM_TooltipFinalizeAcceptance(Record.Lifecycle, true))
			AssertEqual("accepted", Record.Lifecycle.Outcome)
			return
		}
		if Mode == "stale-owner" {
			B := _LTAV_RenderPrediction(["B"], 1, true)
			LLM_Bridge_DeferTooltipHide(false, Record)
			_LLM_Bridge_DeferredTooltipHide(Record, false)
			AssertTrue(_TooltipActiveSurface == B)
			AssertEqual(B.LlmPresented.NavOwnerToken, State.CurrentToken)
			AssertTrue(IsObject(LLM_TooltipGetAcceptSnapshot()), "An old owner cannot revoke the new offer")
			return
		}
		if Mode == "native-index" || Mode == "late-receipt" {
			Receipt := _LNEO_Receipt(49001, Record.NavOwnerToken, 2)
			Receipt["action"] := 1
			Receipt["delta"] := 1
			_LNEO_QueueNativeDecision(State, _LNEO_SuppressResult(49001), Receipt)
			AssertTrue(LLM_NavEventOwner_TestDispatch(_LNEO_NativeEvent(0x28, 0x150, 0, 1), State.Port) is Map)
			AssertEqual(2, State.OwnerIndices[Record.NavOwnerToken], "The real protocol ingress advances native navigation")
			AssertEqual(1, Record.ActiveIdx, "AHK has not yet drained or repainted that receipt")
		}
		if Mode == "idempotent"
			AssertTrue(_LLM_TooltipMarkSurfaceSuggested(A), "The graphics receipt admits one suggested lifecycle")
		AssertTrue(LLM_Bridge_DeferTooltipHide(), "The actual bridge accepts withdrawal of its current offer")
		if Mode == "idempotent" {
			AssertTrue(LLM_Bridge_DeferTooltipHide(false, Record))
			AssertEqual(2, _LLM_TooltipMetricQueue.Length, "One suggested and one dismissal event are queued exactly once")
			AssertEqual("dismissed", _LLM_TooltipMetricQueue[2].Kind)
		}
		if Mode == "same-offer"
			_OWU_AssertTerminalRender(Record, A, true)
		if Mode == "late-receipt" {
			Probe := {Repaint: 0, Accept: 0}
			AssertTrue(LLM_NavEventOwner_Drain(_OWU_ReceiptRepaint.Bind(Probe), 0, 0, _OWU_ReceiptAccept.Bind(Probe)))
			AssertEqual(0, Probe.Repaint, "A pre-withdrawal receipt cannot repaint a retired lifecycle")
			AssertEqual(0, Probe.Accept, "A pre-withdrawal receipt cannot arm text output")
			AssertEqual(0, State.Pending.Get(Record.NavOwnerToken, 0), "The stale receipt is acknowledged instead of leaked")
		}
		if Mode == "replacement" {
			B := _LTAV_RenderPrediction(["B"], 1, true)
			_LLM_Bridge_DeferredTooltipHide(Record, false)
			AssertTrue(_TooltipActiveSurface == B, "An old deferred hide cannot erase a newly committed surface")
			AssertEqual(B.LlmPresented.NavOwnerToken, State.CurrentToken)
			AssertTrue(IsObject(LLM_TooltipGetAcceptSnapshot()), "The exact replacement remains acceptable")
			return
		}
		AssertFalse(IsObject(LLM_TooltipGetAcceptSnapshot()),
			"Withdrawal must revoke acceptance before any deferred visual callback")
		AssertFalse(IsObject(LLM_TooltipClaimAcceptance(Snapshot.Record, Snapshot.Surface, Snapshot.ActiveIdx)),
			"A captured pre-withdrawal snapshot cannot claim afterward")
		AssertEqual("", LLM_TooltipGetText(), "The physical Tab criterion must no longer capture the application key")
		AssertEqual(0, State.CurrentToken, "Native shortcuts must lose their old owner synchronously")
		AssertTrue(_TooltipActiveSurface == A, "The visual owner remains exact until deferred cleanup")
		AssertEqual("dismissed", Record.Lifecycle.Outcome)
	} finally {
		; Let the actual one-shot hide run while its exact facade and native
		; protocol still belong to this fixture, then restore the shared suite.
		Critical("Off")
		Sleep(20)
		Critical("On")
		for Fn in Installed
			Fn.DeleteProp("Call")
		if IsObject(State)
			_LNEO_Teardown()
		_TooltipActiveSurface := SavedSurface
		_TooltipGeneration := SavedGeneration
		_LLM_TooltipMetricQueue := SavedMetrics
		Critical(PreviousCritical)
	}
}

_OWU_ReceiptRepaint(Probe, *) {
	Probe.Repaint += 1
}

_OWU_ReceiptAccept(Probe, *) {
	Probe.Accept += 1
	return true
}

_OWU_AssertTerminalRender(Record, Surface, SameLifecycle) {
	global _TooltipGeneration, _TooltipActiveSurface
	Generation := _TooltipGeneration + 1
	_TooltipGeneration := Generation
	Candidate := {Generation: Generation, LlmPresented: 0, RenderedActiveIdx: 0,
		Rows: [], Border: 0, ContentHwnds: [], BorderHwnds: []}
	Meta := Map("offer_id", Generation, "accept_source", Record.Lifecycle.AcceptSource)
	if SameLifecycle
		Meta["lifecycle"] := Record.Lifecycle
	Caught := false
	try _LLM_TooltipCommitSurfaceState(["late"], 1, Generation, Meta, Candidate, Surface)
	catch as Err {
		AssertTrue(Err is TooltipLlmTerminalOutcomeError,
			"Only the actual terminal-lifecycle refusal qualifies, not a missing fixture dependency")
		Caught := true
	}
	AssertTrue(Caught, "A terminal lifecycle cannot be resurrected by a late render")
	AssertEqual(0, Candidate.LlmPresented, "The rejected render never publishes its semantic record")
	AssertTrue(_TooltipActiveSurface == Surface)
}

for _OWU_Mode in ["admitted", "withdraw", "native-index", "replacement", "idempotent", "claimed-output", "same-offer", "late-receipt", "stale-owner"]
	Test("LLM offered UI: " . _OWU_Mode . " preserves exact withdrawal (offered-ui-withdrawal)", _OWU_Run.Bind(_OWU_Mode))

; Graphics publication port: real records, lifecycle, render guard and native
; swap are production owners. The boundary supplies only detached empty rows.
_OWU_Show(Self, Slots, Active := 1, Final := false, Meta := 0) {
	global _TooltipActiveSurface, _TooltipGeneration
	LLM_Tooltip_Show.DeleteProp("Call")
	try LLM_Tooltip_Show(Slots, Active, Final, Meta)
	finally LLM_Tooltip_Show.DefineProp("Call", {Call: _OWU_Show})
	Generation := _TooltipGeneration + 1
	_TooltipGeneration := Generation
	Surface := {LlmPresented: 0, Generation: Generation, RenderedActiveIdx: 0,
		Rows: [], Border: 0, ContentHwnds: [], BorderHwnds: []}
	Retired := _TooltipActiveSurface
	AssertTrue(_LLM_TooltipCommitSurfaceState(Slots, Active, Generation, Meta, Surface, Retired))
	Swap := LLM_NavEventOwner_BeginSurfaceSwap(Retired, Surface)
	AssertTrue(Swap is Map && !Swap["retry"])
	_TooltipActiveSurface := Surface
	AssertTrue(LLM_NavEventOwner_CommitSurfaceSwap(Swap))
	_LLM_TooltipMarkSurfaceSuggested(Surface)
	return Generation
}

_OWU_Protocol(Reset) {
	global _LLM_Remote_Async, _LLM_Remote_AsyncCounter
	Saved := [_LLM_Remote_Async, _LLM_Remote_AsyncCounter]
	try {
		_LLM_Remote_Async := Map()
		_HNP_Run(Run)
	} finally {
		_LLM_Remote_Async := Saved[1]
		_LLM_Remote_AsyncCounter := Saved[2]
	}
	Run() {
		_LTR_Run(_LPP_Menu(), _LTN_Screen("merci pour ton aide"), "fr", Body)
	}
	Body(Calls, Lines, Sent) {
		global _LLM_Engine_RemoteTransport, _LLM_Bridge_Active
		global _LLM_Bridge_ReadLiveFocus, _LLM_AcceptInProgress
		global _LLM_NavEventOwnerPort, _LLM_NavEventOwnerRecords
		global _TooltipActiveSurface, _TooltipGeneration, _LLM_TooltipMetricQueue
		global _Stub_LlmPresentedRecord
		SavedUi := {Surface: _TooltipActiveSurface, Generation: _TooltipGeneration,
			Metrics: _LLM_TooltipMetricQueue, Port: _LLM_NavEventOwnerPort, Records: _LLM_NavEventOwnerRecords}
		Native := _LNEO_NewNativeState()
		Hooks := Map("LLM_Tooltip_Show", _OWU_Show,
			"LLM_Tooltip_GetPresentedToken", _OWU_Forward.Bind(LLM_TooltipGetPresentedToken),
			"LLM_Tooltip_GetAcceptSnapshot", _OWU_Forward.Bind(LLM_TooltipGetAcceptSnapshot),
			"LLM_Tooltip_ClaimAcceptance", _OWU_Forward.Bind(LLM_TooltipClaimAcceptance),
			"LLM_Tooltip_FinalizeAcceptance", _OWU_Forward.Bind(LLM_TooltipFinalizeAcceptance),
			"LLM_Tooltip_IsVisible", _OWU_Forward.Bind(LLM_TooltipIsVisible),
			"LLM_Tooltip_IsLoading", _OWU_Forward.Bind(LLM_TooltipIsLoading),
			"LLM_Tooltip_GetText", _OWU_Forward.Bind(LLM_TooltipGetText),
			"LLM_Tooltip_IsRenderGenerationCurrent", _OWU_Forward.Bind(LLM_TooltipRenderGenerationIsCurrent),
			"LLM_Tooltip_HideExact", _OWU_Hide)
		if IsSet(LLM_Tooltip_WithdrawExact) && IsSet(LLM_TooltipWithdrawExact)
			Hooks["LLM_Tooltip_WithdrawExact"] := _OWU_Forward.Bind(LLM_TooltipWithdrawExact)
		Installed := []
		SavedFocus := _LLM_Bridge_ReadLiveFocus
		SavedClaim := _LLM_AcceptInProgress
		Dispatch := _LLMRemote_DispatchManagedCurl
		State := _ManagedCurlControlState()
		AssertFalse(Dispatch.HasOwnProp("Call"))
		try {
			_LLM_NavEventOwnerPort := SavedUi.Port.Clone()
			for Key, Fn in Native.Port
				_LLM_NavEventOwnerPort[Key] := Fn
			_LLM_NavEventOwnerRecords := Map()
			_TooltipActiveSurface := 0
			_LLM_TooltipMetricQueue := []
			for Name, Callback in Hooks {
				Fn := %Name%
				AssertFalse(Fn.HasOwnProp("Call"), "The protocol cannot adopt another facade observer")
				Fn.DefineProp("Call", {Call: Callback})
				Installed.Push(Fn)
			}
			_LLM_Engine_RemoteTransport := 0
			AssertFalse(SavedClaim, "the fixture cannot adopt another acceptance")
			_LLM_Bridge_ReadLiveFocus := () => Map("hwnd", 7, "control", 9)
			AssertTrue(_LLM_Bridge_Active, "the actual prediction feed is enabled for the input callback")
			Dispatch.DefineProp("Call", {Call: ObserveDispatch})
			AssertTrue(LLM_Translate_Trigger("en"))
			AssertEqual(1, State["spawns"], "one controlled native Job must be acquired")
			AssertEqual(1, State["starts"], "the captured native Job must start")
			AssertEqual(0, Calls.Length, "the generic engine transport must run")
			Request := State["request"]
			_ManagedCurlControlAck(State)
			Request._PollManagedAdmission()
			AssertTrue(Request.ManagedPayloadPublished, "the original selected-text request is admitted")
			Physical := KS_GetPhysicalInputGeneration()
			AssertTrue(_LLM_Remote_Async.Has(State["id"]), "the source route must still retain the original HTTP owner")
			AssertFalse(_LLM_Remote_Async[State["id"]]["cancelled"], "the probe cannot synthesize an answer to a canceled transport")
			BodyText := '{"choices":[{"message":{"content":"TRANSLATION: Thank you for your help."}}]}'
			AssertTrue(FSWrite(Request.BodyPath, BodyText))
			AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
			State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
			AssertTrue(Request.Completed, "the actual HTTP facade consumes the terminal receipt")
			_LLMRemote_PollRequest(State["id"])
			Shown := _LPP_LastFinalRender()
			AssertTrue(IsObject(Shown), "The actual translation must reach its final render boundary")
			Real := LLM_TooltipGetPresentedToken()
			AssertTrue(IsObject(Real) && Real != _Stub_LlmPresentedRecord,
				"Acceptance must read the genuine surface-owned lifecycle, not the headless facade record")
			if IsObject(Shown) {
				AssertTrue(Shown.meta["render_guard"].Call(), "the actual original requester still authorizes its offered translation")
				if Reset
					LLM_Bridge_ResetPredictions()
				KS_RecordPhysicalKeyDown(0x09, 0x0F, "dispatcher")
				Accepted := LLM_Tooltip_TryAcceptTab(true, [], _LTAP_Input(true, false, false, false, false, 7, 9))
				AssertEqual(!Reset, Accepted, "a reset offer cannot still accept before its deferred paint cleanup")
			}
			AssertEqual(Reset ? 0 : 2, Sent.Length, "caret movement cannot replace a different selection with an old translation")
		} finally {
			for Fn in Installed
				Fn.DeleteProp("Call")
			_TooltipActiveSurface := SavedUi.Surface
			_TooltipGeneration := SavedUi.Generation
			_LLM_TooltipMetricQueue := SavedUi.Metrics
			_LLM_NavEventOwnerPort := SavedUi.Port
			_LLM_NavEventOwnerRecords := SavedUi.Records
			SetTimer(_LLM_Accept_ReleaseClaim, 0)
			_LLM_AcceptInProgress := SavedClaim
			_LLM_Bridge_ReadLiveFocus := SavedFocus
			if Dispatch.HasOwnProp("Call")
				Dispatch.DeleteProp("Call")
			if State.Has("id") {
				LLM_RemoteCancelAsync(State["id"])
				_LLMRemote_PollRequest(State["id"])
			}
			if State.Has("request")
				_ManagedCurlControlRelease(State)
		}
		ObserveDispatch(Self, Id, Reservation, Resolved, Url, Payload, Port := 0) {
			Dispatch.DeleteProp("Call")
			State["id"] := Id
			return Dispatch.Call(Id, Reservation, Resolved, Url, Payload,
				Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
					"create_http", Create))
		}
		Create() {
			Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(State)))
			State["request"] := Request
			return Request
		}
	}
}

Test("LLM offered translation: reset refuses Tab before paint cleanup (offered-ui-withdrawal)", _OWU_Protocol.Bind(true))
Test("LLM offered translation: admitted offer reaches the actual sender (offered-ui-withdrawal)", _OWU_Protocol.Bind(false))
