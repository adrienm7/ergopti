; tests/unit/modules/hotstrings/catalogue/test_hotstrings_config_delimiters.ahk

; ==============================================================================
; MODULE: Hotstrings Config Word Delimiters
; DESCRIPTION:
; SetWordDelimiters propagates live to the engine and round-trips, and
; _SaveOverrides preserves the [__global__] delimiters (F06).
; ==============================================================================

#Requires AutoHotkey v2.0





TestHotstringsConfig_SetWordDelimitersUpdatesEngineVarLive() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedCache  := _HotstringsWordDelimiters
	SavedEngine := HSE_WORD_TERMINATORS
	SavedConsumedCache := _HotstringsConsumedDelimiters
	SavedConsumedEngine := HSE_CONSUMED_DELIMITERS
	Path := A_Temp . "\ergopti_set_word_live_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HotstringsWordDelimiters := ""
		_HotstringsConsumedDelimiters := ""
		Committed := HotstringsSetWordDelimiters("AB")
		EngineAfter := HSE_WORD_TERMINATORS
		AssertTrue(Committed,
			"the fixture must complete the durable transaction before asserting its live projection")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		_HotstringsWordDelimiters := SavedCache
		HSE_WORD_TERMINATORS := SavedEngine
		_HotstringsConsumedDelimiters := SavedConsumedCache
		HSE_CONSUMED_DELIMITERS := SavedConsumedEngine
	}
	AssertEqual("AB", EngineAfter,
		"HotstringsSetWordDelimiters must propagate to HSE_WORD_TERMINATORS immediately (no Reload needed)")
}
Test("HotstringsConfig: SetWordDelimiters propagates to HSE_WORD_TERMINATORS live",
	TestHotstringsConfig_SetWordDelimitersUpdatesEngineVarLive)

TestHotstringsConfig_SetWordDelimitersGetRoundTrip() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedCache  := _HotstringsWordDelimiters
	SavedEngine := HSE_WORD_TERMINATORS
	SavedConsumedCache := _HotstringsConsumedDelimiters
	SavedConsumedEngine := HSE_CONSUMED_DELIMITERS
	Path := A_Temp . "\ergopti_set_word_roundtrip_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HotstringsWordDelimiters := ""
		_HotstringsConsumedDelimiters := ""
		Committed := HotstringsSetWordDelimiters("XY")
		Got := HotstringsGetWordDelimiters()
		AssertTrue(Committed,
			"the fixture must complete the durable transaction before asserting its getter")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		_HotstringsWordDelimiters := SavedCache
		HSE_WORD_TERMINATORS := SavedEngine
		_HotstringsConsumedDelimiters := SavedConsumedCache
		HSE_CONSUMED_DELIMITERS := SavedConsumedEngine
	}
	AssertEqual("XY", Got,
		"HotstringsGetWordDelimiters must return the value just set by HotstringsSetWordDelimiters")
}
Test("HotstringsConfig: SetWordDelimiters / GetWordDelimiters round-trip",
	TestHotstringsConfig_SetWordDelimitersGetRoundTrip)

TestHotstringsConfig_SaveOverridesPreservesGlobalDelimiters() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters

	SavedPath     := _HotstringsOverridesPath
	SavedOv       := _HotstringsOverrides
	SavedWordDel  := _HotstringsWordDelimiters
	SavedConsumed := _HotstringsConsumedDelimiters

	Path := A_Temp . "\hotstrings_config_f06_global.toml"
	try FileDelete(Path)

	; Wire up a real file so _SaveOverrides actually writes to disk
	_HotstringsOverrides     := Map()
	_HotstringsOverridesPath := Path

	; 1. Seed custom delimiter candidates in the live fixture.
	_HotstringsWordDelimiters   := "AB"
	_HotstringsConsumedDelimiters := "A"

	; 2. Trigger _SaveOverrides via a category edit (full-file rebuild)
	HotstringsSetOverride("rolls", "", "delay", 1.2)

	; 3. Read the delimiter back from disk directly — _SaveOverrides must have
	;    re-emitted [__global__] during the rebuild, not clobbered it
	WordDelOnDisk     := _ParseGlobalKey(Path, "word_delimiters")
	ConsumedDelOnDisk := _ParseGlobalKey(Path, "consumed_delimiters")

	try FileDelete(Path)
	_HotstringsOverridesPath      := SavedPath
	_HotstringsOverrides          := SavedOv
	_HotstringsWordDelimiters     := SavedWordDel
	_HotstringsConsumedDelimiters := SavedConsumed
	HotstringsResolveBumpGen()

	; 4. Assert the custom delimiters survived the rebuild
	AssertEqual("AB", WordDelOnDisk,
		"[__global__] word_delimiters must survive a subsequent _SaveOverrides")
	AssertEqual("A", ConsumedDelOnDisk,
		"[__global__] consumed_delimiters must survive a subsequent _SaveOverrides")
}
Test("hotstrings_config: _SaveOverrides preserves [__global__] delimiters", TestHotstringsConfig_SaveOverridesPreservesGlobalDelimiters)

; F37 (audit 2026-07-20): a delimiter containing a quote or backslash once
; produced malformed TOML and silently reverted at the next read. Both global
; keys now share one whole-file serializer, including detached candidates.
TestHotstringsConfig_SaveOverridesEscapesGlobalDelimiters() {
	Path := A_Temp . "\ergopti_delimiter_roundtrip_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "the roundtrip fixture must own a fresh path")
	Word := 'W"\literal`n[injected_word]`ncolor = "bad'
	Consumed := 'C"\literal`n[injected_consumed]`ncolor = "bad'
	try {
		AssertTrue(_SaveOverrides(Map(), 0, 0, Word, Consumed, Path),
			"detached delimiter candidates must reach the real file writer")
		AssertEqual(Word, _ParseGlobalKey(Path, "word_delimiters"),
			"word delimiters must survive actual serialization and parsing")
		AssertEqual(Consumed, _ParseGlobalKey(Path, "consumed_delimiters"),
			"consumed delimiters must survive actual serialization and parsing")
		Parsed := _ParseOverrides(Path)
		AssertFalse(Parsed.Has("injected_word"), "word delimiters cannot inject a section")
		AssertFalse(Parsed.Has("injected_consumed"), "consumed delimiters cannot inject a section")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("hotstrings_config: _SaveOverrides escapes detached [__global__] delimiter candidates",
	TestHotstringsConfig_SaveOverridesEscapesGlobalDelimiters)

TestHotstringsConfig_ParserRejectsNumericOverflow() {
	Path := A_Temp . "\hotstrings_override_numeric_overflow.toml"
	FloatOverflow := "1"
	Loop 309
		FloatOverflow .= "0"
	FloatOverflow .= ".0"
	try {
		try FileDelete(Path)
		FileAppend("[rolls]`ndelay = " . FloatOverflow . "`n"
			. "priority = 18446744073709552116`n`n"
			. "[rolls.too_long]`ndelay = 4294968`n", Path, "UTF-8")
		Parsed := _ParseOverrides(Path)
		AssertTrue(Parsed.Has("rolls"))
		AssertEqual("", Parsed["rolls"].Delay,
			"non-finite override delay must remain unset")
		AssertEqual("", Parsed["rolls"].Priority,
			"overflowing override priority must remain unset")
		AssertEqual("", Parsed["rolls"].Sections["too_long"].Delay,
			"a finite override beyond TickElapsed must remain unset")
	} finally {
		try FileDelete(Path)
	}
}
Test("HotstringsConfig: override parser rejects numeric overflow",
	TestHotstringsConfig_ParserRejectsNumericOverflow)

TestHotstringsConfig_ParserRejectsOutOfDomainPriority() {
	Path := A_Temp . "\hotstrings_override_priority_domain_parse.toml"
	try {
		try FileDelete(Path)
		FileAppend("[rolls]`npriority = 101`n`n"
			. "[rolls.too_high]`npriority = 999`n", Path, "UTF-8")
		Parsed := _ParseOverrides(Path)
		AssertEqual("", Parsed["rolls"].Priority,
			"file-level override priority above 100 must remain unset")
		AssertEqual("", Parsed["rolls"].Sections["too_high"].Priority,
			"section override priority above 100 must remain unset")
	} finally {
		try FileDelete(Path)
	}
}
Test("HotstringsConfig: priority domain rejects out-of-range override files",
	TestHotstringsConfig_ParserRejectsOutOfDomainPriority)

TestHotstringsConfig_PublicWriterRejectsUnrepresentableDelay() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_override_tick_domain.toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		AssertFalse(HotstringsSetOverride("rolls", "", "delay", 4294968),
			"public override writer must reject an unrepresentable duration")
		AssertFalse(FileExist(Path),
			"a rejected duration must not publish an override file")
		AssertFalse(_HotstringsOverrides.Has("rolls"),
			"a rejected duration must not mutate live override state")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("HotstringsConfig: public writer rejects delay beyond TickElapsed",
	TestHotstringsConfig_PublicWriterRejectsUnrepresentableDelay)

TestHotstringsConfig_PublicWriterRejectsInvalidPriority() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_override_priority_domain.toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		for Invalid in [-1, 101, 1.5, "50", 1.0e300] {
			AssertFalse(HotstringsSetOverride("rolls", "", "priority", Invalid),
				"public override writer must reject priorities outside the integer 0..100 domain")
			AssertFalse(FileExist(Path),
				"a rejected priority must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"a rejected priority must not mutate live override state")
		}
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("HotstringsConfig: public writer rejects invalid priority values",
	TestHotstringsConfig_PublicWriterRejectsInvalidPriority)

TestHotstringsConfig_PublicWriterRejectsInvalidTooltipBoolean() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_override_tooltip_boolean.toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		for Invalid in ["false", "true", 2, -1, 0.5] {
			AssertFalse(HotstringsSetOverride("rolls", "", "show_tooltip", Invalid),
				"public override writer must reject non-Boolean tooltip values")
			AssertFalse(FileExist(Path),
				"a rejected tooltip value must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"a rejected tooltip value must not mutate live override state")
		}
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("HotstringsConfig: tooltip Boolean rejects invalid writer values",
	TestHotstringsConfig_PublicWriterRejectsInvalidTooltipBoolean)

TestHotstringsConfig_ColorWriterUsesTomlStringCodec() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_override_color_codec.toml"
	InjectedColor := '#112233"`n[injected]`ncolor = "#445566'
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		AssertFalse(HotstringsSetOverride("rolls", "", "color", 42),
			"the public color writer must reject non-string values")
		AssertFalse(FileExist(Path),
			"a rejected color value must not publish an override file")
		AssertTrue(HotstringsSetOverride("rolls", "", "color", InjectedColor),
			"a string color must remain persistable through the shared TOML codec")
		Reparsed := _ParseOverrides(Path)
		AssertEqual(InjectedColor, Reparsed["rolls"].Color,
			"quotes and line breaks in a color string must round-trip as data")
		AssertFalse(Reparsed.Has("injected"),
			"a color string must not inject a sibling TOML category")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("HotstringsConfig: color writer uses the TOML string codec",
	TestHotstringsConfig_ColorWriterUsesTomlStringCodec)

TestHotstringsConfig_OverrideIdentifiersCannotInjectToml() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_override_identifier_guard.toml"
	InjectedCategory := "evil]`n[injected"
	InjectedSection := "ct]`n[injected"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()

		AssertFalse(HotstringsSetOverride(InjectedCategory, "", "color", "#112233"),
			"a category identifier must not be able to inject a TOML header")
		AssertFalse(FileExist(Path),
			"an invalid category must fail before durable publication")
		AssertFalse(HotstringsSetOverride("rolls", InjectedSection,
			"color", "#112233"),
			"a section identifier must not be able to inject a TOML header")
		AssertFalse(FileExist(Path),
			"an invalid section must fail before durable publication")
		AssertFalse(HotstringsClearOverride(InjectedCategory, ""),
			"the clear API must reject the same invalid identifier domain")

		Candidate := Map(InjectedCategory, {
			Delay: "", Color: "#112233", ShowTooltip: "", Priority: "",
			Sections: Map(),
		})
		AssertFalse(_SaveOverrides(Candidate),
			"the complete serializer must reject invalid identifiers from internal callers")
		AssertFalse(FileExist(Path),
			"serializer validation must run before its stage is published")

		AssertTrue(HotstringsSetOverride("ext.Ergopti-Demo", "demo-symbols",
			"color", "#445566"),
			"valid extension and hyphenated section identifiers must remain writable")
		Reparsed := _ParseOverrides(Path)
		AssertEqual("#445566",
			Reparsed["ext.ergopti-demo"].Sections["demo-symbols"].Color,
			"the accepted identifier grammar must round-trip through the parser")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("HotstringsConfig: override identifiers cannot inject TOML",
	TestHotstringsConfig_OverrideIdentifiersCannotInjectToml)


; Legal TOML comments must not change the current override owner or its values.
_HCOL_Read(Content) {
	Root := A_Temp . "\hotstrings-lexical-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	AssertFalse(FileExist(Root), "the lexical fixture must acquire an absent private root")
	Owned := false
	try {
		DirCreate(Root)
		Owned := true
		Path := Root . "\overrides.toml"
		Stream := FileOpen(Path, "w", "UTF-8")
		Assert(IsObject(Stream), "the owned TOML fixture must open for writing")
		try Stream.Write(Content)
		finally Stream.Close()
		return {
			Overrides: _ParseOverrides(Path),
			Word: _ParseGlobalKey(Path, "word_delimiters"),
			Consumed: _ParseGlobalKey(Path, "consumed_delimiters"),
		}
	} finally {
		if Owned
			DirDelete(Root, true)
	}
}

_HCOL_CategoryHeader() {
	Read := _HCOL_Read("[rolls]`ndelay = 0.3`n`t[magickey] # own category`t`ndelay = 0.9`n")
	AssertEqual(0.3, Read.Overrides["rolls"].Delay, "a commented category must not overwrite the previous category")
	AssertTrue(Read.Overrides.Has("magickey"), "the commented category must have its own identity")
	AssertEqual(0.9, Read.Overrides["magickey"].Delay, "the value belongs to the new category")
}
Test("HotstringsConfig: commented category keeps owner identity (hotstrings-override-lexical)", _HCOL_CategoryHeader)

_HCOL_SectionHeader() {
	Read := _HCOL_Read("[rolls.first]`ndelay = 0.2`n[rolls.second] # own section`ndelay = 0.8`n")
	AssertEqual(0.2, Read.Overrides["rolls"].Sections["first"].Delay, "a commented section must not overwrite the previous section")
	AssertTrue(Read.Overrides["rolls"].Sections.Has("second"), "the new section must exist")
	AssertEqual(0.8, Read.Overrides["rolls"].Sections["second"].Delay, "the value belongs to the new section")
}
Test("HotstringsConfig: commented section keeps owner identity (hotstrings-override-lexical)", _HCOL_SectionHeader)

_HCOL_ExtensionHeader() {
	Read := _HCOL_Read("[rolls]`ndelay = 0.3`n[ext.Demo-Pack] # own extension`ndelay = 0.7`n")
	AssertEqual(0.3, Read.Overrides["rolls"].Delay, "a commented extension must not overwrite the previous category")
	AssertTrue(Read.Overrides.Has("ext.demo-pack"), "the extension retains canonical case folding")
	AssertEqual(0.7, Read.Overrides["ext.demo-pack"].Delay, "the value belongs to the extension")
}
Test("HotstringsConfig: commented extension keeps owner identity (hotstrings-override-lexical)", _HCOL_ExtensionHeader)

_HCOL_ExtensionSectionHeader() {
	Read := _HCOL_Read("[ext.demo]`ndelay = 0.4`n[ext.demo.symbols] # own section`ndelay = 0.6`n")
	AssertEqual(0.4, Read.Overrides["ext.demo"].Delay, "a commented extension section must not overwrite its parent")
	AssertTrue(Read.Overrides["ext.demo"].Sections.Has("symbols"), "the extension section must exist")
	AssertEqual(0.6, Read.Overrides["ext.demo"].Sections["symbols"].Delay, "the section receives its own value")
}
Test("HotstringsConfig: commented extension section keeps owner identity (hotstrings-override-lexical)", _HCOL_ExtensionSectionHeader)

_HCOL_Fields() {
	Content := "[rolls]`ndelay = 0.9 # timing`n"
		. 'color = "#112233" # literal color hash' . "`n"
		. "show_tooltip = false # tooltip`npriority = 7 # priority`n"
	Read := _HCOL_Read(Content)
	Entry := Read.Overrides["rolls"]
	AssertEqual(0.9, Entry.Delay, "a trailing comment must preserve the numeric delay")
	AssertEqual("#112233", Entry.Color, "the quoted color hash is data")
	AssertEqual(false, Entry.ShowTooltip, "a trailing comment must preserve the boolean override")
	AssertEqual(7, Entry.Priority, "a trailing comment must preserve the integer priority")
}
Test("HotstringsConfig: comments preserve all override field types (hotstrings-override-lexical)", _HCOL_Fields)

_HCOL_GlobalHeader() {
	Content := "[__global__] # delimiter owner`n"
		. 'word_delimiters = ".?!"' . "`n"
		. 'consumed_delimiters = ";"' . "`n[rolls]`ndelay = 0.2`n"
	Read := _HCOL_Read(Content)
	AssertEqual(".?!", Read.Word, "a commented global header must expose its delimiter value")
	AssertEqual(Chr(59), Read.Consumed, "the consumed delimiters share the global header owner")
	AssertEqual(0.2, Read.Overrides["rolls"].Delay, "ordinary categories remain readable after global values")
}
Test("HotstringsConfig: commented global header owns both delimiter keys (hotstrings-override-lexical)", _HCOL_GlobalHeader)

_HCOL_GlobalFields() {
	Content := "[__global__]`n"
		. 'word_delimiters = "." # word' . "`n"
		. 'consumed_delimiters = "!" # consumed' . "`n"
	Read := _HCOL_Read(Content)
	AssertEqual(".", Read.Word, "the global quoted word value accepts a trailing comment")
	AssertEqual("!", Read.Consumed, "the consumed value uses the same normalization")
}
Test("HotstringsConfig: comments preserve global delimiter fields (hotstrings-override-lexical)", _HCOL_GlobalFields)

_HCOL_QuotedData() {
	Content := "[__global__]`n" . 'word_delimiters = "#\"é\t"' . "`n"
		. '[rolls]' . "`n" . 'color = "#\"é\t"' . "`n"
	Read := _HCOL_Read(Content)
	Expected := "#" . Chr(34) . "é" . Chr(9)
	AssertEqual(Expected, Read.Word, "an internal hash escaped quote tab and Unicode remain data")
	AssertEqual(Expected, Read.Overrides["rolls"].Color, "ordinary basic-string decoding remains unchanged")
}
Test("HotstringsConfig: quoted hashes and escapes remain data (hotstrings-override-lexical)", _HCOL_QuotedData)

_HCOL_QuotedDataComment() {
	Content := "[__global__]`n" . 'word_delimiters = "#\"é\t" # comment "quote"' . "`n"
		. '[rolls]' . "`n" . 'color = "#\"é\t" # comment "quote"' . "`n"
	Read := _HCOL_Read(Content)
	Expected := "#" . Chr(34) . "é" . Chr(9)
	AssertEqual(Expected, Read.Word, "comment quotes must not become delimiter data")
	AssertEqual(Expected, Read.Overrides["rolls"].Color, "comment stripping must preserve the escaped quote boundary")
}
Test("HotstringsConfig: quoted escapes survive trailing comment quotes (hotstrings-override-lexical)", _HCOL_QuotedDataComment)

_HCOL_OrdinaryDefaults() {
	Content := "[__global__]`n" . 'word_delimiters = "."' . "`n"
		. "[rolls]`ndelay = 0.3`nshow_tooltip = true`npriority = 4`n"
		. "[rolls.symbols]`ndelay = 0.2`n[ext.demo]`ndelay = 0.5`n"
	Read := _HCOL_Read(Content)
	AssertEqual(".", Read.Word, "an ordinary global key retains its value")
	AssertEqual("", Read.Consumed, "an absent delimiter key keeps the existing absent sentinel")
	AssertEqual(0.3, Read.Overrides["rolls"].Delay, "an ordinary category remains unchanged")
	AssertEqual("", Read.Overrides["rolls"].Color, "an absent override retains its default sentinel")
	AssertEqual(true, Read.Overrides["rolls"].ShowTooltip, "ordinary true remains true")
	AssertEqual(4, Read.Overrides["rolls"].Priority, "ordinary integer priority remains intact")
	AssertEqual(0.2, Read.Overrides["rolls"].Sections["symbols"].Delay, "ordinary sections remain separate")
	AssertEqual(0.5, Read.Overrides["ext.demo"].Delay, "ordinary extensions remain separate")
	AssertEqual(0, _ParseOverrides("").Count, "an absent override path retains its empty map")
	AssertEqual("", _ParseGlobalKey("", "word_delimiters"), "an absent global path retains its empty sentinel")
}
Test("HotstringsConfig: ordinary values and absent defaults remain intact (hotstrings-override-lexical)", _HCOL_OrdinaryDefaults)

_HCOL_FullLineComments() {
	Content := "[rolls]`ndelay = 0.3`n# [magickey]`n# delay = 0.9`n"
		. "[__global__]`n# word_delimiters = ignored`n" . 'word_delimiters = "."' . "`n"
	Read := _HCOL_Read(Content)
	AssertEqual(0.3, Read.Overrides["rolls"].Delay, "full-line comment assignments do not change values")
	AssertFalse(Read.Overrides.Has("magickey"), "a full-line comment header never creates a category")
	AssertEqual(".", Read.Word, "the actual delimiter value remains readable after comments")
}
Test("HotstringsConfig: full-line comments never create owners (hotstrings-override-lexical)", _HCOL_FullLineComments)


; Native ownership checks keep every destructive operation inside a directory
; this callback acquired. The former shared TEMP path must fail before deletion.
_HCfgTestFixtureIsolation() {
	global _HCfgTestFixtureRoot
	Path := _HCfgTestOverridePath()
	SplitPath(Path, , &Root)
	Assert(Root != A_Temp && InStr(Root, A_Temp . "\") == 1,
		"the override fixture must own a private directory beneath TEMP")
	AssertEqual(Path, _HCfgTestOverridePath(), "the acquired fixture path must remain stable")
	Sibling := Root . "_sibling", SiblingOwned := false, ForeignOwned := false
	try {
		FSCreateDirectoryExclusiveStrict(Sibling)
		SiblingOwned := true
		FileAppend("sibling owner", Sibling . "\sentinel.txt", "UTF-8-RAW")
		FileAppend("owned override", Path, "UTF-8-RAW")
		_HCfgTestCleanup()
		AssertEqual("", _HCfgTestFixtureRoot, "successful cleanup releases ownership")
		AssertFalse(DirExist(Root), "cleanup must retire the acquired directory")
		_HCfgTestCleanup()
		AssertFalse(DirExist(Root), "empty cleanup must not allocate a fixture")
		AssertEqual("sibling owner", FileRead(Sibling . "\sentinel.txt", "UTF-8"))

		FSCreateDirectoryExclusiveStrict(Root)
		ForeignOwned := true
		FileAppend("foreign owner", Root . "\sentinel.txt", "UTF-8-RAW")
		Failure := 0
		try _HCfgTestOverridePath()
		catch OSError as Caught
			Failure := Caught
		Assert(Failure is OSError, "exclusive acquisition must refuse an occupied candidate")
		AssertEqual("", _HCfgTestFixtureRoot, "failed acquisition must not publish ownership")
		_HCfgTestCleanup()
		AssertEqual("foreign owner", FileRead(Root . "\sentinel.txt", "UTF-8"),
			"cleanup must preserve a candidate whose acquisition was refused")
		AssertEqual("sibling owner", FileRead(Sibling . "\sentinel.txt", "UTF-8"))
	} finally {
		if ForeignOwned && DirExist(Root)
			DirDelete(Root, true)
		if SiblingOwned
			DirDelete(Sibling, true)
	}
}
Test("HotstringsConfig: fixture acquisition and cleanup preserve foreign owners (hotstrings-fixture-ownership)",
	_HCfgTestFixtureIsolation)

_HCfgTestFixtureCleanupRefusal() {
	global _HCfgTestFixtureRoot
	Path := _HCfgTestOverridePath()
	SplitPath(Path, , &Root)
	Assert(Root != A_Temp && InStr(Root, A_Temp . "\") == 1,
		"the cleanup refusal fixture must own a private directory beneath TEMP")
	Handle := -1
	try {
		Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0xC0000000,
			"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
		Assert(Handle != -1, "the fixture must acquire an actual exclusive writer")
		Failure := 0
		try _HCfgTestCleanup()
		catch Error as Caught
			Failure := Caught
		Assert(Failure is Error, "a real native deletion refusal must propagate")
		AssertEqual(Root, _HCfgTestFixtureRoot, "refused cleanup retains the exact owner")
		AssertTrue(DirExist(Root), "the locked fixture cannot be reported retired")
	} finally {
		if Handle != -1
			Assert(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "release the exact native writer")
		_HCfgTestCleanup()
	}
	AssertEqual("", _HCfgTestFixtureRoot, "successful cleanup retry releases ownership")
	AssertFalse(DirExist(Root), "successful cleanup retry retires the directory")
}
Test("HotstringsConfig: refused fixture cleanup retains ownership until retry (hotstrings-fixture-ownership)",
	_HCfgTestFixtureCleanupRefusal)

#Include test_hotstrings_global_key_utf8.ahk
