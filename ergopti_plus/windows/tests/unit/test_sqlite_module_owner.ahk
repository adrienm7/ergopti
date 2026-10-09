; tests/unit/test_sqlite_module_owner.ahk

; ==============================================================================
; MODULE: SQLite Module Ownership Tests
; DESCRIPTION:
; Count native acquisitions and releases across initialization failures, cleanup
; debt, reentry, and reuse. A separate child proves real DLL lifetime without
; the process-wide pins held by other SQLite fixtures in the main test suite.
; ==============================================================================

#Requires AutoHotkey v2.0

class _SQLMO_Native {
	Loads := 0
	Resolves := 0
	Versions := 0
	Frees := []
	FailAt := ""
	FreeFailures := 0
	FreeThrows := 0
	Reenter := false
	ReentryError := 0
	Owner := 0
	Load(Path) {
		this.Loads += 1
		if this.FailAt = "load-throw"
			throw Error("Injected native load failure.")
		if this.Reenter {
			try this.Owner.Ensure(Path)
			catch Error as Err
				this.ReentryError := Err
		}
		return this.FailAt = "load" ? 0 : 100 + this.Loads
	}
	Resolve(Module, Name) {
		this.Resolves += 1
		if this.FailAt = "resolve-throw"
			throw Error("Injected native export failure.")
		AssertEqual("sqlite3_libversion", Name)
		return this.FailAt = "resolve" ? 0 : 200
	}
	Version(Address) {
		this.Versions += 1
		AssertEqual(200, Address)
		if this.FailAt = "version"
			throw Error("Injected native version failure.")
		return this.FailAt = "empty-version" ? "" : "3.50.1"
	}
	Free(Module) {
		this.Frees.Push(Module)
		if this.FreeThrows > 0 {
			this.FreeThrows -= 1
			throw Error("Injected native release failure.")
		}
		if this.FreeFailures > 0 {
			this.FreeFailures -= 1
			return false
		}
		return true
	}
}

_SQLMO_Reuse() {
	Native := _SQLMO_Native()
	Owner := SQLiteModuleOwner(Native)
	Loop 20
		AssertEqual("3.50.1", Owner.Ensure("fixture.dll"))
	AssertEqual(1, Native.Loads)
	AssertEqual(1, Native.Resolves)
	AssertEqual(1, Native.Versions)
	AssertEqual(0, Native.Frees.Length, "ready ownership lasts until process teardown")
	AssertThrows(Owner.Ensure.Bind(Owner, "different.dll"))
	AssertEqual("3.50.1", Owner.Ensure("fixture.dll"))
	AssertEqual(1, Native.Loads, "rejected identity changes must not acquire another module")
}
Test("SQLite module: repeated acquisition has one owner (sqlite-module-owner)", _SQLMO_Reuse)

_SQLMO_Failure(Stage) {
	Native := _SQLMO_Native()
	Native.FailAt := Stage
	Owner := SQLiteModuleOwner(Native)
	AssertThrows(Owner.Ensure.Bind(Owner, "fixture.dll"))
	AssertEqual(1, Native.Loads, "the failure must reach the native acquisition seam")
	AssertEqual(0, Owner.Module, "failed initialization cannot publish ownership")
	AssertEqual(0, Owner.PendingModule, "successful cleanup must settle acquisition debt")
	AssertFalse(Owner.Busy)
	AssertEqual(InStr(Stage, "load") = 1 ? 0 : 1, Native.Frees.Length)
	Native.FailAt := ""
	AssertEqual("3.50.1", Owner.Ensure("fixture.dll"))
	AssertEqual(2, Native.Loads, "a clean failed initialization permits retry")
}
for Stage in ["load", "load-throw", "resolve", "resolve-throw", "version", "empty-version"]
	Test("SQLite module: failed " . Stage . " initialization releases its candidate (sqlite-module-owner)",
		_SQLMO_Failure.Bind(Stage))

_SQLMO_Debt(Throws := false) {
	Native := _SQLMO_Native()
	Native.FailAt := "resolve"
	if Throws
		Native.FreeThrows := 2
	else
		Native.FreeFailures := 2
	Owner := SQLiteModuleOwner(Native)
	Failure := 0
	try Owner.Ensure("fixture.dll")
	catch Error as Err
		Failure := Err
	AssertTrue(Failure is Error)
	AssertContains(Failure.Message, "version export", "cleanup refusal must retain the original failure")
	AssertContains(Failure.Message, "Cleanup failed", "cleanup refusal must also remain diagnosable")
	AssertEqual(101, Owner.PendingModule)
	Native.FailAt := ""
	AssertThrows(Owner.Ensure.Bind(Owner, "fixture.dll"))
	AssertEqual(1, Native.Loads, "unsettled release must block another acquisition")
	AssertEqual(101, Owner.PendingModule)
	AssertEqual("3.50.1", Owner.Ensure("fixture.dll"))
	AssertEqual(2, Native.Loads)
	AssertEqual(3, Native.Frees.Length)
	for Released in Native.Frees
		AssertEqual(101, Released, "every retry must target the original native reference")
	AssertEqual(0, Owner.PendingModule)
}
Test("SQLite module: refused release retains exact cleanup debt (sqlite-module-owner)", _SQLMO_Debt)
Test("SQLite module: thrown release retains exact cleanup debt (sqlite-module-owner)", _SQLMO_Debt.Bind(true))

_SQLMO_Reentry() {
	Native := _SQLMO_Native()
	Owner := SQLiteModuleOwner(Native)
	Native.Owner := Owner
	Native.Reenter := true
	try {
		AssertEqual("3.50.1", Owner.Ensure("fixture.dll"))
		AssertTrue(Native.ReentryError is Error, "native callback reentry must be rejected")
		AssertEqual(1, Native.Loads)
		AssertEqual(101, Owner.Module)
		AssertFalse(Owner.Busy)
	} finally Native.Owner := 0
}
Test("SQLite module: reentry cannot acquire a second reference (sqlite-module-owner)", _SQLMO_Reentry)

_SQLMO_IsolatedNative() {
	static TimeoutMs := 10000, PollMs := 20
	Receipt := {Done: false, Code: -1, Output: "", Errors: ""}
	Done(Code, Output, Errors) {
		Receipt.Done := true
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\sqlite_module_child.ahk"], Done)
	try {
		AssertTrue(Handle.start(), "the isolated native child must start")
		Started := A_TickCount
		while !Receipt.Done && TickElapsed(Started) < TimeoutMs
			Sleep(PollMs)
		AssertTrue(Receipt.Done, "the child must complete within the bounded fixture budget")
		AssertEqual(0, Receipt.Code, Receipt.Errors)
		AssertEqual("", Receipt.Errors)
		AssertEqual("sqlite-module-lifetime-ok", Receipt.Output)
	} finally {
		if !Receipt.Done
			AssertTrue(Handle.terminate(), "fixture timeout must release its owned process tree")
	}
}
Test("SQLite module: standalone databases retain native lifetime (sqlite-module-owner)", _SQLMO_IsolatedNative)
