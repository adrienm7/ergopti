; static/ergopti_plus/windows/tests/unit/modules/hotstrings/catalogue/test_hotstrings_cache.ahk

; ==============================================================================
; MODULE: Hotstrings Self-Healing Cache Tests
; DESCRIPTION:
; Pins the behaviour of infra/hotstrings/hotstrings_cache.ahk — the gitignored .tsv
; cache that replaced the committed generated_*.ahk bundle. The bundled-hotstring
; registration path had NO end-to-end coverage in the headless suite before this;
; these tests are that safety net.
;
; WHY THIS MATTERS (the regressions this encodes):
;   1. Build parity: _HotstringsCacheBuildRows must extract the SAME rows the old
;      generated bundle did. It parses the real bundled TOMLs with the identical
;      line scan + _HOTSTRING_ENTRY_PATTERN the runtime TOML fallback uses, so a
;      regex / flag-logic drift would silently drop or mis-flag thousands of
;      everyday expansions. A specific stable entry and a non-trivial total floor
;      catch that.
;   2. Lossless round-trip: write -> read of the .tsv must preserve every row
;      exactly, including triggers/outputs carrying backslashes and quotes. A
;      broken escape/unescape would corrupt expansions only on the FAST (cached)
;      path — invisible on first launch — so it is pinned here.
;
; SCOPE: drives the real cache module against the real shared TOMLs through the
;   test harness (which supplies UnescapeTomlString, the entry pattern and a
;   ScriptInformation stub). ASCII-only per the suite convention.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../../modules/hotstrings/hotstrings_autocorrection.ahk





; ===============================
; ===============================
; ======= 1/ Test helpers =======
; ===============================
; ===============================

; Point the cache at the real shared hotstrings tree (static/ergopti_plus/_shared)
; resolved relative to the tests directory, so the build reads the genuine TOMLs.
_HsCacheTestSharedDir() {
	SplitPath(A_ScriptDir, , &WindowsDir)   ; ...\windows
	SplitPath(WindowsDir, , &DriversDir)    ; ...\ergopti_plus
	return DriversDir . "\_shared"
}

; Deep-compare two cache rows ([flags, trigger, output, final, repeat, caseSens]).
_HsCacheRowsEqual(A, B) {
	if (A.Length != B.Length)
		return false
	for Idx, Val in A {
		if (B[Idx] != Val)
			return false
	}
	return true
}





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

TestHsCache_BuildExtractsKnownEntry() {
	global _SharedDir
	SavedShared := _SharedDir
	try {
		_SharedDir := _HsCacheTestSharedDir()
		Rows := _HotstringsCacheBuildRows()

		Assert(Rows.Count > 0, "cache build must yield at least one section")
		; Layout-bound categories never enter this cache. The bundled symbol
		; expansion retains the whitespace and strict-case coverage of this parser.
		Key := "magickey.text_expansion_symbols"
		Assert(Rows.Has(Key), "cache build must contain the stable " . Key . " section")
		SymbolRows := Rows[Key]
		AssertEqual(140, SymbolRows.Length, "every symbol expansion must reach the cache")
		Expected := ["*?C", " -> ★", " ➜ ", false, false, true, ""]
		Assert(_HsCacheRowsEqual(SymbolRows[1], Expected),
			"the first symbol retains its flags, literal case and absent priority override")
		Assert(SymbolRows[1][2] == " -> ★" && SymbolRows[1][3] == " ➜ ",
			"trigger and output retain leading and trailing spaces whole")
	} finally _SharedDir := SavedShared
}

TestHsCache_BuildCoversEveryBundledCategory() {
	global _SharedDir
	SavedShared := _SharedDir
	try {
		_SharedDir := _HsCacheTestSharedDir()
		Rows := _HotstringsCacheBuildRows()

		; Sum rows per top-level category and assert each bundled category contributed.
		Totals := Map()
		Grand := 0
		for Key, RowList in Rows {
			Cat := StrSplit(Key, ".", , 2)[1]
			Totals[Cat] := (Totals.Has(Cat) ? Totals[Cat] : 0) + RowList.Length
			Grand += RowList.Length
		}
		for Cat in ["autocorrection", "magickey"]
			Assert(Totals.Has(Cat) and Totals[Cat] > 0, "bundled category '" . Cat . "' must contribute rows")
		; SFB reduction and rolls are the Ergopti extension's files, loaded from there.
		for Cat in ["distancesreduction", "sfbsreduction", "rolls"]
			Assert(!Totals.Has(Cat), "the extension category '" . Cat . "' must not be compiled into the cache")
		; Floor well below the ~2992 current total: a builder that silently drops most
		; entries (regex/flag regression) fails here, while legitimate TOML edits pass.
		Assert(Grand > 2000, "cache build total must stay in the thousands (got " . Grand . ")")
	} finally _SharedDir := SavedShared
}

TestHsCache_TsvRoundTripIsLossless() {
	global _SharedDir
	SavedShared := _SharedDir
	try {
		_SharedDir := _HsCacheTestSharedDir()
		Rows := _HotstringsCacheBuildRows()

		TmpTsv := A_Temp . "\ergopti_hscache_test.tsv"
		_HotstringsCacheWriteTsv(TmpTsv, Rows)
		Back := _HotstringsCacheReadTsv(FileRead(TmpTsv, "UTF-8"))
		try FileDelete(TmpTsv)

		Assert(Back.Count == Rows.Count,
			"round-trip must preserve every section (" . Back.Count . " vs " . Rows.Count . ")")
		; Deep-check a section survived byte-for-byte: its outputs carry a trailing
		; space and non-ASCII letters.
		Key := "magickey.text_expansion_symbols"
		Assert(Back.Has(Key), "round-trip must keep " . Key)
		Orig := Rows[Key]
		RT := Back[Key]
		Assert(RT.Length == Orig.Length, Key . " row count must survive round-trip")
		AllEqual := true
		for Idx, Row in Orig {
			if !_HsCacheRowsEqual(Row, RT[Idx])
				AllEqual := false
		}
		Assert(AllEqual, "every " . Key . " row must be identical after a write/read round-trip")
	} finally _SharedDir := SavedShared
}

TestHsCache_EscapeUnescapeHandlesSpecials() {
	; A value carrying every escape-sensitive character must survive the round-trip:
	; backslash (escaped first), tab (the column delimiter), CR and LF.
	Original := "a\b" . Chr(9) . "c" . Chr(13) . "d" . Chr(10) . "e"
	Escaped := _HsCacheEscape(Original)
	Assert(!InStr(Escaped, Chr(9)), "escaped value must not contain a raw tab (would break the column split)")
	Assert(!InStr(Escaped, Chr(10)), "escaped value must not contain a raw newline")
	Assert(_HsCacheUnescape(Escaped) == Original, "unescape(escape(x)) must equal x for all special characters")
}

TestHsCache_PriorityDomainRejectsCorruptRow() {
	Corrupt := "# source-order-v1`nrolls`tassign`t*?`ta`tb`t0`t0`t0`t101`n"
	AssertThrows(() => _HotstringsCacheReadTsv(Corrupt),
		"cache priority above 100 must invalidate the cache instead of reaching registration")
}

Test("hotstrings cache: build extracts a known entry with correct flags", TestHsCache_BuildExtractsKnownEntry)
Test("hotstrings cache: build covers every bundled category", TestHsCache_BuildCoversEveryBundledCategory)
Test("hotstrings cache: .tsv write/read round-trip is lossless", TestHsCache_TsvRoundTripIsLossless)
Test("hotstrings cache: escape/unescape handles tab, CR, LF and backslash", TestHsCache_EscapeUnescapeHandlesSpecials)
Test("hotstrings cache: priority domain rejects a corrupt row",
	TestHsCache_PriorityDomainRejectsCorruptRow)

; Category moves change the index even when all surviving TOMLs are older.
TestHsCache_IndexChangeInvalidatesCache() {
	global _SharedDir
	Saved := _SharedDir
	Directory := _LCT_TempDir()
	try {
		_SharedDir := Directory
		DirCreate(Directory . "\modules\hotstrings")
		IndexPath := Directory . "\modules\hotstrings\_index.toml"
		FileAppend('[menu]`ncategories_order = ["magickey"]`n[languages]`norder = []`n', IndexPath, "UTF-8")
		SourcePath := Directory . "\modules\hotstrings\magickey.toml"
		AssertTrue(FSWriteCreateDurable(SourcePath,
			'[[ct]]`n"indexprobe" = { output = "Index", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true }`n'))
		TsvPath := Directory . "\cache.tsv"
		_HotstringsCacheWriteTsv(TsvPath, _HotstringsCacheBuildRows())
		AssertTrue(_HotstringsCacheIsFresh(TsvPath), "the genuine initial cache must actually be eligible")
		AssertTrue(FSWriteDurable(IndexPath,
			'[menu]`ncategories_order = ["autocorrection", "magickey"]`n[languages]`norder = []`n'))
		FileSetTime("20000102000000", TsvPath, "M")
		FileSetTime("20000103000000", IndexPath, "M")
		Assert(!_HotstringsCacheIsFresh(TsvPath), "a changed shared index must invalidate an existing cache")
		; Native freshness is a witness, not permission to replace the canonical
		; process snapshot. Explicit invalidation owns the following re-read.
		_ParseTomlGroupConfig_InvalidatePath(IndexPath)
		Common := HotstringsCommonCategories()
		AssertEqual(2, Common.Length)
		AssertEqual("autocorrection", Common[1])
		AssertEqual("magickey", Common[2])
	} finally {
		_SharedDir := Saved
		HotstringsCommonCategories()
		DirDelete(Directory, true)
	}
}
Test("hotstrings cache: shared index moves invalidate persisted categories", TestHsCache_IndexChangeInvalidatesCache)





; ==============================================================
; ==============================================================
; ======= 3/ Independent common autocorrection reference =======
; ==============================================================
; ==============================================================

; This reference was captured before classification; neither the cache nor the
; native registrar is allowed to manufacture its expected rules from the TOML.
_HsCacheCommonReference() {
	return JsonParse(FileRead(_HsCacheTestSharedDir()
		. "\tests\corpus\hotstrings\common_autocorrection_entries.json", "UTF-8"))
}

; The independently frozen pre-split input retains its original reader routes.
_HsCacheLegacyRoot() {
	Root := A_Temp . "\ergopti-legacy-common-" . A_TickCount . "-" . Random(100000, 999999)
	DirCreate(Root . "\modules\hotstrings")
	FileCopy(_HsCacheTestSharedDir() . "\tests\corpus\hotstrings\common_autocorrection_legacy\autocorrection.toml",
		Root . "\modules\hotstrings\autocorrection.toml")
	FileAppend('[menu]`ncategories_order = ["autocorrection"]`n[languages]`norder = []`n',
		Root . "\modules\hotstrings\_index.toml", "UTF-8")
	return Root
}

_HsCacheCommonReferenceRows() {
	global _SharedDir, HotstringGroupConfig
	SavedShared := _SharedDir
	SavedMetadata := HotstringGroupConfig
	try {
		_SharedDir := _HsCacheLegacyRoot()
		HotstringGroupConfig := Map()
		Reference := _HsCacheCommonReference()
		AssertEqual(140, Reference["entries"].Length)
		AssertEqual("common", Reference["source"])
		AssertEqual(10, Reference["source_priority"])
		AssertEqual("caps", Reference["legacy_section"])
		Rows := _HotstringsCacheBuildRows()
		Key := "autocorrection.caps"
		Assert(Rows.Has(Key), "classification must leave the historical preference identity live")
		AssertEqual(140, Rows[Key].Length)
		CommonSections := 0
		for Name in Rows
			if InStr(Name, "autocorrection.") == 1
				CommonSections += 1
		AssertEqual(1, CommonSections, "the editorial catalogue must not change native section selection")
		for Index, Row in Reference["entries"] {
			AssertEqual(Index, Row["ordinal"])
			AssertEqual("caps", Row["section"])
			Actual := Rows[Key][Index]
			AssertEqual(Row["auto_expand"] ? "*" : "", Actual[1], Row["trigger"] . " flags")
			Assert(Actual[2] == Row["trigger"], "trigger identity and source order remain exact")
			Assert(Actual[3] == Row["output"], "replacement identity remains exact")
			AssertEqual(Row["final_result"], Actual[4])
			AssertEqual(false, Actual[5], "capitalization is never a repeat fallback")
			AssertEqual(Row["is_case_sensitive"], Actual[6])
			AssertEqual("", Actual[7], "no individual priority overrides the common tier")
		}
		Metadata := ParseTomlGroupConfig("autocorrection")
		AssertEqual(Reference["meta"]["delay"], Metadata.Delay)
		AssertEqual(Reference["meta"]["color"], Metadata.Color)
		AssertEqual(Reference["meta"]["show_tooltip"], Metadata.ShowTooltip)
		Order := ReadTomlSectionsOrder("autocorrection")
		AssertEqual(1, Order.Length)
		AssertEqual(Reference["meta"]["sections_order"][1], Order[1])
	} finally {
		DirDelete(_SharedDir, true)
		_SharedDir := SavedShared
		HotstringGroupConfig := SavedMetadata
	}
}
Test("common autocorrection: cache preserves all 140 independent rules and their exact source order (common-autocorrection-reference)",
	_HsCacheCommonReferenceRows)

; Both real section-loading paths must agree with the independent capture. The
; cache is installed in memory to avoid touching a live or shared TSV artifact.
_HsCacheCommonReferenceNative(UseCache, SourceOrdered := false) {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _HotstringsOverrides, HotstringGroupConfig, HSE_RegistryByGroup
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED,
		_GENERATED_HOTSTRINGS, _HotstringsOverrides, HotstringGroupConfig]
	try {
		_SharedDir := _HsCacheLegacyRoot()
		Reference := _HsCacheCommonReference()
		_HotstringsOverrides := Map(), HotstringGroupConfig := Map()
		HotstringsResolveBumpGen()
		_HS_CACHE_ROWS := _HotstringsCacheBuildRows()
		_HS_CACHE_LOADED := true
		_GENERATED_HOTSTRINGS := Map()
		Key := "autocorrection.caps"
		if UseCache
			_GENERATED_HOTSTRINGS[Key] := _HsCacheRegisterSection.Bind(Key)
		HSE_TestReset()
		if SourceOrdered
			LoadHotstringsCategory("autocorrection", Map("caps", Map("enabled", true)))
		else
			LoadHotstringsSection("autocorrection", "caps", { Enabled: true })
		Assert(HSE_RegistryByGroup.Has(Key), "the real loader must publish the historical group")
		Registered := _HsCacheWithoutSpaceVariants(HSE_RegistryByGroup[Key])
		AssertEqual(140, Registered.Length, "every historical rule registers once")
		for Index, Row in Reference["entries"] {
			Spec := Registered[Index]
			Assert(Spec.Trigger == Row["trigger"], "the native registration order remains historical")
			Assert(Spec.Replacement == Row["output"], "the native replacement remains exact")
			AssertEqual(Row["ordinal"], Index, "the reference lists the rules in their insertion order")
			if Index > 1
				Assert(Spec.Seq > Registered[Index - 1].Seq, "equal-priority collisions keep their insertion precedence")
			AssertEqual(Row["is_word"], Spec.IsWord)
			AssertEqual(Row["auto_expand"], Spec.Auto)
			AssertEqual(Row["final_result"], Spec.FinalResult)
			AssertEqual(false, Spec.CaseSensitive, "literal registration retains case-folded matching")
			AssertEqual(false, Spec.HasOwnProp("CaseConform") && Spec.CaseConform)
			AssertEqual(Reference["source_priority"], Spec.Priority)
			AssertEqual(Reference["meta"]["delay"], Spec.TimeActivationSeconds)
		}
	} finally {
		HSE_TestReset()
		DirDelete(_SharedDir, true)
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _HotstringsOverrides := Saved[5]
		HotstringGroupConfig := Saved[6]
		HotstringsResolveBumpGen()
	}
}
Test("common autocorrection: the real cached loader preserves all historical registrations (common-autocorrection-reference)",
	_HsCacheCommonReferenceNative.Bind(true))
Test("common autocorrection: the real TOML fallback preserves all historical registrations (common-autocorrection-reference)",
	_HsCacheCommonReferenceNative.Bind(false))


; This independent native input spells every flag in the fixed inline-table
; grammar accepted by both real Windows loaders. The shared source/expectation
; corpus remains unchanged; its broader Lua grammar is not an AHK admission proof.
_HsCacheNativeSourceOrderText(Bound := false) {
	if Bound {
		Lines := [
			'[_meta]',
			'sections_order = ["caps"]',
			'[[caps]]',
			'"boundfirst" = { output = "First bound", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }',
			'[[caps]]',
			'"boundsecond" = { output = "Second bound", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }',
			'[[caps]]',
			'"boundthird" = { output = "Third bound", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }',
			'[[caps]]',
			'"boundfourth" = { output = "Fourth bound", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }']
	} else {
		Lines := [
			'[_meta]',
			'sections_order = ["abbreviations", "caps", "terms", "unknown"]',
			'delay = 0.5',
			'[_meta.section_delays]',
			'caps = 0.2',
			'terms = 0.3',
			'abbreviations = 0.4',
			'[[caps]]',
			'"firstx" = { output = "First", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true }',
			'[[terms]]',
			'"secondx" = { output = "Second", is_word = false, auto_expand = true, is_case_sensitive = true, final_result = false, is_case_sensitive_strict = true, priority = 44 }',
			'[[caps]]',
			'"thirdx" = { output = "Third", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }',
			'[[abbreviations]]',
			'"fourthx" = { output = "Fourth", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }',
			'[[unknown]]',
			'"unknownx" = { output = "Unknown", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = false }',
			'[[caps]]',
			'"sixthx" = { output = "Sixth", is_word = false, auto_expand = true, is_case_sensitive = true, final_result = false }']
	}
	Text := ""
	for Line in Lines
		Text .= Line . "`n"
	return Text
}

; Refuse a fixture that cannot reach the actual parser before testing registry
; order. Trigger/count expectations remain supplied by the frozen shared corpus.
_HsCacheAssertNativeSourceOrderInput(Text, ExpectedTriggers) {
	global _HOTSTRING_ENTRY_PATTERN
	Index := 0
	loop parse, Text, "`n", "`r" {
		Line := Trim(A_LoopField)
		if SubStr(Line, 1, 1) != Chr(34)
			continue
		Assert(RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Entry),
			"every native fixture entry must be admitted by the real loader grammar")
		Index += 1
		Assert(Index <= ExpectedTriggers.Length, "no extra native input entry may replace a missing fixture")
		AssertEqual(ExpectedTriggers[Index], UnescapeTomlString(Entry[1]),
			"the native legal input preserves the independently captured physical sequence")
	}
	AssertEqual(ExpectedTriggers.Length, Index, "all independent fixture inputs must reach the native parser")
}

; Drive the real cache builder, durable TSV round-trip and native registry with
; an independent interleaved source, without changing a live bundled file.
_HsCacheSourceOrderNative(ThroughTsv, CapsOnly, BoundMode := "") {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _HotstringsOverrides, HotstringGroupConfig, HSE_RegistryByGroup, _HotstringBoundSources
	Reference := JsonParse(FileRead(_HsCacheTestSharedDir()
		. "\tests\corpus\hotstrings\source_order_entries.json", "UTF-8"))
	Root := A_Temp . "\ergopti-source-order-" . A_TickCount . "-" . Random(100000, 999999)
	DirCreate(Root)
	Path := Root . "\autocorrection.toml", Tsv := Root . "\cache.tsv", BoundPath := Root . "\bound.toml"
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED,
		_GENERATED_HOTSTRINGS, _HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources]
	try {
		NativeSource := _HsCacheNativeSourceOrderText()
		_HsCacheAssertNativeSourceOrderInput(NativeSource, Reference["source_order"])
		FileAppend(NativeSource, Path, "UTF-8")
		_HS_CACHE_ROWS := _HotstringsCacheBuildRows(Map("autocorrection", Path))
		for Section, ExpectedCount in Reference["counts"] {
			Key := "autocorrection." . Section
			Assert(_HS_CACHE_ROWS.Has(Key), "every fixture section must reach the real cache parser")
			AssertEqual(ExpectedCount, _HS_CACHE_ROWS[Key].Length)
		}
		AssertEqual(Reference["source_order"].Length, _HS_CACHE_ROWS.SourceOrder.Length)
		if ThroughTsv {
			_HotstringsCacheWriteTsv(Tsv, _HS_CACHE_ROWS)
			_HS_CACHE_ROWS := _HotstringsCacheReadTsv(FileRead(Tsv, "UTF-8"))
			Assert(_HS_CACHE_ROWS.SourceOrderVersion, "a grouped legacy cache cannot qualify physical order")
		}
		_HS_CACHE_LOADED := true
		_GENERATED_HOTSTRINGS := Map()
		_HotstringsOverrides := Map(), HotstringGroupConfig := Map()
		HotstringsResolveBumpGen()
		Sections := Map("caps", Map("enabled", true))
		if !CapsOnly {
			Sections["terms"] := Map("enabled", true)
			Sections["abbreviations"] := Map("enabled", true)
		}
		Sections["unknown"] := Map("enabled", false)
		_HotstringBoundSources := Map()
		if BoundMode != "" {
			if BoundMode == "bound" {
				BoundSource := _HsCacheNativeSourceOrderText(true)
				_HsCacheAssertNativeSourceOrderInput(BoundSource, Reference["bound_caps_order"])
				FileAppend(BoundSource, BoundPath, "UTF-8")
			}
			_HotstringBoundSources["autocorrection"] := Map("path", "", "sections", Map("caps", BoundPath))
		}
		HSE_TestReset()
		if !CapsOnly && BoundMode == "" {
			; The retained native section owner is the causal grouped-order control.
			for Key, _Rows in _HS_CACHE_ROWS
				_GENERATED_HOTSTRINGS[Key] := _HsCacheRegisterSection.Bind(Key)
			for Section in Reference["sections"] {
				if Sections.Has(Section) && Sections[Section].Get("enabled", false)
					LoadHotstringsSection("autocorrection", Section, Sections[Section])
			}
			Legacy := [], LegacyBySequence := Map()
			for _Key, Entries in HSE_RegistryByGroup
				for Spec in Entries
					LegacyBySequence[Spec.Seq] := Spec.Trigger
			loop LegacyBySequence.Count
				Legacy.Push(LegacyBySequence[A_Index])
			Assert(_HsCacheRowsEqual(Legacy, Reference["declared_order"]),
				"the original real section loader demonstrates grouped insertion order")
			Assert(!_HsCacheRowsEqual(Legacy, Reference["admitted_source_order"]),
				"the fixture distinguishes grouped insertion from the intended physical sequence")
			HSE_TestReset()
		}
		LoadHotstringsCategory("autocorrection", Sections, Map("IsPrivate", true))
		Wanted := BoundMode == "missing" ? []
			: BoundMode == "bound" ? Reference["bound_caps_order"]
			: Reference[CapsOnly ? "caps_order" : "admitted_source_order"]
		BySequence := Map()
		for Key, Entries in HSE_RegistryByGroup {
			for Spec in Entries {
				BySequence[Spec.Seq] := Spec.Trigger
				AssertEqual(true, Spec.IsPrivate, "native caller extras survive ordered cache registration")
				Assert(Key != "autocorrection.unknown", "disabled unknown sections do not become registered")
				if Spec.Trigger == "secondx" {
					AssertEqual(44, Spec.Priority)
					AssertEqual(true, Spec.CaseSensitive)
				} else if Spec.Trigger == "firstx" {
					AssertEqual(10, Spec.Priority)
					AssertEqual(true, Spec.FinalResult)
				}
			}
		}
		AssertEqual(Wanted.Length, BySequence.Count)
		for Index, Trigger in Wanted
			AssertEqual(Trigger, BySequence[Index], "cross-section Seq must reflect original physical source order")
	} finally {
		HSE_TestReset()
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _HotstringsOverrides := Saved[5]
		HotstringGroupConfig := Saved[6], _HotstringBoundSources := Saved[7]
		HotstringsResolveBumpGen()
		if FileExist(BoundPath)
			FileDelete(BoundPath)
		if FileExist(Path)
			FileDelete(Path)
		if FileExist(Tsv)
			FileDelete(Tsv)
		DirDelete(Root)
	}
}

Test("common autocorrection: actual ordered native loader preserves interleaved sections (source-ordered-autocorrection)",
	_HsCacheSourceOrderNative.Bind(false, false))
Test("common autocorrection: TSV round-trip preserves interleaved sections and native options (source-ordered-autocorrection)",
	_HsCacheSourceOrderNative.Bind(true, false))
Test("common autocorrection: ordered native loader retains the actual caps-only admission (source-ordered-autocorrection)",
	_HsCacheSourceOrderNative.Bind(true, true))

Test("common autocorrection: the actual ordered category loader preserves all 140 historical registrations (common-autocorrection-reference)",
	_HsCacheCommonReferenceNative.Bind(true, true))

_HsCacheReadTsvPacket(Packet) {
	return _HotstringsCacheReadTsv(Packet)
}

_HsCacheSourceOrderHeaderRefusals() {
	Row := "autocorrection`tcaps`t`tfirstx`tFirst`t0`t0`t1`t`n"
	for Prefix in ["", "# source-order-v0`n", "# source-order-v1", "# source-order-v1`r`n",
		"# SOURCE-ORDER-V1`n", "# Source-Order-v1`n"]
		AssertThrows(_HsCacheReadTsvPacket.Bind(Prefix . Row),
			"missing, wrong or truncated header cannot admit an unqualified grouped cache")
	AssertThrows(() => _HotstringsCacheReadTsv("# source-order-v1`n" . Row . "truncated`trow`n"),
		"a malformed tail invalidates the whole cache instead of returning an admitted prefix")
	AssertThrows(() => _HotstringsCacheReadTsv("# source-order-v1`n" . Row . "# source-order-v1`n"),
		"a second header cannot hide a concatenated or partial cache")
	Accepted := _HotstringsCacheReadTsv("# source-order-v1`n" . Row)
	AssertEqual(1, Accepted.SourceOrder.Length)
	AssertEqual("firstx", Accepted.SourceOrder[1][2][2])
}
Test("hotstrings cache: exact source-order header and complete records are required (source-ordered-autocorrection)",
	_HsCacheSourceOrderHeaderRefusals)

Test("common autocorrection: ordered consumer preserves actual bound caps owner (source-ordered-autocorrection)",
	_HsCacheSourceOrderNative.Bind(true, true, "bound"))
Test("common autocorrection: missing bound caps owner cannot use bundled cached rows (source-ordered-autocorrection)",
	_HsCacheSourceOrderNative.Bind(true, true, "missing"))

; The reviewed editorial map, independently authored before the source split.
_HsCacheCommonAssignment() {
	Classification := JsonParse(FileRead(_HsCacheTestSharedDir()
		. "\data\hotstrings\common_autocorrection_sections.json", "UTF-8"))
	Assignment := Map()
	for Section in Classification["sections"]
		for Trigger in Section["triggers"] {
			AssertFalse(Assignment.Has(Trigger), "each independent trigger has one current section")
			Assignment[Trigger] := Section["id"]
		}
	return Assignment
}

; Qualify the actual shared source, typed cache and current native admission.
_HsCacheCommonSplitNative(Selection, ThroughTsv := false, ThroughRegistrar := false) {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _HotstringsOverrides, HotstringGroupConfig, HSE_RegistryByGroup, _HotstringBoundSources
	global HSE_Buffer, HSE_StartIsWordBoundary, Features
	SavedFeatures := Features
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS,
		_HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources]
	Tsv := A_Temp . "\ergopti-common-split-" . A_TickCount . "-" . Random(100000, 999999) . ".tsv"
	try {
		_SharedDir := _HsCacheTestSharedDir()
		Reference := _HsCacheCommonReference(), Assignment := _HsCacheCommonAssignment()
		_HS_CACHE_ROWS := _HotstringsCacheBuildRows()
		if ThroughTsv {
			_HotstringsCacheWriteTsv(Tsv, _HS_CACHE_ROWS)
			_HS_CACHE_ROWS := _HotstringsCacheReadTsv(FileRead(Tsv, "UTF-8"))
		}
		ExpectedCounts := Map("names", 34, "abbreviations", 95, "technical_terms", 11)
		for Section, Count in ExpectedCounts
			AssertEqual(Count, _HS_CACHE_ROWS["autocorrection." . Section].Length)
		AssertFalse(_HS_CACHE_ROWS.Has("autocorrection.caps"), "the shipped source has three independent section identities")
		_HS_CACHE_LOADED := true, _GENERATED_HOTSTRINGS := Map()
		_HotstringsOverrides := Map(), HotstringGroupConfig := Map(), _HotstringBoundSources := Map()
		HotstringsResolveBumpGen()
		Sections := Map()
		for Section in ["names", "abbreviations", "technical_terms"]
			Sections[Section] := Map("enabled", Selection == "all" || Selection == Section)
		HSE_TestReset()
		if ThroughRegistrar {
			French := Map()
			for Section in ["typographic_apostrophe", "errors", "ou", "multiple_punctuation_marks",
				"suffixes_a_chaining", "minus", "minus_apostrophe", "names", "accents"]
				French[Section] := Map("enabled", false)
			Features := Map("hotstrings", Map("autocorrection", Sections, "french_autocorrection", French))
			_HS_RegisterAutocorrection()
		} else
			LoadHotstringsCategory("autocorrection", Sections)
		Selected := []
		for Key, Specs in HSE_RegistryByGroup
			for Spec in Specs {
				if ThroughRegistrar && !RegExMatch(Key, "^autocorrection\.(names|abbreviations|technical_terms)$")
					continue
				Selected.Push(Spec)
			}
		; The rules in insertion order, ranked 1..N without their no-break variants.
		Observed := Map(), RegisteredCount := 0
		for Spec in _HsCacheSortBySeq(_HsCacheWithoutSpaceVariants(Selected)) {
			RegisteredCount += 1
			Observed[RegisteredCount] := Spec
		}
		AssertEqual(Selection == "all" ? 140 : ExpectedCounts[Selection], RegisteredCount)
		Index := 0
		for Row in Reference["entries"] {
			Section := Assignment[Row["trigger"]]
			if Selection != "all" && Selection != Section
				continue
			Index += 1
			AssertTrue(Observed.Has(Index), "the registration owner assigns every historical subset sequence")
			Actual := Observed[Index]
			Assert(Actual.Trigger == Row["trigger"], "each selection keeps historical relative order")
			Assert(Actual.Replacement == Row["output"], "the independent output remains unchanged")
			AssertEqual(Row["is_word"], Actual.IsWord)
			AssertEqual(Row["auto_expand"], Actual.Auto)
			AssertEqual(Row["final_result"], Actual.FinalResult)
			AssertEqual(false, Actual.CaseSensitive)
			AssertEqual(Reference["source_priority"], Actual.Priority)
			; Each family waits the delay its manifest row declares, not the
			; historical file's 1.0 s (the maintainer's decision of 3 November 2026).
			AssertEqual(ManifestValueFor("hotstrings.autocorrection." . Section . ".time_activation_seconds", "default"),
				Actual.TimeActivationSeconds)
			AssertTrue(HSE_RegistryByGroup.Has("autocorrection." . Section), "the current section owns its native registrations")
		}
		for ExpansionCase in [
			{ Section: "names", Trigger: "chatgpt", Output: "ChatGPT" },
			{ Section: "abbreviations", Trigger: "api", Output: "API" },
			{ Section: "technical_terms", Trigger: "adaboost", Output: "AdaBoost" }] {
			HSE_Buffer := ExpansionCase.Trigger . " ", HSE_StartIsWordBoundary := true
			Match := HSE_FindMatchAtEnd(" ")
			if Selection == "all" || Selection == ExpansionCase.Section {
				AssertTrue(Match is Object, "the real matcher executes the selected section")
				Assert(Match.Replacement == ExpansionCase.Output, "actual native matching keeps the independent typed result")
			} else
				AssertFalse(Match is Object, "the real matcher cannot execute another selection")
		}
		for Section in Sections
			Sections[Section]["enabled"] := false
		HSE_TestReset()
		if ThroughRegistrar
			_HS_RegisterAutocorrection()
		else
			LoadHotstringsCategory("autocorrection", Sections)
		AssertEqual(0, HSE_RegistryByGroup.Count, "disabled current sections publish no owned mappings")
	} finally {
		if FileExist(Tsv)
			FileDelete(Tsv)
		HSE_TestReset()
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _HotstringsOverrides := Saved[5]
		HotstringGroupConfig := Saved[6], _HotstringBoundSources := Saved[7]
		Features := SavedFeatures
		HotstringsResolveBumpGen()
	}
}
for _hsSplit_Selection in ["all", "names", "abbreviations", "technical_terms"] {
	Test("common source split: native selection " . _hsSplit_Selection . " (common-autocorrection-split)",
		_HsCacheCommonSplitNative.Bind(_hsSplit_Selection, false))
	Test("common source split: TSV selection " . _hsSplit_Selection . " (common-autocorrection-split)",
		_HsCacheCommonSplitNative.Bind(_hsSplit_Selection, true))
}

for _hsSplit_Selection in ["all", "names", "abbreviations", "technical_terms"]
	Test("common source split: actual native boot registrar " . _hsSplit_Selection . " (common-autocorrection-split)",
		_HsCacheCommonSplitNative.Bind(_hsSplit_Selection, false, true))






; ===================================================
; ===================================================
; ======= 4/ Shared source custody regression =======
; ===================================================
; ===================================================

TestHsCache_SharedSourceCustody() {
	global _SharedDir
	SavedShared := _SharedDir
	State := _LoggerPrivacyState(), SavedPolicy := [State["config"], State["root"]]
	try {
		State["config"] := 0, State["root"] := ""
		Policy := _LoggerPrivacyConfig()
		AssertTrue(Policy is Map, "The real canonical logger policy is admitted before cache work")
		for Callback in [TestHsCache_BuildExtractsKnownEntry, TestHsCache_BuildCoversEveryBundledCategory, TestHsCache_TsvRoundTripIsLossless] {
			Callback.Call()
			AssertTrue(_SharedDir == SavedShared, "Each cache callback restores the exact inherited shared source")
			AssertTrue(_LoggerPrivacyConfig() == Policy, "Cache work preserves the actual admitted logger policy owner")
		}
	} finally {
		_SharedDir := SavedShared
		State["config"] := SavedPolicy[1], State["root"] := SavedPolicy[2]
	}
}
Test("hotstrings cache: callbacks preserve the admitted shared logger source", TestHsCache_SharedSourceCustody)

; Canonical cache source-inventory regressions.
; Production sources only. The test controls physical files and cold-load module
; state, never replaces the cache parser, writer, freshness owner or registrar.
_HSCI_Source(Trigger, Output) {
	return '[[names]]`n"' . Trigger . '" = { output = "' . Output . '", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true }`n'
}

_HSCI_ContainsNative(Trigger) {
	global HSE_RegistryByGroup
	for Key, Entries in HSE_RegistryByGroup
		for Spec in Entries
			if Spec.Trigger == Trigger
				return true
	return false
}

_HSCI_CurrentOwner(Mode) {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources
	global _TomlFileCache, _TomlFileSectionCounts, _TomlCountCache
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS,
		_HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources,
		_TomlFileCache, _TomlFileSectionCounts, _TomlCountCache]
	Root := A_Temp . "\ergopti_cache_inventory_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	try {
		DirCreate(Root . "\modules\hotstrings")
		Index := Root . "\modules\hotstrings\_index.toml"
		FileCopy(_HsCacheTestSharedDir() . "\modules\hotstrings\_index.toml", Index)
		_SharedDir := Root
		; Retain original memo contents independently; fixture reads still enter
		; the genuine ReadTomlFile owner and generate their own native receipts.
		_TomlFileCache := _TomlFileCache.Clone()
		_TomlFileSectionCounts := _TomlFileSectionCounts.Clone()
		_TomlCountCache := _TomlCountCache.Clone()
		_HotstringsOverrides := Map(), HotstringGroupConfig := Map(), _HotstringBoundSources := Map()
		HotstringsResolveBumpGen()
		Paths := []
		for Category in HotstringsBundledCategories() {
			Path := _HotstringsCacheTomlPath(Category)
			SplitPath(Path, , &Parent)
			DirCreate(Parent)
			if Category == "autocorrection"
				AssertTrue(FSWriteCreateDurable(Path, Mode == "unbound-extension"
					? _HSCI_Source("newcacheprobe", "New") : _HSCI_Source("oldcacheprobe", "Old")))
			else
				AssertTrue(FSWriteCreateDurable(Path, "# genuine empty declared source`n"))
			Paths.Push(Path)
			FileSetTime("20000101000000", Path, "M")
		}
		FileSetTime("20000101000000", Index, "M")
		AssertTrue(_TomlFileCache.Has(Index), "the ordinary canonical index read must really populate its memo")
		Source := _HotstringsCacheTomlPath("autocorrection")
		Tsv := _HotstringsCacheTsvPath()
		if Mode == "unbound-extension" {
			ExtensionRoot := Root . "\extensions"
			PackDir := ExtensionRoot . "\cacheprobe"
			DirCreate(PackDir . "\hotstrings")
			Manifest := '[extension]`nid = "cacheprobe"`nname = "Cache Probe"`nversion = "1.0.0"`n'
				. '[extension.hotstring_bindings.words]`ncategory = "autocorrection"`nfeature_section = "hotstrings.autocorrection"`nsource = "common"`n'
			AssertTrue(FSWriteCreateDurable(PackDir . "\manifest.toml", Manifest))
			BoundPath := PackDir . "\hotstrings\words.toml"
			AssertTrue(FSWriteCreateDurable(BoundPath, _HSCI_Source("oldcacheprobe", "Old")))
			FileSetTime("20000101000000", BoundPath, "M")
			; These are the genuine scanner and route producer used by Prepare.
			; No binding receipt is manufactured by the fixture.
			Packs := HotstringExtensions_Scan([ExtensionRoot])
			AssertEqual(1, Packs.Length)
			_HotstringBoundSources := HotstringExtensions_RouteBound(Packs)
			AssertEqual(BoundPath, HotstringsBoundTomlPath("autocorrection"))
		}
		if Mode == "edited-during-build" {
			; These are the exact production build and publish owners used by
			; Ensure. The ordinary edit occupies their interruptible boundary.
			Rows := _HotstringsCacheBuildRows()
			AssertEqual("oldcacheprobe", Rows["autocorrection.names"][1][2])
			AssertTrue(FSWriteDurable(Source, _HSCI_Source("newcacheprobe", "New")))
			FileSetTime("20000102000000", Source, "M")
			_HotstringsCacheWriteTsv(Tsv, Rows)
		} else {
			; First load follows the entire real Ensure production pipeline.
			_HS_CACHE_ROWS := Map(), _HS_CACHE_LOADED := false, _GENERATED_HOTSTRINGS := Map()
			HotstringsCacheEnsure()
			AssertTrue(_HS_CACHE_ROWS.Has("autocorrection.names"))
			if Mode != "unbound-extension"
				AssertEqual("oldcacheprobe", _HS_CACHE_ROWS["autocorrection.names"][1][2])
			if Mode == "deleted-source"
				FileDelete(Source)
			else if Mode == "unbound-extension" {
				DirDelete(PackDir, true)
				Packs := HotstringExtensions_Scan([ExtensionRoot])
				AssertEqual(0, Packs.Length)
				_HotstringBoundSources := HotstringExtensions_RouteBound(Packs)
				AssertEqual("", HotstringsBoundTomlPath("autocorrection"))
			}
		}
		AssertTrue(FileExist(Tsv) != "", "the real durable cache writer must have published a cache")
		; Model an ordinary completed publication in a later clock second.
		; No sleep or scheduler timing is used as evidence.
		FileSetTime("20000103000000", Tsv, "M")
		Fresh := _HotstringsCacheIsFresh(Tsv)
		; Cold-load state is isolated exactly as on initial boot. This is an
		; in-process production reload test, not a claim of OS-process restart.
		_HS_CACHE_ROWS := Map(), _HS_CACHE_LOADED := false, _GENERATED_HOTSTRINGS := Map()
		HotstringGroupConfig := Map()
		HotstringsResolveBumpGen()
		HSE_TestReset()
		LoadHotstringsCategory("autocorrection", Map("names", Map("enabled", true)), Map("IsPrivate", true))
		OldRegistered := _HSCI_ContainsNative("oldcacheprobe")
		NewRegistered := _HSCI_ContainsNative("newcacheprobe")
		DiskRows := _HotstringsCacheReadTsv(FileRead(Tsv, "UTF-8"))
		if Mode == "live" {
			AssertTrue(Fresh, "an unchanged complete source inventory retains the cache path")
			AssertTrue(OldRegistered)
			AssertFalse(NewRegistered)
		} else {
			AssertFalse(OldRegistered, "the actual production category owner must never register a removed/replaced rule")
			if Mode != "unbound-extension"
				AssertFalse(Fresh, "late TSV mtime cannot establish source-inventory identity")
			if Mode == "edited-during-build" || Mode == "unbound-extension" {
				AssertTrue(NewRegistered, "the actual rebuilt native registration must use authoritative edited content")
				AssertEqual("newcacheprobe", DiskRows["autocorrection.names"][1][2])
			} else {
				AssertFalse(NewRegistered)
				AssertFalse(DiskRows.Has("autocorrection.names"))
			}
		}
	} finally {
		HSE_TestReset()
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _HotstringsOverrides := Saved[5], HotstringGroupConfig := Saved[6]
		_HotstringBoundSources := Saved[7], _TomlFileCache := Saved[8]
		_TomlFileSectionCounts := Saved[9], _TomlCountCache := Saved[10]
		HotstringsResolveBumpGen()
		HotstringsCommonCategories()
		DirDelete(Root, true)
	}
}
for _HSCI_Mode in ["live", "deleted-source", "edited-during-build", "unbound-extension"]
	Test("hotstrings cache source inventory: " . _HSCI_Mode, _HSCI_CurrentOwner.Bind(_HSCI_Mode))

; Additional genuine INITIAL Ensure regression. A real exclusive stage handle
; makes the real writer issue its real diagnostic. The existing logger observer
; edits the authoritative input after BuildRows; neither producer is replaced.
_HSCI_EnsureWriteCallout(Mode) {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources
	global _TomlFileCache, _TomlFileSectionCounts, _TomlCountCache
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _HealthCheckWarnCount
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	AssertEqual(0, _LOGGER_TEST_SINK, "a foreign log observer cannot be detached")
	LoggerState := _TLOG_CaptureLoggerState()
	AssertFalse(LoggerState.FlushActive)
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS,
		_HotstringsOverrides, HotstringGroupConfig, _HotstringBoundSources,
		_TomlFileCache, _TomlFileSectionCounts, _TomlCountCache]
	SavedRepeat := _LOGGER_REPEAT_ENABLED, SavedDate := _LOGGER_PATH_DATE
	HadWarnings := IsSet(_HealthCheckWarnCount)
	SavedWarnings := HadWarnings ? _HealthCheckWarnCount : 0
	Root := A_Temp . "\ergopti_initial_cache_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Created := false, RegistryScope := 0
	Lock := 0, Failure := 0, PreviousCritical := A_IsCritical
	Facts := {logs: 0, critical: false, changed: false, failure: 0, ownedCalls: 0, ownedReturns: 0, collisions: []}
	OwnedWriter := FSWriteReplaceOwned, HadOwnedCall := OwnedWriter.HasOwnProp("Call"), InstalledOwned := false
	if HadOwnedCall
		SavedOwnedCall := OwnedWriter.GetOwnPropDesc("Call")
	ObserveOwned(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := (Target is String) && StrCompare(Target, Tsv, true) == 0
		CreateOriginal(Folder, Name, Attributes) {
			ForeignPath := Tsv . Suffix
			AssertEqual(1, FSWriteCreateDurable(ForeignPath, "Independent cache collision"))
			Facts.collisions.Push(ForeignPath)
			return StageFn.Call(Folder, Name, Attributes)
		}
		if Mine
			Facts.ownedCalls += 1
		Result := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			Mine ? CreateOriginal : StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if Mine
			Facts.ownedReturns += 1
		return Result
	}
	OnLog(Line) {
		if !InStr(Line, "Could not write hotstring cache", true)
			return
		Facts.logs += 1
		if Facts.logs != 1
			return
		Facts.critical := A_IsCritical
		try {
			if Mode == "index" {
				NewIndex := StrReplace(IndexImage,
					'categories_order = ["autocorrection", "magickey"]', 'categories_order = ["magickey"]', , &Replacements, 1)
				if Replacements != 1
					throw Error("the independent index fixture must remove precisely its common source")
				Facts.changed := FSWriteDurable(Index, NewIndex)
			} else
				Facts.changed := FSWriteDurable(Source, _HSCI_Source("newcacheprobe", "New"))
		} catch as Err
			Facts.failure := Err
	}
	try {
		Critical("Off")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		RegistryScope := _HotstringRegistryScope()
		DirCreate(Root . "\modules\hotstrings")
		Index := Root . "\modules\hotstrings\_index.toml"
		FileCopy(_HsCacheTestSharedDir() . "\modules\hotstrings\_index.toml", Index)
		_SharedDir := Root
		_TomlFileCache := _TomlFileCache.Clone()
		_TomlFileSectionCounts := _TomlFileSectionCounts.Clone()
		_TomlCountCache := _TomlCountCache.Clone()
		_HotstringsOverrides := Map(), HotstringGroupConfig := Map(), _HotstringBoundSources := Map()
		HotstringsResolveBumpGen()
		for Category in HotstringsBundledCategories() {
			Path := _HotstringsCacheTomlPath(Category)
			SplitPath(Path, , &Parent)
			DirCreate(Parent)
			AssertTrue(FSWriteCreateDurable(Path, Category == "autocorrection"
				? _HSCI_Source("oldcacheprobe", "Old") : "# empty canonical source`n"))
		}
		IndexImage := ReadTomlFile(Index)
		AssertEqual(FSReadStrict(Index), IndexImage, "the initial canonical memo must be the actual index A")
		Source := _HotstringsCacheTomlPath("autocorrection")
		Tsv := _HotstringsCacheTsvPath()
		AssertFalse(FileExist(Tsv), "this must exercise the first production build, not a disk cache hit")
		OwnedWriter.DefineProp("Call", {Call: ObserveOwned})
		InstalledOwned := true
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := ""
		LoggerSetTestSink(OnLog)
		_HS_CACHE_ROWS := Map(), _HS_CACHE_LOADED := false, _GENERATED_HOTSTRINGS := Map()
		HSE_TestReset()
		try LoadHotstringsCategory("autocorrection", Map("names", Map("enabled", true)), Map("IsPrivate", true))
		catch as Err
			Failure := Err
		LoggerClearTestSink()
		if Facts.failure is Error
			throw Facts.failure
		_TestPrint("# initial-cache-owned-diagnostic mode=" . Mode . " owned_calls=" . Facts.ownedCalls
			. " owned_returns=" . Facts.ownedReturns . " collisions=" . Facts.collisions.Length . " logs=" . Facts.logs)
		AssertTrue(Facts.ownedCalls >= 1)
		AssertEqual(Facts.ownedCalls, Facts.ownedReturns)
		AssertEqual(Facts.ownedCalls, Facts.collisions.Length)
		for ForeignPath in Facts.collisions
			AssertEqual("Independent cache collision", FSReadUtf8Exact(ForeignPath), "the real refused cache owner cannot retire the foreign stage")
		AssertTrue(Facts.logs >= 1, "the actual writer must really reach its post-build diagnostic")
		AssertFalse(Facts.critical, "the genuine yielding diagnostic must stay interruptible")
		AssertTrue(Facts.changed is Integer && Facts.changed == 1, "the observer must physically change its authoritative input")
		AssertFalse(_HSCI_ContainsNative("oldcacheprobe"), "initial Ensure must never publish the pre-diagnostic rule")
		AssertFalse(FileExist(Tsv), "a valid TOML load cannot depend on successful disk cache publication")
		if Mode == "category" {
			AssertFalse(Failure is Error)
			AssertTrue(_HS_CACHE_LOADED)
			AssertTrue(_HSCI_ContainsNative("newcacheprobe"), "the bounded retry must load the genuinely edited source")
			AssertEqual("newcacheprobe", _HS_CACHE_ROWS["autocorrection.names"][1][2])
		} else {
			AssertTrue(Failure is Error, "stale canonical index A cannot authorize a memory projection against actual index B")
			AssertContains(Failure.Message, "no cache projection was published")
			AssertFalse(_HS_CACHE_LOADED)
			AssertEqual(0, _HS_CACHE_ROWS.Count)
			AssertEqual(0, _GENERATED_HOTSTRINGS.Count)
			AssertEqual(IndexImage, ReadTomlFile(Index), "verification must not silently bless or replace the canonical memo A")
			AssertTrue(StrCompare(IndexImage, FSReadStrict(Index), true) != 0, "the actual disk index B must remain changed")
		}
		AssertTrue(Facts.logs <= 2, "source movement must settle or refuse within the bounded producer attempts")
	} finally {
		if InstalledOwned {
			if HadOwnedCall
				OwnedWriter.DefineProp("Call", SavedOwnedCall)
			else
				OwnedWriter.DeleteProp("Call")
		}
		LoggerClearTestSink()
		_LOGGER_REPEAT_ENABLED := SavedRepeat, _LOGGER_PATH_DATE := SavedDate
		_TLOG_RestoreLoggerState(LoggerState)
		_HealthCheckWarnCount := HadWarnings ? SavedWarnings : unset
		CloseFailure := 0
		try {
			if IsObject(Lock)
				Lock.Close()
		} catch as Err
			CloseFailure := Err
		if IsObject(RegistryScope) {
			HSE_TestReset()
			_HotstringRegistryScope(RegistryScope)
		}
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _HotstringsOverrides := Saved[5], HotstringGroupConfig := Saved[6]
		_HotstringBoundSources := Saved[7], _TomlFileCache := Saved[8]
		_TomlFileSectionCounts := Saved[9], _TomlCountCache := Saved[10]
		HotstringsResolveBumpGen()
		HotstringsCommonCategories()
		try {
			if CloseFailure is Error
				throw CloseFailure
			if Created
				DirDelete(Root, true)
		} finally Critical(PreviousCritical)
	}
}
Test("hotstrings cache initial publication: real writer diagnostic edits category", _HSCI_EnsureWriteCallout.Bind("category"))
Test("hotstrings cache initial publication: canonical memo A cannot bless actual index B", _HSCI_EnsureWriteCallout.Bind("index"))

_HCOW_PublicEnsure(Collision, TruncateStage := false) {
	global _SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS
	global _TomlFileCache, _TomlFileSectionCounts, _TomlCountCache, HS_BUNDLED_CATEGORIES, _HotstringBoundSources
	Saved := [_SharedDir, _HS_CACHE_ROWS, _HS_CACHE_LOADED, _GENERATED_HOTSTRINGS,
		_TomlFileCache, _TomlFileSectionCounts, _TomlCountCache, HS_BUNDLED_CATEGORIES, _HotstringBoundSources]
	Root := A_Temp . "\ergopti_cache_stage_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Created := false
	OwnedWriter := FSWriteReplaceOwned, HadOwnedCall := OwnedWriter.HasOwnProp("Call"), InstalledOwned := false
	if HadOwnedCall
		SavedOwnedCall := OwnedWriter.GetOwnPropDesc("Call")
	Fault := {calls: 0, handle: -1, truncated: 0, observedBytes: -1, nativeAck: -1, stagePath: ""}
	ObserveOwned(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := (Target is String) && StrCompare(Target, Tsv, true) == 0
		CreateOriginal(Folder, Name, Attributes) {
			Fault.handle := StageFn.Call(Folder, Name, Attributes)
			Fault.stagePath := Tsv . Suffix
			return Fault.handle
		}
		TruncateThenVerify() {
			_FSRewind(Fault.handle)
			Prefix := Buffer(1, 0x23)
			if !_FSNativeWrite(Fault.handle, Prefix.Ptr, 1, &Written := 0) || Written != 1
				throw Error("the genuine private stage prefix could not be written")
			if !DllCall("kernel32\SetEndOfFile", "Ptr", Fault.handle, "Int")
				throw OSError(A_LastError, "private held cache stage truncation")
			if !DllCall("kernel32\FlushFileBuffers", "Ptr", Fault.handle, "Int")
				throw OSError(A_LastError, "private truncated cache flush")
			if !DllCall("kernel32\GetFileSizeEx", "Ptr", Fault.handle, "Int64*", &Bytes := 0, "Int")
				throw OSError(A_LastError, "private truncated cache size")
			Fault.observedBytes := Bytes
			Fault.truncated += 1
			return BeforePublishFn.Call()
		}
		if Mine
			Fault.calls += 1
		Result := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			Mine ? CreateOriginal : StageFn, Mine ? TruncateThenVerify : BeforePublishFn,
			AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if Mine
			Fault.nativeAck := Result
		return Result
	}
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		DirCreate(Root . "\modules\hotstrings")
		FileCopy(_HsCacheTestSharedDir() . "\modules\hotstrings\_index.toml", Root . "\modules\hotstrings\_index.toml")
		_SharedDir := Root
		_TomlFileCache := _TomlFileCache.Clone()
		_TomlFileSectionCounts := _TomlFileSectionCounts.Clone()
		_TomlCountCache := _TomlCountCache.Clone()
		_HotstringBoundSources := Map()
		for Category in HotstringsBundledCategories() {
			Path := _HotstringsCacheTomlPath(Category)
			SplitPath(Path, , &Parent)
			DirCreate(Parent)
			AssertEqual(1, FSWriteCreateDurable(Path, Category == "autocorrection"
				? _HSCI_Source("cacheownerprobe", "Owned output") : "# genuine empty source`n"))
		}
		Tsv := _HotstringsCacheTsvPath(), Foreign := Tsv . ".tmp"
		Sentinel := "Independent cache stage é😀"
		if Collision {
			AssertEqual(1, FSWriteCreateDurable(Foreign, Sentinel))
			Before := FSReadBytesStrict(Foreign)
		}
		_HS_CACHE_ROWS := Map(), _GENERATED_HOTSTRINGS := Map(), _HS_CACHE_LOADED := false
		if TruncateStage {
			OwnedWriter.DefineProp("Call", {Call: ObserveOwned})
			InstalledOwned := true
		}
		HotstringsCacheEnsure()
		Present := FSStrictExists(Foreign), CachePresent := FSStrictExists(Tsv)
		After := Present ? FSReadBytesStrict(Foreign) : Buffer(0)
		_TestPrint("# hotstrings-cache-stage collision=" . Collision . " foreign_present=" . Present
			. " cache_present=" . CachePresent . " loaded=" . _HS_CACHE_LOADED
			. " has_rows=" . _HS_CACHE_ROWS.Has("autocorrection.names") . " foreign_bytes=" . After.Size
			. " truncated=" . Fault.truncated . " observed_stage_bytes=" . Fault.observedBytes . " native_ack=" . Fault.nativeAck)
		AssertTrue(_HS_CACHE_LOADED, "valid TOML remains loadable even if the best-effort cache cannot publish")
		AssertEqual("cacheownerprobe", _HS_CACHE_ROWS["autocorrection.names"][1][2])
		AssertEqual("Owned output", _HS_CACHE_ROWS["autocorrection.names"][1][3])
		if Collision {
			AssertTrue(Present, "public Ensure cannot consume an independently created cache stage")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "foreign cache bytes remain exact")
		} else if TruncateStage {
			AssertEqual(1, Fault.calls)
			AssertEqual(1, Fault.truncated, "the actual owned native stage must be physically truncated after its first flush")
			AssertEqual(1, Fault.observedBytes)
			AssertEqual(0, Fault.nativeAck, "the genuine helper must refuse the corrupt held stage")
			AssertFalse(CachePresent, "a complete-looking prefix cannot receive a reusable cache publication")
			AssertFalse(FSStrictExists(Fault.stagePath), "only the owned rejected stage is retired")
		} else {
			AssertTrue(CachePresent, "the default native writer still produces a reusable verified cache")
			Disk := _HotstringsCacheReadTsv(FSReadUtf8Exact(Tsv))
			AssertTrue(_HotstringsCacheInventoryMatches(Disk))
			AssertEqual("cacheownerprobe", Disk["autocorrection.names"][1][2])
		}
	} finally {
		if InstalledOwned {
			if HadOwnedCall
				OwnedWriter.DefineProp("Call", SavedOwnedCall)
			else
				OwnedWriter.DeleteProp("Call")
		}
		_SharedDir := Saved[1], _HS_CACHE_ROWS := Saved[2], _HS_CACHE_LOADED := Saved[3]
		_GENERATED_HOTSTRINGS := Saved[4], _TomlFileCache := Saved[5]
		_TomlFileSectionCounts := Saved[6], _TomlCountCache := Saved[7]
		HS_BUNDLED_CATEGORIES := Saved[8], _HotstringBoundSources := Saved[9]
		if Created
			DirDelete(Root, true)
	}
}
for _HCOW_Collision in [true, false]
	Test("hotstrings cache stage: public Ensure collision=" . _HCOW_Collision
		. " (hotstrings-cache-stage-ownership)", _HCOW_PublicEnsure.Bind(_HCOW_Collision))

; HSE-003 registers a no-break and a narrow no-break variant beside each trigger
; with an inner space. The historical reference counts rules, so a variant whose
; space form is registered too is set aside; the rules keep their own order.
; @param Specs {Array} Registered specs.
; @returns {Array} The specs without their no-break space variants.
_HsCacheWithoutSpaceVariants(Specs) {
	Triggers := Map()
	for Spec in Specs
		Triggers[Spec.Trigger] := true
	Kept := []
	for Spec in Specs {
		Spaced := StrReplace(StrReplace(Spec.Trigger, Chr(0xA0), " "), Chr(0x202F), " ")
		if (Spaced != Spec.Trigger) && Triggers.Has(Spaced)
			continue
		Kept.Push(Spec)
	}
	return Kept
}

; @param Specs {Array} Registered specs.
; @returns {Array} The same specs by ascending insertion sequence.
_HsCacheSortBySeq(Specs) {
	Sorted := []
	for Spec in Specs {
		Position := Sorted.Length + 1
		while Position > 1 && Sorted[Position - 1].Seq > Spec.Seq
			Position -= 1
		Sorted.InsertAt(Position, Spec)
	}
	return Sorted
}
