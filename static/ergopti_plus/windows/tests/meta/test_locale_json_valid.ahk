; tests/meta/test_locale_json_valid.ahk

; ==============================================================================
; MODULE: Locale JSON Validity Test
; DESCRIPTION:
; Ensures every .json file under _shared/data/locales/ is structurally valid:
; parseable by JsonParse, starts with '{', ends with '}', and contains the
; minimum required keys (e.g. _meta.locale, _meta.flag).
;
; MOTIVATION:
; A locale-insertion script once stripped the opening '{' from all 21 locale
; files, causing AHK's t() to crash silently at startup — the driver booted
; with its custom tray icon but no menu and no log entries. This test catches
; that class of corruption before a reload.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; =============================================
; ======= 1/ Locale file listing helper =======
; =============================================
; ============================================

_LocaleListJsonFiles(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_locale_list.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if Line = "" {
			continue
		}
		if not Line ~= "i)\.json$" {
			continue
		}
		Files.Push(Dir . "\" . Line)
	}
	return Files
}

Test_LocaleLoader_ParsesBomJsonAfterCacheMiss() {
	FixturePath := A_Temp . "\\ergopti_locale_bom_" . A_TickCount . ".json"
	FixtureTsv := RegExReplace(FixturePath, "\\.json$", ".tsv")
	try {
		; UTF-8-RAW deliberately preserves the leading BOM: this reproduces a
		; fresh source file with no usable fast-cache.
		FileAppend(Chr(0xFEFF) . '{"fixture.key":"loaded"}', FixturePath, "UTF-8-RAW")
		Loaded := _I18nLoadLocaleMap(FixturePath, "★")
		Assert(Loaded.Ok, "a BOM-prefixed locale source must load after a cache miss")
		Assert(Loaded.Cache.Has("fixture.key"), "BOM-prefixed JSON must retain its key")
		AssertEqual("loaded", Loaded.Cache["fixture.key"])
	} finally {
		try FileDelete(FixturePath)
		try FileDelete(FixtureTsv)
	}
}
Test("locale loader: parses UTF-8 BOM source after cache miss", Test_LocaleLoader_ParsesBomJsonAfterCacheMiss)





; ============================================
; =============================================
; ======= 2/ Locale JSON validity tests =======
; =============================================
; ============================================

_MetaRunLocaleJsonValidTests() {
	; A_ScriptDir = tests/ (set by run_all.ahk, which #Include-s this file)
	; SplitPath(tests/) → windows/
	; SplitPath(windows/) → ergopti_plus/
	; _shared/data/locales lives at ergopti_plus/_shared/data/locales
	SplitPath(A_ScriptDir, , &_LocaleTestDriverDir)
	SplitPath(_LocaleTestDriverDir, , &_LocaleTestEpDir)
	LocaleDir := _LocaleTestEpDir . "\_shared\data\locales"

	Files := _LocaleListJsonFiles(LocaleDir)
	TotalFiles := Files.Length
	ParseErrors   := 0
	StructErrors  := 0
	MissingKeys   := 0
	MissingParityKeys := 0
	ScannedFiles  := 0

	; Required keys that must be present in every locale file.
	; These are the minimum set that t() and the locale picker rely on.
	RequiredKeys := ["_meta.locale", "_meta.flag", "_meta.name"]

	GlobalKeySet := Map()
	ParsedLocales := Map()

	for AbsPath in Files {
		ScannedFiles++
		try {
			Raw := FileRead(AbsPath, "UTF-8")
		} catch {
			ParseErrors++
			OutputDebug("LOCALE ERROR: cannot read " . AbsPath)
			continue
		}

		; Strip BOM if present (AHK FileRead may or may not auto-strip UTF-8 BOM)
		if (Ord(SubStr(Raw, 1, 1)) = 0xFEFF) {
			Raw := SubStr(Raw, 2)
		}

		; Full JSON parse via the i18n module's own parser (also validates envelope)
		Parsed := ""
		try {
			Parsed := JsonParse(Raw)
		} catch as E {
			ParseErrors++
			OutputDebug("LOCALE ERROR: JSON parse failed in " . AbsPath . " — " . E.Message)
		}

		; Check structural envelope independently (catches missing { even if parser is lenient)
		; Trim() removes leading/trailing whitespace including CRLF.
		; Use RegExMatch to check that the file starts with { and ends with }
		; after stripping whitespace — avoids SubStr/StrLen issues with long Unicode content.
		if not (Raw ~= "^\s*\{") {
			StructErrors++
			OutputDebug("LOCALE ERROR: content does not start with '{' in " . AbsPath)
		}
		if not (Raw ~= "\}\s*$") {
			StructErrors++
			OutputDebug("LOCALE ERROR: content does not end with '}' in " . AbsPath)
		}

		if Type(Parsed) == "Map" {
			ParsedLocales[AbsPath] := Parsed
			for Key, _ in Parsed {
				GlobalKeySet[Key] := true
			}
		}

		; Verify required keys are present
		if Type(Parsed) == "Map" {
			for Key in RequiredKeys {
				if not Parsed.Has(Key) {
					MissingKeys++
					OutputDebug("LOCALE ERROR: missing required key '" . Key . "' in " . AbsPath)
				}
			}
		}
	}

	for AbsPath, Parsed in ParsedLocales {
		for Key, _ in GlobalKeySet {
			if not Parsed.Has(Key) {
				MissingParityKeys++
			}
		}
	}

	TotalErrors := ParseErrors + StructErrors + MissingKeys + MissingParityKeys

	_MetaLocaleParseResult() {
		Assert(ParseErrors = 0,
			"Found " . ParseErrors . " locale file(s) with JSON parse errors — check for malformed JSON")
	}
	Test("meta locales: all " . TotalFiles . " JSON files are parseable (" . ParseErrors . " error(s))", _MetaLocaleParseResult)

	_MetaLocaleStructResult() {
		Assert(StructErrors = 0,
			"Found " . StructErrors . " locale file(s) missing opening '{' or closing '}' — check for truncated files")
	}
	Test("meta locales: all JSON files have valid '{...}' envelope (" . StructErrors . " error(s))", _MetaLocaleStructResult)

	_MetaLocaleRequiredKeysResult() {
		Assert(MissingKeys = 0,
			"Found " . MissingKeys . " missing required key(s) across locale files — _meta.locale, _meta.flag, _meta.name must be present")
	}
	Test("meta locales: all required keys present (" . MissingKeys . " missing)", _MetaLocaleRequiredKeysResult)

	_MetaLocaleParityResult() {
		Assert(MissingParityKeys = 0,
			"Found " . MissingParityKeys . " missing parity key(s) across locale files. All locales must have the exact same set of keys.")
	}
	Test("meta locales: all locales have complete key parity (" . MissingParityKeys . " missing)", _MetaLocaleParityResult)
}

_MetaRunLocaleJsonValidTests()
