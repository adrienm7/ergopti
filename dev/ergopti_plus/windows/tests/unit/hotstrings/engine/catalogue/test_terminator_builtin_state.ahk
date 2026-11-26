; tests/unit/hotstrings/engine/catalogue/test_terminator_builtin_state.ahk

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

_HTMK_Migration(Mode) {
	global ConfigurationFile, _HotstringsTerminatorRecords
	Snow := Chr(0x2603), Preferred := "custom_2603"
	Before := FSReadUtf8Exact(ConfigurationFile)
	Word := HSE_TerminatorDefaultWordDelimiters() . Snow
	Consumed := HSE_TerminatorDefaultConsumedDelimiters() . Snow
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed),
		"the actual configuration writer must acknowledge the legacy migration")
	AssertTrue(InStr(HotstringsGetWordDelimiters(), Snow, true) > 0,
		"a successfully migrated legacy delimiter must reach the actual engine string")
	AssertTrue(InStr(HotstringsGetConsumedDelimiters(), Snow, true) > 0,
		"the migrated consumed choice must reach the actual engine string")
	Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
	Resolved := HotstringsTerminatorRecordsResolve(Document)
	AssertEqual(0, Resolved.Rejected.Length, "key allocation cannot create a rejected duplicate record")
	Found := 0
	for Entry in Resolved.Records
		if Entry.Char == Snow {
			Found += 1
			AssertTrue(Entry.Enabled)
			AssertTrue(Entry.Consume)
			if Mode == "record" || Mode == "state"
				AssertTrue(Entry.Key != Preferred, "a new logical delimiter cannot borrow an existing record or future state key")
		}
	AssertEqual(1, Found)
	if Mode == "record" {
		AssertTrue(InStr(HotstringsGetWordDelimiters(), "¤", true) > 0,
			"the existing independent currency delimiter must remain admitted")
		AssertEqual("¤", Document["hotstrings"]["terminators"][1]["char"])
		AssertEqual(Preferred, Document["hotstrings"]["terminators"][1]["key"])
	} else if Mode == "state"
		AssertEqual(false, Document["hotstrings"]["terminator_states"][Preferred].Value,
			"the unrelated future false leaf must stay unchanged")
	if Mode == "existing-character-control"
		AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile), "an already owned delimiter needs no migration rewrite")
	After := FSReadUtf8Exact(ConfigurationFile)
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed))
	AssertEqual(After, FSReadUtf8Exact(ConfigurationFile), "the actual successful move must remain idempotent")
	AssertEqual(After, _HotstringsTerminatorRecords.Source)
}
Test("terminator-move key allocation: existing record cannot hide the legacy character",
	_HTBS_Run.Bind("key-move-record", '[[hotstrings.terminators]]`nkey="custom_2603"`nchar="¤"`nlabel="Existing currency"`nconsume=false`n', _HTMK_Migration.Bind("record")))
Test("terminator-move key allocation: future false state cannot disable the legacy character",
	_HTBS_Run.Bind("key-move-state", '[hotstrings.terminator_states]`ncustom_2603=false`n', _HTMK_Migration.Bind("state")))
Test("terminator-move key allocation: ordinary fresh allocation remains admitted",
	_HTBS_Run.Bind("key-move-fresh", "", _HTMK_Migration.Bind("fresh-control")))
Test("terminator-move key allocation: an existing character is not duplicated",
	_HTBS_Run.Bind("key-move-existing-char", '[[hotstrings.terminators]]`nkey="already_snow"`nchar="☃"`nlabel="Owned snow"`nconsume=true`n', _HTMK_Migration.Bind("existing-character-control")))

_HTEI_MagicMove(Mode) {
	global HSE_Terminators, _HotstringsTerminatorRecords
	Saved := _HSDT_SaveState(), SavedTerms := HSE_Terminators
	try {
		HSE_Terminators := Terminators()
		_HotstringsTerminatorRecords := 0
		; The real detached factory owns this setup; migration is the subject.
		HSE_Terminators.updateMagicKey("A")
		_HSDT_Seed("magic-exact-move-" . Mode)
		Legacy := Mode == "lower" ? "a" : "A"
		AssertEqual(1, HotstringsTerminatorMigrateStrings(Legacy, Legacy))
		AssertEqual(Legacy, HotstringsGetWordDelimiters(), "a configured magic A cannot claim the case-distinct legacy scalar a")
		AssertEqual(Legacy, HotstringsGetConsumedDelimiters())
	} finally {
		HSE_Terminators := SavedTerms
		_HSDT_Restore(Saved)
	}
}
for _HTEI_MagicMode in ["upper", "lower"]
	Test("terminator-move exact magic membership: " . _HTEI_MagicMode, _HTEI_MagicMove.Bind(_HTEI_MagicMode))

_HTCC_Migration(Mode) {
	global ConfigurationFile
	Word := HSE_TerminatorDefaultWordDelimiters() . "Aa"
	BaseConsumed := HSE_TerminatorDefaultConsumedDelimiters()
	Selected := Mode == "upper" ? "A" : (Mode == "lower" ? "a" : (Mode == "both-control" ? "Aa" : ""))
	Consumed := BaseConsumed . Selected
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed), "the real migration writer must acknowledge the intended scalar choices")
	AssertEqual(Word, HotstringsGetWordDelimiters(), "both case-distinct valid scalars must remain active")
	AssertEqual(Consumed, HotstringsGetConsumedDelimiters(),
		"migration must not consume the case-distinct scalar absent from the actual consumed string")
	Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
	Rows := Document["hotstrings"]["terminators"]
	AssertEqual(2, Rows.Length)
	AssertEqual("A", Rows[1]["char"])
	AssertEqual("a", Rows[2]["char"])
	AssertEqual(InStr(Selected, "A", true) > 0, Rows[1]["consume"].Value)
	AssertEqual(InStr(Selected, "a", true) > 0, Rows[2]["consume"].Value)
	Before := FSReadUtf8Exact(ConfigurationFile)
	AssertEqual(1, HotstringsTerminatorMigrateStrings(Word, Consumed))
	AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile), "repeating the successful move must preserve exact source")
}
for _HTCC_Mode in ["upper", "lower", "both-control", "neither-control"]
	Test("terminator-move exact consumption: " . _HTCC_Mode,
		_HTBS_Run.Bind("consumption-case-" . _HTCC_Mode, "", _HTCC_Migration.Bind(_HTCC_Mode)))

_HOSG_CanonicalLegacyMigration(Mode) {
	global _HotstringsOverrides, _HotstringsOverridesPath, _HotstringsLegacyDelimiters
	global _HotstringsCommonOverrideAdmitted, HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
		legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted()}
	Root := A_Temp . "\ergopti_override_legacy_syntax_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		if Mode == "literal"
			Leaves := "word_delimiters = '.¤'`nconsumed_delimiters = '¤'`n"
		else if Mode == "multiline-literal"
			Leaves := "word_delimiters = '''.¤'''`nconsumed_delimiters = '''¤'''`n"
		else if Mode == "quoted-keys"
			Leaves := '"word_delimiters" = ".¤"`n"consumed_delimiters" = "¤"`n'
		else
			Leaves := 'word_delimiters = ".¤"`nconsumed_delimiters = "¤"`n'
		Source := "[__global__]`n" . Leaves . "[magickey]`npriority = 25`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		Typed := TOML_ParseDocument(FSReadStrict(Path))
		AssertEqual(".¤", Typed["__global__"]["word_delimiters"])
		AssertEqual("¤", Typed["__global__"]["consumed_delimiters"])
		HotstringsConfigInit(Path)
		AssertTrue(HotstringsDelimitersBoot(), "real native boot must durably transfer the legacy strings")
		AssertEqual(".¤", HSE_WORD_TERMINATORS, "the canonical source strings must reach the actual delimiter owner")
		AssertEqual("¤", HSE_CONSUMED_DELIMITERS)
		Disk := TOML_ParseDocument(FSReadStrict(Path))
		AssertFalse(Disk.Has("__global__"), "legacy source is retired only after its real destination commit")
		AssertEqual(25, Disk["magickey"]["priority"])
		AssertEqual("", _HotstringsLegacyDelimiters.Word)
		AssertEqual("", _HotstringsLegacyDelimiters.Consumed)
	} finally {
		_HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		_HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOSG_Mode in ["literal", "multiline-literal", "quoted-keys", "basic-control"]
	Test("HotstringsConfig canonical legacy migration: " . _HOSG_Mode,
		_HTBS_Run.Bind("canonical-legacy-" . _HOSG_Mode, "", _HOSG_CanonicalLegacyMigration.Bind(_HOSG_Mode)))

_HOSR_LegacyRetirementReceipt(Mode) {
	global _HotstringsOverrides, _HotstringsOverridesPath, _HotstringsLegacyDelimiters
	global _HotstringsCommonOverrideAdmitted
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
		legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted()}
	Root := A_Temp . "\ergopti_override_retirement_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		Empty := Mode == "empty-control"
		Source := "[__global__]`nword_delimiters = " . TOML_RenderString(Empty ? "" : ".")
			. "`nconsumed_delimiters = " . TOML_RenderString(Empty ? "" : ".") . "`n[magickey]`npriority = 25`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		HotstringsConfigInit(Path)
		Owner := _HotstringsOverrides
		if Mode == "receipt-source-changed" {
			Changed := StrReplace(Source, 'word_delimiters = "."', 'word_delimiters = ".¤"', true)
			Move(Word, Consumed) {
				Result := HotstringsTerminatorMigrateStrings(Word, Consumed)
				AssertEqual(1, Result, "the original source must genuinely commit at its destination")
				AssertTrue(FSWriteDurable(Path, Changed), "the real source changes after its old values were transferred")
				return Result
			}
			AssertFalse(HotstringsDelimitersBoot(Move), "a receipt for the earlier values cannot retire the new source")
			AssertEqual(Changed, FSReadStrict(Path))
			AssertEqual(".", _HotstringsLegacyDelimiters.Word, "the unretired request remains retryable")
		} else if Empty {
			AssertTrue(HotstringsSetOverride("magickey", "", "color", "#123456"), "empty legacy strings carry no pending character intent")
			Disk := TOML_ParseDocument(FSReadStrict(Path))
			AssertEqual("#123456", Disk["magickey"]["color"])
		} else {
			Result := Mode == "ordinary-clear"
				? HotstringsClearOverride("magickey", "", "priority")
				: HotstringsSetOverride("magickey", "", "color", "#123456")
			AssertFalse(Result, "ordinary writes cannot retire legacy delimiters before a destination acknowledgment")
			AssertEqual(Source, FSReadStrict(Path))
			AssertTrue(_HotstringsOverrides == Owner)
		}
	} finally {
		_HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		_HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOSR_Mode in ["ordinary-set", "ordinary-clear", "receipt-source-changed", "empty-control"]
	Test("HotstringsConfig delimiter retirement receipt: " . _HOSR_Mode,
		_HTBS_Run.Bind("retirement-receipt-" . _HOSR_Mode, "", _HOSR_LegacyRetirementReceipt.Bind(_HOSR_Mode)))
