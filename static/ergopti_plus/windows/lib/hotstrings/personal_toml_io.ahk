; lib/hotstrings/personal_toml_io.ahk

; ==============================================================================
; MODULE: Personal TOML I/O
; DESCRIPTION:
; Owns all file I/O for personal_hotstrings.toml and personal_info.toml.
; Provides path resolution, TOML parsing (ReadPersonalToml, ReadPersonalInfoToml),
; serialisation (WritePersonalToml, WritePersonalInfoToml), file-bootstrap
; (EnsurePersonalInfoTomlFile), output normalisation (NormaliseOutput,
; EscapeTomlValue), and live hotstring reload (ReloadPersonalSection).
; The UI layer (ui/personal_toml_editor.ahk) depends on this module for all
; disk operations; no file access is performed directly in the GUI code.
; ==============================================================================






; ===============================
; ===============================
; ======= 1/ Path helpers =======
; ===============================
; ===============================

; Return the configured path to personal_hotstrings.toml.
PersonalTomlPath() {
	global ScriptInformation
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalTomlPath") {
		return ScriptInformation["PersonalTomlPath"]
	}
	return A_ScriptDir . "\..\hotstrings\personal_hotstrings.toml"
}

; Return the configured path to personal_info.toml.
PersonalInfoTomlPath() {
	global ScriptInformation
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalInfoTomlPath") {
		return ScriptInformation["PersonalInfoTomlPath"]
	}
	return A_ScriptDir . "\..\hotstrings\personal_info.toml"
}





; ==========================================
; ==========================================
; ======= 2/ TOML read / write layer =======
; ==========================================
; ==========================================

; Escape a value for inclusion inside a TOML double-quoted string. Newlines
; and tabs are normalised to {Enter} and {Tab} tokens (rather than the TOML
; escape sequences \n / \t) so that the saved file uses a single canonical
; representation matching what NormaliseOutput emits and what the runtime
; Send treats as a key press. This guarantees the on-disk format never
; mixes raw \n with {Enter} for the same kind of payload.
EscapeTomlValue(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, '"', '\"')
	s := StrReplace(s, "`r`n", "{Enter}")
	s := StrReplace(s, "`r", "{Enter}")
	s := StrReplace(s, "`n", "{Enter}")
	s := StrReplace(s, "`t", "{Tab}")
	return s
}

; Mirrors HS normalise_output: bare CRLF/LF become {Enter}, bare tabs become
; {Tab}, and {alias} tokens are canonicalised to their proper AHK {Token}
; form. Keeping newline/tab handling here as well as in EscapeTomlValue means
; outputs read from any source (textarea, legacy TOML, paste) end up with the
; same tokenised representation before serialisation.
NormaliseOutput(s) {
	s := StrReplace(s, "`r`n", "{Enter}")
	s := StrReplace(s, "`r", "{Enter}")
	s := StrReplace(s, "`n", "{Enter}")
	s := StrReplace(s, "`t", "{Tab}")

	Aliases := Map(
		"esc", "Escape", "escape", "Escape",
		"bs", "BackSpace", "backspace", "BackSpace",
		"del", "Delete", "delete", "Delete",
		"return", "Enter", "enter", "Enter",
		"left", "Left", "right", "Right",
		"up", "Up", "down", "Down",
		"home", "Home", "end", "End",
		"tab", "Tab", "pgup", "PgUp",
		"pgdn", "PgDn", "ins", "Insert",
		"insert", "Insert", "space", "Space",
	)

	Result := ""
	i := 1
	n := StrLen(s)
	while i <= n {
		c := SubStr(s, i, 1)
		if (c == "{") {
			; Find closing brace
			j := InStr(s, "}", , i + 1)
			if j {
				Inner := SubStr(s, i + 1, j - i - 1)
				Lower := StrLower(Inner)
				if Aliases.Has(Lower) {
					Result .= "{" . Aliases[Lower] . "}"
				} else {
					; Capitalise first letter for unknown tokens
					Result .= "{" . StrUpper(SubStr(Inner, 1, 1)) . SubStr(Inner, 2) . "}"
				}
				i := j + 1
				continue
			}
		}
		Result .= c
		i++
	}
	return Result
}

global _ReadPersonalTomlCache := false

; Parse personal_hotstrings.toml into a structured object:
;   .sections_order  — Array of section names in meta order (or file order if no meta)
;   .sections        — Map(name → {description, entries[]})
;   .meta_description — string
ReadPersonalToml() {
	global _ReadPersonalTomlCache
	if (_ReadPersonalTomlCache != false)
		return _ReadPersonalTomlCache

	FilePath := PersonalTomlPath()
	Result := Map(
		"sections_order", [],
		"sections", Map(),
		"meta_description", t("editor.hotstrings.meta_desc"),
	)
	if !FileExist(FilePath) {
		_ReadPersonalTomlCache := Result
		return Result
	}

	Q := Chr(34)
	EntryPattern :=
		'i)^' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*=\s*\{\s*output\s*=\s*' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)'
		. '\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)'
		. '(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?'
		. '(?:\s*,\s*priority\s*=\s*([0-9]+))?\s*\}'

	; Normalise to LF so every line ends cleanly — eliminates CRLF anchor bugs
	FileContent := StrReplace(FileRead(FilePath, "UTF-8"), "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")

	; ── Extract sections_order directly from raw content ──
	MetaOrder := []
	MetaDescriptions := Map()

	if RegExMatch(FileContent, "m)^sections_order\s*=\s*\[([^\]]+)\]", &OM) {
		for Token in StrSplit(OM[1], ",") {
			Token := Trim(Token, " `t`n" . Q)
			if (Token != "") {
				MetaOrder.Push(StrLower(Token))
			}
		}
	}

	if RegExMatch(FileContent, "m)^description\s*=\s*" . Q . "([^" . Q . "]*)" . Q, &DM) {
		Result["meta_description"] := DM[1]
	}

	; ── Extract [_meta.sections] descriptions via multiline scan ──
	; Locate the [_meta.sections] block and read until next [ header
	if RegExMatch(FileContent, "m)^\[_meta\.sections\]\n((?:(?!\[).+\n?)*)", &MS) {
		DescBlock := MS[1]
		Pos := 1
		KPat := "m)^([A-Za-z0-9_]+)\s*=\s*" . Q . "((?:[^" . Q . "\\]|\\.)*)" . Q
		while RegExMatch(DescBlock, KPat, &KM, Pos) {
			MetaDescriptions[StrLower(KM[1])] := UnescapeTomlString(KM[2])
			Pos := KM.Pos + KM.Len
		}
	}

	; ── Single pass: collect [[section]] entries ──
	CurrentSection := ""
	LineIndex := 0
	FileSectionOrder := []

	loop parse, FileContent, "`n" {
		LineIndex++
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		; [[section]] header
		if (SubStr(Line, 1, 2) == "[[" and SubStr(Line, -1) == "]") {
			CurrentSection := StrLower(SubStr(Line, 3, StrLen(Line) - 4))
			if !Result["sections"].Has(CurrentSection) {
				FileSectionOrder.Push(CurrentSection)
				Result["sections"][CurrentSection] := Map(
					"description", MetaDescriptions.Has(CurrentSection)
						? MetaDescriptions[CurrentSection]
						: CurrentSection,
					"entries", [],
					"line_start", LineIndex,
				)
			}
			continue
		}
		; [simple] header — reset section context
		if (SubStr(Line, 1, 1) == "[") {
			CurrentSection := ""
			continue
		}
		if (CurrentSection == "") {
			continue
		}
		if !RegExMatch(Line, EntryPattern, &EM) {
			continue
		}
		Entry := Map(
			"trigger", UnescapeTomlString(EM[1]),
			"output", UnescapeTomlString(EM[2]),
			"is_word", (EM[3] == "true"),
			"auto_expand", (EM[4] == "true"),
			"is_case_sensitive", (EM[5] == "true"),
			"final_result", (EM[6] == "true"),
			"strict_case", (EM[7] == "true"),
			; Empty string means "inherit the source default" (no per-entry key)
			"priority", (EM[8] != "" ? EM[8] + 0 : ""),
			"line_index", LineIndex,
		)
		Result["sections"][CurrentSection]["entries"].Push(Entry)
	}

	; ── Build final sections_order: meta order first, then unlisted sections ──
	Seen := Map()
	for _, SecName in MetaOrder {
		if Result["sections"].Has(SecName) {
			Result["sections_order"].Push(SecName)
			Seen[SecName] := true
		}
	}
	for _, SecName in FileSectionOrder {
		if !Seen.Has(SecName) {
			Result["sections_order"].Push(SecName)
			Seen[SecName] := true
		}
	}
	_ReadPersonalTomlCache := Result
	return Result
}

; Serialise the full TOML structure back to disk.
; Writes [_meta], [_meta.sections], then all [[section]] blocks.
WritePersonalToml(Data) {
	global _ReadPersonalTomlCache, _HS_GrandTotalCache
	_ReadPersonalTomlCache := false ; Invalidate
	_HS_GrandTotalCache := -1
	FilePath := PersonalTomlPath()
	; The two lines above evict only this module's editor-model cache. The engine
	; loader (LoadHotstringsSection) and the prefix-watcher read personal hotstrings
	; through the raw-content _TomlFileCache, which they do NOT touch. Without this
	; eviction the next live rebuild (any tray hotstring toggle -> RebuildHotstringsLive)
	; re-reads the STALE boot-time file content and silently reverts the edit just
	; saved to disk. Drop the reader-shared caches (raw content, group config, section
	; counts, resolve memo) too so the on-disk truth wins on the next read.
	try _ParseTomlGroupConfig_InvalidatePath(FilePath)
	Q := Chr(34)
	Lines := []

	MetaDesc := Data.Has("meta_description") ? Data["meta_description"] : t("editor.hotstrings.meta_desc")
	Lines.Push("[_meta]")
	Lines.Push("description = " . Q . EscapeTomlValue(MetaDesc) . Q)

	; Build sections_order as a TOML inline array
	OrderParts := []
	for SecName in Data["sections_order"] {
		OrderParts.Push(Q . EscapeTomlValue(SecName) . Q)
	}
	Lines.Push("sections_order = [" . ArrayJoin(OrderParts, ", ") . "]")

	Lines.Push("[_meta.sections]")
	for SecName in Data["sections_order"] {
		if Data["sections"].Has(SecName) {
			Desc := Data["sections"][SecName]["description"]
			Lines.Push(EscapeTomlValue(SecName) . " = " . Q . EscapeTomlValue(Desc) . Q)
		}
	}

	for SecName in Data["sections_order"] {
		if !Data["sections"].Has(SecName) {
			continue
		}
		Sec := Data["sections"][SecName]
		Lines.Push("[[" . SecName . "]]")
		for E in Sec["entries"] {
			IsWord := E["is_word"] ? "true" : "false"
			AutoExp := E["auto_expand"] ? "true" : "false"
			IsCaseSens := E["is_case_sensitive"] ? "true" : "false"
			Final := E["final_result"] ? "true" : "false"
			Line := Q . EscapeTomlValue(E["trigger"]) . Q
			. " = { output = " . Q . EscapeTomlValue(E["output"]) . Q
			. ", is_word = " . IsWord
			. ", auto_expand = " . AutoExp
			. ", is_case_sensitive = " . IsCaseSens
			. ", final_result = " . Final
			if E.Has("strict_case") and E["strict_case"] {
				Line .= ", is_case_sensitive_strict = true"
			}
			; Individual collision-priority override — written only when set so
			; entries that inherit the source default stay free of the key
			if E.Has("priority") and E["priority"] != "" {
				Line .= ", priority = " . E["priority"]
			}
			Line .= " }"
			Lines.Push(Line)
		}
	}

	Content := ""
	for i, L in Lines {
		Content .= L . "`r`n"
	}

	FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
	if !FileObj {
		try LoggerError("PersonalToml", "Could not open '{1}' for writing — personal hotstrings NOT saved.", FilePath)
		return False
	}
	FileObj.Write(Content)
	FileObj.Close()

	return True
}

global _ReadPersonalInfoTomlCache := false

; Read personal_info.toml and atomically populate personal-info Maps.
; Format:
;   [info]
;   FirstName = "Adrien"
;   …
;   [letters]
;   a = "StreetAddress"
;   …
; Missing file is silently skipped (defaults remain).
ReadPersonalInfoToml(FilePath) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	if (_ReadPersonalInfoTomlCache != false) {
		PersonalInformation := _ReadPersonalInfoTomlCache["info"].Clone()
		PersonalInformationLetters := _ReadPersonalInfoTomlCache["letters"].Clone()
		return
	}

	if !FileExist(FilePath) {
		return
	}

	try {
		FileContent := FileRead(FilePath, "UTF-8")
	} catch as e {
		LoggerError("hotstrings", "Could not read personal info TOML '{1}': {2}.", FilePath, e.Message)
		return
	}
	NextInformation := PersonalInformation.Clone()
	NextLetters := Map()
	SawLetters := false
	FileContent := StrReplace(FileContent, "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")
	CurrentSection := ""

	loop parse, FileContent, "`n" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		; Section header
		if RegExMatch(Line, "^\[([a-z_]+)\]$", &HM) {
			CurrentSection := HM[1]
			continue
		}
		; Key = "value" pair
		if RegExMatch(Line, 'i)^(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
			Key := KM[1]
			Val := UnescapeTomlString(KM[2])
			if (CurrentSection == "info") {
				if NextInformation.Has(Key)
					NextInformation[Key] := Val
			} else if (CurrentSection == "letters") {
				SawLetters := true
				if (StrLen(Key) != 1) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because it is not one character.", Key)
					continue
				}
				if !NextInformation.Has(Val) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because '{2}' is not an info key.", Key, Val)
					continue
				}
				if NextLetters.Has(Key) {
					LoggerWarn("hotstrings", "Ignoring duplicate personal-info letter alias '{1}'.", Key)
					continue
				}
				NextLetters[Key] := Val
			}
		}
	}
	PersonalInformation := NextInformation
	if SawLetters
		PersonalInformationLetters := NextLetters
	_ReadPersonalInfoTomlCache := Map(
		"info", PersonalInformation.Clone(),
		"letters", PersonalInformationLetters.Clone()
	)
}

; Serialise PersonalInformation and PersonalInformationLetters to personal_info.toml.
WritePersonalInfoToml(FilePath) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	_ReadPersonalInfoTomlCache := false ; Invalidate
	Q := Chr(34)
	Lines := []

	Lines.Push("[info]")
	for Key, Val in PersonalInformation {
		Lines.Push(Key . " = " . Q . EscapeTomlValue(Val) . Q)
	}

	Lines.Push("[letters]")
	for Letter, Key in PersonalInformationLetters {
		Lines.Push(Letter . " = " . Q . EscapeTomlValue(Key) . Q)
	}

	Content := ""
	for L in Lines {
		Content .= L . "`r`n"
	}

	FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
	if !FileObj {
		try LoggerError("PersonalToml", "Could not open '{1}' for writing — personal info NOT saved.", FilePath)
		return False
	}
	FileObj.Write(Content)
	FileObj.Close()

	return True
}

; Make sure personal_info.toml exists at FilePath, materialising the in-memory
; defaults from PersonalInformation / PersonalInformationLetters when it does
; not. Called at script load so that renaming or deleting the file simply
; triggers a fresh re-creation on the next launch — same UX guarantee as
; EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk.
EnsurePersonalInfoTomlFile(FilePath) {
	if FileExist(FilePath) {
		return
	}
	try {
		Dir := RegExReplace(FilePath, "\\[^\\]+$", "")
		if (Dir != "" and !DirExist(Dir)) {
			DirCreate(Dir)
		}
		if WritePersonalInfoToml(FilePath) {
			try LoggerInfo("ErgoptiPlus", "Personal info file created from defaults at '{1}'.", FilePath)
		} else {
			try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}'.", FilePath)
		}
	} catch as e {
		try LoggerWarn("ErgoptiPlus", "Could not create personal info file at '{1}': {2}.",
			FilePath, e.Message)
	}
}

; Helper: join an Array of strings with a separator.
ArrayJoin(Arr, Sep) {
	Out := ""
	for i, v in Arr {
		Out .= (i > 1 ? Sep : "") . v
	}
	return Out
}

; Re-register all hotstrings in a given section from the current TOML data.
; Called after save so new/edited entries are immediately active.
ReloadPersonalSection(Data, SectionName, FeatureConfig) {
	if !Data["sections"].Has(SectionName) {
		return
	}
	; Respect the per-section enabled flag before registering anything live.
	; ApplyMasterGatesToFeatures already folds the Hotstrings master gate (and
	; any per-file sub-category gate) into this same "enabled" flag (see
	; lib/master_gates.ahk), so checking it here mirrors exactly what
	; _HS_RegisterPersonal already does at boot/full-rebuild time. Without this,
	; saving an edit in a section the tray checkbox still shows as disabled
	; silently activated it live (personal-hotstring-live-reload-ignores-gate).
	; FeatureConfig is NOT used for this check — the caller (_SaveData) always
	; passes the "autocorrection" sub-Map regardless of which section is being
	; saved, so this reads the real per-section node from Features directly.
	global Features
	SecKey := StrLower(SectionName)
	SectionEnabled := (IsSet(Features) and Features.Has("hotstrings")
		and Features["hotstrings"].Has("personal")
		and Features["hotstrings"]["personal"].Has(SecKey)
		and IsObject(Features["hotstrings"]["personal"][SecKey])
		and Features["hotstrings"]["personal"][SecKey].Has("enabled")
		and Features["hotstrings"]["personal"][SecKey]["enabled"])
	if !SectionEnabled {
		try LoggerDebug("PersonalToml", "ReloadPersonalSection: '{1}' is disabled — skipping live registration.", SectionName)
		return
	}
	; Clear the section's OLD HSE group before re-registering. Without this the
	; fresh spec for an edited trigger lands as a dead duplicate BEHIND the
	; stale one (HSE's Seq tie-break favours the older/lower-Seq registration),
	; so a same-trigger edit could never take effect until a full Reload
	; (personal-hotstring-live-reload-stale-group). This Group string must stay
	; byte-identical to the one HSE_Register derives below from Options'
	; "Category"/"Section" (Meta.Category . "." . Meta.Section).
	Group := "personal." . SectionName
	HSE_ClearGroupForReload(Group)
	for E in Data["sections"][SectionName]["entries"] {
		Trigger := StrReplace(E["trigger"], "★", ScriptInformation["MagicKey"])
		Output := E["output"]
		Flags := ""
		if E["auto_expand"] {
			Flags .= "*"
		}
		if !E["is_word"] {
			Flags .= "?"
		}
		if E.Has("strict_case") and E["strict_case"] {
			Flags .= "C"
		}
		; Collision priority: the individual per-hotstring override when set,
		; otherwise the personal source default (50). Passing Category + Priority
		; mirrors the boot loader so a live editor reload registers personal
		; hotstrings at the same tier they get at startup — without this they
		; silently fell back to CreateHotstring's common default (10).
		EntryPriority := (E.Has("priority") and E["priority"] != "")
			? E["priority"]
			: _HSE_SourcePriority("personal")
		Options := Map(
			"TimeActivationSeconds", 0,
			"FinalResult", E["final_result"],
			"Category", "personal",
			; Without this, HSE_Register's Group derivation requires BOTH
			; Category and Section to be set, so every re-registered personal
			; hotstring fell back to the generic "default" group — which is
			; never cleared on a normal reload (personal-hotstring-live-
			; reload-stale-group). Must match the "Group" string built above.
			"Section", SectionName,
			"Priority", EntryPriority,
		)
		if E["is_case_sensitive"] {
			CreateHotstring(Flags, Trigger, Output, Options)
		} else {
			CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
		}
	}
}
