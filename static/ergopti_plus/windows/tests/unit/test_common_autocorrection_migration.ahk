; tests/unit/test_common_autocorrection_migration.ahk

; ==============================================================================
; MODULE: Independent Common Autocorrection Override Migration Tests
; DESCRIPTION:
; Replays handwritten complete byte images through the actual Windows record
; owner and qualifies conditional native publication before live initialization.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../modules/hotstrings.ahk

_CAO_Policy() {
	global _SharedDir
	return _ConfigMigrateParse(FSReadStrict(_SharedDir
		. "\data\hotstrings\common_autocorrection_migration.toml"), "independent override policy")["migration"]["ops"]
}

_CAO_Bytes(Name) {
	global _SharedDir
	return _CMG_Read(_SharedDir . "\tests\corpus\common_autocorrection_migration\" . Name . ".toml")
}

_CAO_CompleteBytes() {
	Input := _CAO_Bytes("input"), Expected := _CAO_Bytes("expected")
	Plan := HotstringsCommonOverridePlan(Input, _CAO_Policy())
	AssertEqual("migrated", Plan["outcome"])
	Assert(StrCompare(Expected, Plan["candidate"], true) == 0, "the entire independent byte image survives")
	AssertEqual("current", HotstringsCommonOverridePlan(Expected, _CAO_Policy())["outcome"])
	AssertFalse(TOML_ParseDocument(Plan["candidate"]).Has("_meta"), "overrides never inherit config schema stamps")
}
Test("common override migration: all independent bytes and explicit false survive (common-autocorrection-split)",
	_CAO_CompleteBytes)

_CAO_Occupied() {
	Input := '[autocorrection]`nnames = { delay = 0.2, future = true }`n'
		. '[autocorrection.caps]`ndelay = 0.875`n'
		. '[autocorrection.abbreviations.delay]`nowned = "future"`n'
	Plan := HotstringsCommonOverridePlan(Input, _CAO_Policy())
	Actual := TOML_ParseDocument(Plan["candidate"])["autocorrection"]
	AssertEqual(0.2, Actual["names"]["delay"])
	AssertTrue(Actual["names"]["future"].Value)
	AssertEqual("future", Actual["abbreviations"]["delay"]["owned"])
	AssertEqual(0.875, Actual["technical_terms"]["delay"])
	AssertThrows(() => HotstringsCommonOverridePlan('[autocorrection]`ncaps = { delay = 0.3 }`n', _CAO_Policy()),
		"an unaddressable legacy inline source cannot report a successful no-op")
	AssertThrows(() => HotstringsCommonOverridePlan(Input, [Map("op", "missing")]), "invalid operation refuses")
}
Test("common override migration: occupied namespaces and strict source ownership (common-autocorrection-split)",
	_CAO_Occupied)

_CAO_NativePublication() {
	global _HotstringsCommonOverrideAdmitted
	SavedAdmission := HotstringsCommonOverrideAdmitted()
	Directory := _CMG_NewDir(), Path := Directory . "\overrides.toml"
	Input := _CAO_Bytes("input"), Expected := _CAO_Bytes("expected")
	try {
		AssertTrue(HotstringsCommonOverrideMigrate(Path), "an absent file needs no publication")
		AssertFalse(FileExist(Path), "the absent override remains absent")
		AssertTrue(FSWriteCreateDurable(Path, Input))
		Calls := 0
		Refuse(Target, Candidate, Source) {
			Calls += 1
			AssertEqual(Path, Target)
			Assert(StrCompare(Expected, Candidate, true) == 0)
			Assert(StrCompare(Input, Source, true) == 0, "native source fence retains the exact observation")
			return "independent native refusal"
		}
		AssertFalse(HotstringsCommonOverrideMigrate(Path, Refuse))
		AssertEqual(1, Calls)
		Assert(StrCompare(Input, _CMG_Read(Path), true) == 0, "refusal leaves every source byte unchanged")
		Assert(TOML_WriteRefusal(Path) != "", "the refused override cannot subsequently save")
		SuccessPath := Directory . "\acknowledged.toml"
		AssertTrue(FSWriteCreateDurable(SuccessPath, Input))
		AssertTrue(HotstringsCommonOverrideMigrate(SuccessPath))
		Assert(StrCompare(Expected, _CMG_Read(SuccessPath), true) == 0, "the actual atomic publisher writes the independent candidate")
		AssertTrue(HotstringsCommonOverrideMigrate(SuccessPath), "a second boot is idempotent")
	} finally {
		_HotstringsCommonOverrideAdmitted := SavedAdmission
		for RefusedName in ["overrides.toml", "foreign.toml", "legacy-invalid.toml"] {
			RefusalKey := _TOML_WriteRefusalKey(Directory . "\" . RefusedName)
			if _TOML_WriteRefusals().Has(RefusalKey)
				_TOML_WriteRefusals().Delete(RefusalKey)
		}
		DirDelete(Directory, true)
	}
}
Test("common override migration: actual absent and acknowledged native publication (common-autocorrection-split)",
	_CAO_NativePublication)

_CAO_NativeInitialization() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HotstringsCommonOverrideAdmitted
	SavedAdmission := HotstringsCommonOverrideAdmitted()
	Saved := [_HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters]
	Directory := _CMG_NewDir(), Path := Directory . "\overrides.toml"
	try {
		AssertTrue(FSWriteCreateDurable(Path, _CAO_Bytes("input")))
		HotstringsConfigInit(Path)
		Assert(StrCompare(_CAO_Bytes("expected"), _CMG_Read(Path), true) == 0)
		for Section in ["names", "abbreviations", "technical_terms"] {
			Actual := _HotstringsOverrides["autocorrection"].Sections[Section]
			AssertEqual(Section == "names" ? 0.2 : 0.875, Actual.Delay)
			AssertEqual(Section == "abbreviations" ? "#abcdef" : "#123456", Actual.Color)
			AssertEqual(Section == "names", Actual.ShowTooltip)
			AssertEqual(23, Actual.Priority)
			Resolved := HotstringsResolve("autocorrection", Section)
			AssertEqual(Actual.Delay, Resolved.Delay, "the inline-commented explicit choice reaches native runtime")
			AssertEqual(23, Resolved.Priority)
		}
	} finally {
		_HotstringsOverridesPath := Saved[1], _HotstringsOverrides := Saved[2]
		_HotstringsWordDelimiters := Saved[3], _HotstringsConsumedDelimiters := Saved[4]
		_HotstringsCommonOverrideAdmitted := SavedAdmission
		HotstringsResolveBumpGen()
		for RefusedName in ["overrides.toml", "foreign.toml", "legacy-invalid.toml"] {
			RefusalKey := _TOML_WriteRefusalKey(Directory . "\" . RefusedName)
			if _TOML_WriteRefusals().Has(RefusalKey)
				_TOML_WriteRefusals().Delete(RefusalKey)
		}
		DirDelete(Directory, true)
	}
}
Test("common override migration: native initialization consumes acknowledged new section choices (common-autocorrection-split)",
	_CAO_NativeInitialization)

; Production initialization, not a test flag, fences the actual native entrypoints.
_CAO_NativeAdmission() {
	global _HotstringsCommonOverrideAdmitted, HSE_RegistryByGroup, Features
	SavedFeatures := Features
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	Saved := [_HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters,
		HotstringsCommonOverrideAdmitted()]
	Directory := _CMG_NewDir(), Path := Directory . "\foreign.toml"
	Source := '[__global__]`nfuture = "bad\uD800" # retain unrelated unsupported scalar bytes`n'
	try {
		AssertTrue(FSWriteCreateDurable(Path, Source))
		HotstringsConfigInit(Path)
		AssertEqual(false, HotstringsCommonOverrideAdmitted(), "unproved common override semantics stay closed")
		Assert(StrCompare(Source, _CMG_Read(Path), true) == 0, "foreign bytes remain unchanged")
		HSE_TestReset()
		CreateHotstring("*C", "foreign", "Preserved", Map("Category", "foreign", "Section", "owned"))
		Sequence := HSE_RegistryByGroup["foreign.owned"][1].Seq
		AssertThrows(() => LoadHotstringsCategory("autocorrection", Map("names", Map("enabled", true))),
			"requested common category refuses before any runtime publication")
		AssertThrows(() => LoadHotstringsSection("autocorrection", "technical_terms", Map("enabled", true)),
			"the direct native section entry cannot bypass admission")
		AssertEqual(1, HSE_RegistryByGroup.Count)
		AssertEqual(Sequence, HSE_RegistryByGroup["foreign.owned"][1].Seq)
		Features := Map("hotstrings", Map("autocorrection", Map(
			"names", Map("enabled", true), "abbreviations", Map("enabled", false), "technical_terms", Map("enabled", false))))
		AssertEqual(false, RegisterAllHotstrings(), "the actual boot owner preflights before any partial registration")
		AssertEqual(false, _RebuildHotstringsLiveOnce(), "the actual live owner preflights before clearing its existing runtime image")
		AssertEqual(1, HSE_RegistryByGroup.Count)
		AssertEqual(Sequence, HSE_RegistryByGroup["foreign.owned"][1].Seq)
		LoadHotstringsCategory("autocorrection", Map("names", Map("enabled", false)))
		AssertEqual(1, HSE_RegistryByGroup.Count, "disabled choices remain desired and do not publish common rows")
		LegacyPath := Directory . "\legacy-invalid.toml"
		Legacy := '[autocorrection.caps]`ncolor = "bad\q"`n[__global__]`nword_delimiters = "bad\uD800"`n'
		AssertTrue(FSWriteCreateDurable(LegacyPath, Legacy))
		AssertFalse(HotstringsCommonOverrideMigrate(LegacyPath), "a malformed known owned source cannot become a successful passthrough")
		CommittedOverrides := _HotstringsOverrides, CommittedDelimiters := _HotstringsWordDelimiters
		AssertEqual(false, HotstringsConfigInit(LegacyPath), "unsafe source bytes never reach the native color or delimiter decoder")
		AssertTrue(_HotstringsOverrides == CommittedOverrides, "failed migration retains the exact prior proven override object")
		AssertEqual(CommittedDelimiters, _HotstringsWordDelimiters)
		AssertEqual(false, HotstringsCommonOverrideAdmitted(), "the actual retained-source boot owner never acknowledges failed migration")
		Assert(TOML_WriteRefusal(LegacyPath) != "", "failed owned migration blocks later override publication")
		AssertEqual(false, RegisterAllHotstrings())
		AssertEqual(false, _RebuildHotstringsLiveOnce())
		AssertEqual(1, HSE_RegistryByGroup.Count)
		AssertEqual(Sequence, HSE_RegistryByGroup["foreign.owned"][1].Seq)
		Assert(StrCompare(Legacy, _CMG_Read(LegacyPath), true) == 0)
	} finally {
		_HotstringsOverridesPath := Saved[1], _HotstringsOverrides := Saved[2]
		_HotstringsWordDelimiters := Saved[3], _HotstringsConsumedDelimiters := Saved[4]
		_HotstringsCommonOverrideAdmitted := Saved[5]
		Features := SavedFeatures
		HotstringsResolveBumpGen()
		HSE_TestReset()
		for RefusedName in ["overrides.toml", "foreign.toml", "legacy-invalid.toml"] {
			RefusalKey := _TOML_WriteRefusalKey(Directory . "\" . RefusedName)
			if _TOML_WriteRefusals().Has(RefusalKey)
				_TOML_WriteRefusals().Delete(RefusalKey)
		}
		DirDelete(Directory, true)
	}
}
Test("common override migration: actual native admission refuses an unacknowledged common cohort (common-autocorrection-split)",
	_CAO_NativeAdmission)

; Optional sibling owners exist only in the complete group snapshot. Generic
; global probes keep this fixture executable with the isolated 104 source slice.
_CAO_IsolateOptionalOwners() {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _UserHotstringsInputSerial, _UserHotstringsCapture, _UserHotstringsLastRepair, _UserHotstringsRepairPending
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending, PersonalInformationHotstrings, HSE_PersonalInfoCombosEnabled
	if IsSet(_UserHotstringsJobs)
		AssertEqual(0, _UserHotstringsJobs.Count, "an earlier programmable owner cannot leave live native jobs")
	if IsSet(_UserHotstringsLoader)
		AssertFalse(IsObject(_UserHotstringsLoader), "an earlier fixture cannot leave an owned native loader")
	Fresh := Map("_UserHotstringsOwner", 0, "_UserHotstringsLoader", 0, "_UserHotstringsJobs", Map(),
		"_UserHotstringsLoadEpoch", 0, "_UserHotstringsInputSerial", 0, "_UserHotstringsCapture", 0,
		"_UserHotstringsLastRepair", "", "_UserHotstringsRepairPending", false,
		"_HSE_TerminalOwner", 0, "_HSE_TerminalReplayPending", 0,
		"PersonalInformationHotstrings", Map(), "HSE_PersonalInfoCombosEnabled", false)
	Saved := Map()
	for NativeName, Value in Fresh
		if IsSet(%NativeName%) {
			Saved[NativeName] := %NativeName%
			%NativeName% := Value
		}
	return Saved
}

_CAO_RestoreOptionalOwners(Saved) {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _UserHotstringsInputSerial, _UserHotstringsCapture, _UserHotstringsLastRepair, _UserHotstringsRepairPending
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending, PersonalInformationHotstrings, HSE_PersonalInfoCombosEnabled
	for NativeName, Value in Saved
		%NativeName% := Value
}

; The cold initializer runs real unrelated registrars rather than fabricating a
; successful receipt from the migration helper. All selections are explicit.
_CAO_NativeColdBoot() {
	global Features, ScriptInformation, ConfigurationFile, HSE_RegistryByGroup
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HotstringsCommonOverrideAdmitted, _HS_CACHE_LOADED, _HS_CACHE_ROWS, _GENERATED_HOTSTRINGS
	global HotstringGroupConfig, _HotstringBoundSources, _HotstringExtensionPacks
	SavedFeatures := Features, SavedInformation := ScriptInformation, SavedConfiguration := ConfigurationFile
	Saved := [_HotstringsOverridesPath, _HotstringsOverrides, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters,
		HotstringsCommonOverrideAdmitted(), _HS_CACHE_LOADED, _HS_CACHE_ROWS, _GENERATED_HOTSTRINGS,
		HotstringGroupConfig, _HotstringBoundSources, _HotstringExtensionPacks]
	OptionalOwners := _CAO_IsolateOptionalOwners()
	global PersonalFileControls, PersonalInformation
	HadPersonalInformation := IsSet(PersonalInformation)
	SavedPersonalInformation := HadPersonalInformation ? PersonalInformation : 0
	SavedPersonalControls := IsSet(PersonalFileControls) ? [PersonalFileControls.owners, PersonalFileControls.inventory] : false
	Directory := _CMG_NewDir(), Path := Directory . "\overrides.toml"
	Source := '[autocorrection.caps]`ncolor = "bad\uD800"`n'
	try {
		BootSource := _StripFullLineComments(FileRead(_DriverDir . "\ErgoptiPlus.ahk", "UTF-8"))
		PersonalInformation := _HSCS_TrayMapLiteral(BootSource, "PersonalInformation")
		if SavedPersonalControls is Array
			PersonalFileControls.owners := Map(), PersonalFileControls.inventory := []
		Features := _HSDeepCloneMap(SavedFeatures)
		for Group, Children in Features["hotstrings"]
			if Children is Map
				for Section, Node in Children
					if Node is Map && Node.Has("enabled")
						Node["enabled"] := false
		Features["hotstrings"]["autocorrection"] := Map("names", Map("enabled", true),
			"abbreviations", Map("enabled", false), "technical_terms", Map("enabled", false))
		French := Map()
		for Section in ["typographic_apostrophe", "errors", "ou", "multiple_punctuation_marks",
			"suffixes_a_chaining", "minus", "minus_apostrophe", "names", "accents"]
			French[Section] := Map("enabled", Section == "names")
		Features["hotstrings"]["french_autocorrection"] := French
		Features["hotstrings"]["french_distancesreduction"] := Map("suffixes_a", Map("enabled", false))
		Features["hotstrings"]["french_magickey"] := Map("text_expansion", Map("enabled", false),
			"text_expansion_auto", Map("enabled", false), "text_expansion_emojis", Map("enabled", false))
		for Section in ["close_chevron_tag", "comment_close", "comment_open", "english_negation", "assign",
			"close_chevron", "hashtag_open_bracket", "hashtag_close_bracket", "hashtag_quote",
			"assign_arrow_equal_left", "assign_arrow_equal_right", "assign_arrow_minus_left", "assign_arrow_minus_right"]
			Features["hotstrings"]["rolls"][Section] := Map("enabled", false)
		ScriptInformation := SavedInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := Directory . "\missing.toml"
		ScriptInformation["PersonalHotstringsDir"] := Directory . "\missing"
		ConfigurationFile := Directory . "\config.toml"
		AssertTrue(FSWriteCreateDurable(ConfigurationFile, "# independent empty personal configuration`n"))
		_HotstringExtensionPacks := [], _HS_CACHE_LOADED := false
		_HS_CACHE_ROWS := Map(), _GENERATED_HOTSTRINGS := Map()
		HotstringGroupConfig := Map(), _HotstringBoundSources := Map()
		AssertTrue(FSWriteCreateDurable(Path, Source))
		AssertEqual(false, HotstringsConfigInit(Path), "actual failed cold migration retains its source")
		HSE_TestReset()
		Receipt := RegisterAllHotstrings(false, true)
		AssertTrue(Receipt["committed"], "the actual cold owner commits unrelated native families")
		AssertFalse(Receipt["complete"], "partial startup must never announce a complete common registry")
		AssertEqual(1, Receipt["unavailable"].Length)
		AssertEqual("autocorrection", Receipt["unavailable"][1])
		for Section in ["names", "abbreviations", "technical_terms"]
			AssertFalse(HSE_RegistryByGroup.Has("autocorrection." . Section))
		AssertTrue(HSE_RegistryByGroup.Has("french_autocorrection.names"), "unrelated actual native registration survives")
		Found := false
		for Spec in HSE_RegistryByGroup["french_autocorrection.names"]
			if Spec.Trigger == "aicha" && Spec.Replacement == "Aïcha"
				Found := true
		AssertTrue(Found, "an independently authored unrelated trigger still exists after cold refusal")
		PreviewIndex := Map("preserved", []), PreviewSet := Map("preserved", true)
		AssertEqual(0, _RegisterCategoryTriggers("autocorrection", PreviewIndex, PreviewSet),
			"actual source-backed previews cannot advertise unavailable common triggers")
		AssertEqual(0, _RegisterCategoryTriggersFromCache("autocorrection", PreviewIndex, PreviewSet),
			"actual cached previews cannot advertise unavailable common triggers")
		AssertEqual(1, PreviewIndex.Count)
		AssertEqual(1, PreviewSet.Count)
		AssertTrue(PreviewIndex.Has("preserved") && PreviewSet.Has("preserved"))
		Count := HSE_RegistryByGroup.Count, Sequence := HSE_RegistryByGroup["french_autocorrection.names"][1].Seq
		AssertEqual(false, RegisterAllHotstrings(), "default registration remains a fail-closed live owner")
		AssertEqual(false, _RebuildHotstringsLiveOnce(), "live refusal precedes registry clear")
		AssertEqual(Count, HSE_RegistryByGroup.Count)
		AssertEqual(Sequence, HSE_RegistryByGroup["french_autocorrection.names"][1].Seq)
		Assert(StrCompare(Source, _CMG_Read(Path), true) == 0, "cold/live policy never rewrites refused source bytes")
		HotstringsConfigInit(Directory . "\acknowledged-absent.toml")
		AssertEqual(true, HotstringsCommonOverrideAdmitted(), "a genuinely absent source admits common registration")
		HSE_TestReset()
		Complete := RegisterAllHotstrings(false, true)
		AssertTrue(Complete["committed"] && Complete["complete"], "healthy cold startup returns a complete receipt")
		AssertEqual(0, Complete["unavailable"].Length)
		AssertTrue(HSE_RegistryByGroup.Has("autocorrection.names"))
		AssertTrue(HSE_RegistryByGroup.Has("french_autocorrection.names"))
	} finally {
		PersonalInformation := HadPersonalInformation ? SavedPersonalInformation : unset
		Features := SavedFeatures, ScriptInformation := SavedInformation, ConfigurationFile := SavedConfiguration
		_HotstringsOverridesPath := Saved[1], _HotstringsOverrides := Saved[2]
		_HotstringsWordDelimiters := Saved[3], _HotstringsConsumedDelimiters := Saved[4]
		_HotstringsCommonOverrideAdmitted := Saved[5], _HS_CACHE_LOADED := Saved[6], _HS_CACHE_ROWS := Saved[7]
		_GENERATED_HOTSTRINGS := Saved[8], HotstringGroupConfig := Saved[9], _HotstringBoundSources := Saved[10]
		_HotstringExtensionPacks := Saved[11]
		HotstringsResolveBumpGen(), HSE_TestReset()
		if SavedPersonalControls is Array
			PersonalFileControls.owners := SavedPersonalControls[1], PersonalFileControls.inventory := SavedPersonalControls[2]
		_CAO_RestoreOptionalOwners(OptionalOwners)
		for RefusedName in ["overrides.toml", "foreign.toml", "legacy-invalid.toml"] {
			RefusalKey := _TOML_WriteRefusalKey(Directory . "\" . RefusedName)
			if _TOML_WriteRefusals().Has(RefusalKey)
				_TOML_WriteRefusals().Delete(RefusalKey)
		}
		DirDelete(Directory, true)
	}
}
Test("common override migration: actual cold owner classifies unavailable common families and retains unrelated native groups (common-autocorrection-split)",
	_CAO_NativeColdBoot)
