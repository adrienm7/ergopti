; tests/unit/hotstrings/engine/personal/test_info_source_witness.ahk
; Real personal-information saves must not replace a source changed while the
; candidate was being staged. The only injected boundary writes the real stage
; before making an independently readable competing source.
#Requires AutoHotkey v2.0

_PISW_Image(First, Last) {
	return '[info]`nfirst_name = "' . First . '"`nlast_name = "' . Last
		. '"`n`n[letters]`np = "first_name"`nn = "last_name"`n'
}

_PISW_Stage(Receipt, Mode, Path, StagePath, Content) {
	Receipt["calls"] += 1
	Receipt["stage"] := StagePath
	try {
		Written := FSWriteDurable(StagePath, Content)
		if !(Written is Integer) || Written != 1
			throw Error("The native candidate stage was not written.")
		Receipt["staged"] := FileRead(StagePath, "RAW")
		if Mode == "delete" {
			FSDeleteStrict(Path)
		} else if Mode != "live" {
			if Mode == "create" && FSStrictExists(Path)
				throw Error("The competing creation requires an absent native source.")
			Written := FSWriteDurable(Path, _PISW_Image("Zoë", "Concurrent"))
			if !(Written is Integer) || Written != 1
				throw Error("The competing personal-information source was not written.")
			Receipt["winner"] := FileRead(Path, "RAW")
		}
		return 1
	} catch as Err {
		; The production writer catches adapter exceptions; retain the genuine
		; setup failure so a broken fixture cannot look like a safe refusal.
		Receipt["error"] := Err
		return 0
	}
}

_PISW_Bytes(Expected, Actual, Message) {
	AssertTrue(Expected is Buffer && Actual is Buffer, Message)
	AssertEqual(Expected.Size, Actual.Size, Message)
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, Message)
}

_PISW_Run(Mode, Path) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global HSE_RuntimeDecisionGeneration
	Generation := HSE_RuntimeDecisionGeneration
	Receipt := Map("calls", 0, "stage", "", "error", 0)
	try {
		if Mode == "create"
			AssertFalse(FSStrictExists(Path), "the create control must begin with an absent source")
		if Mode != "create" {
			AssertEqual(1, FSWriteDurable(Path, _PISW_Image("André", "Initial")))
			ReadPersonalInfoToml(Path)
			AssertEqual("André", PersonalInformation["first_name"],
				"the public reader must admit the initial real source")
		}
		BeforeInformation := PersonalInformation
		BeforeLetters := PersonalInformationLetters
		BeforeName := BeforeInformation["first_name"]
		Result := PersonalInfoCommitValues(Path, Map("first_name", "Edited"),
			_PISW_Stage.Bind(Receipt, Mode, Path))
		if IsObject(Receipt["error"])
			throw Receipt["error"]
		AssertEqual(1, Receipt["calls"], "the actual stage writer must run once")
		AssertTrue(Receipt["staged"].Size > 0, "the native stage must contain bytes")
		if Mode == "live" {
			_PISW_Bytes(Receipt["staged"], FileRead(Path, "RAW"),
				"the uninterrupted transaction must publish its real stage")
			AssertTrue(Result is Integer && Result == 1)
			AssertEqual("Edited", PersonalInformation["first_name"])
		} else {
			; The source oracle comes before the receipt: the old implementation
			; must fail for overwriting the winning source, not for its API shape.
			if Mode == "delete"
				AssertFalse(FSStrictExists(Path), "a competing deletion must remain absent")
			else
				_PISW_Bytes(Receipt["winner"], FileRead(Path, "RAW"),
					"a competing identity must remain byte-for-byte authoritative")
			AssertTrue(Result is Integer && Result == 0)
			AssertTrue(PersonalInformation == BeforeInformation,
				"a refused source must not publish the detached identity map")
			AssertTrue(PersonalInformationLetters == BeforeLetters)
			AssertEqual(BeforeName, PersonalInformation["first_name"])
			AssertEqual(Generation, HSE_RuntimeDecisionGeneration)
		}
		AssertFalse(FSStrictExists(Receipt["stage"]),
			"both acknowledged and refused stages must be retired")
		Lease := _PersonalTomlWriteLeaseTryAcquire(Path, "personal-info-witness-control")
		AssertTrue(Lease is Object, "the completed transaction must release its exact lease")
		try AssertTrue(_PersonalTomlWriteLeaseOwns(Lease, Path))
		finally _PersonalTomlWriteLeaseRelease(Lease)
		if Mode != "delete" {
			AssertFalse(_ReadPersonalInfoTomlCache,
				"the terminal save must invalidate the previous read projection")
			ReadPersonalInfoToml(Path)
			AssertEqual(Mode == "live" ? "Edited" : "Zoë",
				PersonalInformation["first_name"],
				"the actual reader must recover the authoritative durable identity")
		}
	} finally {
		HSE_RuntimeDecisionGeneration := Generation
		; A failing old implementation still leaves no private stage behind.
		if Receipt["stage"] != ""
			FSDeleteStrict(Receipt["stage"])
	}
}

_PISW_Utf16Run(Path, Literal := false) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global HSE_RuntimeDecisionGeneration
	Generation := HSE_RuntimeDecisionGeneration
	Source := _PISW_Image("Zoë", "Native BOM")
	if Literal
		Source := StrReplace(Source, 'first_name = "Zoë"', "first_name = " . Chr(39) . "Zoë" . Chr(39), true)
	try {
		File := FSOpenStrict(Path, "w", "UTF-16")
		AssertTrue(IsObject(File), "the native UTF-16 fixture writer must open")
		try File.Write(Source)
		finally File.Close()
		Bytes := FSReadBytesStrict(Path)
		AssertEqual(2 + StrLen(Source) * 2, Bytes.Size,
			"the fixture must contain one BOM and exactly the UTF-16 source")
		AssertEqual(0xFEFF, NumGet(Bytes, 0, "UShort"),
			"the positive control must exercise native BOM detection")
		ReadPersonalInfoToml(Path)
		AssertEqual("Zoë", PersonalInformation["first_name"],
			"the existing public reader admits the UTF-16 identity")
		Result := PersonalInfoCommitValues(Path, Map("first_name", "Édited"))
		AssertTrue(Result is Integer && Result == 1,
			"adding a source witness must retain an admitted native-BOM source")
		AssertEqual("Édited", PersonalInformation["first_name"])
		AssertEqual("Native BOM", PersonalInformation["last_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
		AssertFalse(_ReadPersonalInfoTomlCache)
		ReadPersonalInfoToml(Path)
		AssertEqual("Édited", PersonalInformation["first_name"],
			"the actual native publisher must remain readable after the edit")
		AssertEqual("Native BOM", PersonalInformation["last_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
	} finally HSE_RuntimeDecisionGeneration := Generation
}

_PISW_Case(Mode) {
	global PersonalInformation, PersonalInformationLetters
	global _ReadPersonalInfoTomlCache, ScriptInformation, _TomlUnreadableFiles
	static Sequence := 0
	HadInformation := IsSet(PersonalInformation)
	OldInformation := HadInformation ? PersonalInformation : 0
	HadLetters := IsSet(PersonalInformationLetters)
	OldLetters := HadLetters ? PersonalInformationLetters : 0
	OldCache := _ReadPersonalInfoTomlCache
	HadPath := ScriptInformation.Has("PersonalInfoTomlPath")
	OldPath := ScriptInformation.Get("PersonalInfoTomlPath", "")
	Root := A_Temp . "\ergopti_personal_info_source_" . A_ScriptHwnd
		. "_" . A_TickCount . "_" . ++Sequence
	Path := Root . "\personal_info.toml"
	; A collision fails before entering cleanup or adopting any existing file.
	FSCreateDirectoryExclusiveStrict(Root)
	try {
		PersonalInformation := Map("first_name", "Old", "last_name", "Before")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		if Mode == "utf16" || Mode == "utf16-literal"
			_PISW_Utf16Run(Path, Mode == "utf16-literal")
		else
			_PISW_Run(Mode, Path)
	} finally {
		PersonalInformation := HadInformation ? OldInformation : unset
		PersonalInformationLetters := HadLetters ? OldLetters : unset
		_ReadPersonalInfoTomlCache := OldCache
		if HadPath
			ScriptInformation["PersonalInfoTomlPath"] := OldPath
		else
			ScriptInformation.Delete("PersonalInfoTomlPath")
		if IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
			_TomlUnreadableFiles.Delete(Path)
		DirDelete(Root, true)
	}
}

Test("personal info source: external edit during staging is retained (personal-info-source-witness)",
	_PISW_Case.Bind("change"))
Test("personal info source: external creation during staging is retained (personal-info-source-witness)",
	_PISW_Case.Bind("create"))
Test("personal info source: external deletion during staging is retained (personal-info-source-witness)",
	_PISW_Case.Bind("delete"))
Test("personal info source: uninterrupted native save publishes and reloads (personal-info-source-witness)",
	_PISW_Case.Bind("live"))
Test("personal info source: admitted UTF-16 BOM identity still saves and reloads (personal-info-source-witness)",
	_PISW_Case.Bind("utf16"))

_PISYN_Display(Value) => JsonStringLiteral(Value is String ? Value : "<" . Type(Value) . ">")

_PISYN_PublicRoundTrip(Mode) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global ScriptInformation, _TomlUnreadableFiles, HSE_RuntimeDecisionGeneration
	HadInfo := IsSet(PersonalInformation), OldInfo := HadInfo ? PersonalInformation : 0
	HadLetters := IsSet(PersonalInformationLetters), OldLetters := HadLetters ? PersonalInformationLetters : 0
	OldCache := _ReadPersonalInfoTomlCache, OldGeneration := HSE_RuntimeDecisionGeneration
	HadPath := ScriptInformation.Has("PersonalInfoTomlPath"), OldPath := ScriptInformation.Get("PersonalInfoTomlPath", "")
	Root := A_Temp . "\ergopti_personal_info_projection_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\personal_info.toml", Created := false
	try {
		AssertFalse(A_IsSuspended)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		; These are actual declared field/alias identities, detached from user data.
		PersonalInformation := Map("first_name", "PlaceholderFirst", "last_name", "PlaceholderLast")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		First := Mode == "unsupported-info-type" ? 42 : Mode == "bare-date-type" ? "1979-05-27"
			: Mode == "multiline-literal-control" ? "Ada'#Place" : Mode == "quoted-hash-control" ? "Ada#Place" : "Ada"
		RawFirst := Mode == "unsupported-info-type" ? "42" : Mode == "bare-date-type" ? "1979-05-27"
			: Mode == "multiline-literal-control" ? Chr(39) . Chr(39) . Chr(39) . First . Chr(39) . Chr(39) . Chr(39)
			: Mode == "literal-info" ? "'Ada'" : Mode == "multiline-info" ? Chr(34) . Chr(34) . Chr(34) . "Ada" . Chr(34) . Chr(34) . Chr(34) : TOML_RenderString(First)
		InfoHeader := Mode == "header-comment" ? "[info] # valid annotation" : "[info]"
		RawLetter := Mode == "literal-letter" ? "'first_name'" : TOML_RenderString("first_name")
		Source := InfoHeader . "`nfirst_name = " . RawFirst . '`nlast_name = "Initial"`n'
			. "[letters]`np = " . RawLetter . '`nn = "last_name"`n'
		if Mode == "inline-control"
			Source := 'info = { first_name = "Ada", last_name = "Initial" }`nletters = { p = "first_name", n = "last_name" }`n'
		else if Mode == "dotted-control"
			Source := 'info.first_name = "Ada"`ninfo.last_name = "Initial"`nletters.p = "first_name"`nletters.n = "last_name"`n'
		AssertTrue(FSWriteCreateDurable(Path, Source))
		Independent := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(First, Independent["info"]["first_name"], "the actual canonical decoder accepts this genuine TOML source")
		AssertEqual("first_name", Independent["letters"]["p"])
		ReadPersonalInfoToml(Path)
		ReadFirst := PersonalInformation["first_name"]
		ReadLetter := PersonalInformationLetters.Get("p", "_missing_")
		Opening := _PersonalInfoCaptureEditorSource(Path)
		Result := PersonalInfoCommitValues(Path, Map("last_name", "Edited"), 0, 0, 0, 0, Opening)
		After := FSReadUtf8Exact(Path)
		Disk := TOML_ParseDocument(After)
		_TestPrint("# personal-info-projection mode=" . Mode . " ack=" . Result
			. " read_first=" . _PISYN_Display(ReadFirst) . " read_alias=" . _PISYN_Display(ReadLetter)
			. " disk_first=" . _PISYN_Display(Disk["info"].Get("first_name", "_missing_"))
			. " disk_alias=" . _PISYN_Display(Disk.Get("letters", Map()).Get("p", "_missing_")))
		if Mode == "unsupported-info-type" || Mode == "bare-date-type" {
			AssertFalse(Result, "a non-String owned field must refuse the public save; preserving its number is not a valid admission")
			AssertEqual(Source, After, "a refused unsupported owned type must preserve every original source byte")
			return
		}
		if InStr(Mode, "control") > 0
			AssertTrue(Result, "an ordinary representable source must retain the true public persistence route")
		if !Result {
			AssertEqual(Source, After, "a projection that cannot represent its owned source must refuse without rewriting any byte")
			return
		}
		AssertEqual(First, Disk["info"].Get("first_name", "_missing_"), "editing last_name cannot erase a correctly authored first_name omitted by the loader")
		AssertEqual("first_name", Disk.Get("letters", Map()).Get("p", "_missing_"), "an unrelated info edit cannot erase a correctly authored letter alias")
		AssertEqual("Edited", Disk["info"]["last_name"])
		AssertEqual(First, PersonalInformation["first_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
		ReadPersonalInfoToml(Path)
		AssertEqual(First, PersonalInformation["first_name"], "the genuine reloaded owner retains the original source field")
		AssertEqual("Edited", PersonalInformation["last_name"])
		AssertEqual("first_name", PersonalInformationLetters["p"])
	} finally {
		PersonalInformation := HadInfo ? OldInfo : unset
		PersonalInformationLetters := HadLetters ? OldLetters : unset
		_ReadPersonalInfoTomlCache := OldCache
		HSE_RuntimeDecisionGeneration := OldGeneration
		if HadPath
			ScriptInformation["PersonalInfoTomlPath"] := OldPath
		else
			ScriptInformation.Delete("PersonalInfoTomlPath")
		if _TomlUnreadableFiles.Has(Path)
			_TomlUnreadableFiles.Delete(Path)
		if Created
			DirDelete(Root, true)
	}
}
for _PISYN_Mode in ["literal-info", "multiline-info", "header-comment", "literal-letter", "unsupported-info-type", "basic-control", "quoted-hash-control"]
	Test("personal info source projection: " . _PISYN_Mode, _PISYN_PublicRoundTrip.Bind(_PISYN_Mode))

Test("personal info source: actual UTF-16 BOM literal identity still saves and reloads (personal-info-canonical-grammar)",
	_PISW_Case.Bind("utf16-literal"))
for _PICAL_Mode in ["inline-control", "dotted-control", "multiline-literal-control", "bare-date-type"]
	Test("personal info canonical grammar: " . _PICAL_Mode . " (personal-info-canonical-grammar)",
		_PISYN_PublicRoundTrip.Bind(_PICAL_Mode))

_PIENC_Bytes(Source, Utf16 := false, Bom := false) {
	if Utf16 {
		Count := StrLen(Source) * 2
		Encoded := Buffer(Count + 2, 0)
		StrPut(Source, Encoded, StrLen(Source) + 1, "UTF-16")
		Result := Buffer(2 + Count, 0)
		NumPut("UShort", 0xFEFF, Result)
		DllCall("ntdll\RtlMoveMemory", "Ptr", Result.Ptr + 2, "Ptr", Encoded, "UPtr", Count)
		return Result
	}
	Count := StrPut(Source, "UTF-8") - 1
	Encoded := Buffer(Count + 1, 0)
	StrPut(Source, Encoded, Count + 1, "UTF-8")
	Offset := Bom ? 3 : 0
	Result := Buffer(Offset + Count, 0)
	if Bom {
		NumPut("UChar", 0xEF, Result, 0)
		NumPut("UChar", 0xBB, Result, 1)
		NumPut("UChar", 0xBF, Result, 2)
	}
	DllCall("ntdll\RtlMoveMemory", "Ptr", Result.Ptr + Offset, "Ptr", Encoded, "UPtr", Count)
	return Result
}
_PIENC_Case(Kind) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global ScriptInformation, _TomlUnreadableFiles, HSE_RuntimeDecisionGeneration
	Saved := {hadInfo: IsSet(PersonalInformation), hadLetters: IsSet(PersonalInformationLetters),
		cache: _ReadPersonalInfoTomlCache, generation: HSE_RuntimeDecisionGeneration,
		hadPath: ScriptInformation.Has("PersonalInfoTomlPath"), path: ScriptInformation.Get("PersonalInfoTomlPath", "")}
	Saved.info := Saved.hadInfo ? PersonalInformation : 0
	Saved.letters := Saved.hadLetters ? PersonalInformationLetters : 0
	Root := A_Temp . "\ergopti_personal_info_encoding_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\personal_info.toml", Created := false
	try {
		AssertFalse(A_IsSuspended)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		PersonalInformation := Map("first_name", "Placeholder", "last_name", "Before")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		Invalid := Kind == "invalid-utf8" || Kind == "odd-utf16"
			|| Kind == "embedded-nul-utf8" || Kind == "lone-surrogate-utf16"
		First := (Kind == "invalid-utf8" || Kind == "embedded-nul-utf8" || Kind == "lone-surrogate-utf16") ? "A?B" : "Zoë😀"
		Source := _PISW_Image(First, "Initial")
		Utf16 := Kind == "utf16-control" || Kind == "odd-utf16" || Kind == "lone-surrogate-utf16"
		Input := _PIENC_Bytes(Source, Utf16, Kind == "utf8-bom-control")
		if Kind == "invalid-utf8" || Kind == "embedded-nul-utf8" {
			AssertEqual(StrLen(Source), Input.Size, "the injected marker subject is genuinely ASCII before corruption")
			Marker := InStr(Source, "?", true)
			AssertTrue(Marker > 0)
			NumPut("UChar", Kind == "invalid-utf8" ? 0xFF : 0, Input, Marker - 1)
		} else if Kind == "lone-surrogate-utf16" {
			Marker := InStr(Source, "?", true)
			AssertTrue(Marker > 0)
			MarkerOffset := 2 + (Marker - 1) * 2
			AssertEqual(Ord("?"), NumGet(Input, MarkerOffset, "UShort"))
			NumPut("UShort", 0xD800, Input, MarkerOffset)
		} else if Kind == "odd-utf16" {
			Odd := Buffer(Input.Size + 1, 0)
			DllCall("ntdll\RtlMoveMemory", "Ptr", Odd, "Ptr", Input, "UPtr", Input.Size)
			NumPut("UChar", 0x41, Odd, Input.Size)
			Input := Odd
		}
		FileHandle := FSOpenStrict(Path, "w", "UTF-8-RAW")
		AssertTrue(IsObject(FileHandle))
		try AssertEqual(Input.Size, FileHandle.RawWrite(Input, Input.Size), "the native fixture writes its complete nonempty byte image")
		finally FileHandle.Close()
		Before := FSReadBytesStrict(Path)
		_PISW_Bytes(Input, Before, "the physical source must contain exactly the independently constructed bytes")
		if Kind == "invalid-utf8" {
			AssertEqual(0xFF, NumGet(Before, Marker - 1, "UChar"), "the real source contains a byte forbidden in UTF-8")
			AssertFalse(FSReadUtf8Exact(Path) is String, "the genuine strict native decoder must independently reject this UTF-8 image")
		} else if Kind == "embedded-nul-utf8" {
			AssertEqual(Ord("A"), NumGet(Before, Marker - 2, "UChar"))
			AssertEqual(0, NumGet(Before, Marker - 1, "UChar"), "the native UTF-8 source physically contains NUL inside its quoted field")
			AssertEqual(Ord("B"), NumGet(Before, Marker, "UChar"))
		} else if Utf16 {
			AssertEqual(0xFEFF, NumGet(Before, 0, "UShort"))
			AssertEqual(Kind == "odd-utf16" ? 1 : 0, Mod(Before.Size, 2))
			if Kind == "lone-surrogate-utf16" {
				AssertEqual(Ord("A"), NumGet(Before, MarkerOffset - 2, "UShort"))
				AssertEqual(0xD800, NumGet(Before, MarkerOffset, "UShort"), "the actual source contains an unmatched high surrogate")
				AssertEqual(Ord("B"), NumGet(Before, MarkerOffset + 2, "UShort"), "the next actual unit is not a low surrogate")
			}
		}
		if !Invalid {
			NativeDecoded := FileRead(Path, "UTF-8")
			if SubStr(NativeDecoded, 1, 1) == Chr(0xFEFF)
				NativeDecoded := SubStr(NativeDecoded, 2)
			AssertEqual(Source, NativeDecoded, "the positive control must be independently readable through native BOM detection")
		}
		ReadPersonalInfoToml(Path)
		Opening := _PersonalInfoCaptureEditorSource(Path)
		Result := PersonalInfoCommitValues(Path, Map("last_name", "Edited"), 0, 0, 0, 0, Opening)
		After := FSReadBytesStrict(Path)
		_TestPrint("# personal-info-encoding kind=" . Kind . " result=" . Result . " before-bytes=" . Before.Size
			. " after-bytes=" . After.Size . " latched=" . _TomlUnreadableFiles.Has(Path))
		if Invalid {
			AssertFalse(Result, "an unreadable original encoding must refuse an unrelated field edit instead of normalizing away its bytes")
			_PISW_Bytes(Before, After, "an unsupported source encoding must remain byte-for-byte unchanged")
			AssertTrue(_TomlUnreadableFiles.Has(Path), "the public reader must fence its unrepresentable decoded model")
		} else {
			AssertTrue(Result, "valid native UTF-8/UTF-16 source protocols retain the true public persistence route")
			Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual(First, Disk["info"]["first_name"])
			AssertEqual("Edited", Disk["info"]["last_name"])
			_ReadPersonalInfoTomlCache := false
			ReadPersonalInfoToml(Path)
			AssertEqual(First, PersonalInformation["first_name"])
			AssertEqual("Edited", PersonalInformation["last_name"])
		}
	} finally {
		PersonalInformation := Saved.hadInfo ? Saved.info : unset
		PersonalInformationLetters := Saved.hadLetters ? Saved.letters : unset
		_ReadPersonalInfoTomlCache := Saved.cache
		HSE_RuntimeDecisionGeneration := Saved.generation
		if Saved.hadPath
			ScriptInformation["PersonalInfoTomlPath"] := Saved.path
		else
			ScriptInformation.Delete("PersonalInfoTomlPath")
		if _TomlUnreadableFiles.Has(Path)
			_TomlUnreadableFiles.Delete(Path)
		if Created
			DirDelete(Root, true)
	}
}
for _PIENC_Kind in ["invalid-utf8", "odd-utf16", "utf8-control", "utf8-bom-control", "utf16-control"]
	Test("personal info encoding admission: " . _PIENC_Kind . " (personal-info-encoding)", _PIENC_Case.Bind(_PIENC_Kind))

for _PIENC_ExtraKind in ["lone-surrogate-utf16", "embedded-nul-utf8"]
	Test("personal info encoding admission: " . _PIENC_ExtraKind . " (personal-info-encoding)", _PIENC_Case.Bind(_PIENC_ExtraKind))

; The WebView bridge forwards JsonParse(...)["values"] directly to the public
; commit route. JSON string values may contain NUL, unlike native Map keys.
_PIWS_Case(Kind, Direct := false) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global ScriptInformation, _TomlUnreadableFiles, HSE_RuntimeDecisionGeneration
	Saved := {hadInfo: IsSet(PersonalInformation), hadLetters: IsSet(PersonalInformationLetters),
		cache: _ReadPersonalInfoTomlCache, generation: HSE_RuntimeDecisionGeneration,
		hadPath: ScriptInformation.Has("PersonalInfoTomlPath"), path: ScriptInformation.Get("PersonalInfoTomlPath", "")}
	Saved.info := Saved.hadInfo ? PersonalInformation : 0
	Saved.letters := Saved.hadLetters ? PersonalInformationLetters : 0
	Root := A_Temp . "\ergopti_personal_info_write_scalar_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\personal_info.toml", Created := false
	try {
		AssertFalse(A_IsSuspended)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		PersonalInformation := Map("first_name", "Placeholder", "last_name", "Before")
		PersonalInformationLetters := Map("p", "first_name", "n", "last_name")
		_ReadPersonalInfoTomlCache := false
		ScriptInformation["PersonalInfoTomlPath"] := Path
		AssertEqual(1, FSWriteDurable(Path, _PISW_Image("Initial", "Untouched")))
		ReadPersonalInfoToml(Path)
		AssertEqual("Initial", PersonalInformation["first_name"])
		Before := FSReadBytesStrict(Path)
		OpeningInformation := PersonalInformation, OpeningLetters := PersonalInformationLetters
		OpeningGeneration := HSE_RuntimeDecisionGeneration
		Opening := _PersonalInfoCaptureEditorSource(Path)
		Encoded := Kind == "nul" ? 'A\u0000B' : Kind == "control" ? 'A\u0001B' : 'A\\u0000B'
		Payload := JsonParse('{"action":"save","values":{"first_name":"' . Encoded . '"}}')
		Value := Payload["values"]["first_name"]
		AssertTrue(Value is String)
		if Kind != "literal" {
			AssertEqual(3, StrLen(Value), "the actual bridge parser retains all three UTF-16 units")
			AssertEqual(65, NumGet(StrPtr(Value), 0, "UShort"))
			AssertEqual(Kind == "nul" ? 0 : 1, NumGet(StrPtr(Value), 2, "UShort"))
			AssertEqual(66, NumGet(StrPtr(Value), 4, "UShort"))
		} else
			AssertEqual('A\u0000B', Value, "literal backslash spelling is ordinary representable text")
		if Direct {
			Candidate := PersonalInformation.Clone()
			Candidate["first_name"] := Value
			Result := WritePersonalInfoToml(Path, Candidate, PersonalInformationLetters,
				0, 0, 0, 0, 0, 0, Opening)
		} else
			Result := PersonalInfoCommitValues(Path, Payload["values"], 0, 0, 0, 0, Opening)
		After := FSReadBytesStrict(Path)
		DiskAccepted := false
		try {
			Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
			DiskAccepted := true
		}
		_TestPrint("# personal-info-write-scalar kind=" . Kind . " result=" . Result
			. " parsed=" . DiskAccepted . " before-bytes=" . Before.Size . " after-bytes=" . After.Size)
		_TestPrint("# personal-info-write-scalar candidate=" . _PIWS_Units(Value)
			. " live=" . _PIWS_Units(PersonalInformation["first_name"])
			. " disk=" . (DiskAccepted ? _PIWS_Units(Document["info"]["first_name"]) : "<refused>"))
		if Kind == "nul" {
			AssertFalse(Result, "a public edit must refuse a value its canonical reader cannot represent")
			_PISW_Bytes(Before, After, "refusing an unsupported value must preserve the original durable identity")
			AssertTrue(PersonalInformation == OpeningInformation)
			AssertTrue(PersonalInformationLetters == OpeningLetters)
			AssertEqual(OpeningGeneration, HSE_RuntimeDecisionGeneration)
		} else {
			AssertTrue(Result, "representable escaped controls and literal backslashes remain writable")
			AssertTrue(DiskAccepted, "an acknowledged personal-information image must be readable")
			AssertEqual(StrLen(Value), StrLen(Document["info"]["first_name"]))
			AssertEqual(Value, Document["info"]["first_name"])
			AssertEqual("Untouched", Document["info"]["last_name"])
		}
		_ReadPersonalInfoTomlCache := false
		ReadPersonalInfoToml(Path)
		AssertFalse(_TomlUnreadableFiles.Has(Path), "refused edits and acknowledged controls must remain reloadable")
		AssertEqual(Kind == "nul" ? "Initial" : Value, PersonalInformation["first_name"])
		AssertEqual("Untouched", PersonalInformation["last_name"])
	} finally {
		PersonalInformation := Saved.hadInfo ? Saved.info : unset
		PersonalInformationLetters := Saved.hadLetters ? Saved.letters : unset
		_ReadPersonalInfoTomlCache := Saved.cache
		HSE_RuntimeDecisionGeneration := Saved.generation
		if Saved.hadPath
			ScriptInformation["PersonalInfoTomlPath"] := Saved.path
		else
			ScriptInformation.Delete("PersonalInfoTomlPath")
		if _TomlUnreadableFiles.Has(Path)
			_TomlUnreadableFiles.Delete(Path)
		if Created
			DirDelete(Root, true)
	}
}
for _PIWS_Kind in ["nul", "control", "literal"]
	Test("personal info write scalar admission: " . _PIWS_Kind . " (personal-info-write-scalar)", _PIWS_Case.Bind(_PIWS_Kind))

_PIWS_Units(Value) {
	Units := "length=" . StrLen(Value) . ":"
	Loop StrLen(Value)
		Units .= Format("{:04X}", NumGet(StrPtr(Value), (A_Index - 1) * 2, "UShort")) . ","
	return Units
}

Test("personal info direct writer scalar admission: nul (personal-info-write-scalar-direct)", _PIWS_Case.Bind("nul", true))
Test("personal info direct writer scalar admission: control (personal-info-write-scalar-direct)", _PIWS_Case.Bind("control", true))
