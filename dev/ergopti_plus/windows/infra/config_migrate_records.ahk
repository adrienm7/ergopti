; infra/config_migrate_records.ahk

; ==============================================================================
; MODULE: Migration Record Rendering
; DESCRIPTION:
; Applies the migration model's explicit deltas to physical TOML records.
; Untouched comments, values, headers, blank lines, BOM and line terminators
; retain their exact bytes. Ordinary Windows saves keep their canonical writer.
; Lexical continuation tracking mirrors the shared toml_codec.record_scanner:
; a header-looking line inside a value never acquires configuration ownership.
; Quoted identities and arrays of tables stay opaque; changing them refuses.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Physical scan =======
; ================================
; ================================

_ConfigMigrateRecordLines(Source) {
	Lines := [], Position := 1
	while Position <= StrLen(Source) {
		Found := RegExMatch(Source, "`r`n|`n|`r", &Ending, Position)
		if !Found {
			Lines.Push({ Text: SubStr(Source, Position), Eol: "" })
			break
		}
		Lines.Push({ Text: SubStr(Source, Position, Found - Position), Eol: Ending[0] })
		Position := Found + StrLen(Ending[0])
	}
	return Lines
}

_ConfigMigrateRecordAdvance(Text, &Depth, &Quote) {
	Index := 1, Length := StrLen(Text), SawMultilineString := false
	BasicTriple := Chr(34) . Chr(34) . Chr(34)
	LiteralTriple := Chr(39) . Chr(39) . Chr(39)
	while Index <= Length {
		Char := SubStr(Text, Index, 1)
		Triple := SubStr(Text, Index, 3)
		if Quote != "" {
			if Quote == BasicTriple && Char == "\"
				Index += 2
			else if Triple == Quote {
				Index += 3
				while SubStr(Text, Index, 1) == Char
					Index += 1
				Quote := ""
			} else
				Index += 1
		} else if Char == "#"
			break
		else if Triple == BasicTriple || Triple == LiteralTriple {
			SawMultilineString := true
			Quote := Triple
			Index += 3
		} else if Char == Chr(34) {
			Index += 1
			while Index <= Length {
				Char := SubStr(Text, Index, 1)
				if Char == "\"
					Index += 2
				else if Char == Chr(34) {
					Index += 1
					break
				} else
					Index += 1
			}
		} else if Char == Chr(39) {
			Closing := InStr(Text, Chr(39), true, Index + 1)
			Index := Closing ? Closing + 1 : Length + 1
		} else if Char == "[" || Char == "{" {
			Depth += 1
			Index += 1
		} else if Char == "]" || Char == "}" {
			Depth := Max(0, Depth - 1)
			Index += 1
		} else
			Index += 1
	}
	return SawMultilineString
}

_ConfigMigrateRecordUnder(Section, Prefix) {
	return Section = Prefix || InStr(Section, Prefix . ".") == 1
}

_ConfigMigrateRecordAssignmentKey(Text) {
	Index := 1, Quote := ""
	while Index <= StrLen(Text) {
		Char := SubStr(Text, Index, 1)
		if Quote != "" {
			if Quote == Chr(34) && Char == "\"
				Index += 2
			else {
				if Char == Quote
					Quote := ""
				Index += 1
			}
		} else if Char == Chr(34) || Char == Chr(39) {
			Quote := Char
			Index += 1
		} else if Char == "="
			return Trim(SubStr(Text, 1, Index - 1), " `t")
		else if Char == "#"
			return ""
		else
			Index += 1
	}
	return ""
}

_ConfigMigrateRecordMatchesParts(Path, Parts) {
	if !(Parts is Array)
		return false
	Expected := StrSplit(Path, ".")
	if Expected.Length != Parts.Length
		return false
	for Index, Part in Parts {
		if !(Part == Expected[Index])
			return false
	}
	return true
}

_ConfigMigrateRecordScan(Source) {
	Lines := _ConfigMigrateRecordLines(Source)
	Bom := "", Eol := "`n"
	if Lines.Length && SubStr(Lines[1].Text, 1, 1) == Chr(0xFEFF) {
		Bom := Chr(0xFEFF)
		Lines[1].Text := SubStr(Lines[1].Text, 2)
	}
	for Line in Lines {
		if Line.Eol != "" {
			Eol := Line.Eol
			break
		}
	}
	Headers := [], Records := [], Header := 0, Open := 0, Depth := 0, Quote := ""
	for Index, Line in Lines {
		if Depth > 0 || Quote != "" {
			if _ConfigMigrateRecordAdvance(Line.Text, &Depth, &Quote)
				Open.MultilineString := true
			Open.Last := Index
			continue
		}
		Text := Trim(Line.Text, " `t")
		if Text == "" || SubStr(Text, 1, 1) == "#"
			continue
		if SubStr(Text, 1, 1) == "[" {
			ArrayHeader := SubStr(Text, 1, 2) == "[["
			Clean := Trim(TOML_StripInlineComment(Text), " `t")
			Name := ArrayHeader ? SubStr(Clean, 3, StrLen(Clean) - 4) : SubStr(Clean, 2, StrLen(Clean) - 2)
			Name := Trim(Name, " `t")
			Bare := RegExMatch(Name, "^[A-Za-z0-9_-]+(\s*\.\s*[A-Za-z0-9_-]+)*$") != 0
			Header := { Index: Index, Section: Bare ? RegExReplace(Name, "\s+", "") : Name,
				Bare: Bare, Array: ArrayHeader, ModelSection: Name, Parts: TomlConfigSectionParts(Name) }
			Headers.Push(Header)
			continue
		}
		Key := _ConfigMigrateRecordAssignmentKey(Text)
		Addressable := (Header is Object) && Header.Bare && !Header.Array
			&& RegExMatch(Key, "^[A-Za-z0-9_-]+$") != 0
		Open := { First: Index, Last: Index, Header: Header, Key: Key, KeyParts: TomlConfigSectionParts(Key), Addressable: Addressable }
		Records.Push(Open)
		Open.MultilineString := _ConfigMigrateRecordAdvance(Line.Text, &Depth, &Quote)
	}
	if Depth > 0 || Quote != ""
		throw Error("unterminated TOML assignment in the migration source")
	for Record in Records {
		if !Record.Addressable
			continue
		for Owner in Headers {
			if Owner.Array && Owner.Bare && _ConfigMigrateRecordUnder(Record.Header.Section, Owner.Section) {
				Record.Addressable := false
				break
			}
		}
	}
	return { Lines: Lines, Headers: Headers, Records: Records, Bom: Bom, Eol: Eol }
}





; ==================================
; ==================================
; ======= 2/ Explicit deltas =======
; ==================================
; ==================================

_ConfigMigrateRecordDropped(Header, Prefixes) {
	if !(Header is Object)
		return false
	for Prefix in Prefixes {
		if _ConfigMigrateRecordUnder(Header.Section, Prefix)
			return true
	}
	return false
}

_ConfigMigrateRecordBlock(Section, Updates, Eol) {
	Block := "[" . Section . "]" . Eol
	Keys := []
	for Key in Updates
		Keys.Push(Key)
	for Key in SortArray(Keys)
		Block .= Key . " = " . TOML_RenderValue(Updates[Key].Value) . Eol
	return Block
}

; The typed reader does not decode multiline strings. A header or assignment
; inside one can fabricate a source value, or overwrite an earlier real one.
; Migration refuses that unrepresentable model instead of publishing a copy.
; Every other model cell must belong to an actual physical assignment under
; the native reader's raw header/key identity; foreign root records stay opaque.
_ConfigMigrateRecordValidateModel(Scan, Before) {
	Physical := Map()
	for Record in Scan.Records {
		if Record.MultilineString
			throw Error("the native TOML reader cannot represent multiline string ownership")
		Header := Record.Header
		if !(Header is Object)
			continue
		Key := Record.Key
		if StrLen(Key) >= 2 && SubStr(Key, 1, 1) == Chr(34) && SubStr(Key, -1) == Chr(34)
			Key := SubStr(Key, 2, StrLen(Key) - 2)
		if !Physical.Has(Header.ModelSection)
			Physical[Header.ModelSection] := Map()
		Physical[Header.ModelSection][Key] := true
	}
	for Section, Entries in Before {
		for Key in Entries {
			if !(Physical.Has(Section) && Physical[Section].Has(Key))
				throw Error("the native TOML model contains a value outside physical record ownership")
		}
	}
}

; A retained copy source is still a read. The native reader flattens table
; arrays, so their fields cannot prove a scalar source even when no source
; record is deleted. Check only source paths named by active driver steps;
; unrelated opaque tables retain their exact bytes and native model contract.
_ConfigMigrateRecordValidateSources(Scan, Before, Registry, Driver, FromVersion) {
	Addressable := Map()
	for Record in Scan.Records {
		if !Record.Addressable
			continue
		Section := Record.Header.ModelSection
		if !Addressable.Has(Section)
			Addressable[Section] := Map()
		Addressable[Section][Record.Key] := true
	}
	for Step in Registry["steps"] {
		if Step["from"] < FromVersion || !Step["drivers"].Has(Driver)
			continue
		for Op in Step["ops"] {
			if Op["op"] == "set_if_absent" || Op["op"] == "delete"
				continue
			for Section, Entries in Before {
				if Op.Has("key") ? !(Section == Op["section"]) : !_ConfigMigrateRecordUnder(Section, Op["section"])
					continue
				for Key in Entries {
					if Op.Has("key") && !(Key == Op["key"])
						continue
					if !(Addressable.Has(Section) && Addressable[Section].Has(Key))
						throw Error("the migration source is not an addressable physical TOML record")
				}
			}
		}
	}
}

_ConfigMigrateRecordPartsUnder(Parts, Prefix) {
	if !(Parts is Array) || !(Prefix is Array) || Parts.Length < Prefix.Length
		return false
	for Index, Part in Prefix {
		if !(Part == Parts[Index])
			return false
	}
	return true
}

; A new leaf cannot replace an explicitly occupied physical namespace. The
; typed Windows model omits root records and flattens dotted keys/table arrays;
; semantic path parts preserve their ownership without changing op policy.
_ConfigMigrateRecordValidateTargets(Scan, Updates, DropSections) {
	Targets := [], Removed := Map()
	for Update in Updates {
		if Update.HasOwnProp("Delete") && Update.Delete
			Removed[Update.Section . "`n" . Update.Key] := true
		else
			Targets.Push(StrSplit(Update.Section . "." . Update.Key, "."))
	}
	for Index, Target in Targets {
		for OtherIndex, Other in Targets {
			if OtherIndex > Index && Target.Length != Other.Length
				&& (_ConfigMigrateRecordPartsUnder(Target, Other) || _ConfigMigrateRecordPartsUnder(Other, Target))
				throw Error("the migration targets overlap a physical TOML value namespace")
		}
		for Header in Scan.Headers {
			if Header.Bare && !Header.Array && _ConfigMigrateRecordDropped(Header, DropSections)
				continue
			if _ConfigMigrateRecordPartsUnder(Header.Parts, Target)
				|| (Header.Array && _ConfigMigrateRecordPartsUnder(Target, Header.Parts))
				throw Error("the migration target occupies a physical TOML table namespace")
		}
		for Record in Scan.Records {
			if Record.Addressable && (_ConfigMigrateRecordDropped(Record.Header, DropSections)
				|| Removed.Has(Record.Header.ModelSection . "`n" . Record.Key))
				continue
			if !(Record.KeyParts is Array)
				continue
			Parts := (Record.Header is Object) ? Record.Header.Parts : []
			if !(Parts is Array)
				continue
			Path := Parts.Clone()
			for Part in Record.KeyParts
				Path.Push(Part)
			if (_ConfigMigrateRecordPartsUnder(Target, Path) && Target.Length > Path.Length)
				|| (_ConfigMigrateRecordPartsUnder(Path, Target) && Path.Length > Target.Length)
				|| (_ConfigMigrateRecordPartsUnder(Path, Target) && !Record.Addressable)
				throw Error("the migration target occupies a physical TOML value namespace")
		}
	}
}

; The delta owner validates the candidate again against its complete typed
; model. This renderer handles record identity and bytes, never op semantics.
_ConfigMigrateRenderRecords(Source, Updates, DropSections, Scan := 0) {
	if !(Scan is Object)
		Scan := _ConfigMigrateRecordScan(Source)
	Pending := Map(), Seen := Map(), Dropped := Map(), Replaced := Map()
	HeaderLast := Map(), KeptHeaders := Map(), BeforeLine := Map(), AfterLine := Map()
	for Update in Updates {
		if !_ConfigMigrateIsSectionPath(Update.Section) || !_ConfigMigrateIsBareKey(Update.Key)
			throw Error("migration delta has an unaddressable TOML identity")
		if !Pending.Has(Update.Section)
			Pending[Update.Section] := Map()
		if Pending[Update.Section].Has(Update.Key)
			throw Error("migration delta repeats a TOML identity")
		Pending[Update.Section][Update.Key] := Update
	}
	_ConfigMigrateRecordValidateTargets(Scan, Updates, DropSections)
	for Header in Scan.Headers {
		if !Header.Bare {
			for Section in Pending {
				if _ConfigMigrateRecordMatchesParts(Section, Header.Parts)
					throw Error("migration cannot edit an opaque quoted TOML header")
			}
		}
		if _ConfigMigrateRecordDropped(Header, DropSections) {
			if !Header.Bare || Header.Array
				throw Error("migration cannot drop an opaque TOML header")
			Dropped[Header.Index] := true
		} else if Header.Bare && !Header.Array
			KeptHeaders[Header.Section] := Header
	}
	for Record in Scan.Records {
		Header := Record.Header
		if Header is Object
			HeaderLast[Header.Index] := Record.Last
		Dropping := _ConfigMigrateRecordDropped(Header, DropSections)
		if Dropping && !Record.Addressable
			throw Error("migration cannot drop a section containing opaque TOML records")
		if !Record.Addressable {
			if (Header is Object) && Header.Bare && Pending.Has(Header.Section) && (Record.KeyParts is Array) {
				for Key in Pending[Header.Section] {
					if Record.KeyParts.Length && (Record.KeyParts[1] == Key)
						throw Error("migration cannot edit an opaque quoted or dotted TOML key")
				}
			}
			continue
		}
		Section := Header.Section
		Identity := Section . "`n" . Record.Key
		if !Dropping && Seen.Has(Identity)
			throw Error("migration source repeats an edited TOML identity")
		if !Dropping && !(Pending.Has(Section) && Pending[Section].Has(Record.Key))
			continue
		if !Dropping {
			Seen[Identity] := true
			Update := Pending[Section][Record.Key]
			Deleting := Update.HasOwnProp("Delete") && Update.Delete
			if !Deleting {
				RegExMatch(Scan.Lines[Record.First].Text, "^\s*", &Indent)
				Replaced[Record.First] := Indent[0] . Record.Key . " = " . TOML_RenderValue(Update.Value)
					. Scan.Lines[Record.Last].Eol
			}
			Pending[Section].Delete(Record.Key)
		}
		Loop Record.Last - Record.First + 1
			Dropped[Record.First + A_Index - 1] := true
	}
	Sections := []
	for Section in Pending
		Sections.Push(Section)
	Appended := []
	for Section in SortArray(Sections) {
		Remaining := Pending[Section]
		for Key in _ConfigMigrateKeys(Remaining) {
			Update := Remaining[Key]
			if Update.HasOwnProp("Delete") && Update.Delete
				throw Error("migration cannot delete an opaque or missing TOML record")
		}
		if Remaining.Count == 0
			continue
		if KeptHeaders.Has(Section) {
			Header := KeptHeaders[Section]
			Anchor := HeaderLast.Get(Header.Index, Header.Index)
			Rows := ""
			for Key in SortArray(_ConfigMigrateKeys(Remaining))
				Rows .= Key . " = " . TOML_RenderValue(Remaining[Key].Value) . Scan.Eol
			AfterLine[Anchor] := Rows
		} else {
			Block := _ConfigMigrateRecordBlock(Section, Remaining, Scan.Eol)
			if Section == "_meta" && Scan.Headers.Length
				BeforeLine[Scan.Headers[1].Index] := Block . Scan.Eol
			else
				Appended.Push(Block)
		}
	}
	Content := ""
	for Index, Line in Scan.Lines {
		if BeforeLine.Has(Index)
			Content .= BeforeLine[Index]
		if Replaced.Has(Index)
			Content .= Replaced[Index]
		else if !Dropped.Has(Index)
			Content .= Line.Text . Line.Eol
		if AfterLine.Has(Index) {
			if Content != "" && !RegExMatch(Content, "[\r\n]$")
				Content .= Scan.Eol
			Content .= AfterLine[Index]
		}
	}
	for Block in Appended {
		if Content != "" {
			if !RegExMatch(Content, "[\r\n]$")
				Content .= Scan.Eol
			Content .= Scan.Eol
		}
		Content .= Block
	}
	return Map("status", "ok", "content", Scan.Bom . Content)
}
