; tests/unit/hotstrings/engine/personal/test_toml_roundtrip.ahk

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





; =========================================================
; =========================================================
; ======= 4/ Editor rows load and fire from disk =========
; =========================================================
; =========================================================

; Field report on 1.0.9: a personal hotstring typing `(){left}` could not be
; created, nor `()` alone. The editor wrote a letters-only trigger as a bare TOML
; key (`par = { ... }`) and every Windows loader pattern admitted quoted keys only,
; so the section loader skipped the row: it never fired after a section toggle,
; a new-section save or a restart. These tests go through the real writer and the
; real section loader, then type the trigger.

global _PTIO_LoadBursts := []

_PTIO_LoadRecord(Keys) {
	global _PTIO_LoadBursts
	_PTIO_LoadBursts.Push(Keys)
	return 1
}

_PTIO_PersoSource(Rows) {
	Q := Chr(34)
	return "[_meta]`ndescription = " . Q . "Perso" . Q . "`n"
		. "sections_order = [" . Q . "perso" . Q . "]`n`n"
		. "[_meta.sections]`nperso = " . Q . "Perso" . Q . "`n`n"
		. "[[perso]]`n" . Rows
}

; Loads the [[perso]] section of Path the way boot and every live rebuild do,
; types Typed and returns the bursts it sent.
_PTIO_LoadAndType(Path, Typed) {
	global _PTIO_LoadBursts, _AHK_SendInput
	_PersonalTomlInvalidateCaches(Path)
	_AHK_SendInput := _PTIO_LoadRecord
	_PTIO_LoadBursts := []
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	LoadHotstringsSection("personal", "perso", { TimeActivationSeconds: 0 })
	_HCA_Type(Typed)
	return _PTIO_LoadBursts
}

_PTIO_EditorRowFiresFromDiskImpl() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_editor_row_load_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		FileAppend(_PTIO_PersoSource(""), TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		; The exact save payload of the shared editor page, decoded as the bridge does.
		Payload := JsonParse('{"sections_order":["perso"],"sections":{"perso":{"description":"Perso",'
			. '"entries":[{"trigger":"par","output":"(){Left}","is_word":true,"auto_expand":true,'
			. '"is_case_sensitive":false,"final_result":false,"is_case_sensitive_strict":false}]}}}')
		AssertTrue(WritePersonalToml(Map("meta_description", "Perso",
			"sections_order", Payload["sections_order"], "sections", Payload["sections"])),
			"the editor save of a letters-only trigger must be written")
		AssertTrue(InStr(FileRead(TargetPath, "UTF-8"), '"par" = { output = "(){Left}"') > 0,
			"the writer quotes the trigger key, as the macOS and Linux writers do")
		Bursts := _PTIO_LoadAndType(TargetPath, "par")
		AssertEqual(1, Bursts.Length, "the saved personal hotstring must load from disk and fire")
		AssertEqual("{BackSpace 3}(){Left}", Bursts.Length ? Bursts[1] : "",
			"it types the parentheses and presses Left between them")
	} finally {
		try FileDelete(TargetPath)
		try _PersonalTomlInvalidateCaches(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-row-loads: a saved letters-only trigger fires from disk (personal-paren-left)",
	() => _HCA_Run(1, _PTIO_EditorRowFiresFromDiskImpl))

; Files 1.0.9 already wrote keep their bare rows until the row is edited again.
_PTIO_BareRowFiresFromDiskImpl() {
	global ScriptInformation
	TargetPath := A_Temp . "\ergopti_personal_bare_row_load_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	try {
		try FileDelete(TargetPath)
		FileAppend(_PTIO_PersoSource('par = { output = "()", is_word = true, auto_expand = true,'
			. ' is_case_sensitive = false, final_result = false }`n'), TargetPath, "UTF-8")
		OldPath := ScriptInformation["PersonalTomlPath"]
		ScriptInformation["PersonalTomlPath"] := TargetPath
		try Bursts := _PTIO_LoadAndType(TargetPath, "par")
		finally ScriptInformation["PersonalTomlPath"] := OldPath
		AssertEqual(1, Bursts.Length, "a bare TOML key is a trigger like a quoted one")
		AssertEqual("{BackSpace 3}{Text}()", Bursts.Length ? Bursts[1] : "",
			"and its output is typed")
		Line := 'par = { output = "()", is_word = true, auto_expand = true, is_case_sensitive = false, final_result = false }'
		AssertTrue(RegExMatch(Line, HS_PREFIX_ENTRY_PATTERN, &M) > 0,
			"the preview index reads the same bare row")
		AssertEqual("par", M[1], "and keeps the trigger as group 1")
	} finally {
		try FileDelete(TargetPath)
		try _PersonalTomlInvalidateCaches(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
	}
}
Test("personal-editor-row-loads: a bare trigger key on disk fires (personal-paren-left)",
	() => _HCA_Run(1, _PTIO_BareRowFiresFromDiskImpl))

; The shared editor page names the strict flag is_case_sensitive_strict, as the
; TOML and the macOS and Linux models do. The Windows model called it
; strict_case, so a box ticked in the WebView editor was dropped on save.
_PTIO_WebViewStrictFlagSurvivesSave() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_strict_flag_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		FileAppend(_PTIO_PersoSource(""), TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		Payload := JsonParse('{"sections_order":["perso"],"sections":{"perso":{"description":"Perso",'
			. '"entries":[{"trigger":"sru","output":"SRU","is_word":true,"auto_expand":false,'
			. '"is_case_sensitive":true,"final_result":false,"is_case_sensitive_strict":true}]}}}')
		AssertTrue(WritePersonalToml(Map("meta_description", "Perso",
			"sections_order", Payload["sections_order"], "sections", Payload["sections"])),
			"the editor save of a strict entry must be written")
		AssertTrue(InStr(FileRead(TargetPath, "UTF-8"), "is_case_sensitive_strict = true") > 0,
			"the strict flag the page sent reaches the file")
		_ReadPersonalTomlCache := false
		Entry := ReadPersonalToml(true)["sections"]["perso"]["entries"][1]
		AssertEqual(true, Entry.Get("is_case_sensitive_strict", false) ? true : false,
			"and the model reads it back under the same name")
	} finally {
		try FileDelete(TargetPath)
		try _PersonalTomlInvalidateCaches(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-editor-strict-flag: the WebView strict flag survives a save (personal-strict-name)",
	_PTIO_WebViewStrictFlagSurvivesSave)
