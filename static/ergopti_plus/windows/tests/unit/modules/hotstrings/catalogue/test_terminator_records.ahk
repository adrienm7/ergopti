; tests/unit/modules/hotstrings/catalogue/test_terminator_records.ahk

; ==============================================================================
; MODULE: Typed Custom Terminator Records
; DESCRIPTION:
; Custom terminators are typed records: the loader and cleanup recognise
; foreign records, a fresh record keeps its intent, and canonical scalars
; keep their precedence.
; ==============================================================================

#Requires AutoHotkey v2.0





_HTR_Source() {
	return '[private]`ncredential = "keep"`n'
		. '[["hotstrings"."terminators"]] # owned table array`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`nmetadata = { future = "keep", count = 7 }`n'
		. '[[hotstrings.terminators]]`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n'
		. '[[foreign.rows]]`nvalue = "never alter" # foreign comment`n'
}

_HTR_WithRuntime(Body) {
	global _HotstringsTerminatorRecords, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := { Owner: _HotstringsTerminatorRecords, Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters, EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS }
	try {
		_HotstringsTerminatorRecords := 0
		_HotstringsWordDelimiters := "!", _HotstringsConsumedDelimiters := "!"
		return Body.Call()
	} finally {
		_HotstringsTerminatorRecords := Saved.Owner
		_HotstringsWordDelimiters := Saved.Word
		_HotstringsConsumedDelimiters := Saved.Consumed
		HSE_WORD_TERMINATORS := Saved.EngineWord
		HSE_CONSUMED_DELIMITERS := Saved.EngineConsumed
	}
}

_HTR_BootProjectionBody() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	AssertEqual(true, HotstringsTerminatorRecordsInit(_HTR_Source()))
	AssertEqual("!¤😀", HotstringsGetWordDelimiters(), "the actual consumer must publish both admitted scalars")
	AssertEqual("!¤", HotstringsGetConsumedDelimiters(), "only the independently consumed record joins the consumed set")
	AssertEqual("!", _HotstringsWordDelimiters, "record loading must preserve the historical word preference")
	AssertEqual("!", _HotstringsConsumedDelimiters, "record loading must preserve the historical consumed preference")
}
_HTR_BootProjection() {
	_HTR_WithRuntime(_HTR_BootProjectionBody)
}
Test("terminator-records: actual boot consumer projects AOT and Unicode without changing string controls", _HTR_BootProjection)

_HTR_InlineRecords() {
	InlineRecordSource := 'hotstrings.terminators = [{ key = "upper", char = "A", label = "Upper", consume = false }, { key = "lower", char = "a", label = "Lower", consume = true }]`n'
	Resolved := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(InlineRecordSource))
	AssertEqual(2, Resolved.Records.Length, "case-sensitive scalar identity must match the shared catalogue")
	AssertEqual("A", Resolved.Records[1].Char)
	AssertEqual("a", Resolved.Records[2].Char)
	AssertEqual(0, Resolved.Rejected.Length)
}
Test("terminator-records: actual typed inline list preserves case-sensitive scalar identities", _HTR_InlineRecords)

_HTR_InvalidRecords() {
	InvalidRecordSource := 'hotstrings.terminators = ['
		. '{ key = "space", char = "¤", label = "Builtin", consume = false },'
		. '{ key = "two", char = "xy", label = "Two", consume = false },'
		. '{ key = "integer", char = "¤", label = "Integer", consume = 1 },'
		. '{ key = "duplicate_char", char = " ", label = "Space", consume = false },'
		. '{ key = "good", char = "¤", label = "Good", consume = true },'
		. '{ key = "good", char = "😀", label = "Duplicate", consume = false }]`n'
	Resolved := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(InvalidRecordSource))
	AssertEqual(1, Resolved.Records.Length)
	AssertEqual("good", Resolved.Records[1].Key)
	AssertEqual(5, Resolved.Rejected.Length)
	for RejectedOrdinal, Reason in ["key_collision", "invalid_character", "invalid_consume", "character_collision", "key_collision"]
		AssertEqual(Reason, Resolved.Rejected[RejectedOrdinal]["reason"], "each independently invalid row must retain its refusal reason")
}
Test("terminator-records: actual reader quarantines invalid rows and retains the independent valid row", _HTR_InvalidRecords)

_HTR_InvalidScalar() {
	for InvalidScalar in ["", "ab", Chr(0xD800), Chr(0xDC00), Chr(0xD800) . "a", 0, []]
		AssertEqual(false, HotstringsTerminatorRecordCharacter(InvalidScalar))
	AssertEqual(true, HotstringsTerminatorRecordCharacter("😀"))
	AssertEqual(true, HotstringsTerminatorRecordCharacter("¤"))
}
Test("terminator-records: one exact scalar rejects truncated surrogate and malformed inputs", _HTR_InvalidScalar)

_HTR_DuplicateInitBody() {
	HotstringsTerminatorRecordsInit(_HTR_Source())
	AssertThrows(HotstringsTerminatorRecordsInit.Bind(""), "a second initializer cannot replace a live boot owner")
	AssertEqual("!¤😀", HotstringsGetWordDelimiters())
}
_HTR_DuplicateInit() {
	_HTR_WithRuntime(_HTR_DuplicateInitBody)
}
Test("terminator-records: explicit initialization rejects a second source owner", _HTR_DuplicateInit)

_HTR_Upsert() {
	Record := Map("key", "currency", "char", "§", "label", "Updated", "consume", TOML_Bool(false))
	Plan := HotstringsTerminatorRecordPlan(_HTR_Source(), Map("mode", "upsert", "record", Record))
	Document := TOML_ParseDocument(Plan.Content)
	AssertEqual("§", Document["hotstrings"]["terminators"][1]["char"])
	AssertEqual("keep", Document["hotstrings"]["terminators"][1]["metadata"]["future"])
	AssertEqual(7, Document["hotstrings"]["terminators"][1]["metadata"]["count"])
	AssertContains(Plan.Content, '[[foreign.rows]]`nvalue = "never alter" # foreign comment`n')
	AssertContains(Plan.Content, '[private]`ncredential = "keep"`n')
	AssertEqual(2, Plan.Settings.Records.Length)
}
Test("terminator-records: editing an actual AOT record preserves unknown metadata and foreign spans", _HTR_Upsert)

_HTR_SiblingCollision() {
	Record := Map("key", "currency", "char", "😀", "label", "Collision", "consume", TOML_Bool(false))
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "upsert", "record", Record)), "an earlier row must not steal an admitted later sibling scalar")
}
Test("terminator-records: an upsert cannot silently quarantine a later admitted sibling", _HTR_SiblingCollision)

_HTR_Remove() {
	RemovalSource := _HTR_Source() . '[[hotstrings.terminators]]`nkey = "old_bad"`nchar = "zz"`nlabel = "Keep quarantined"`nconsume = false`nunknown = "retain"`n'
	Plan := HotstringsTerminatorRecordPlan(RemovalSource, Map("mode", "remove", "key", "currency"))
	Document := TOML_ParseDocument(Plan.Content)
	AssertEqual(2, Document["hotstrings"]["terminators"].Length)
	AssertEqual("smile", Document["hotstrings"]["terminators"][1]["key"])
	AssertEqual("retain", Document["hotstrings"]["terminators"][2]["unknown"])
	AssertEqual(1, Plan.Settings.Records.Length)
	AssertEqual("never alter", Document["foreign"]["rows"][1]["value"])
}
Test("terminator-records: removing one admitted record retains quarantined rows and foreign tables", _HTR_Remove)

_HTR_StateBody() {
	global _HotstringsTerminatorRecords, _HotstringsWordDelimiters
	Plan := HotstringsTerminatorRecordPlan(_HTR_Source(), Map("mode", "state", "key", "currency", "enabled", false))
	_HotstringsTerminatorRecords := Plan.Settings
	_HotstringsWordDelimiters := "!¤"
	AssertEqual("!😀", HotstringsGetWordDelimiters(), "a disabled record owns its scalar even in the older string")
	AssertEqual("!", HotstringsGetConsumedDelimiters())
	AssertEqual("!¤", _HotstringsWordDelimiters, "effective record projection must not rewrite historical preferences")
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "state", "key", "currency", "enabled", "false")))
}
_HTR_State() {
	_HTR_WithRuntime(_HTR_StateBody)
}
Test("terminator-records: exact record state projection and typed edit preserve legacy strings", _HTR_State)

_HTR_ParentInlineEdit() {
	ParentFixtureSource := 'hotstrings = { terminators = [{ key = "one", char = "¤", label = "One", consume = false }], unknown = "keep" }`n'
	AssertEqual(1, HotstringsTerminatorRecordsResolve(TOML_ParseDocument(ParentFixtureSource)).Records.Length)
	ParentEdited := HotstringsTerminatorRecordPlan(ParentFixtureSource, Map("mode", "remove", "key", "one"))
	AssertEqual(0, TOML_ParseDocument(ParentEdited.Content)["hotstrings"]["terminators"].Length)
	AssertEqual("keep", TOML_ParseDocument(ParentEdited.Content)["hotstrings"]["unknown"])
	AssertContains(ParentEdited.Content, ' unknown = "keep" }`n', "an inline edit preserves the exact unrelated member and closure")
}
Test("terminator-records: actual inline parent removal preserves the independent foreign member", _HTR_ParentInlineEdit)

_HTR_Operation() {
	return Map("mode", "upsert", "record", Map("key", "section", "char", "§",
		"label", "Section", "consume", TOML_Bool(false)))
}

_HTR_WalLifecycle(Refuse) {
	; The actual journal classifies the same intended current source before boot.
	OriginalBody := _HTR_Source()
	Fixture := _ScopeOwnerFixture(OriginalBody)
	Source := Fixture.source
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, OnSuccess := 0, OnRefused := 0, Calls := 0
	Launch(Success, Borrowed, Refused) {
		Bundle := Borrowed, OnSuccess := Success, OnRefused := Refused
		Calls += 1
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		AssertEqual(OriginalBody, SubStr(Source, InStr(Source, "`n") + 1),
			"current positive fixture metadata preserves every original record/foreign byte")
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual(1, Calls, "actual durable publication must reach the reload admission")
		AssertEqual("pending", Receipt["status"], "durable write is not a runtime acknowledgement")
		AssertEqual(3, TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))["hotstrings"]["terminators"].Length)
		Assert(!_ConfigWriteLeaseTryAcquire(Fixture.path, "intruder"), "reload owns the configuration barrier")
		if Refuse {
			OnRefused.Call("controlled refusal")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "the genuine rollback must restore all original bytes")
			Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
			AssertEqual("pending", Receipt["status"], "settled refusal permits one new admitted retry")
			OnRefused.Call("controlled second refusal")
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
		} else {
			OnSuccess.Call()
			AssertEqual("committed", Receipt["status"], "only the actual replacement callback acknowledges runtime completion")
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: genuine WAL commit retains pending ownership until reload ACK", _HTR_WalLifecycle.Bind(false))
Test("terminator-records: genuine refused reload rolls back exact bytes and permits an admitted retry", _HTR_WalLifecycle.Bind(true))

_HTR_ForeignSource() {
	global _ConfigTransitionRetainedBarrier
	PriorRetained := _ConfigTransitionRetainedBarrier
	OriginalBody := _HTR_Source()
	Fixture := _ScopeOwnerFixture(OriginalBody)
	Source := Fixture.source
	Port := ConfigTransitionProductionPort(), NativeHash := Port["hash"]
	Changed := false, Foreign := Source . '# independently changed source`n'
	Bundle := 0, OnRefused := 0, Launches := 0
	Launch(Success, Borrowed, Refused) {
		Launches += 1, Bundle := Borrowed, OnRefused := Refused
		return true
	}
	Fixture.options["port"] := Port
	Fixture.options["reload"] := Launch
	TeardownPrimary := false
	try {
		AssertEqual(OriginalBody, SubStr(Source, InStr(Source, "`n") + 1),
			"the genuine current boot retains every original record and foreign byte")
		AssertTrue(ConfigTransitionProductionPort(Port), "the original native port owns the entire conflict scenario")
		Acquired := ConfigTransitionAcquireLifecycleBundle(Fixture.options["locator"], [Fixture.path], Port,
			Fixture.options.Get("acquire", 0), Fixture.options.Get("settle", 0))
		AssertTrue(ConfigTransitionResultIs(Acquired, "bundle_acquired"), "capture starts inside the actual lifecycle owner")
		Bundle := Acquired["bundle"]
		Captured := FSReadUtf8Exact(Fixture.path)
		AssertEqual(Source, Captured, "the real old file precedes the independent write")
		Candidate := HotstringsTerminatorRecordPlan(Captured, _HTR_Operation())
		Expected := ConfigTransitionExpectedOld(1, Captured, Port)
		AssertTrue(Expected is Map, "the unchanged native hash captures an actual source precondition")
		AssertEqual(NativeHash.Call(Source), Expected["hash"], "the captured digest belongs to the actual old bytes")
		AssertTrue(ConfigTransitionProductionPort(Port), "hash capture preserves the original native callback image")
		; This independent writer acts after actual capture and before real prepare.
		; No published WAL, native callback replacement or timing assumption is used.
		AssertTrue(FSWriteDurable(Fixture.path, Foreign))
		Changed := FSUtf8ExactMatches(Fixture.path, Foreign)
		Transition := ConfigTransitionCommitOwned(Fixture.options["locator"],
			[ConfigTransitionPresentTarget(Fixture.path, Candidate.Content, Expected)], Bundle, Port)
		AssertEqual(0, Launches, "a stale exact-source intent must refuse before reload admission")
		Assert(Changed, "the actual captured native hash precedes the independent source race")
		AssertEqual("retry", Transition["status"], "the real conditional journal refuses the detached stale candidate")
		AssertEqual("expected_old_conflict", Transition["kind"], "refusal is caused by the genuine captured source conflict")
		AssertEqual(Foreign, FSReadUtf8Exact(Fixture.path), "a foreign source wins before any replacement")
		AssertTrue(ConfigTransitionProductionPort(Port), "the refused candidate never revokes native authority")
		AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(Fixture.options["locator"], Port), "absent"),
			"conflict occurs before any actual WAL publication")
		AssertFalse(FileExist(ConfigTransitionWalPath(Fixture.options["locator"])), "no synthetic or prepared WAL is retained")
		Files := 0
		Loop Files Fixture.directory . "\*", "F" {
			Files += 1
			AssertEqual(Fixture.path, Fixture.directory . "\" . A_LoopFileName, "conflict creates no stage, backup or replacement file")
		}
		AssertEqual(1, Files, "only the independently changed original file remains")
		_ConfigWriteTerminalRelease(Bundle)
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object,
			"an absent WAL permits actual terminal-owner retirement")
		Bundle := 0
		; A fresh attempt goes through the untouched editor and its real reload port.
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual(1, Launches, "the genuine editor retry reaches reload after exact fresh capture")
		AssertEqual("pending", Receipt["status"])
		Published := TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))
		AssertEqual(3, Published["hotstrings"]["terminators"].Length)
		AssertContains(FSReadUtf8Exact(Fixture.path), '# independently changed source`n',
			"the fresh actual editor candidate preserves the independently added source")
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object,
			"the real retry retains ownership until the actual reload callback")
		OnRefused.Call("controlled refusal after genuine retry")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Foreign, FSReadUtf8Exact(Fixture.path), "real retry refusal restores exact independent bytes")
		AssertTrue(ConfigTransitionResultIs(ConfigTransitionInspect(Fixture.options["locator"], Port), "absent"))
		AssertFalse(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object)
		AssertTrue(ConfigTransitionProductionPort(Port), "retry and compensation retain native authority")
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		CleanupFailure := false, RetirementReady := false, OwnerRetired := false
		ResolveCleanup() {
			if !(Bundle is Object) {
				RetirementReady := true
				return
			}
			Inspected := ConfigTransitionInspect(Fixture.options["locator"], Port)
			if ConfigTransitionResultIs(Inspected, "absent") {
				RetirementReady := true
				return
			}
			if !ConfigTransitionResultIs(Inspected, "ready")
				throw Error("The genuine terminator fixture journal could not be inspected for retirement.")
			Resolution := ConfigTransitionRollbackOwned(Fixture.options["locator"], Bundle, Port)
			if !ConfigTransitionResultIs(Resolution, "absent") && !ConfigTransitionResultIs(Resolution, "recovered_old")
				throw Error("The genuine terminator fixture journal could not restore its owned source before retirement.")
			After := ConfigTransitionInspect(Fixture.options["locator"], Port)
			if !ConfigTransitionResultIs(After, "absent")
				throw Error("The genuine terminator fixture journal remains after native rollback.")
			RetirementReady := true
		}
		RetireOwner() {
			if !RetirementReady {
				if Bundle is Object && !ConfigTransitionRetainBarrier(Bundle)
					throw Error("The unresolved genuine terminator fixture barrier could not be retained.")
				return
			}
			if Bundle is Object && _ConfigWriteTerminalTryAcquire([], Bundle) {
				Released := _ConfigWriteTerminalRelease(Bundle)
				if !(Released is Integer) || Released != 1
					throw Error("The genuine terminator fixture terminal release was not acknowledged.")
			}
			if _ConfigWriteTerminalIsActive()
				throw Error("A genuine terminal barrier is still active before terminator fixture retirement.")
			if Bundle is Object && (_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object
					|| _ConfigWriteLeaseSelectOwner(Bundle, Fixture.options["locator"]) is Object)
				throw Error("The genuine terminator fixture still owns a target or locator after terminal release.")
			OwnerRetired := true
			PreviousCritical := A_IsCritical
			Critical("On")
			try {
				; A foreign marker never belongs to this fixture's retirement.
				if Bundle is Object && _ConfigTransitionRetainedBarrier == Bundle
					_ConfigTransitionRetainedBarrier := PriorRetained
			} finally Critical(PreviousCritical)
		}
		RetireFiles() {
			if !RetirementReady || !OwnerRetired
				throw Error("The unresolved genuine terminator fixture and native journal are retained for recovery.")
			_ScopeOwnerCleanup(Fixture)
		}
		; Every cleanup phase is attempted; actual WAL resolution precedes release.
		for Operation in [() => HasMethod(OnRefused, "Call") ? OnRefused.Call("controlled cleanup") : 0,
			ResolveCleanup, RetireOwner, RetireFiles] {
			try Operation.Call()
			catch as Failure {
				if !CleanupFailure
					CleanupFailure := Failure
			}
		}
		if !TeardownPrimary && CleanupFailure
			throw CleanupFailure
	}
}
Test("terminator-records: an independently changed source refuses the actual conditional WAL candidate", _HTR_ForeignSource)

_HTR_TerminalBarrier() {
	Fixture := _ScopeOwnerFixture()
	Bundle := _ConfigWriteTerminalTryAcquire([Fixture.path])
	Assert(Bundle is Object)
	try {
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		Assert(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object,
			"the refused record editor must preserve the independently held lifecycle owner")
	} finally {
		_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: a genuine foreign terminal barrier refuses before candidate effects", _HTR_TerminalBarrier)

_HTR_ForeignOwnership() {
	OwnerFeatures := Map(), BeforeCount := OwnerFeatures.Count
	for ForeignMemberKey in ["terminators", "terminator_states"] {
		AssertEqual("", TomlConfigUnknownKind(OwnerFeatures, "hotstrings", ForeignMemberKey, &ForeignMemberOwner))
		AssertEqual("TerminatorRecords", ForeignMemberOwner, "record leaves must not become cleanup candidates")
	}
	AssertEqual(BeforeCount, OwnerFeatures.Count, "foreign ownership admission cannot manufacture a Features namespace")
}
Test("terminator-records: loader and cleanup recognize the actual foreign record owner", _HTR_ForeignOwnership)

_HTRA_Source(Kind) {
	if Kind == "authored"
		return 'hotstrings = { terminators = [{ key="custom_A4", char="§", label="Authored", consume=true, metadata={opaque="keep",count=7} }], terminator_states={custom_A4=false, future=true}, unknown={nested="retain"} } # retain parent comment`n[foreign]`nkeep="exact" # retain foreign comment`n'
	return '[hotstrings]`nterminators=[]`nterminator_states={custom_A4=false, future=true}`n[foreign]`nkeep="exact" # retain foreign comment`n'
}

_HTRA_MenuAddCollisionBody(Kind) {
	global _HotstringsTerminatorRecords
	OriginalAddBody := _HTRA_Source(Kind)
	AddFixture := _ScopeOwnerFixture(OriginalAddBody)
	AddSource := AddFixture.source
	AddBundle := 0, AddAcknowledge := 0, AddRefused := 0, AddLaunches := 0
	AddLaunch(Acknowledge, Borrowed, Refused) {
		AddBundle := Borrowed, AddAcknowledge := Acknowledge, AddRefused := Refused
		AddLaunches += 1
		return true
	}
	AddFixture.options["reload"] := AddLaunch
	try {
		AssertEqual(OriginalAddBody, SubStr(AddSource, InStr(AddSource, "`n") + 1),
			"the genuine current Add source retains every original record and foreign byte")
		AssertTrue(FSWriteDurable(AddFixture.path, AddSource))
		HotstringsTerminatorRecordsInit(AddSource)
		PriorAddOwner := _HotstringsTerminatorRecords
		PriorAddDocument := TOML_ParseDocument(AddSource)
		AddReceipt := _HS_DelimAddRecordCommit("¤", 0, AddFixture.options)
		AssertEqual(1, AddLaunches, "the actual Add owner must reach real conditional WAL reload admission")
		AssertEqual("pending", AddReceipt["status"], "durable Add is not a runtime acknowledgment")
		AssertEqual(PriorAddOwner, _HotstringsTerminatorRecords, "pending Add must not replace the live consumer")
		AddBytes := FSReadUtf8Exact(AddFixture.path)
		AddDocument := TOML_ParseDocument(AddBytes)
		AssertEqual(Kind == "authored" ? 2 : 1, AddDocument["hotstrings"]["terminators"].Length,
			"native Add must append without overwriting an independently authored key")
		AddedDefinition := AddDocument["hotstrings"]["terminators"][Kind == "authored" ? 2 : 1]
		AssertEqual("custom_A4_1", AddedDefinition["key"], "both record and future-state occupation require a fresh exact key")
		AssertEqual("¤", AddedDefinition["char"])
		AssertEqual(false, AddedDefinition["consume"].Value)
		if Kind == "authored" {
			AssertTrue(TOML_SameValue(PriorAddDocument["hotstrings"]["terminators"][1],
				AddDocument["hotstrings"]["terminators"][1]), "every original record field and unknown metadata must survive")
			AssertTrue(TOML_SameValue(PriorAddDocument["hotstrings"]["unknown"],
				AddDocument["hotstrings"]["unknown"]), "the unrelated inline parent owner must survive")
		}
		for PriorStateKey, PriorStateValue in PriorAddDocument["hotstrings"]["terminator_states"]
			AssertTrue(TOML_SameValue(PriorStateValue, AddDocument["hotstrings"]["terminator_states"][PriorStateKey]),
				"fresh Add must preserve every existing state owner")
		AssertEqual(true, AddDocument["hotstrings"]["terminator_states"]["custom_A4_1"].Value,
			"the new Add intent must explicitly enable only its fresh key")
		AssertEqual(false, AddDocument["hotstrings"]["terminator_states"]["custom_A4"].Value)
		AssertContains(AddBytes, '[foreign]`nkeep="exact" # retain foreign comment`n')
		AddedSettings := HotstringsTerminatorRecordsResolve(AddDocument)
		AssertEqual(Kind == "authored" ? 2 : 1, AddedSettings.Records.Length)
		AssertEqual(true, AddedSettings.Records[AddedSettings.Records.Length].Enabled,
			"a future false state must not silently disable the newly added scalar")
		AssertTrue(HasMethod(AddAcknowledge, "Call"))
		AssertTrue(AddAcknowledge.Call(), "the actual retained callback must acknowledge the owned transaction")
		AssertEqual("committed", AddReceipt["status"])
		AssertEqual(PriorAddOwner, _HotstringsTerminatorRecords,
			"the modeled replacement acknowledgment is not a fake local boot")
	} finally {
		if HasMethod(AddRefused, "Call")
			AddRefused.Call("controlled Add fixture cleanup")
		if AddBundle is Object
			_ConfigWriteTerminalRelease(AddBundle)
		_ScopeOwnerCleanup(AddFixture)
	}
}

_HTRA_MenuAddCollision(Kind) {
	_HTR_WithRuntime(_HTRA_MenuAddCollisionBody.Bind(Kind))
}
Test("terminator-add: actual native Add preserves an authored generated-key record through WAL acknowledgment",
	_HTRA_MenuAddCollision.Bind("authored"))
Test("terminator-add: actual native Add reserves a future false state and explicitly enables its fresh key",
	_HTRA_MenuAddCollision.Bind("future-state"))

_HTRA_FiniteAllocationAndQuarantinedKeys() {
	AllocationSource := 'hotstrings = { terminators = [{key="custom_A4",char="§",label="Valid",consume=false},{key="custom_A4_1",char="bad",label="Quarantined",consume=false,unknown="keep"}], terminator_states={custom_A4_2=false, opaque="keep"}, foreign="unchanged" }`n'
	AddedAllocation := HotstringsTerminatorRecordPlan(AllocationSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false))))
	AllocationBefore := TOML_ParseDocument(AllocationSource)
	AllocationAfter := TOML_ParseDocument(AddedAllocation.Content)
	AssertEqual(3, AllocationAfter["hotstrings"]["terminators"].Length)
	AssertEqual("custom_A4_3", AllocationAfter["hotstrings"]["terminators"][3]["key"],
		"quarantined raw keys and future states both reserve their exact identity")
	loop 2
		AssertTrue(TOML_SameValue(AllocationBefore["hotstrings"]["terminators"][A_Index],
			AllocationAfter["hotstrings"]["terminators"][A_Index]))
	AssertEqual("keep", AllocationAfter["hotstrings"]["terminator_states"]["opaque"])
	AssertEqual("unchanged", AllocationAfter["hotstrings"]["foreign"])
	AssertEqual(true, AllocationAfter["hotstrings"]["terminator_states"]["custom_A4_3"].Value)
	HoleSource := 'hotstrings = { terminators = [], terminator_states={custom_A4=false,custom_A4_2=false} }`n'
	HolePlan := HotstringsTerminatorRecordPlan(HoleSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false))))
	AssertEqual("custom_A4_1", TOML_ParseDocument(HolePlan.Content)["hotstrings"]["terminators"][1]["key"],
		"cardinality bounds the search but must not skip an independently free earlier key")
}
Test("terminator-add: finite actual allocation reserves quarantined keys and future states without skipping a free hole",
	_HTRA_FiniteAllocationAndQuarantinedKeys)

_HTRA_MalformedStatesRefuse() {
	MalformedAddSource := 'hotstrings = { terminators = [], terminator_states="opaque" }`n'
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(MalformedAddSource, Map("mode", "add", "record",
		Map("key", "custom_A4", "char", "¤", "label", "Independent currency", "consume", TOML_Bool(false)))),
		"Add must not replace an unaddressable existing state owner")
	AssertEqual('hotstrings = { terminators = [], terminator_states="opaque" }`n', MalformedAddSource)
}
Test("terminator-add: an unaddressable existing state owner refuses the new Add intent",
	_HTRA_MalformedStatesRefuse)

_HTRP_CanonicalPrecedence(LegacyWord, LegacyConsumed, RecordSource, ExpectedWord, ExpectedConsumed) {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	_HotstringsWordDelimiters := LegacyWord
	_HotstringsConsumedDelimiters := LegacyConsumed
	AssertEqual(true, HotstringsTerminatorRecordsInit(RecordSource))
	AssertEqual(ExpectedWord, HotstringsGetWordDelimiters(), "the canonical record owns only its exact scalar")
	AssertEqual(ExpectedConsumed, HotstringsGetConsumedDelimiters(), "canonical consumption is independent of legacy string membership")
	AssertEqual(ExpectedWord, HSE_WORD_TERMINATORS, "the real boot consumer must publish the independently expected word string")
	AssertEqual(ExpectedConsumed, HSE_CONSUMED_DELIMITERS, "the real boot consumer must publish the independently expected consumed string")
	AssertEqual(LegacyWord, _HotstringsWordDelimiters, "canonical activation must not migrate saved legacy word bytes")
	AssertEqual(LegacyConsumed, _HotstringsConsumedDelimiters, "canonical activation must not migrate saved legacy consumed bytes")
}

_HTRP_WithPrecedence(LegacyWord, LegacyConsumed, RecordSource, ExpectedWord, ExpectedConsumed) {
	return _HTR_WithRuntime(_HTRP_CanonicalPrecedence.Bind(LegacyWord, LegacyConsumed,
		RecordSource, ExpectedWord, ExpectedConsumed))
}

Test("terminator-precedence: explicit disabled record removes only its scalar from both legacy sets",
	_HTRP_WithPrecedence.Bind("!¤", "!¤",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`n[hotstrings.terminator_states]`ncurrency = false`n', "!", "!"))
Test("terminator-precedence: admitted active consumed record joins both sets absent from legacy strings",
	_HTRP_WithPrecedence.Bind("!", "!",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true`n', "!¤", "!¤"))
Test("terminator-precedence: explicit consume false removes legacy consumption without disabling the record",
	_HTRP_WithPrecedence.Bind("!¤", "!¤",
		'[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = false`n', "!¤", "!"))
Test("terminator-precedence: a complete disabled emoji scalar preserves unrelated legacy punctuation",
	_HTRP_WithPrecedence.Bind("!?😀", "!😀",
		'[[hotstrings.terminators]]`nkey = "smile"`nchar = "😀"`nlabel = "Smile"`nconsume = false`n[hotstrings.terminator_states]`nsmile = false`n', "!?", "!"))
