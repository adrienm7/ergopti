; drivers/autohotkey/lib/personal_toml_editor.ahk

; ==============================================================================
; MODULE: Personal TOML Editor
; DESCRIPTION:
; Full-featured GUI for managing hotstrings stored in personal.toml.
; Mirrors the Hammerspoon hotstring editor feature set: section navigation,
; per-entry flags (is_word, auto_expand, is_case_sensitive, final_result),
; multiline output with {Token} alias support, inline editing, section
; creation/rename/delete, and persistent UI preferences.
;
; FEATURES & RATIONALE:
; 1. ReadPersonalToml: parses the full TOML structure (sections, entries, meta)
;    and returns a structured Map so the GUI can navigate by section.
; 2. WritePersonalToml: serialises the full structure back to disk, preserving
;    the [_meta] / [_meta.sections] / [[section]] format expected by the loader.
; 3. NormaliseOutput: mirrors HS normalise_output — converts bare line-breaks to
;    {Enter} and canonicalises {alias} tokens ({left} → {Left}, etc.).
; 4. OpenPersonalEditor: singleton GUI with section tabs, entry list,
;    add/edit/delete form, flag checkboxes, and preference persistence.
; 5. Section management: create, rename, and delete sections from the GUI.
; 6. Preference persistence: default section and close-on-add are stored in
;    the ini so they survive script reloads.
; ==============================================================================




; ==========================================================
; ==========================================================
; ======= 1/ Path helper =======
; ==========================================================
; ==========================================================

; Return the configured path to personal.toml.
PersonalTomlPath() {
	global ScriptInformation
	if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalTomlPath") {
		return ScriptInformation["PersonalTomlPath"]
	}
	return A_ScriptDir . "\..\hotstrings\personal.toml"
}




; ==========================================================
; ==========================================================
; ======= 2/ TOML read / write layer =======
; ==========================================================
; ==========================================================

; Escape a raw string for a TOML double-quoted value field.
EscapeTomlValue(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, "`"", "\`"")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return s
}

; Mirrors HS normalise_output: bare CRLF/LF become {Enter}; {alias} tokens are
; canonicalised to their proper AHK {Token} form.
NormaliseOutput(s) {
	s := StrReplace(s, "`r`n", "{Enter}")
	s := StrReplace(s, "`r",   "{Enter}")
	s := StrReplace(s, "`n",   "{Enter}")

	Aliases := Map(
		"esc",      "Escape",   "escape",    "Escape",
		"bs",       "BackSpace","backspace",  "BackSpace",
		"del",      "Delete",   "delete",     "Delete",
		"return",   "Enter",    "enter",      "Enter",
		"left",     "Left",     "right",      "Right",
		"up",       "Up",       "down",       "Down",
		"home",     "Home",     "end",        "End",
		"tab",      "Tab",      "pgup",       "PgUp",
		"pgdn",     "PgDn",     "ins",        "Insert",
		"insert",   "Insert",   "space",      "Space",
	)

	Result := ""
	i      := 1
	n      := StrLen(s)
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

; Parse personal.toml into a structured object:
;   .sections_order  — Array of section names in meta order (or file order if no meta)
;   .sections        — Map(name → {description, entries[]})
;   .meta_description — string
;
; Strategy: normalise line endings to LF first so Trim and SubStr are reliable,
; then parse line-by-line. sections_order and descriptions are extracted directly
; from the raw file content with RegExMatch on the full string before the loop,
; avoiding all CRLF / regex-anchor fragility.
ReadPersonalToml() {
	FilePath := PersonalTomlPath()
	Result := Map(
		"sections_order",   [],
		"sections",         Map(),
		"meta_description", "Hotstrings personnels",
	)
	if !FileExist(FilePath) {
		return Result
	}

	Q := Chr(34)
	EntryPattern :=
		'i)^' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*=\s*\{\s*output\s*=\s*' . Q . '([^' . Q . '\\]*(?:\\.[^' . Q . '\\]*)*)' . Q
		. '\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)'
		. '\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)'
		. '(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?\s*\}'

	; Normalise to LF so every line ends cleanly — eliminates CRLF anchor bugs
	FileContent := StrReplace(FileRead(FilePath, "UTF-8"), "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")

	; ── Extract sections_order directly from raw content ──
	MetaOrder        := []
	MetaDescriptions := Map()

	if RegExMatch(FileContent, "m)^sections_order\s*=\s*\[([^\]]+)\]", &OM) {
		for _, Token in StrSplit(OM[1], ",") {
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
	CurrentSection   := ""
	LineIndex        := 0
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
					"entries",    [],
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
			"trigger",           UnescapeTomlString(EM[1]),
			"output",            UnescapeTomlString(EM[2]),
			"is_word",           (EM[3] == "true"),
			"auto_expand",       (EM[4] == "true"),
			"is_case_sensitive", (EM[5] == "true"),
			"final_result",      (EM[6] == "true"),
			"strict_case",       (EM[7] == "true"),
			"line_index",        LineIndex,
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
		}
	}

	return Result
}

; Serialise the full TOML structure back to disk.
; Writes [_meta], [_meta.sections], then all [[section]] blocks.
WritePersonalToml(Data) {
	FilePath := PersonalTomlPath()
	Q        := Chr(34)
	Lines    := []

	MetaDesc := Data.Has("meta_description") ? Data["meta_description"] : "Hotstrings personnels"
	Lines.Push("[_meta]")
	Lines.Push("description = " . Q . EscapeTomlValue(MetaDesc) . Q)

	; Build sections_order as a TOML inline array
	OrderParts := []
	for _, SecName in Data["sections_order"] {
		OrderParts.Push(Q . EscapeTomlValue(SecName) . Q)
	}
	Lines.Push("sections_order = [" . ArrayJoin(OrderParts, ", ") . "]")
	Lines.Push("")

	Lines.Push("[_meta.sections]")
	for _, SecName in Data["sections_order"] {
		if Data["sections"].Has(SecName) {
			Desc := Data["sections"][SecName]["description"]
			Lines.Push(EscapeTomlValue(SecName) . " = " . Q . EscapeTomlValue(Desc) . Q)
		}
	}
	Lines.Push("")

	for _, SecName in Data["sections_order"] {
		if !Data["sections"].Has(SecName) {
			continue
		}
		Sec := Data["sections"][SecName]
		Lines.Push("[[" . SecName . "]]")
		for _, E in Sec["entries"] {
			IsWord   := E["is_word"]    ? "true" : "false"
			AutoExp  := E["auto_expand"] ? "true" : "false"
			IsCaseSens := E["is_case_sensitive"] ? "true" : "false"
			Final    := E["final_result"] ? "true" : "false"
			Line := Q . EscapeTomlValue(E["trigger"]) . Q
				. " = { output = " . Q . EscapeTomlValue(E["output"]) . Q
				. ", is_word = " . IsWord
				. ", auto_expand = " . AutoExp
				. ", is_case_sensitive = " . IsCaseSens
				. ", final_result = " . Final
			if E.Has("strict_case") and E["strict_case"] {
				Line .= ", is_case_sensitive_strict = true"
			}
			Line .= " }"
			Lines.Push(Line)
		}
		Lines.Push("")
	}

	Content := ""
	for i, L in Lines {
		Content .= L . "`r`n"
	}

	FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
	if !FileObj {
		return False
	}
	FileObj.Write(Content)
	FileObj.Close()
	return True
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
	for _, E in Data["sections"][SectionName]["entries"] {
		Trigger := StrReplace(E["trigger"], "★", ScriptInformation["MagicKey"])
		Output  := E["output"]
		Flags   := ""
		if E["auto_expand"] {
			Flags .= "*"
		}
		if !E["is_word"] {
			Flags .= "?"
		}
		if E.Has("strict_case") and E["strict_case"] {
			Flags .= "C"
		}
		Options := Map("TimeActivationSeconds", 0, "FinalResult", E["final_result"])
		if E["is_case_sensitive"] {
			CreateHotstring(Flags, Trigger, Output, Options)
		} else {
			CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
		}
	}
}




; ==========================================================
; ==========================================================
; ======= 3/ Preference persistence =======
; ==========================================================
; ==========================================================

; Keys under [PersonalEditor] in the main ini.
_EditorPrefGet(Key, Default) {
	global ConfigurationFile
	if !IsSet(ConfigurationFile) or !FileExist(ConfigurationFile) {
		return Default
	}
	Val := IniRead(ConfigurationFile, "PersonalEditor", Key, "_MISSING_")
	return (Val == "_MISSING_") ? Default : Val
}
_EditorPrefSet(Key, Value) {
	global ConfigurationFile
	if IsSet(ConfigurationFile) {
		IniWrite(Value, ConfigurationFile, "PersonalEditor", Key)
	}
}




; ==========================================================
; ==========================================================
; ======= 4/ GUI =======
; ==========================================================
; ==========================================================

global _PersonalEditorGui   := ""
global _PersonalEditorData  := ""   ; last loaded TOML data (Map)
global _PersonalEditorSection := "" ; currently selected section name

; Open the editor, optionally jumping to a specific section.
; DefaultSection — if set, the editor pre-selects that section.
OpenPersonalEditor(DefaultSection := "") {
	global _PersonalEditorGui, _PersonalEditorData, _PersonalEditorSection

	; Bring existing window to front
	if IsObject(_PersonalEditorGui) {
		try {
			_PersonalEditorGui.Show()
			; If a section was requested, switch to it
			if (DefaultSection != "") {
				_SwitchEditorSection(DefaultSection)
			}
			return
		}
	}

	_PersonalEditorData := ReadPersonalToml()

	; Resolve the section to open
	TargetSection := DefaultSection
	if (TargetSection == "") {
		TargetSection := _EditorPrefGet("DefaultSection", "")
	}
	if (TargetSection == "" and _PersonalEditorData["sections_order"].Length > 0) {
		TargetSection := _PersonalEditorData["sections_order"][1]
	}
	_PersonalEditorSection := TargetSection

	W := Gui("+Resize +MinSize700x560", "Éditeur de hotstrings personnels")
	W.SetFont("s10", "Segoe UI")
	W.MarginX := 12
	W.MarginY := 10

	; ── Top bar: section selector + section management buttons ──
	W.Add("Text", "xm y12 w70 h24 +0x200", "Section :")
	SectionDrop := W.Add("DropDownList", "x+6 yp w420", _BuildSectionList(_PersonalEditorData))
	W.Add("Button", "x+8 yp w90 h24", "Nouvelle…").OnEvent("Click", (*) => _NewSection(W, SectionDrop))
	W.Add("Button", "x+4 yp w90 h24", "Renommer…").OnEvent("Click", (*) => _RenameSection(W, SectionDrop))
	BtnDelSec := W.Add("Button", "x+4 yp w90 h24", "Supprimer")
	BtnDelSec.OnEvent("Click", (*) => _DeleteSection(W, SectionDrop))

	_SelectDropDown(SectionDrop, _PersonalEditorSection)

	; ── Entry list ──
	LV := W.Add("ListView",
		"xm y+10 w860 r12 -Multi +LV0x10000",
		["Déclencheur", "Résultat", "Mot", "Auto", "Casse", "Final"])
	LV.ModifyCol(1, 160)
	LV.ModifyCol(2, 490)
	LV.ModifyCol(3, 45)
	LV.ModifyCol(4, 45)
	LV.ModifyCol(5, 50)
	LV.ModifyCol(6, 45)

	_PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)

	; ── Separator ──
	W.Add("Text", "xm y+8 w860 h1 +0x10")   ; horizontal rule

	; ── Form layout ──
	; Left col : Déclencheur (h22) then Résultat (h62), total left height ≈ 22+6+22+62 = 112
	; Right col: 4 checkboxes h≈20 each with 4px gap = 4*20+3*4 = 92px
	; Add left col first, then place flags with yp pointing back to TriggerEdit top.
	; OutputEdit h=62, flags block h=92 → flags start at TriggerEdit top = OutputEdit top - 28.
	; In AHK v2 yp after OutputEdit = OutputEdit top, so flags at yp-28 = TriggerEdit top.

	W.Add("Text",  "xm y+10 w90 h22 +0x200", "Déclencheur :")
	TriggerEdit := W.Add("Edit", "x108 yp w520 h22")
	W.Add("Text",  "xm y+6  w90 h22 +0x200", "Résultat :")
	OutputEdit  := W.Add("Edit", "x108 yp w520 h62 +Multi +WantReturn")

	; Flags — placed to the right of TriggerEdit, anchored at TriggerEdit top via yp
	TriggerEdit.GetPos(, &TrigY)
	ChkIsWord   := W.Add("CheckBox", "x644 y" . TrigY . " w180", "Mot complet")
	ChkAutoExp  := W.Add("CheckBox", "x644 y+11 w180", "Auto-expand")
	ChkCaseSens := W.Add("CheckBox", "x644 y+11 w180", "Sensible à la casse")
	ChkFinal    := W.Add("CheckBox", "x644 y+11 w180", "Résultat final")
	ChkAutoExp.Value := 1

	; Token help placed under OutputEdit — anchor with absolute Y from OutputEdit position
	OutputEdit.GetPos(, &OutY, , &OutH)
	TokenHelp := W.Add("Text", "xm y" . (OutY + OutH + 8) . " w630 cGray",
		"Tokens : {Enter}  {Tab}  {Left}  {Right}  {Up}  {Down}  {BackSpace}  {Delete}  {Escape}  {Home}  {End}  {Space}  {PgUp}  {PgDn}  {Insert}")

	; ── Separator — anchored below TokenHelp ──
	TokenHelp.GetPos(, &TokY, , &TokH)
	W.Add("Text", "xm y" . (TokY + TokH + 6) . " w860 h1 +0x10")

	; ── Action buttons — three visual groups ──
	GB1 := W.Add("GroupBox", "xm y+10 w240 h54", "Créer")
	GB1.GetPos(&GB1X, &GB1Y)
	BtnAdd        := W.Add("Button",   "x" . (GB1X+10) . " y" . (GB1Y+22) . " w110 h26", "➕ Ajouter")
	CloseOnAddChk := W.Add("CheckBox", "x" . (GB1X+128) . " y" . (GB1Y+26) . " w100",    "Fermer après")
	CloseOnAddChk.Value := (_EditorPrefGet("CloseOnAdd", "0") == "1") ? 1 : 0

	GB2 := W.Add("GroupBox", "x" . (GB1X+250) . " y" . GB1Y . " w360 h54", "Hotstring sélectionné")
	GB2.GetPos(&GB2X, &GB2Y)
	BtnSave  := W.Add("Button", "x" . (GB2X+10)  . " y" . (GB2Y+22) . " w106 h26", "💾 Modifier")
	BtnDel   := W.Add("Button", "x" . (GB2X+122) . " y" . (GB2Y+22) . " w110 h26", "🗑 Supprimer")
	BtnClear := W.Add("Button", "x" . (GB2X+238) . " y" . (GB2Y+22) . " w112 h26", "✖ Effacer form")

	GB3 := W.Add("GroupBox", "x" . (GB2X+370) . " y" . GB1Y . " w120 h54", "Fenêtre")
	GB3.GetPos(&GB3X, &GB3Y)
	W.Add("Button", "x" . (GB3X+10) . " y" . (GB3Y+22) . " w100 h26", "Fermer").OnEvent("Click", (*) => W.Destroy())

	; ── Status bar ──
	StatusText := W.Add("Text", "xm y+10 w860 h20 cGray", "")

	; ── Wiring ──
	BtnAdd.OnEvent("Click", (*) => _AddEntry(W, LV, TriggerEdit, OutputEdit,
		ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, CloseOnAddChk, StatusText))
	BtnSave.OnEvent("Click", (*) => _SaveEntry(W, LV, TriggerEdit, OutputEdit,
		ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))
	BtnDel.OnEvent("Click",  (*) => _DeleteEntry(W, LV, StatusText))
	BtnClear.OnEvent("Click", (*) => _ClearForm(TriggerEdit, OutputEdit,
		ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal))

	LV.OnEvent("ItemSelect", (*) => _FillFormFromSelection(LV, TriggerEdit, OutputEdit,
		ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal))

	SectionDrop.OnEvent("Change", (*) => _OnSectionChange(SectionDrop, LV,
		TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText))

	CloseOnAddChk.OnEvent("Click", (*) => _EditorPrefSet("CloseOnAdd",
		CloseOnAddChk.Value ? "1" : "0"))

	W.OnEvent("Close", (*) => _OnEditorClose())
	W.OnEvent("Size",  (*) => _ResizeEditor(W, LV, OutputEdit, StatusText))

	_PersonalEditorGui := W
	W.Show("Center w900 h640")
}


; ─────────────────────────────────────────────────────
; Internal helpers
; ─────────────────────────────────────────────────────

; Returns display labels for all sections. Kept separate from key names so the
; DDL index always matches sections_order index 1:1.
_BuildSectionList(Data) {
	List := []
	for _, SecName in Data["sections_order"] {
		Desc := Data["sections"].Has(SecName) ? Data["sections"][SecName]["description"] : SecName
		List.Push(Desc)
	}
	if List.Length == 0 {
		List.Push("(aucune section)")
	}
	return List
}

; Rebuild a DropDownList from scratch.
_RebuildDropdown(DDL, Data) {
	DDL.Delete()
	DDL.Add(_BuildSectionList(Data))
}

; Select the DDL entry whose index matches SectionName in sections_order.
_SelectDropDown(DDL, SectionName) {
	global _PersonalEditorData
	if (SectionName == "") {
		DDL.Choose(1)
		return
	}
	for i, SecName in _PersonalEditorData["sections_order"] {
		if (StrLower(Trim(SecName)) == StrLower(Trim(SectionName))) {
			DDL.Choose(i)
			return
		}
	}
	; Fallback: select first item if name not found
	if _PersonalEditorData["sections_order"].Length > 0 {
		DDL.Choose(1)
	}
}

_CurrentSectionFromDrop(DDL) {
	global _PersonalEditorData
	Idx := DDL.Value
	if (Idx < 1 or Idx > _PersonalEditorData["sections_order"].Length) {
		return ""
	}
	return _PersonalEditorData["sections_order"][Idx]
}

_PopulateList(LV, Data, SectionName) {
	LV.Delete()
	if (SectionName == "" or !Data["sections"].Has(SectionName)) {
		return
	}
	for _, E in Data["sections"][SectionName]["entries"] {
		LV.Add("",
			E["trigger"],
			StrReplace(E["output"], "`n", "↵"),
			E["is_word"]    ? "✓" : "",
			E["auto_expand"] ? "✓" : "",
			E["is_case_sensitive"] ? "✓" : "",
			E["final_result"] ? "✓" : "")
	}
}

_FillFormFromSelection(LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
	global _PersonalEditorData, _PersonalEditorSection
	Row := LV.GetNext(0)
	if !Row {
		return
	}
	if !_PersonalEditorData["sections"].Has(_PersonalEditorSection) {
		return
	}
	Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
	if Row > Entries.Length {
		return
	}
	E := Entries[Row]
	TriggerEdit.Value  := E["trigger"]
	OutputEdit.Value   := E["output"]
	ChkIsWord.Value    := E["is_word"]    ? 1 : 0
	ChkAutoExp.Value   := E["auto_expand"] ? 1 : 0
	ChkCaseSens.Value  := E["is_case_sensitive"] ? 1 : 0
	ChkFinal.Value     := E["final_result"] ? 1 : 0
}

_ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
	TriggerEdit.Value := ""
	OutputEdit.Value  := ""
	ChkIsWord.Value   := 0
	ChkAutoExp.Value  := 1
	ChkCaseSens.Value := 0
	ChkFinal.Value    := 0
}

_BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal) {
	T := Trim(TriggerEdit.Value)
	O := NormaliseOutput(OutputEdit.Value)
	return Map(
		"trigger",           T,
		"output",            O,
		"is_word",           ChkIsWord.Value   == 1,
		"auto_expand",       ChkAutoExp.Value  == 1,
		"is_case_sensitive", ChkCaseSens.Value == 1,
		"final_result",      ChkFinal.Value    == 1,
		"strict_case",       false,
		"line_index",        0,
	)
}

_SaveData(W, LV, StatusText) {
	global _PersonalEditorData, _PersonalEditorSection
	if !WritePersonalToml(_PersonalEditorData) {
		StatusText.Value := "⚠ Erreur d'écriture dans personal.toml."
		return false
	}
	FeatureConfig := {TimeActivationSeconds: 0}
	if IsSet(Features) and Features.Has("Personal") and Features["Personal"].Has("Autocorrection") {
		FeatureConfig := Features["Personal"]["Autocorrection"]
	}
	ReloadPersonalSection(_PersonalEditorData, _PersonalEditorSection, FeatureConfig)
	_PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
	StatusText.Value := "✓ Sauvegardé — " . A_Now
	return true
}

_AddEntry(W, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, CloseOnAddChk, StatusText) {
	global _PersonalEditorData, _PersonalEditorSection
	T := Trim(TriggerEdit.Value)
	O := Trim(OutputEdit.Value)
	if (T == "" or O == "") {
		StatusText.Value := "⚠ Le déclencheur et le résultat sont obligatoires."
		return
	}
	if (_PersonalEditorSection == "") {
		StatusText.Value := "⚠ Sélectionnez ou créez une section d'abord."
		return
	}
	; Check for duplicate trigger in this section
	for _, E in _PersonalEditorData["sections"][_PersonalEditorSection]["entries"] {
		if (E["trigger"] == T) {
			StatusText.Value := "⚠ Ce déclencheur existe déjà dans cette section."
			return
		}
	}
	Entry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
	_PersonalEditorData["sections"][_PersonalEditorSection]["entries"].Push(Entry)
	if _SaveData(W, LV, StatusText) {
		_ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
		if CloseOnAddChk.Value {
			W.Destroy()
		}
	}
}

_SaveEntry(W, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
	global _PersonalEditorData, _PersonalEditorSection
	Row := LV.GetNext(0)
	if !Row {
		StatusText.Value := "⚠ Sélectionnez un hotstring à modifier."
		return
	}
	T := Trim(TriggerEdit.Value)
	O := Trim(OutputEdit.Value)
	if (T == "" or O == "") {
		StatusText.Value := "⚠ Le déclencheur et le résultat sont obligatoires."
		return
	}
	Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
	if Row > Entries.Length {
		return
	}
	Entry := _BuildEntry(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
	Entry["line_index"] := Entries[Row]["line_index"]
	Entries[Row] := Entry
	_SaveData(W, LV, StatusText)
}

_DeleteEntry(W, LV, StatusText) {
	global _PersonalEditorData, _PersonalEditorSection
	Row := LV.GetNext(0)
	if !Row {
		StatusText.Value := "⚠ Sélectionnez un hotstring à supprimer."
		return
	}
	Entries := _PersonalEditorData["sections"][_PersonalEditorSection]["entries"]
	if Row > Entries.Length {
		return
	}
	E := Entries[Row]
	Confirm := MsgBox(
		"Supprimer `"" . E["trigger"] . "`" → `"" . E["output"] . "`" ?",
		"Confirmation", "YesNo Icon?"
	)
	if Confirm != "Yes" {
		return
	}
	Entries.RemoveAt(Row)
	_SaveData(W, LV, StatusText)
}

_OnSectionChange(SectionDrop, LV, TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal, StatusText) {
	global _PersonalEditorSection
	_PersonalEditorSection := _CurrentSectionFromDrop(SectionDrop)
	_EditorPrefSet("DefaultSection", _PersonalEditorSection)
	global _PersonalEditorData
	_PopulateList(LV, _PersonalEditorData, _PersonalEditorSection)
	_ClearForm(TriggerEdit, OutputEdit, ChkIsWord, ChkAutoExp, ChkCaseSens, ChkFinal)
	StatusText.Value := ""
}

_NewSection(W, SectionDrop) {
	global _PersonalEditorData, _PersonalEditorSection
	Res := InputBox("Nom de la nouvelle section (identifiant, sans espaces) :", "Nouvelle section", "w300 h120")
	if Res.Result != "OK" or Trim(Res.Value) == "" {
		return
	}
	SecName := StrLower(Trim(Res.Value))
	SecName := RegExReplace(SecName, "[^a-z0-9_]", "_")
	if _PersonalEditorData["sections"].Has(SecName) {
		MsgBox("Cette section existe déjà.", "Erreur", "Icon!")
		return
	}
	Res2 := InputBox("Description affichée dans le menu pour cette section :", "Description", "w300 h120", SecName)
	if Res2.Result != "OK" {
		return
	}
	Desc := Trim(Res2.Value)
	if (Desc == "") {
		Desc := SecName
	}
	_PersonalEditorData["sections_order"].Push(SecName)
	_PersonalEditorData["sections"][SecName] := Map(
		"description", Desc,
		"entries",     [],
		"line_start",  0,
	)
	; Persist and rebuild dropdown
	WritePersonalToml(_PersonalEditorData)
	_RebuildDropdown(SectionDrop, _PersonalEditorData)
	_SelectDropDown(SectionDrop, SecName)
	_PersonalEditorSection := SecName
	_EditorPrefSet("DefaultSection", SecName)
}

_RenameSection(W, SectionDrop) {
	global _PersonalEditorData, _PersonalEditorSection
	if (_PersonalEditorSection == "") {
		MsgBox("Aucune section sélectionnée.", "Erreur", "Icon!")
		return
	}
	OldDesc := _PersonalEditorData["sections"].Has(_PersonalEditorSection)
		? _PersonalEditorData["sections"][_PersonalEditorSection]["description"]
		: _PersonalEditorSection
	Res := InputBox("Nouvelle description pour la section `"" . _PersonalEditorSection . "`" :", "Renommer", "w300 h120", OldDesc)
	if Res.Result != "OK" or Trim(Res.Value) == "" {
		return
	}
	_PersonalEditorData["sections"][_PersonalEditorSection]["description"] := Trim(Res.Value)
	WritePersonalToml(_PersonalEditorData)
	_RebuildDropdown(SectionDrop, _PersonalEditorData)
	_SelectDropDown(SectionDrop, _PersonalEditorSection)
}

_DeleteSection(W, SectionDrop) {
	global _PersonalEditorData, _PersonalEditorSection
	if (_PersonalEditorSection == "") {
		MsgBox("Aucune section sélectionnée.", "Erreur", "Icon!")
		return
	}
	EntryCount := _PersonalEditorData["sections"].Has(_PersonalEditorSection)
		? _PersonalEditorData["sections"][_PersonalEditorSection]["entries"].Length
		: 0
	Confirm := MsgBox(
		"Supprimer la section `"" . _PersonalEditorSection . "`" et ses " . EntryCount . " entrée(s) ?",
		"Confirmation", "YesNo Icon?"
	)
	if Confirm != "Yes" {
		return
	}
	; Remove from order array
	NewOrder := []
	for _, SecName in _PersonalEditorData["sections_order"] {
		if (SecName != _PersonalEditorSection) {
			NewOrder.Push(SecName)
		}
	}
	_PersonalEditorData["sections_order"] := NewOrder
	_PersonalEditorData["sections"].Delete(_PersonalEditorSection)
	WritePersonalToml(_PersonalEditorData)
	_PersonalEditorSection := NewOrder.Length > 0 ? NewOrder[1] : ""
	_RebuildDropdown(SectionDrop, _PersonalEditorData)
	if (_PersonalEditorSection != "") {
		_SelectDropDown(SectionDrop, _PersonalEditorSection)
	}
}

; Switch the open editor to a different section (called when reopening with a target).
_SwitchEditorSection(SectionName) {
	global _PersonalEditorGui, _PersonalEditorData, _PersonalEditorSection
	if !IsObject(_PersonalEditorGui) {
		return
	}
	_PersonalEditorSection := SectionName
	; The ListView and dropdown are stored as named controls — rebuild via a fresh open
	; is the simplest approach for AHK (no handle cache needed).
	_PersonalEditorData := ReadPersonalToml()
	_PersonalEditorGui.Destroy()
	_PersonalEditorGui := ""
	OpenPersonalEditor(SectionName)
}

_OnEditorClose() {
	global _PersonalEditorGui
	_PersonalEditorGui := ""
}

_ResizeEditor(W, LV, OutputEdit, StatusText) {
	W.GetClientPos(, , &CW, &CH)
	LV.Move(, , CW - 24, )
	StatusText.Move(, CH - 26, CW - 24, )
}
