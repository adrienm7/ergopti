; tests/meta/corpus/test_corpus_logger_parity.ahk

; ==============================================================================
; MODULE: Logger Parity Corpus Consumer (AHK)
; DESCRIPTION:
; Replays the sections of _shared/tests/corpus/logger/parity_vectors.json that
; name this driver: the stored log level, a failed format, and the retention of
; dated and topical files. The macOS and Linux suites replay the same file, so
; a rule cannot change on one driver without the corpus saying so.
;
; CONTRACT:
; 1. The corpus is readable and every replayed section is non-empty.
; 2. LoggerResolveLevel gives each case's level, threshold and refusal, and
;    LOGGER_DEFAULT_LEVEL is the corpus default.
; 3. A failed Format keeps the template and appends the shared marker; a
;    well-formed line carries none.
; 4. _LoggerDatedLogExpired and _LoggerTopicalLogStale give each case's verdict.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Helpers ===================
; ======================================
; ======================================

; "YYYY-MM-DD HH:MM:SS" to the YYYYMMDDHH24MISS stamp AHK date functions read.
; @param Text {String}
; @returns {String}
_LogParity_Stamp(Text) {
	return RegExReplace(Text, "[^0-9]")
}

; Emits one INFO line through the test sink with a clean dedup state and repeat
; collapsing disarmed, and returns its body (the text after "[INFO] [tag] ").
; @param Template {String}
; @param Argument {Any}
; @returns {String}
_LogParity_EmitBody(Template, Argument) {
	global LOGGER_MIN_LEVEL, _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT, _LOGGER_REPEAT_ENABLED
	Lines := []
	PreviousLevel := LOGGER_MIN_LEVEL
	WasArmed := _LOGGER_REPEAT_ENABLED
	if WasArmed
		_LoggerRepeatDisable()
	LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_COUNT := 0
	try {
		LoggerSetTestSink((Line) => Lines.Push(Line))
		LoggerInfo("LogParity", Template, Argument)
	} finally {
		LoggerClearTestSink()
		LOGGER_MIN_LEVEL := PreviousLevel
		_LoggerRefreshFastFlags()
		if WasArmed
			_LoggerRepeatEnable()
	}
	AssertEqual(1, Lines.Length, "exactly one line must reach the sink")
	Marker := "[INFO] [LogParity] "
	At := InStr(Lines[1], Marker)
	AssertTrue(At > 0, "the line must carry its level and tag: " . Lines[1])
	return SubStr(Lines[1], At + StrLen(Marker))
}




; ======================================
; ======================================
; ======= 2/ Cases =====================
; ======================================
; ======================================

_LogParity_RunAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\logger\parity_vectors.json"

	_LogParity_FileExists() {
		AssertTrue(FileExist(CorpusPath) != "", "logger parity corpus must exist at: " . CorpusPath)
	}
	Test("logger parity corpus: file exists", _LogParity_FileExists)
	if !FileExist(CorpusPath)
		return
	Data := JsonParse(FileRead(CorpusPath, "UTF-8"))

	_LogParity_Sections() {
		for Name in ["level_setting", "detailed_log", "format_failure", "dated_retention", "topical_retention"] {
			AssertTrue(Data.Has(Name) && Data[Name]["cases"].Length > 0, "the " . Name . " section is empty")
			Named := false
			for Driver in Data[Name]["drivers"]
				Named := Named || Driver == "windows"
			AssertTrue(Named, "the " . Name . " section must name the windows driver it is replayed on")
		}
	}
	Test("logger parity corpus: replayed sections present and non-empty", _LogParity_Sections)

	_LogParity_Default() {
		global LOGGER_DEFAULT_LEVEL
		AssertEqual(Data["level_setting"]["default"], LOGGER_DEFAULT_LEVEL,
			"LOGGER_DEFAULT_LEVEL must be the declared default the corpus records")
	}
	Test("logger parity corpus: the default level is the declared one", _LogParity_Default)

	_LogParity_MakeLevelCase(Vector) {
		_Run() {
			global LOGGER_SEVERITY, LOGGER_DEFAULT_LEVEL
			; An absent key reaches the resolver as the IniCacheGet default.
			Stored := Vector.Has("stored_absent") ? LOGGER_DEFAULT_LEVEL : Vector["stored"]
			Resolved := LoggerResolveLevel(Stored)
			AssertEqual(Vector["level"], Resolved["level"], Vector["id"] . ": level")
			AssertEqual(Vector["threshold"], LOGGER_SEVERITY[Resolved["level"]], Vector["id"] . ": threshold")
			AssertEqual(Vector["refused"] ? true : false, Resolved["refused"], Vector["id"] . ": refused")
		}
		return _Run
	}
	for _, Vector in Data["level_setting"]["cases"]
		Test("logger parity level_setting: " . Vector["id"], _LogParity_MakeLevelCase(Vector))

	_LogParity_MakeDetailedCase(Vector) {
		_Run() {
			global LOGGER_DEFAULT_LEVEL
			; An absent key reaches the resolver as the IniCacheGet default.
			Stored := Vector.Has("stored_absent") ? LOGGER_DEFAULT_LEVEL : Vector["stored"]
			AssertEqual(Vector["ticked"] ? true : false, LoggerIsDetailed(Stored) ? true : false,
				Vector["id"] . ": ticked")
			AssertEqual(Vector["click_stores"], LoggerDetailedToggleTarget(Stored),
				Vector["id"] . ": the level a click stores")
		}
		return _Run
	}
	for _, Vector in Data["detailed_log"]["cases"]
		Test("logger parity detailed_log: " . Vector["id"], _LogParity_MakeDetailedCase(Vector))

	_LogParity_MakeFormatCase(Vector) {
		_Run() {
			Template := Vector["ahk_template"]
			Argument := Vector["argument"] == "object" ? Map() : Vector["argument"]
			Body := _LogParity_EmitBody(Template, Argument)
			Marker := Data["format_failure"]["marker"]
			if Vector["failed"] {
				AssertEqual(Template . Marker, SubStr(Body, 1, StrLen(Template . Marker)),
					Vector["id"] . ": the template, then the marker: " . Body)
				Suffix := Vector["expect_suffix"]
				AssertEqual(Suffix, SubStr(Body, -StrLen(Suffix)), Vector["id"] . ": the lost-argument count: " . Body)
			} else {
				AssertEqual(Vector["expect_body"], Body, Vector["id"] . ": the substituted body")
			}
		}
		return _Run
	}
	for _, Vector in Data["format_failure"]["cases"]
		Test("logger parity format_failure: " . Vector["id"], _LogParity_MakeFormatCase(Vector))

	_LogParity_MakeDatedCase(Vector) {
		_Run() {
			Expired := _LoggerDatedLogExpired(_LogParity_Stamp(Vector["file_date"]),
				_LogParity_Stamp(Vector["now"]), Vector["retention_days"])
			AssertEqual(Vector["purged"] ? true : false, Expired ? true : false, Vector["id"])
		}
		return _Run
	}
	for _, Vector in Data["dated_retention"]["cases"]
		Test("logger parity dated_retention: " . Vector["id"], _LogParity_MakeDatedCase(Vector))

	_LogParity_MakeTopicalCase(Vector) {
		_Run() {
			Stale := _LoggerTopicalLogStale(_LogParity_Stamp(Vector["modified"]), _LogParity_Stamp(Vector["now"]))
			AssertEqual(Vector["removed"] ? true : false, Stale ? true : false, Vector["id"])
		}
		return _Run
	}
	for _, Vector in Data["topical_retention"]["cases"]
		Test("logger parity topical_retention: " . Vector["id"], _LogParity_MakeTopicalCase(Vector))
}

_LogParity_RunAll()
