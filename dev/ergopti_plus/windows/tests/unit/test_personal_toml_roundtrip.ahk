; tests/unit/test_personal_toml_roundtrip.ahk

; ==============================================================================
; MODULE: Personal TOML Round-Trip Tests
; DESCRIPTION: Preserve metadata and canonical ordering across complete rewrites.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 3/ Metadata-preserving round trips =========
; =====================================================
; =====================================================

; The personal editor persists the complete model returned by ReadPersonalToml.
; If that model omits a known [_meta] or [_meta.sections.<name>] override, the
; otherwise-successful full rewrite silently deletes configuration owned by the
; hotstring config window. Exercise the public read/write pair against the real
; configured path and verify the resulting file semantically through the normal
; group-config parser, while also proving that the hotstring payload survives.
_PTIO_ReadWritePreservesKnownMetadataOverrides() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\\ergopti_personal_meta_roundtrip_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	Q := Chr(34)
	Content := "[_meta]`n"
		. "description = " . Q . "Metadata round-trip" . Q . "`n"
		. "sections_order = [" . Q . "alpha" . Q . "]`n"
		. "delay = 0.61`n"
		. "color = " . Q . "#112233" . Q . "`n"
		. "priority = 41`n"
		. "show_tooltip = false`n"
		. "`n[_meta.sections.alpha]`n"
		. "delay = 0.17`n"
		. "color = " . Q . "#AABBCC" . Q . "`n"
		. "priority = 73`n"
		. "show_tooltip = true`n"
		. "`n[[alpha]]`n"
		. Q . "zz" . Q . " = { output = " . Q . "KEPT" . Q
		. ", is_word = false, auto_expand = true"
		. ", is_case_sensitive = false, final_result = false }`n"
	try {
		try FileDelete(TargetPath)
		FileAppend(Content, TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false

		Model := ReadPersonalToml()
		AssertTrue(WritePersonalToml(Model),
			"the full-model personal TOML rewrite must succeed")

		Config := ParseTomlGroupConfig("", TargetPath)
		AssertEqual(0.61, Config.Delay,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] delay")
		AssertEqual("#112233", Config.Color,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] color")
		AssertEqual(41, Config.Priority,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] priority")
		AssertEqual(false, Config.ShowTooltip,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] show_tooltip=false")
		SectionConfig := Config.Sections.Get("alpha",
			{ Delay: "", Color: "", Priority: "", ShowTooltip: "" })
		AssertEqual(0.17, SectionConfig.Delay,
			"the rewrite must preserve [_meta.sections.alpha] delay")
		AssertEqual("#AABBCC", SectionConfig.Color,
			"the rewrite must preserve [_meta.sections.alpha] color")
		AssertEqual(73, SectionConfig.Priority,
			"the rewrite must preserve [_meta.sections.alpha] priority")
		AssertEqual(true, SectionConfig.ShowTooltip,
			"the rewrite must preserve [_meta.sections.alpha] show_tooltip=true")

		_ReadPersonalTomlCache := false
		RoundTripped := ReadPersonalToml()
		EntrySignature := ""
		if RoundTripped["sections"].Has("alpha")
			&& RoundTripped["sections"]["alpha"]["entries"].Length == 1 {
			Entry := RoundTripped["sections"]["alpha"]["entries"][1]
			EntrySignature := Entry["trigger"] . "=>" . Entry["output"]
		}
		AssertEqual("zz=>KEPT", EntrySignature,
			"the existing hotstring entry must remain intact through the same rewrite")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-meta-roundtrip: known overrides and entries survive a full rewrite",
	_PTIO_ReadWritePreservesKnownMetadataOverrides)

_PTIO_DuplicateOrderToml() {
	Q := Chr(34)
	return "[_meta]`n"
		. "description = " . Q . "Duplicate order" . Q . "`n"
		. "sections_order = [" . Q . "alpha" . Q . ", "
		. Q . "ALPHA" . Q . ", " . Q . "alpha" . Q . "]`n"
		. "`n[_meta.sections]`n"
		. "alpha = " . Q . "Alpha" . Q . "`n"
		. "`n[[alpha]]`n"
		. Q . "once" . Q . " = { output = " . Q . "ONE" . Q
		. ", is_word = false, auto_expand = true"
		. ", is_case_sensitive = false, final_result = false }`n"
}

_PTIO_DuplicateMetaOrderParsesOneCanonicalSection() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_duplicate_order_read_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		FileAppend(_PTIO_DuplicateOrderToml(), TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false

		Model := ReadPersonalToml()
		AssertEqual(1, Model["sections_order"].Length,
			"duplicate and case-equivalent metadata names must collapse at parse time")
		AssertEqual("alpha", Model["sections_order"][1])
		AssertEqual(1, Model["sections"].Count,
			"one extant section must have one canonical order position")
		AssertEqual(1, Model["sections"]["alpha"]["entries"].Length,
			"metadata duplication must not duplicate the section payload")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-order-dedup: duplicate metadata parses one canonical section",
	_PTIO_DuplicateMetaOrderParsesOneCanonicalSection)

_PTIO_DuplicateCandidateOrderStaysCanonicalAcrossTwoCycles() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_duplicate_order_write_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		Candidate := _PTIO_RaceModel("once")
		Candidate["sections_order"] := ["race", "RACE", "race"]

		AssertTrue(WritePersonalToml(Candidate),
			"the writer must accept and canonicalize duplicate order metadata")
		FirstCycle := ReadPersonalToml()
		AssertEqual(1, FirstCycle["sections_order"].Length)
		AssertEqual(1, FirstCycle["sections"]["race"]["entries"].Length,
			"the first write must emit the section and its entry exactly once")

		AssertTrue(WritePersonalToml(FirstCycle),
			"a second parse/write cycle must remain writable")
		SecondCycle := ReadPersonalToml()
		AssertEqual(1, SecondCycle["sections_order"].Length,
			"two cycles must not reintroduce duplicate order tokens")
		AssertEqual(1, SecondCycle["sections"]["race"]["entries"].Length,
			"two cycles must not multiply a duplicated section entry")

		Raw := FileRead(TargetPath, "UTF-8")
		BlockNeedle := "[[race]]"
		BlockCount := Floor((StrLen(Raw)
			- StrLen(StrReplace(Raw, BlockNeedle, ""))) / StrLen(BlockNeedle))
		MetaNeedle := 'race = "Race"'
		MetaCount := Floor((StrLen(Raw)
			- StrLen(StrReplace(Raw, MetaNeedle, ""))) / StrLen(MetaNeedle))
		AssertEqual(1, BlockCount,
			"the durable candidate must contain one [[race]] block")
		AssertEqual(1, MetaCount,
			"the durable candidate must contain one race description metadata row")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-order-dedup: two cycles keep one section and one entry",
	_PTIO_DuplicateCandidateOrderStaysCanonicalAcrossTwoCycles)
