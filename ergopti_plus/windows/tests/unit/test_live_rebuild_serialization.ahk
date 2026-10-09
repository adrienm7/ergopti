; static/ergopti_plus/windows/tests/unit/test_live_rebuild_serialization.ahk

; ==============================================================================
; MODULE: Live Hotstring Rebuild Serialization Tests
; DESCRIPTION:
; Behavioural coverage for pseudo-thread re-entry while the hotstring registry
; is being rebuilt. A nested request must be coalesced behind the active owner,
; never enter the rebuild body recursively, and a throwing owner must release
; the coordinator without acknowledging unpublished work.
; ==============================================================================

#Requires AutoHotkey v2.0+

global _LRS_Events := []
global _LRS_Depth := 0
global _LRS_MaxDepth := 0
global _LRS_Runs := 0
global _LRS_ReleaseRequests := 0
global _LRS_ExpectedError := 0
global _LRS_SuccessorAcquired := false
global _LRS_FailureMode := ""

_LRS_ResetCoordinator() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress
	global _LRS_Events, _LRS_Depth, _LRS_MaxDepth, _LRS_Runs, _LRS_ReleaseRequests
	global _LRS_SuccessorAcquired
	global _LRS_FailureMode
	_HSLR_RequestedGeneration := 0
	_HSLR_PublishedGeneration := 0
	_HSLR_Active := false
	HSE_RebuildInProgress := false
	_LRS_Events := []
	_LRS_Depth := 0
	_LRS_MaxDepth := 0
	_LRS_Runs := 0
	_LRS_ReleaseRequests := 0
	_LRS_SuccessorAcquired := false
	_LRS_FailureMode := ""
}

_LRS_ReentrantBody() {
	global HSE_RebuildInProgress
	global _LRS_Events, _LRS_Depth, _LRS_MaxDepth, _LRS_Runs
	_LRS_Depth += 1
	_LRS_MaxDepth := Max(_LRS_MaxDepth, _LRS_Depth)
	_LRS_Runs += 1
	RunNumber := _LRS_Runs
	AssertTrue(HSE_RebuildInProgress,
		"the matcher fence must remain raised throughout every coalesced pass")
	_LRS_Events.Push("start-" . RunNumber)
	try {
		if (RunNumber == 1) {
			Accepted := RebuildHotstringsLive(_LRS_ReentrantBody)
			_LRS_Events.Push(Accepted ? "nested-accepted" : "nested-refused")
		}
		_LRS_Events.Push("end-" . RunNumber)
	} finally {
		_LRS_Depth -= 1
	}
	return true
}

_LRS_EventText() {
	global _LRS_Events
	Text := ""
	for Index, Event in _LRS_Events
		Text .= (Index > 1 ? "|" : "") . Event
	return Text
}

_LRS_NestedRequestRunsSequentially() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global _LRS_Events, _LRS_MaxDepth, _LRS_Runs
	_LRS_ResetCoordinator()
	AssertTrue(RebuildHotstringsLive(_LRS_ReentrantBody))
	AssertEqual(1, _LRS_MaxDepth,
		"a nested tray/editor request must never enter the rebuild body recursively")
	AssertEqual(2, _LRS_Runs,
		"one follow-up rebuild must cover every request that arrived during the active pass")
	AssertEqual("start-1|nested-accepted|end-1|start-2|end-2",
		_LRS_EventText(),
		"the active registry owner must finish before the coalesced request starts")
	AssertEqual(2, _HSLR_RequestedGeneration)
	AssertEqual(2, _HSLR_PublishedGeneration)
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress,
		"the matcher fence must lower only with final owner release")
}
Test("menu_rebuild: nested live rebuilds are serialized (live-rebuild-reentrant-fence)",
	_LRS_NestedRequestRunsSequentially)

_LRS_OnlyOneOwnerCanBeAcquired() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress
	_LRS_ResetCoordinator()
	AssertTrue(_HSLR_RequestAndTryAcquire(),
		"the first request must acquire the idle rebuild owner")
	AssertFalse(_HSLR_RequestAndTryAcquire(),
		"a second pseudo-thread must queue behind the live owner")
	AssertEqual(2, _HSLR_RequestedGeneration)
	AssertEqual(0, _HSLR_PublishedGeneration)
	AssertTrue(_HSLR_Active)
	AssertTrue(HSE_RebuildInProgress)
	_HSLR_ReleaseAfterInvariantFailure()
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress)
}
Test("menu_rebuild: acquisition admits only one registry owner (live-rebuild-owner-acquire)",
	_LRS_OnlyOneOwnerCanBeAcquired)

_LRS_RequestAtIdleRelease() {
	global _LRS_ReleaseRequests
	if (_LRS_ReleaseRequests > 0)
		return
	_LRS_ReleaseRequests += 1
	AssertTrue(RebuildHotstringsLive(_LRS_SuccessBody),
		"a request arriving at owner release must be accepted")
}

_LRS_IdleReleaseCannotLoseARequest() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global _LRS_ReleaseRequests, _LRS_Runs
	_LRS_ResetCoordinator()
	AssertTrue(RebuildHotstringsLive(
		_LRS_SuccessBody, _LRS_RequestAtIdleRelease))
	AssertEqual(1, _LRS_ReleaseRequests)
	AssertEqual(2, _LRS_Runs,
		"a request delivered immediately before owner release needs a second serialized pass")
	AssertEqual(_HSLR_RequestedGeneration, _HSLR_PublishedGeneration,
		"owner release must never strand an accepted generation")
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress)
}
Test("menu_rebuild: idle release cannot lose a concurrent request (live-rebuild-release-handoff)",
	_LRS_IdleReleaseCannotLoseARequest)

_LRS_AcquireSuccessorAfterRelease() {
	global _LRS_SuccessorAcquired
	_LRS_SuccessorAcquired := _HSLR_RequestAndTryAcquire()
}

_LRS_OldOwnerCannotReleaseItsSuccessor() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress, _LRS_SuccessorAcquired
	_LRS_ResetCoordinator()
	AssertTrue(RebuildHotstringsLive(
		_LRS_SuccessBody, 0, _LRS_AcquireSuccessorAfterRelease))
	AssertTrue(_LRS_SuccessorAcquired,
		"a successor arriving after idle release must acquire a fresh owner")
	AssertTrue(_HSLR_Active,
		"the returning old stack must not clear its successor's owner flag")
	AssertTrue(HSE_RebuildInProgress,
		"the returning old stack must not lower its successor's matcher fence")
	AssertEqual(2, _HSLR_RequestedGeneration)
	AssertEqual(1, _HSLR_PublishedGeneration)
	AssertTrue(_HSLR_DrainOwner(_LRS_SuccessBody))
	AssertEqual(_HSLR_RequestedGeneration, _HSLR_PublishedGeneration)
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress)
}
Test("menu_rebuild: released owner cannot clear its successor (live-rebuild-owner-aba)",
	_LRS_OldOwnerCannotReleaseItsSuccessor)

_LRS_FailFirstPassAfterNestedRequest() {
	global _LRS_Runs, _LRS_FailureMode, _LRS_ExpectedError
	_LRS_Runs += 1
	if (_LRS_Runs > 1)
		return true
	AssertTrue(RebuildHotstringsLive(_LRS_FailFirstPassAfterNestedRequest),
		"a request delivered during the first pass must be accepted")
	if (_LRS_FailureMode == "throw")
		throw _LRS_ExpectedError
	return "1"
}

_LRS_AssertFailedPassHandsOff(FailureMode) {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress, _LRS_FailureMode, _LRS_ExpectedError, _LRS_Runs
	_LRS_ResetCoordinator()
	_LRS_FailureMode := FailureMode
	_LRS_ExpectedError := Error("injected first-pass failure")
	AssertTrue(RebuildHotstringsLive(_LRS_FailFirstPassAfterNestedRequest),
		"the retained owner must satisfy the accepted newer request")
	AssertEqual(2, _LRS_Runs,
		"a newer generation must receive one retry after the pass it interrupted fails")
	AssertEqual(2, _HSLR_RequestedGeneration)
	AssertEqual(2, _HSLR_PublishedGeneration,
		"the successful handoff pass must publish every accepted generation")
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress)
}

_LRS_ThrownPassHandsOffToAcceptedRequest() {
	_LRS_AssertFailedPassHandsOff("throw")
}
Test("menu_rebuild: a thrown pass hands off to its accepted successor (live-rebuild-failure-handoff)",
	_LRS_ThrownPassHandsOffToAcceptedRequest)

_LRS_MalformedPassHandsOffToAcceptedRequest() {
	_LRS_AssertFailedPassHandsOff("malformed")
}
Test("menu_rebuild: malformed failure hands off to its accepted successor (live-rebuild-failure-handoff)",
	_LRS_MalformedPassHandsOffToAcceptedRequest)

_LRS_ThrowExpectedError() {
	global _LRS_Runs, _LRS_ExpectedError
	_LRS_Runs += 1
	throw _LRS_ExpectedError
}

_LRS_SuccessBody() {
	global _LRS_Runs, HSE_RebuildInProgress
	AssertTrue(HSE_RebuildInProgress,
		"an acquired rebuild body must always run behind the matcher fence")
	_LRS_Runs += 1
	return true
}

_LRS_FailureReleasesOwnerWithoutPublishing() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global _LRS_Runs, _LRS_ExpectedError
	_LRS_ResetCoordinator()
	Threw := false
	try {
		_LRS_ExpectedError := Error("injected rebuild failure")
		RebuildHotstringsLive(_LRS_ThrowExpectedError)
	} catch as Err {
		Threw := ObjPtr(Err) == ObjPtr(_LRS_ExpectedError)
	}
	AssertTrue(Threw)
	AssertFalse(_HSLR_Active,
		"a failed rebuild must release the coordinator for a later retry")
	AssertFalse(HSE_RebuildInProgress,
		"a failed rebuild must release the matcher fence")
	AssertEqual(1, _HSLR_RequestedGeneration)
	AssertEqual(0, _HSLR_PublishedGeneration,
		"a thrown rebuild must never acknowledge an unpublished registry")
	AssertTrue(RebuildHotstringsLive(_LRS_SuccessBody))
	AssertEqual(2, _LRS_Runs,
		"one successful retry must cover both the retained and new request")
	AssertEqual(_HSLR_RequestedGeneration, _HSLR_PublishedGeneration)
	AssertFalse(_HSLR_Active)
}
Test("menu_rebuild: rebuild failure releases owner without false publication (live-rebuild-reentrant-fence)",
	_LRS_FailureReleasesOwnerWithoutPublishing)

_LRS_StringOneBody() {
	global _LRS_Runs
	_LRS_Runs += 1
	return "1"
}

_LRS_MalformedSuccessCannotPublish() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress
	_LRS_ResetCoordinator()
	AssertFalse(RebuildHotstringsLive(_LRS_StringOneBody),
		"only an Integer true may acknowledge a completed registry publication")
	AssertEqual(1, _HSLR_RequestedGeneration)
	AssertEqual(0, _HSLR_PublishedGeneration)
	AssertFalse(_HSLR_Active)
	AssertFalse(HSE_RebuildInProgress)
}
Test("menu_rebuild: malformed success cannot publish a generation (live-rebuild-strict-outcome)",
	_LRS_MalformedSuccessCannotPublish)
