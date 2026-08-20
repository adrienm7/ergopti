; tests/unit/test_config_commit_gateway.ahk

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
