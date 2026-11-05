; tests/unit/infra/config/persistence/test_config_commit_gateway.ahk

; ==============================================================================
; MODULE: Configuration commit gateway transactions
; DESCRIPTION:
; Behavioural proof that one config.toml owner spans candidate construction,
; durable I/O, reversible finalization and atomic live publication. Malformed
; contracts fail before the writer and every terminal path releases ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

global _CCG_Path := ""
global _CCG_BuildCalls := 0
global _CCG_WriteCalls := 0
global _CCG_PublishCalls := 0
global _CCG_FinalizeCalls := 0
global _CCG_CompensateCalls := 0
global _CCG_NotifyCalls := 0
global _CCG_NestedResult := true
global _CCG_LiveValue := "old"
global _CCG_WriterResult := true
global _CCG_WriterCritical := -1
global _CCG_PublishCritical := -1
global _CCG_BuildCritical := -1
global _CCG_FinalizeCritical := -1
global _CCG_NotifyCritical := -1

_CCG_Reset() {
	global _CCG_Path, _CCG_BuildCalls, _CCG_WriteCalls, _CCG_PublishCalls
	global _CCG_FinalizeCalls, _CCG_CompensateCalls, _CCG_NotifyCalls
	global _CCG_NestedResult, _CCG_LiveValue, _CCG_WriterResult
	global _CCG_WriterCritical, _CCG_PublishCritical, _CCG_BuildCritical
	global _CCG_FinalizeCritical, _CCG_NotifyCritical
	_CCG_Path := A_Temp . "\ergopti_config_commit_gateway.toml"
	_CCG_BuildCalls := 0
	_CCG_WriteCalls := 0
	_CCG_PublishCalls := 0
	_CCG_FinalizeCalls := 0
	_CCG_CompensateCalls := 0
	_CCG_NotifyCalls := 0
	_CCG_NestedResult := true
	_CCG_LiveValue := "old"
	_CCG_WriterResult := true
	_CCG_WriterCritical := -1
	_CCG_PublishCritical := -1
	_CCG_BuildCritical := -1
	_CCG_FinalizeCritical := -1
	_CCG_NotifyCritical := -1
}

_CCG_Notify(Message, Options) {
	global _CCG_NotifyCalls, _CCG_NotifyCritical
	_CCG_NotifyCalls += 1
	_CCG_NotifyCritical := A_IsCritical
}

_CCG_Writer(Path, Updates) {
	global _CCG_WriteCalls, _CCG_WriterResult, _CCG_WriterCritical
	_CCG_WriteCalls += 1
	_CCG_WriterCritical := A_IsCritical
	return _CCG_WriterResult
}

_CCG_StringWriter(Path, Updates) {
	global _CCG_WriteCalls
	_CCG_WriteCalls += 1
	return "1"
}

_CCG_Publish() {
	global _CCG_PublishCalls, _CCG_LiveValue, _CCG_PublishCritical
	_CCG_PublishCalls += 1
	_CCG_PublishCritical := A_IsCritical
	_CCG_LiveValue := "new"
}

_CCG_Finalize() {
	global _CCG_FinalizeCalls, _CCG_FinalizeCritical
	_CCG_FinalizeCalls += 1
	_CCG_FinalizeCritical := A_IsCritical
	return true
}

_CCG_FalseFinalize() {
	global _CCG_FinalizeCalls
	_CCG_FinalizeCalls += 1
	return false
}

_CCG_Compensate() {
	global _CCG_CompensateCalls
	_CCG_CompensateCalls += 1
	return true
}

_CCG_NestedBuilder() {
	global _CCG_BuildCalls
	_CCG_BuildCalls += 1
	return { updates: [] }
}

_CCG_OwnerBuilder() {
	global _CCG_Path, _CCG_NestedResult, _CCG_BuildCritical
	_CCG_BuildCritical := A_IsCritical
	_CCG_NestedResult := ConfigCommitBuilt(StrUpper(StrReplace(_CCG_Path, "\", "/")),
		"the nested candidate", _CCG_NestedBuilder, _CCG_Writer, _CCG_Notify)
	return {
		updates: [{ Section: "script", Key: "locale", Value: "en" }],
		finalize: _CCG_Finalize,
		publish: _CCG_Publish
	}
}

_CCG_AssertReleased(Message) {
	global _CCG_Path
	Token := _ConfigWriteLeaseTryAcquire(_CCG_Path, "test")
	AssertTrue(Token is Object, Message)
	AssertTrue(_ConfigWriteLeaseRelease(Token), Message . " (release)")
}

_CCG_BuilderRunsUnderOneLeaseThroughPublication() {
	global _CCG_Path, _CCG_BuildCalls, _CCG_NestedResult
	global _CCG_WriteCalls, _CCG_FinalizeCalls, _CCG_PublishCalls
	global _CCG_LiveValue, _CCG_WriterCritical, _CCG_PublishCritical
	_CCG_Reset()
	AssertTrue(ConfigCommitBuilt(_CCG_Path, "the outer candidate",
		_CCG_OwnerBuilder, _CCG_Writer, _CCG_Notify))
	AssertFalse(_CCG_NestedResult,
		"a path alias must not acquire while the outer builder owns config.toml")
	AssertEqual(0, _CCG_BuildCalls,
		"the losing transaction must be refused before reading live state")
	AssertEqual(1, _CCG_WriteCalls)
	AssertEqual(1, _CCG_FinalizeCalls)
	AssertEqual(1, _CCG_PublishCalls)
	AssertEqual("new", _CCG_LiveValue)
	AssertEqual(0, _CCG_WriterCritical,
		"configuration I/O must run outside Critical")
	AssertTrue(_CCG_PublishCritical > 0,
		"the coupled live swap must run inside one short Critical window")
	_CCG_AssertReleased("successful publication must release the config owner")
}
Test("config commit gateway: owner spans build through publication (config-commit-gateway)",
	_CCG_BuilderRunsUnderOneLeaseThroughPublication)

_CCG_MalformedPlan(Kind) {
	Plan := {
		updates: [{ Section: "features", Key: "enabled", Value: false }],
		compensate: _CCG_Compensate
	}
	Plan.%Kind% := {}
	return Plan
}

_CCG_MalformedCallbacksAndWriterStatusFailClosed() {
	global _CCG_Path, _CCG_WriteCalls, _CCG_PublishCalls
	global _CCG_CompensateCalls, _CCG_NotifyCalls
	_CCG_Reset()
	for Kind in ["publish", "finalize", "compensate"] {
		WritesBefore := _CCG_WriteCalls
		AssertFalse(ConfigCommitBuilt(_CCG_Path,
			"the malformed " . Kind . " callback",
			_CCG_MalformedPlan.Bind(Kind), _CCG_Writer, _CCG_Notify),
			"a declared " . Kind . " callback must be callable")
		AssertEqual(WritesBefore, _CCG_WriteCalls,
			"callback validation must precede durable I/O")
		_CCG_AssertReleased("a malformed callback must release ownership")
	}
	AssertFalse(ConfigCommitUpdates(_CCG_Path,
		[{ Section: "features", Key: "enabled", Value: false }],
		"the malformed writer status", _CCG_StringWriter, _CCG_Notify,
		_CCG_Publish))
	AssertEqual(0, _CCG_PublishCalls,
		"a truthy String writer status must never authorize publication")
	AssertEqual(4, _CCG_NotifyCalls,
		"every malformed transaction contract must be visible")
	_CCG_AssertReleased("a malformed writer result must release ownership")
}
Test("config commit gateway: malformed contracts fail before publication (config-commit-contract-types)",
	_CCG_MalformedCallbacksAndWriterStatusFailClosed)

_CCG_FinalizerRefusalIsConsumedAndCompensated() {
	global _CCG_Path, _CCG_FinalizeCalls, _CCG_PublishCalls, _CCG_NotifyCalls
	_CCG_Reset()
	AssertFalse(ConfigCommitUpdates(_CCG_Path,
		[{ Section: "features", Key: "enabled", Value: true }],
		"the refused finalizer", _CCG_Writer, _CCG_Notify,
		_CCG_Publish, _CCG_FalseFinalize))
	AssertEqual(1, _CCG_FinalizeCalls)
	AssertEqual(0, _CCG_PublishCalls,
		"a refused finalizer must stop ordinary live publication")
	AssertEqual(1, _CCG_NotifyCalls)
	_CCG_AssertReleased("a refused finalizer must release ownership")
}
Test("config commit gateway: finalizer refusal is a visible partial failure (config-commit-gateway)",
	_CCG_FinalizerRefusalIsConsumedAndCompensated)

_CCG_InheritedCriticalCannotWrapGatewayWork() {
	global _CCG_Path, _CCG_WriterResult
	global _CCG_BuildCritical, _CCG_WriterCritical
	global _CCG_FinalizeCritical, _CCG_PublishCritical
	global _CCG_NotifyCritical
	_CCG_Reset()
	PreviousCritical := Critical("On")
	try {
		AssertTrue(ConfigCommitBuilt(_CCG_Path, "the inherited built candidate",
			_CCG_OwnerBuilder, _CCG_Writer, _CCG_Notify))
		AssertTrue(A_IsCritical,
			"ConfigCommitBuilt must restore its caller's Critical state")
	} finally Critical(PreviousCritical)
	AssertEqual(0, _CCG_BuildCritical,
		"candidate construction must remain interruptible")
	AssertEqual(0, _CCG_WriterCritical,
		"durable config I/O must remain interruptible")
	AssertEqual(0, _CCG_FinalizeCritical,
		"native finalization must not inherit caller Critical")
	AssertTrue(_CCG_PublishCritical > 0,
		"only the memory publication callback may run Critical")

	_CCG_Reset()
	PreviousCritical := Critical("On")
	try {
		AssertTrue(ConfigCommitUpdates(_CCG_Path,
			[{ Section: "script", Key: "locale", Value: "en" }],
			"the inherited targeted candidate", _CCG_Writer, _CCG_Notify,
			_CCG_Publish, _CCG_Finalize))
		AssertTrue(A_IsCritical,
			"ConfigCommitUpdates must restore its caller's Critical state")
	} finally Critical(PreviousCritical)
	AssertEqual(0, _CCG_WriterCritical)
	AssertEqual(0, _CCG_FinalizeCritical)
	AssertTrue(_CCG_PublishCritical > 0)

	_CCG_Reset()
	OwnerToken := _ConfigWriteLeaseTryAcquire(_CCG_Path,
		"inherited-borrowed-test")
	AssertTrue(OwnerToken is Object)
	try {
		_CCG_WriterResult := false
		PreviousCritical := Critical("On")
		try {
			AssertFalse(ConfigCommitBorrowedUpdates(OwnerToken, _CCG_Path,
				[{ Section: "script", Key: "locale", Value: "en" }],
				"the inherited borrowed candidate", _CCG_Writer, _CCG_Notify))
			AssertTrue(A_IsCritical,
				"borrowed commit must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _CCG_WriterCritical)
		AssertEqual(0, _CCG_NotifyCritical,
			"failure feedback must not inherit caller Critical")
		AssertTrue(_ConfigWriteLeaseOwns(OwnerToken, _CCG_Path),
			"the borrowed gateway must retain the caller's owner")
	} finally _ConfigWriteLeaseRelease(OwnerToken)
}
Test("config commit gateway: inherited Critical cannot wrap writers finalizers or feedback (config-commit-inherited-critical)",
	_CCG_InheritedCriticalCannotWrapGatewayWork)

_TCHP_Flush(State, Handle, Phase) {
	State.flushes += 1, State.handle := Handle
	try {
		if State.mode == "corrupt" && Phase == "stage" {
			_FSRewind(Handle)
			Byte := Buffer(1, 0x21)
			Written := 0
			if !DllCall("kernel32\WriteFile", "Ptr", Handle, "Ptr", Byte, "UInt", 1,
					"UInt*", &Written, "Ptr", 0, "Int") || Written != 1
				throw Error("The owned stage corruption fixture did not write exactly one byte.")
			State.corrupted := true
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
			throw OSError(A_LastError, "the fixture's actual native flush refused")
		State.nativeFlushes += 1
		; This is a typed adapter acknowledgement refusal after actual native
		; rename, not a claim that the host OS itself refused FlushFileBuffers.
		return State.mode == "partial" && Phase == "published" ? 0 : 1
	} catch as Err {
		State.error := Err
		return 0
	}
}
_TCHP_Write(State, Path, Updates) {
	State.writes += 1
	Flush := State.mode == "control" ? 0 : _TCHP_Flush.Bind(State)
	return _TOML_BatchWriteImpl(Path, Updates, [], "write", , , false, 0, Flush)
}
_TCHP_CaptureStage(State, Create, Folder, Name, Attributes) {
	Handle := Create.Call(Folder, Name, Attributes)
	State.handle := Handle, State.creations += 1
	return Handle
}
_TCHP_ObserveOwned(State, This, Path, Content, Suffix, &Detail, StageFn,
		BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn) {
	Result := Func.Prototype.Call.Call(This, Path, Content, Suffix, &Detail,
		_TCHP_CaptureStage.Bind(State, StageFn), BeforePublishFn, AdmissionFn,
		ReplaceExisting, &Publication, FlushFn)
	; This observation precedes the renderer's error logger and gateway
	; feedback, which can otherwise recycle a legitimately closed handle value.
	if State.handle != -1 {
		Information := Buffer(52, 0)
		DllCall("kernel32\SetLastError", "UInt", 0)
		State.retired := !DllCall("kernel32\GetFileInformationByHandle", "Ptr", State.handle,
			"Ptr", Information, "Int")
		State.retirementError := A_LastError
	}
	return Result
}
_TCHP_Notify(State, Message, Options) {
	State.messages.Push(Message)
}
_TCHP_Publish(State) {
	State.publishes += 1
}
_TCHP_RefuseBuild(State) {
	State.builds += 1
	return 0
}
_TCHP_Case(Borrowed, Mode) {
	global ConfigurationFile
	SavedPathSet := IsSet(ConfigurationFile)
	SavedPath := SavedPathSet ? ConfigurationFile : ""
	Root := A_Temp . "\ergopti_toml_held_partial_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\data.toml", Created := false, Lease := 0
	State := {mode: Mode, writes: 0, flushes: 0, nativeFlushes: 0, handle: -1,
		corrupted: false, error: 0, messages: [], publishes: 0, creations: 0, retired: false, retirementError: 0, builds: 0}
	Owner := FSWriteReplaceOwned
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	Installed := false
	try {
		AssertFalse(HadCall, "the observer must not replace an unknown native function owner")
		AssertFalse(_ConfigFullSaveHasPending(), "the private generic gateway must not detach a foreign full-save obligation")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		; This is a real ordinary data-file gateway, without pretending to own
		; a selected config.toml journal/schema destination.
		ConfigurationFile := unset
		AssertEqual(1, FSWriteCreateDurable(Path, '[custom]`nvalue = "Initial"`n'))
		Before := FSReadBytesStrict(Path)
		Updates := [{Section: "custom", Key: "value", Value: "Edited"}]
		Writer := _TCHP_Write.Bind(State), Notify := _TCHP_Notify.Bind(State)
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _TCHP_ObserveOwned.Bind(State)})
		Installed := true
		if Borrowed {
			Lease := _ConfigWriteLeaseTryAcquire(Path, "toml-held-partial-fixture")
			AssertTrue(Lease is Object)
			Result := ConfigCommitBorrowedUpdates(Lease, Path, Updates, "private held TOML", Writer, Notify)
		} else
			Result := ConfigCommitUpdates(Path, Updates, "private held TOML", Writer, Notify, _TCHP_Publish.Bind(State))
		Closed := State.retired, CloseError := State.retirementError
		After := FSReadBytesStrict(Path)
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		Partial := _TOML_SessionHasPartialPublication(Path)
		_TestPrint("# toml-held borrowed=" . Borrowed . " mode=" . Mode . " result=" . Result
			. " disk=" . Disk["custom"]["value"] . " partial=" . Partial . " publishes=" . State.publishes
			. " flushes=" . State.flushes . " native-flushes=" . State.nativeFlushes . " corrupted=" . State.corrupted
			. " closed=" . Closed . " close-error=" . CloseError . " messages=" . State.messages.Length)
		if IsObject(State.error)
			throw State.error
		AssertEqual(1, State.writes)
		AssertEqual(1, State.creations, "the observer forwards one actual exclusive stage acquisition")
		if State.handle != -1 {
			AssertTrue(Closed)
			AssertEqual(6, CloseError, "the completed native stage handle must really be invalid before more filesystem work")
		}
		if Mode == "control" {
			AssertTrue(Result)
			AssertEqual("Edited", Disk["custom"]["value"])
			AssertFalse(Partial)
			AssertEqual(0, State.messages.Length)
			AssertEqual(Borrowed ? 0 : 1, State.publishes)
		} else if Mode == "corrupt" {
			AssertFalse(Result)
			AssertTrue(State.corrupted)
			AssertEqual(1, State.nativeFlushes)
			AssertFalse(Partial, "rejected stage bytes must not fabricate a native rename effect")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"))
			AssertEqual(0, State.publishes)
		} else {
			AssertFalse(Result)
			AssertEqual("Edited", Disk["custom"]["value"], "the partial case must have genuinely published its native candidate")
			AssertEqual(2, State.nativeFlushes)
			AssertTrue(Partial)
			AssertEqual(0, State.publishes)
			AssertEqual(1, State.messages.Length)
			AssertEqual(t("onboarding.error.write_failed"), State.messages[1], "the gateway must not announce unchanged/reverted durability")
			AssertTrue(TOML_WriteRefusal(Path) is String && TOML_WriteRefusal(Path) != "")
			TOML_RefuseWrites(Path, "a later source admission refusal")
			AssertEqual("a later source admission refusal", TOML_WriteRefusal(Path))
			AssertTrue(_TOML_SessionHasPartialPublication(Path), "a new refusal reason must preserve the native session effect")
			AssertEqual("Edited", ParseTomlFile(Path)["custom"]["value"], "actual fresh reading can observe the candidate without clearing session safety")
			if Borrowed
				Retry := ConfigCommitBorrowedUpdates(Lease, Path, [{Section: "custom", Key: "value", Value: "Retry"}], "blocked retry", 0, Notify)
			else
				Retry := ConfigCommitUpdates(Path, [{Section: "custom", Key: "value", Value: "Retry"}], "blocked retry", 0, Notify)
			AssertFalse(Retry)
			AssertEqual(2, State.messages.Length)
			AssertEqual(t("onboarding.error.write_failed"), State.messages[2], "blocked retry feedback refers to the earlier partial session effect")
			BuiltRetry := ConfigCommitBuilt(Path, "refused candidate in partial session",
				_TCHP_RefuseBuild.Bind(State), 0, Notify, Borrowed ? Lease : 0)
			_TestPrint("# toml-held-built-retry borrowed=" . Borrowed . " result=" . BuiltRetry
				. " build-calls=" . State.builds . " messages=" . State.messages.Length)
			AssertFalse(BuiltRetry, "a real producer refusing its candidate must stay a failed action")
			AssertEqual(1, State.builds, "the actual built gateway must reach the supplied real candidate producer")
			AssertEqual(3, State.messages.Length)
			AssertEqual(t("onboarding.error.write_failed"), State.messages[3], "pre-transfer failure must retain truthful session-partial feedback")
			RetryBytes := FSReadBytesStrict(Path)
			AssertEqual(After.Size, RetryBytes.Size)
			AssertEqual(After.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", After,
				"Ptr", RetryBytes, "UPtr", After.Size, "UPtr"), "the blocked retry must not perform another native publication")
		}
		if Borrowed
			AssertTrue(_ConfigWriteLeaseOwns(Lease, Path), "the borrowed gateway must retain the exact caller owner")
	} finally {
		if Installed {
			if HadCall
				Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
			else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
				Object.Prototype.DeleteProp.Call(Owner, "Call")
		}
		if Lease is Object
			_ConfigWriteLeaseRelease(Lease)
		ConfigurationFile := SavedPathSet ? SavedPath : unset
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals()
			if Refusals.Has(_TOML_WriteRefusalKey(Path))
				Refusals.Delete(_TOML_WriteRefusalKey(Path))
			DirDelete(Root, true)
		}
	}
}
Test("TOML held publication: owned gateway reports partial session and blocks retry (toml-held-publication)", _TCHP_Case.Bind(false, "partial"))
Test("TOML held publication: borrowed gateway reports partial session and blocks retry (toml-held-publication)", _TCHP_Case.Bind(true, "partial"))
Test("TOML held publication: owned full native acknowledgement publishes (toml-held-publication)", _TCHP_Case.Bind(false, "control"))
Test("TOML held publication: borrowed full native acknowledgement retains owner (toml-held-publication)", _TCHP_Case.Bind(true, "control"))
Test("TOML held publication: actual held-stage corruption refuses before rename (toml-held-publication)", _TCHP_Case.Bind(false, "corrupt"))

_TRIO_Flush(State, Handle, Phase) {
	State.flushes += 1
	try {
		AssertFalse(A_IsCritical)
		if Phase == "stage" && !State.changed {
			if FSWriteDurable(State.targetA, '[custom]`nvalue = "External"`n') != 1
				throw Error("The competing original target was not written.")
			State.winner := FSReadBytesStrict(State.targetA)
			SetWorkingDir(State.otherCwd)
			State.changed := true
		}
		if !DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
			throw OSError(A_LastError, "the relative-path fixture's genuine stage flush")
		return 1
	} catch as Err {
		State.error := Err
		return 0
	}
}
_TRIO_Case(Race) {
	SavedCwd := A_WorkingDir
	Nonce := A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Root := A_Temp . "\ergopti_toml_relative_" . Nonce
	Created := false
	Relative := Race ? "nested_" . Nonce . "\data.toml" : "data_" . Nonce . ".toml"
	FirstDir := Root . "\first", SecondDir := Root . "\second"
	PathA := FirstDir . "\" . Relative, PathB := SecondDir . "\" . Relative
	State := {targetA: PathA, otherCwd: SecondDir, flushes: 0, changed: false, error: 0, winner: 0}
	try {
		AssertFalse(_ConfigFullSaveHasPending(), "a private cwd scope must not redirect an accepted foreign full-save obligation")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSCreateDirectoryExclusiveStrict(FirstDir))
		AssertEqual(1, FSCreateDirectoryExclusiveStrict(SecondDir))
		if Race {
			AssertEqual(1, FSCreateDirectoryExclusiveStrict(FirstDir . "\nested_" . Nonce))
			AssertEqual(1, FSCreateDirectoryExclusiveStrict(SecondDir . "\nested_" . Nonce))
		}
		Source := '[custom]`nvalue = "Initial"`n'
		AssertEqual(1, FSWriteCreateDurable(PathA, Source))
		AssertEqual(1, FSWriteCreateDurable(PathB, Source))
		OtherBefore := FSReadBytesStrict(PathB)
		SetWorkingDir(FirstDir)
		Updates := [{Section: "custom", Key: "value", Value: "Edited"}]
		Result := Race ? _TOML_BatchWriteImpl(Relative, Updates, [], "write", , , false, 0, _TRIO_Flush.Bind(State))
			: TOML_BatchWrite(Relative, Updates)
		ActualA := FSReadBytesStrict(PathA), ActualB := FSReadBytesStrict(PathB)
		ValueA := TOML_ParseDocument(FSReadUtf8Exact(PathA))["custom"]["value"]
		_TestPrint("# toml-relative race=" . Race . " result=" . Result . " targetA=" . ValueA
			. " flushes=" . State.flushes . " changed=" . State.changed . " cwd-second=" . (A_WorkingDir == SecondDir))
		if IsObject(State.error)
			throw State.error
		AssertEqual(OtherBefore.Size, ActualB.Size)
		AssertEqual(OtherBefore.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", OtherBefore,
			"Ptr", ActualB, "UPtr", OtherBefore.Size, "UPtr"), "the competing current-directory target is not this operation's source or destination")
		if Race {
			AssertTrue(State.changed, "the real stage flush must run the cwd/source mutation cutpoint")
			AssertFalse(Result, "the original native target changed after capture and must remain authoritative")
			AssertEqual("External", ValueA)
			AssertEqual(State.winner.Size, ActualA.Size)
			AssertEqual(State.winner.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", State.winner,
				"Ptr", ActualA, "UPtr", State.winner.Size, "UPtr"))
		} else {
			AssertTrue(Result, "the public drop-in ordinary writer must retain basename-relative support")
			AssertEqual("Edited", ValueA)
			TOML_RefuseWrites(Relative, "private logical path fence")
			Refused := TOML_BatchWrite(Relative, [{Section: "custom", Key: "value", Value: "Retry"}])
			AssertFalse(Refused, "capturing an absolute I/O target must not bypass the original logical refusal identity")
			AssertEqual("private logical path fence", TOML_WriteRefusal(Relative))
			AfterRefusal := FSReadBytesStrict(PathA)
			AssertEqual(ActualA.Size, AfterRefusal.Size)
			AssertEqual(ActualA.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", ActualA,
				"Ptr", AfterRefusal, "UPtr", ActualA.Size, "UPtr"))
		}
	} finally {
		SetWorkingDir(SavedCwd)
		if Created {
			for KeyPath in [Relative, PathA, PathB] {
				_TOML_InvalidateParseCache(KeyPath)
				Refusals := _TOML_WriteRefusals()
				Key := _TOML_WriteRefusalKey(KeyPath)
				if Refusals.Has(Key)
					Refusals.Delete(Key)
			}
			DirDelete(Root, true)
		}
	}
}
Test("TOML relative native target: public basename save retains logical refusal identity (toml-relative-native-target)", _TRIO_Case.Bind(false))
Test("TOML relative native target: cwd movement cannot bless a different source (toml-relative-native-target)", _TRIO_Case.Bind(true))
