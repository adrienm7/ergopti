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
