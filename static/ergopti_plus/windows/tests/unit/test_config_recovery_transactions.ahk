; tests/unit/test_config_recovery_transactions.ahk

; ==============================================================================
; MODULE: Config recovery transactions
; DESCRIPTION:
; Behavioural proof that a staged native authority can reverse its durable write
; after activation failure, and that failed cleanup is retained before the new
; durable/native authority is published. Every step remains under one lease.
; ==============================================================================

#Requires AutoHotkey v2.0

global _CRT_Events := []
global _CRT_Path := ""
global _CRT_Mode := ""
global _CRT_PublishCalls := 0
global _CRT_RetainStage := ""
global _CRT_LeaseHeld := []
global _CRT_NotifyReacquired := false

_CRT_Reset(Mode) {
	global _CRT_Events, _CRT_Path, _CRT_Mode, _CRT_PublishCalls
	global _CRT_RetainStage, _CRT_LeaseHeld, _CRT_NotifyReacquired
	_CRT_Events := []
	_CRT_Path := A_Temp . "\ergopti_config_recovery_transaction.toml"
	_CRT_Mode := Mode
	_CRT_PublishCalls := 0
	_CRT_RetainStage := ""
	_CRT_LeaseHeld := []
	_CRT_NotifyReacquired := false
}

_CRT_AssertLeaseHeld(Stage) {
	global _CRT_Path, _CRT_LeaseHeld
	Intruder := _ConfigWriteLeaseTryAcquire(_CRT_Path, "recovery-intruder")
	Held := !(Intruder is Object)
	_CRT_LeaseHeld.Push([Stage, Held])
	if (Intruder is Object)
		_ConfigWriteLeaseRelease(Intruder)
}

_CRT_Writer(Path, Updates) {
	global _CRT_Events
	_CRT_AssertLeaseHeld("writer")
	_CRT_Events.Push("write:" . Updates[1].Value)
	return true
}

_CRT_Finalize() {
	global _CRT_Events, _CRT_Mode
	_CRT_Events.Push("activate")
	return _CRT_Mode != "activate-fails"
		&& _CRT_Mode != "compensation-fails"
}

_CRT_Compensate() {
	global _CRT_Events, _CRT_Mode
	_CRT_Events.Push("abort")
	return _CRT_Mode != "compensation-fails"
}

_CRT_Cleanup() {
	global _CRT_Events, _CRT_Mode
	_CRT_Events.Push("retire")
	return _CRT_Mode != "cleanup-fails"
}

_CRT_Retain(Stage) {
	global _CRT_Events, _CRT_RetainStage
	_CRT_AssertLeaseHeld("retain")
	_CRT_RetainStage := Stage
	_CRT_Events.Push("retain:" . Stage)
	return true
}

_CRT_Publish() {
	global _CRT_Events, _CRT_PublishCalls
	_CRT_PublishCalls += 1
	_CRT_Events.Push("publish")
}

_CRT_Notify(Message, Options) {
	global _CRT_Events, _CRT_Path, _CRT_NotifyReacquired
	Token := _ConfigWriteLeaseTryAcquire(_CRT_Path, "recovery-notifier")
	_CRT_NotifyReacquired := Token is Object
	if (Token is Object)
		_ConfigWriteLeaseRelease(Token)
	_CRT_Events.Push("notify")
}

_CRT_Plan() {
	global _CRT_Events
	_CRT_Events.Push("reserve-off")
	return {
		updates: [{ Section: "metrics", Key: "shortcut", Value: "new" }],
		rollback_updates: [{ Section: "metrics", Key: "shortcut", Value: "old" }],
		finalize: _CRT_Finalize,
		compensate: _CRT_Compensate,
		cleanup: _CRT_Cleanup,
		retain: _CRT_Retain,
		publish: _CRT_Publish
	}
}

_CRT_AssertEvents(Expected, Message) {
	global _CRT_Events
	AssertEqual(Expected.Length, _CRT_Events.Length, Message . " (event count)")
	for Index, Event in Expected
		AssertEqual(Event, _CRT_Events[Index], Message . " (event " . Index . ")")
}

_CRT_ActivationFailureRollsBackUnderSameLease() {
	global _CRT_PublishCalls, _CRT_RetainStage, _CRT_LeaseHeld
	global _CRT_NotifyReacquired, _CRT_Path
	_CRT_Reset("activate-fails")
	AssertFalse(ConfigCommitBuilt(_CRT_Path, "the staged activation failure",
		_CRT_Plan, _CRT_Writer, _CRT_Notify))
	_CRT_AssertEvents(["reserve-off", "write:new", "activate", "abort",
		"write:old", "notify"], "activation rollback")
	AssertEqual(0, _CRT_PublishCalls,
		"a reversed candidate must never publish forward live state")
	AssertEqual("", _CRT_RetainStage,
		"complete rollback needs no recovery retention")
	for Observation in _CRT_LeaseHeld
		AssertTrue(Observation[2], Observation[1] . " must run under the same lease")
	AssertTrue(_CRT_NotifyReacquired,
		"the notifier must run only after rollback releases ownership")
}
Test("config recovery: activation failure reverses durability under one lease "
	. "(config-recovery-activation-rollback)",
	_CRT_ActivationFailureRollsBackUnderSameLease)

_CRT_FailedCompensationNeverRewritesOldDurability() {
	global _CRT_PublishCalls, _CRT_RetainStage, _CRT_LeaseHeld
	global _CRT_NotifyReacquired, _CRT_Path
	_CRT_Reset("compensation-fails")
	AssertFalse(ConfigCommitBuilt(_CRT_Path, "the failed native compensation",
		_CRT_Plan, _CRT_Writer, _CRT_Notify))
	_CRT_AssertEvents(["reserve-off", "write:new", "activate", "abort",
		"retain:compensation_failed", "notify"],
		"failed compensation must retain forward authority")
	AssertEqual(0, _CRT_PublishCalls,
		"ambiguous native authority must remain behind explicit recovery")
	AssertEqual("compensation_failed", _CRT_RetainStage)
	for Observation in _CRT_LeaseHeld
		AssertTrue(Observation[2], Observation[1] . " must run under the same lease")
	AssertTrue(_CRT_NotifyReacquired)
}
Test("config recovery: failed compensation cannot authorize reverse durability "
	. "(config-recovery-compensation-before-rollback)",
	_CRT_FailedCompensationNeverRewritesOldDurability)

_CRT_CleanupFailurePublishesAndRetainsAuthority() {
	global _CRT_PublishCalls, _CRT_RetainStage, _CRT_LeaseHeld
	global _CRT_NotifyReacquired, _CRT_Path
	_CRT_Reset("cleanup-fails")
	AssertFalse(ConfigCommitBuilt(_CRT_Path, "the staged cleanup failure",
		_CRT_Plan, _CRT_Writer, _CRT_Notify))
	_CRT_AssertEvents(["reserve-off", "write:new", "activate", "retire",
		"retain:cleanup_failed", "publish", "notify"], "cleanup retention")
	AssertEqual(1, _CRT_PublishCalls,
		"forward durable/native authority must publish despite stale cleanup")
	AssertEqual("cleanup_failed", _CRT_RetainStage)
	for Observation in _CRT_LeaseHeld
		AssertTrue(Observation[2], Observation[1] . " must run under the same lease")
	AssertTrue(_CRT_NotifyReacquired)
}
Test("config recovery: cleanup failure retains before forward publication "
	. "(config-recovery-cleanup-retention)",
	_CRT_CleanupFailurePublishesAndRetainsAuthority)
