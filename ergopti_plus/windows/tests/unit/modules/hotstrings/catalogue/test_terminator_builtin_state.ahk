; tests/unit/modules/hotstrings/catalogue/test_terminator_builtin_state.ahk

; ==============================================================================
; MODULE: Built-in Delimiter State and the Move of the Old Strings
; DESCRIPTION:
; The word and consumed strings of earlier builds move to config.toml: a shipped
; delimiter whose state or consumption differed from the catalogue becomes a
; sparse leaf, every other character becomes a record, and the override file is
; rewritten without them. The move keeps every effective choice, never overrides
; a leaf the configuration already holds, and can run twice.
; ==============================================================================

#Requires AutoHotkey v2.0

_HTBS_Run(Name, Extra, Body) {
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed(Name, Extra)
		return Body.Call()
	} finally _HSDT_Restore(Saved)
}

_HTBS_Document() {
	global ConfigurationFile
	return TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
}

_HTBS_MigrationKeepsOldChoices() {
	global ConfigurationFile, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	; The old word string dropped the three sentence marks and added a currency sign
	; and an emoji; the old consumed string kept the magic key and the currency sign.
	Word := " `t`r`n★,;.¤" . Chr(0x1F600), Consumed := "★¤"
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed),
		"the real configuration writer must acknowledge the move")
	Hotstrings := _HTBS_Document()["hotstrings"]
	States := Hotstrings["terminator_states"]
	for Key in ["exclam", "question", "colon"]
		AssertEqual(false, States[Key].Value, Key . " was off in the old string")
	AssertEqual(3, States.Count, "only the delimiters that differ from the catalogue are leaves")
	AssertFalse(Hotstrings.Has("terminator_consume"), "the old consumption equals the catalogue for every shipped delimiter")
	Records := Hotstrings["terminators"]
	AssertEqual(2, Records.Length)
	AssertEqual("¤", Records[1]["char"])
	AssertEqual(true, Records[1]["consume"].Value, "the old consumed string held the currency sign")
	AssertEqual(Chr(0x1F600), Records[2]["char"])
	AssertEqual(false, Records[2]["consume"].Value)
	AssertEqual(Word, HSE_WORD_TERMINATORS, "the engine strings are exactly the old ones")
	AssertEqual(Consumed, HSE_CONSUMED_DELIMITERS)
	AssertEqual(FSReadUtf8Exact(ConfigurationFile), _HotstringsTerminatorRecords.Source,
		"the owner follows the bytes just written")

	; A second run finds nothing to add.
	Before := FSReadUtf8Exact(ConfigurationFile)
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed))
	AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile), "the move is idempotent")
}
Test("terminator-move: the old strings become sparse leaves and records, keeping every choice",
	_HTBS_Run.Bind("move", "", _HTBS_MigrationKeepsOldChoices))

_HTBS_MigrationNeverOverridesAStoredLeaf() {
	global _HSDT_WriteCalls, _HSDT_WrittenUpdates
	; The old string still held the period; the configuration already turned it off.
	AssertEqual(1, HotstringsTerminatorMigrateStrings(HSE_TerminatorDefaultWordDelimiters(),
		HSE_TerminatorDefaultConsumedDelimiters(), _HSDT_AcceptWriter))
	AssertEqual(0, _HSDT_WriteCalls, "the catalogue defaults and a stored leaf leave nothing to write")
	AssertEqual(false, _HotstringsTerminatorRecords.Builtin["period"].Enabled, "the stored leaf wins")
}
Test("terminator-move: a leaf the configuration already holds wins over the old string",
	_HTBS_Run.Bind("move-wins", '[hotstrings.terminator_states]`nperiod = false`n', _HTBS_MigrationNeverOverridesAStoredLeaf))

_HTBS_MigrationKeepsUnconsumedStar() {
	global _HSDT_WrittenUpdates
	; The old consumed string no longer held the magic key: it was not consumed.
	AssertEqual(1, HotstringsTerminatorMigrateStrings("", "x", _HSDT_AcceptWriter))
	AssertEqual(1, _HSDT_WrittenUpdates[1].Length, "only the magic key differs from the catalogue")
	Update := _HSDT_WrittenUpdates[1][1]
	AssertEqual("hotstrings.terminator_consume", Update.Section)
	AssertEqual("star", Update.Key)
	AssertEqual(false, Update.Value.Value)
}
Test("terminator-move: an old consumed string without the magic key keeps it unconsumed",
	_HTBS_Run.Bind("move-star", "", _HTBS_MigrationKeepsUnconsumedStar))

_HTBS_BootStepRetiresTheStrings() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsLegacyDelimiters
	global _HotstringsCommonOverrideAdmitted
	SavedOverrides := [_HotstringsOverridesPath, _HotstringsOverrides, _HotstringsLegacyDelimiters,
		HotstringsCommonOverrideAdmitted()]
	Path := A_Temp . "\ergopti_hs_delimiter_boot_" . A_ScriptHwnd . ".toml"
	try {
		if FileExist(Path)
			FileDelete(Path)
		AssertTrue(FSWriteCreateDurable(Path, '[__global__]`nword_delimiters = "!."`nconsumed_delimiters = "."`n'
			. '[rolls]`ndelay_offset = 0.25`n'))
		HotstringsConfigInit(Path)
		AssertEqual("!.", _HotstringsLegacyDelimiters.Word)
		AssertFalse(_HotstringsOverrides.Has("__global__"),
			"the reserved delimiter table is no override category, or the rewrite would refuse it")
		Seen := []
		Refusing(Word, Consumed) {
			Seen.Push([Word, Consumed])
			return 0
		}
		AssertFalse(HotstringsDelimitersBoot(Refusing), "a refused move reports failure")
		AssertEqual("!.", _HotstringsLegacyDelimiters.Word, "and keeps the strings for the next start")
		AssertContains(FSReadUtf8Exact(Path), "word_delimiters", "the file is untouched until the move is durable")
		Accepting(Word, Consumed) {
			Seen.Push([Word, Consumed])
			return 1
		}
		AssertTrue(HotstringsDelimitersBoot(Accepting))
		AssertEqual(2, Seen.Length)
		AssertEqual("!.", Seen[2][1])
		AssertEqual(".", Seen[2][2])
		Content := FSReadUtf8Exact(Path)
		AssertFalse(InStr(Content, "word_delimiters") || InStr(Content, "consumed_delimiters"),
			"the override file no longer holds the strings")
		AssertContains(Content, "delay_offset = 0.25", "and keeps every other value")
		AssertEqual("", _HotstringsLegacyDelimiters.Word)
		AssertTrue(HotstringsDelimitersBoot(Refusing), "with nothing left, the step does not call the move again")
		AssertEqual(2, Seen.Length)
	} finally {
		_HotstringsOverridesPath := SavedOverrides[1], _HotstringsOverrides := SavedOverrides[2]
		_HotstringsLegacyDelimiters := SavedOverrides[3]
		_HotstringsCommonOverrideAdmitted := SavedOverrides[4]
		HotstringsResolveBumpGen()
		try FileDelete(Path)
	}
}
Test("terminator-move: the boot step retires the strings of the override file only after a durable move",
	_HTBS_BootStepRetiresTheStrings)

_HTBS_RecordsOwnTheirScalarOverTheLeaves() {
	; A record owns its scalar: a stored state for another key never reaches it.
	AssertEqual(" `t`r`n★,;.!?:¤", HotstringsGetWordDelimiters())
	AssertEqual("★¤", HotstringsGetConsumedDelimiters())
}
Test("terminator-leaves: records add their scalar after the shipped delimiters",
	_HTBS_Run.Bind("records-after", '[[hotstrings.terminators]]`nkey = "currency"`nchar = "¤"`nlabel = "C"`nconsume = true`n',
		_HTBS_RecordsOwnTheirScalarOverTheLeaves))
