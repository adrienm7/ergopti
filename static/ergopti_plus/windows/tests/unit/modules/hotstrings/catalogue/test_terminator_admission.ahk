; tests/unit/modules/hotstrings/catalogue/test_terminator_admission.ahk

; ==============================================================================
; MODULE: Custom Terminator Boot, Removal and Admission
; DESCRIPTION:
; Admitted bootstrap and modal removal remove only their own record, and
; the displayed records are admitted before any mutation.
; ==============================================================================

#Requires AutoHotkey v2.0





_HTRB_WithBoot(Body) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _ConfigBootReadFailed
	Saved := { Rejected: _ConfigBootRejectedOverrides, Outdated: _ConfigBootOutdatedEntries,
		ReadFailed: _ConfigBootReadFailed }
	try {
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map(), _ConfigBootReadFailed := false
		return _HTR_WithRuntime(Body)
	} finally {
		_ConfigBootRejectedOverrides := Saved.Rejected
		_ConfigBootOutdatedEntries := Saved.Outdated
		_ConfigBootReadFailed := Saved.ReadFailed
	}
}

_HTRB_AdmittedGeneration() {
	OriginalBootBody := _HTR_Source()
	Fixture := _ScopeOwnerFixture(OriginalBootBody)
	try {
		AssertEqual(OriginalBootBody, SubStr(Fixture.source, InStr(Fixture.source, "`n") + 1),
			"the genuine current boot source retains every original record and foreign byte")
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		BootSnapshot := 0
		ApplyBootConfigToml(Map(), Fixture.path, &BootSnapshot)
		Assert(BootSnapshot is Object, "the actual loader must publish its admitted image")
		AssertEqual(Fixture.source, BootSnapshot.Source)
		Assert(FSWriteDurable(Fixture.path, 'hotstrings = [unterminated`n'))
		AssertTrue(HotstringsTerminatorRecordsInitBoot(BootSnapshot),
			"the consumer must not borrow a later refused source generation")
		AssertEqual("!¤😀", HotstringsGetWordDelimiters())
		AssertEqual("!¤", HotstringsGetConsumedDelimiters())
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("terminator-boot: real loader receipt retains the admitted generation after the source changes",
	_HTRB_WithBoot.Bind(_HTRB_AdmittedGeneration))

_HTRB_RefusedGeneration(ReadRefusal) {
	global _HotstringsTerminatorRecords, _ConfigBootRejectedOverrides, _ConfigBootReadFailed
	Fixture := _ScopeOwnerFixture(), ReadLock := false, PrimaryFailure := false
	CloseReadLock() {
		if IsObject(ReadLock) {
			ReadLock.Close()
			ReadLock := false
		}
	}
	try {
		InvalidSource := 'hotstrings = [unterminated`n'
		Assert(FSWriteDurable(Fixture.path, InvalidSource))
		BootSnapshot := { Source: "foreign preexisting output" }
		RejectedPath := Fixture.path
		if ReadRefusal {
			; The genuine journal already owns this file; native opening must now fail.
			ReadLock := FileOpen(RejectedPath, "r-rwd")
			Assert(IsObject(ReadLock), "the actual reader refusal requires its real exclusive file lock")
			AssertTrue(ReadLock is File, "the native read refusal requires an acquired exclusive file lock")
		}
		ReadFailure := false
		try {
			AssertEqual(-1, ApplyBootConfigToml(Map(), RejectedPath, &BootSnapshot))
		} catch as Failure {
			ReadFailure := Failure
			throw Failure
		} finally {
			try CloseReadLock()
			catch as Failure {
				if !ReadFailure
					throw Failure
			}
		}
		AssertEqual(0, BootSnapshot, "the real refusal must clear an earlier output receipt")
		AssertFalse(HotstringsTerminatorRecordsInitBoot(BootSnapshot))
		AssertEqual(0, _HotstringsTerminatorRecords, "no empty record initialization may hide a refused load")
		AssertEqual("!", HotstringsGetWordDelimiters())
		AssertTrue(ReadRefusal ? _ConfigBootReadFailed : _ConfigBootRejectedOverrides > 0)
		AssertEqual(InvalidSource, FSReadUtf8Exact(Fixture.path), "refusal cannot migrate or erase source bytes")
	} catch as Failure {
		PrimaryFailure := Failure
		throw Failure
	} finally {
		; Attempt both owned releases even if native close fails, preserving the first error.
		CleanupFailure := false
		for Operation in [CloseReadLock, () => _ScopeOwnerCleanup(Fixture)] {
			try Operation.Call()
			catch as Failure {
				if !CleanupFailure
					CleanupFailure := Failure
			}
		}
		if !PrimaryFailure && CleanupFailure
			throw CleanupFailure
	}
}
Test("terminator-boot: semantic refusal preserves source protection without publishing an empty owner",
	_HTRB_WithBoot.Bind(_HTRB_RefusedGeneration.Bind(false)))
Test("terminator-boot: native reader refusal remains protected without a second source read",
	_HTRB_WithBoot.Bind(_HTRB_RefusedGeneration.Bind(true)))

_HTRB_RemoveAfterModal(PauseAfterConfirmation) {
	return _HTR_WithRuntime(_HTRB_RemoveAfterModalBody.Bind(PauseAfterConfirmation))
}

_HTRB_RemoveAfterModalBody(PauseAfterConfirmation) {
	global _HotstringsTerminatorRecords
	OriginalRemovalBody := _HTR_Source()
	Fixture := _ScopeOwnerFixture(OriginalRemovalBody), PriorSuspend := A_IsSuspended
	Calls := 0, Acquisitions := 0, Success := 0, Bundle := 0
	Confirm(*) {
		Calls += 1
		if PauseAfterConfirmation
			Suspend(true)
		return "Yes"
	}
	RefuseAcquisition(*) {
		Acquisitions += 1
		return 0
	}
	Launch(Acknowledged, Borrowed, Refused) {
		Success := Acknowledged, Bundle := Borrowed
		return true
	}
	Fixture.options["confirm"] := Confirm
	Fixture.options["reload"] := Launch
	if PauseAfterConfirmation
		Fixture.options["acquire"] := RefuseAcquisition
	try {
		Suspend(false)
		AssertEqual(OriginalRemovalBody, SubStr(Fixture.source, InStr(Fixture.source, "`n") + 1),
			"the genuine current removal source retains every original record and foreign byte")
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		HotstringsTerminatorRecordsInit(Fixture.source)
		Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
		Outcome := _HS_DelimRemoveRecord(Admission, Fixture.options)
		AssertEqual(1, Calls, "the real removal helper must receive the confirmation")
		if PauseAfterConfirmation {
			AssertEqual(false, Outcome, "a pause during confirmation revokes admission")
			AssertEqual(0, Acquisitions, "paused confirmation must not acquire transaction ownership")
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		} else {
			Assert(Outcome is Map)
			AssertEqual("pending", Outcome["status"], "publication still requires the runtime ACK")
			AssertEqual("smile", TOML_ParseDocument(FSReadUtf8Exact(Fixture.path))["hotstrings"]["terminators"][1]["key"])
			Success.Call()
			AssertEqual("committed", Outcome["status"])
		}
	} finally {
		Suspend(PriorSuspend)
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-remove: a real post-confirmation pause refuses before acquiring any transaction",
	_HTRB_RemoveAfterModal.Bind(true))
Test("terminator-remove: an admitted confirmation removes only its record and still requires runtime ACK",
	_HTRB_RemoveAfterModal.Bind(false))

_HTRD_WithDisplayed(Body) {
	return _HTR_WithRuntime(Body)
}

_HTRD_SourceReplacement(Mode) {
	global _HotstringsTerminatorRecords
	Original := _HTR_Source()
	HotstringsTerminatorRecordsInit(Original)
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	Replacement := StrReplace(StrReplace(Original, 'char = "¤"', 'char = "§"', true),
		'label = "Currency"', 'label = "Replacement"', true)
	AssertEqual("§", HotstringsTerminatorRecordsResolve(TOML_ParseDocument(Replacement)).Records[1].Char)
	Operation := Map("mode", Mode, "key", Admission.Key, "enabled", false, "admission", Admission)
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(Replacement, Operation),
		"a key match cannot authorize an operation on the independently replaced source")
	AssertEqual(Original, Admission.Source)
	AssertTrue(HotstringsTerminatorRecordCurrent(Admission), "external bytes do not retire the runtime owner")
}
Test("terminator-admission: remove refuses replacement under the same displayed key",
	_HTRD_WithDisplayed.Bind(_HTRD_SourceReplacement.Bind("remove")))
Test("terminator-admission: state refuses replacement under the same displayed key",
	_HTRD_WithDisplayed.Bind(_HTRD_SourceReplacement.Bind("state")))

_HTRD_UnchangedSource() {
	global _HotstringsTerminatorRecords
	Original := _HTR_Source()
	HotstringsTerminatorRecordsInit(Original)
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	Removed := HotstringsTerminatorRecordPlan(Original,
		Map("mode", "remove", "key", Admission.Key, "admission", Admission))
	AssertEqual("smile", Removed.Settings.Records[1].Key)
	State := HotstringsTerminatorRecordPlan(Original,
		Map("mode", "state", "key", Admission.Key, "enabled", false, "admission", Admission))
	AssertFalse(State.Settings.Records[1].Enabled)
	AssertTrue(HotstringsTerminatorRecordCurrent(Admission))
}
Test("terminator-admission: unchanged displayed source admits detached remove and state plans",
	_HTRD_WithDisplayed.Bind(_HTRD_UnchangedSource))

_HTRD_RetiredOwner() {
	global _HotstringsTerminatorRecords
	HotstringsTerminatorRecordsInit(_HTR_Source())
	Admission := HotstringsTerminatorRecordCapture(_HotstringsTerminatorRecords.Records[1])
	_HotstringsTerminatorRecords := 0
	HotstringsTerminatorRecordsInit(_HTR_Source())
	AssertFalse(HotstringsTerminatorRecordCurrent(Admission), "equal source cannot borrow a new runtime owner")
	AssertThrows(HotstringsTerminatorRecordPlan.Bind(_HTR_Source(),
		Map("mode", "remove", "key", Admission.Key, "admission", Admission)))
}
Test("terminator-admission: equal bytes cannot replace the captured runtime owner identity",
	_HTRD_WithDisplayed.Bind(_HTRD_RetiredOwner))


; A synthesized parent must not capture the independent root schema stamp or
; bare user keys. The original AOT/foreign subject still has no parent header.
_HTR_CurrentRootOwners(Bom, FinalNewline) {
	RootBytes := 'root_owner = "keep root" # retain root comment`nroot_flag = true`nroot_count = 7`nroot_unknown.child = "keep dotted"`n'
	Source := _CMJFixtureCurrentSource(RootBytes . _HTR_Source())
	if !FinalNewline
		Source := SubStr(Source, 1, StrLen(Source) - 1)
	if Bom
		Source := Chr(0xFEFF) . Source
	Before := TOML_ParseDocument(Source)
	AssertFalse(InStr(Source, '[hotstrings]`n'), "the real source must require a new parent declaration")
	Plan := HotstringsTerminatorRecordPlan(Source, _HTR_Operation())
	Parsed := TOML_ParseDocument(Plan.Content)
	AssertEqual(ConfigMigrateCurrentVersion(), Parsed["_meta"]["schema_version"],
		"the actual edited candidate retains its current root schema authority")
	AssertFalse(Parsed["hotstrings"].Has("_meta"), "schema metadata never moves under the created parent")
	for Key in ["_meta", "root_owner", "root_flag", "root_count", "root_unknown", "private", "foreign"]
		AssertTrue(TOML_SameValue(Before[Key], Parsed[Key]), "the independent root/foreign owner survives: " . Key)
	AssertContains(Plan.Content, RootBytes, "all original bare root bytes and comments remain exact")
	AssertContains(Plan.Content, '[private]`ncredential = "keep"`n')
	AssertContains(Plan.Content, '[[foreign.rows]]`nvalue = "never alter" # foreign comment')
	AssertEqual(Bom ? Chr(0xFEFF) : "_", SubStr(Plan.Content, 1, 1), "BOM and first root metadata byte stay before any table")
	AssertEqual(3, Parsed["hotstrings"]["terminators"].Length)
	loop 2
		AssertTrue(TOML_SameValue(Before["hotstrings"]["terminators"][A_Index],
			Parsed["hotstrings"]["terminators"][A_Index]), "each original record and unknown metadata survive")
	AssertEqual("section", Parsed["hotstrings"]["terminators"][3]["key"])
	AssertEqual("§", Parsed["hotstrings"]["terminators"][3]["char"])
}
Test("terminator-records: new parent retains current root metadata and bare owners", _HTR_CurrentRootOwners.Bind(false, true))
Test("terminator-records: new parent retains current root metadata without a final newline", _HTR_CurrentRootOwners.Bind(false, false))
Test("terminator-records: new parent retains BOM before current root metadata", _HTR_CurrentRootOwners.Bind(true, true))
Test("terminator-records: new parent retains BOM and unterminated foreign comment", _HTR_CurrentRootOwners.Bind(true, false))

; Retain the independent release-branch callback-copy and root-owner controls.
_HTR_ForeignSourceCallbackCopy() {
	Fixture := _ScopeOwnerFixture(_HTR_Source())
	NativePort := ConfigTransitionProductionPort(), NativeHash := NativePort["hash"]
	; A never-issued callback copy models the race without revoking native IO.
	Port := NativePort.Clone()
	AssertFalse(ConfigTransitionProductionPort(Port), "the race callback copy grants no native authority")
	HashCalls := 0, Changed := false, Foreign := Fixture.source . '# independently changed source`n'
	Hash(Content) {
		HashCalls += 1
		Digest := NativeHash.Call(Content)
		if !Changed && Content == Fixture.source {
			Changed := true
			Assert(FSWriteDurable(Fixture.path, Foreign))
		}
		return Digest
	}
	Port["hash"] := Hash
	Fixture.options["port"] := Port
	Bundle := 0, OnRefused := 0, Launches := 0
	Launch(Success, Borrowed, Refused) {
		Launches += 1, Bundle := Borrowed, OnRefused := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := HotstringsTerminatorRecordsEdit(_HTR_Operation(), Fixture.options)
		AssertEqual(0, Launches, "a stale exact-source intent must refuse before reload admission")
		Assert(HashCalls > 0, "the retained native hash callback must execute before race refusal")
		Assert(Changed, "the actual native hash boundary must exercise the source race")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Foreign, FSReadUtf8Exact(Fixture.path), "a foreign source wins before any replacement")
	} finally {
		if HasMethod(OnRefused, "Call")
			OnRefused.Call("controlled cleanup")
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		try AssertTrue(ConfigTransitionProductionPort(NativePort), "the race fixture retains the exact canonical native image")
		finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("terminator-records: injected hash callback copy preserves independent source refusal", _HTR_ForeignSourceCallbackCopy)

; Tampering is refused even for an issued identity; restoration preserves custody.
_HTR_NativePortMutationCustody() {
	Port := ConfigTransitionProductionPort(), NativeHash := Port["hash"]
	try {
		Port["hash"] := (*) => false
		AssertFalse(ConfigTransitionProductionPort(Port), "an issued identity cannot authorize a changed callback")
		AssertThrows(_ConfigTransitionRuntimePort.Bind(Port), "revoked native IO must not become a custom port")
		AssertThrows(ConfigTransitionProductionPort, "the shared constructor must refuse the changed image")
	} finally Port["hash"] := NativeHash
	AssertTrue(ConfigTransitionProductionPort(Port), "restoration retains the original native identity")
	Assert(Port == ConfigTransitionProductionPort(), "restoration must not mint replacement authority")
}
Test("terminator-records: issued native mutation refuses and restores exact custody", _HTR_NativePortMutationCustody)

_HTR_NativePortIntact() {
	Port := ConfigTransitionProductionPort()
	AssertTrue(ConfigTransitionProductionPort(Port), "prior terminator fixtures retain the canonical native image")
	Assert(Port["hash"] == CryptoSha256, "the original native hash callback remains installed")
	Assert(Port == ConfigTransitionProductionPort(), "the next constructor observes the same admitted identity")
}
Test("terminator-records: following fixture observes intact canonical native ownership", _HTR_NativePortIntact)

_HTR_RootOwnerImage() {
	for Prefix in ["", Chr(0xFEFF)] {
		Source := Prefix . '_meta.schema_version = 7`nroot_owner = { keep = "exact", nested = { n = 9 } }`n' . _HTR_Source()
		Before := TOML_ParseDocument(Source)
		Plan := HotstringsTerminatorRecordPlan(Source, Map("mode", "upsert", "record",
			Map("key", "section", "char", "§", "label", "Section", "consume", TOML_Bool(false))))
		After := TOML_ParseDocument(Plan.Content)
		AssertTrue(TOML_SameValue(Before["_meta"], After["_meta"]), "root schema metadata remains outside the new hotstrings parent")
		AssertTrue(TOML_SameValue(Before["root_owner"], After["root_owner"]), "an independent root owner retains every typed leaf")
		AssertTrue(TOML_SameValue(Before["private"], After["private"]))
		AssertTrue(TOML_SameValue(Before["foreign"], After["foreign"]))
		AssertEqual(3, After["hotstrings"]["terminators"].Length)
		AssertEqual(Prefix == "" ? false : true, SubStr(Plan.Content, 1, 1) == Chr(0xFEFF))
	}
	Minimal := '[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "Currency"`nconsume = true'
	for Source in [Minimal, Minimal . '`n# retained final trivia'] {
		Removed := HotstringsTerminatorRecordPlan(Source, Map("mode", "remove", "key", "currency"))
		AssertEqual(0, TOML_ParseDocument(Removed.Content)["hotstrings"]["terminators"].Length,
			"an empty retained image still admits one explicit empty parent")
		if InStr(Source, "# retained final trivia")
			AssertContains(Removed.Content, "# retained final trivia", "retained trivia is not discarded by parent insertion")
	}
	RootOnly := 'root_owner = { keep = "exact" }'
	RootPlan := HotstringsTerminatorRecordPlan(RootOnly, Map("mode", "upsert", "record",
		Map("key", "section", "char", "§", "label", "Section", "consume", TOML_Bool(false))))
	RootAfter := TOML_ParseDocument(RootPlan.Content)
	AssertTrue(TOML_SameValue(TOML_ParseDocument(RootOnly)["root_owner"], RootAfter["root_owner"]),
		"a root-only image without a terminal newline retains its independent owner")
	AssertEqual(1, RootAfter["hotstrings"]["terminators"].Length)

}
Test("terminator-records: a new parent preserves independent root owners and BOM", _HTR_RootOwnerImage)
