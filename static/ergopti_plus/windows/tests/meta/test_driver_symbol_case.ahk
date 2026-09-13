; tests/meta/test_driver_symbol_case.ahk

; ==============================================================================
; MODULE: Driver Symbol Case Tests
; DESCRIPTION:
; Source guards must follow the same symbol identity as the native interpreter.
; ==============================================================================

#Requires AutoHotkey v2.0

_DSNC_NativeSubject() {
	return 37
}

_DSNC_NativeIdentity() {
	AssertEqual(37, _dsnc_nativesubject())
	AssertEqual(37, _DSNC_NATIVESUBJECT())
}
Test("driver symbols: native function identity ignores case (driver-symbol-case)", _DSNC_NativeIdentity)

_DSNC_Extract(Variant, Indexed) {
	Source := "CaseSubject() {`n`treturn 37`n}"
	Original := Source
	if Indexed {
		Cache := _DriverFunctionBodyCache(() => Source)
		Body := Cache.Get(Variant)
		AssertEqual(Body, Cache.Get("CaseSubject"), "aliases must resolve the same immutable body")
	} else {
		Definition := _DriverFindFunctionDefinition(&Source, Variant)
		AssertTrue(IsObject(Definition), "a valid case alias must resolve the native definition")
		Body := _DriverExtractFunctionBody(&Source, Variant)
	}
	AssertContains(Body, "return 37", "case variants must not turn a live function into an absent symbol")
	AssertEqual(Original, Source)
}
for Indexed in [false, true]
	for Variant in ["casesubject", "CASESUBJECT", "cAsEsUbJeCt"]
		Test("driver symbols: " . Variant . " indexed=" . Indexed . " (driver-symbol-case)",
			_DSNC_Extract.Bind(Variant, Indexed))

_DSNC_Graph() {
	global _HGBS_HOTIF_PARENTS
	Saved := _HGBS_HOTIF_PARENTS
	Source := "#hOtIf RootCase()`n#HOTIF rootcase()`nROOTCASE() {`n`tLeafCase()`n}`n"
		. "LEAFCASE() {`n`tGLOBAL GhostState`n`treturn GhostState`n}"
	Cache := _DriverFunctionBodyCache(() => Source)
	try {
		Names := _HGBS_HotIfFunctions(Source, ObjBindMethod(Cache, "Get"))
		AssertEqual(2, Names.Count, "case aliases must retain every transitive function exactly once")
		AssertTrue(Names.Has("RootCase"))
		AssertTrue(Names.Has("LeafCase"))
		Body := Cache.Get("leafcase")
		AssertTrue(Body != "")
		Globals := _HGBS_UnguardedGlobalsOf(Body)
		AssertEqual(1, Globals.Length, "uppercase GLOBAL cannot hide an unset read")
		AssertEqual("GhostState", Globals[1])
	} finally _HGBS_HOTIF_PARENTS := Saved
}
Test("driver symbols: mixed-case HotIf graph retains an unguarded global (driver-symbol-case)", _DSNC_Graph)
