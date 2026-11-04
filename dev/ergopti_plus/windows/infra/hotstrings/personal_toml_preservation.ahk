; infra/hotstrings/personal_toml_preservation.ahk

; ==============================================================================
; MODULE: Personal TOML Source Preservation
; DESCRIPTION:
; Replace only the rows projected by the personal editor. Foreign assignments,
; metadata and comments retain their physical source ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

; A typed fallback admits ordinary rows with additional inline members while
; leaving shorthand and incomplete records outside the editor's ownership.
_PersonalTomlTypedEntry(Line, LineIndex) {
	Position := 1
	Key := _TOML_DocumentToken(Line, &Position, "=", &Separated)
	if !Separated
		return false
	try {
		Parts := TOML_ParseKeyPath(Key, true)
		if Parts.Length != 1
			return false
		ValuePosition := 1
		ValueText := _TOML_DocumentToken(SubStr(Line, Position), &ValuePosition, "")
		Value := _TOML_DocumentValue(ValueText)
		if !(Value is Map) || !Value.Has("output") || !(Value["output"] is String)
			return false
		for Field in ["is_word", "auto_expand", "is_case_sensitive", "final_result"] {
			if !Value.Has(Field) || !(Value[Field] is TOML_Bool)
				return false
		}
		if Value.Has("is_case_sensitive_strict") && !(Value["is_case_sensitive_strict"] is TOML_Bool)
			return false
		if Value.Has("priority") && !HotstringsTryPriority(Value["priority"], &Priority)
			return false
		Entry := Map("trigger", Parts[1], "output", Value["output"],
			"line_index", LineIndex, "priority", Value.Get("priority", ""),
			"strict_case", Value.Has("is_case_sensitive_strict")
				? Value["is_case_sensitive_strict"].Value : false)
		for Field in ["is_word", "auto_expand", "is_case_sensitive", "final_result"]
			Entry[Field] := Value[Field].Value
		return Entry
	} catch {
		; This reader projects only admitted rows; the whole-document writer
		; separately rejects malformed source rather than replacing it.
		return false
	}
}

_PersonalTomlEntryValue(Entry, Previous := 0) {
	Value := Previous is Map ? Previous.Clone() : _TOML_DocumentTable()
	Value["output"] := Entry["output"]
	for Field in ["is_word", "auto_expand", "is_case_sensitive", "final_result"]
		Value[Field] := TOML_Bool(Entry[Field])
	if Entry.Get("strict_case", false)
		Value["is_case_sensitive_strict"] := TOML_Bool(true)
	else if Value.Has("is_case_sensitive_strict")
		Value.Delete("is_case_sensitive_strict")
	if Entry.Get("priority", "") != ""
		Value["priority"] := Entry["priority"]
	else if Value.Has("priority")
		Value.Delete("priority")
	return Value
}

_PersonalTomlRenderEntry(Entry, Original := 0) {
	Previous := Original is Object ? Original.Value : 0
	Value := _PersonalTomlEntryValue(Entry, Previous)
	if Original is Object && TOML_SameValue(Value, Previous)
		return Original.Text
	Value["output"] := NormaliseOutput(Value["output"])
	; Known fields keep the native reader's canonical order. Unknown fields
	; remain typed data, including nested inline tables and literal dotted keys.
	Members := []
	for Field in ["output", "is_word", "auto_expand", "is_case_sensitive", "final_result",
			"is_case_sensitive_strict", "priority"] {
		if Value.Has(Field)
			Members.Push(Field . " = " . TOML_RenderValue(Value[Field]))
	}
	for Field, Child in Value {
		if !InStr("|output|is_word|auto_expand|is_case_sensitive|final_result|is_case_sensitive_strict|priority|", "|" . Field . "|")
			Members.Push(TOML_RenderKey(Field) . " = " . TOML_RenderValue(Child))
	}
	Tail := "`n"
	if Original is Object {
		Position := 1
		_TOML_DocumentToken(Original.Text, &Position, "=")
		Raw := SubStr(Original.Text, Position)
		Position := 1
		_TOML_DocumentToken(Raw, &Position, "", , , &ValueEnd)
		Tail := SubStr(Raw, ValueEnd + 1)
	}
	return TOML_RenderKey(Entry["trigger"]) . " = { " . ArrayJoin(Members, ", ") . " }" . Tail
}

_PersonalTomlAppendSource(&Content, Text) {
	if Text == ""
		return
	if Content != "" && Content != Chr(0xFEFF) && !TOML_EndsWithLineBreak(Content)
		Content .= "`n"
	Content .= Text
}

; The source model is read from these exact bytes rather than a mutable cache.
; Explicit deletion owns displayed rows and headers, never hidden assignments.
_PersonalTomlPreserveModel(Source, Data, Order) {
	Document := TOML_ParseDocument(Source, &Records, &Physical)
	Projected := ReadPersonalToml(true, 0, Source)
	Groups := Map(), ProjectedLines := Map(), DesiredSections := Map()
	for Name, Section in Data["sections"]
		DesiredSections[StrLower(Name)] := Section
	for Name, Section in Projected["sections"] {
		Group := { Name: Name, Rows: [], Headers: [], Foreign: false, Last: 0,
			Originals: Map(), Desired: Map(), Rendered: [], NewRows: [] }
		Group.Originals.CaseSense := "On", Group.Desired.CaseSense := "On"
		Groups[Name] := Group
		for Entry in Section["entries"]
			ProjectedLines[Entry["line_index"]] := Entry
	}
	LineIndex := 1, RecordIndex := 0, Current := 0
	for Index, Row in Physical {
		if Row.Kind == "opaque"
			throw ValueError("unclassified-personal-source")
		if Row.Kind == "header" {
			Parts := TOML_ParseKeyPath(Row.Section, true)
			for Name, Group in Groups {
				Prefix := TOML_ParseKeyPath(Group.HasOwnProp("SourceName") ? Group.SourceName : Name, true)
				if Parts.Length <= Prefix.Length
					continue
				Descendant := true
				for PartIndex, Part in Prefix {
					if !(Part == Parts[PartIndex])
						Descendant := false
				}
				if Descendant
					Group.Foreign := true
			}
			Current := SubStr(Trim(Row.Text), 1, 2) == "[[" && Groups.Has(StrLower(Row.Section))
				? Groups[StrLower(Row.Section)] : 0
			if Current is Object {
				if Current.HasOwnProp("SourceName") && !(Current.SourceName == Row.Section)
					throw ValueError("ambiguous-personal-section-owner")
				Current.SourceName := Row.Section
				Current.Headers.Push(Index)
			}
		}
		if Current is Object
			Current.Last := Index
		if Row.Kind == "assignment" {
			RecordIndex += 1
			if Current is Object {
				if ProjectedLines.Has(LineIndex) {
					Entry := ProjectedLines[LineIndex]
					Trigger := Entry["trigger"]
					if Current.Originals.Has(Trigger)
						throw ValueError("duplicate-personal-trigger")
					Original := { Index: Index, Text: Row.Text, Value: Records[RecordIndex].Value, Trigger: Trigger }
					Current.Originals[Trigger] := Original
					Current.Rows.Push(Original)
				} else
					Current.Foreign := true
			}
		}
		LineIndex += StrSplit(Row.Text, "`n").Length - 1
	}
	for Name, Group in Groups {
		if !DesiredSections.Has(Name) {
			if Group.Foreign
				throw ValueError("unowned-personal-section")
			continue
		}
		for Entry in DesiredSections[StrLower(Name)]["entries"] {
			Trigger := Entry["trigger"]
			if Group.Desired.Has(Trigger)
				throw ValueError("duplicate-personal-trigger")
			Group.Desired[Trigger] := Entry
			Original := Group.Originals.Get(Trigger, 0)
			Group.Rendered.Push(_PersonalTomlRenderEntry(Entry, Original))
			if !(Original is Object)
				Group.NewRows.Push(_PersonalTomlRenderEntry(Entry))
		}
		if Group.Foreign {
			Expected := []
			for Original in Group.Rows {
				if Group.Desired.Has(Original.Trigger)
					Expected.Push(Original.Trigger)
			}
			for Entry in DesiredSections[StrLower(Name)]["entries"] {
				if !Group.Originals.Has(Entry["trigger"])
					Expected.Push(Entry["trigger"])
			}
			for Index, Entry in DesiredSections[StrLower(Name)]["entries"] {
				if !(Entry["trigger"] == Expected[Index])
					throw ValueError("unowned-personal-order")
			}
		}
	}
	Replacements := Map(), Removed := Map(), After := Map()
	for Name, Group in Groups {
		Retained := DesiredSections.Has(Name)
		for Original in Group.Rows {
			Removed[Original.Index] := true
			if !Retained || !Group.Desired.Has(Original.Trigger) {
				Comment := _PersonalTomlRetiredRowComment(Original.Text)
				if Comment != "" {
					Removed.Delete(Original.Index)
					Replacements[Original.Index] := Comment
				}
			}
			if Retained && Group.Foreign && Group.Desired.Has(Original.Trigger) {
				Removed.Delete(Original.Index)
				Replacements[Original.Index] := _PersonalTomlRenderEntry(Group.Desired[Original.Trigger], Original)
			}
		}
		if Retained && Group.Foreign
			After[Group.Last] := Group.NewRows
		else {
			for Index, Header in Group.Headers {
				if !Retained || Index > 1 {
					Comment := _PersonalTomlRetiredHeaderComment(Physical[Header].Text)
					if Comment == ""
						Removed[Header] := true
					else
						Replacements[Header] := Comment
				}
			}
			if Retained
				After[Group.Headers[1]] := Group.Rendered
		}
	}
	Content := SubStr(Source, 1, 1) == Chr(0xFEFF) ? Chr(0xFEFF) : ""
	for Index, Row in Physical {
		if !Removed.Has(Index)
			_PersonalTomlAppendSource(&Content, Replacements.Get(Index, Row.Text))
		if After.Has(Index) {
			for Text in After[Index]
				_PersonalTomlAppendSource(&Content, Text)
		}
	}
	for Name in Order {
		if Groups.Has(StrLower(Name))
			continue
		TOML_ParseKeyPath(Name, true)
		_PersonalTomlAppendSource(&Content, "[[" . Name . "]]`n")
		for Entry in DesiredSections[StrLower(Name)]["entries"]
			_PersonalTomlAppendSource(&Content, _PersonalTomlRenderEntry(Entry))
	}
	Updates := [{ Section: "_meta", Key: "sections_order", Value: Order }]
	if Source == ""
		Updates.Push({ Section: "_meta", Key: "description",
			Value: Data.Get("meta_description", t("editor.hotstrings.meta_desc")) })
	for Name in Order {
		Path := ["_meta", "sections", Name]
		Parent := _TOML_DocumentLookup(Document, Path)
		Nested := Parent["found"] && Parent["value"] is Map
		Stored := Parent
		if Nested {
			Stored := _TOML_DocumentLookup(Document, ["_meta", "sections", Name, "description"])
			; A flat inline description map has no visible description leaf.
			; Ordinary section-override tables may acquire a new visible leaf.
			if !Stored["found"] {
				for Record in Records {
					if Record.Path.Length == Path.Length && TOML_SameValue(Record.Path, Path) {
						Stored := Parent
						break
					}
				}
			}
		}
		Description := Data["sections"][Name]["description"]
		if Stored["found"] && !(Stored["value"] is String) {
			Fallback := Projected["sections"].Has(StrLower(Name))
				? Projected["sections"][StrLower(Name)]["description"] : StrLower(Name)
			if !(Description == Fallback)
				throw ValueError("unowned-personal-description")
			continue
		}
		if Nested
			Updates.Push({ Section: "_meta.sections." . TOML_RenderKey(Name), Key: "description", Value: Description })
		else
			Updates.Push({ Section: "_meta.sections", Key: Name, Value: Description })
	}
	_PersonalTomlMetadataRowsAvailable(Source, Updates)
	Patched := TOML_BuildConfigDocumentCandidate(Content, Updates, [])
	Candidate := Patched["content"]
	if SubStr(Source, 1, 1) != Chr(0xFEFF) && SubStr(Candidate, 1, 1) == Chr(0xFEFF)
		Candidate := SubStr(Candidate, 2)
	Check := ReadPersonalToml(true, 0, Candidate)
	for Name in Order {
		if !Check["sections"].Has(StrLower(Name))
			throw ValueError("personal-projection-mismatch")
		Actual := Check["sections"][StrLower(Name)]["entries"]
		Wanted := DesiredSections[StrLower(Name)]["entries"]
		if Actual.Length != Wanted.Length
			throw ValueError("personal-projection-mismatch")
		for Index, Entry in Wanted {
			for Field in ["trigger", "is_word", "auto_expand", "is_case_sensitive", "final_result"] {
				if !(Entry[Field] == Actual[Index][Field])
					throw ValueError("personal-projection-mismatch")
			}
			if !(Entry["output"] == Actual[Index]["output"])
					&& !(NormaliseOutput(Entry["output"]) == Actual[Index]["output"])
				throw ValueError("personal-projection-mismatch")
			if Entry.Get("strict_case", false) != Actual[Index].Get("strict_case", false)
					|| Entry.Get("priority", "") != Actual[Index].Get("priority", "")
				throw ValueError("personal-projection-mismatch")
		}
	}
	return Candidate
}

; Folded aliases are foreign data. A canonical neighboring leaf would otherwise
; become ambiguous for the native consumers that normalize metadata names.
_PersonalTomlMetadataRowsAvailable(Source, Updates) {
	Document := TOML_ParseDocument(Source, &Records, &Physical)
	for Update in Updates {
		Target := _TOML_ConfigPath(Update.Section, Update.Key)
		Node := Document
		for Part in Target {
			if !(Node is Map)
				break
			for Key, Value in Node {
				if StrLower(Key) == StrLower(Part) && !(Key == Part)
					throw ValueError("ambiguous-personal-metadata")
			}
			if !Node.Has(Part)
				break
			Node := Node[Part]
		}
		for Row in Physical {
			if Row.Kind != "header"
				continue
			Parts := TOML_ParseKeyPath(Row.Section, true)
			Folded := true, Exact := true
			loop Min(Parts.Length, Target.Length) {
				if StrLower(Parts[A_Index]) != StrLower(Target[A_Index])
					Folded := false
				if !(Parts[A_Index] == Target[A_Index])
					Exact := false
			}
			if Folded && !Exact
				throw ValueError("ambiguous-personal-metadata")
		}
	}
}

; The UI deletes the displayed assignment. Its trailing comment is user data
; and survives as a standalone comment, with string-contained hashes excluded.
_PersonalTomlRetiredRowComment(Text) {
	Position := 1
	_TOML_DocumentToken(Text, &Position, "=")
	Raw := SubStr(Text, Position)
	Position := 1
	_TOML_DocumentToken(Raw, &Position, "", , , &ValueEnd)
	Tail := SubStr(Raw, ValueEnd + 1)
	return SubStr(LTrim(Tail, " `t"), 1, 1) == "#" ? Tail : ""
}

_PersonalTomlRetiredHeaderComment(Text) {
	Position := 1
	_TOML_DocumentToken(Text, &Position, "", , , &HeaderEnd)
	Tail := SubStr(Text, HeaderEnd + 1)
	return SubStr(LTrim(Tail, " `t"), 1, 1) == "#" ? Tail : ""
}
