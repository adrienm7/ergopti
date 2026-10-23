; tests/fixtures/updater_managed_json_harvest.ahk

; ==============================================================================
; MODULE: Updater Managed JSON Harvest Fixture
; DESCRIPTION:
; Shared original-byte and real cache controls for distinct updater consumers.
; Constructor/process receipts are controlled; business harvests and files are real.
; ==============================================================================

#Requires AutoHotkey v2.0

_UGH_Complete(State, Callback, Code, Out, Err) {
	_MRU_Write(State["request"].HeaderPath,
		['HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nETag: "utf8-harvest"`r`n`r`n'])
	Callback.Call(Code, Out, Err)
}

_UGH_Spawn(State, Executable, Args, Callback, *) {
	return _UMJ_Spawn(State, Executable, Args, _UGH_Complete.Bind(State, Callback))
}

_UGH_Case(Consumer, InvokeFn, ListResult, CacheExpected, Mode) {
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	global _UpdaterActiveAsyncTerminalDeliveryCount, _UpdaterAsyncActionLeases
	global _UpdaterFetchCache, _UpdaterListCacheDir, _UpdaterListDiskLoaded, _UpdaterListDiskEntry
	global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	AssertFalse(A_IsSuspended, "the harvest requires a current updater request")
	PreviousCritical := Critical("On")
	Saved := _UpdaterTest_SaveRequestState()
	SavedCache := {Cache: _UpdaterFetchCache, Dir: _UpdaterListCacheDir,
		Loaded: _UpdaterListDiskLoaded, Entry: _UpdaterListDiskEntry}
	HadCall := CurlAsyncRequest.HasOwnProp("Call")
	SavedCall := HadCall ? CurlAsyncRequest.GetOwnPropDesc("Call") : 0
	State := _ManagedCurlControlState()
	State["constructs"] := 0
	Primary := 0, CleanupFailure := 0, Isolated := false, CacheOwned := false
	CacheDir := A_Temp . "\ergopti-updater-json-" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "-" . A_TickCount . "-" . ObjPtr(State)
	try {
		AssertEqual(0, _UpdaterAsyncRequests.Count, "a foreign async owner must not be detached")
		AssertEqual(0, _UpdaterActiveSendLeaseCount, "a foreign send lease must not be detached")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount, "foreign terminal delivery must not be detached")
		AssertEqual(0, _UpdaterAsyncActionLeases.Count, "a foreign action lease must not be detached")
		AssertFalse(DirExist(CacheDir), "the private native cache directory must not preexist")
		DirCreate(CacheDir)
		CacheOwned := true
		_UpdaterTest_ResetRequestState()
		Isolated := true
		_UpdaterFetchCache := Map()
		_UpdaterListCacheDir := CacheDir
		_UpdaterListDiskLoaded := true
		_UpdaterListDiskEntry := 0
		Request := CurlAsyncRequest(Map("spawn", _UGH_Spawn.Bind(State)))
		State["request"] := Request
		Prefix := '[{"tag_name":"v9.9.9","prerelease":false,"draft":false,'
			. '"published_at":"2026-10-23T00:00:00Z","body":"'
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
		Json := InvokeFn.Call(State)
		if State.Has("error")
			throw State["error"]
		AssertEqual(1, State["constructs"], "the actual consumer must acquire one genuine facade")
		AssertEqual(1, State["spawns"], "the actual facade must dispatch exactly one controlled Job")
		AssertEqual(1, State["starts"], "the exact process receipt port must start")
		AssertTrue(Request.Completed, "the actual managed completion must settle")
		AssertEqual(200, Request.Status, "the original HTTP status must remain independent from encoding refusal")
		Invalid := Mode == "invalid"
		AssertEqual(!Invalid, Request.ResponseEncodingValid, "the actual facade must judge original response bytes")
		AssertEqual('"utf8-harvest"', Request.GetResponseHeader("ETag"), "the actual header parser must retain the real validator")
		CachePath := _Updater_ListCachePath()
		FileAppend("RECEIPT updater-json-harvest consumer=" . Consumer . " mode=" . Mode
			. " raw=" . State["raw"] . " encoding_valid=" . Request.ResponseEncodingValid
			. " status=" . Request.Status . " result_units=" . _MRU_UnitHex(Json)
			. " cache_count=" . _UpdaterFetchCache.Count . " disk_exists=" . (FileExist(CachePath) != "") . "`n", "*")
		if Invalid
			AssertEqual("", Json, "invalid original bytes must not authorize updater JSON")
		else {
			AssertTrue(Json is String && Json != "", "a valid response must retain usable JSON")
			Decoded := JsonParse(Json)
			Release := ListResult ? Decoded[1] : Decoded
			AssertEqual("v9.9.9", Release["tag_name"], "the real channel harvest must preserve the release tag")
			AssertEqual(Expected, Release["body"], "Unicode and a genuine U+FFFD scalar must remain exact")
			if ListResult
				AssertEqual(Request.ResponseText, Json, "the list consumer must retain the exact admitted JSON")
		}
		CacheAdmitted := CacheExpected && !Invalid
		AssertEqual(CacheAdmitted ? 1 : 0, _UpdaterFetchCache.Count, "only the admitted cache-owning consumer may publish RAM")
		AssertEqual(CacheAdmitted, FileExist(CachePath) != "", "only an admitted list validator may reach the durable cache")
		if CacheAdmitted {
			AssertEqual(Request.ResponseText, _UpdaterFetchCache["main"].Json, "the conditional cache must retain the exact full list")
			Disk := _Updater_ParseListCache(FSReadStrict(CachePath), Updater_ReleaseApiUrl())
			AssertTrue(IsObject(Disk), "the real durable write must produce a complete authenticated list cache")
			AssertEqual(Request.ResponseText, Disk.Json, "the stored cache must retain exact admitted Unicode")
			AssertEqual('"utf8-harvest"', Disk.Etag, "the stored validator must come from the actual response headers")
		}
		AssertEqual(0, _UpdaterAsyncRequests.Count, "the actual consumer must retire its registry record")
		AssertEqual(0, _UpdaterActiveSendLeaseCount, "no exact send lease may remain")
		AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount, "no exact terminal delivery lease may remain")
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
				AssertFalse(IsObject(Request.Handle), "the controlled process handle must retire")
				AssertFalse(IsObject(Request.ManagedCapture), "the actual capture must retire")
				AssertFalse(IsObject(Request.ManagedAdmissionFn), "the actual admission callback must retire")
				AssertFalse(IsObject(Request.DeadlineFn), "the actual deadline callback must retire")
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId), "no private response file debt may remain")
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "no private abort debt may remain")
				for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(Path), "all private response artifacts must retire")
			}
			if State.Has("directory")
				AssertFalse(DirExist(State["directory"]), "the actual capture directory must retire")
			if CacheOwned {
				DirDelete(CacheDir, true)
				AssertFalse(DirExist(CacheDir), "the exact private durable cache must retire")
			}
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			try {
				if Isolated {
					_UpdaterTest_RestoreRequestState(Saved)
					_UpdaterFetchCache := SavedCache.Cache
					_UpdaterListCacheDir := SavedCache.Dir
					_UpdaterListDiskLoaded := SavedCache.Loaded
					_UpdaterListDiskEntry := SavedCache.Entry
				}
			} finally Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}
