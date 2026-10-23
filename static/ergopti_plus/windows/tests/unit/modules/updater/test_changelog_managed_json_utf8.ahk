; tests/unit/modules/updater/test_changelog_managed_json_utf8.ahk

; ==============================================================================
; MODULE: Changelog Managed JSON Encoding Tests
; DESCRIPTION:
; Pass original bytes through managed admission and the genuine changelog fetch
; and completion owners. No network wire or rendered WebView is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_CJU_PollHandoff(Observed, Request, Context, Polls) {
	Observed.Push({Request: Request, Context: Context, Polls: Polls})
}

_CJU_Response(Mode) {
	global _CLW_ActiveRequest, _CLW_ActiveRequestEpoch, _CLW_Queue
	global _CLW_LastList, _CLW_FeedStarter
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	global _UpdaterActiveAsyncTerminalDeliveryCount, _UpdaterAsyncActionLeases
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	AssertFalse(A_IsSuspended, "the control requires a current changelog request")
	PreviousCritical := Critical("On")
	SavedUpdater := _UpdaterTest_SaveRequestState()
	State := _ManagedCurlControlState()
	Started := [], Handoffs := []
	Primary := 0, CleanupFailure := 0, Isolated := false
	SavedStarter := _CLW_FeedStarter
	SavedList := _CLW_LastList
	try {
		AssertFalse(IsObject(_CLW_ActiveRequest), "a foreign changelog request must not be detached")
		AssertEqual(0, _CLW_Queue.Length, "foreign pending page work must not be detached")
		AssertEqual(0, _UpdaterAsyncRequests.Count, "a foreign updater request must not be detached")
		AssertEqual(0, _UpdaterActiveSendLeaseCount, "a foreign send lease must not be detached")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount, "foreign terminal delivery must not be detached")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count, "a foreign action lease must not be detached")
		Previous := _CRE_InstallFixture()
		_UpdaterTest_ResetRequestState()
		Isolated := true
		Sentinel := Map("kind", "json", "json", "[]")
		_CLW_LastList := Sentinel
		_CLW_FeedStarter := (Feed) => Started.Push(Feed)
		Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(State)))
		State["request"] := Request
		Context := _CLW_BeginFetchRequest("main")
		_CLW_DoFetch(Context, Map("create_http", () => Request,
			"managed_settings", () => _CNR_Config(), "poll", _CJU_PollHandoff.Bind(Handoffs)))
		AssertEqual(1, State["spawns"], "the real fetch owner must dispatch one managed facade")
		AssertEqual(1, Handoffs.Length, "the real fetch must hand off exactly one poll")
		AssertTrue(Handoffs[1].Request == Request && Handoffs[1].Context == Context,
			"the poll must retain the exact registered request and provenance")
		AssertEqual(0, Handoffs[1].Polls, "the original polling budget must begin at zero")
		AssertTrue(_CLW_ActiveRequest == Request, "the real fetch must retain its exact active transport")
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "the actual facade must own an admission timer")
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		Request._PollManagedAdmission()
		AssertTrue(Request.ManagedPayloadPublished, "actual managed admission must publish transport input")
		_MRU_Write(Request.HeaderPath, ["HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"])
		Prefix := '[{"tag_name":"v9.9.9","body":"'
		Suffix := '"}]'
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
		State["callback"].Call(0,
			'{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
		AssertTrue(Request.Completed, "the genuine managed callback must settle")
		AssertEqual(200, Request.Status, "invalid encoding must remain distinct from an HTTP failure")
		Invalid := Mode == "invalid"
		AssertEqual(!Invalid, Request.ResponseEncodingValid, "the facade must classify the original bytes")
		_CLW_PollFetch(Request, Context, 0)
		FileAppend("RECEIPT changelog-managed-json-utf8 mode=" . Mode . " raw=" . OriginalHex
			. " encoding_valid=" . Request.ResponseEncodingValid . " status=" . Request.Status
			. " body_units=" . _MRU_UnitHex(Request.ResponseText)
			. " fallback_count=" . Started.Length . " queue_count=" . _CLW_Queue.Length
			. " cache_replaced=" . (_CLW_LastList != Sentinel) . "`n", "*")
		if Invalid {
			AssertEqual(0, _CLW_Queue.Length, "repaired invalid bytes must never become page release data")
			AssertTrue(_CLW_LastList == Sentinel, "invalid source bytes must not replace the prior list cache")
			AssertEqual(1, Started.Length, "an invalid API response must start the existing alternate-source owner")
			AssertEqual("feed", Started[1].Stage, "the fallback must retain the genuine feed source")
			AssertEqual(Context.RequestEpoch, Started[1].RequestEpoch, "fallback must retain the exact request epoch")
		} else {
			AssertEqual(0, Started.Length, "valid Unicode and an original replacement scalar must not force fallback")
			AssertEqual(1, _CLW_Queue.Length, "the current valid source must queue exactly one page update")
			AssertEqual("json", _CLW_LastList["kind"], "the accepted source must remain JSON")
			AssertEqual(Request.ResponseText, _CLW_LastList["json"], "the cache must retain the exact accepted JSON")
			AssertEqual(Expected, JsonParse(_CLW_LastList["json"])[1]["body"], "accepted scalar values must remain exact")
			AssertEqual("injectReleasesJson(" . _CLW_JsStr(Request.ResponseText) . ',"main")',
				_CLW_Queue[1].Js, "the real deferred script must contain the exact JSON and channel")
			AssertEqual(Context.RequestEpoch, _CLW_Queue[1].RequestEpoch, "page work must retain current request provenance")
		}
		AssertEqual(0, _CLW_ActiveRequest, "completion must retire the exact active transport")
		AssertEqual(0, _CLW_ActiveRequestEpoch, "completion must retire its active epoch")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			_ManagedCurlControlRelease(State)
			if Isolated && IsSet(Context)
				_CLW_ReleaseActiveRequest(Context)
			if IsSet(Request) {
				AssertFalse(IsObject(Request.Handle), "the controlled process owner must retire")
				AssertFalse(IsObject(Request.ManagedCapture), "the exact native capture must retire")
				AssertFalse(IsObject(Request.ManagedAdmissionFn), "the exact admission callback must retire")
				AssertFalse(IsObject(Request.DeadlineFn), "the exact deadline callback must retire")
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId), "no private response file debt may remain")
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "no private abort debt may remain")
				for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(Path), "every private response artifact must retire")
			}
			if State.Has("directory")
				AssertFalse(DirExist(State["directory"]), "the exact private capture directory must retire")
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			try {
				if Isolated {
					_CRE_RestoreFixture(Previous)
					_UpdaterTest_RestoreRequestState(SavedUpdater)
				}
				_CLW_LastList := SavedList
				_CLW_FeedStarter := SavedStarter
			} finally Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Mode in ["invalid", "valid", "replacement"]
	Test("changelog JSON encoding: API " . Mode . " (changelog-managed-json-utf8)", _CJU_Response.Bind(Mode))
