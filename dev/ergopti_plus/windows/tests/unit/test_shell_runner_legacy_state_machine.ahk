; static/ergopti_plus/windows/tests/unit/test_shell_runner_legacy_state_machine.ahk

; ==============================================================================
; MODULE: Legacy ShellRunner State-Machine Regression Tests
; DESCRIPTION:
; Drives the exact state transitions behind ShellRunner_Spawn without launching
; a subprocess. Run() pumps AHK messages before it returns a PID, so lifecycle
; callbacks can otherwise disappear in the private-PID publication window.
;
; FEATURES & RATIONALE:
; 1. A terminate-before-start remains a no-op and the handle stays startable.
; 2. Termination while Run is pumping cancels the unpublished launch.
; 3. Detach is remembered before publication and exact after publication.
; 4. Completion and termination compete for one ObjPtr-checked winner claim.
; 5. Async cancellation publishes detached cleanup instead of blocking start.
; 6. A claimed completion remains revocable until its callback dispatch claim.
; 7. The complete public handle surface delegates to the tested transitions.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Test State Helpers =======
; =====================================
; =====================================

global _SRLSM_NEXT_TASK_ID := 910000

_SRLSM_NewState(OnDone := 0) {
	global _SRLSM_NEXT_TASK_ID
	local task_id := ++_SRLSM_NEXT_TASK_ID
	return _SR_LegacyNewState(task_id,
		A_Temp . "\ergopti_sr_state_test_" . task_id . ".tmp", OnDone)
}

_SRLSM_DropState(State) {
	local previous_critical := Critical("On")
	try {
		local task_id := State["TaskId"]
		if _SR_ActiveTasks.Has(task_id)
			&& ObjPtr(_SR_ActiveTasks[task_id]) = ObjPtr(State)
			_SR_ActiveTasks.Delete(task_id)
	} finally {
		Critical(previous_critical)
	}
	local tmp_file := State["TmpFile"]
	if FileExist(tmp_file)
		FileDelete(tmp_file)
}





; =========================================
; =========================================
; ======= 2/ Pre-Start Contracts ===========
; =========================================
; =========================================

_SRLSM_TerminateBeforeStartKeepsStartable() {
	local state := _SRLSM_NewState()
	try {
		AssertEqual(0, _SR_LegacyClaimTerminate(state),
			"terminate before start must not manufacture a terminal claim")
		AssertEqual(SR_LEGACY_PHASE_READY, state["Phase"],
			"terminate before start must leave the lifecycle in READY")
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"the same handle must still begin its first start after terminate")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminate before start stays startable (shellrunner-legacy-prestart)",
	_SRLSM_TerminateBeforeStartKeepsStartable)

_SRLSM_RequestTerminateBeforeStartRefusesStart() {
	local state := _SRLSM_NewState()
	try {
		AssertEqual(0, _SR_LegacyClaimRequestTerminate(state),
			"requestTerminate has no PID before start")
		AssertTrue(state["TerminationRequested"],
			"requestTerminate before start must persist its refusal token")
		AssertEqual(SR_LEGACY_START_REFUSED, _SR_LegacyBeginStart(state),
			"requestTerminate before start must keep its established start-refusal contract")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: requestTerminate before start refuses later start (shellrunner-legacy-request-prestart)",
	_SRLSM_RequestTerminateBeforeStartRefusesStart)

_SRLSM_PublicHandleSurfaceIsComplete() {
	local handle := ShellRunner_Spawn(A_ComSpec, ["/c", "exit /b 0"], (*) => 0)
	for method_name in [
		"start",
		"terminate",
		"processId",
		"detach",
		"requestTerminate",
		"terminateAsync"
	] {
		AssertTrue(HasMethod(handle, method_name),
			"ShellRunner_Spawn must publish public method " . method_name)
	}
	AssertTrue(handle.terminateAsync(),
		"the public terminateAsync binding must accept a READY handle without launching a kill")
	AssertEqual(0, handle.processId(),
		"terminateAsync on a READY handle must not manufacture a process identity")
	; Keep this construction-only test free of process side effects.
	handle.terminate()
}
Test("shell_runner legacy: real handle publishes complete lifecycle surface (shellrunner-legacy-handle-surface)",
	_SRLSM_PublicHandleSurfaceIsComplete)





; ===========================================
; ===========================================
; ======= 3/ Run Publication Window =========
; ===========================================
; ===========================================

_SRLSM_TerminateWhileRunPumpsCancelsPublication() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"the launch must be in STARTING while Run owns no public PID")
		AssertEqual(0, _SR_LegacyClaimTerminate(state),
			"terminate during Run cannot yet own a process claim")
		AssertTrue(state["CancelLaunch"],
			"terminate during Run must persist cancellation until Run returns")

		local publication := _SR_LegacyPublishStart(state, 424242)
		AssertFalse(publication["Published"],
			"a launch cancelled while Run pumped messages must never enter the active registry")
		AssertTrue(IsObject(publication["Claim"]),
			"the returning Run owner must receive the private PID cleanup claim")
		AssertEqual(424242, publication["Claim"]["Pid"],
			"the cleanup claim must own the PID Run returned")
		AssertFalse(_SR_ActiveTasks.Has(state["TaskId"]),
			"a cancelled launch must be retired without publication")
		AssertEqual(0, publication["Claim"]["CallbackToken"]["Callback"],
			"a launch cancelled before publication must never retain OnDone")
		AssertEqual(0, callback_calls,
			"cancelling the private launch must not invoke completion")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminate during Run cancels unpublished PID (shellrunner-legacy-run-pump)",
	_SRLSM_TerminateWhileRunPumpsCancelsPublication)

_SRLSM_AsyncTerminateWhileRunPumpsPublishesDetached() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		local outcome := _SR_LegacyClaimAsyncTerminate(state)
		AssertTrue(outcome["Accepted"],
			"terminateAsync during Run must accept logical cancellation")
		AssertEqual(0, outcome["Pid"],
			"terminateAsync cannot expose a PID before Run returns")
		AssertFalse(state["CancelLaunch"],
			"async cancellation must not enter synchronous private-claim cleanup")
		AssertTrue(state["AsyncTerminationRequested"],
			"the returning start stack must observe the async cancellation token")
		local publication := _SR_LegacyPublishStart(state, 434343)
		AssertTrue(publication["Published"],
			"async cancellation must leave a detached poller owner for cleanup")
		AssertTrue(publication["RequestKill"],
			"the resumed start stack must launch only the asynchronous tree kill")
		AssertTrue(publication["StartCanceled"],
			"start must report the Run-pump cancellation to its caller")
		AssertEqual(0, publication["Claim"],
			"async cancellation must never manufacture a synchronous teardown claim")
		AssertEqual(ObjPtr(state), ObjPtr(_SR_ActiveTasks[state["TaskId"]]),
			"the exact detached state must remain poller-owned")
		AssertEqual(0, state["CallbackToken"]["Callback"],
			"async cancellation must retire callback ownership before publication")
		local completion := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(completion),
			"the poller must be able to reap the detached async cancellation")
		AssertTrue(_SR_LegacyFinishCompletion(completion, 1),
			"detached async cleanup must finalize without a callback")
		AssertEqual(0, callback_calls,
			"async-cancelled completion must stay callback-free")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminateAsync during Run publishes detached cleanup (shellrunner-legacy-async-run-pump)",
	_SRLSM_AsyncTerminateWhileRunPumpsPublishesDetached)

_SRLSM_DetachBeforePublicationIsRemembered() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		AssertTrue(_SR_LegacyClaimDetach(state),
			"detach before start must be accepted")
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"detach must not cancel the launch")
		local publication := _SR_LegacyPublishStart(state, 515151)
		AssertTrue(publication["Published"],
			"a detached handle must still publish and run")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(claim),
			"the poller must still reap a detached process")
		AssertEqual(0, claim["CallbackToken"]["Callback"],
			"detach before publication must remain visible to completion")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"detached completion must still cleanly finalize")
		AssertEqual(0, callback_calls,
			"detached completion must never invoke OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: detach before publication suppresses completion (shellrunner-legacy-detach-prepublish)",
	_SRLSM_DetachBeforePublicationIsRemembered)

_SRLSM_DetachWhileRunPumpsIsRemembered() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"precondition: Run must own the STARTING state")
		AssertTrue(_SR_LegacyClaimDetach(state),
			"detach while Run pumps must be accepted")
		local publication := _SR_LegacyPublishStart(state, 515152)
		AssertTrue(publication["Published"],
			"detach must not cancel the returning launch")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"the detached STARTING task must remain reapable")
		AssertEqual(0, callback_calls,
			"detach during Run must suppress the later completion callback")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: detach during Run survives publication (shellrunner-legacy-detach-run-pump)",
	_SRLSM_DetachWhileRunPumpsIsRemembered)

_SRLSM_RequestTerminateDuringRunKeepsCompletionOwner() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"the launch must already be in STARTING")
		AssertEqual(0, _SR_LegacyClaimRequestTerminate(state),
			"requestTerminate cannot return a PID until Run finishes")
		local publication := _SR_LegacyPublishStart(state, 525252)
		AssertTrue(publication["Published"],
			"requestTerminate during Run must retain completion ownership")
		AssertTrue(publication["RequestKill"],
			"publication must hand the deferred tree-kill request back to start")
		AssertTrue(IsObject(state["CallbackToken"]["Callback"]),
			"the poller must retain OnDone when requestTerminate races publication")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(claim),
			"a request-terminated task must remain reapable")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"completion must finalize the retained callback")
		AssertEqual(1, callback_calls,
			"requestTerminate must preserve exactly one completion callback")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: requestTerminate during Run keeps completion owner (shellrunner-legacy-request-run-pump)",
	_SRLSM_RequestTerminateDuringRunKeepsCompletionOwner)





; =======================================
; =======================================
; ======= 4/ Live Handle Branches =======
; =======================================
; =======================================

_SRLSM_LiveProcessIdAndRequestTerminate() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		AssertTrue(_SR_LegacyPublishStart(state, 605001)["Published"],
			"precondition: task must be live")
		AssertEqual(605001, _SR_LegacyProcessId(state),
			"processId must expose the exact live wrapper PID")
		AssertEqual(605001, _SR_LegacyClaimRequestTerminate(state),
			"requestTerminate must return the exact live wrapper PID")
		AssertTrue(state["TerminationRequested"],
			"requestTerminate must persist its live kill request")
		AssertTrue(IsObject(state["CallbackToken"]["Callback"]),
			"requestTerminate must retain completion callback ownership")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"a request-terminated task must remain completion-owned")
		AssertEqual(1, callback_calls,
			"requestTerminate must preserve exactly one completion callback")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: live processId/requestTerminate preserve completion (shellrunner-legacy-live-request)",
	_SRLSM_LiveProcessIdAndRequestTerminate)

_SRLSM_LiveDetachKeepsPollerOwner() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 605002)
		AssertTrue(_SR_LegacyClaimDetach(state),
			"detach must accept the exact live task")
		AssertEqual(ObjPtr(state), ObjPtr(_SR_ActiveTasks[state["TaskId"]]),
			"detach must retain the live state for poller cleanup")
		AssertEqual(0, state["CallbackToken"]["Callback"],
			"detach must revoke the live callback token")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"a detached live task must remain reapable")
		AssertEqual(0, callback_calls,
			"detached completion must not invoke OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: live detach keeps exact poller owner (shellrunner-legacy-live-detach)",
	_SRLSM_LiveDetachKeepsPollerOwner)

_SRLSM_LiveAsyncTerminateKeepsPollerOwner() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 605003)
		local outcome := _SR_LegacyClaimAsyncTerminate(state)
		AssertTrue(outcome["Accepted"],
			"terminateAsync must accept the exact live task")
		AssertEqual(605003, outcome["Pid"],
			"terminateAsync must return the exact live PID to its bounded launcher")
		AssertEqual(ObjPtr(state), ObjPtr(_SR_ActiveTasks[state["TaskId"]]),
			"terminateAsync must retain the task for poller cleanup")
		AssertEqual(0, state["CallbackToken"]["Callback"],
			"terminateAsync must revoke completion before launching taskkill")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(_SR_LegacyFinishCompletion(claim, 1),
			"async-terminated live work must remain reapable")
		AssertEqual(0, callback_calls,
			"async-terminated completion must not invoke OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: live terminateAsync keeps exact poller owner (shellrunner-legacy-live-async)",
	_SRLSM_LiveAsyncTerminateKeepsPollerOwner)





; ======================================
; ======================================
; ======= 5/ Exact Winner Claims =======
; ======================================
; ======================================

_SRLSM_StaleIdentityCannotTouchSuccessor() {
	global _SRLSM_NEXT_TASK_ID
	local task_id := ++_SRLSM_NEXT_TASK_ID
	local stale_calls := 0
	local live_calls := 0
	local stale := _SR_LegacyNewState(task_id,
		A_Temp . "\ergopti_sr_stale_" . task_id . ".tmp",
		(*) => (stale_calls += 1))
	local live := _SR_LegacyNewState(task_id,
		A_Temp . "\ergopti_sr_live_" . task_id . ".tmp",
		(*) => (live_calls += 1))
	try {
		stale["Phase"] := SR_LEGACY_PHASE_RUNNING
		stale["Pid"] := 610001
		live["Phase"] := SR_LEGACY_PHASE_RUNNING
		live["Pid"] := 610002
		local previous_critical := Critical("On")
		try _SR_ActiveTasks[task_id] := live
		finally Critical(previous_critical)

		AssertEqual(0, _SR_LegacyClaimCompletion(task_id, stale),
			"a stale snapshot must not claim a successor sharing its task ID")
		AssertFalse(_SR_LegacyClaimDetach(stale),
			"a stale detach must not clear the successor callback")
		AssertEqual(0, _SR_LegacyClaimTerminate(stale),
			"a stale terminate must not delete the successor")
		AssertEqual(0, _SR_LegacyClaimRequestTerminate(stale),
			"a stale requestTerminate must not target the successor PID")
		local stale_async := _SR_LegacyClaimAsyncTerminate(stale)
		AssertFalse(stale_async["Accepted"],
			"a stale terminateAsync must not be accepted")
		AssertEqual(0, stale_async["Pid"],
			"a stale terminateAsync must not target the successor PID")
		AssertEqual(0, _SR_LegacyProcessId(stale),
			"a stale processId lookup must not expose its retired PID")
		AssertEqual(0, _SR_LegacyFailStart(stale, 610001),
			"a stale start-failure path must not claim a live successor")
		AssertEqual(ObjPtr(live), ObjPtr(_SR_ActiveTasks[task_id]),
			"all stale operations must leave the exact successor registered")
		AssertTrue(IsObject(live["CallbackToken"]["Callback"]),
			"the successor callback must remain owned by the successor")
		AssertFalse(live["TerminationRequested"],
			"stale termination requests must not mutate the successor")
		AssertEqual(0, stale_calls,
			"the stale callback must not run")
		AssertEqual(0, live_calls,
			"the live callback must not run during stale operations")
	} finally {
		_SRLSM_DropState(stale)
		_SRLSM_DropState(live)
	}
}
Test("shell_runner legacy: stale ObjPtr cannot retire successor (shellrunner-legacy-exact-identity)",
	_SRLSM_StaleIdentityCannotTouchSuccessor)

_SRLSM_TerminateWinnerSuppressesCompletion() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		AssertTrue(_SR_LegacyPublishStart(state, 620001)["Published"],
			"precondition: task must be live")
		local snapshot := state
		local terminate_claim := _SR_LegacyClaimTerminate(state)
		AssertTrue(IsObject(terminate_claim),
			"terminate must win one terminal claim")
		AssertEqual(0, _SR_LegacyClaimCompletion(state["TaskId"], snapshot),
			"completion must lose after terminate removed exact ownership")
		AssertEqual(0, callback_calls,
			"the losing completion path must not invoke OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminate winner suppresses poll callback (shellrunner-legacy-terminate-wins)",
	_SRLSM_TerminateWinnerSuppressesCompletion)

_SRLSM_FailedPublishedStartRetiresExactTask() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		AssertTrue(_SR_LegacyPublishStart(state, 625001)["Published"],
			"precondition: Run returned and publication won")
		local claim := _SR_LegacyFailStart(state, 625001)
		AssertTrue(IsObject(claim),
			"a poller-arm failure after publication must own one cleanup claim")
		AssertFalse(_SR_ActiveTasks.Has(state["TaskId"]),
			"start failure must retire the exact published task")
		AssertEqual(0, claim["CallbackToken"]["Callback"],
			"start failure must suppress a completion callback")
		AssertEqual(0, _SR_LegacyClaimCompletion(state["TaskId"], state),
			"the stale poll snapshot must lose after start failure")
		AssertEqual(SR_LEGACY_START_ALREADY_ACTIVE, _SR_LegacyBeginStart(state),
			"start remains idempotent after its first launch attempt")
		AssertEqual(0, callback_calls,
			"start-failure ownership must not invoke OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: published start failure retires exact task (shellrunner-legacy-start-failure)",
	_SRLSM_FailedPublishedStartRetiresExactTask)

_SRLSM_FailedStartingLaunchOwnsPrivatePid() {
	local state := _SRLSM_NewState((*) => 0)
	try {
		AssertEqual(SR_LEGACY_START_BEGUN, _SR_LegacyBeginStart(state),
			"precondition: launch must be STARTING")
		local claim := _SR_LegacyFailStart(state, 625002)
		AssertTrue(IsObject(claim),
			"a Run failure after receiving a PID must own private cleanup")
		AssertEqual(625002, claim["Pid"],
			"the start failure claim must retain the private PID")
		AssertEqual("start_failed", claim["Owner"],
			"the failure claim must name its terminal owner")
		AssertEqual(0, claim["CallbackToken"]["Callback"],
			"a failed STARTING launch must never retain OnDone")
		AssertFalse(_SR_ActiveTasks.Has(state["TaskId"]),
			"a failed private launch must never enter the registry")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: STARTING failure owns private PID (shellrunner-legacy-starting-failure)",
	_SRLSM_FailedStartingLaunchOwnsPrivatePid)

_SRLSM_PublicationCollisionPreservesLiveOwner() {
	global _SRLSM_NEXT_TASK_ID
	local task_id := ++_SRLSM_NEXT_TASK_ID
	local live := _SR_LegacyNewState(task_id,
		A_Temp . "\ergopti_sr_collision_live_" . task_id . ".tmp", (*) => 0)
	local candidate := _SR_LegacyNewState(task_id,
		A_Temp . "\ergopti_sr_collision_candidate_" . task_id . ".tmp", (*) => 0)
	try {
		_SR_LegacyBeginStart(live)
		AssertTrue(_SR_LegacyPublishStart(live, 625003)["Published"],
			"precondition: exact live owner must already be published")
		_SR_LegacyBeginStart(candidate)
		local collision := _SR_LegacyPublishStart(candidate, 625004)
		AssertFalse(collision["Published"],
			"a duplicate task ID must never replace the live state")
		AssertEqual("identity_collision", collision["Claim"]["Owner"],
			"the rejected PID must become an explicit collision claim")
		AssertEqual(625004, collision["Claim"]["Pid"],
			"the collision claim must retain only the rejected private PID")
		AssertEqual(ObjPtr(live), ObjPtr(_SR_ActiveTasks[task_id]),
			"the exact live owner must survive the collision")
		AssertTrue(IsObject(live["CallbackToken"]["Callback"]),
			"the collision must not detach the live owner's callback")
	} finally {
		_SRLSM_DropState(candidate)
		_SRLSM_DropState(live)
	}
}
Test("shell_runner legacy: publication collision preserves live owner (shellrunner-legacy-publish-collision)",
	_SRLSM_PublicationCollisionPreservesLiveOwner)

_SRLSM_DetachRevokesClaimedCompletionBeforeDispatch() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 625005)
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(claim),
			"precondition: completion must own the terminal claim")
		AssertTrue(_SR_LegacyClaimDetach(state),
			"detach must revoke a claimed callback before dispatch begins")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"revoked completion must still finalize output cleanup")
		AssertEqual(0, callback_calls,
			"a callback revoked after completion claim must not fire")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: detach revokes claimed completion before dispatch (shellrunner-legacy-revoke-claim)",
	_SRLSM_DetachRevokesClaimedCompletionBeforeDispatch)

_SRLSM_TerminateRevokesClaimedCompletionBeforeDispatch() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 625008)
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(claim),
			"precondition: completion must own the terminal claim")
		AssertEqual(0, _SR_LegacyClaimTerminate(state),
			"terminate after completion claim has no process claim left to return")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"terminate-revoked completion must still finalize output cleanup")
		AssertEqual(0, callback_calls,
			"terminate after completion claim must suppress OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminate revokes claimed completion before dispatch (shellrunner-legacy-terminate-revoke-claim)",
	_SRLSM_TerminateRevokesClaimedCompletionBeforeDispatch)

_SRLSM_AsyncTerminateRevokesClaimedCompletion() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 625007)
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		local outcome := _SR_LegacyClaimAsyncTerminate(state)
		AssertTrue(outcome["Accepted"],
			"terminateAsync must revoke a terminal callback not yet dispatched")
		AssertEqual(0, outcome["Pid"],
			"a completion-owned terminal task must expose no killable PID")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"revoked terminal completion must still finalize output cleanup")
		AssertEqual(0, callback_calls,
			"terminateAsync after completion claim must suppress OnDone")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: terminateAsync revokes claimed completion (shellrunner-legacy-async-revoke-claim)",
	_SRLSM_AsyncTerminateRevokesClaimedCompletion)

_SRLSM_DetachLosesAfterDispatchClaim() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		_SR_LegacyPublishStart(state, 625006)
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(_SR_LegacyBeginFinalize(claim),
			"precondition: completion must own one-shot finalization")
		local callback := 0
		AssertTrue(_SR_LegacyClaimCallback(claim, &callback),
			"completion must claim its live callback immediately before dispatch")
		AssertFalse(_SR_LegacyClaimDetach(state),
			"detach must report false once callback dispatch has linearized")
		callback.Call(0, "", "")
		AssertEqual(1, callback_calls,
			"the one dispatch winner must retain exactly one callback")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: detach loses explicitly after dispatch claim (shellrunner-legacy-dispatch-wins)",
	_SRLSM_DetachLosesAfterDispatchClaim)

_SRLSM_CompletionCallbackIsAtMostOnce() {
	local callback_calls := 0
	local state := _SRLSM_NewState((*) => (callback_calls += 1))
	try {
		_SR_LegacyBeginStart(state)
		AssertTrue(_SR_LegacyPublishStart(state, 630001)["Published"],
			"precondition: task must be live")
		local claim := _SR_LegacyClaimCompletion(state["TaskId"], state)
		AssertTrue(IsObject(claim),
			"completion must win the live task")
		AssertEqual(0, _SR_LegacyClaimCompletion(state["TaskId"], state),
			"the registry must offer no second completion claim")
		AssertTrue(_SR_LegacyFinishCompletion(claim, 0),
			"the first finalizer must own the callback")
		AssertFalse(_SR_LegacyFinishCompletion(claim, 0),
			"the same claim cannot be finalized twice")
		AssertEqual(1, callback_calls,
			"OnDone must be invoked at most once")
	} finally {
		_SRLSM_DropState(state)
	}
}
Test("shell_runner legacy: completion callback is at most once (shellrunner-legacy-callback-once)",
	_SRLSM_CompletionCallbackIsAtMostOnce)
