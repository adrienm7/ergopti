; tests/unit/llm_nav_event_owner/test_profile_receipts.ahk

; ==============================================================================
; MODULE: LLM Navigation Owner — Profile Receipts
; DESCRIPTION:
; Cohesive navigation-owner coverage included by test_llm_nav_event_owner.ahk.
; Uses the injected native port without installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 6/ Profile receipt ownership =======
; ============================================
; ============================================

_LNEO_ProfilePlan() {
	Plan := []
	Loop 9
		Plan.Push(Map(
			"profile_idx", A_Index,
			"physical_id", "^vk00" . (30 + A_Index)))
	return Plan
}

_LNEO_QueueProfileReceipt(State, Sequence, Token, TargetIdx) {
	Receipt := Map(
		"seq", Sequence,
		"owner_token", Token,
		"owner_epoch", Token,
		"plan_generation", 1,
		"route_idx", TargetIdx,
		"action", 3,
		"delta", 0,
		"from_idx", 0,
		"target_idx", TargetIdx,
		"pass_through", 0)
	State.ReceiptQueue.Push(Receipt)
	State.Pending[Token] := State.Pending.Get(Token, 0) + 1
}

_LNEO_ProfileSelectProbe(State, ProfileId) {
	State.Calls.Push(ProfileId)
	if State.QuiesceDuring
		State.QuiesceResult := LLM_NavEventOwner_QuiesceForLifecycle(true)
	return State.Status
}

_LNEO_ProfileBeginAlwaysClosesOrQuarantinesFence() {
	Plan := _LNEO_ProfilePlan()
	Cases := [
		Map("mode", "refuse", "stops", 0, "aborts", 0),
		Map("mode", "throw", "stops", 1, "aborts", 0),
		Map("mode", "malformed_mask", "stops", 0, "aborts", 1),
		Map("mode", "malformed_ticket", "stops", 1, "aborts", 0)
	]
	for Scenario in Cases {
		State := _LNEO_Setup()
		try {
			State.ProfileBeginMode := Scenario["mode"]
			Result := LLM_NavEventOwner_BeginProfileSwap(
				Plan, ["a"], 1, ["a"], State.Port)
			AssertFalse(Result is Map,
				"a refused or ambiguous Begin must never publish a transaction")
			AssertEqual(Scenario["stops"], State.StopCalls,
				Scenario["mode"] . " must use the expected quarantine boundary")
			AssertEqual(Scenario["aborts"], State.ProfileAbortCalls.Length,
				Scenario["mode"] . " must use the expected exact Abort boundary")
			AssertFalse(State.StagedProfileSwap is Map,
				Scenario["mode"] . " must not leave a silent profile fence armed")
		} finally _LNEO_Teardown()
	}
}

Test("LLM nav event owner: malformed profile Begin closes its fence (ahk-029)",
	_LNEO_ProfileBeginAlwaysClosesOrQuarantinesFence)

_LNEO_ProfileReceiptRetainsAdmittedTargetAcrossReorder() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerProfileOwners
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First),
			"the first immutable profile order must publish")
		OldToken := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8001, OldToken, 2)

		Second := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["b", "c"], 1, ["b", "c"], State.Port)
		AssertTrue(Second is Map
			&& LLM_NavEventOwner_CommitProfileSwap(Second),
			"deleting an earlier profile must preserve a pending target")
		AssertTrue(_LLM_NavEventOwnerProfileOwners.Has(OldToken),
			"the retired order must remain retained while its receipt is pending")
		Probe := {Calls: [], Status: 1, QuiesceDuring: false,
			QuiesceResult: true}
		AssertTrue(LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe)))
		AssertEqual(1, Probe.Calls.Length,
			"one profile receipt must cause exactly one selection")
		AssertEqual("b", Probe.Calls[1],
			"the receipt must resolve through its admitted old order")
		AssertFalse(_LLM_NavEventOwnerProfileOwners.Has(OldToken),
			"the retired order may collect only after exact completion")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: admitted profile target survives earlier deletion (ahk-029)",
	_LNEO_ProfileReceiptRetainsAdmittedTargetAcrossReorder)

_LNEO_ProfileTargetDeletionIsRefusedWhilePending() {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global _LLM_NavEventOwnerActiveProfileToken
	SavedMenu := _LLM_Menu
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	_LLM_Menu_ProfileHotkeyOwner := 0
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		LLM_PROFILE_BUILTIN_ORDER := []
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu := Map(
			"enabled", true,
			"profile_id", "a",
			"app_profile_overrides", Map(),
			"user_profiles", [
				Map("id", "a"), Map("id", "b"), Map("id", "c")])
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		_LLM_Menu_ProfileHotkeyOwner := Map(
			"ready", true, "degraded", false,
			"native", true, "plan", Plan)
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8002, Token, 2)
		Candidate := LLM_Menu_DeepClone(_LLM_Menu)
		AssertTrue(_LLM_Menu_DeleteProfileCandidate(Candidate, "b"),
			"the test must exercise the real detached deletion mutator")
		Rejected := _LLM_Menu_PrepareProfileOwnerCandidate(Candidate)
		AssertEqual(0, Rejected,
			"the real menu preparation must refuse deletion of its pending target")
		AssertEqual(1, State.ProfileBeginCalls.Length,
			"known retired debt must refuse before opening a second fence")
		AssertEqual(0, State.ProfileAbortCalls.Length)
		AssertEqual(Token, State.CurrentProfileToken,
			"refusal must retain the prior native owner")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
		_LNEO_Teardown()
	}
}

Test("LLM nav event owner: pending profile target blocks its deletion (ahk-029)",
	_LNEO_ProfileTargetDeletionIsRefusedWhilePending)

_LNEO_DeleteProfileB(Candidate) {
	return _LLM_Menu_DeleteProfileCandidate(Candidate, "b")
}

_LNEO_DisabledRetiredTargetBlocksDurableDelete() {
	global Features, _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	global _LLM_NavEventOwnerActiveProfileToken, _LMT_WriterCalls
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	_LLM_Menu_ProfileHotkeyOwner := 0
	Previous := _LMT_InstallFixture()
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		LLM_PROFILE_BUILTIN_ORDER := []
		LLM_PROFILE_HOTKEY_LIMIT := 9
		_LLM_Menu["enabled"] := true
		_LLM_Menu["profile_id"] := "a"
		_LLM_Menu["app_profile_overrides"] := Map()
		_LLM_Menu["user_profiles"] := [
			Map("id", "a"), Map("id", "b"), Map("id", "c")]
		AssertTrue(_LLM_Menu_SyncToFeatures(Features, _LLM_Menu))
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 1, ["a", "b", "c"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		OldToken := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8004, OldToken, 2)
		Disabled := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b", "c"], 0, ["a", "b", "c"], State.Port)
		AssertTrue(Disabled is Map
			&& LLM_NavEventOwner_CommitProfileSwap(Disabled),
			"the active profile surface must disable while retaining old debt")
		_LLM_Menu["enabled"] := false
		Features["llm"]["enabled"] := false
		_LLM_Menu_ProfileHotkeyOwner := Map(
			"ready", true, "degraded", false,
			"native", true, "plan", Plan)
		_LMT_WriterCalls := 0
		AssertFalse(LLM_Menu_CommitMutation(
			"the pending profile deletion", _LNEO_DeleteProfileB,
			0, _LMT_Writer, _LMT_Notify, _LMT_Acquire,
			_LMT_Settle, _LMT_Quiesce, _LMT_Collect),
			"retired receipt debt must refuse the complete menu transaction")
		AssertEqual(0, _LMT_WriterCalls,
			"pending-target refusal must precede durable config I/O")
		AssertEqual(3, _LLM_Menu["user_profiles"].Length,
			"the failed candidate must not mutate live profiles")
	} finally {
		_LNEO_Teardown()
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
		_LMT_RestoreFixture(Previous)
	}
}

Test("LLM nav event owner: disabled retired target blocks durable deletion (ahk-029)",
	_LNEO_DisabledRetiredTargetBlocksDurableDelete)

_LNEO_ProfileEffectDoesNotReplayAfterAckFailure() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerClaimedReceipt
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8003, Token, 2)
		Probe := {Calls: [], Status: 1, QuiesceDuring: true,
			QuiesceResult: true}
		State.CompleteMode := "refuse"
		LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(1, Probe.Calls.Length)
		AssertFalse(Probe.QuiesceResult,
			"lifecycle quiescence must not begin during the profile effect")
		AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map
			&& _LLM_NavEventOwnerClaimedReceipt.Get(
				"profile_effect_done", false),
			"a completed effect must remain marked while its ACK is retried")

		State.CompleteMode := "accept"
		LLM_NavEventOwner_Drain(0, 0,
			_LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(1, Probe.Calls.Length,
			"an ACK retry must never replay the durable profile selection")
		AssertFalse(_LLM_NavEventOwnerClaimedReceipt is Map,
			"the exact claimed receipt must clear after its ACK succeeds")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: profile effect is exactly-once across ACK retry (ahk-029)",
	_LNEO_ProfileEffectDoesNotReplayAfterAckFailure)

; A profile receipt owns a SUPPRESSED physical key: until it is completed, the
; digit the user pressed never reaches the focused application. A refused effect
; used to return with the receipt still claimed and nothing to retire it, so the
; 100 ms service timer re-attempted the same doomed selection forever. Field logs
; from 2026-09-05 show the shape exactly: pressing "1" wedged slot 1, 106 refusals
; followed at typing cadence, the digit never appeared, and six consecutive exit
; attempts were vetoed because a native receipt was still owned.
;
; The budget must therefore be a BUDGET, not a hint: the receipt has to be retired
; on exhaustion so the key is released, and the doomed effect must not be replayed
; afterwards (llm-profile-receipt-retry-livelock).
_LNEO_RefusedProfileEffectIsRetiredNotRetriedForever() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerClaimedReceipt
	global LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8007, Token, 1)
		; Status 0 is the live failure: LLM_Menu_SetProfile returning "refused"
		; because the owner preparation could not be admitted.
		Probe := {Calls: [], Status: 0, QuiesceDuring: false,
			QuiesceResult: true}
		Budget := LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS
		AssertTrue(Budget >= 1,
			"the retry budget must be a positive integer for this guard to mean anything")

		; Every drain here stands for one 100 ms service tick.
		Loop Budget - 1 {
			LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Probe))
			AssertEqual(A_Index, Probe.Calls.Length,
				"each tick within the budget must re-attempt the effect exactly once")
			AssertEqual(0, State.CompleteCalls.Length,
				"the receipt must not be retired while budget remains")
			AssertTrue(_LLM_NavEventOwnerClaimedReceipt is Map,
				"the receipt stays claimed while it is still being retried")
		}

		LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(Budget, Probe.Calls.Length,
			"the budget must be spent exactly, never exceeded")
		AssertEqual(1, State.CompleteCalls.Length,
			"an effect that cannot be applied must still RETIRE its receipt: leaving it "
			. "claimed is what swallowed the user's keystroke and vetoed shutdown "
			. "(llm-profile-receipt-retry-livelock)")
		AssertEqual(0, State.Pending.Get(Token, 0),
			"retiring the receipt must clear the owner's pending mask, so the next "
			. "profile transaction is admissible again")
		AssertFalse(_LLM_NavEventOwnerClaimedReceipt is Map,
			"the claim must be released -- while it is held, the suppressed physical "
			. "key never reaches the focused application")

		; The livelock is only broken if the doomed effect also stops replaying.
		Loop 5
			LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(Budget, Probe.Calls.Length,
			"a retired receipt must never be re-attempted: further ticks re-entering "
			. "the same doomed selection IS the livelock this guard exists for")
		AssertEqual(1, State.CompleteCalls.Length,
			"and it must not be retired twice")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: a refused profile effect is retired, not retried forever (llm-profile-receipt-retry-livelock)",
	_LNEO_RefusedProfileEffectIsRetiredNotRetriedForever)

; The budget must not leak across receipts. A user who wedges one slot, recovers,
; then presses another digit must get the full budget again -- otherwise the
; second press is retired without ever being attempted.
_LNEO_ProfileRetryBudgetIsPerReceipt() {
	global _LLM_NavEventOwnerActiveProfileToken
	global LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		Budget := LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS

		_LNEO_QueueProfileReceipt(State, 8008, Token, 1)
		Probe := {Calls: [], Status: 0, QuiesceDuring: false,
			QuiesceResult: true}
		Loop Budget
			LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(Budget, Probe.Calls.Length,
			"the first receipt must spend the whole budget")

		; A second, independent press of another slot.
		_LNEO_QueueProfileReceipt(State, 8009, Token, 2)
		Second := {Calls: [], Status: 1, QuiesceDuring: false,
			QuiesceResult: true}
		LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Second))
		AssertEqual(1, Second.Calls.Length,
			"a fresh receipt must be attempted on its first tick, not refused on a "
			. "budget the previous receipt already spent")
		AssertEqual(2, State.CompleteCalls.Length,
			"a succeeding second receipt must retire normally")
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: the profile retry budget is per receipt (llm-profile-receipt-retry-livelock)",
	_LNEO_ProfileRetryBudgetIsPerReceipt)

_LNEO_StopClearsRetiredProfileFailures() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerProfileFailures, _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerClaimedReceipt
	SavedFailures := _LLM_NavEventOwnerProfileFailures
	State := _LNEO_Setup()
	try {
		_LLM_NavEventOwnerProfileFailures := Map()
		Swap := LLM_NavEventOwner_BeginProfileSwap(
			_LNEO_ProfilePlan(), ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(Swap is Map && LLM_NavEventOwner_CommitProfileSwap(Swap))
		_LNEO_QueueProfileReceipt(State, 8010, _LLM_NavEventOwnerActiveProfileToken, 2)
		Probe := {Calls: [], Status: 0, QuiesceDuring: false, QuiesceResult: true}
		LLM_NavEventOwner_Drain(0, 0, _LNEO_ProfileSelectProbe.Bind(Probe))
		AssertEqual(1, Probe.Calls.Length, "the receipt must incur a real failed attempt")
		AssertEqual(1, _LLM_NavEventOwnerProfileFailures.Count)
		State.StopMode := "refuse"
		AssertFalse(LLM_NavEventOwner_Stop())
		AssertEqual(1, _LLM_NavEventOwnerProfileFailures.Count,
			"refused teardown must retain the retry budget with its live receipt")
		State.StopMode := "accept"
		AssertTrue(LLM_NavEventOwner_Stop())
		AssertEqual(0, _LLM_NavEventOwnerProfileFailures.Count,
			"acknowledged teardown must retire the global profile retry registry")
		AssertEqual(0, _LLM_NavEventOwnerProfileOwners.Count)
		AssertEqual(0, _LLM_NavEventOwnerClaimedReceipt)
	} finally {
		State.StopMode := "accept"
		try _LNEO_Teardown()
		finally _LLM_NavEventOwnerProfileFailures := SavedFailures
	}
}
Test("LLM nav event owner: acknowledged Stop clears retired profile failures (profile-failure-stop-cleanup)",
	_LNEO_StopClearsRetiredProfileFailures)

_LNEO_ShutdownPreflightDrainsBeforeDebtProof() {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerShutdownFenced
	State := _LNEO_Setup()
	try {
		Plan := _LNEO_ProfilePlan()
		First := LLM_NavEventOwner_BeginProfileSwap(
			Plan, ["a", "b"], 1, ["a", "b"], State.Port)
		AssertTrue(First is Map
			&& LLM_NavEventOwner_CommitProfileSwap(First))
		Token := _LLM_NavEventOwnerActiveProfileToken
		_LNEO_QueueProfileReceipt(State, 8005, Token, 2)
		Probe := {Calls: [], Status: 1, QuiesceDuring: false,
			QuiesceResult: true}
		AssertTrue(LLM_NavEventOwner_PrepareShutdown(
			_LNEO_ProfileSelectProbe.Bind(Probe), State.Port),
			"shutdown may proceed only after the fenced receipt drain")
		AssertEqual(1, Probe.Calls.Length)
		AssertEqual("b", Probe.Calls[1])
		AssertEqual(1, State.CanStopCalls,
			"native terminal debt must be checked after AHK drain")
		AssertEqual(1, State.SuspendCalls.Length)
		AssertEqual(1, State.SuspendCalls[1],
			"native admission must be fenced before profile selection")
		AssertTrue(_LLM_NavEventOwnerShutdownFenced)
		AssertTrue(LLM_NavEventOwner_CancelShutdown(),
			"a later shutdown refusal must resume the native owner")
		AssertEqual(2, State.SuspendCalls.Length)
		AssertEqual(0, State.SuspendCalls[2])
		AssertFalse(_LLM_NavEventOwnerShutdownFenced)
		State.CanStopMode := "refuse"
		AssertFalse(LLM_NavEventOwner_PrepareShutdown(0, State.Port),
			"native debt refusal must keep shutdown reversible")
		AssertEqual(4, State.SuspendCalls.Length)
		AssertEqual(1, State.SuspendCalls[3])
		AssertEqual(0, State.SuspendCalls[4],
			"a refused debt proof must compensate native suspension")
		AssertFalse(_LLM_NavEventOwnerShutdownFenced)
	} finally _LNEO_Teardown()
}

Test("LLM nav event owner: shutdown fence drains profiles before debt proof (ahk-029)",
	_LNEO_ShutdownPreflightDrainsBeforeDebtProof)

_LNEO_ShutdownSourceCompensatesEveryRefusal() {
	Body := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	AssertTrue(Body != "", "the production shutdown handler must be scanned")
	Preflight := InStr(Body, "LLM_NavEventOwner_PrepareShutdown()")
	Bundle := InStr(Body, "ReloadTerminalHandoffClaim(reason)")
	Terminal := InStr(Body, "ShutdownTerminal := true")
	Stop := InStr(Body, "LLM_NavEventOwner_Stop(false, true)")
	AssertTrue(Preflight > 0 && Bundle > Preflight,
		"profile drain must run before the config bundle can block persistence")
	AssertTrue(Terminal > Bundle && Stop > Terminal,
		"shutdown may become irreversible only after every refusal gate")
	AssertTrue(InStr(Body, "if !ShutdownTerminal") > 0
		&& InStr(Body, "LLM_NavEventOwner_CancelShutdown()") > 0,
		"the outer finally must resume native admission after every refusal")
}

Test("LLM lifecycle: every shutdown refusal resumes profile admission (ahk-029)",
	_LNEO_ShutdownSourceCompensatesEveryRefusal)
