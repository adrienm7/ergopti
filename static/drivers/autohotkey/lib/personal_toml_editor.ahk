; drivers/autohotkey/lib/personal_toml_editor.ahk

; ==============================================================================
; MODULE: Personal TOML Editor
; DESCRIPTION:
; Lightweight GUI for viewing, adding, and deleting hotstrings stored in
; hotstrings/personal.toml. New entries are appended to a dedicated
; [[personal]] section so the file stays compatible with Hammerspoon and the
; TOML loader without requiring a full parser.
;
; FEATURES & RATIONALE:
; 1. ReadPersonalEntries: scans every [[section]] of personal.toml and returns
;    a flat list so the UI can display all personal hotstrings at a glance.
; 2. AppendPersonalEntry: appends a new entry to the [[personal]] section,
;    creating the section header when it is absent, so the writer never has to
;    re-serialise the whole file (keeping hand-edited comments intact).
; 3. DeletePersonalEntry: rewrites the file with the chosen line removed.
; 4. OpenPersonalEditor: builds the Gui and wires up all event handlers.
; ==============================================================================

; ===========================================
; ===========================================
; ======= 1/ TOML read/write helpers =======
; ===========================================
; ===========================================

; Return path to personal.toml relative to the AHK script directory.
PersonalTomlPath() {
	return A_ScriptDir . "\..\hotstrings\personal.toml"
}

; Escape a raw string for a TOML double-quoted value field.
EscapeTomlValue(s) {
	s := StrReplace(s, "\", "\\")
	s := StrReplace(s, "`"", "\`"")
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return s
}

; Read all hotstring entries from personal.toml.
; Returns an Array of Maps with keys: trigger, output, section, line_index.
ReadPersonalEntries() {
	FilePath := PersonalTomlPath()
	Entries := []
	if !FileExist(FilePath) {
		return Entries
	}

	EntryPattern :=
		'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)'

	FileContent := FileRead(FilePath, "UTF-8")
	CurrentSection := ""
	LineIndex := 0

	loop parse, FileContent, "`n", "`r" {
		LineIndex++
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		if RegExMatch(Line, "^\[\[(.+)\]\]$", &M) {
			CurrentSection := StrLower(M[1])
			continue
		}
		if (SubStr(Line, 1, 1) == "[") {
			CurrentSection := ""
			continue
		}
		if (CurrentSection == "") {
			continue
		}
		if !RegExMatch(Line, EntryPattern, &M) {
			continue
		}
		Entries.Push(Map(
			"trigger",    UnescapeTomlString(M[1]),
			"output",     UnescapeTomlString(M[2]),
			"section",    CurrentSection,
			"line_index", LineIndex,
		))
	}
	return Entries
}

; Append a new entry to the [[personal]] section of personal.toml.
; Creates the file and/or the section header when absent.
AppendPersonalEntry(Trigger, Output) {
	FilePath := PersonalTomlPath()

	EscTrigger := EscapeTomlValue(Trigger)
	EscOutput  := EscapeTomlValue(Output)
	Q       := Chr(34)
	NewLine := Q . EscTrigger . Q . " = { output = " . Q . EscOutput
		. Q . ", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }"

	; Create the file with a minimal header when it does not exist yet.
	if !FileExist(FilePath) {
		FileAppend(
			"# personal.toml — Hotstrings personnels`r`n"
			. "# Géré en partie par l'éditeur AHK. Ne pas modifier l'en-tête.`r`n"
			. "`r`n"
			. "[_meta]`r`n"
			. "description = `"Hotstrings personnels`"`r`n"
			. "sections_order = [`"personal`"]`r`n"
			. "`r`n"
			. "[_meta.sections]`r`n"
			. "personal = `"Hotstrings personnels (ajoutés via l'éditeur AHK)`"`r`n"
			. "`r`n"
			. "[[personal]]`r`n"
			. NewLine . "`r`n",
			FilePath, "UTF-8-RAW"
		)
		return True
	}

	Content := FileRead(FilePath, "UTF-8")
	if InStr(Content, "[[personal]]") {
		; Section exists — just append the new entry at end of file.
		FileAppend(NewLine . "`r`n", FilePath, "UTF-8-RAW")
	} else {
		; No [[personal]] section yet — append header + entry.
		FileAppend(
			"`r`n[[personal]]`r`n" . NewLine . "`r`n",
			FilePath, "UTF-8-RAW"
		)
	}
	return True
}

; Delete the entry at LineIndex from personal.toml (1-based).
DeletePersonalEntry(LineIndex) {
	FilePath := PersonalTomlPath()
	if !FileExist(FilePath) {
		return False
	}
	Content  := FileRead(FilePath, "UTF-8")
	Lines    := StrSplit(Content, "`n")
	NewLines := []
	for i, L in Lines {
		if i != LineIndex {
			NewLines.Push(L)
		}
	}
	NewContent := ""
	for i, L in NewLines {
		NewContent .= L
		if i < NewLines.Length {
			NewContent .= "`n"
		}
	}
	FileObj := FileOpen(FilePath, "w", "UTF-8-RAW")
	if !FileObj {
		return False
	}
	FileObj.Write(NewContent)
	FileObj.Close()
	return True
}




; ======================================
; ======================================
; ======= 2/ GUI — Editor window =======
; ======================================
; ======================================

; Singleton reference so only one editor window is open at a time.
global _PersonalEditorGui := ""

OpenPersonalEditor(*) {
	global _PersonalEditorGui

	; Bring existing window to front rather than opening a duplicate.
	if IsObject(_PersonalEditorGui) {
		try {
			_PersonalEditorGui.Show()
			return
		}
	}

	Entries := ReadPersonalEntries()

	W := Gui("+Resize", "Éditeur de hotstrings personnels")
	W.SetFont("s10", "Segoe UI")
	W.MarginX := 10
	W.MarginY := 10

	; --- ListView ---
	LV := W.Add("ListView",
		"r14 w680 -Multi +LV0x10000",
		["Déclencheur", "Résultat", "Section"])
	LV.ModifyCol(1, 140)
	LV.ModifyCol(2, 400)
	LV.ModifyCol(3, 100)

	for _, E in Entries {
		LV.Add("", E["trigger"], E["output"], E["section"])
	}

	W._entries := Entries

	; --- Add form ---
	W.Add("Text", "xm y+10", "Déclencheur :")
	TriggerEdit := W.Add("Edit", "w200 x+5")
	W.Add("Text", "x+10", "Résultat :")
	OutputEdit  := W.Add("Edit", "w340 x+5")

	BtnAdd := W.Add("Button", "x+10 w80", "Ajouter")
	BtnDel := W.Add("Button", "x+5  w80", "Supprimer")
	W.Add("Button", "x+5 w80", "Fermer").OnEvent("Click", (*) => W.Destroy())

	; --- Event handlers ---

	BtnAdd.OnEvent("Click", AddEntry)
	BtnDel.OnEvent("Click", DeleteEntry)
	LV.OnEvent("DoubleClick", FillFormFromSelection)

	AddEntry(*) {
		global _PersonalEditorGui
		T := Trim(TriggerEdit.Value)
		O := Trim(OutputEdit.Value)
		if (T == "" or O == "") {
			MsgBox("Le déclencheur et le résultat sont obligatoires.", "Éditeur", "Icon!")
			return
		}
		if !AppendPersonalEntry(T, O) {
			MsgBox("Erreur lors de l'écriture dans personal.toml.", "Éditeur", "Icon!")
			return
		}
		; Register the new hotstring immediately without reloading the whole script.
		CreateCaseSensitiveHotstrings("*", T, O)
		W.Destroy()
		_PersonalEditorGui := ""
		OpenPersonalEditor()
	}

	DeleteEntry(*) {
		global _PersonalEditorGui
		Row := LV.GetNext(0)
		if !Row {
			MsgBox("Sélectionnez un hotstring à supprimer.", "Éditeur", "Icon!")
			return
		}
		if Row > W._entries.Length {
			return
		}
		E := W._entries[Row]
		Confirm := MsgBox(
			"Supprimer `"" . E["trigger"] . "`" → `"" . E["output"] . "`" ?",
			"Confirmation", "YesNo Icon?"
		)
		if Confirm != "Yes" {
			return
		}
		DeletePersonalEntry(E["line_index"])
		W.Destroy()
		_PersonalEditorGui := ""
		OpenPersonalEditor()
	}

	FillFormFromSelection(LVCtrl, Row) {
		if !Row or Row > W._entries.Length {
			return
		}
		E := W._entries[Row]
		TriggerEdit.Value := E["trigger"]
		OutputEdit.Value  := E["output"]
	}

	W.OnEvent("Close", OnEditorClose)
	OnEditorClose(*) {
		global _PersonalEditorGui
		_PersonalEditorGui := ""
	}

	_PersonalEditorGui := W
	W.Show("Center")
}
