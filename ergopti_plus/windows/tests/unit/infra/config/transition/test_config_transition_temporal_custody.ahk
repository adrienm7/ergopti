; tests/unit/infra/config/transition/test_config_transition_temporal_custody.ahk

; ==============================================================================
; MODULE: Config Transition Acquired-Read Temporal Custody
; DESCRIPTION:
; A real timer runs during the acquired native read of the recovery and of
; the guarded adapter: custody withdrawn during that read cannot acknowledge
; a snapshot, and cleanup retires the native owner after a body failure.
; ==============================================================================

#Requires AutoHotkey v2.0





; A real AHK timer withdraws custody while the unchanged Win32 reader owns
; its acquired handle. No port, read function or dispatcher is replaced here.
_CTWP_NativeReadCustodyTick(State) {
	if !State.active || State.observed || !FileReadActivityBusy(State.path)
		return
	try {
		Activity := _FileReadActivityState()
		for _, Reader in Activity.owners {
			if Reader.key != State.pathKey || Reader.handle == -1
				continue
			Identity := FSHandleSnapshot(Reader.handle)
			if !Identity.Get("ok", false)
				continue
			State.observed := true
			State.readerHandle := Reader.handle
			State.timerCritical := A_IsCritical
			if State.mode == "hash"
				CryptoSha256.DefineProp("Call", {Call: State.observer})
			else if State.mode == "port"
				State.port.DefineProp("__Item", {Get: State.observer})
			return
		}
	} catch as Err {
		State.failure := Err.Message
		State.active := false
	}
}


; These fixture-only helpers serve the two real acquired-read timer families.
; They do not grant production admission or replace the native journal ports.
_CTWP_TemporalDescriptorMatches(Left, Right) {
	if !(Left is Object) || !(Right is Object)
		return false
	LeftCount := 0, RightCount := 0
	for Name in ObjOwnProps(Left) {
		LeftCount += 1
		if !Object.Prototype.HasOwnProp.Call(Right, Name) || Left.%Name% != Right.%Name%
			return false
	}
	for Name in ObjOwnProps(Right)
		RightCount += 1
	return LeftCount == RightCount
}

_CTWP_TemporalRestoreDescriptor(Owner, Name, HadOriginal, Original, Observer, Field) {
	if !(Owner is Object)
		return
	HasCurrent := Object.Prototype.HasOwnProp.Call(Owner, Name)
	if !HasCurrent {
		if HadOriginal
			throw Error("The original acquired-read descriptor was withdrawn by another owner.")
		return
	}
	Current := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	if HadOriginal && _CTWP_TemporalDescriptorMatches(Current, Original)
		return
	Expected := {}, Expected.%Field% := Observer
	if !_CTWP_TemporalDescriptorMatches(Current, Expected)
		throw Error("A foreign acquired-read descriptor replacement is retained.")
	Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadOriginal
		Object.Prototype.DefineProp.Call(Owner, Name, Original)
	HasAfter := Object.Prototype.HasOwnProp.Call(Owner, Name)
	if HadOriginal {
		if !HasAfter || !_CTWP_TemporalDescriptorMatches(Object.Prototype.GetOwnPropDesc.Call(Owner, Name), Original)
			throw Error("Exact acquired-read descriptor restoration was not acknowledged.")
	} else if HasAfter
		throw Error("The acquired-read descriptor's original absence was not restored.")
}

_CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native, State, Timer,
		RestoreHash, RestorePort, PriorRetained, ReleaseOwner) {
	global _ConfigTransitionRetainedBarrier
	Receipt := {errors: State.restoreErrors.Clone(), resolved: false, ownerRetired: false, deleted: false,
		timerStopped: false, hashRestored: false, portRestored: false}
	Attempt(Phase, Operation) {
		try Operation.Call()
		catch as Failure
			Receipt.errors.Push({phase: Phase, failure: Failure})
	}
	StopTimer() {
		State.active := false
		SetTimer(Timer, 0)
		Receipt.timerStopped := true
	}
	RestoreHashOnce() {
		RestoreHash.Call()
		Receipt.hashRestored := true
	}
	RestorePortOnce() {
		RestorePort.Call()
		Receipt.portRestored := true
	}
	ResolveJournal() {
		if !Receipt.timerStopped || !Receipt.hashRestored || !Receipt.portRestored
			throw Error("Unsettled acquired-read callback cleanup retains its real journal.")
		if FileReadActivityBusy(Path) || !ConfigTransitionProductionPort(Native)
			throw Error("Actual acquired-read native ownership has not settled.")
		Inspected := ConfigTransitionInspect(PathsFile, Native)
		if ConfigTransitionResultIs(Inspected, "ready") {
			if !(Bundle is Object) || !_ConfigWriteTerminalTryAcquire([], Bundle)
				throw Error("The real acquired-read journal has no held native retirement owner.")
			Resolution := ConfigTransitionRollbackOwned(PathsFile, Bundle, Native)
			if !ConfigTransitionResultIs(Resolution, "recovered_old")
				throw Error("The actual acquired-read journal refused owned rollback.")
			Inspected := ConfigTransitionInspect(PathsFile, Native)
		}
		if !ConfigTransitionResultIs(Inspected, "absent")
			throw Error("The real acquired-read journal is unresolved before retirement.")
		if FSStrictExists(Path) && !FSUtf8ExactMatches(Path, OldSource)
			throw Error("A foreign acquired-read source is retained before retirement.")
		Receipt.resolved := true
	}
	RetireOwner() {
		global _ConfigTransitionRetainedBarrier
		if !Receipt.resolved {
			if Bundle is Object && !ConfigTransitionRetainBarrier(Bundle)
				throw Error("The genuine unresolved acquired-read barrier could not be retained.")
			return
		}
		if Bundle is Object && _ConfigWriteTerminalTryAcquire([], Bundle) {
			ReleaseOwner.Call()
		}
		if _ConfigWriteTerminalIsActive()
			throw Error("A real terminal barrier remains active before acquired-read file retirement.")
		if Bundle is Object && (_ConfigWriteLeaseSelectOwner(Bundle, Path) is Object
				|| _ConfigWriteLeaseSelectOwner(Bundle, PathsFile) is Object)
			throw Error("The acquired-read target or locator lease remains active.")
		Receipt.ownerRetired := true
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if Bundle is Object && _ConfigTransitionRetainedBarrier == Bundle
				_ConfigTransitionRetainedBarrier := PriorRetained
		} finally Critical(PreviousCritical)
	}
	RetainUnresolved() {
		if (!Receipt.resolved || !Receipt.ownerRetired) && Bundle is Object
				&& _ConfigWriteTerminalTryAcquire([], Bundle) && !ConfigTransitionRetainBarrier(Bundle)
			throw Error("The actual acquired-read cleanup debt could not retain its native barrier.")
	}
	RetireFiles() {
		if !Receipt.resolved || !Receipt.ownerRetired
			throw Error("Unresolved acquired-read files remain available for real recovery.")
		if !ConfigTransitionResultIs(ConfigTransitionInspect(PathsFile, Native), "absent")
			throw Error("A successor acquired-read journal is retained.")
		if DirExist(Dir) {
			; Only the two genuine file intentions can belong to this fixture.
			; Foreign entries and subdirectories prevent any destructive cleanup.
			loop files Dir . "\*", "FD" {
				if InStr(A_LoopFileAttrib, "D") || (A_LoopFileName != "config.toml"
						&& A_LoopFileName != "owned-native-repair.txt")
					throw Error("An unowned acquired-read directory entry is retained.")
			}
			if FSStrictExists(Path) && !FSUtf8ExactMatches(Path, OldSource)
				throw Error("A foreign acquired-read source remains after native release.")
			RepairPath := Dir . "\owned-native-repair.txt"
			if FSStrictExists(RepairPath) && !FSUtf8ExactMatches(RepairPath, "owned native repair output")
				throw Error("A foreign acquired-read repair file is retained.")
			if FSStrictExists(Path) && FSDeleteStrict(Path) != 1
				throw Error("The exact acquired-read source could not be retired.")
			if FSStrictExists(RepairPath) && FSDeleteStrict(RepairPath) != 1
				throw Error("The owned acquired-read repair file could not be retired.")
			DirDelete(Dir, false)
			if DirExist(Dir)
				throw Error("The actual acquired-read directory deletion was not acknowledged.")
		}
		Receipt.deleted := true
	}
	State.active := false
	for Pair in [["timer", StopTimer], ["hash", RestoreHashOnce], ["port", RestorePortOnce],
			["journal", ResolveJournal], ["owner", RetireOwner], ["retention", RetainUnresolved], ["files", RetireFiles]]
		Attempt(Pair[1], Pair[2])
	return Receipt
}

_CTWP_TemporalReport(Receipt, Primary, Family) {
	SecondaryCount := Receipt.errors.Length
	loop SecondaryCount {
		Secondary := Receipt.errors[A_Index]
		try _TestPrint("# ERGOPTI_ACQUIRED_READ_SECONDARY phase=" . Secondary.phase . "; message=" . Secondary.failure.Message)
		catch as ReportingFailure
			Receipt.errors.Push({phase: "secondary_report", failure: ReportingFailure})
	}
	try _TestPrint("# ERGOPTI_ACQUIRED_READ_CLEANUP family=" . Family
		. ";primary_present=" . (Primary is Object ? 1 : 0) . ";secondary_count=" . Receipt.errors.Length
		. ";resolved=" . (Receipt.resolved ? 1 : 0) . ";owner_retired=" . (Receipt.ownerRetired ? 1 : 0)
		. ";files_deleted=" . (Receipt.deleted ? 1 : 0))
	catch as ReportingFailure
		Receipt.errors.Push({phase: "cleanup_report", failure: ReportingFailure})
	if !(Primary is Object) && Receipt.errors.Length
		throw Receipt.errors[1].failure
}

_CTWP_NativeReadTemporalCustody(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("genuine-native-read-temporal-custody")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old actual timed recovery source")
	; 8 MiB keeps the native read across a timer tick (1 MiB sometimes missed it)
	; at a quarter of the cost of the former 32 MiB source.
	Padding := "x"
	loop 23
		Padding .= Padding
	NewSource := _CTWP_SchemaSource("new actual timed recovery source") . "# " . Padding . "`n"
	Padding := ""
	Native := ConfigTransitionProductionPort(), HashCallback := Native["hash"]
	Digest := CryptoSha256(NewSource), Bundle := false
	State := {path: Path, pathKey: FileReadActivityKey(Path), port: Native, mode: Mode,
		active: false, observed: false, readerHandle: -1, timerCritical: -1, observerCalls: 0, failure: ""}
	State.observer := Mode == "port" ? ((*) => (State.observerCalls += 1, HashCallback))
		: ((*) => (State.observerCalls += 1, Digest))
	Timer := _CTWP_NativeReadCustodyTick.Bind(State)
	HadHashCall := Object.Prototype.HasOwnProp.Call(CryptoSha256, "Call")
	HashDescriptor := HadHashCall ? CryptoSha256.GetOwnPropDesc("Call") : false
	HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
	PortDescriptor := HadPortItem ? Native.GetOwnPropDesc("__Item") : false
	State.restoreErrors := [], Primary := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	Restore() {
		First := false
		try RestoreHash()
		catch as Failure
			First := Failure
		try RestorePort()
		catch as Failure {
			if First is Object
				State.restoreErrors.Push({phase: "body_port_restore", failure: Failure})
			else
				First := Failure
		}
		if First is Object
			throw First
	}
	try {
		AssertEqual(0, A_IsCritical, "the genuine read timer subject requires interruptible native IO")
		AssertEqual(8, Native.Count, "the original canonical native callback class is the subject")
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile), BeforeWal := _CTWP_RawHex(WalPath)
		Facts := false
		; Eight genuine invocations bound timing variance. A missing acquired-read
		; timer interval is a failure, never a green skip or modeled observation.
		loop 8 {
			State.active := true
			SetTimer(Timer, 1)
			try Facts := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
			finally {
				State.active := false
				SetTimer(Timer, 0)
			}
			if State.observed
				break
		}
		Restore()
		AssertEqual("", State.failure, "actual timer observer failure is retained rather than swallowed")
		AssertTrue(State.observed, "an actual timer must run during the acquired native exact-read span")
		Assert(State.readerHandle != -1, "the timer observed an actual retained Win32 read handle")
		AssertEqual(0, State.timerCritical, "the original native read remains interruptible")
		AssertFalse(FileReadActivityBusy(Path), "actual native close retires the observed read activity")
		if Mode == "control" {
			Assert(Facts is Object, "the original unmodified acquired-read timer control issues genuine recovery facts")
			AssertEqual(OldSource, Facts.old.source)
			AssertEqual(NewSource, Facts.new.source)
		} else
			AssertFalse(Facts, "custody withdrawn during real IO cannot issue recovery facts")
		AssertEqual(0, State.observerCalls, "same-object ownership withdrawal must refuse before nested hash or port lookup dispatch")
		AssertEqual(BeforeWal, _CTWP_RawHex(WalPath))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource), "the exact genuine target bytes remain unchanged")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionNativeRecoveryImages(PathsFile, Path, Bundle)
		Assert(Repaired is Object, "repair of original descriptors restores actual native recovery facts")
		AssertEqual(OldSource, Repaired.old.source)
		AssertEqual(NewSource, Repaired.new.source)
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertTrue(FSUtf8ExactMatches(Path, OldSource))
		AssertFalse(FSStrictExists(WalPath))
	} catch as Failure {
		Primary := Failure
		throw Failure
	} finally {
		ReleaseOwned() {
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		}
		Receipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
			State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
		_CTWP_TemporalReport(Receipt, Primary, "recovery:" . Mode)
	}
}

for Mode in ["control", "hash", "port"]
	Test("config transition native recovery: genuine acquired-read timer custody " . Mode,
		_CTWP_NativeReadTemporalCustody.Bind(Mode))


; A real AHK timer withdraws custody while the unchanged Win32 reader owns
; its acquired handle. No port, read function or dispatcher is replaced here.
_CTWP_GuardedReadCustodyTick(State) {
	if !State.active || State.observed || !FileReadActivityBusy(State.path)
		return
	try {
		Activity := _FileReadActivityState()
		for _, Reader in Activity.owners {
			if Reader.key != State.pathKey || Reader.handle == -1
				continue
			Identity := FSHandleSnapshot(Reader.handle)
			if !Identity.Get("ok", false)
				continue
			State.observed := true
			State.readerHandle := Reader.handle
			State.timerCritical := A_IsCritical
			if State.mode == "port"
				State.port.DefineProp("__Item", {Get: State.observer})
			else if State.callback is Object
				State.callback.DefineProp("Call", {Call: State.observer})
			return
		}
	} catch as Err {
		State.failure := Err.Message
		State.active := false
	}
}

_CTWP_GuardedReadTemporalCustody(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("genuine-guarded-read-temporal-custody")
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("old actual timed recovery source")
	; 8 MiB keeps the native read across a timer tick (1 MiB sometimes missed it)
	; at a quarter of the cost of the former 32 MiB source.
	Padding := "x"
	loop 23
		Padding .= Padding
	NewSource := _CTWP_SchemaSource("new actual timed recovery source") . "# " . Padding . "`n"
	Padding := ""
	Native := ConfigTransitionProductionPort(), HashCallback := Native["hash"]
	TargetCallback := false
	switch Mode {
	case "hash": TargetCallback := CryptoSha256
	case "exists": TargetCallback := FSStrictExists
	case "read_bounded": TargetCallback := FSReadUtf8ExactBounded
	case "write_create_durable": TargetCallback := FSWriteCreateDurable
	}
	Digest := CryptoSha256(NewSource), Bundle := false
	State := {path: Path, pathKey: FileReadActivityKey(Path), port: Native, mode: Mode, callback: TargetCallback,
		active: false, observed: false, readerHandle: -1, timerCritical: -1, observerCalls: 0, failure: ""}
	State.observer := Mode == "port" ? ((*) => (State.observerCalls += 1, HashCallback))
		: ((*) => (State.observerCalls += 1, Mode == "hash" ? Digest : 1))
	Timer := _CTWP_GuardedReadCustodyTick.Bind(State)
	HadHashCall := TargetCallback is Object && Object.Prototype.HasOwnProp.Call(TargetCallback, "Call")
	HashDescriptor := HadHashCall ? TargetCallback.GetOwnPropDesc("Call") : false
	HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
	PortDescriptor := HadPortItem ? Native.GetOwnPropDesc("__Item") : false
	State.restoreErrors := [], Primary := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(TargetCallback, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	Restore() {
		First := false
		try RestoreHash()
		catch as Failure
			First := Failure
		try RestorePort()
		catch as Failure {
			if First is Object
				State.restoreErrors.Push({phase: "body_port_restore", failure: Failure})
			else
				First := Failure
		}
		if First is Object
			throw First
	}
	try {
		AssertEqual(0, A_IsCritical, "the genuine read timer subject requires interruptible native IO")
		AssertEqual(8, Native.Count, "the original canonical native callback class is the subject")
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile,
			[ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile), BeforeWal := _CTWP_RawHex(WalPath)
		Captured := _ConfigTransitionGuardedProductionPort(PathsFile, Bundle, [], true)
		Assert(Captured is Object && Captured.port is Map)
		AssertEqual(8, Captured.port.Count, "the actual guarded adapter forwards the complete native callback class")
		ProbePath := Dir . "\foreign-timer-probe.txt"
		Facts := false
		; Eight genuine invocations bound timing variance. A missing acquired-read
		; timer interval is a failure, never a green skip or modeled observation.
		loop 8 {
			State.active := true
			SetTimer(Timer, 1)
			try Facts := _ConfigTransitionReadSnapshot(Captured.port, Path)
			finally {
				State.active := false
				SetTimer(Timer, 0)
			}
			if State.observed
				break
		}
		if Mode != "control" {
			if Mode == "write_create_durable"
				AssertThrows(() => Captured.port[Mode].Call(ProbePath, "foreign timer output"))
			else if Mode == "read_bounded"
				AssertThrows(() => Captured.port[Mode].Call(WalPath, CONFIG_TRANSITION_MAX_WAL_BYTES))
			else if Mode == "exists"
				AssertThrows(() => Captured.port[Mode].Call(Path))
			else if Mode == "hash"
				AssertThrows(() => Captured.port[Mode].Call(NewSource))
			else
				AssertThrows(() => Captured.port["hash"].Call(NewSource))
		}
		Restore()
		AssertEqual("", State.failure, "actual timer observer failure is retained rather than swallowed")
		AssertTrue(State.observed, "an actual timer must run during the acquired native exact-read span")
		Assert(State.readerHandle != -1, "the timer observed an actual retained Win32 read handle")
		AssertEqual(0, State.timerCritical, "the original native read remains interruptible")
		AssertFalse(FileReadActivityBusy(Path), "actual native close retires the observed read activity")
		if Mode == "control" {
			AssertTrue(ConfigTransitionResultIs(Facts, "snapshot"), "the original guarded acquired-read control returns a genuine native snapshot")
			AssertEqual(NewSource, Facts["snapshot"]["content"])
		} else
			AssertFalse(ConfigTransitionResultIs(Facts, "snapshot"), "custody withdrawn during real IO cannot acknowledge a guarded snapshot")
		AssertEqual(0, State.observerCalls, "same-object ownership withdrawal must refuse before nested hash or port lookup dispatch")
		AssertFalse(FSStrictExists(ProbePath), "a withdrawn callback never creates foreign native output")
		AssertEqual(BeforeWal, _CTWP_RawHex(WalPath))
		AssertTrue(FSUtf8ExactMatches(Path, NewSource), "the exact genuine target bytes remain unchanged")
		AssertTrue(_ConfigWriteTerminalOwnsExact(Bundle, Path))
		Repaired := _ConfigTransitionReadSnapshot(Captured.port, Path)
		AssertTrue(ConfigTransitionResultIs(Repaired, "snapshot"), "exact descriptor repair restores the same actual guarded adapter")
		AssertEqual(NewSource, Repaired["snapshot"]["content"])
		AssertEqual(1, Captured.port["exists"].Call(Path), "repaired existence uses its actual native producer")
		AssertEqual(Digest, Captured.port["hash"].Call(NewSource), "repaired hash keeps the actual canonical native digest")
		AssertEqual(FSReadUtf8Exact(WalPath), Captured.port["read_bounded"].Call(WalPath, CONFIG_TRANSITION_MAX_WAL_BYTES),
			"repaired bounded read returns actual native WAL bytes")
		RepairPath := Dir . "\owned-native-repair.txt"
		AssertEqual(1, Captured.port["write_create_durable"].Call(RepairPath, "owned native repair output"),
			"repaired creation retains the actual durable native receipt")
		AssertEqual("owned native repair output", FSReadUtf8Exact(RepairPath))
		AssertEqual(1, Captured.port["delete"].Call(RepairPath))
		AssertFalse(FSStrictExists(RepairPath))
		RolledBack := ConfigTransitionRollbackOwned(PathsFile, Bundle)
		AssertTrue(ConfigTransitionResultIs(RolledBack, "recovered_old"))
		AssertTrue(FSUtf8ExactMatches(Path, OldSource))
		AssertFalse(FSStrictExists(WalPath))
	} catch as Failure {
		Primary := Failure
		throw Failure
	} finally {
		ReleaseOwned() {
			AssertTrue(_ConfigWriteTerminalRelease(Bundle))
		}
		Receipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
			State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
		_CTWP_TemporalReport(Receipt, Primary, "guarded:" . Mode)
	}
}

for Mode in ["control", "hash", "port", "exists", "read_bounded", "write_create_durable"]
	Test("config transition guarded native adapter: genuine acquired-read timer custody " . Mode,
		_CTWP_GuardedReadTemporalCustody.Bind(Mode))

; A body error after a real committed journal must not destroy that journal
; before owned rollback, nor replace the exact original error object.
_CTWP_TemporalFailureRetirement(Mode) {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	Dir := _CTWP_NewDir("temporal-cleanup-primary-" . Mode)
	PathsFile := Dir . "\paths.toml", Path := Dir . "\config.toml"
	OldSource := _CTWP_SchemaSource("original temporal cleanup source")
	NewSource := _CTWP_SchemaSource("committed temporal cleanup source")
	ForeignSource := _CTWP_SchemaSource("independently written foreign cleanup source")
	Native := false, Bundle := false, HeldLock := false
	Primary := Error("exact owned body failure after actual journal commit")
	OuterPrimary := false, Caught := false, Completed := false
	Hits := {count: 0}, State := {active: false, restoreErrors: []}
	State.observer := (*) => (Hits.count += 1, 0)
	OtherObserver := (*) => (Hits.count += 1, 0)
	Timer := (*) => 0
	HadHashCall := Object.Prototype.HasOwnProp.Call(CryptoSha256, "Call")
	HashDescriptor := HadHashCall ? Object.Prototype.GetOwnPropDesc.Call(CryptoSha256, "Call") : false
	HadPortItem := false, PortDescriptor := false
	RestoreHash() {
		_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, State.observer, "Call")
	}
	RestorePort() {
		_CTWP_TemporalRestoreDescriptor(Native, "__Item", HadPortItem, PortDescriptor, State.observer, "Get")
	}
	ReleaseOwned() {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
	CloseLock() {
		if HeldLock is File {
			HeldLock.Close()
			HeldLock := false
		}
	}
	RepairControlledDescriptor() {
		if Mode == "descriptor_refusal"
			_CTWP_TemporalRestoreDescriptor(CryptoSha256, "Call", HadHashCall, HashDescriptor, OtherObserver, "Call")
		else
			RestoreHash()
	}
	RepairControlledSource() {
		if Mode == "foreign_source" && FSStrictExists(Path) {
			if !FSUtf8ExactMatches(Path, ForeignSource)
				throw Error("The exact independently written foreign subject was superseded; retaining it.")
			AssertEqual(1, FSWriteDurable(Path, NewSource))
		}
	}
	try {
		Native := ConfigTransitionProductionPort()
		HadPortItem := Object.Prototype.HasOwnProp.Call(Native, "__Item")
		PortDescriptor := HadPortItem ? Object.Prototype.GetOwnPropDesc.Call(Native, "__Item") : false
		AssertEqual(1, FSWriteCreateDurable(Path, OldSource))
		AssertEqual("current", ConfigMigrateBoot(Path)["status"])
		Bundle := _ConfigWriteTerminalTryAcquire([PathsFile, Path])
		Assert(Bundle is Object)
		Committed := ConfigTransitionCommitOwned(PathsFile, [ConfigTransitionPresentTarget(Path, NewSource)], Bundle)
		AssertTrue(ConfigTransitionResultIs(Committed, "committed_new"))
		WalPath := ConfigTransitionWalPath(PathsFile)
		AssertTrue(FSStrictExists(WalPath))
		try {
			if Mode == "body" || Mode == "descriptor_refusal" {
				CryptoSha256.DefineProp("Call", {Call: State.observer})
				Native.DefineProp("__Item", {Get: State.observer})
				if Mode == "descriptor_refusal"
					CryptoSha256.DefineProp("Call", {Call: OtherObserver})
			} else if Mode == "locked_rollback" {
				HeldLock := FileOpen(Path, "r-rwd", "UTF-8")
				Assert(HeldLock is File, "the real non-sharing handle must be held before the native rollback attempt")
			} else if Mode == "foreign_source" {
				AssertEqual(1, FSWriteDurable(Path, ForeignSource))
				AssertTrue(FSUtf8ExactMatches(Path, ForeignSource))
			} else
				throw Error("Unknown genuine temporal cleanup regression subject.")
			throw Primary
		} catch as Failure {
			Caught := Failure
		} finally {
			FirstReceipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(FirstReceipt, Caught, "regression:" . Mode)
		}
		Assert(Caught == Primary, "real cleanup must preserve the exact original primary error object")
		AssertEqual(0, Hits.count, "genuine descriptor refusals and repair observe no foreign callback")
		AssertTrue(FirstReceipt.portRestored, "the original port descriptor is attempted independently of the hash repair")
		if Mode == "body" {
			AssertEqual(0, FirstReceipt.errors.Length)
			AssertTrue(FirstReceipt.resolved && FirstReceipt.ownerRetired && FirstReceipt.deleted)
			AssertFalse(FSStrictExists(WalPath))
			AssertFalse(DirExist(Dir))
			AssertFalse(_ConfigWriteTerminalIsActive())
		} else {
			AssertTrue(FirstReceipt.errors.Length > 0, "real refusal remains a visible secondary cleanup failure")
			AssertFalse(FirstReceipt.resolved)
			AssertFalse(FirstReceipt.ownerRetired)
			AssertFalse(FirstReceipt.deleted)
			AssertTrue(FSStrictExists(WalPath), "the actual unresolved journal survives the failed cleanup")
			AssertTrue(_ConfigWriteTerminalTryAcquire([], Bundle))
			Assert(ConfigTransitionRetainedBarrier() == Bundle, "cleanup retains only the genuine acquired native bundle")
			if Mode == "descriptor_refusal" {
				AssertFalse(FirstReceipt.hashRestored)
				Current := Object.Prototype.GetOwnPropDesc.Call(CryptoSha256, "Call")
				Assert(Current.Call == OtherObserver, "the different exact descriptor is left untouched until its own explicit repair")
			} else if Mode == "foreign_source"
				AssertTrue(FSUtf8ExactMatches(Path, ForeignSource), "owned rollback refuses to replace the independent foreign source")
			CloseLock()
			RepairControlledDescriptor()
			RepairControlledSource()
			State.restoreErrors := []
			Repaired := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(Repaired, Primary, "regression:" . Mode . ":repair")
			AssertEqual(0, Repaired.errors.Length)
			AssertTrue(Repaired.resolved && Repaired.ownerRetired && Repaired.deleted)
			AssertFalse(FSStrictExists(WalPath))
			AssertFalse(DirExist(Dir))
			AssertFalse(_ConfigWriteTerminalIsActive())
			Assert(ConfigTransitionRetainedBarrier() == PriorRetained)
			AssertEqual(0, Hits.count)
		}
		Completed := true
	} catch as Failure {
		OuterPrimary := Failure
		throw Failure
	} finally {
		if !Completed {
			PreCleanupErrors := []
			for Pair in [["close_lock", CloseLock], ["repair_descriptor", RepairControlledDescriptor],
					["restore_port", RestorePort], ["repair_source", RepairControlledSource]] {
				try Pair[2].Call()
				catch as Failure
					PreCleanupErrors.Push({phase: Pair[1], failure: Failure})
			}
			State.restoreErrors := PreCleanupErrors
			LastReceipt := _CTWP_TemporalCleanup(Dir, PathsFile, Path, OldSource, Bundle, Native,
				State, Timer, RestoreHash, RestorePort, PriorRetained, ReleaseOwned)
			_CTWP_TemporalReport(LastReceipt, OuterPrimary, "regression:" . Mode . ":outer_failure")
		}
	}
}
for Mode in ["body", "descriptor_refusal", "locked_rollback", "foreign_source"]
	Test("config transition temporal cleanup: actual body primary and native retirement " . Mode,
		_CTWP_TemporalFailureRetirement.Bind(Mode))
