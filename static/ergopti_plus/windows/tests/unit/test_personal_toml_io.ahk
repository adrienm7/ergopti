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
		_ReadPersonalInfoTomlCache := false
		PersonalInformation := Map("first_name", "Changed")
		PersonalInformationLetters := Map()
		ReadPersonalInfoToml(Path)
		AssertEqual("first_name", PersonalInformationLetters["n"], "cached read must restore letters with info")
	} finally {
		try FileDelete(Path)
		PersonalInformation := SavedInfo
		PersonalInformationLetters := SavedLetters
		_ReadPersonalInfoTomlCache := SavedCache
	}
}
Test("personal TOML: [letters] aliases load and cache atomically (personal-toml-letters-not-loaded)", _PTIO_LoadsLettersAtomically)

; F06 (audit 2026-07-20): WritePersonalToml evicted only its own editor-model cache
; (_ReadPersonalTomlCache), never the raw-content _TomlFileCache that the engine
; loader and prefix-watcher read. So after an editor save, the next live rebuild
; (any tray hotstring toggle -> RebuildHotstringsLive) re-read the stale boot-time
; file content and silently reverted the saved edit. Source-scan the writer body
; (a behavioural call would write to the real PersonalTomlPath) to assert it evicts
; the reader-shared cache via _ParseTomlGroupConfig_InvalidatePath.
_PTIO_WriteEvictsReaderSharedCache() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml must exist in lib/hotstrings/personal_toml_io.ahk")
	Assert(InStr(Body, "_ParseTomlGroupConfig_InvalidatePath") > 0,
		"WritePersonalToml must evict the reader-shared _TomlFileCache (via _ParseTomlGroupConfig_InvalidatePath) so a live rebuild reads the saved edit, not the stale boot-time content")
}
Test("personal TOML: writer evicts the reader-shared raw-content cache (no silent revert)", _PTIO_WriteEvictsReaderSharedCache)
