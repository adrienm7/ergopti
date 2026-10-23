; tests/unit/modules/updater/test_updater_managed_json_utf8.ahk

; ==============================================================================
; MODULE: Updater Managed JSON Encoding Tests
; DESCRIPTION:
; Carry original response bytes through the actual managed facade and public
; releases-list consumer. Only constructor and process boundaries are controlled.
; ==============================================================================

#Requires AutoHotkey v2.0

class _UMJ_CompletedJob {
	__New(State) {
		this.State := State
	}

	terminate() {
		this.State["terminates"].Push(ObjPtr(this))
		return this.State["retire"]
	}

	start() {
		State := this.State
		State["starts"] += 1
		try {
			Request := State["request"]
			_ManagedCurlControlAck(State)
			Request._PollManagedAdmission()
			AssertTrue(Request.ManagedPayloadPublished, "actual admission must publish the exact transport input")
			_MRU_Write(Request.HeaderPath, ["HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"])
			_MRU_Write(Request.BodyPath, State["pieces"])
			State["raw"] := _MRU_ByteHex(FileRead(Request.BodyPath, "RAW"))
			State["callback"].Call(0,
				'{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
			return true
		} catch Any as Failure {
			; Send catches transport exceptions. Preserve observer failures so no
			; infrastructure error can masquerade as the expected JSON refusal.
			State["error"] := Failure
			return false
		}
	}
}

_UMJ_Spawn(State, Executable, Args, Callback, *) {
	_ManagedCurlControlSpawn(State, Executable, Args, Callback)
	State["job"] := _UMJ_CompletedJob(State)
	return State["job"]
}

_UMJ_Construct(State, *) {
	State["constructs"] += 1
	return State["request"]
}

_UMJ_ReleasesList(Mode) {
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	global _UpdaterActiveAsyncTerminalDeliveryCount, _UpdaterAsyncActionLeases
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	AssertFalse(A_IsSuspended, "the control requires an admitted current updater request")
	PreviousCritical := Critical("On")
	Saved := _UpdaterTest_SaveRequestState()
	HadCall := CurlAsyncRequest.HasOwnProp("Call")
	SavedCall := HadCall ? CurlAsyncRequest.GetOwnPropDesc("Call") : 0
	State := _ManagedCurlControlState()
	State["constructs"] := 0
	Primary := 0, CleanupFailure := 0, Isolated := false
	try {
		AssertEqual(0, _UpdaterAsyncRequests.Count, "a foreign async updater owner must not be detached")
		AssertEqual(0, _UpdaterActiveSendLeaseCount, "a foreign send lease must not be detached")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount, "a foreign delivery must not be detached")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count, "a foreign action lease must not be detached")
		_UpdaterTest_ResetRequestState()
		Isolated := true
		Request := CurlAsyncRequest(Map("spawn", _UMJ_Spawn.Bind(State)))
		State["request"] := Request
		Prefix := '[{"tag_name":"v9.9.9","body":"'
		Suffix := '"}]'
		Expected := "Étude 😀"
		if Mode == "invalid"
			State["pieces"] := [Prefix . "x", _MRU_Bytes([0xC3, 0x28]), "y" . Suffix]
		else if Mode == "replacement" {
			Expected := "x" . Chr(0xFFFD) . "y"
			State["pieces"] := [Prefix . "x", _MRU_Bytes([0xEF, 0xBF, 0xBD]), "y" . Suffix]
		} else
			State["pieces"] := [Prefix . Expected . Suffix]
		CurlAsyncRequest.DefineProp("Call", {Call: _UMJ_Construct.Bind(State)})
		Json := Updater_FetchReleasesListJson("main")
		if State.Has("error")
			throw State["error"]
		AssertEqual(1, State["constructs"], "the public consumer must construct exactly one actual facade")
		AssertEqual(1, State["spawns"], "the actual managed facade must dispatch exactly once")
		AssertEqual(1, State["starts"], "the exact controlled Job must start")
		AssertTrue(Request.Completed, "the actual managed terminal must settle")
		AssertEqual(200, Request.Status, "encoding refusal must not manufacture an HTTP failure")
		Invalid := Mode == "invalid"
		AssertEqual(!Invalid, Request.ResponseEncodingValid, "the actual facade must classify the original bytes")
		FileAppend("RECEIPT updater-managed-json-utf8 consumer=releases-list-sync mode=" . Mode
			. " raw=" . State["raw"] . " encoding_valid=" . Request.ResponseEncodingValid
			. " status=" . Request.Status . " body_units=" . _MRU_UnitHex(Request.ResponseText)
			. " result_units=" . _MRU_UnitHex(Json) . "`n", "*")
		if Invalid
			AssertEqual("", Json, "malformed original bytes must not become an admitted releases list")
		else {
			AssertEqual(Request.ResponseText, Json, "the public consumer must preserve the exact valid JSON")
			Decoded := JsonParse(Json)
			AssertEqual("v9.9.9", Decoded[1]["tag_name"], "valid release metadata must remain usable")
			AssertEqual(Expected, Decoded[1]["body"], "Unicode and an original U+FFFD scalar must remain exact")
		}
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if HadCall
				CurlAsyncRequest.DefineProp("Call", SavedCall)
			else if CurlAsyncRequest.HasOwnProp("Call")
				CurlAsyncRequest.DeleteProp("Call")
			_ManagedCurlControlRelease(State)
			if IsSet(Request) {
				AssertFalse(IsObject(Request.Handle), "the private controlled handle must retire")
				AssertFalse(IsObject(Request.ManagedCapture), "the actual capture must retire")
				AssertFalse(IsObject(Request.ManagedAdmissionFn), "no admission callback may remain")
				AssertFalse(IsObject(Request.DeadlineFn), "no deadline callback may remain")
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId), "no private file debt may remain")
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "no private abort debt may remain")
				for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(Path), "every private response artifact must retire")
			}
			if State.Has("directory")
				AssertFalse(DirExist(State["directory"]), "the private capture directory must retire")
			if Isolated {
				AssertEqual(0, _UpdaterAsyncRequests.Count, "the synchronous consumer must leave no registry owner")
				AssertEqual(0, _UpdaterActiveSendLeaseCount, "the synchronous consumer must leave no send lease")
			}
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			if Isolated
				_UpdaterTest_RestoreRequestState(Saved)
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Mode in ["invalid", "valid", "replacement"]
	Test("updater JSON encoding: releases-list-sync " . Mode . " (updater-managed-json-utf8)",
		_UMJ_ReleasesList.Bind(Mode))
