; tests/meta/test_driver_body_cache.ahk

; ==============================================================================
; MODULE: Driver Function Body Cache Tests
; DESCRIPTION:
; Repeated meta-tests must reuse extraction from the immutable source snapshot
; without changing exact-name lookup, retryable absence, or fail-loudly errors.
; Counters wrap the real parser: equal strings alone cannot prove avoided work.
; ==============================================================================

#Requires AutoHotkey v2.0

_DFBC_Extract(State, Source, Name) {
	State.Extractions += 1
	return _DriverExtractFunctionBody(&Source, Name)
}

_DFBC_ReadSource(State) {
	State.Reads += 1
	return State.Source
}

_DFBC_Fixture(Source) {
	State := {Source: Source, Extractions: 0, Reads: 0}
	State.Cache := _DriverFunctionBodyCache(_DFBC_ReadSource.Bind(State),
		_DFBC_Extract.Bind(State))
	return State
}

_DFBC_RepeatedBody() {
	Source := "CacheSubject() {`n`treturn 42`n}`n"
	State := _DFBC_Fixture(Source)
	Expected := _DriverExtractFunctionBody(&Source, "CacheSubject")
	AssertTrue(Expected != "")
	loop 5
		AssertEqual(Expected, State.Cache.Get("CacheSubject"))
	AssertEqual(1, State.Extractions, "repeated body reads must perform exactly one extraction")
	AssertEqual(1, State.Reads)
}

_DFBC_RepeatedAbsence() {
	State := _DFBC_Fixture("PresentSubject() {`n`treturn 1`n}`n")
	loop 3
		AssertEqual("", State.Cache.Get("AbsentSubject"))
	AssertEqual(1, State.Extractions, "a missing definition is a cached result, not a cache miss")
}

_DFBC_CaseIdentity(LowerFirst) {
	State := _DFBC_Fixture("CaseSubject() {`n`treturn 2`n}`n")
	Names := LowerFirst ? ["casesubject", "CaseSubject"] : ["CaseSubject", "casesubject"]
	loop 2 {
		for Name in Names {
			Body := State.Cache.Get(Name)
			AssertEqual(Name == "CaseSubject", Body != "", "cache keys must preserve scanner case identity")
		}
	}
	AssertEqual(2, State.Extractions)
}

_DFBC_EmptySourceCanRecover() {
	State := _DFBC_Fixture("")
	AssertEqual("", State.Cache.Get("LaterSubject"))
	State.Source := "LaterSubject() {`n`treturn 3`n}`n"
	AssertContains(State.Cache.Get("LaterSubject"), "return 3")
	AssertContains(State.Cache.Get("LaterSubject"), "return 3")
	AssertEqual(2, State.Extractions, "empty source must not poison the later snapshot")
	AssertEqual(2, State.Reads)
}

_DFBC_SnapshotOwnership() {
	State := _DFBC_Fixture("FirstSubject() {`n`treturn 4`n}`nSecondSubject() {`n`treturn 5`n}`n")
	AssertContains(State.Cache.Get("FirstSubject"), "return 4")
	State.Source := "SecondSubject() {`n`treturn 99`n}`n"
	AssertContains(State.Cache.Get("SecondSubject"), "return 5",
		"all names in an instance must resolve from the same nonempty snapshot")
	Other := _DFBC_Fixture(State.Source)
	AssertContains(Other.Cache.Get("SecondSubject"), "return 99",
		"independent source snapshots must never share name-only entries")
	AssertEqual(1, State.Reads)
}

_DFBC_InvalidNameStillThrows() {
	State := _DFBC_Fixture("ValidSubject() {`n`treturn 6`n}`n")
	loop 2 {
		Failure := 0
		try State.Cache.Get("invalid-name")
		catch as Err
			Failure := Err
		AssertTrue(Failure is ValueError)
		AssertContains(Failure.Message, "Invalid driver function name")
		State.Source := "ValidSubject() {`n`treturn 99`n}`n"
	}
	AssertEqual(2, State.Extractions, "failed extractions must not publish a cached result")
	AssertContains(State.Cache.Get("ValidSubject"), "return 6")
	AssertEqual(1, State.Reads, "even a failed first extraction must retain its nonempty snapshot")
}

_DFBC_InvalidNameOnEmptySource() {
	State := _DFBC_Fixture("")
	Failure := 0
	try State.Cache.Get("invalid-name")
	catch as Err
		Failure := Err
	AssertTrue(Failure is ValueError, "empty source must not hide an invalid-name error")
	State.Source := "RecoveredSubject() {`n`treturn 7`n}`n"
	AssertContains(State.Cache.Get("RecoveredSubject"), "return 7")
}

_DFBC_StrictWrapperStillThrows() {
	; This deliberate missing symbol exercises the strict wrapper's error path.
	Missing := "_DFBC_AbsentProductionSymbol"
	loop 2 {
		AssertEqual("", _DriverFuncBodyOrEmpty(Missing))
		Failure := 0
		try _DriverFuncBody(Missing)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "no definition")
	}
	AssertTrue(_DriverFuncBody("Ergopti_OnShutdown") != "")
}

_DFBC_TypedInvalidName(Name) {
	State := _DFBC_Fixture("ValidSubject() {`n`treturn 8`n}`n")
	Expected := 0
	Source := State.Source
	try _DriverExtractFunctionBody(&Source, Name)
	catch as Err
		Expected := Err
	AssertTrue(Expected is Error, "the real extractor must reject this invalid typed name")
	loop 2 {
		Actual := 0
		try State.Cache.Get(Name)
		catch as Err
			Actual := Err
		AssertTrue(Actual is Error, "cache lookup must not turn an invalid typed name into a value")
		AssertEqual(Type(Expected), Type(Actual))
	}
	AssertEqual(2, State.Extractions)
	AssertContains(State.Cache.Get("ValidSubject"), "return 8")
}

_DFBC_IndexedScannerParity() {
	Source := "Probe()`nOther()`nProbe(Value := Map(`n`t'brace', '}', 'call', Other(1))) {`n"
		. "`treturn '{' " . Chr(59) . " a closing brace } in prose`n}`n`tIndented() {`n`treturn 9`n}`n"
	OriginalSource := Source
	State := {Source: Source, Reads: 0}
	Cache := _DriverFunctionBodyCache(_DFBC_ReadSource.Bind(State))
	for Name in ["Probe", "Other", "Indented", "probe", "Missing"]
		AssertEqual(_DriverExtractFunctionBody(&Source, Name), Cache.Get(Name),
			"indexed lookup must preserve calls, multiline signatures, literal braces and case")
	AssertContains(Cache.Get("Probe"), "return '{'")
	AssertContains(Cache.Get("Indented"), "return 9")
	for Name in ["invalid-name", 0, 1.5, Map()] {
		Expected := 0
		Actual := 0
		try _DriverExtractFunctionBody(&Source, Name)
		catch Error as Failure
			Expected := Failure
		try Cache.Get(Name)
		catch Error as Failure
			Actual := Failure
		AssertTrue(Expected is Error)
		AssertTrue(Actual is Error)
		AssertEqual(Type(Expected), Type(Actual), "absent index entries must not hide invalid names")
	}
	AssertEqual(1, State.Reads)
	AssertEqual(OriginalSource, Source, "successful and refused lookups must not mutate borrowed source")
}

_DFBC_IndexedSnapshotOwnership() {
	State := {Source: "", Reads: 0}
	Cache := _DriverFunctionBodyCache(_DFBC_ReadSource.Bind(State))
	AssertEqual("", Cache.Get("First"))
	State.Source := "First() {`n`treturn 1`n}`nSecond() {`n`treturn 2`n}`n"
	AssertContains(Cache.Get("First"), "return 1")
	State.Source := "Second() {`n`treturn 3`n}`n"
	AssertContains(Cache.Get("Second"), "return 2", "the index and bodies must share the same immutable snapshot")
	Other := _DriverFunctionBodyCache(_DFBC_ReadSource.Bind(State))
	AssertContains(Other.Get("Second"), "return 3", "a separate snapshot must own a separate index")
	AssertEqual(3, State.Reads)
}

_DFBC_ParserBorrowsSource() {
	; A by-value parameter copies the multi-megabyte snapshot for every name,
	; even when the index already proves that the name is absent.
	AssertTrue(_DriverExtractFunctionBody.IsByRef(1), "body extraction must borrow its source buffer")
	AssertTrue(_DriverFindFunctionDefinition.IsByRef(1), "signature lookup must borrow the same source buffer")
}
Test("driver body cache: parser borrows immutable source (driver-body-source-reference)", _DFBC_ParserBorrowsSource)

Test("driver body cache: indexed scanner preserves parsing and errors (driver-body-cache)", _DFBC_IndexedScannerParity)
Test("driver body cache: indexed snapshots recover and stay isolated (driver-body-cache)", _DFBC_IndexedSnapshotOwnership)
Test("driver body cache: repeated extraction is reused (driver-body-cache)", _DFBC_RepeatedBody)
Test("driver body cache: absent definitions are reused (driver-body-cache)", _DFBC_RepeatedAbsence)
for LowerFirst in [false, true]
	Test("driver body cache: case identity lower-first=" . LowerFirst . " (driver-body-cache)",
		_DFBC_CaseIdentity.Bind(LowerFirst))
Test("driver body cache: empty source can recover (driver-body-cache)", _DFBC_EmptySourceCanRecover)
Test("driver body cache: snapshot ownership is exact (driver-body-cache)", _DFBC_SnapshotOwnership)
Test("driver body cache: invalid names still throw (driver-body-cache)", _DFBC_InvalidNameStillThrows)
Test("driver body cache: invalid names on empty source still throw (driver-body-cache)", _DFBC_InvalidNameOnEmptySource)
Test("driver body cache: strict wrapper still throws (driver-body-cache)", _DFBC_StrictWrapperStillThrows)
for Index, Name in [0, 1.5, Map()]
	Test("driver body cache: invalid typed name vector=" . Index . " (driver-body-cache)",
		_DFBC_TypedInvalidName.Bind(Name))
