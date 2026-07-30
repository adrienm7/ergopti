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
		. 'simplekey = "simple value"`n',
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
