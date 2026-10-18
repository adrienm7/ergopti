; tests/unit/infra/config/migration/test_config_journal_settlement.ahk

; ==============================================================================
; MODULE: Config Journal Owned Settlement
; DESCRIPTION:
; Owned journal settlement keeps booted readiness across native publication
; and rollback, recovers legacy WAL, retries partial settlement and lets
; only the original recovery producer mint its outcome.
; ==============================================================================

#Requires AutoHotkey v2.0





; Native journal recovery returns only the phase acquired before its terminal span.
_CMJ_OwnedReadyLifecycle(Mode) {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n[private]`nkeep = "retained"`n')
	Path := Fixture.path, Locator := Fixture.options["locator"], ApiPath := Fixture.directory . "\api_entries.json"
	Initial := Fixture.source, ApiInitial := '{"generation":0}', Bundle := 0
	Assert(FSWriteDurable(ApiPath, ApiInitial))
	try {
		Loops := Mode == "success" ? 2 : 1
		Loop Loops {
			NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = ' . (A_Index == 1 ? "false" : "true") . '`n[private]`nkeep = "retained"`n')
			ApiNew := '{"generation":' . A_Index . '}'
			Bundle := _ConfigWriteTerminalTryAcquire([Path, ApiPath, Locator])
			Assert(Bundle is Object)
			Specs := [ConfigTransitionPresentTarget(Path, NewSource), ConfigTransitionPresentTarget(ApiPath, ApiNew)]
			Committed := ConfigTransitionCommitOwned(Locator, Specs, Bundle)
			Assert(ConfigTransitionResultIs(Committed, "committed_new"), "the real two-file native publisher must commit before readiness is examined")
			Assert(ConfigSchemaPrepareOwnedSource(Path, Bundle), "same-bundle repeated preparation remains admitted")
			Resolved := Mode == "rollback" ? ConfigTransitionRollbackOwned(Locator, Bundle)
				: ConfigTransitionRecoverOwned(Locator, Bundle)
			Assert(ConfigTransitionResultIs(Resolved, Mode == "rollback" ? "recovered_old" : "recovered_new"))
			Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
			Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
			Assert(ConfigSchemaCanPrepareWrite(Path), "a completed native transition cannot retire a genuinely booted source forever")
			AssertTrue(FSUtf8ExactMatches(Path, Mode == "rollback" ? Initial : NewSource))
			AssertTrue(FSUtf8ExactMatches(ApiPath, Mode == "rollback" ? ApiInitial : ApiNew))
		}
		Assert(TOML_ConfigBatchWrite(Path, [{ Section: "llm", Key: "enabled", Value: TOML_Bool(true) }]), "an independent later native writer must remain admitted")
	} finally {
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: two native publications retain booted readiness", _CMJ_OwnedReadyLifecycle.Bind("success"))
Test("config journal owned settlement: native rollback retains booted readiness", _CMJ_OwnedReadyLifecycle.Bind("rollback"))

_CMJ_OwnedPreparedLifecycle() {
	Fixture := _ScopeOwnerFixture(), Path := Fixture.directory . "\preboot.toml", Locator := Fixture.options["locator"], Bundle := 0
	Initial := _CMJFixtureCurrentSource('[llm]`nenabled = true`n')
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n')
	try {
		Assert(FSWriteDurable(Path, Initial))
		AssertEqual("current", ConfigSchemaPrepareSource(Path)["status"])
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle), "committed_new"))
		Assert(ConfigSchemaPrepareOwnedSource(Path, Bundle))
		Assert(ConfigTransitionResultIs(ConfigTransitionRecoverOwned(Locator, Bundle), "recovered_new"))
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "owned wizard publication must not manufacture completed startup")
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Assert(ConfigSchemaCanPrepareWrite(Path), "only the genuine later boot may acquire readiness")
	} finally {
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: preboot remains readonly until genuine boot", _CMJ_OwnedPreparedLifecycle)

_CMJ_OwnedColdLegacyRecovery() {
	Fixture := _ScopeOwnerFixture(), Path := Fixture.directory . "\cold.toml", Locator := Fixture.options["locator"], Bundle := 0
	Legacy := '[llm]`nenabled = true`n', NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n')
	try {
		Assert(FSWriteDurable(Path, Legacy))
		Port := ConfigTransitionProductionPort()
		Assert(ConfigTransitionResultIs(ConfigTransitionPrepare(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Port), "prepared"))
		AssertEqual("migrate", ConfigSchemaPrepareSource(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionRecoverOwned(Locator, Bundle), "recovered_old"), "real cold all-old recovery keeps its legacy source")
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		AssertTrue(FSUtf8ExactMatches(Path, Legacy))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "recovery alone does not complete legacy migration")
		AssertEqual("migrated", ConfigMigrateBoot(Path)["status"])
		Assert(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: cold legacy WAL recovery preserves later migration", _CMJ_OwnedColdLegacyRecovery)

_CMJ_OwnedSettlementRefusals() {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n'), Path := Fixture.path, Locator := Fixture.options["locator"], Bundle := 0
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n')
	try {
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigSchemaPrepareOwnedSource(Path, Bundle))
		AssertFalse(ConfigSchemaSettleOwnedSource(Path, Locator, {}, "old"), "a foreign bundle cannot settle the source")
		Assert(FSWriteDurable(Path, Fixture.source . "# foreign current bytes`n"))
		AssertFalse(ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, "old"), "current classification cannot replace exact settled byte identity")
		Assert(FSWriteDurable(Path, Fixture.source))
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle), "committed_new"))
		AssertFalse(ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, "new"), "discoverable WAL debt must remain owned")
		Assert(ConfigTransitionResultIs(ConfigTransitionRollbackOwned(Locator, Bundle), "recovered_old"))
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		Assert(ConfigSchemaCanPrepareWrite(Path))
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(ConfigSchemaPrepareOwnedSource(Path, Bundle))
		TOML_RefuseWrites(Path, "owned fixture refusal")
		AssertFalse(ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, "old"), "an explicit real refusal cannot be promoted to READY")
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		AssertFalse(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: foreign bytes bundle debt and refusal stay fail closed", _CMJ_OwnedSettlementRefusals)

_CMJ_OwnedNativeWithdrawal() {
	Fixture := _ScopeOwnerFixture(), Path := Fixture.directory . "\withdraw.toml", Locator := Fixture.options["locator"], Bundle := 0
	Initial := _CMJFixtureCurrentSource('[llm]`nenabled = true`n')
	Invocations := { count: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(ConfigMigrateSameValue, "Call"))
	try {
		Assert(FSWriteDurable(Path, Initial))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigSchemaPrepareOwnedSource(Path, Bundle))
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
		ConfigMigrateSameValue.DefineProp("Call", {Call: (*) => (Invocations.count += 1, true)})
		AssertFalse(ConfigMigrateBoot(Path, "known"), "withdrawn native authority must not be mistaken for an unknown destination")
		Recovered := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual("retry", Recovered["status"], "recovery cannot report clean settlement after its native issuer was withdrawn")
		AssertEqual("source_schema_settlement_refused", Recovered["kind"])
		AssertEqual(0, Invocations.count, "the foreign native callback must never be invoked")
		ConfigMigrateSameValue.DeleteProp("Call")
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
		AssertTrue(FSUtf8ExactMatches(Path, Initial))
		Assert(ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, "old"), "exact issuer repair can acknowledge the already observed settled image")
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		Assert(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigMigrateSameValue, "Call")
			ConfigMigrateSameValue.DeleteProp("Call")
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: withdrawn native issuer cannot look like unknown destination", _CMJ_OwnedNativeWithdrawal)

_CMJ_OwnedRecoveredNewRetry() {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n'), Path := Fixture.path, Locator := Fixture.options["locator"], Bundle := 0
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n')
	Fault := { calls: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(ConfigSchemaSettleOwnedSource, "Call"))
	try {
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle), "committed_new"))
		; This named boundary fault refuses only schema settlement. The genuine
		; native recovery still verifies new bytes and physically retires its WAL.
		ConfigSchemaSettleOwnedSource.DefineProp("Call", {Call: (*) => (Fault.calls += 1, false)})
		First := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual("retry", First["status"])
		AssertEqual("source_schema_settlement_refused", First["kind"])
		AssertEqual(1, Fault.calls, "the injected refusal must occur at the actual post-recovery settlement boundary")
		ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource))
		Retry := ConfigTransitionRecoverOwned(Locator, Bundle)
		Assert(ConfigTransitionResultIs(Retry, "absent"), "retry must retain the genuinely recovered-new side: " . Retry["status"] . "/" . Retry["kind"])
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		Assert(ConfigSchemaCanPrepareWrite(Path))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource))
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigSchemaSettleOwnedSource, "Call")
			ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: recovered-new cleanup refusal retries its exact side", _CMJ_OwnedRecoveredNewRetry)

_CMJ_OwnedRebindFault(Fault, Owner, Path, Locator, Bundle, Side, Bounds := 0) {
	Fault.calls += 1
	ConfigSchemaSettleOwnedSource.DeleteProp("Call")
	Guard := ConfigMigrateBoot(Path, "capture_transition", Map("present", 1, "content", Fault.source), Bundle)
	Assert(HasMethod(Guard, "Call"))
	AssertTrue(Guard.Call(Fault.original, 1, Fault.source, 1), "the successor candidate must genuinely reach the original source owner")
	Assert(FSWriteDurable(Path, Fault.source))
	return ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, Side, Bounds)
}

_CMJ_OwnedRecoveredImageBound() {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n'), Path := Fixture.path, Locator := Fixture.options["locator"], Bundle := 0
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n[private]`nmarker = 1`n')
	Fault := { calls: 0, original: NewSource, source: _CMJFixtureCurrentSource('[llm]`nenabled = false`n[private]`nmarker = 2`n') }
	try {
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle), "committed_new"))
		ConfigSchemaSettleOwnedSource.DefineProp("Call", {Call: (*) => false})
		First := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual("retry", First["status"])
		ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
		ConfigSchemaSettleOwnedSource.DefineProp("Call", {Call: _CMJ_OwnedRebindFault.Bind(Fault)})
		Retry := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual(1, Fault.calls, "the candidate replacement must occur after native record snapshot verification")
		AssertEqual("retry", Retry["status"])
		AssertEqual("source_schema_settlement_refused", Retry["kind"])
		AssertTrue(FSUtf8ExactMatches(Path, Fault.source))
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "the recovered image cannot promote a later same-bundle candidate to READY")
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigSchemaSettleOwnedSource, "Call")
			ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: recovered record cannot lend READY to a later candidate", _CMJ_OwnedRecoveredImageBound)

_CMJ_OwnedPartialFault(Fault, Owner, Path, Locator, Bundle, Side, Bounds := 0) {
	if Path == Fault.second {
		Fault.refused += 1
		return false
	}
	ConfigSchemaSettleOwnedSource.DeleteProp("Call")
	try {
		Result := ConfigSchemaSettleOwnedSource(Path, Locator, Bundle, Side, Bounds)
		if (Result is Integer) && Result == 1
			Fault.confirmed += 1
		return Result
	} finally ConfigSchemaSettleOwnedSource.DefineProp("Call", {Call: _CMJ_OwnedPartialFault.Bind(Fault)})
}

_CMJ_OwnedPartialRetry() {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n'), Path := Fixture.path, Locator := Fixture.options["locator"], Bundle := 0
	Second := Fixture.directory . "\second.toml", Initial := _CMJFixtureCurrentSource('[llm]`nenabled = true`n')
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n')
	Fault := { second: Second, confirmed: 0, refused: 0 }
	try {
		Assert(FSWriteDurable(Second, Initial))
		AssertEqual("current", ConfigMigrateBoot(Second)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Second, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator,
			[ConfigTransitionPresentTarget(Path, NewSource), ConfigTransitionPresentTarget(Second, NewSource)], Bundle), "committed_new"))
		ConfigSchemaSettleOwnedSource.DefineProp("Call", {Call: _CMJ_OwnedPartialFault.Bind(Fault)})
		First := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual("retry", First["status"])
		AssertEqual(1, Fault.confirmed, "the first real native target must already be settled")
		AssertEqual(1, Fault.refused, "the second target must actually refuse after partial settlement")
		ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "absent"))
		Foreign := { kind: Bundle.kind, id: Bundle.id, tokens: Bundle.tokens, authorized: Bundle.authorized, shutdown_claimed: Bundle.shutdown_claimed }
		AssertEqual("fatal", ConfigTransitionRecoverOwned(Locator, Foreign)["status"], "a lookalike bundle cannot consume the observation")
		AssertEqual("fatal", ConfigTransitionRecoverOwned(Fixture.directory . "\foreign-paths.toml", Bundle)["status"], "a foreign locator cannot consume the observation")
		Assert(ConfigTransitionResultIs(ConfigTransitionRecoverOwned(Locator, Bundle), "absent"))
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		Assert(ConfigSchemaCanPrepareWrite(Path))
		Assert(ConfigSchemaCanPrepareWrite(Second))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource))
		AssertTrue(FSUtf8ExactMatches(Second, NewSource))
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigSchemaSettleOwnedSource, "Call")
			ConfigSchemaSettleOwnedSource.DeleteProp("Call")
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: partial native settlement retries all original targets", _CMJ_OwnedPartialRetry)

_CMJ_OwnedRecoveryProducer() {
	Fixture := _ScopeOwnerFixture('[llm]`nenabled = true`n'), Path := Fixture.path, Locator := Fixture.options["locator"], Bundle := 0
	NewSource := _CMJFixtureCurrentSource('[llm]`nenabled = false`n'), Invocations := { count: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(ConfigTransitionRecover, "Call"))
	try {
		Bundle := _ConfigWriteTerminalTryAcquire([Path, Locator])
		Assert(Bundle is Object)
		Assert(ConfigTransitionResultIs(ConfigTransitionCommitOwned(Locator, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle), "committed_new"))
		ConfigTransitionRecover.DefineProp("Call", {Call: (*) => (Invocations.count += 1, Map("status", "ok", "kind", "recovered_new"))})
		Refused := ConfigTransitionRecoverOwned(Locator, Bundle)
		AssertEqual("retry", Refused["status"])
		AssertEqual("recovery_native_owner_refused", Refused["kind"])
		AssertEqual(0, Invocations.count, "a foreign recovery callback cannot mint an actual-native observation")
		ConfigTransitionRecover.DeleteProp("Call")
		Assert(ConfigTransitionResultIs(ConfigTransitionInspect(Locator, ConfigTransitionProductionPort()), "ready"))
		Assert(ConfigTransitionResultIs(ConfigTransitionRecoverOwned(Locator, Bundle), "recovered_new"))
		Assert(_ConfigWriteTerminalRelease(Bundle)), Bundle := 0
		Assert(ConfigSchemaCanPrepareWrite(Path))
	} finally {
		if Object.Prototype.HasOwnProp.Call(ConfigTransitionRecover, "Call")
			ConfigTransitionRecover.DeleteProp("Call")
		if Bundle is Object {
			ConfigTransitionRollbackOwned(Locator, Bundle)
			_ConfigWriteTerminalRelease(Bundle)
		}
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config journal owned settlement: only the original recovery producer can mint its outcome", _CMJ_OwnedRecoveryProducer)
