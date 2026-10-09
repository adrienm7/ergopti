; tests/unit/test_personal_toml_io.ahk

; ==============================================================================
; MODULE: Personal Information TOML Tests
; DESCRIPTION:
; Verifies that the personal-information reader loads both serialized sections.
;
; The writer has always emitted [info] and [letters], but the reader previously
; ignored [letters]. This test keeps the alias map and its cache in the same
; atomic contract as the user-visible value map.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Personal TOML section loading ===========
; =====================================================
; =====================================================

_PTIO_LoadsLettersAtomically() {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	Path := A_Temp . "\\ergopti_personal_toml_letters_test.toml"
	SavedInfo := IsSet(PersonalInformation) ? PersonalInformation : Map()
	SavedLetters := IsSet(PersonalInformationLetters) ? PersonalInformationLetters : Map()
	SavedCache := IsSet(_ReadPersonalInfoTomlCache) ? _ReadPersonalInfoTomlCache : false
	Q := Chr(34)
	try {
		try FileDelete(Path)
		FileAppend("[info]`nfirst_name = " . Q . "Ada" . Q . "`n[letters]`nn = " . Q . "first_name" . Q . "`n", Path, "UTF-8")
		PersonalInformation := Map("first_name", "Default")
		PersonalInformationLetters := Map("p", "first_name")
		_ReadPersonalInfoTomlCache := false
		ReadPersonalInfoToml(Path)
		AssertEqual("Ada", PersonalInformation["first_name"], "[info] must load before aliases resolve")
		AssertEqual("first_name", PersonalInformationLetters["n"], "[letters] alias must be loaded")
		AssertFalse(PersonalInformationLetters.Has("p"), "a present [letters] section must atomically replace stale aliases")
		FileDelete(Path)
		AssertFalse(FileExist(Path), "cache reads must succeed without falling back to the fixture")
		PersonalInformation := Map("first_name", "Changed")
		PersonalInformationLetters := Map()
		ReadPersonalInfoToml(Path)
		AssertEqual("Ada", PersonalInformation["first_name"], "cached read must restore information without disk access")
		AssertEqual("first_name", PersonalInformationLetters["n"], "cached read must restore letters with info")
		PersonalInformation["first_name"] := "Mutated"
		PersonalInformationLetters["n"] := "Mutated"
		ReadPersonalInfoToml(Path)
		AssertEqual("Ada", PersonalInformation["first_name"], "live information mutations must not corrupt the cache")
		AssertEqual("first_name", PersonalInformationLetters["n"], "live alias mutations must not corrupt the cache")
	} finally {
		try FileDelete(Path)
		PersonalInformation := SavedInfo
		PersonalInformationLetters := SavedLetters
		_ReadPersonalInfoTomlCache := SavedCache
	}
}
Test("personal TOML: [letters] aliases load and cache atomically (personal-toml-letters-not-loaded)", _PTIO_LoadsLettersAtomically)

_PTIO_EmptyLettersSectionReplacesAliases() {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	Path := A_Temp . "\ergopti_personal_empty_letters_" . DllCall("GetCurrentProcessId") . ".toml"
	SavedInfo := IsSet(PersonalInformation) ? PersonalInformation : Map()
	SavedLetters := IsSet(PersonalInformationLetters) ? PersonalInformationLetters : Map()
	SavedCache := _ReadPersonalInfoTomlCache
	try {
		for HasLettersSection in [true, false] {
			try FileDelete(Path)
			Content := HasLettersSection
				? _PersonalInfoSerializeCandidate(Map("first_name", "Ada"), Map())
				: '[info]`nfirst_name = "Ada"`n'
			FileAppend(Content, Path, "UTF-8")
			PersonalInformation := Map("first_name", "Default")
			PersonalInformationLetters := Map("p", "first_name")
			_ReadPersonalInfoTomlCache := false
			ReadPersonalInfoToml(Path)
			AssertEqual("Ada", PersonalInformation["first_name"], "the serialized information must load")
			if HasLettersSection
				AssertEqual(0, PersonalInformationLetters.Count, "an explicitly empty section must clear stale aliases")
			else
				AssertEqual("first_name", PersonalInformationLetters["p"], "an omitted section must preserve defaults")
		}
	} finally {
		try FileDelete(Path)
		PersonalInformation := SavedInfo
		PersonalInformationLetters := SavedLetters
		_ReadPersonalInfoTomlCache := SavedCache
	}
}
Test("personal TOML: empty aliases round-trip without reviving defaults (personal-empty-letters)",
	_PTIO_EmptyLettersSectionReplacesAliases)

; F06 (audit 2026-07-20): WritePersonalToml evicted only its own editor-model cache
; (_ReadPersonalTomlCache), never the raw-content _TomlFileCache that the engine
; loader and prefix-watcher read. So after an editor save, the next live rebuild
; (any tray hotstring toggle -> RebuildHotstringsLive) re-read the stale boot-time
; file content and silently reverted the saved edit. Source-scan the writer body
; (a behavioural call would write to the real PersonalTomlPath) to assert it evicts
; the reader-shared cache via _ParseTomlGroupConfig_InvalidatePath.
_PTIO_WriteEvictsReaderSharedCache() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml must exist in infra/hotstrings/personal_toml_io.ahk")
	InvalidateBody := _DriverFuncBody("_PersonalTomlInvalidateCaches")
	Assert(InvalidateBody != "", "the personal TOML cache invalidator must exist")
	Assert(InStr(InvalidateBody, "_ParseTomlGroupConfig_InvalidatePath") > 0,
		"the shared invalidator must evict the reader-shared _TomlFileCache")
	Needle := "_PersonalTomlInvalidateCaches(FilePath)"
	InvalidateCalls := Floor(
		(StrLen(Body) - StrLen(StrReplace(Body, Needle, ""))) / StrLen(Needle))
	Assert(InvalidateCalls >= 2,
		"WritePersonalToml must invalidate before serialization and again after the terminal atomic attempt")
}
Test("personal-toml-cache-race: writer evicts every derived reader cache",
	_PTIO_WriteEvictsReaderSharedCache)





#Include test_personal_toml_atomic.ahk
#Include test_personal_toml_roundtrip.ahk
#Include test_personal_toml_metadata_transactions.ahk
#Include test_personal_toml_live_transactions.ahk
