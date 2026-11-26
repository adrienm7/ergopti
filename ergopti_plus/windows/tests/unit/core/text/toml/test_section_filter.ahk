; tests/unit/core/text/toml/test_section_filter.ahk

; ==============================================================================
; MODULE: Section-Filtered Flat TOML Parse Tests
; DESCRIPTION:
; Personal-file metadata reads only [_meta] tables, so its parse skips decoding
; every other section. Each kept section must hold exactly what a full parse
; gives it, including after multi-line arrays the skipped sections open.
; ==============================================================================

#Requires AutoHotkey v2.0

; A typed value as text, so two parses compare entry by entry.
_TSF_Dump(Value) {
	if Value is TOML_Bool
		return "bool:" . Value.Value
	if Value is Array {
		Text := "["
		for Item in Value
			Text .= _TSF_Dump(Item) . ","
		return Text . "]"
	}
	if Value is Map {
		Text := "{"
		for Key, Item in Value
			Text .= Key . "=" . _TSF_Dump(Item) . ","
		return Text . "}"
	}
	return Type(Value) . ":" . Value
}

_TSF_Source() {
	Q := Chr(34)
	return "[_meta]`ndescription = " . Q . "Personal" . Q . "`ndelay = 0.5`n"
		. "sections_order = [" . Q . "code" . Q . ", " . Q . "mail" . Q . "]`n"
		. "[_meta.sections.code]`ncolor = " . Q . "#112233" . Q . "`nshow_tooltip = false`n"
		. "[[code]]`n" . Q . "abc" . Q . " = { output = " . Q . "x" . Q . ", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`n"
		. "multi = [`n  " . Q . "a" . Q . ",`n  " . Q . "]" . Q . ",`n]`n"
		. "[[mail]]`nopen = [`n  " . Q . "lost" . Q . ",`n"
		. "[_meta.sections.mail]`npriority = 40`n"
		. "[_meta.sections." . Q . "a.b" . Q . "] # tail`ncolor = " . Q . "#778899" . Q . " # tail`n"
		. "[_META.sections.Upper]`ncolor = " . Q . "#445566" . Q . "`n"
		. "[[code]]`n" . Q . "def" . Q . " = " . Q . "plain" . Q . "`n"
}

_TSF_KeptSectionsMatchAFullParse() {
	Content := _TSF_Source()
	Full := _ParseTomlFileImpl("personal_filter_probe.toml", false, false, Content, true, &FullDiscarded)
	Filtered := _ParseTomlFileImpl("personal_filter_probe.toml", false, false, Content, true, &FilteredDiscarded,
		_PersonalFileMetadataHeader)
	AssertEqual(FullDiscarded, FilteredDiscarded, "the skipped sections keep the line state of a full parse")
	Kept := 0
	for Header, Fields in Full {
		if !_PersonalFileMetadataHeader(Header)
			continue
		Kept += 1
		AssertTrue(Filtered.Has(Header), "kept section [" . Header . "] is present")
		AssertEqual(_TSF_Dump(Fields), _TSF_Dump(Filtered[Header]), "kept section [" . Header . "] is unchanged")
	}
	AssertEqual(5, Kept, "every metadata table of the fixture is kept, the unterminated array's recovery included")
	for Header, Fields in Filtered {
		if !_PersonalFileMetadataHeader(Header)
			AssertEqual(0, Fields.Count, "skipped section [" . Header . "] decodes no value")
	}
}
Test("TOML: a section-filtered parse keeps every kept section of a full parse (personal-metadata-filter-2026-11-03)",
	_TSF_KeptSectionsMatchAFullParse)

_TSF_MetadataReadIsUnchanged() {
	Owner := { path: "personal_filter_probe.toml" }
	Config := PersonalFileAdoptedOwner.Prototype.ReadMetadata.Call(Owner, _TSF_Source())
	AssertEqual(0.5, Config.Delay)
	AssertEqual("#112233", Config.Sections["code"].Color)
	AssertEqual(false, Config.Sections["code"].ShowTooltip)
	AssertEqual(40, Config.Sections["mail"].Priority)
	AssertEqual("#778899", Config.Sections["a.b"].Color, "a quoted dotted name stays one section")
	AssertEqual("#445566", Config.Sections["upper"].Color, "a header spelled in capitals is metadata, as before")
}
Test("TOML: personal metadata reads only its own tables with the same result (personal-metadata-filter-2026-11-03)",
	_TSF_MetadataReadIsUnchanged)

_TSF_FilteredParseRefusesTheCache() {
	AssertThrows(() => _ParseTomlFileImpl("personal_filter_probe.toml", true, false, _TSF_Source(), false, ,
		_PersonalFileMetadataHeader), "a partial parse must never be served or stored as the file's parse")
}
Test("TOML: a section-filtered parse never uses the reader cache (personal-metadata-filter-2026-11-03)",
	_TSF_FilteredParseRefusesTheCache)
