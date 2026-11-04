; tests/meta/suite/test_driver_symbol_case.ahk

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

; The line-by-line definition the native comment stripper must keep matching.
_DSNC_StripOracle(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r")
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	return Out
}

_DSNC_StripMatchesLineContract() {
	; Chr(59): a spaced semicolon ends an enclosed multi-line expression's line.
	C := Chr(59)
	for Sample in ["", "`n", C, "code", C . " a`ncode`n", "`r`n`t" . C . " a`r`n`r`nb " . C . " c`r`n",
		"`n`n " . C . " a`n`n", "a`rb`n`r" . C . " c`n", "`f" . C . " a`nb", "`r`r" . C . "a`r`r`nb`r`r"]
		AssertEqual(_DSNC_StripOracle(Sample), _StripFullLineComments(Sample), "stripper sample " . A_Index)
	Actual := _DriverSourceConcat()
	Assert(StrLen(Actual) > 100000, "the differential must cover the actual driver source")
	Assert(_DSNC_StripOracle(Actual) == _StripFullLineComments(Actual),
		"the native stripper must equal the line contract on the whole driver")
}
Test("source helpers: native comment stripping equals the line contract (meta-source-memo)", _DSNC_StripMatchesLineContract)

; A cached mask must never answer for different text, including text of the same
; length and a rewritten file: the memo is what a fixture writer could be fooled by.
_DSNC_MaskMemoFollowsContent() {
	Padding := "`n" . Format("{:2000}", "")
	First := 'x := "aaa"' . Padding
	Second := 'x := bbbbb' . Padding
	AssertEqual(StrLen(First), StrLen(Second), "the fixture must exercise equal lengths")
	FirstMask := _DriverMaskNonCode(&First)
	AssertEqual(FirstMask, _DriverMaskNonCode(&First), "a repeated text keeps its mask")
	AssertFalse(InStr(FirstMask, "aaa"), "a string literal is masked")
	AssertContains(_DriverMaskNonCode(&Second), "bbbbb", "equal-length code must get its own mask")
	Path := A_Temp . "\ergopti_mask_memo_" . DllCall("GetCurrentProcessId") . ".ahk"
	try {
		FileAppend(First, Path, "UTF-8")
		Read := FileRead(Path, "UTF-8")
		AssertFalse(InStr(_DriverMaskNonCode(&Read), "bbbbb"), "the first fixture bytes are scanned")
		FileDelete(Path)
		FileAppend(Second, Path, "UTF-8")
		Read := FileRead(Path, "UTF-8")
		AssertContains(_DriverMaskNonCode(&Read), "bbbbb", "a rewritten fixture must not see the earlier mask")
	} finally {
		try FileDelete(Path)
	}
	Block := "/*`nhidden`n*/`nvisible := 1" . Padding
	AssertContains(_DriverMaskNonCode(&Block, true), "visible", "the block-only view keeps code")
	Literal := 'x := "kept"`n/*`nhidden`n*/' . Padding
	AssertContains(_DriverMaskNonCode(&Literal, true), "kept", "the block-only view keeps literals")
	AssertFalse(InStr(_DriverMaskNonCode(&Literal), "kept"), "the two views must not share one memo")
}
Test("source helpers: the mask memo follows content, never a stale file (meta-source-memo)", _DSNC_MaskMemoFollowsContent)

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

; Real temporary driver trees exercise the production resolver without pinning
; a symbol to its current module. All prior symbol-case assertions stay intact.
_DSFR_With(Body) {
	Root := A_Temp . "\ergopti-symbol-tree-" . DllCall("GetCurrentProcessId", "uint")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	AssertTrue(DllCall("CreateDirectoryW", "str", Root, "ptr", 0, "int"),
		"the fixture must exclusively own its native source root")
	try {
		; Native enumeration expands 8.3 aliases. Obtain the independently owned
		; directory's long spelling before authoring any expected fixture paths.
		Storage := Buffer(65536)
		Length := DllCall("GetLongPathNameW", "Str", Root, "Ptr", Storage, "UInt", 32768, "UInt")
		Assert(Length > 0 && Length < 32768, "the owned fixture root must resolve its complete native long path")
		Body.Call(StrGet(Storage, Length, "UTF-16"))
	} finally DirDelete(Root, true)
}

_DSFR_Write(Root, Relative, Source) {
	Path := Root . "\" . Relative
	SplitPath(Path, , &Directory)
	DirCreate(Directory)
	FileAppend(Source, Path, "UTF-8")
	return Path
}

_DSFR_Failure(Body, Needle, Kind := "Error") {
	Failure := 0
	try Body.Call()
	catch Error as Err
		Failure := Err
	Assert(IsObject(Failure), "the resolver must refuse this source tree")
	if Kind == "OSError"
		Assert(Failure is OSError, "native read refusal must propagate as an OS error")
	else if Kind == "ValueError"
		Assert(Failure is ValueError, "invalid symbols or roots must be rejected by validation")
	else if Kind == "TypeError"
		Assert(Failure is TypeError, "invalid root types must be rejected by validation")
	AssertContains(Failure.Message, Needle)
}

_DSFR_Positive(Root) {
	Path := _DSFR_Write(Root, "one\first.ahk", "ExportSubject(`nOption := Map('k', 3)`n) {`nreturn 37`n}`n")
	for _, Name in ["ExportSubject", "exportsubject", "EXPORTSUBJECT"]
		AssertEqual(Path, _DriverProductionFileForSymbol(Name, Root), "native case aliases resolve the same unique definition")
}
Test("driver symbols: unique production source follows native symbol case (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Positive))

_DSFR_Decoys(Root) {
	Source := "; ExportSubject() {}`n/*`nExportSubject() {}`n*/`n"
		. 'Data := "`n(`nExportSubject() {}`n)"`n'
		. "ExportSubject()`n"
		. "class Container {`nExportSubject() {`nreturn 1`n}`n}`n"
		. "Outer() {`nExportSubject() {`nreturn 2`n}`n}`n"
		. "ExportSubject() {`nreturn 37`n}`n"
	Path := _DSFR_Write(Root, "one\first.ahk", Source)
	AssertEqual(Path, _DriverProductionFileForSymbol("ExportSubject", Root),
		"comments, strings, calls, methods and nested functions cannot duplicate an export")
}
Test("driver symbols: noncode and nested definitions cannot impersonate a production export (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Decoys))

_DSFR_Missing(Root) {
	_DSFR_Write(Root, "one\first.ahk", "ExportSubject()`nclass Container {`nExportSubject() {}`n}`n")
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "No production definition")
}
Test("driver symbols: missing exported definition fails loudly (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Missing))

_DSFR_Duplicate(Root, SameFile) {
	_DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 1`n}`n"
		. (SameFile ? "exportsubject() {`nreturn 2`n}`n" : ""))
	if !SameFile
		_DSFR_Write(Root, "two\second.ahk", "exportsubject() {`nreturn 2`n}`n")
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "Multiple production definitions")
}
Test("driver symbols: duplicate definitions in one production file are refused (driver-production-symbol)",
	_DSFR_With.Bind((Root) => _DSFR_Duplicate(Root, true)))
Test("driver symbols: case aliases across production files are ambiguous (driver-production-symbol)",
	_DSFR_With.Bind((Root) => _DSFR_Duplicate(Root, false)))

_DSFR_Excluded(Root) {
	Expected := _DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 37`n}`n")
	for _, Tree in ["tests", "vendor", "build", "_generated", "one\tests"]
		_DSFR_Write(Root, Tree . "\decoy.ahk", "ExportSubject() {`nreturn 1`n}`n")
	AssertEqual(Expected, _DriverProductionFileForSymbol("ExportSubject", Root),
		"the existing production ownership rule excludes every generated/test/vendor subtree")
}
Test("driver symbols: source resolution retains the shared production census exclusions (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Excluded))

_DSFR_Moved(Root) {
	Before := _DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 37`n}`n")
	AssertEqual(Before, _DriverProductionFileForSymbol("ExportSubject", Root))
	DirCreate(Root . "\two")
	After := Root . "\two\moved.ahk"
	FileMove(Before, After)
	AssertEqual(After, _DriverProductionFileForSymbol("ExportSubject", Root),
		"a new lookup must discover an actual native file move rather than reuse the old path")
	FileDelete(After)
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "No production definition")
}
Test("driver symbols: actual file moves and deletion invalidate prior source locations (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Moved))

; The per-file memory must answer from an aged, unchanged file without reading it
; (the exclusive lock proves no read happened) and must drop it once a new stamp
; or a fresh, racy write says the bytes may differ.
_DSFR_RememberedSource(Root) {
	Path := _DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 37`n}`n")
	Aged := DateAdd(A_Now, -1, "Hours")
	FileSetTime(Aged, Path)
	AssertEqual(Path, _DriverProductionFileForSymbol("ExportSubject", Root))
	Handle := DllCall("CreateFileW", "str", Path, "uint", 0x80000000, "uint", 0,
		"ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
	Assert(Handle != -1, "the fixture must own a real exclusive native source lock")
	try {
		AssertEqual(Path, _DriverProductionFileForSymbol("ExportSubject", Root),
			"an unchanged aged source is answered without another read")
		_DSFR_Failure(() => _DriverProductionFileForSymbol("OtherSubject", Root), "No production definition")
	} finally DllCall("CloseHandle", "ptr", Handle)
	FileDelete(Path)
	_DSFR_Write(Root, "one\first.ahk", "OtherExport() {`nreturn 37`n}`n")
	FileSetTime(Aged, Path)
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "No production definition")
	AssertEqual(Path, _DriverProductionFileForSymbol("OtherExport", Root),
		"a size change under the same modification time invalidates the memory")
	FileDelete(Path)
	_DSFR_Write(Root, "one\first.ahk", "ExportSubjecT() {`nreturn 37`n}`n")
	AssertEqual(Path, _DriverProductionFileForSymbol("ExportSubject", Root),
		"a fresh write is never answered from the memory")
	FileDelete(Path)
	_DSFR_Write(Root, "one\first.ahk", "OtherSubjecT() {`nreturn 37`n}`n")
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "No production definition")
}
Test("driver symbols: unchanged sources are remembered and any new stamp or racy write invalidates them (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_RememberedSource))

_DSFR_Unreadable(Root) {
	Expected := _DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 37`n}`n")
	Locked := _DSFR_Write(Root, "two\locked.ahk", "OtherSubject() {`nreturn 1`n}`n")
	Handle := DllCall("CreateFileW", "str", Locked, "uint", 0x80000000, "uint", 0,
		"ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
	Assert(Handle != -1, "the fixture must own a real exclusive native source lock")
	try _DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "(32)", "OSError")
	finally DllCall("CloseHandle", "ptr", Handle)
	AssertEqual(Expected, _DriverProductionFileForSymbol("ExportSubject", Root),
		"successful retry must census all production sources after the lock closes")
}
Test("driver symbols: unreadable production siblings fail instead of returning a partial census (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_Unreadable))

_DSFR_InvalidInputs(Root) {
	Locked := _DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 37`n}`n")
	Handle := DllCall("CreateFileW", "str", Locked, "uint", 0x80000000, "uint", 0,
		"ptr", 0, "uint", 3, "uint", 0, "ptr", 0, "ptr")
	Assert(Handle != -1, "validation controls must own an unreadable source")
	try {
		for _, Name in ["", "a.b", "a/b", "a\\b", "Name()", "Name.*", "Name`nOther", 3, Map()]
			_DSFR_Failure(_DriverProductionFileForSymbol.Bind(Name, Root), "Invalid production function symbol", "ValueError")
		_DSFR_Failure(_DriverProductionFileForSymbol.Bind("ExportSubject", Map()), "path string", "TypeError")
		_DSFR_Failure(_DriverProductionFileForSymbol.Bind("ExportSubject", Root . "\missing"), "existing directory", "ValueError")
	} finally DllCall("CloseHandle", "ptr", Handle)
}

Test("driver symbols: invalid names and source roots fail before resolution (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_InvalidInputs))

_DSFR_ActualExports() {
	for _, Symbol in ["ChordParse", "HotkeyRegistrarReservePhysicalBroker"] {
		Path := _DriverProductionFileForSymbol(Symbol)
		Assert(_DriverIsProductionSource(Path), "an actual exported symbol must resolve authored production source")
		Source := FileRead(Path, "UTF-8")
		Code := _DriverMaskNonCode(&Source)
		AssertEqual(1, _DriverTopLevelDefinitionCount(&Code, Symbol), "the resolved native include contains its exact declared export")
	}
}
Test("driver symbols: declared native fixture exports resolve actual production files (driver-production-symbol)",
	_DSFR_ActualExports)

_DSFR_NativeArrow(Value := 3) => Value * 2

class _DSFR_NativeArrowClass {
	Value() => 7
}

_DSFR_NativeArrowIdentity() {
	Nested(Value) => Value + 1
	AssertEqual(38, _dsfr_nativearrow(19), "native top-level arrow declarations retain case-insensitive identity")
	AssertEqual(7, _DSFR_NativeArrowClass().Value(), "a native method arrow remains in its class namespace")
	AssertEqual(5, Nested(4), "a native nested arrow retains its local namespace")
}
Test("driver symbols: native arrow declarations preserve global and nested namespaces (driver-production-symbol)",
	_DSFR_NativeArrowIdentity)

_DSFR_ArrowPositive(Root) {
	Path := _DSFR_Write(Root, "one\first.ahk", 'Data := "=>😀"`n'
		. "ExportSubject(`nOption := Map('k', 3)`n) => Option['k']`n")
	for _, Name in ["ExportSubject", "exportsubject", "EXPORTSUBJECT"]
		AssertEqual(Path, _DriverProductionFileForSymbol(Name, Root),
			"an actual arrow signature must resolve its unique source at unchanged native offsets")
}
Test("driver symbols: arrow exports resolve multiline signatures and native offsets (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_ArrowPositive))

_DSFR_ArrowDuplicate(Root, SameFile) {
	_DSFR_Write(Root, "one\first.ahk", "ExportSubject() {`nreturn 1`n}`n"
		. (SameFile ? "exportsubject() => 2`n" : ""))
	if !SameFile
		_DSFR_Write(Root, "two\second.ahk", "exportsubject() => 2`n")
	_DSFR_Failure(() => _DriverProductionFileForSymbol("ExportSubject", Root), "Multiple production definitions")
}
Test("driver symbols: same-file mixed declaration forms are duplicate exports (driver-production-symbol)",
	_DSFR_With.Bind((Root) => _DSFR_ArrowDuplicate(Root, true)))
Test("driver symbols: cross-file mixed case arrow aliases are duplicate exports (driver-production-symbol)",
	_DSFR_With.Bind((Root) => _DSFR_ArrowDuplicate(Root, false)))

_DSFR_ArrowDecoys(Root) {
	Source := "class Container {`nExportSubject() => 1`n}`n"
		. "Outer() {`nexportsubject() => 2`n}`n"
		. "; ExportSubject() => 3`n" . 'Data := "ExportSubject() => 4"`n'
		. "ExportSubject() => 37`n"
	Path := _DSFR_Write(Root, "one\first.ahk", Source)
	AssertEqual(Path, _DriverProductionFileForSymbol("ExportSubject", Root),
		"original code depth must exclude method/nested arrows without hiding the later global export")
}
Test("driver symbols: original brace depth excludes arrow method and nested decoys (driver-production-symbol)",
	_DSFR_With.Bind(_DSFR_ArrowDecoys))
