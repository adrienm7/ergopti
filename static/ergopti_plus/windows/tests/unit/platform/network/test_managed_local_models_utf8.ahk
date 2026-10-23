; tests/unit/platform/network/test_managed_local_models_utf8.ahk

; ==============================================================================
; MODULE: Local Models Response Encoding Tests
; DESCRIPTION:
; Feed original response bytes through the real managed curl facade and local
; discovery/readiness consumers. Process receipts are controlled, not wire E2E.
; ==============================================================================

_MLM_Timer(Timers, Callback, Period) {
	Id := ObjPtr(Callback)
	if Period == 0 {
		if Timers.Has(Id)
			Timers.Delete(Id)
	} else
		Timers[Id] := Callback
	return true
}

_MLM_Case(Consumer, Mode) {
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	PreviousCritical := Critical("On")
	SavedOwners := _LLM_AuxOwners
	SavedDebt := _LLM_AuxCleanupDebt
	_LLM_AuxOwners := Map()
	_LLM_AuxCleanupDebt := Map()
	State := _ManagedCurlControlState()
	Results := [], Timers := Map()
	ModelOwner := 0, ReadyOwner := 0
	Primary := 0, CleanupFailure := 0
	try {
		Request := _ManagedCurlControlNew(State)
		Request.SetManagedRouting(() => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""))
		if Consumer == "discovery" {
			ModelOwner := LocalServerModelsOwner(Map("servers", Map("lmstudio", Map("auth", "optional")),
				"timeout_ms", 20000, "poll_ms", 20, "request", (*) => Request,
				"timer", _MLM_Timer.Bind(Timers)))
			AssertTrue(ModelOwner.Probe(Map("id", "lmstudio", "base_url", "http://127.0.0.1:19273/v1", "token", ""),
				(Receipt) => Results.Push(Receipt), Map("is_current", () => true)),
				"the real discovery owner must dispatch its actual managed facade")
		} else {
			ReadyOwner := LLM_AuxBegin("managed-local-models-utf8:" . Mode)
			ReadyOwner["local_server"] := true
			AssertTrue(Request.Send(), "the real readiness facade must dispatch")
		}
		AssertEqual(1, State["spawns"], "only the process launch boundary is controlled")
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "the actual facade must own admission")
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		Request._PollManagedAdmission()
		AssertTrue(Request.ManagedPayloadPublished, "the actual admission must publish transport input")
		_MRU_Write(Request.HeaderPath, ["HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"])
		Prefix := '{"data":[{"id":"'
		Suffix := '"}]}'
		Expected := "Étude 😀"
		if Mode == "invalid"
			Pieces := [Prefix . "x", _MRU_Bytes([0xC3, 0x28]), "y" . Suffix]
		else if Mode == "replacement" {
			Expected := "x" . Chr(0xFFFD) . "y"
			Pieces := [Prefix . "x", _MRU_Bytes([0xEF, 0xBF, 0xBD]), "y" . Suffix]
		} else
			Pieces := [Prefix . Expected . Suffix]
		_MRU_Write(Request.BodyPath, Pieces)
		OriginalHex := _MRU_ByteHex(FileRead(Request.BodyPath, "RAW"))
		State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
		AssertTrue(Request.Completed, "the actual managed terminal must settle")
		AssertEqual(200, Request.Status, "encoding rejection must not manufacture a transport failure")
		Invalid := Mode == "invalid"
		AssertEqual(!Invalid, Request.ResponseEncodingValid, "the real facade must classify the original byte sequence")
		if Consumer == "discovery"
			ModelOwner.RetryPending()
		else
			_LLMRemote_PollReady(Request, (Reachable) => Results.Push(Reachable), A_TickCount, 20000, ReadyOwner)
		AssertEqual(1, Results.Length, "the real current owner must publish exactly once")
		Admitted := Consumer == "discovery" ? Results[1]["ok"] : Results[1]
		FileAppend("RECEIPT managed-local-models-utf8 consumer=" . Consumer . " mode=" . Mode
			. " raw=" . OriginalHex . " encoding_valid=" . Request.ResponseEncodingValid
			. " status=" . Request.Status . " body_units=" . _MRU_UnitHex(Request.ResponseText)
			. " admitted=" . Admitted . "`n", "*")
		AssertEqual(!Invalid, Admitted, "malformed original bytes must never authorize local model JSON")
		if Consumer == "discovery" {
			AssertEqual(Invalid ? 0 : 1, Results[1]["models"].Length, "invalid encoding must expose no selectable model")
			if !Invalid
				AssertEqual(Expected, Results[1]["models"][1], "valid Unicode and genuine U+FFFD must remain exact")
			AssertFalse(ModelOwner.HasPending("lmstudio"), "the exact discovery request must retire")
		} else
			AssertFalse(LLM_AuxIsCurrent(ReadyOwner), "readiness completion must retire its exact auxiliary owner")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if ModelOwner is LocalServerModelsOwner {
				ModelOwner.Cancel("lmstudio")
				ModelOwner.RetryPending()
				AssertFalse(ModelOwner.HasPending("lmstudio"), "cleanup must retire the private models owner")
			}
			if ReadyOwner is Map
				LLM_AuxFinish(ReadyOwner)
			_ManagedCurlControlRelease(State)
			AssertEqual(0, Timers.Count, "the passive timer port must retain no callback")
			if IsSet(Request) {
				AssertFalse(IsObject(Request.Handle), "the private controlled handle must retire")
				AssertFalse(IsObject(Request.ManagedCapture), "the actual capture must retire")
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId), "no private file debt may remain")
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "no private abort debt may remain")
				for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(Path), "every private response artifact must retire")
			}
			if State.Has("directory")
				AssertFalse(DirExist(State["directory"]), "the private capture directory must retire")
		} catch as Failure {
			CleanupFailure := Failure
		} finally {
			_LLM_AuxOwners := SavedOwners
			_LLM_AuxCleanupDebt := SavedDebt
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Consumer in ["discovery", "readiness"]
	for Mode in ["invalid", "valid", "replacement"]
		Test("local models encoding: " . Consumer . " " . Mode . " (managed-local-models-utf8)", _MLM_Case.Bind(Consumer, Mode))
