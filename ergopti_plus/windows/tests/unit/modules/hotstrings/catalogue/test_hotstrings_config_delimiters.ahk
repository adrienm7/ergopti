; tests/unit/modules/hotstrings/catalogue/test_hotstrings_config_delimiters.ahk

; ==============================================================================
; MODULE: Hotstrings Config Word Delimiters
; DESCRIPTION:
; A built-in delimiter change is a config.toml leaf written through the live
; writer: it reaches the engine strings immediately and round-trips through the
; file. The override file holds no delimiter string any more: _SaveOverrides
; writes none, and what an earlier build left there is read once for the move.
; ==============================================================================

#Requires AutoHotkey v2.0





; Runs a body against a fresh current-schema configuration and a fresh delimiter
; owner, with the real configuration writer: nothing is injected. Each test owns a
; distinct path: the migration registry keeps one row per path for the whole run
; and refuses a second boot of a path it already booted.
_HCD_WithConfig(Name, Body) {
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed(Name)
		return Body.Call()
	} finally _HSDT_Restore(Saved)
}

TestHotstringsConfig_ToggleUpdatesEngineVarLive() {
	global ConfigurationFile, HSE_WORD_TERMINATORS
	Before := HSE_WORD_TERMINATORS
	AssertEqual(1, HotstringsTerminatorToggle("colon"),
		"the live configuration writer must complete the durable write")
	AssertEqual(StrReplace(Before, ":", ""), HSE_WORD_TERMINATORS,
		"a toggle must propagate to HSE_WORD_TERMINATORS immediately (no Reload needed)")
	Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
	AssertEqual(false, Document["hotstrings"]["terminator_states"]["colon"].Value,
		"the state is a leaf of config.toml")
	AssertEqual(FSReadUtf8Exact(ConfigurationFile), _HotstringsTerminatorRecords.Source,
		"the owner follows the exact bytes just written")
}
Test("HotstringsConfig: a delimiter toggle propagates to HSE_WORD_TERMINATORS live",
	_HCD_WithConfig.Bind("config-delimiters-live", TestHotstringsConfig_ToggleUpdatesEngineVarLive))

TestHotstringsConfig_ToggleGetRoundTrip() {
	global ConfigurationFile
	AssertEqual(1, HotstringsTerminatorToggle("slash"))
	AssertEqual(1, HotstringsTerminatorToggle("colon"))
	Got := HotstringsGetWordDelimiters()
	AssertTrue(InStr(Got, "/") > 0 and InStr(Got, ":") == 0)
	; A restart reads the same state back from the file.
	Reread := HotstringsTerminatorRecordsResolve(TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile)))
	AssertEqual(true, Reread.Builtin["slash"].Enabled)
	AssertEqual(false, Reread.Builtin["colon"].Enabled)
	AssertEqual(0, Reread.Rejected.Length)
	; Toggling back deletes the leaf instead of storing a default.
	AssertEqual(1, HotstringsTerminatorToggle("colon"))
	Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
	Table := Document["hotstrings"].Get("terminator_states", Map())
	AssertFalse(Table.Has("colon"), "a state back on its default leaves no key")
}
Test("HotstringsConfig: delimiter toggles round-trip through config.toml",
	_HCD_WithConfig.Bind("config-delimiters-round-trip", TestHotstringsConfig_ToggleGetRoundTrip))

TestHotstringsConfig_SaveOverridesWritesNoGlobalDelimiters() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	SavedPath := _HotstringsOverridesPath
	SavedOv := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_config_no_global.toml"
	try FileDelete(Path)
	_HotstringsOverrides := Map()
	_HotstringsOverridesPath := Path
	try {
		AssertTrue(HotstringsSetOverride("rolls", "", "delay", 1.2))
		Content := FSReadUtf8Exact(Path)
		AssertFalse(InStr(Content, "__global__"), "no delimiter table is written")
		AssertFalse(InStr(Content, "word_delimiters"))
		AssertContains(Content, "delay_offset = 0.45")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOv
		HotstringsResolveBumpGen()
	}
}
Test("hotstrings_config: _SaveOverrides writes no [__global__] delimiter table",
	TestHotstringsConfig_SaveOverridesWritesNoGlobalDelimiters)

; The strings of an earlier build are read exactly once, to move them. A quote or
; a backslash in them once produced malformed TOML; the reader must still decode
; every escape.
TestHotstringsConfig_LegacyGlobalDelimitersAreReadExactly() {
	Path := A_Temp . "\ergopti_delimiter_legacy_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "the fixture must own a fresh path")
	Word := 'W"\literal'
	Consumed := 'C"\literal'
	try {
		AssertTrue(FSWriteDurable(Path, "[__global__]`nword_delimiters = " . TOML_RenderString(Word)
			. "`nconsumed_delimiters = " . TOML_RenderString(Consumed) . '`n[rolls]`ncolor = "#112233"`n'))
		AssertEqual(Word, _ParseGlobalKey(Path, "word_delimiters"),
			"word delimiters must survive actual parsing")
		AssertEqual(Consumed, _ParseGlobalKey(Path, "consumed_delimiters"),
			"consumed delimiters must survive actual parsing")
		Parsed := _ParseOverrides(Path)
		AssertEqual("#112233", Parsed["rolls"].Color)
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("hotstrings_config: legacy [__global__] delimiter strings are read exactly",
	TestHotstringsConfig_LegacyGlobalDelimitersAreReadExactly)

TestHotstringsConfig_ParserRejectsNumericOverflow() {
	Path := A_Temp . "\hotstrings_override_numeric_overflow.toml"
	FloatOverflow := "1"
	Loop 309
		FloatOverflow .= "0"
	FloatOverflow .= ".0"
	try {
		try FileDelete(Path)
		FileAppend("[rolls]`ndelay_offset = " . FloatOverflow . "`n"
			. "priority = 18446744073709552116`n`n"
			. "[rolls.too_long]`ndelay_offset = 4294968`n"
			. "[rolls.too_negative]`ndelay_offset = -4294968`n", Path, "UTF-8")
		Parsed := _ParseOverrides(Path)
		AssertTrue(Parsed.Has("rolls"))
		AssertEqual("", Parsed["rolls"].PendingOffset,
			"non-finite override delay offset must remain unset")
		AssertEqual("", Parsed["rolls"].Priority,
			"overflowing override priority must remain unset")
		AssertEqual("", Parsed["rolls"].Sections["too_long"].PendingOffset,
			"a finite offset beyond TickElapsed must remain unset")
		AssertEqual("", Parsed["rolls"].Sections["too_negative"].PendingOffset,
			"a negative offset beyond TickElapsed must remain unset")
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
	Read := _HCOL_Read("[rolls]`ndelay_offset = 0.3`n`t[magickey] # own category`t`ndelay_offset = 0.9`n")
	AssertEqual(0.3, Read.Overrides["rolls"].PendingOffset, "a commented category must not overwrite the previous category")
	AssertTrue(Read.Overrides.Has("magickey"), "the commented category must have its own identity")
	AssertEqual(0.9, Read.Overrides["magickey"].PendingOffset, "the value belongs to the new category")
}
Test("HotstringsConfig: commented category keeps owner identity (hotstrings-override-lexical)", _HCOL_CategoryHeader)

_HCOL_SectionHeader() {
	Read := _HCOL_Read("[rolls.first]`ndelay_offset = 0.2`n[rolls.second] # own section`ndelay_offset = 0.8`n")
	AssertEqual(0.2, Read.Overrides["rolls"].Sections["first"].PendingOffset, "a commented section must not overwrite the previous section")
	AssertTrue(Read.Overrides["rolls"].Sections.Has("second"), "the new section must exist")
	AssertEqual(0.8, Read.Overrides["rolls"].Sections["second"].PendingOffset, "the value belongs to the new section")
}
Test("HotstringsConfig: commented section keeps owner identity (hotstrings-override-lexical)", _HCOL_SectionHeader)

_HCOL_ExtensionHeader() {
	Read := _HCOL_Read("[rolls]`ndelay_offset = 0.3`n[ext.Demo-Pack] # own extension`ndelay_offset = 0.7`n")
	AssertEqual(0.3, Read.Overrides["rolls"].PendingOffset, "a commented extension must not overwrite the previous category")
	AssertTrue(Read.Overrides.Has("ext.demo-pack"), "the extension retains canonical case folding")
	AssertEqual(0.7, Read.Overrides["ext.demo-pack"].PendingOffset, "the value belongs to the extension")
}
Test("HotstringsConfig: commented extension keeps owner identity (hotstrings-override-lexical)", _HCOL_ExtensionHeader)

_HCOL_ExtensionSectionHeader() {
	Read := _HCOL_Read("[ext.demo]`ndelay_offset = 0.4`n[ext.demo.symbols] # own section`ndelay_offset = 0.6`n")
	AssertEqual(0.4, Read.Overrides["ext.demo"].PendingOffset, "a commented extension section must not overwrite its parent")
	AssertTrue(Read.Overrides["ext.demo"].Sections.Has("symbols"), "the extension section must exist")
	AssertEqual(0.6, Read.Overrides["ext.demo"].Sections["symbols"].PendingOffset, "the section receives its own value")
}
Test("HotstringsConfig: commented extension section keeps owner identity (hotstrings-override-lexical)", _HCOL_ExtensionSectionHeader)

_HCOL_Fields() {
	Content := "[rolls]`ndelay_offset = 0.9 # timing`n"
		. 'color = "#112233" # literal color hash' . "`n"
		. "show_tooltip = false # tooltip`npriority = 7 # priority`n"
	Read := _HCOL_Read(Content)
	Entry := Read.Overrides["rolls"]
	AssertEqual(0.9, Entry.PendingOffset, "a trailing comment must preserve the numeric delay")
	AssertEqual("#112233", Entry.Color, "the quoted color hash is data")
	AssertEqual(false, Entry.ShowTooltip, "a trailing comment must preserve the boolean override")
	AssertEqual(7, Entry.Priority, "a trailing comment must preserve the integer priority")
}
Test("HotstringsConfig: comments preserve all override field types (hotstrings-override-lexical)", _HCOL_Fields)

_HCOL_GlobalHeader() {
	Content := "[__global__] # delimiter owner`n"
		. 'word_delimiters = ".?!"' . "`n"
		. 'consumed_delimiters = ";"' . "`n[rolls]`ndelay_offset = 0.2`n"
	Read := _HCOL_Read(Content)
	AssertEqual(".?!", Read.Word, "a commented global header must expose its delimiter value")
	AssertEqual(Chr(59), Read.Consumed, "the consumed delimiters share the global header owner")
	AssertEqual(0.2, Read.Overrides["rolls"].PendingOffset, "ordinary categories remain readable after global values")
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
		. "[rolls]`ndelay_offset = 0.3`nshow_tooltip = true`npriority = 4`n"
		. "[rolls.symbols]`ndelay_offset = 0.2`n[ext.demo]`ndelay_offset = 0.5`n"
	Read := _HCOL_Read(Content)
	AssertEqual(".", Read.Word, "an ordinary global key retains its value")
	AssertEqual("", Read.Consumed, "an absent delimiter key keeps the existing absent sentinel")
	AssertEqual(0.3, Read.Overrides["rolls"].PendingOffset, "an ordinary category remains unchanged")
	AssertEqual("", Read.Overrides["rolls"].Color, "an absent override retains its default sentinel")
	AssertEqual(true, Read.Overrides["rolls"].ShowTooltip, "ordinary true remains true")
	AssertEqual(4, Read.Overrides["rolls"].Priority, "ordinary integer priority remains intact")
	AssertEqual(0.2, Read.Overrides["rolls"].Sections["symbols"].PendingOffset, "ordinary sections remain separate")
	AssertEqual(0.5, Read.Overrides["ext.demo"].PendingOffset, "ordinary extensions remain separate")
	AssertEqual(0, _ParseOverrides("").Count, "an absent override path retains its empty map")
	AssertEqual("", _ParseGlobalKey("", "word_delimiters"), "an absent global path retains its empty sentinel")
}
Test("HotstringsConfig: ordinary values and absent defaults remain intact (hotstrings-override-lexical)", _HCOL_OrdinaryDefaults)

_HCOL_FullLineComments() {
	Content := "[rolls]`ndelay_offset = 0.3`n# [magickey]`n# delay = 0.9`n"
		. "[__global__]`n# word_delimiters = ignored`n" . 'word_delimiters = "."' . "`n"
	Read := _HCOL_Read(Content)
	AssertEqual(0.3, Read.Overrides["rolls"].PendingOffset, "full-line comment assignments do not change values")
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
