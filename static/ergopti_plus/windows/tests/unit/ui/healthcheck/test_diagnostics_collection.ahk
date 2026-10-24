; tests/unit/ui/healthcheck/test_diagnostics_collection.ahk

; ==============================================================================
; MODULE: Diagnostics Collection
; DESCRIPTION:
; The diagnostics collection contains pre-spawn failures, publishes the
; worker's nullable receipts, keeps cleanup custody on cancellation and
; exit refusal, binds archive acknowledgements to exact bytes and projects
; resident observations without private content.
; ==============================================================================

#Requires AutoHotkey v2.0





/** Runs collection state regressions in an owned synthetic directory without launching a worker. */
_TestHC_CollectionState(TestCase) {
	D := DiagnosticCollectionWindows()
	Root := A_Temp . "\ergopti-hc-collection-" . D.Id
	D.Directory := Root . "\" . D.Id
	D.Archive := D.Directory . ".zip"
	DirCreate(Root)
	try {
		if TestCase == "launch-failure" {
			FileAppend("synthetic blocker", D.Directory, "UTF-8-RAW")
			AssertEqual(false, D.Start(), "A pre-spawn filesystem failure must be contained.")
			AssertTrue(D.Terminal, "No native task exists; the failed session must allow retry.")
			AssertEqual("failed", D.Result["phase"])
			AssertEqual("synthetic blocker", FileRead(D.Directory, "UTF-8"), "The preexisting file is not owned output.")
		} else {
			DirCreate(D.Directory)
			if TestCase == "cancel" {
				AssertTrue(D.Cancel())
				First := D.CancelTick
				AssertTrue(D.Cancel())
				AssertEqual(First, D.CancelTick, "Repeated cancellation must not postpone retirement.")
				AssertEqual(false, D.SkipGuided(), "Cancelled observations cannot be acknowledged.")
				AssertTrue(FileExist(D.Directory . "\cancel"))
				AssertEqual(false, D.Terminal, "A request is not a native retirement acknowledgement.")
			} else if TestCase == "skip" {
				AssertTrue(D.SkipGuided())
				Receipt := JsonParse(FileRead(D.Directory . "\physical.json", "UTF-8"))
				AssertEqual("SKIP", Receipt["physical_text"])
				AssertEqual("SKIP", Receipt["physical_display"])
				AssertEqual(D.Id, Receipt["session_id"])
				D.Completed(1, "", "")
				AssertTrue(D.Terminal)
				AssertEqual("failed", D.Result["phase"])
				AssertEqual(false, D.Result["archive_created"])
			} else if TestCase == "progress" {
				Value := Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
					"total", D.Contract["checks"].Length, "results", [])
				AssertTrue(D.AcceptProgress(Value))
				Bad := Value.Clone(), Bad["session_id"] := "foreign"
				AssertThrows(() => D.AcceptProgress(Bad))
				Bad := Value.Clone(), Bad["completed"] := 1
				AssertThrows(() => D.AcceptProgress(Bad))
				Bad := Value.Clone(), Bad["completed"] := 1
				Bad["results"] := [Map("id", "callbacks", "status", "PASS", "evidence_class", "unexecuted")]
				AssertThrows(() => D.AcceptProgress(Bad), "An unexecuted check must never become PASS.")
				Bad["results"][1]["status"] := "UNRUN"
				AssertTrue(D.AcceptProgress(Bad))
				Pending := Value.Clone(), Pending["phase"] := "completed", Pending["archive_created"] := true
				Pending["results"] := []
				for Id in D.Contract["checks"]
					Pending["results"].Push(Map("id", Id, "status", "UNRUN", "evidence_class", "unexecuted"))
				Pending["completed"] := Pending["results"].Length
				AssertTrue(D.AcceptProgress(Pending))
				AssertEqual("retiring", D.Result["phase"], "Worker progress cannot attest to native task retirement.")
				AssertFalse(D.Result["archive_created"], "Only the exact terminal acknowledgement may expose the archive action.")
				AssertTrue(D.Result["owner_pending"])
				D.Completed(1, "", "")
				AssertFalse(D.AcceptProgress(Value), "Stale progress cannot resurrect a retired session.")
				AssertEqual("failed", D.Result["phase"])
			} else if TestCase == "terminate-reentry" {
				D.Task := {requestTerminate: Retire}
				Retire(This) {
					D.Completed(1, "", "")
					return true
				}
				D.Write("progress.json", Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
					"total", D.Contract["checks"].Length, "results", []))
				D.Cancel()
				D.CancelTick := A_TickCount - D.Contract["retirement_grace_ms"] - 1
				D.Tick()
				AssertTrue(D.Terminal)
				AssertEqual("failed", D.Result["phase"], "Synchronous retirement cannot be overwritten by stale guided progress.")
			} else if TestCase == "exit-refusal" {
				D.Task := {requestTerminate: (*) => false}
				AssertEqual(1, D.Exit("Exit", 0), "Unacknowledged worker retirement must veto application exit.")
				AssertFalse(D.Terminal)
				AssertFalse(FileExist(D.Directory . "\host-exit.json"), "A refused exit cannot write a cleanup acknowledgement.")
			} else if TestCase == "cancel-write-failure" {
				D.DefineProp("Write", {Call: RefuseWrite})
				RefuseWrite(This, Name, Value) {
					throw Error("Injected cancellation filesystem failure.")
				}
				AssertTrue(D.Cancel(), "A failed control write cannot crash the cancellation action.")
				AssertTrue(D.Result["cancel_control_failed"])
				AssertEqual("cleanup_pending", D.Result["phase"])
				AssertFalse(D.Terminal, "Control write failure cannot invent worker retirement.")
			} else if TestCase == "archive-ack" || TestCase == "archive-good" || TestCase == "archive-failed" {
				FileAppend("synthetic archive bytes", D.Archive, "UTF-8-RAW")
				Ack := Map("schema_version", 1, "session_id", D.Id, "archive_committed", true,
					"bytes", FileGetSize(D.Archive), "sha256", CryptoSha256Bytes(FileRead(D.Archive, "RAW")))
				if TestCase == "archive-ack" {
					Bad := Ack.Clone(), Bad["sha256"] := StrReplace(Ack["sha256"], SubStr(Ack["sha256"], 1, 1), "z")
					AssertTrue(D.Completed(0, _HC_ValueToJson(Bad), ""))
					AssertFalse(D.Result["archive_created"], "Existence and size alone cannot acknowledge an archive.")
					AssertFalse(D.Completed(0, _HC_ValueToJson(Ack), ""), "A duplicate completion cannot replace a failed terminal receipt.")
					AssertFalse(D.Result["archive_created"])
				} else if TestCase == "archive-failed" {
					AssertTrue(D.Completed(1, _HC_ValueToJson(Ack), ""))
					AssertEqual("failed", D.Result["phase"], "A valid ZIP cannot promote the worker's primary failure.")
					AssertTrue(D.Result["archive_created"], "Failed collection retains its exact acknowledged evidence archive.")
					AssertFalse(D.Result["owner_pending"], "Only canonical native completion retires worker custody.")
					AssertTrue(D.Result["worker_tree_retired"])
					AssertTrue(D.Result["folder_available"])
				} else {
					AssertTrue(D.Completed(0, _HC_ValueToJson(Ack), ""))
					AssertTrue(D.Result["archive_created"])
					FileAppend("replacement", D.Archive, "UTF-8-RAW")
					AssertFalse(D.OpenFolder(), "A changed archive must be refused before opening Explorer.")
				}
			}
		}
	} finally {
		SetTimer(D.CollectionTimer, 0)
		DirDelete(Root, true)
	}
}
Test("Diagnostics collection contains pre-spawn failure (groups247-collection)", (*) => _TestHC_CollectionState("launch-failure"))

/** Replays the worker's nullable failure receipt through the actual page serializer. */
_TestHC_CollectionNullableProgress() {
	global JSON_NULL
	D := DiagnosticCollectionWindows()
	Raw := '{"schema_version":1,"session_id":"' . D.Id . '","phase":"collecting","completed":1,"total":'
		. D.Contract["checks"].Length . ',"results":[{"id":"native_uia","status":"FAIL","evidence_class":"native_synthetic","receipt":null}]}'
	AssertTrue(D.AcceptProgress(JsonParse(Raw)))
	Published := JsonParse(_HC_ValueToJson(Map("type", "collection", "collection", D.Result)))
	Row := Published["collection"]["results"][1]
	AssertEqual("FAIL", Row["status"], "Transporting a missing receipt cannot promote the native failure.")
	AssertTrue(IsObject(Row["receipt"]) && ObjPtr(Row["receipt"]) == ObjPtr(JSON_NULL),
		"The worker's JSON null retains its exact sentinel through page publication.")
	AssertTrue(Published["collection"]["owner_pending"])
	AssertFalse(Published["collection"]["archive_created"])
}
Test("Diagnostics collection publishes actual nullable worker receipts (groups247-collection)", _TestHC_CollectionNullableProgress)
Test("Diagnostics collection cancellation retains acknowledgement ownership (groups247-collection)", (*) => _TestHC_CollectionState("cancel"))
Test("Diagnostics collection skipped physical checks never pass (groups247-collection)", (*) => _TestHC_CollectionState("skip"))
Test("Diagnostics collection validates progress and refuses resurrection (groups247-collection)", (*) => _TestHC_CollectionState("progress"))
Test("Diagnostics collection synchronous retirement keeps terminal state (groups247-collection)", (*) => _TestHC_CollectionState("terminate-reentry"))
Test("Diagnostics collection exit refusal keeps cleanup custody (groups247-collection)", (*) => _TestHC_CollectionState("exit-refusal"))
Test("Diagnostics collection archive acknowledgement binds exact bytes (groups247-collection)", (*) => _TestHC_CollectionState("archive-ack"))
Test("Diagnostics collection rejects replaced acknowledged archives (groups247-collection)", (*) => _TestHC_CollectionState("archive-good"))
Test("Diagnostics collection failed cancel write retains cleanup custody (groups247-collection)", (*) => _TestHC_CollectionState("cancel-write-failure"))

_TestHC_ResidentObservationProjection() {
	Assert(IsSet(DiagSnapshot_ResidentObservations), "the collecting resident must produce its own closed observations")
	global HSE_Buffer, HSE_LastMatch, _PrefixBuffer
	Saved := [HSE_Buffer, HSE_LastMatch, _PrefixBuffer]
	Sentinel := "private synthetic corpus token sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	try {
		HSE_Buffer := Sentinel, HSE_LastMatch := Sentinel, _PrefixBuffer := Sentinel
		Receipt := DiagSnapshot_ResidentObservations()
		AssertEqual(1, Receipt["schema_version"])
		Assert(Receipt["captured_at_filetime"] is Integer && Receipt["captured_at_filetime"] > 0)
		AssertEqual(4, Receipt["rows"].Length)
		AssertFalse(InStr(_HC_ValueToJson(Receipt), Sentinel), "private input and corpus values cannot enter technical observations")
		for Row in Receipt["rows"] {
			AssertFalse(Row["scenario_qualified"], "a state read cannot qualify the unexecuted functional scenario")
			AssertTrue(Row["values"] is Map)
		}
		AssertEqual("runtime_state", Receipt["rows"][1]["scope"])
		AssertEqual("UNRUN", Receipt["rows"][2]["status"], "an absent production runtime cannot become native identity evidence")
		AssertEqual("UNRUN", Receipt["rows"][3]["status"], "headless execution cannot start a native capture owner")
		AssertEqual("UNRUN", Receipt["rows"][4]["status"], "headless execution cannot load or initialize a native DLL")
	} finally {
		HSE_Buffer := Saved[1], HSE_LastMatch := Saved[2], _PrefixBuffer := Saved[3]
	}
}
Test("Diagnostics collection projects resident observations without private content (groups247-resident-observations)", _TestHC_ResidentObservationProjection)

_TestHC_ResidentIdentityDebt() {
	global _OllamaIdentityPendingHandles, _LLM_ManagedBootstrap
	SavedHandles := _OllamaIdentityPendingHandles, SavedFlow := _LLM_ManagedBootstrap
	try {
		; Zero is an invalid recording handle, never an acquired process resource.
		Debt := Map(0, true)
		_OllamaIdentityPendingHandles := Debt
		_LLM_ManagedBootstrap := {Port: 0, Ready: true, Runtime: {Record: Map("target", Map())}}
		Receipt := DiagSnapshot_ResidentObservations()
		Row := Receipt["rows"][2]
		AssertEqual("UNRUN", Row["status"], "an existing probe-handle debt refuses another identity query")
		AssertEqual("native_identity_cleanup_pending", Row["reason"])
		AssertEqual(1, Row["values"]["identity_handle_debt"])
		AssertTrue(_OllamaIdentityPendingHandles == Debt)
		AssertTrue(Debt.Has(0), "collection cannot retire another operation's retained handle")
		AssertFalse(Row["scenario_qualified"])
	} finally {
		_OllamaIdentityPendingHandles := SavedHandles
		_LLM_ManagedBootstrap := SavedFlow
	}
}
Test("Diagnostics collection preserves existing identity handle debt (groups247-resident-observations)", _TestHC_ResidentIdentityDebt)

Test("Diagnostics collection primary failure retains its verified archive (groups247-collection)", (*) => _TestHC_CollectionState("archive-failed"))

/** Receives a real exclusive native writer without inventing a progress or retirement ACK. */
_TestHC_CollectionExclusiveProgress(Scenario := "retry") {
	D := DiagnosticCollectionWindows()
	Root := A_Temp . "\ergopti-hc-exclusive-" . D.Id
	D.Directory := Root . "\" . D.Id
	D.Archive := D.Directory . ".zip"
	DirCreate(D.Directory)
	Handle := 0
	try {
		D.Write("progress.json", Map("schema_version", 1, "session_id", D.Id, "phase", "guided", "completed", 0,
			"total", D.Contract["checks"].Length, "results", []))
		Handle := DllCall("CreateFileW", "Str", D.Directory . "\progress.json", "UInt", 0xC0000000,
			"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle && Handle != -1, "The native writer must own an exclusive real file handle.")
		if Scenario == "deadline"
			D.Started := A_TickCount - D.Contract["deadline_ms"] - 1
		D.Tick()
		AssertFalse(D.ProgressFault, "A sharing conflict is not invalid progress or a worker completion.")
		AssertFalse(D.Terminal, "A retry cannot attest to native task retirement.")
		AssertEqual(Scenario == "deadline", D.Cancelled, "The original deadline still cancels behind a busy writer.")
		AssertTrue(DllCall("CloseHandle", "Ptr", Handle, "Int"))
		Handle := 0
		if Scenario == "malformed" {
			FileDelete(D.Directory . "\progress.json")
			FileAppend("invalid JSON", D.Directory . "\progress.json", "UTF-8-RAW")
			D.Tick()
			AssertTrue(D.ProgressFault, "Actual malformed bytes must still fail closed after the writer retires.")
			AssertTrue(D.Cancelled)
			AssertEqual("invalid_progress", D.Result["reason"])
		} else if Scenario == "retry" {
			D.Tick()
			AssertFalse(D.ProgressFault)
			AssertEqual("guided", D.Result["phase"], "The next normal read receives the actual committed progress.")
			AssertTrue(D.Result["owner_pending"])
			AssertFalse(D.Result["archive_created"])
		}
	} finally {
		if Handle
			AssertTrue(DllCall("CloseHandle", "Ptr", Handle, "Int"))
		SetTimer(D.CollectionTimer, 0)
		DirDelete(Root, true)
	}
}
Test("Diagnostics collection retries actual exclusive progress writes (groups247-collection)", _TestHC_CollectionExclusiveProgress)
Test("Diagnostics collection preserves malformed progress refusal after sharing (groups247-collection)", _TestHC_CollectionExclusiveProgress.Bind("malformed"))
Test("Diagnostics collection keeps its deadline behind exclusive progress (groups247-collection)", _TestHC_CollectionExclusiveProgress.Bind("deadline"))

#Include test_healthcheck_collection_publish_owner.ahk
