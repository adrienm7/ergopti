; tests/unit/modules/hotstrings/personal/test_personal_info_source_witness.ahk
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

_PISW_Utf16Run(Path) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	global HSE_RuntimeDecisionGeneration
	Generation := HSE_RuntimeDecisionGeneration
	Source := _PISW_Image("Zoë", "Native BOM")
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
		if Mode == "utf16"
			_PISW_Utf16Run(Path)
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
