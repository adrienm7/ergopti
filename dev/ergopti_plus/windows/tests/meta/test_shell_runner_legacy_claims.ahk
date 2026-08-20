; static/ergopti_plus/windows/tests/meta/test_shell_runner_legacy_claims.ahk

; ==============================================================================
; MODULE: Legacy ShellRunner Claim-Protocol Guard
; DESCRIPTION:
; Guards the complete legacy ShellRunner_Spawn lifecycle class against
; Has-to-Delete, private-PID publication, stale identity, and double-callback
; regressions. Behavioral tests drive the transitions; this source guard makes
; every future registry delete join the same exact-claim protocol automatically.
;
; FEATURES & RATIONALE:
; 1. Every lifecycle transition which touches shared state owns Critical.
; 2. Every registry delete is inside an ObjPtr-checked claim helper.
; 3. Polling claims before exit lookup, file I/O, cleanup, or callback dispatch.
; 4. start, terminate, detach, and async termination delegate to the state map.
; 5. Claim finalization is taken before the first yielding operation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Source Utilities =======
; ===================================
; ===================================

_SRLC_Count(Haystack, Needle) {
	local count := 0
	local pos := 1
	while (pos := InStr(Haystack, Needle, true, pos)) {
		count += 1
		pos += StrLen(Needle)
	}
	return count
}

_SRLC_CountRegex(Haystack, Pattern) {
	local count := 0
	local pos := 1
	local match := 0
	while RegExMatch(Haystack, Pattern, &match, pos) {
		count += 1
		pos := match.Pos + match.Len
	}
	return count
}





; ===============================================
; ===============================================
; ======= 2/ Atomic Exact-Identity Claims =======
; ===============================================
; ===============================================

_SRLC_EverySharedTransitionOwnsCritical() {
	local transition_names := [
		"ShellRunner_Spawn",
		"_SR_LegacyBeginStart",
		"_SR_LegacyPublishStart",
		"_SR_LegacyFailStart",
		"_SR_LegacyClaimTerminate",
		"_SR_LegacyClaimCompletion",
		"_SR_LegacyClaimDetach",
		"_SR_LegacyClaimRequestTerminate",
		"_SR_LegacyClaimAsyncTerminate",
		"_SR_LegacyProcessId",
		"_SR_LegacyBeginFinalize",
		"_SR_LegacyClaimCallback",
		"_SR_EnsurePoller",
		"_SR_Poll"
	]
	local expected := Map()
	for name in transition_names {
		expected[name] := true
	}
	local non_transition_names := [
		"_SR_LegacyNewState",
		"_SR_LegacyRegistryOwnsLocked",
		"_SR_LegacyBuildClaimLocked",
		"_SR_LegacyDetachCallbackLocked",
		"_SR_LegacyRequestTreeKill",
		"_SR_LegacyTerminateClaim",
		"_SR_LegacyFinishCompletion"
	]
	local non_transitions := Map()
	for name in non_transition_names
		non_transitions[name] := true

	; Derive the complete legacy inventory from production definitions. Every new
	; helper must be classified explicitly as either a Critical-owning transition
	; or one of the private construction/locked/finalization helpers above.
	local source := _DriverSourceNoComments()
	local mutable_globals := Map()
	local global_pos := 1
	local global_match := 0
	while RegExMatch(source,
			"m)^[ \t]*global[ \t]+(_SR_[A-Za-z0-9_]+)[ \t]*:=",
			&global_match, global_pos) {
		mutable_globals[global_match[1]] := true
		global_pos := global_match.Pos + global_match.Len
	}
	Assert(mutable_globals.Count > 0,
		"the Critical audit must derive at least one mutable _SR_* global")
	local discovered := Map()
	local pattern := "m)^(ShellRunner_Spawn|_SR_EnsurePoller|_SR_Poll|_SR_Legacy[A-Za-z0-9_]*)\([^`r`n]*\)\s*\{"
	local pos := 1
	local match := 0
	while RegExMatch(source, pattern, &match, pos) {
		discovered[match[1]] := true
		pos := match.Pos + match.Len
	}
	AssertEqual(expected.Count + non_transitions.Count, discovered.Count,
		"the lifecycle audit inventory must classify every production legacy helper definition")
	for name, _ in discovered
		AssertTrue(expected.Has(name) || non_transitions.Has(name),
			"new legacy helper must be classified by the lifecycle audit: " . name)
	for name, _ in expected
		AssertTrue(discovered.Has(name),
			"Critical-owning lifecycle helper disappeared from production: " . name)
	for name, _ in non_transitions
		AssertTrue(discovered.Has(name),
			"classified non-transition lifecycle helper disappeared from production: " . name)

	for name, _ in expected {
		local raw_body := _StripFullLineComments(_DriverFuncBody(name))
		AssertEqual(0, RegExMatch(raw_body,
			"m)^[ \t]*global[^\r\n]*:="),
			name . " must not initialize or reset a global on its declaration line")
		local body := RegExReplace(raw_body,
			"m)^[ \t]*global[^\r\n]*(?:\R|$)")
		Assert(body != "", name . " must exist for the Critical class audit")
		local critical_pos := InStr(body, 'Critical("On")', true)
		Assert(critical_pos > 0,
			name . " must acquire Critical before reading or mutating legacy lifecycle state")
		local try_pos := InStr(body, "try", true, critical_pos)
		Assert(try_pos > critical_pos,
			name . " must begin a guarded try after acquiring Critical")
		local finally_pos := InStr(body, "finally", true, try_pos)
		Assert(finally_pos > try_pos,
			name . " must restore Critical through a finally path")
		local restore_pos := InStr(body, "Critical(previous_critical)", true,
			finally_pos)
		Assert(restore_pos > finally_pos,
			name . " must keep shared work inside try/finally and restore Critical only afterward")

		local shared_match := 0
		local shared_pos := RegExMatch(body,
			"\b(?:State|SnapshotState|Claim)\s*(?:\[|\.)",
			&shared_match)
		for global_name, _ in mutable_globals {
			local candidate_pos := InStr(body, global_name, true)
			if candidate_pos > 0 && (shared_pos = 0 || candidate_pos < shared_pos)
				shared_pos := candidate_pos
		}
		Assert(shared_pos > critical_pos && shared_pos < finally_pos,
			name . " must acquire Critical before its first shared read and retain it through the transaction")
	}
}
Test("shell_runner legacy: every shared transition owns Critical (shellrunner-legacy-critical-class)",
	_SRLC_EverySharedTransitionOwnsCritical)

_SRLC_LockedHelpersHaveOnlyAuditedOwners() {
	local source := _DriverSourceNoComments()
	local locked_owners := Map(
		"_SR_LegacyRegistryOwnsLocked", [
			"_SR_LegacyFailStart",
			"_SR_LegacyClaimTerminate",
			"_SR_LegacyClaimCompletion",
			"_SR_LegacyClaimDetach",
			"_SR_LegacyClaimRequestTerminate",
			"_SR_LegacyClaimAsyncTerminate",
			"_SR_LegacyProcessId"
		],
		"_SR_LegacyBuildClaimLocked", [
			"_SR_LegacyPublishStart",
			"_SR_LegacyFailStart",
			"_SR_LegacyClaimTerminate",
			"_SR_LegacyClaimCompletion"
		],
		"_SR_LegacyDetachCallbackLocked", [
			"_SR_LegacyBuildClaimLocked",
			"_SR_LegacyClaimTerminate",
			"_SR_LegacyClaimDetach",
			"_SR_LegacyClaimAsyncTerminate"
		])
	for helper_name, owners in locked_owners {
		local token := helper_name . "("
		local source_calls := _SRLC_Count(source, token) - 1
		Assert(source_calls > 0,
			helper_name . " must have at least one production caller")
		local audited_calls := 0
		for owner_name in owners {
			local owner_body := _StripFullLineComments(_DriverFuncBody(owner_name))
			Assert(owner_body != "", owner_name . " must exist as a locked-helper owner")
			local owner_calls := _SRLC_Count(owner_body, token)
			Assert(owner_calls > 0,
				owner_name . " must remain a real owner of " . helper_name)
			audited_calls += owner_calls
		}
		AssertEqual(source_calls, audited_calls,
			"every call to " . helper_name . " must remain inside an enumerated Critical owner")
	}
}
Test("shell_runner legacy: locked helpers have only audited Critical owners (shellrunner-legacy-locked-callers)",
	_SRLC_LockedHelpersHaveOnlyAuditedOwners)

_SRLC_EveryRegistryDeleteUsesExactIdentity() {
	local source := _DriverSourceNoComments()
	local delete_token := "_SR_ActiveTasks.Delete("
	local delete_owners := [
		"_SR_LegacyFailStart",
		"_SR_LegacyClaimTerminate",
		"_SR_LegacyClaimCompletion"
	]
	local guarded_deletes := 0
	for name in delete_owners {
		local body := _DriverFuncBody(name)
		local delete_count := _SRLC_Count(body, delete_token)
		Assert(delete_count > 0,
			name . " must remain a real registry-delete owner so the class scan cannot pass vacuously")
		Assert(InStr(body, "_SR_LegacyRegistryOwnsLocked", true) > 0,
			name . " must verify exact live identity before deleting a task")
		guarded_deletes += delete_count
	}
	AssertEqual(guarded_deletes, _SRLC_Count(source, delete_token),
		"every legacy registry delete in the full driver tree must live in an enumerated exact-identity owner")
	AssertEqual(1, _SRLC_CountRegex(source,
		"_SR_ActiveTasks\[[^\r\n]+\]\s*:="),
		"the full driver tree must have exactly one legacy task publisher")
	local publish_body := _DriverFuncBody("_SR_LegacyPublishStart")
	Assert(InStr(publish_body, "_SR_ActiveTasks[task_id] := State", true) > 0,
		"the sole legacy registry publisher must be the atomic publication helper")

	local identity_body := _DriverFuncBody("_SR_LegacyRegistryOwnsLocked")
	Assert(InStr(identity_body, "ObjPtr(current) = ObjPtr(State)", true) > 0,
		"exact ownership must compare the live registry object with the claimant by ObjPtr")
	Assert(InStr(identity_body, 'current.Get("Identity", 0) = State["Identity"]', true) > 0,
		"the immutable identity token must agree with the exact object comparison")
}
Test("shell_runner legacy: every registry delete uses exact ObjPtr identity (shellrunner-legacy-delete-class)",
	_SRLC_EveryRegistryDeleteUsesExactIdentity)





; ==========================================
; ==========================================
; ======= 3/ Winner-Before-I/O Order =======
; ==========================================
; ==========================================

_SRLC_PollClaimsBeforeYieldingWork() {
	local body := _DriverFuncBody("_SR_Poll")
	local claim_pos := InStr(body, "_SR_LegacyClaimCompletion(", true)
	local exit_pos := InStr(body, "_SR_GetExitCode(", true)
	local finish_pos := InStr(body, "_SR_LegacyFinishCompletion(", true)
	Assert(claim_pos > 0,
		"_SR_Poll must claim the exact task before completing it")
	Assert(exit_pos > claim_pos,
		"exit-code lookup must happen only after the exact completion claim")
	Assert(finish_pos > exit_pos,
		"file capture, cleanup, and callback dispatch must happen after the claim and exit lookup")
	AssertEqual(0, InStr(body, "FileRead(", true),
		"_SR_Poll must not perform file I/O directly before a claim helper can win")
	AssertEqual(0, InStr(body, "FileDelete(", true),
		"_SR_Poll must not perform cleanup directly before a claim helper can win")
	AssertEqual(0, InStr(body, '["OnDone"].Call(', true),
		"_SR_Poll must never retain a direct callback route around the claim finalizer")
}
Test("shell_runner legacy: poll claims before I/O and callback (shellrunner-legacy-claim-before-io)",
	_SRLC_PollClaimsBeforeYieldingWork)

_SRLC_FinalizersTakeClaimBeforeYielding() {
	local completion := Trim(_StripFullLineComments(
		_DriverFuncBody("_SR_LegacyFinishCompletion")), " `t`r`n")
	local completion_statements := Trim(SubStr(completion,
		InStr(completion, "{") + 1), " `t`r`n")
	AssertEqual(1, RegExMatch(completion_statements,
		"^if !_SR_LegacyBeginFinalize\(Claim\)\R[ \t]+return false"),
		"completion must begin with the finalization claim before any other statement")
	local completion_claim := InStr(completion, "_SR_LegacyBeginFinalize(", true)
	Assert(completion_claim > 0,
		"completion must take the one-shot finalization claim")
	for token in ["FileExist(", "FileRead(", "FileDelete(", ".Call("] {
		local pos := InStr(completion, token, true)
		Assert(pos > completion_claim,
			"completion token " . token . " must appear only after the finalization claim")
	}
	local callback_claim := InStr(completion, "_SR_LegacyClaimCallback(", true)
	local file_delete := InStr(completion, "FileDelete(", true)
	local callback_call := InStr(completion, ".Call(", true)
	Assert(callback_claim > file_delete && callback_call > callback_claim,
		"callback ownership must remain revocable through completion I/O and become claimed immediately before dispatch")

	local termination := Trim(_StripFullLineComments(
		_DriverFuncBody("_SR_LegacyTerminateClaim")), " `t`r`n")
	local termination_statements := Trim(SubStr(termination,
		InStr(termination, "{") + 1), " `t`r`n")
	AssertEqual(1, RegExMatch(termination_statements,
		"^if !_SR_LegacyBeginFinalize\(Claim\)\R[ \t]+return false"),
		"termination must begin with the finalization claim before any other statement")
	local termination_claim := InStr(termination, "_SR_LegacyBeginFinalize(", true)
	Assert(termination_claim > 0,
		"termination must take the one-shot finalization claim")
	for token in ["Run(", "ProcessClose(", "FileExist(", "FileDelete("] {
		local pos := InStr(termination, token, true)
		Assert(pos > termination_claim,
			"termination token " . token . " must appear only after the finalization claim")
	}
}
Test("shell_runner legacy: finalizers claim before yielding operations (shellrunner-legacy-finalize-order)",
	_SRLC_FinalizersTakeClaimBeforeYielding)

_SRLC_AsyncTerminationCallGraphIsBounded() {
	local expected_graph := Map(
		"_SR_HandleTerminateAsync", Map(
			"_SR_LegacyClaimAsyncTerminate", 1,
			"_SR_LegacyRequestTreeKill", 1),
		"_SR_LegacyClaimAsyncTerminate", Map(
			"_SR_LegacyRegistryOwnsLocked", 1,
			"_SR_LegacyDetachCallbackLocked", 3),
		"_SR_LegacyDetachCallbackLocked", Map(),
		"_SR_LegacyRequestTreeKill", Map(
			"_SR_DeferLogError", 1),
		"_SR_DeferLogError", Map())
	local graph_source := ""
	for function_name, expected_calls in expected_graph {
		local function_body := _StripFullLineComments(_DriverFuncBody(function_name))
		Assert(function_body != "", function_name . " must exist in the bounded async graph")
		local function_statements := SubStr(function_body,
			InStr(function_body, "{") + 1)
		graph_source .= "`n" . function_statements
		local actual_calls := Map()
		local pos := 1
		local match := 0
		while RegExMatch(function_statements, "(_SR_[A-Za-z0-9_]+)\(", &match, pos) {
			actual_calls[match[1]] := actual_calls.Get(match[1], 0) + 1
			pos := match.Pos + match.Len
		}
		AssertEqual(expected_calls.Count, actual_calls.Count,
			function_name . " changed its internal call graph; classify every new edge before trusting async boundedness")
		for called_name, call_count in actual_calls {
			AssertTrue(expected_calls.Has(called_name),
				function_name . " reaches an unclassified async helper: " . called_name)
			AssertEqual(expected_calls[called_name], call_count,
				function_name . " has the wrong call count for " . called_name)
		}
	}
	for forbidden in [
		"ProcessClose(",
		"ProcessWait(",
		"ProcessWaitClose(",
		"RunWait(",
		"Sleep(",
		"KeyWait(",
		"WinWait",
		"WaitForResponse(",
		"WaitForSingleObject",
		"MsgWaitForMultipleObjects",
		"WaitForInputIdle",
		"DllCall(",
		"ComCall(",
		"_LoggerFlush("
	] {
		AssertEqual(0, InStr(graph_source, forbidden, true),
			"the complete terminateAsync helper closure must stay non-blocking: " . forbidden)
	}
	local forbidden_families := Map(
		"\b(?:File|Dir|Reg)[A-Za-z0-9_]*\s*\(", "filesystem or registry I/O",
		"\b[A-Za-z0-9_]*Wait[A-Za-z0-9_]*\s*\(", "wait call")
	for forbidden_pattern, forbidden_label in forbidden_families
		AssertEqual(0, RegExMatch(graph_source, forbidden_pattern),
			"the complete terminateAsync helper closure must contain no " . forbidden_label)
	AssertEqual(0, InStr(graph_source, "_SR_LogError(", true),
		"the synchronous terminateAsync graph must not reach force-flushed error logging")
	local deferred_log := _StripFullLineComments(_DriverFuncBody("_SR_DeferLogError"))
	local timer_pos := InStr(deferred_log, "SetTimer(", true)
	local callback_pos := InStr(deferred_log, "_SR_LogError.Bind(", true)
	Assert(timer_pos > 0 && callback_pos > timer_pos,
		"force-flushed error logging must cross an explicit one-shot SetTimer boundary")
	AssertEqual(1, _SRLC_Count(deferred_log, "_SR_LogError.Bind("),
		"the deferred boundary must schedule exactly one central error-log callback")
	AssertEqual(1, _SRLC_Count(deferred_log, "SetTimer("),
		"the deferred boundary must arm exactly one timer")
	Assert(RegExMatch(deferred_log,
		"SetTimer\(\s*_SR_LogError\.Bind\(FormatString,\s*Args\*\),\s*-1\s*\)") > 0,
		"deferred error logging must use an exact one-shot negative timer period")
}
Test("shell_runner legacy: terminateAsync call graph is bounded transitively (shellrunner-legacy-async-graph)",
	_SRLC_AsyncTerminationCallGraphIsBounded)





; ===========================================
; ===========================================
; ======= 4/ Public Handle Delegation =======
; ===========================================
; ===========================================

_SRLC_PublicHandleUsesOneStateMap() {
	local body := _DriverFuncBody("ShellRunner_Spawn")
	local state_pos := InStr(body, "state := _SR_LegacyNewState(", true)
	local run_pos := InStr(body, "Run(cmd", true)
	local publish_pos := InStr(body, "_SR_LegacyPublishStart(state, spawned_pid)", true)
	local poll_pos := InStr(body, "_SR_EnsurePoller()", true)
	local deferred_kill_pos := InStr(body,
		'_SR_LegacyRequestTreeKill(spawned_pid)', true)
	Assert(state_pos > 0,
		"ShellRunner_Spawn must create one shared identity state map")
	Assert(run_pos > state_pos,
		"Run must execute only after the shared state exists for re-entrant callbacks")
	Assert(publish_pos > run_pos,
		"the PID returned from Run must cross the atomic publication gate")
	Assert(poll_pos > publish_pos,
		"the poller must arm only after publication succeeds")
	Assert(deferred_kill_pos > poll_pos,
		"requestTerminate during Run must publish before issuing its deferred tree kill")

	local handler_routes := Map(
		"_SR_HandleStart", Map(
			"_SR_LogError", 2,
			"_SR_LegacyBeginStart", 1,
			"_SR_LegacyPublishStart", 1,
			"_SR_LegacyFailStart", 1,
			"_SR_LegacyTerminateClaim", 2,
			"_SR_EnsurePoller", 1,
			"_SR_LegacyRequestTreeKill", 1),
		"_SR_HandleTerminate", Map(
			"_SR_LegacyClaimTerminate", 1,
			"_SR_LegacyTerminateClaim", 1),
		"_SR_HandleDetach", Map(
			"_SR_LegacyClaimDetach", 1),
		"_SR_HandleProcessId", Map(
			"_SR_LegacyProcessId", 1),
		"_SR_HandleRequestTerminate", Map(
			"_SR_LegacyClaimRequestTerminate", 1,
			"_SR_LegacyRequestTreeKill", 1),
		"_SR_HandleTerminateAsync", Map(
			"_SR_LegacyClaimAsyncTerminate", 1,
			"_SR_LegacyRequestTreeKill", 1))
	for handler_name, expected_routes in handler_routes {
		local handler_body := _StripFullLineComments(_DriverFuncBody(handler_name))
		Assert(handler_body != "", handler_name . " must exist for public route auditing")
		local handler_statements := SubStr(handler_body,
			InStr(handler_body, "{") + 1)
		local actual_routes := Map()
		local route_pos := 1
		local route_match := 0
		while RegExMatch(handler_statements,
				"(_SR_[A-Za-z0-9_]+)\(", &route_match, route_pos) {
			actual_routes[route_match[1]] := actual_routes.Get(route_match[1], 0) + 1
			route_pos := route_match.Pos + route_match.Len
		}
		AssertEqual(expected_routes.Count, actual_routes.Count,
			handler_name . " changed its direct call graph; classify every new route")
		for route_name, route_count in actual_routes {
			AssertTrue(expected_routes.Has(route_name),
				handler_name . " reaches an unclassified helper: " . route_name)
			AssertEqual(expected_routes[route_name], route_count,
				handler_name . " has the wrong route count for " . route_name)
		}
	}
	local public_wiring := Map(
		"start", "_SR_HandleStart",
		"terminate", "_SR_HandleTerminate",
		"processId", "_SR_HandleProcessId",
		"detach", "_SR_HandleDetach",
		"requestTerminate", "_SR_HandleRequestTerminate",
		"terminateAsync", "_SR_HandleTerminateAsync")
	for method_name, handler_name in public_wiring {
		local assignment_pattern := "handle\." . method_name
			. "\s*:=\s*" . handler_name
		AssertEqual(1, _SRLC_CountRegex(body, assignment_pattern),
			"the real handle must publish exactly one " . method_name
			. " binding to " . handler_name)
	}
	AssertEqual(0, InStr(body, "_SR_ActiveTasks[", true),
		"ShellRunner_Spawn must not bypass the state-machine helpers with a direct registry write")
	AssertEqual(0, InStr(body, "_SR_ActiveTasks.Delete(", true),
		"ShellRunner_Spawn must not bypass exact claims with a direct registry delete")
	local unpublished_pos := InStr(body, 'if !publication["Published"] {', true)
	local sync_cleanup_pos := InStr(body,
		"_SR_LegacyTerminateClaim(cancelled_claim, true)", true, unpublished_pos)
	local unpublished_return := InStr(body, "return false", true, sync_cleanup_pos)
	Assert(unpublished_pos > 0 && sync_cleanup_pos > unpublished_pos
		&& unpublished_return > sync_cleanup_pos && poll_pos > unpublished_return,
		"blocking private cleanup must stay confined to the unpublished branch; every published async cancellation must reach the poller path")
}
Test("shell_runner legacy: public handle delegates through one state map (shellrunner-legacy-public-delegation)",
	_SRLC_PublicHandleUsesOneStateMap)
