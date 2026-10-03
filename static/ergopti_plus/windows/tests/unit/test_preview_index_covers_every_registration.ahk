; static/ergopti_plus/windows/tests/unit/test_preview_index_covers_every_registration.ahk

; ==============================================================================
; MODULE: Regression — extension packs are previewable
;         (preview-index-covers-every-registration)
; DESCRIPTION:
; Drop mypack.toml next to personal_hotstrings.toml, restart, type its trigger
; and pause: no tooltip, ever. Type the terminator and the engine expands it
; perfectly. The hotstring worked; only the preview was blind to it.
;
; ROOT CAUSE ENCODED: the preview index and the engine had two different sources
; of truth for the same question. The engine enumerated REGISTRATIONS — the six
; bundled categories plus every other *.toml under PersonalHotstringsDir, walked
; recursively. The preview enumerated FILES, from a hardcoded six-element list
; whose "personal" entry resolved to one single path. Every registration that did
; not come from those six files was therefore invisible to the tooltip by
; construction, which is why no amount of hardening inside the index build would
; have found it.
;
; There was no error path to notice: LoadExtTomlFile logs a successful load with
; its entry count, so the logs positively assert the pack is live. The user reads
; it as "tooltips work for the built-in hotstrings but not for mine" — a design
; choice rather than a gap. The config window even exposes a per-pack tooltip
; colour, a user-visible setting with nothing behind it.
;
; The fix gives both sides ONE enumeration, so they cannot drift apart again.
;
; SCOPE: behavioural for the enumeration and the indexer, over a temp directory;
; structural for the two call sites, because a full rebuild needs the live
; InputHook this runner does not arm.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Temp extension-pack fixture ==
; =========================================
; =========================================

; A pack in the generator's exact on-disk shape, one trigger, one sub-folder pack
; so the hierarchical label is covered too.
_PICR_MakeFixture() {
	Root := A_Temp . "\ergopti_picr_" . A_TickCount
	DirCreate(Root)
	DirCreate(Root . "\work")
	; The root personal file must be SKIPPED — it is its own category, not a pack.
	FileAppend('[[meta]]`nname = "personal"`n', Root . "\personal_hotstrings.toml", "UTF-8")
	FileAppend(
		'[[snippets]]`n"zqx" = { output = "expansion", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n',
		Root . "\mypack.toml", "UTF-8")
	FileAppend(
		'[[notes]]`n"wfh" = { output = "work from home", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n',
		Root . "\work\team.toml", "UTF-8")
	; The OTHER two shapes LoadExtTomlFile accepts, which the preview indexer used
	; to drop on the floor: a SINGLE-bracket header, and a bare key = "value"
	; entry. The [_meta] block is here because accepting single brackets means the
	; metadata skip has to become explicit — its description must never index as a
	; trigger.
	FileAppend(
		'[_meta]`ndescription = "not a hotstring"`n'
		. '[snippets]`n"sbx" = { output = "single bracket", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n'
		. 'simplekey = "simple value"`n'
		. 'escapedoutput = "say \"hi\""`n'
		. '"escaped\"trigger" = "value"`n',
		Root . "\otherpack.toml", "UTF-8")
	return Root
}

_PICR_Cleanup(Root) {
	try DirDelete(Root, true)
}





; =========================================
; =========================================
; ======= 2/ The enumeration ==============
; =========================================
; =========================================

_PICR_EnumerationFindsPacksAndSkipsTheRootFile() {
	global ScriptInformation
	Root := _PICR_MakeFixture()
	Saved := ScriptInformation.Has("PersonalHotstringsDir") ? ScriptInformation["PersonalHotstringsDir"] : ""
	ScriptInformation["PersonalHotstringsDir"] := Root
	try {
		Labels := Map()
		for _, Pack in HS_EnumeratePersonalExtFiles()
			Labels[Pack["Label"]] := Pack["Path"]

		Assert(Labels.Has("mypack"),
			"a *.toml sitting next to personal_hotstrings.toml is an extension pack and must be enumerated — this is the file the engine registers and the preview could never see")
		Assert(Labels.Has("work / team"),
			"a pack inside a sub-folder must be enumerated with its hierarchical label, matching the label the engine registers it under")
		Assert(!Labels.Has("personal_hotstrings"),
			"the root personal_hotstrings.toml is its own category and must NOT be enumerated as a pack, or every personal trigger would be indexed twice under two different category labels")
	} finally {
		if (Saved != "")
			ScriptInformation["PersonalHotstringsDir"] := Saved
		_PICR_Cleanup(Root)
	}
}





; =========================================
; =========================================
; ======= 3/ The indexer ==================
; =========================================
; =========================================

_PICR_PackTriggersReachTheIndex() {
	global ScriptInformation
	Root := _PICR_MakeFixture()
	Saved := ScriptInformation.Has("PersonalHotstringsDir") ? ScriptInformation["PersonalHotstringsDir"] : ""
	ScriptInformation["PersonalHotstringsDir"] := Root
	try {
		Index := Map()
		Set := Map()
		Count := _RegisterExtPackTriggers(Root . "\mypack.toml", "mypack", Index, Set)

		Assert(Count >= 1,
			"the pack's single entry must be indexed. Returning zero means the preview still cannot see a hotstring the engine expands")
		Assert(Set.Has("zqx"),
			"the pack's trigger must land in the trigger set — that set is what the watcher consults to decide whether a tooltip is possible at all")
	} finally {
		if (Saved != "")
			ScriptInformation["PersonalHotstringsDir"] := Saved
		_PICR_Cleanup(Root)
	}
}

; ROOT CAUSE of the second half of this defect: the two sides were unified on the
; FILE SET but not on the GRAMMAR. LoadExtTomlFile accepts one-or-more-bracket
; headers AND bare `key = "value"` entries; the preview indexer accepted double
; brackets and inline tables only, resetting its section on anything else. A pack
; written in either of the other two shapes expanded and could never be previewed
; — the same user-visible symptom, through a different mechanism, with the same
; positively-successful log line.
_PICR_EveryAcceptedShapeIsIndexed() {
	global ScriptInformation, HSE_PRIORITY_PACKAGE
	Root := _PICR_MakeFixture()
	Saved := ScriptInformation.Has("PersonalHotstringsDir") ? ScriptInformation["PersonalHotstringsDir"] : ""
	ScriptInformation["PersonalHotstringsDir"] := Root
	try {
		Index := Map()
		Set := Map()
		_RegisterExtPackTriggers(Root . "\otherpack.toml", "otherpack", Index, Set)

		Assert(Set.Has("sbx"),
			"an entry under a SINGLE-bracket [section] header must be indexed: LoadExtTomlFile's header pattern "
			. "accepts one or more brackets, so it registers and expands the hotstring. Accepting only [[section]] "
			. "here made the pack expand while never being previewable "
			. "(preview-index-grammar-stricter-than-engine)")
		Assert(Set.Has("simplekey"),
			'a bare key = "value" entry must be indexed: LoadExtTomlFile registers that shape through '
			. 'CreateCaseSensitiveHotstrings, so it expands. Matching only the inline-table pattern here left it '
			. 'un-previewable (preview-index-grammar-stricter-than-engine)')
		Assert(Set.Has("escapedoutput"),
			"a simple entry with an escaped quote in its output must be indexed")
		Assert(Index.Has("escapedoutput")
			and Index["escapedoutput"] is Array
			and Index["escapedoutput"].Length >= 1,
			"the escaped-output trigger must have an indexed preview row")
		AssertEqual('say "hi"', Index["escapedoutput"][1].Output,
			"the preview must receive the same unescaped output as the engine")
		Assert(Set.Has('escaped"trigger'),
			"a quoted simple trigger must be parsed and unescaped before indexing")
		; The preview ranks colliding candidates by Priority so the non-dimmed row
		; is the one the engine will fire. LoadExtTomlFile registers every ext-pack
		; entry at HSE_PRIORITY_PACKAGE, while the index's own fallback is
		; HSE_PRIORITY_COMMON — reached here because a pack's Category is its LABEL,
		; which HotstringsResolve knows nothing about. A pack trigger colliding with
		; a bundled one therefore previewed as the LOSER and fired as the winner.
		Assert(Set.Has("sbx") and IsObject(Set["sbx"]),
			"prerequisite: the pack entry must be in the trigger set to inspect its rank")
		AssertEqual(HSE_PRIORITY_PACKAGE, Set["sbx"].Priority,
			"an extension-pack preview must be ranked at the priority the ENGINE fires it at. Ranking it at the "
			. "common default makes the tooltip name one expansion while the engine performs another whenever a "
			. "pack trigger collides with a bundled one — preview-without-fire, the visible lie "
			. "(ext-pack-preview-ranked-below-its-fire)")
		Assert(!Set.Has("description"),
			"a [_meta] key must NOT be indexed as a trigger. The old single-bracket RESET stood in for the metadata "
			. "skip by accident, so accepting single brackets requires the skip to be explicit — otherwise the "
			. "pack's own description becomes an expandable hotstring")
	} finally {
		if (Saved != "")
			ScriptInformation["PersonalHotstringsDir"] := Saved
		_PICR_Cleanup(Root)
	}
}

; An extension pack has no per-section toggle in the menu — the engine enables
; every section of it. Gating the preview on a Features node that cannot exist
; would index nothing and silently restore the original defect.
_PICR_PackIndexingIsNotGatedOnPerSectionFeatures() {
	Body := _DriverFuncBody("_RegisterExtPackTriggers")
	Assert(Body != "", "_RegisterExtPackTriggers() must exist in the driver source")

	Assert(InStr(Body, 'Features["hotstrings"]') == 0,
		"_RegisterExtPackTriggers must not consult a per-section Features node. Packs have no per-section toggle, so such a lookup always misses and the pack silently drops out of the index again")
	Assert(InStr(Body, "IsCategoryGated(") > 0,
		"_RegisterExtPackTriggers must still honour the master hotstrings gate — that gate really can silence a pack, and ignoring it would preview hotstrings that cannot fire")
}





; ==========================================
; ==========================================
; ======= 4/ One walk, two consumers =======
; ==========================================
; ==========================================

; The guarantee that keeps this fixed: both sides read the same enumeration.
_PICR_BothSidesShareOneEnumeration() {
	Rebuild := _DriverFuncBody("HotstringPrefixWatcherRebuildIndex")
	Assert(Rebuild != "", "HotstringPrefixWatcherRebuildIndex() must exist in the driver source")
	Assert(InStr(Rebuild, "HS_EnumeratePersonalExtFiles(") > 0,
		"the index rebuild must enumerate the extension packs. Without it the index covers only the six bundled categories and every pack expands with no tooltip — the defect this test exists for")

	Register := _DriverFuncBody("_HS_RegisterPersonal")
	Assert(Register != "", "_HS_RegisterPersonal() must exist in the driver source")
	Assert(InStr(Register, "HS_EnumeratePersonalExtFiles(") > 0,
		"the engine registration must walk the packs through the SAME enumeration as the index. Two independent walks is exactly how the two sides came to disagree, and a private copy here would let them drift apart again")
}

Test("preview index: extension packs are enumerated, the root personal file is not (preview-index-covers-every-registration)",
	_PICR_EnumerationFindsPacksAndSkipsTheRootFile)
Test("preview index: an extension pack's triggers reach the index (preview-index-covers-every-registration)",
	_PICR_PackTriggersReachTheIndex)
Test("preview index: every entry shape the engine registers is also indexed (preview-index-grammar-stricter-than-engine)",
	_PICR_EveryAcceptedShapeIsIndexed)
Test("preview index: pack indexing is not gated on a per-section Features node (preview-index-covers-every-registration)",
	_PICR_PackIndexingIsNotGatedOnPerSectionFeatures)
Test("preview index: the engine and the index share one pack enumeration (preview-index-covers-every-registration)",
	_PICR_BothSidesShareOneEnumeration)


; The live pack and its preview must identify the same parsed source without
; accidentally adopting bundled-category activation gates from that label.
_PICR_LivePersonalProvenanceMatchesPreview(Label) {
	global ScriptInformation, _HotstringRegistrar, HSE_RegistryByGroup, HSE_SeqCounter, CategoryEnabled
	Root := A_Temp . "\ergopti_picr_provenance_" . A_TickCount
	DirCreate(Root)
	DirCreate(Root . "\Équipe")
	Path := Label == "rolls" ? Root . "\rolls.toml" : Root . "\Équipe\mémoire.toml"
	SavedRegistrar := _HotstringRegistrar
	HadDirectory := ScriptInformation.Has("PersonalHotstringsDir")
	SavedDirectory := ScriptInformation.Get("PersonalHotstringsDir", "")
	HadMaster := CategoryEnabled.Has("Hotstrings")
	SavedMaster := CategoryEnabled.Get("Hotstrings", false)
	try {
		FileAppend('[_meta]`ndescription = "not a trigger"`n'
			. '[Fallback]`npsx = "simple"`n'
			. '"plx" = { output = "Literal", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true, is_case_sensitive_strict = true, priority = 81 }`n'
			. '[[Other]]`n"pcx★" = { output = "Owned conform", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
			. '"pex" = { output = "Explicit", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = false }`n', Path, "UTF-8")
		; Native enumeration expands short directory aliases. Obtain the expected
		; identity independently from Win32 before observing the catalogue owner.
		CanonicalPaths := []
		for SourcePath in [Root, Path] {
			CanonicalBuffer := Buffer(32768 * 2, 0)
			CanonicalLength := DllCall("GetLongPathNameW", "Str", SourcePath,
				"Ptr", CanonicalBuffer, "UInt", 32768, "UInt")
			AssertTrue(CanonicalLength > 0 && CanonicalLength < 32768,
				"Win32 must resolve the existing fixture without truncation")
			CanonicalPaths.Push(StrGet(CanonicalBuffer, CanonicalLength, "UTF-16"))
		}
		ScriptInformation["PersonalHotstringsDir"] := Root
		Packs := HS_EnumeratePersonalExtFiles()
		AssertEqual(1, Packs.Length, "the actual recursive owner enumerates exactly this personal source")
		AssertEqual(CanonicalPaths[2], Packs[1]["Path"])
		AssertEqual(Label, Packs[1]["Label"], "the source label comes from the authoritative enumerator")
		ScriptInformation["PersonalHotstringsDir"] := CanonicalPaths[1]
		CanonicalPacks := HS_EnumeratePersonalExtFiles()
		AssertEqual(1, CanonicalPacks.Length, "both native root spellings identify exactly one source")
		AssertEqual(CanonicalPaths[2], CanonicalPacks[1]["Path"])
		AssertEqual(Label, CanonicalPacks[1]["Label"], "root aliases preserve the hierarchical Unicode label")
		ScriptInformation["PersonalHotstringsDir"] := Root
		CategoryEnabled["Hotstrings"] := true
		_HotstringRegistrar := 0
		HSE_RegistryClear()
		AssertEqual(4, LoadExtTomlFile(Packs[1]["Path"], Packs[1]["Label"], "", Packs[1]["PersonalSource"]), "metadata is excluded from both entry shapes")
		AssertEqual(1, HSE_RegistryByGroup.Count, "source metadata must preserve whole-file activation ownership")
		AssertTrue(HSE_RegistryByGroup.Has("default"))
		Specs := HSE_RegistryByGroup["default"]
		AssertEqual(8, Specs.Length, "simple and inline case families retain their original registration counts")
		ActualPersonalBinding := Map("source", Specs[1].PersonalSource, "owner", Specs[1].Group, "path", Packs[1]["Path"])
		ActualPersonalEvidence := [Map("source", Specs[1].PersonalSource, "owner", Specs[1].Group, "path", Packs[1]["Path"],
			"admitted", true, "exclusive", false)]
		AssertEqual("default", ActualPersonalBinding["owner"], "the registered owner remains the historical shared default")
		RefusedPersonalBinding := PersonalScopeAdmit(ActualPersonalEvidence, ActualPersonalBinding, &PersonalBindingRefusal)
		AssertFalse(RefusedPersonalBinding, "actual additional-file registration grants no exclusive file gate")
		AssertEqual("unavailable-owner", PersonalBindingRefusal)
		AssertEqual(8, HSE_RegistryByGroup["default"].Length, "admission never mutates live specs or activation")
		ExpectedTriggers := ["psx", "PSX", "Psx", "plx", "pcx" . ScriptInformation["MagicKey"], "pex", "PEX", "Pex"]
		ExpectedOutputs := ["simple", "SIMPLE", "Simple", "Literal", "owned conform", "explicit", "EXPLICIT", "Explicit"]
		Index := Map()
		Set := Map()
		AssertEqual(4, _RegisterExtPackTriggers(Path, Label, Index, Set, "", Packs[1]["PersonalSource"]))
		PreviewRows := Map()
		PreviewRows.CaseSense := "On"
		for _, Bucket in Index {
			for Row in Bucket {
				AssertFalse(PreviewRows.Has(Row.Trigger), "the preview never duplicates a case variant")
				PreviewRows[Row.Trigger] := Row
			}
		}
		AssertEqual(10, PreviewRows.Count, "the conform family previews each of its three accepted cases")
		for Position, OwnedSpec in Specs {
			AssertEqual(ExpectedTriggers[Position], OwnedSpec.Trigger, "historical factory registration order is unchanged")
			AssertEqual(ExpectedOutputs[Position], OwnedSpec.Replacement)
			AssertEqual(Label, OwnedSpec.Category, "live metadata retains the actual hierarchical personal-file label")
			AssertEqual(Position <= 4 ? "fallback" : "other", OwnedSpec.Section, "the parser's section supplies provenance even without a declaration")
			AssertEqual("default", OwnedSpec.Group)
			AssertEqual(Position, OwnedSpec.Seq)
			AssertEqual(0, OwnedSpec.TimeActivationSeconds)
			AssertEqual(Position == 4 ? 81 : 30, OwnedSpec.Priority)
			AssertTrue(PreviewRows.Has(OwnedSpec.Trigger), "every actual live spec has an exact preview row")
			Preview := PreviewRows[OwnedSpec.Trigger]
			AssertEqual(OwnedSpec.Category, Preview.Category)
			AssertEqual(OwnedSpec.Section, Preview.Section)
			AssertTrue(OwnedSpec.HasOwnProp("PersonalSource"), "native factory variant " . Position . " must retain admitted personal provenance")
			AssertEqual(Packs[1]["PersonalSource"]["id"], OwnedSpec.PersonalSource["id"], "the actual live spec retains discovery identity")
			AssertEqual(OwnedSpec.PersonalSource["id"], Preview.PersonalSource["id"], "the real preview row retains the same source")
			Assert(OwnedSpec.PersonalSource != Preview.PersonalSource, "live and preview never share mutable provenance")
			Assert(OwnedSpec.PersonalSource != Packs[1]["PersonalSource"], "each registered variant owns its discovery descriptor snapshot")
			AssertEqual(OwnedSpec.Priority, Preview.Priority)
			AssertEqual(OwnedSpec.Replacement, Preview.Output)
		}
		Packs[1]["PersonalSource"]["components"][1] := "changed.toml"
		for OwnedSpec in Specs
			AssertTrue(PersonalFileDescriptorValid(OwnedSpec.PersonalSource), "mutating discovery never corrupts any simple or inline registered variant")
		AssertTrue(Specs[4].Star && Specs[4].CaseSensitive && Specs[4].FinalResult)
		AssertFalse(Specs[4].InWord)
		AssertTrue(Specs[5].Star && Specs[5].InWord && Specs[5].CaseConform)
		AssertFalse(Specs[5].FinalResult)
		HSE_DisableGroup(Label . ".fallback")
		HSE_DisableGroup(Label . ".other")
		HSE_FeedReset(true)
		for Char in StrSplit("plx")
			Match := HSE_FeedChar(Char, true)
		AssertTrue(Match == Specs[4], "unrelated derived-section gates cannot silence a whole-file pack")
		HSE_DisableGroup("default")
		HSE_FeedReset(true)
		for Char in StrSplit("plx")
			Match := HSE_FeedChar(Char, true)
		AssertEqual("", Match, "the retained default owner still disables the native mapping")
		HSE_EnableGroup("default")
		HSE_EnableGroup("default")
		HSE_FeedReset(true)
		for Char in StrSplit("plx")
			Match := HSE_FeedChar(Char, true)
		AssertTrue(Match == Specs[4], "reactivation restores the exact original native spec")
		AssertEqual(7, HSE_MappingsForTail("X").Length, "restoring the default group never duplicates end-character or literal specs")
		AssertEqual(1, HSE_MappingsForTail(ScriptInformation["MagicKey"]).Length, "the conform spec retains its exact live identity")
		AssertEqual(8, HSE_SeqCounter, "toggle operations neither duplicate nor re-register personal entries")
	} finally {
		_HotstringRegistrar := SavedRegistrar
		if HadDirectory
			ScriptInformation["PersonalHotstringsDir"] := SavedDirectory
		else
			ScriptInformation.Delete("PersonalHotstringsDir")
		if HadMaster
			CategoryEnabled["Hotstrings"] := SavedMaster
		else
			CategoryEnabled.Delete("Hotstrings")
		HSE_RegistryClear()
		HSE_FeedReset(true)
		DirDelete(Root, true)
	}
}
Test("personal pack provenance: nested Unicode labels and parsed sections match real preview rows", (*) => _PICR_LivePersonalProvenanceMatchesPreview("Équipe / mémoire"))
Test("personal pack provenance: bundled-label collisions preserve whole-file activation ownership", (*) => _PICR_LivePersonalProvenanceMatchesPreview("rolls"))


_PICR_DescriptorCorpus() {
	global _SharedDir
	DescriptorCorpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\personal_file_descriptors.json", "UTF-8"))
	AssertEqual(13, DescriptorCorpus["vectors"].Length, "the independent cross-driver goldens must be complete")
	SeenDescriptors := Map()
	SeenDescriptors.CaseSense := "On"
	for AuthorityVector in DescriptorCorpus["vectors"] {
		OwnedDescriptor := PersonalFileDescribe(AuthorityVector["components"])
		Assert(OwnedDescriptor["id"] == AuthorityVector["id"], AuthorityVector["name"])
		Assert(OwnedDescriptor["label"] == AuthorityVector["label"], AuthorityVector["name"])
		AssertFalse(SeenDescriptors.Has(OwnedDescriptor["id"]), "every admitted filename has a distinct identity")
		SeenDescriptors[OwnedDescriptor["id"]] := true
		AssertFalse(InStr(OwnedDescriptor["id"], "."), "the identity stays one canonical TOML path segment")
		DecodedComponents := PersonalFileComponents(AuthorityVector["id"])
		AssertTrue(DecodedComponents is Array)
		AssertEqual(AuthorityVector["components"].Length, DecodedComponents.Length)
		for Position, NativeComponent in DecodedComponents
			Assert(NativeComponent == AuthorityVector["components"][Position], "native UTF-8 roundtrip preserves exact components")
		CopiedDescriptor := PersonalFileDescriptorCopy(OwnedDescriptor)
		OwnedDescriptor["components"][1] := "mutated.toml"
		AssertTrue(PersonalFileDescriptorValid(CopiedDescriptor))
		AssertFalse(PersonalFileDescriptorValid(OwnedDescriptor), "forged components refuse")
		CopiedDescriptor["label"] := "forged"
		AssertFalse(PersonalFileDescriptorValid(CopiedDescriptor), "forged label refuses")
	}
	for InvalidComponents in DescriptorCorpus["invalid_components"] {
		AdmittedComponents := true
		try PersonalFileDescribe(InvalidComponents)
		catch {
			AdmittedComponents := false
		}
		AssertFalse(AdmittedComponents, "malformed relative components refuse")
	}
	for InvalidIdentity in DescriptorCorpus["invalid_ids"]
		AssertEqual(0, PersonalFileComponents(InvalidIdentity), "noncanonical or malformed UTF-8 identity refuses")
	ExtraDescriptor := PersonalFileDescribe(["a.toml"])
	ExtraDescriptor["future"] := true
	AssertFalse(PersonalFileDescriptorValid(ExtraDescriptor), "unknown fields cannot silently cross the source boundary")
	NumericLabel := PersonalFileDescribe(["123.toml"])
	NumericLabel["label"] := 123
	AssertFalse(PersonalFileDescriptorValid(NumericLabel), "native comparison cannot coerce a numeric label into text")
	AssertFalse(PersonalFileDescriptorValid(Map("ID", "personal-file:612e746f6d6c", "components", ["a.toml"], "label", "a")), "descriptor fields retain exact shared spelling")
}
Test("personal-file descriptors: independent exact UTF-8 identity corpus", _PICR_DescriptorCorpus)


_PICR_DistinctDiscoveredSources(RootSpelling := "temp") {
	global ScriptInformation
	OwnedRoot := A_Temp . "\ergopti_picr_sources_" . A_TickCount
	SourceFiles := Map("a__b.toml", "personal-file:615f5f622e746f6d6c",
		"a\b.toml", "personal-file:61:622e746f6d6c",
		"words.old.toml", "personal-file:776f7264732e6f6c642e746f6d6c",
		"work\team.toml", "personal-file:776f726b:7465616d2e746f6d6c",
		"home\team.toml", "personal-file:686f6d65:7465616d2e746f6d6c",
		"Équipe\mémoire.toml", "personal-file:c3897175697065:6dc3a96d6f6972652e746f6d6c",
		"rolls.toml", "personal-file:726f6c6c732e746f6d6c", ".toml", "personal-file:2e746f6d6c")
	HadRoot := ScriptInformation.Has("PersonalHotstringsDir")
	PriorRoot := ScriptInformation.Get("PersonalHotstringsDir", "")
	try {
		for Directory in ["", "a", "work", "home", "Équipe"]
			DirCreate(OwnedRoot . "\" . Directory)
		for RelativeFile in SourceFiles
			FileAppend('[probe]`n"pqx" = "Owned"`n', OwnedRoot . "\" . RelativeFile, "UTF-8")
		FileAppend('[probe]`n"pqx" = "Canonical"`n', OwnedRoot . "\personal_hotstrings.toml", "UTF-8")
		; Resolve the oracle through Win32, independently of the catalogue owner.
		NativeBuffer := Buffer(32768 * 2, 0)
		NativeLength := DllCall("GetLongPathNameW", "Str", OwnedRoot, "Ptr", NativeBuffer, "UInt", 32768, "UInt")
		AssertTrue(NativeLength > 0 && NativeLength < 32768, "Win32 resolves the owned existing root without truncation")
		LongRoot := StrGet(NativeBuffer, NativeLength, "UTF-16")
		InputRoot := RootSpelling == "long" ? LongRoot : OwnedRoot
		ScriptInformation["PersonalHotstringsDir"] := InputRoot
		Packs := HS_EnumeratePersonalExtFiles()
		AssertEqual(8, Packs.Length, "neither colliding labels, repeated basenames nor the historical empty stem may disappear from actual discovery")
		SeenSources := Map()
		for Pack in Packs {
			Assert(SubStr(Pack["Path"], 1, StrLen(LongRoot) + 1) == LongRoot . "\", "the canonical discovered file must remain inside the exact owned native root")
			RelativeFile := SubStr(Pack["Path"], StrLen(LongRoot) + 2)
			AssertTrue(SourceFiles.Has(RelativeFile), "only actual fixture-owned source paths are admitted")
			AssertTrue(PersonalFileDescriptorValid(Pack["PersonalSource"]))
			AssertEqual(SourceFiles[RelativeFile], Pack["PersonalSource"]["id"])
			AssertFalse(SeenSources.Has(Pack["PersonalSource"]["id"]), "each exact relative file has its own descriptor")
			SeenSources[Pack["PersonalSource"]["id"]] := true
		}
		AssertEqual(8, SeenSources.Count)
	} finally {
		if HadRoot
			ScriptInformation["PersonalHotstringsDir"] := PriorRoot
		else if ScriptInformation.Has("PersonalHotstringsDir")
			ScriptInformation.Delete("PersonalHotstringsDir")
		try DirDelete(OwnedRoot, true)
	}
}
Test("personal-file descriptors: recursive native discovery retains distinct exact paths", _PICR_DistinctDiscoveredSources)
Test("personal-file descriptors: recursive native discovery admits the exact long root", (*) => _PICR_DistinctDiscoveredSources("long"))

#Include %A_LineFile%\..\..\..\..\_shared\modules\hotstrings\personal_scope.ahk

; A TOML header comment cannot create or erase known-trigger analytics rows.
_PICR_CommentedHeaderCatalogue(Kind, Mode, Brackets := 2) {
	global Features, ScriptInformation, CategoryEnabled
	ProcessId := ProcessExist()
	Root := A_Temp . "\ergopti_picr_header_" . ProcessId . "_" . A_TickCount
	Path := Root . "\owned.toml"
	AssertFalse(DirExist(Root), "the fixture refuses a pre-existing temporary root")
	DirCreate(Root)
	Open := Brackets == 1 ? "[" : "[["
	Close := Brackets == 1 ? "]" : "]]"
	Inline := '"cmtb" = { output = "second#value", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`n'
	Content := Open . "first" . Close . (Mode == "first" ? " # first section" : "") . '`n"cmta" = { output = "first#value", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`n'
	if Mode == "second" || Mode == "selected"
		Content .= Open . "second" . Close . " # selected section`n" . Inline
	else if Mode == "metadata"
		Content .= Open . "_meta.sections" . Close . ' # metadata`ndescription = "not a trigger"`n'
	HadMaster := CategoryEnabled.Has("Hotstrings")
	PriorMaster := CategoryEnabled.Get("Hotstrings", false)
	HadPersonal := Features["hotstrings"].Has("personal")
	PriorPersonal := Features["hotstrings"].Get("personal", 0)
	HadPath := ScriptInformation.Has("PersonalTomlPath")
	PriorPath := ScriptInformation.Get("PersonalTomlPath", "")
	try {
		CategoryEnabled["Hotstrings"] := true
		Features["hotstrings"]["personal"] := Map("first", Map("enabled", true), "second", Map("enabled", true))
		ScriptInformation["PersonalTomlPath"] := Path
		FileAppend(Content, Path, "UTF-8")
		_ParseTomlGroupConfig_InvalidatePath(Path)
		Index := Map(), TriggerSet := Map()
		if Kind == "category"
			Count := _RegisterCategoryTriggers("personal", Index, TriggerSet)
		else
			Count := _RegisterExtPackTriggers(Path, "owned", Index, TriggerSet, Mode == "selected" ? "second" : "")
		ExpectedCount := Mode == "second" ? 2 : 1
		AssertEqual(ExpectedCount, Count, "only source hotstring rows enter the analytics catalogue")
		if Mode != "selected" {
			AssertTrue(TriggerSet.Has("cmta"), "the first declared source row remains a known trigger")
			AssertEqual("first", TriggerSet["cmta"].Section, "commented headers retain exact section ownership")
			AssertEqual("first#value", TriggerSet["cmta"].Output, "a hash inside output remains source text")
		}
		if Mode == "second" || Mode == "selected" {
			AssertTrue(TriggerSet.Has("cmtb"), "a later commented section cannot disappear or inherit its predecessor")
			AssertEqual("second", TriggerSet["cmtb"].Section, "the second declared section owns its row")
			AssertEqual("second#value", TriggerSet["cmtb"].Output)
		}
		if Mode == "selected"
			AssertFalse(TriggerSet.Has("cmta"), "selection still excludes another declared section")
		AssertFalse(TriggerSet.Has("description"), "commented metadata can never become a known trigger")
	} finally {
		try _ParseTomlGroupConfig_InvalidatePath(Path)
		finally {
			if HadMaster
				CategoryEnabled["Hotstrings"] := PriorMaster
			else
				CategoryEnabled.Delete("Hotstrings")
			if HadPersonal
				Features["hotstrings"]["personal"] := PriorPersonal
			else
				Features["hotstrings"].Delete("personal")
			if HadPath
				ScriptInformation["PersonalTomlPath"] := PriorPath
			else
				ScriptInformation.Delete("PersonalTomlPath")
			Assert(InStr(Root, RTrim(A_Temp, "\/") . "\ergopti_picr_header_" . ProcessId . "_") == 1, "cleanup stays inside this process-owned temporary root")
			DirDelete(Root, true)
		}
	}
}
Test("catalogue: commented initial personal header retains analytics rows (catalogue-header-comments)", (*) => _PICR_CommentedHeaderCatalogue("category", "first"))
Test("catalogue: commented later personal header retains analytics rows (catalogue-header-comments)", (*) => _PICR_CommentedHeaderCatalogue("category", "second"))
for _PICR_HeaderBrackets in [1, 2] {
	Test("catalogue: commented initial extension header " . _PICR_HeaderBrackets . " retains analytics rows (catalogue-header-comments)", _PICR_CommentedHeaderCatalogue.Bind("extension", "first", _PICR_HeaderBrackets))
	Test("catalogue: commented later extension header " . _PICR_HeaderBrackets . " retains exact ownership (catalogue-header-comments)", _PICR_CommentedHeaderCatalogue.Bind("extension", "second", _PICR_HeaderBrackets))
	Test("catalogue: commented selected extension header " . _PICR_HeaderBrackets . " retains analytics rows (catalogue-header-comments)", _PICR_CommentedHeaderCatalogue.Bind("extension", "selected", _PICR_HeaderBrackets))
	Test("catalogue: commented metadata header " . _PICR_HeaderBrackets . " cannot become a trigger (catalogue-header-comments)", _PICR_CommentedHeaderCatalogue.Bind("extension", "metadata", _PICR_HeaderBrackets))
}
