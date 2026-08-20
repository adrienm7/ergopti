; tests/meta/test_shell_runner_poll_suspend_guard.ahk

; ==============================================================================
; MODULE: ShellRunner Poll Suspend Guard Meta Test (Pattern 1, 1h)
; DESCRIPTION:
; Regression guard for the "native Suspend() never disarms a SetTimer
; callback" gap-class as it applies to ShellRunner's async completion poller.
; _SR_Poll is a periodic SetTimer that fires OnDone callbacks for completed
; async subprocesses; native Suspend() has no effect on it. Legacy keylogger
; and UIA workers still use this poller, so its suspend ordering is live.
;
; SCOPE: source introspection of adapters/shell_runner.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ _SR_Poll suspend guard ===============
; =================================================
; =================================================

_SRPSG_PollHasSuspendGuard() {
	Body := _DriverFuncBody("_SR_Poll")
	Assert(Body != "", "_SR_Poll must exist in adapters/shell_runner.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0,
		"_SR_Poll must check A_IsSuspended — this periodic SetTimer bypasses native Suspend() and would otherwise fire OnDone callbacks while the driver is paused")

	; The guard must precede the callback-firing loop, not the self-disarm
	; branch above it (that branch legitimately always runs, suspended or not,
	; so the queue can still be recognised as drained).
	DispatchPos := InStr(Body, "_SR_LegacyFinishCompletion(claim, exit_code)")
	Assert(DispatchPos > 0,
		"_SR_Poll must still hand claimed tasks to the callback/output finalizer")
	Assert(GuardPos < DispatchPos,
		"_SR_Poll: the A_IsSuspended guard must appear BEFORE the OnDone dispatch")
}
Test("shell_runner: _SR_Poll has A_IsSuspended guard before OnDone dispatch (suspend-guard-pattern-1)",
	_SRPSG_PollHasSuspendGuard)

_SRPSG_TreePollHasSuspendGuard() {
	Body := _DriverFuncBody("_SR_TreePoll")
	Assert(Body != "", "_SR_TreePoll must exist in adapters/shell_runner.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	DispatchPos := InStr(Body, "_SR_TreeFinishClaim(claim)")
	Assert(GuardPos > 0,
		"_SR_TreePoll must check A_IsSuspended — Job Object ownership does not disarm its SetTimer callback")
	Assert(DispatchPos > 0,
		"_SR_TreePoll must still hand completed tasks to the callback/output finalizer")
	Assert(GuardPos < DispatchPos,
		"_SR_TreePoll: the A_IsSuspended guard must appear BEFORE completion dispatch")
}
Test("shell_runner: _SR_TreePoll has A_IsSuspended guard before completion dispatch",
	_SRPSG_TreePollHasSuspendGuard)





; =========================================================
; =========================================================
; ======= 2/ Tree poller transition ownership =============
; =========================================================
; =========================================================

_SRPSG_Count(Haystack, Needle) {
	local count := 0
	local pos := 1
	while (pos := InStr(Haystack, Needle, true, pos)) {
		count += 1
		pos += StrLen(Needle)
	}
	return count
}

_SRPSG_CountRegex(Haystack, Pattern) {
	local count := 0
	local pos := 1
	local match := 0
	while RegExMatch(Haystack, Pattern, &match, pos) {
		count += 1
		pos := match.Pos + match.Len
	}
	return count
}

_SRPSG_FindAfter(Haystack, Needle, PreviousPos) {
	if PreviousPos <= 0
		return 0
	return InStr(Haystack, Needle, true, PreviousPos)
}

_SRPSG_TreePollerTransitionsAreCentralized() {
	local source := _DriverSourceNoComments()
	local helper_name := "_SR_TreeSetPollerRunningLocked"
	local helper_token := helper_name . "("
	local helper := _DriverFuncBody(helper_name)
	local ensure := _DriverFuncBody("_SR_TreeEnsurePoller")
	local poll := _DriverFuncBody("_SR_TreePoll")
	local start := _DriverFuncBody("_SR_TreeHandleStart")
	Assert(helper != "" && ensure != "" && poll != "" && start != "",
		"the complete tree-poller transition class must remain inspectable")

	local ensure_call := InStr(ensure, helper_name . "(true", true)
	local poll_call := InStr(poll, helper_name . "(false", true)
	Assert(ensure_call > InStr(ensure, 'Critical("On")', true)
		&& ensure_call < InStr(ensure, "finally", true),
		"arming must delegate to the locked helper inside Ensure's Critical transaction")
	Assert(poll_call > InStr(poll, "_SR_TreeOwnedTasks.Count = 0", true)
		&& poll_call < InStr(poll, "finally", true),
		"empty-queue disarm must delegate before Poll releases Critical")
	AssertEqual(0, _SRPSG_Count(ensure, "SetTimer("),
		"Ensure must not issue any direct or aliased timer arm outside the locked helper")
	AssertEqual(0, _SRPSG_Count(poll, "SetTimer("),
		"Poll must not issue any direct or aliased timer disarm outside the locked helper")
	AssertEqual(0, _SRPSG_Count(ensure, "_SR_TreePollRunning :="),
		"Ensure must not bypass the centralized timer/flag transition")
	AssertEqual(0, _SRPSG_Count(poll, "_SR_TreePollRunning :="),
		"Poll must not bypass the centralized timer/flag transition")

	local direct_calls := _SRPSG_Count(source, helper_token) - 1
	local audited_calls := _SRPSG_Count(ensure, helper_token)
		+ _SRPSG_Count(poll, helper_token)
	AssertEqual(2, direct_calls,
		"the locked poller helper must have exactly the arm and disarm owners")
	AssertEqual(direct_calls, audited_calls,
		"every locked poller-helper caller must remain in the two audited Critical owners")
	AssertEqual(2, _SRPSG_Count(helper, "SetTimer(_SR_TreePoll,"),
		"the helper must own exactly the real arm and disarm timer sites")
	AssertEqual(2, _SRPSG_Count(helper, "SetTimer("),
		"the locked helper must contain no unclassified timer operation")
	AssertEqual(_SRPSG_Count(helper, "SetTimer(_SR_TreePoll,"),
		_SRPSG_Count(source, "SetTimer(_SR_TreePoll,"),
		"no tree-poller SetTimer call may live outside the locked transition helper")
	AssertEqual(0, _SRPSG_Count(helper, "Critical("),
		"the locked helper must inherit its caller's fence and never release or replace it")

	; Close the whole sibling class, not only today's Poll/Ensure spellings. A
	; callback alias such as SetTimer(cb, 0) must not evade the target-specific
	; inventory above, and a new _SR_Tree* helper must be audited automatically.
	local tree_helper_count := 0
	local tree_pos := 1
	local tree_match := 0
	while RegExMatch(source,
			"m)^(_SR_Tree[A-Za-z0-9_]*)\([^`r`n]*\)\s*\{",
			&tree_match, tree_pos) {
		local tree_name := tree_match[1]
		local tree_body := _DriverFuncBody(tree_name)
		tree_helper_count += 1
		if tree_name = helper_name
			AssertEqual(2, _SRPSG_Count(tree_body, "SetTimer("),
				"the atomic helper must retain exactly its arm/disarm sites")
		else
			AssertEqual(0, _SRPSG_Count(tree_body, "SetTimer("),
				tree_name . " must delegate every timer operation to the atomic helper")
		tree_pos := tree_match.Pos + tree_match.Len
	}
	Assert(tree_helper_count > 10,
		"the generic tree-helper timer inventory must match a non-vacuous production class")
	AssertEqual(1, _SRPSG_CountRegex(helper,
		"_SR_TreePollRunning[ \\t]*:="),
		"the helper must own exactly one logical flag commit")
	AssertEqual(2, _SRPSG_CountRegex(source,
		"_SR_TreePollRunning[ \\t]*:="),
		"the only tree-poller flag writes must be its global initializer and locked helper")

	local apply_pos := InStr(helper, "ApplyTimer.Call(period)", true)
	local arm_timer_pos := InStr(helper,
		"SetTimer(_SR_TreePoll, _SR_POLL_INTERVAL_MS)", true)
	local disarm_timer_pos := InStr(helper, "SetTimer(_SR_TreePoll, 0)", true)
	local flag_pos := InStr(helper, "_SR_TreePollRunning := Desired", true)
	Assert(apply_pos > 0 && arm_timer_pos > 0
		&& disarm_timer_pos > 0 && flag_pos > 0,
		"the helper must expose injected, explicit arm/disarm, and one flag commit")
	Assert(apply_pos < flag_pos && arm_timer_pos < flag_pos
		&& disarm_timer_pos < flag_pos,
		"the timer operation must succeed before the matching flag is committed")

	local publish_pos := InStr(start,
		'_SR_TreeOwnedTasks[State["TaskId"]] := State', true)
	local start_ensure_pos := InStr(start, "_SR_TreeEnsurePoller()", true)
	AssertEqual(1, _SRPSG_Count(source, "_SR_TreeEnsurePoller(") - 1,
		"tree-poller arming must retain exactly one audited production caller")
	AssertEqual(1, _SRPSG_Count(start, "_SR_TreeEnsurePoller("),
		"the successful tree-owned start must remain the sole poller-arm owner")
	Assert(publish_pos > 0 && start_ensure_pos > publish_pos,
		"the tree-owned task must be published before its sole Ensure call can arm the poller")
}
Test("shell_runner: tree poller timer and flag have one Critical owner (shellrunner-tree-poller-owner-class)",
	_SRPSG_TreePollerTransitionsAreCentralized)





; =========================================================
; =========================================================
; ======= 3/ STARTING cancellation ownership =============
; =========================================================
; =========================================================

_SRPSG_StartingCancellationOwnsCompleteNativeBundle() {
	local start := _DriverFuncBody("_SR_TreeHandleStart")
	local terminate := _DriverFuncBody("_SR_TreeHandleTerminate")
	local detach := _DriverFuncBody("_SR_TreeHandleDetach")
	local claim := _DriverFuncBody("_SR_TreeClaimTaskLocked")
	Assert(start != "" && terminate != "" && detach != "" && claim != "",
		"the complete STARTING cancellation class must remain inspectable")

	local starting_guard := InStr(terminate,
		'if State["Starting"] && !State["TerminalClaimed"]', true)
	local reserve_callback := _SRPSG_FindAfter(terminate,
		'State["PendingTerminationCallback"] := FireDone',
		starting_guard)
	local mark_pending := _SRPSG_FindAfter(terminate, "starting_pending := true",
		reserve_callback)
	local pending_return_guard := _SRPSG_FindAfter(terminate, "if starting_pending",
		mark_pending)
	local pending_return := _SRPSG_FindAfter(terminate, "return false",
		pending_return_guard)
	local direct_claim := InStr(terminate,
		"_SR_TreeClaimTaskLocked(State, FireDone, false)", true)
	Assert(starting_guard > 0 && reserve_callback > starting_guard
		&& mark_pending > reserve_callback
		&& pending_return_guard > mark_pending
		&& pending_return > pending_return_guard,
		"STARTING termination must reserve request ownership without claiming State and return an honest pending result")
	AssertEqual(1, _SRPSG_Count(terminate, "_SR_TreeClaimTaskLocked("),
		"only the non-STARTING terminator branch may claim State directly")
	Assert(direct_claim > mark_pending,
		"the STARTING branch must be selected before the direct native claim")
	Assert(InStr(detach,
		'State["PendingTerminationCallback"] := 0', true) > 0,
		"detach must retire a still-unclaimed STARTING callback as well as OnDone")

	local seam_call := InStr(start, "before_adopt.Call(State, native)", true)
	local adoption_locals_end := _SRPSG_FindAfter(start,
		'local thread_close_error := ""', seam_call)
	local adoption_fence := _SRPSG_FindAfter(start,
		'previous_critical := Critical("On")', adoption_locals_end)
	local process_take := _SRPSG_FindAfter(start,
		'State["ProcessHandle"] := native["ProcessHandle"]', adoption_fence)
	local process_zero := _SRPSG_FindAfter(start, 'native["ProcessHandle"] := 0',
		process_take)
	local thread_take := _SRPSG_FindAfter(start,
		'State["ThreadHandle"] := native["ThreadHandle"]', adoption_fence)
	local thread_zero := _SRPSG_FindAfter(start, 'native["ThreadHandle"] := 0',
		thread_take)
	local job_take := _SRPSG_FindAfter(start,
		'State["JobHandle"] := native["JobHandle"]', adoption_fence)
	local job_zero := _SRPSG_FindAfter(start, 'native["JobHandle"] := 0', job_take)
	local pid_take := _SRPSG_FindAfter(start,
		'State["Pid"] := native["Pid"]', adoption_fence)
	local pid_zero := _SRPSG_FindAfter(start, 'native["Pid"] := 0', pid_take)
	local last_transfer := Max(process_zero, thread_zero, job_zero, pid_zero)
	local starting_clear := _SRPSG_FindAfter(start, 'State["Starting"] := false',
		last_transfer)
	local pending_branch := _SRPSG_FindAfter(start,
		'if State["TerminationRequested"]', starting_clear)
	local canceled_claim := _SRPSG_FindAfter(start,
		"_SR_TreeClaimTaskLocked(State, false, false)",
		pending_branch)
	local publish := InStr(start,
		'_SR_TreeOwnedTasks[State["TaskId"]] := State', true)
	local resume := InStr(start, 'DllCall("Kernel32\ResumeThread"', true)
	local adoption_restore := _SRPSG_FindAfter(start,
		"Critical(previous_critical)", resume)
	local adoption_slice := adoption_restore > adoption_fence
		? SubStr(start, adoption_fence,
			adoption_restore + StrLen("Critical(previous_critical)")
				- adoption_fence)
		: ""
	Assert(adoption_locals_end > seam_call && adoption_fence > adoption_locals_end,
		"native adoption must enter its own Critical transaction after the test seam")
	Assert(process_take > adoption_fence && process_zero > process_take
		&& thread_take > adoption_fence && thread_zero > thread_take
		&& job_take > adoption_fence && job_zero > job_take
		&& pid_take > adoption_fence && pid_zero > pid_take
		&& starting_clear > last_transfer,
		"State must remain STARTING until every private native value is transferred and zeroed")
	Assert(pending_branch > starting_clear && canceled_claim > pending_branch
		&& publish > canceled_claim && resume > publish
		&& adoption_restore > resume,
		"one Critical transaction must own complete adoption, canceled claim, publication, and ResumeThread")
	AssertEqual(2, _SRPSG_Count(adoption_slice, "Critical("),
		"the adoption transaction may contain only its opening fence and final restoration")
	AssertEqual(0, _SRPSG_Count(claim, "Critical("),
		"the locked claim helper must inherit and never release its caller's adoption fence")

	local pending_read := InStr(claim,
		'local pending_callback := State["PendingTerminationCallback"]', true)
	local pending_select := _SRPSG_FindAfter(claim,
		"local callback := IsObject(pending_callback)", pending_read)
	local normal_select := _SRPSG_FindAfter(claim,
		'FireDone && !State["Detached"]', pending_select)
	local pending_clear := _SRPSG_FindAfter(claim,
		'State["PendingTerminationCallback"] := 0', normal_select)
	Assert(pending_read > 0 && pending_select > pending_read
		&& normal_select > pending_select && pending_clear > normal_select,
		"the terminal claim must consume remaining STARTING callback ownership before its normal callback fallback")
}
Test("shell_runner: STARTING cancellation adopts before claim/publication/resume (shellrunner-tree-starting-owner-class)",
	_SRPSG_StartingCancellationOwnsCompleteNativeBundle)
