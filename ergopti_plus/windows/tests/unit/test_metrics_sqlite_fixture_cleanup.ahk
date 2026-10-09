; tests/unit/test_metrics_sqlite_fixture_cleanup.ahk

; ==============================================================================
; MODULE: Metrics SQLite Fixture Ownership
; DESCRIPTION: Failed schema setup must destroy the native SQLite fixture.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRFC_FailSchema(State, Throws, Db) {
	State["db"] := Db
	Result := DllCall(SQLiteConst.DLL . "\sqlite3_create_function_v2",
		"Ptr", Db, "AStr", "fixture_lifetime", "Int", 0, "Int", 1, "Ptr", 0,
		"Ptr", State["function"], "Ptr", 0, "Ptr", 0, "Ptr", State["destroy"], "Int")
	AssertEqual(0, Result, "the native destructor must be registered before injecting failure")
	if Throws
		throw Error("injected fixture schema exception")
	return false
}

_LRFC_SchemaFailureClosesDatabase(OpenFixture, Throws) {
	State := Map("db", 0, "closed", false)
	State["function"] := CallbackCreate((Context, Count, Values) => 0)
	State["destroy"] := CallbackCreate((Context) => State["closed"] := true)
	try {
		Failure := 0
		try OpenFixture.Call(_LRFC_FailSchema.Bind(State, Throws))
		catch as Err
			Failure := Err
		AssertTrue(IsObject(Failure), "schema setup must propagate its failure")
		AssertContains(Failure.Message, Throws ? "injected fixture schema exception" : "canonical production schema",
			"cleanup must preserve the original setup failure")
		AssertTrue(State["closed"], "the native SQLite destructor must run before failed fixture setup returns")
	} finally {
		; A failing baseline must not leak its deliberately observed native owner.
		if State["db"] && !State["closed"]
			SQLite_Close(State["db"])
		if State["db"]
			AssertTrue(State["closed"], "test teardown must destroy the observed native owner")
		CallbackFree(State["function"])
		CallbackFree(State["destroy"])
	}
}
for OpenFixture in [_KLRLlmAccepted_OpenFixture, _KLRSource_OpenFixture, _KLRAppFilter_OpenFixture,
	_KLRManifest_OpenFixture, _KLRShortcut_OpenFixture]
	for Throws in [false, true]
		Test("Metrics fixture: " . OpenFixture.Name . " schema failure throws=" . Throws . " (metrics-fixture-cleanup)",
			_LRFC_SchemaFailureClosesDatabase.Bind(OpenFixture, Throws))
