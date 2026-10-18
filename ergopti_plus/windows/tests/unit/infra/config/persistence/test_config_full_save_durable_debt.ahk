; tests/unit/infra/config/persistence/test_config_full_save_durable_debt.ahk

; ==============================================================================
; MODULE: Config Full Save Durable Debt
; DESCRIPTION:
; Native durable debt is reconciled only by the genuine default full save:
; conflicts keep both sides, copied owners and supplied producers cannot
; settle it, and the coordinator observers are refused.
; ==============================================================================

#Requires AutoHotkey v2.0





; These subjects use the real default collector, renderer, native writer and
; final acknowledgement. Only the candidate's logical owner is withdrawn.
_CFGFS_DurableDebtFixture(Subject) {
	global Features, _LLM_Menu_Loaded, _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	PreviousFeatures := Features, HadLoaded := IsSet(_LLM_Menu_Loaded)
	PreviousLoaded := HadLoaded ? _LLM_Menu_Loaded : false
	PreviousRejected := _ConfigBootRejectedOverrides, PreviousOutdated := _ConfigBootOutdatedEntries
	Dir := A_Temp . "\ergopti-native-fullsave-debt-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	try {
		Features := ManifestBuildFeaturesMap()
		_LLM_Menu_Loaded := false
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		_CFGFS_Prepare(Path)
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, _CFGFS_Timer), "the actual default full save establishes a genuine current native source")
		AssertTrue(FSStrictExists(Path))
		Subject.Call(Path)
	} finally {
		Features := PreviousFeatures
		_LLM_Menu_Loaded := HadLoaded ? PreviousLoaded : unset
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigBootOutdatedEntries := PreviousOutdated
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		DirDelete(Dir, true)
	}
}

_CFGFS_CreateActualDurableDebt(Path, Updates, ExistingOwner := 0) {
	State := { allowed: true, publications: 0 }
	Plan := { updates: Updates,
		admission: () => State.allowed,
		finalize: () => (State.allowed := false, true),
		publish: () => State.publications += 1 }
	AssertFalse(ConfigCommitBuilt(Path, "the native debt regression", () => Plan, 0, (*) => true, ExistingOwner), "actual durable success followed by logical withdrawal must refuse")
	AssertEqual(0, State.publications, "the withdrawn runtime candidate is never published")
	AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
	AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(), "private debt plus genuine mandatory pending intent requires orderly shutdown retention")
	AssertFalse(ConfigSchemaCanPrepareWrite(Path), "ordinary writes cannot borrow reconciliation permission")
}

_CFGFS_DebtMatchingDefaultFullSave(Path) {
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	AssertContains(Before, 'retained = "native"', "the actual native write reached disk before logical withdrawal")
	AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
	AssertEqual(Before, FSReadUtf8Exact(Path), "genuine reconciliation preserves every exact durable byte")
	AssertEqual(BeforeTime, FileGetTime(Path, "M"), "source-preserving acknowledgement never replaces the target")
	AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
	AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention(), "settled intent restores the ordinary bounded shutdown policy")
	AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation)
	AssertFalse(_ConfigFullSaveHasPending())
}
Test("config full save: genuine default native noop reconciles matching durable debt (config-full-save-debt-matching)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtMatchingDefaultFullSave))

_CFGFS_DebtConflictRetainsBothAndCanRetry(Path) {
	global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
	OldLevel := LOGGER_MIN_LEVEL
	DiskLevel := OldLevel == "DEBUG" ? "INFO" : "DEBUG"
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "script", Key: "log_level", Value: DiskLevel }])
	Before := FSReadUtf8Exact(Path)
	try {
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer), "conflicting RAM cannot overwrite retained durable authority")
		AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(OldLevel, LOGGER_MIN_LEVEL, "blocked reconciliation never silently chooses disk over RAM")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertTrue(_ConfigFullSaveHasPending(), "the mandatory accepted request remains represented")
		AssertTrue(_ConfigFullSaveCoordinator().committed_generation < Generation)
		; An external configuration editor can restore the retained runtime choice;
		; ordinary menu writers correctly remain blocked by the durable debt.
		DiskLine := 'log_level = "' . DiskLevel . '"' . "`n"
		RepairLine := OldLevel == LOGGER_DEFAULT_LEVEL ? ""
			: 'log_level = "' . OldLevel . '"' . "`n"
		AssertContains(Before, DiskLine, "the independently authored physical row identifies the user's edit")
		Repaired := StrReplace(Before, DiskLine, RepairLine, true)
		AssertFalse(Repaired == Before)
		AssertTrue(FSWriteDurable(Path, Repaired), "the real external-file edit preserves every other source byte")
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(OldLevel, LOGGER_MIN_LEVEL, "the genuine retry does not mutate the retained runtime authority")
		AssertEqual(Repaired, FSReadUtf8Exact(Path))
	} finally LOGGER_MIN_LEVEL := OldLevel
}
Test("config full save: conflicting durable debt retains bytes and mandatory request until actual reconciliation (config-full-save-debt-conflict)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtConflictRetainsBothAndCanRetry))

_CFGFS_DebtCannotUseSuppliedCollectorOrOwnerClone(Path) {
	_ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Before := FSReadUtf8Exact(Path), Calls := []
	AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave((*) => (Calls.Push("writer"), true), _CFGFS_Timer, 0, () => (Calls.Push("collector"), [])))
	AssertEqual(0, Calls.Length, "supplied producers are refused before invocation")
	Owner := _ConfigWriteLeaseTryAcquire(Path, "native-debt-clone-control")
	AssertTrue(Owner is Object)
	try {
		Clone := { key: Owner.key, id: Owner.id, kind: Owner.kind }
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Clone), "same-id cloned native owner cannot settle private debt")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner), "the exact genuine owner retains the real positive route")
	} finally _ConfigWriteLeaseRelease(Owner)
}
Test("config full save: copied ownership and supplied producers cannot settle native debt (config-full-save-debt-identity)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtCannotUseSuppliedCollectorOrOwnerClone))

; The real default collector enumerates the native metrics filter Map. This
; fixture uses that actual callback boundary without supplying a replacement
; collector, renderer, schema owner or acknowledgement.
_CFGFS_DebtObservedFilterMap(Source, Actor) {
	Observed := _CFGFS_DebtObservedFilters()
	Observed.CaseSense := Source.CaseSense
	Observed.Actor := Actor
	for Proc, Value in Source
		Observed[Proc] := Value
	return Observed
}
class _CFGFS_DebtObservedFilters extends Map {
	Actor := 0
	__Enum(VarCount) {
		Next := super.__Enum(VarCount), First := true
		Enumerate(&Proc, &Value) {
			if First {
				First := false
				this.Actor.Call()
			}
			return Next(&Proc, &Value)
		}
		return Enumerate
	}
}

_CFGFS_DebtAcknowledgesOnlyCapturedGeneration(Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	OriginalFilters := MetricsFilters.disabled_apps
	Before := FSReadUtf8Exact(Path)
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters,
			() => _ConfigFullSaveRequest(true, Path))
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation,
			"the real collector's newer request cannot be acknowledged by the captured earlier proof")
		AssertEqual(Generation + 1, _ConfigFullSaveCoordinator().requested_generation)
		AssertTrue(_ConfigFullSaveHasPending())
		AssertEqual(Before, FSReadUtf8Exact(Path))
		MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigFullSaveHasPending(), "the genuine later drain owns its own newer generation")
	} finally MetricsFilters.disabled_apps := OriginalFilters
}
Test("config full save: real collector cannot over-ack newer requests while reconciling native debt (config-full-save-debt-generation)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtAcknowledgesOnlyCapturedGeneration))

_CFGFS_DebtAppearingInsideDefaultCollectorWithdrawsCapturedAdmission(Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	Before := FSReadUtf8Exact(Path)
	NoopAdmission := ConfigMigrateBoot(Path, "capture_noop")
	WriteAdmission := ConfigMigrateBoot(Path, "capture_write", Before)
	AssertTrue(HasMethod(NoopAdmission, "Call"))
	AssertTrue(HasMethod(WriteAdmission, "Call"))
	OriginalFilters := MetricsFilters.disabled_apps
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters,
			() => _CFGFS_CreateActualDurableDebt(Path, [], _ConfigWriteLeaseCurrent(Path)))
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"actual late durable debt withdraws the ordinary full-save candidate before publication")
		AssertEqual(Before, FSReadUtf8Exact(Path), "the nested genuine native noop isolates debt withdrawal from source drift")
		AssertFalse(NoopAdmission.Call(Before, 1), "captured native noop permission observes later private debt")
		AssertFalse(WriteAdmission.Call(Before, 1, Before), "captured native replacement permission observes later private debt")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertTrue(_ConfigFullSaveHasPending())
		AssertTrue(_ConfigFullSaveCoordinator().committed_generation < Generation)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertFalse(_ConfigFullSaveHasPending())
	} finally MetricsFilters.disabled_apps := OriginalFilters
}
Test("config full save: debt added inside the actual collector withdraws captured noop and write guards (config-full-save-debt-late-withdrawal)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtAppearingInsideDefaultCollectorWithdrawsCapturedAdmission))

_CFGFS_GenuineCoordinatorObserver(Name, Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	State := _ConfigFullSaveCoordinator()
	Descriptor := Object.Prototype.GetOwnPropDesc.Call(State, Name)
	Original := Descriptor.Value, Hits := { count: 0 }, OriginalFilters := MetricsFilters.disabled_apps
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	Committed := State.committed_generation, Settled := State.settled_generation
	Owner := _ConfigWriteLeaseTryAcquire(Path, "actual coordinator purity subject")
	AssertTrue(Owner is Object)
	Observe() {
		State.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
	}
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters, Observe)
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Owner),
			"the actual default collector cannot acknowledge matching native debt through a changed coordinator getter")
		AssertFalse(FSNativeAcknowledge(() => _ConfigFullSaveCoordinatorDataAdmitted(State)),
			"the actual current native acknowledgement refuses the same genuine descriptor")
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"private actual accepted mandatory request plus debt survives malformed public metadata without getter execution")
		AssertEqual(0, Hits.count, "no public coordinator getter executes from the native final predicate or held-debt query")
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path), "false acknowledgment preserves the exact native publication debt")
		AssertEqual(Generation, State.requested_generation, "the actually accepted captured generation remains pending")
		for Pair in [["committed_generation", Committed], ["settled_generation", Settled]] {
			if Pair[1] == Name
				AssertEqual(Pair[2], Descriptor.Value, "the original scalar acknowledgment image remains retained")
			else
				AssertEqual(Pair[2], Object.Prototype.GetOwnPropDesc.Call(State, Pair[1]).Value,
					"the other actual generation remains unacknowledged")
		}
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner),
			"exact original descriptor repair admits the actual default collector/rendered strict native noop")
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Generation, State.committed_generation), AssertEqual(Generation, State.settled_generation)
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
}
for Name in ["bound_path_key", "committed_generation", "settled_generation"]
	Test("config full save: actual matching debt noop refuses genuine coordinator observer " . Name,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_GenuineCoordinatorObserver.Bind(Name)))

_CFGFS_ActualIntentSurvivesPublicCoordinatorReplacement(Path) {
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Original := _ConfigFullSaveCoordinator(), Before := FSReadUtf8Exact(Path)
	Replacement := { requested_generation: 0, committed_generation: 0,
		settled_generation: 0, terminal_required_generation: 0, bound_path: "",
		bound_path_key: "", reload_required: false, timer_armed: false, reported_failure_generation: 0 }
	Owner := _ConfigWriteLeaseTryAcquire(Path, "actual coordinator replacement subject")
	AssertTrue(Owner is Object)
	try {
		_ConfigFullSaveCoordinator(Replacement)
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"valid zero public replacement cannot hide the actual original accepted request/debt evidence")
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Owner),
			"a new public data object never inherits the original genuine accepted request owner")
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(0, Replacement.committed_generation), AssertEqual(0, Replacement.settled_generation)
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner), "exact original state repair admits actual native matching-source settlement")
		AssertEqual(Generation, Original.committed_generation), AssertEqual(Generation, Original.settled_generation)
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertEqual(Before, FSReadUtf8Exact(Path))
	} finally {
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
}
Test("config full save: actual native intent survives a valid zero public coordinator replacement",
	_CFGFS_DurableDebtFixture.Bind(_CFGFS_ActualIntentSurvivesPublicCoordinatorReplacement))

_CFGFS_ActualTerminalDebtCannotLookSettled(Mode, Path) {
	global CONFIG_SAVE_FAILED
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Original := _ConfigFullSaveCoordinator(), Before := FSReadUtf8Exact(Path)
	BeforeTime := FileGetTime(Path, "M"), Hits := { count: 0 }
	Descriptor := Object.Prototype.GetOwnPropDesc.Call(Original, "requested_generation")
	Committed := Original.committed_generation
	Settled := Original.settled_generation, Required := Original.terminal_required_generation
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object, "the actual terminal issuer owns the native configuration path")
	Repair() {
		Original.DefineProp("requested_generation", Descriptor)
		Original.settled_generation := Settled
		Original.terminal_required_generation := Required
		_ConfigFullSaveCoordinator(Original)
	}
	try {
		switch Mode {
		case "replacement":
			_ConfigFullSaveCoordinator({ requested_generation: 0, committed_generation: 0,
				settled_generation: 0, terminal_required_generation: 0, bound_path: "",
				bound_path_key: "", reload_required: false, timer_armed: false, reported_failure_generation: 0 })
		case "scalar":
			Original.settled_generation := Generation
			Original.terminal_required_generation := 0
		case "getter":
			Original.DefineProp("requested_generation", { Get: (*) => (Hits.count += 1, Generation) })
		}
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"the real accepted request and real native debt survive misleading public terminal metadata")
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, 0, _CFGFS_Timer),
			"the actual shutdown drain cannot report settled or optional abandonment for retained mandatory native debt")
		Token := _ConfigWriteLeaseSelectOwner(Bundle, Path)
		AssertTrue(Token is Object)
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer, Token),
			"the actual default drain cannot turn false public settlement into CONFIG_SAVE_OK")
		AssertFalse(_ConfigFullSaveAbandonThrough(Generation),
			"the actual optional abandonment owner retains this accepted mandatory native debt")
		AssertEqual(0, Hits.count, "no misleading coordinator getter is invoked by pending, shutdown or abandonment checks")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path)), AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(Committed, Object.Prototype.GetOwnPropDesc.Call(Original, "committed_generation").Value)
		Repair()
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, 0, _CFGFS_Timer),
			"exact genuine metadata repair permits the actual default collector and strict native noop settlement")
		AssertEqual(Generation, Original.committed_generation), AssertEqual(Generation, Original.settled_generation)
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		Original.DefineProp("requested_generation", Descriptor)
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
for Mode in ["replacement", "scalar", "getter"]
	Test("config full save: genuine terminal debt cannot look settled through public coordinator " . Mode,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_ActualTerminalDebtCannotLookSettled.Bind(Mode)))

_CFGFS_GenuineDefaultDrainCoordinatorObserver(Name, Path) {
	global MetricsFilters, CONFIG_SAVE_FAILED, CONFIG_SAVE_OK
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	State := _ConfigFullSaveCoordinator(), Descriptor := Object.Prototype.GetOwnPropDesc.Call(State, Name)
	Original := Descriptor.Value, Hits := { count: 0 }, OriginalFilters := MetricsFilters.disabled_apps
	Committed := State.committed_generation, Settled := State.settled_generation
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	Getter := (*) => (Hits.count += 1, Original)
	Observe() {
		State.DefineProp(Name, { Get: Getter })
	}
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters, Observe)
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"actual default drain and its real retry tail refuse the genuine collector-withdrawn coordinator")
		AssertTrue(_ConfigFullSaveHasPending(), "malformed actual metadata cannot prove absence of the retained obligation")
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertFalse(_ConfigArmFullSaveRetry(-100, _CFGFS_Timer), "retry must refuse before reading the same malformed genuine counters")
		AssertFalse(_ConfigFullSaveAcknowledge(Generation), "actual generation acknowledgement refuses before counter getter execution")
		AssertFalse(_ConfigFullSaveRejectExact(Generation), "failure resolution must not select disk or retire accepted native debt through corrupted metadata")
		AssertEqual(0, Hits.count, "default drain, pending query, retry, acknowledgement and failure policy execute no coordinator observer")
		for Pair in [["committed_generation", Committed], ["settled_generation", Settled]] {
			CurrentDescriptor := Object.Prototype.GetOwnPropDesc.Call(State, Pair[1])
			if Pair[1] == Name {
				AssertFalse(CurrentDescriptor.HasOwnProp("Value"), "the withdrawn actual getter descriptor was never replaced with acknowledged data")
				AssertTrue(CurrentDescriptor.Get == Getter, "the exact independently installed getter descriptor remains uncalled and unmodified")
				AssertEqual(Pair[2], Descriptor.Value, "the independently captured original generation scalar remains retained for exact repair")
			} else {
				AssertTrue(CurrentDescriptor.HasOwnProp("Value"))
				AssertEqual(Pair[2], CurrentDescriptor.Value, "the other actual generation remains unacknowledged")
			}
		}
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path)), AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		State.DefineProp(Name, Descriptor), MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"exact original descriptor repair permits actual default native noop debt closure and captured generation acknowledgement")
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Generation, State.committed_generation), AssertEqual(Generation, State.settled_generation)
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
	}
}
for Name in ["bound_path_key", "committed_generation", "settled_generation"]
	Test("config full save: genuine default drain and retry tail refuse actual coordinator observer " . Name,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_GenuineDefaultDrainCoordinatorObserver.Bind(Name)))

; The same genuine readonly constructor was known before this helper ran.
_CFGFS_KnownCurrentSourceCompletesActualBoot() {
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Dir := A_Temp . "\ergopti-fullsave-known-current-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[private]`nkeep = 42`n"
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Prepared := ConfigSchemaPrepareSource(Path)
		AssertEqual("current", Prepared["status"]), AssertEqual(1, Prepared["read_only"])
		AssertTrue(ConfigMigrateBoot(Path, "known"))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "real readonly preparation does not complete native Boot")
		_CFGFS_Prepare(Path)
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "the same known source now completed genuine default Boot")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "real startup preserves the complete independently authored current image")
		_CFGFS_Prepare(Path)
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "already booted current source is reused without a second Boot")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		_CFGFS_RestoreRuntime(Runtime), _ConfigFullSaveCoordinator(Coordinator)
		DirDelete(Dir, true)
	}
}
Test("config full save fixture: known readonly current source completes actual default Boot once", _CFGFS_KnownCurrentSourceCompletesActualBoot)

_CFGFS_ExplicitReadonlyKeepsPreBootWriterRefusal() {
	global CONFIG_SAVE_FAILED, _CFGFS_CollectCalls, _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Dir := A_Temp . "\ergopti-fullsave-preboot-refusal-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[private]`nkeep = 42`n"
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		_CFGFS_Prepare(Path, true, false, false)
		AssertTrue(ConfigMigrateBoot(Path, "known"))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "explicit readonly custody does not manufacture native READY")
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_CollectCalls), AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(FSUtf8ExactMatches(Path, Source), "the actual pre-Boot writer refusal retains all original bytes")
	} finally {
		_CFGFS_RestoreRuntime(Runtime), _ConfigFullSaveCoordinator(Coordinator)
		DirDelete(Dir, true)
	}
}
Test("config full save fixture: explicit readonly source retains real pre-Boot writer refusal", _CFGFS_ExplicitReadonlyKeepsPreBootWriterRefusal)

; Temporary qualification observation after the real native Boot result. It
; never acquires, clears, repairs or replaces any native/source/writer owner.
_CFGFS_TraceActualBootRefusal(Boot) {
	global TEST_RESULTS_FILE
	Status := Boot.Get("status", "missing")
	if !(Status is String) || !InStr("|absent|current|migrated|newer|invalid|unsupported|failed|", "|" . Status . "|")
		Status := "noncanonical"
	ReadOnly := Boot.Get("read_only", "missing")
	if !(ReadOnly is Integer)
		ReadOnly := "noninteger"
	Detail := Boot.Get("detail", "")
	; Only exact closed native policy messages are safe to publish. Other
	; messages may contain paths or source excerpts, so they stay unlogged.
	ClosedDetails := Map(
		"the actual boot registry owner refused before migration effects", true,
		"another configuration transaction owns the file", true,
		"the migration source/lease lost registry admission", true,
		"the original native source classification remains refused for this session", true,
		"the actual registry owner changed before native boot migration", true,
		"the completed native migration lost its exact boot source/registry handoff", true)
	if !(Detail is String) || !ClosedDetails.Has(Detail)
		Detail := "redacted noncanonical detail"
	TerminalActive := _ConfigWriteTerminalIsActive() ? 1 : 0
	Line := "# group1-actual-boot-refusal: status=" . Status
		. ";read_only=" . ReadOnly . ";detail=" . Detail
		. ";terminal_active=" . TerminalActive . "`r`n"
	; The real reporter's acquired results file is the reliable CI channel.
	; Missing observation never replaces the original native outcome/assertion.
	try _TestResultsWrite(TEST_RESULTS_FILE, Line)
}
