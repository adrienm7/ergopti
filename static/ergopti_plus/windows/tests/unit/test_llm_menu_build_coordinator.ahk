; tests/unit/test_llm_menu_build_coordinator.ahk

; ==============================================================================
; MODULE: LLM Menu Build Coordinator
; DESCRIPTION:
; AHK-010 behavioral regression. Every menu producer transfers its request to
; one generation owner. Requests arriving during an active build or Suspend are
; retained, coalesced, and drained from the newest state exactly once.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMBCO_IsSuspended(State) {
	return State["suspended"]
}

_LMBCO_BuildWithBusyRequests(State) {
	State["passes"].Push(State["value"])
	if State["passes"].Length == 1 {
		State["value"] := "fresh"
		AssertTrue(State["coordinator"].Request("tags"))
		AssertTrue(State["coordinator"].Request("health"))
	}
	return true
}

_LMBCO_BuildCount(State) {
	State["builds"] += 1
	return true
}

_LMBCO_SuspendWinsAfterAdmission(State) {
	State["checks"] += 1
	if State["checks"] == 1
		return false
	if State["checks"] == 2
		return true
	return State["suspended"]
}

_LMBCO_BuildInterruptedBySuspend(State) {
	State["builds"] += 1
	if State["builds"] == 1 {
		State["suspended"] := true
		AssertTrue(State["coordinator"].Request("health"),
			"an active owner must retain the request even after Suspend wins")
		return false
	}
	return true
}

_LMBCO_BuildThrowsOnce(State) {
	State["builds"] += 1
	if State["builds"] == 1
		throw Error("injected build failure")
	return true
}

_LMBCO_RecordError(State, Err) {
	State["errors"].Push(Err.Message)
}

_LMBCO_BusyRequestsDrainNewestSnapshot() {
	State := Map("suspended", false, "value", "stale", "passes", [])
	Coordinator := LLMMenuBuildCoordinator(
		_LMBCO_BuildWithBusyRequests.Bind(State),
		_LMBCO_IsSuspended.Bind(State))
	State["coordinator"] := Coordinator

	AssertTrue(Coordinator.Request("initial"))
	AssertEqual(2, State["passes"].Length,
		"two requests during pass one must coalesce into one successor")
	AssertEqual("stale", State["passes"][1])
	AssertEqual("fresh", State["passes"][2],
		"the terminal pass must rebuild from the newest state")
	AssertEqual(3, Coordinator.RequestedGeneration)
	AssertEqual(3, Coordinator.PublishedGeneration)
	AssertFalse(Coordinator.Active)
}

_LMBCO_SuspendedRequestsReplayOnceOnResume() {
	State := Map("suspended", true, "builds", 0)
	Coordinator := LLMMenuBuildCoordinator(
		_LMBCO_BuildCount.Bind(State),
		_LMBCO_IsSuspended.Bind(State))

	AssertFalse(Coordinator.Request("tags"))
	AssertFalse(Coordinator.Request("health"))
	AssertFalse(Coordinator.Request("delete"))
	AssertFalse(Coordinator.Request("post_pull"))
	AssertEqual(0, State["builds"],
		"native menu work must remain silent throughout Suspend")
	AssertEqual(4, Coordinator.RequestedGeneration)
	AssertEqual(0, Coordinator.PublishedGeneration)

	State["suspended"] := false
	AssertTrue(Coordinator.Service())
	AssertEqual(1, State["builds"],
		"all paused producers must coalesce into one newest resume build")
	AssertEqual(4, Coordinator.PublishedGeneration)
	AssertTrue(Coordinator.Service())
	AssertEqual(1, State["builds"],
		"a settled coordinator must not invent another resume build")
}

_LMBCO_SuspendDuringBuildRetainsUnpublishedGeneration() {
	State := Map("suspended", false, "builds", 0)
	Coordinator := LLMMenuBuildCoordinator(
		_LMBCO_BuildInterruptedBySuspend.Bind(State),
		_LMBCO_IsSuspended.Bind(State))
	State["coordinator"] := Coordinator

	AssertFalse(Coordinator.Request("initial"))
	AssertEqual(1, State["builds"])
	AssertEqual(2, Coordinator.RequestedGeneration)
	AssertEqual(0, Coordinator.PublishedGeneration,
		"a candidate refused at the pause publication fence is not published")
	AssertFalse(Coordinator.Active)

	State["suspended"] := false
	AssertTrue(Coordinator.Service())
	AssertEqual(2, State["builds"])
	AssertEqual(2, Coordinator.PublishedGeneration)
}

_LMBCO_SuspendBetweenAdmissionAndDrainRetainsRequest() {
	State := Map("suspended", false, "checks", 0, "builds", 0)
	Coordinator := LLMMenuBuildCoordinator(
		_LMBCO_BuildCount.Bind(State),
		_LMBCO_SuspendWinsAfterAdmission.Bind(State))

	AssertFalse(Coordinator.Request("health"),
		"Suspend winning after admission must stop before native menu work")
	AssertEqual(0, State["builds"])
	AssertEqual(1, Coordinator.RequestedGeneration)
	AssertEqual(0, Coordinator.PublishedGeneration)
	AssertTrue(Coordinator.Service())
	AssertEqual(1, State["builds"])
	AssertEqual(1, Coordinator.PublishedGeneration)
}

_LMBCO_ThrownBuildIsReportedAndRetained() {
	State := Map("suspended", false, "builds", 0, "errors", [])
	Coordinator := LLMMenuBuildCoordinator(
		_LMBCO_BuildThrowsOnce.Bind(State),
		_LMBCO_IsSuspended.Bind(State),
		_LMBCO_RecordError.Bind(State))

	AssertFalse(Coordinator.Request("settings"))
	AssertEqual(1, State["errors"].Length)
	AssertEqual("injected build failure", State["errors"][1])
	AssertEqual(0, Coordinator.PublishedGeneration,
		"an exception must not consume the dirty generation")
	AssertTrue(Coordinator.Service())
	AssertEqual(2, State["builds"])
	AssertEqual(1, Coordinator.PublishedGeneration)
}

Test("llm menu coordinator: busy requests drain newest snapshot (ahk-010-menu-build-coordinator)",
	_LMBCO_BusyRequestsDrainNewestSnapshot)
Test("llm menu coordinator: suspended producers coalesce into one resume build (ahk-010-menu-build-coordinator)",
	_LMBCO_SuspendedRequestsReplayOnceOnResume)
Test("llm menu coordinator: suspend during staging retains unpublished generation (ahk-010-menu-build-coordinator)",
	_LMBCO_SuspendDuringBuildRetainsUnpublishedGeneration)
Test("llm menu coordinator: Suspend between admission and drain retains request (ahk-010-menu-build-coordinator)",
	_LMBCO_SuspendBetweenAdmissionAndDrainRetainsRequest)
Test("llm menu coordinator: thrown build is reported and retained (ahk-010-menu-build-coordinator)",
	_LMBCO_ThrownBuildIsReportedAndRetained)





_LMBCO_ObservationLine(Lines, Line) {
	if InStr(Line, "[LLMBuildObservation.")
		Lines.Push(Line)
}

_LMBCO_ClosedBuildObservation() {
	global _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_FLUSH_ACTIVE
	global _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global _LOGGER_REPEAT_ENABLED, _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	global _LastErrTime, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LOGGER_SUB_PENDING
	Saved := [_LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_FLUSH_ACTIVE,
		_LOGGER_FORCE_FLUSH_PENDING, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS,
		_LOGGER_REPEAT_ENABLED, _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT,
		_LastErrTime, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LOGGER_SUB_PENDING]
	Lines := [], State := Map("suspended", false, "builds", 0)
	Coordinator := LLMMenuBuildCoordinator(_LMBCO_BuildCount.Bind(State),
		_LMBCO_IsSuspended.Bind(State))
	try {
		_LOGGER_TEST_SINK := _LMBCO_ObservationLine.Bind(Lines)
		_LOGGER_INFO_ENABLED := true, _LOGGER_REPEAT_ENABLED := false
		; The real logger records metadata without admitting a file append.
		_LOGGER_FLUSH_ACTIVE := true, _LOGGER_FORCE_FLUSH_PENDING := false
		_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
		_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_LEVEL := "INFO", _LOGGER_DEDUP_COUNT := 0
		_LastErrTime := 0, LOGGER_RING_BUFFER := [], LOGGER_RING_CURSOR := 0
		_LOGGER_SUB_PENDING := Map()
		AssertTrue(Coordinator.Request("toggle_committed"))
		AssertTrue(Coordinator.Request("private-build-reason-sentinel"))
		AssertEqual(2, State["builds"], "observation must preserve actual build execution")
		AssertEqual(2, Coordinator.PublishedGeneration)
		AssertFalse(Coordinator.Active)
		AssertEqual(2, Lines.Length)
		AssertContains(Lines[1], "[LLMBuildObservation.toggle_committed] Build entered; generation=1.")
		AssertContains(Lines[2], "[LLMBuildObservation.other] Build entered; generation=2.")
		for Line in Lines {
			AssertContains(Line, "[INFO]")
			AssertFalse(InStr(Line, "private-build-reason-sentinel"))
		}
		for InvalidGeneration in [0, -1, "1", 1.5]
			Coordinator._ObserveBuild("toggle_committed", InvalidGeneration)
		AssertEqual(2, Lines.Length, "non-positive or non-integer generation must not be published")
		AssertFalse(_LOGGER_FORCE_FLUSH_PENDING, "informational observation must not request recursive forced flush")
	} finally {
		_LOGGER_TEST_SINK := Saved[1], _LOGGER_INFO_ENABLED := Saved[2]
		_LOGGER_FLUSH_ACTIVE := Saved[3], _LOGGER_FORCE_FLUSH_PENDING := Saved[4]
		_LOGGER_PENDING := Saved[5], _LOGGER_PENDING_ERRORS := Saved[6]
		_LOGGER_REPEAT_ENABLED := Saved[7]
		_LOGGER_DEDUP_KEY := Saved[8], _LOGGER_DEDUP_LEVEL := Saved[9], _LOGGER_DEDUP_COUNT := Saved[10]
		_LastErrTime := Saved[11], LOGGER_RING_BUFFER := Saved[12], LOGGER_RING_CURSOR := Saved[13]
		_LOGGER_SUB_PENDING := Saved[14]
	}
}
Test("llm menu coordinator: real requests emit only closed buffered metadata (llm-build-reason-observation)",
	_LMBCO_ClosedBuildObservation)
