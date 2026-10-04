; infra/toml/toml_document.ahk

; ==============================================================================
; MODULE: TOML Semantic Document Reader
; DESCRIPTION:
; Proves table and assignment ownership before a native migration can publish.
; The legacy cache and writer keep their flat model; this independent typed
; read refuses semantic aliases that that projection cannot distinguish.
; Scalar coercion retains the native legacy contract for unowned values.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Returns a case-sensitive semantic table without native configuration effects. */
_TOML_DocumentTable() {
	Table := Map()
	Table.CaseSense := "On"
	return Table
}

; One lexical owner serves physical records and nested value containers. Only
; an unquoted top-level separator ends a token; comments never acquire ownership.
_TOML_DocumentToken(Text, &Position, Separator, &Separated := 0) {
	Separated := false
	Result := "", Quote := "", Closers := [], Length := StrLen(Text)
	while Position <= Length {
		Char := SubStr(Text, Position, 1)
		Triple := SubStr(Text, Position, 3)
		if Quote != "" {
			if StrLen(Quote) == 3 && Triple == Quote {
				Run := 3
				while SubStr(Text, Position + Run, 1) == Char
					Run += 1
				if Run > 5
					throw ValueError("Invalid TOML multiline string closure")
				Result .= SubStr(Text, Position, Run)
				Position += Run
				Quote := ""
				continue
			}
			if SubStr(Quote, 1, 1) == Chr(34) && Char == "\" {
				Result .= SubStr(Text, Position, 2)
				Position += 2
				continue
			}
			if StrLen(Quote) == 1 && Char == Quote
				Quote := ""
			else if StrLen(Quote) == 1 && (Char == Chr(10) || Char == Chr(13))
				throw ValueError("A single-line TOML string contains a newline")
		} else if Char == "#" {
			while Position <= Length && SubStr(Text, Position, 1) != Chr(10)
				Position += 1
			continue
		} else if (Triple == Chr(34) . Chr(34) . Chr(34))
				|| (Triple == Chr(39) . Chr(39) . Chr(39)) {
			Quote := Triple
			Result .= Triple
			Position += 3
			continue
		} else if Char == Chr(34) || (Char == Chr(39) && _TOML_IsLiteralStart(Text, Position))
			Quote := Char
		else if Char == "[" || Char == "{"
			Closers.Push(Char == "[" ? "]" : "}")
		else if Char == "]" || Char == "}" {
			if !Closers.Length || !(Char == Closers[Closers.Length])
				throw ValueError("Unbalanced TOML document container")
			Closers.Pop()
		} else if Char == Separator && !Closers.Length {
			Separated := true
			Position += 1
			return Trim(Result, " " . Chr(9) . Chr(13) . Chr(10))
		}
		Result .= Char
		Position += 1
	}
	if Quote != "" || Closers.Length
		throw ValueError("Unterminated TOML document record")
	return Trim(Result, " " . Chr(9) . Chr(13) . Chr(10))
}

_TOML_DocumentMultilineBody(Raw) {
	Delimiter := SubStr(Raw, 1, 3)
	if SubStr(Raw, -3) != Delimiter
		throw ValueError("Unterminated TOML multiline string")
	Body := StrReplace(SubStr(Raw, 4, StrLen(Raw) - 6), Chr(13) . Chr(10), Chr(10))
	if SubStr(Body, 1, 1) == Chr(10)
		Body := SubStr(Body, 2)
	if SubStr(Delimiter, 1, 1) == Chr(39)
		return Body
	Result := "", Position := 1
	while Position <= StrLen(Body) {
		Char := SubStr(Body, Position, 1)
		if Char != "\" {
			Result .= Char
			Position += 1
			continue
		}
		Next := Position + 1
		while InStr(" " . Chr(9), SubStr(Body, Next, 1)) && Next <= StrLen(Body)
			Next += 1
		if SubStr(Body, Next, 1) == Chr(10) {
			Position := Next + 1
			while Position <= StrLen(Body) && InStr(" " . Chr(9) . Chr(10), SubStr(Body, Position, 1))
				Position += 1
		} else {
			Result .= SubStr(Body, Position, 2)
			Position += 2
		}
	}
	return TOML_UnescapeBasicStringContents(Result)
}

; Native Boolean intent stays typed; bare legacy strings keep the old scalar
; contract rather than turning an unknown setting into a whole-file refusal.
_TOML_DocumentValue(Raw) {
	Raw := Trim(Raw, " " . Chr(9) . Chr(13) . Chr(10))
	if SubStr(Raw, 1, 3) == Chr(34) . Chr(34) . Chr(34)
			|| SubStr(Raw, 1, 3) == Chr(39) . Chr(39) . Chr(39)
		return _TOML_DocumentMultilineBody(Raw)
	if SubStr(Raw, 1, 1) == "{"
		return TOML_ParseInlineTable(Raw, _TOML_DocumentValue)
	if SubStr(Raw, 1, 1) == "[" {
		if SubStr(Raw, -1) != "]"
			throw ValueError("Unterminated TOML array")
		Body := SubStr(Raw, 2, StrLen(Raw) - 2), Position := 1, Result := []
		while Position <= StrLen(Body) {
			Token := _TOML_DocumentToken(Body, &Position, ",")
			if Token == "" {
				if SubStr(Body, Position - 1, 1) == ","
					throw ValueError("Empty TOML array member")
				if Trim(SubStr(Body, Position), " " . Chr(9) . Chr(13) . Chr(10)) != ""
					throw ValueError("Empty TOML array member")
				break
			}
			Result.Push(_TOML_DocumentValue(Token))
		}
		return Result
	}
	return TOML_CoerceValue(Raw, true)
}

_TOML_DocumentSealed(Value, Sealed) {
	if !(Value is Map || Value is Array) || Sealed.Has(Value)
		return
	Sealed[Value] := true
	for Key, Child in Value
		_TOML_DocumentSealed(Child, Sealed)
}

_TOML_DocumentContainer(Root, Parts, Limit, Arrays, Sealed) {
	Node := Root
	loop Limit {
		Key := Parts[A_Index]
		if !Node.Has(Key)
			Node[Key] := _TOML_DocumentTable()
		Child := Node[Key]
		if Sealed.Has(Child) || !(Child is Map || Child is Array)
			throw ValueError("TOML header extends a closed value")
		if Arrays.Has(Child) {
			if !Child.Length
				throw ValueError("TOML table array has no current owner")
			Child := Child[Child.Length]
		}
		if !(Child is Map)
			throw ValueError("TOML header crosses an ordinary array")
		Node := Child
	}
	return Node
}

/**
 * Reads exact semantic namespaces without replacing the native flat cache.
 * @param {String} Source - TOML source observed by its existing I/O owner.
 * @param {Array} Records - Receives typed assignment identities and raw values.
 * @param {Array} Physical - Receives exact lexical record spans in source order.
 * @returns {Map} Case-sensitive semantic document; malformed namespaces throw.
 */
TOML_ParseDocument(Source, &Records := 0, &Physical := 0) {
	if !(Source is String)
		throw TypeError("TOML document source must be a String")
	if SubStr(Source, 1, 1) == Chr(0xFEFF)
		Source := SubStr(Source, 2)
	Root := _TOML_DocumentTable(), Current := Root, CurrentPath := [], NativeSection := ""
	Declared := Map(), Dotted := Map(), Arrays := Map(), Sealed := Map()
	Records := [], Physical := [], Position := 1
	while Position <= StrLen(Source) {
		Start := Position
		Record := _TOML_DocumentToken(Source, &Position, Chr(10))
		RawRecord := SubStr(Source, Start, Position - Start)
		if Record == "" {
			Physical.Push({ Kind: "trivia", Section: NativeSection, Text: RawRecord })
			continue
		}
		if SubStr(Record, 1, 1) == "[" {
			ArrayHeader := SubStr(Record, 1, 2) == "[["
			Width := ArrayHeader ? 2 : 1
			if SubStr(Record, -Width) != (ArrayHeader ? "]]" : "]")
				throw ValueError("Malformed TOML table header")
			NativeSection := Trim(SubStr(Record, Width + 1, StrLen(Record) - 2 * Width), " " . Chr(9))
			Parts := TOML_ParseKeyPath(NativeSection, true)
			Parent := _TOML_DocumentContainer(Root, Parts, Parts.Length - 1, Arrays, Sealed)
			Key := Parts[Parts.Length]
			if ArrayHeader {
				if !Parent.Has(Key) {
					Parent[Key] := []
					Arrays[Parent[Key]] := true
				}
				if !(Parent[Key] is Array) || !Arrays.Has(Parent[Key])
					throw ValueError("TOML table array redefines a value")
				Current := _TOML_DocumentTable()
				Parent[Key].Push(Current)
			} else {
				if !Parent.Has(Key)
					Parent[Key] := _TOML_DocumentTable()
				Current := Parent[Key]
				if !(Current is Map) || Sealed.Has(Current) || Declared.Has(Current)
					throw ValueError("Duplicate or closed TOML table namespace")
				Declared[Current] := true
			}
			CurrentPath := Parts
			Physical.Push({ Kind: "header", Section: NativeSection, Text: RawRecord })
			continue
		}
		SplitPosition := 1
		KeyText := _TOML_DocumentToken(Record, &SplitPosition, "=", &Separated)
		if !Separated {
			Physical.Push({ Kind: "opaque", Section: NativeSection, Text: RawRecord })
			continue
		}
		Parts := TOML_ParseKeyPath(KeyText, true)
		Raw := Trim(SubStr(Record, SplitPosition), " " . Chr(9) . Chr(13) . Chr(10))
		Node := Current
		loop Parts.Length - 1 {
			Key := Parts[A_Index]
			if !Node.Has(Key)
				Node[Key] := _TOML_DocumentTable()
			Child := Node[Key]
			if !(Child is Map) || Sealed.Has(Child) || Arrays.Has(Child)
					|| (Declared.Has(Child) && !Dotted.Has(Child))
				throw ValueError("TOML assignment extends a closed namespace")
			Declared[Child] := true
			Dotted[Child] := true
			Node := Child
		}
		Key := Parts[Parts.Length]
		if Node.Has(Key)
			throw ValueError("Duplicate TOML semantic assignment")
		Value := _TOML_DocumentValue(Raw)
		Node[Key] := Value
		_TOML_DocumentSealed(Value, Sealed)
		Path := CurrentPath.Clone()
		for Part in Parts
			Path.Push(Part)
		NativeKey := KeyText
		if StrLen(NativeKey) >= 2 && SubStr(NativeKey, 1, 1) == Chr(34) && SubStr(NativeKey, -1) == Chr(34)
			NativeKey := SubStr(NativeKey, 2, StrLen(NativeKey) - 2)
		Records.Push({ Path: Path, Raw: Raw, Value: Value, Owner: Node, Key: Key,
			NativeSection: NativeSection, NativeKey: NativeKey })
		Physical.Push({ Kind: "assignment", Section: NativeSection, Key: NativeKey, Text: RawRecord })
	}
	return Root
}


; The semantic reader and migration share one typed value owner. Native Boolean
; sentinels retain their intent, while integers and floats compare by value.
_TOML_ValueKind(Value) {
	if Value is TOML_Bool
		return "boolean"
	if Value is String
		return "string"
	if Value is Integer || Value is Float
		return "number"
	if Value is Array
		return "array"
	if Value is Map
		return "table"
	return "unknown"
}

/** Compares native typed TOML values without coercing strings or Booleans. */
TOML_SameValue(Left, Right) {
	Kind := _TOML_ValueKind(Left)
	if Kind != _TOML_ValueKind(Right)
		return false
	switch Kind {
		case "boolean": return !!Left.Value == !!Right.Value
		case "string": return StrCompare(Left, Right, true) == 0
		case "number": return Left = Right
		case "array":
			if Left.Length != Right.Length
				return false
			for Index, Item in Left {
				if !TOML_SameValue(Item, Right[Index])
					return false
			}
			return true
		case "table":
			if Left.Count != Right.Count
				return false
			for Key, Item in Left {
				if !Right.Has(Key) || !TOML_SameValue(Item, Right[Key])
					return false
			}
			return true
	}
	return false
}

; This is the existing flat model's semantic projection, not a second physical
; writer. Rendering values through the canonical owner exposes literal-dot keys,
; ignored root records and collapsed table-array generations before publication.
_TOML_FlatDocument(Sections) {
	Image := ""
	for Section, Entries in Sections {
		Image .= "[" . Section . "]`n"
		for Key, Value in Entries
			Image .= TOML_RenderKey(Key) . " = " . TOML_RenderValue(Value) . "`n"
	}
	return TOML_ParseDocument(Image)
}

_TOML_DocumentLookup(Document, Parts) {
	Node := Document
	for Part in Parts {
		if !(Node is Map)
			return Map("found", false, "blocked", true)
		if !Node.Has(Part)
			return Map("found", false, "blocked", false)
		Node := Node[Part]
	}
	return Map("found", true, "blocked", false, "value", Node)
}

; Native flat identities are only a projection. Verify every requested effect
; against actual source assignments or a strict semantic destination, including
; deletes that the old reader reports missing because it ignores root records.
_TOML_DocumentUpdatesAreNoOp(Document, Projection, Records, Before, After, Updates, Prefixes) {
	for Prefix in Prefixes {
		Parts := TOML_ParseKeyPath(Prefix, true)
		Existing := _TOML_DocumentLookup(Document, Parts)
		if Existing["blocked"]
			return false
		if Existing["found"] {
			Projected := _TOML_DocumentLookup(Projection, Parts)
			if !Projected["found"] || !TOML_SameValue(Existing["value"], Projected["value"])
					|| !TOML_SameValue(Before, After)
				return false
		}
	}
	for Update in Updates {
		Deleting := Update.HasOwnProp("Delete") && Update.Delete == 1
		Matched := false
		for Record in Records {
			if StrCompare(Record.NativeSection, Update.Section, true) != 0
					|| StrCompare(Record.NativeKey, Update.Key, true) != 0
				continue
			Matched := true
			if Deleting || !TOML_SameValue(Record.Value, Update.Value)
				return false
		}
		if Matched
			continue
		Parts := TOML_ParseKeyPath(Update.Section, true)
		Parts.Push(Update.Key)
		Existing := _TOML_DocumentLookup(Document, Parts)
		if Existing["blocked"] || (Deleting && Existing["found"])
			return false
		if !Deleting && (!Existing["found"] || !TOML_SameValue(Existing["value"], Update.Value))
			return false
	}
	return true
}

/** Admits the canonical writer only when its source namespaces survive. */
TOML_AdmitWriterCandidate(Source, Before, After, Candidate, Updates, Prefixes) {
	Document := TOML_ParseDocument(Source, &Records)
	Projection := _TOML_FlatDocument(Before)
	TOML_ParseDocument(Candidate)
	if TOML_SameValue(Document, Projection) {
		Content := _TOML_RetainForeignRecords(Source, Candidate, Updates, Prefixes)
		if !TOML_SameValue(TOML_ParseDocument(Content), _TOML_FlatDocument(After))
			throw ValueError("The physical TOML candidate differs from the requested model")
		return Map("content", Content, "preserve_source", false)
	}
	; Only a semantic no-op can authorize retaining an unrepresentable source.
	; Flat equality alone misses deletes and aliases the old reader cannot see.
	if !_TOML_DocumentUpdatesAreNoOp(Document, Projection, Records, Before, After, Updates, Prefixes)
		throw ValueError("The canonical TOML writer cannot preserve the source namespaces")
	return Map("content", Source, "preserve_source", true)
}


; Only an explicit assignment or namespace replacement owns a physical value.
; The same case-insensitive native Maps select the actual flat writer targets;
; semantic source admission independently rejects collapsed namespace aliases.
_TOML_RecordSectionDropped(Section, Prefixes) {
	for Prefix in Prefixes {
		if Section = Prefix || InStr(Section, Prefix . ".") == 1
			return true
	}
	return false
}

_TOML_RecordOwned(Record, Owners, Prefixes) {
	return _TOML_RecordSectionDropped(Record.Section, Prefixes)
		|| (Owners.Has(Record.Section) && Owners[Record.Section].Has(Record.Key))
}

; Unmatched physical records are user data. Keep their complete lexical spans,
; including comments inside multiline arrays, instead of re-encoding values.
; Explicitly owned rows still come from the existing canonical serializer.
_TOML_RetainForeignRecords(Source, Candidate, Updates, Prefixes) {
	TOML_ParseDocument(Source, , &Physical)
	TOML_ParseDocument(Candidate, , &Canonical)
	Owners := Map(), Rows := Map(), Headers := Map(), Order := []
	Spacing := "", Separator := ""
	for Update in Updates {
		if !Owners.Has(Update.Section)
			Owners[Update.Section] := Map()
		Owners[Update.Section][Update.Key] := Update
	}
	Foreign := false
	for Record in Physical {
		if Record.Kind == "assignment" && !_TOML_RecordOwned(Record, Owners, Prefixes)
			Foreign := true
		else if Record.Kind == "trivia" && Trim(Record.Text, " " . Chr(9) . Chr(13) . Chr(10)) != ""
			Foreign := true
		else if Record.Kind == "header" && !_TOML_RecordSectionDropped(Record.Section, Prefixes) {
			if !Owners.Has(Record.Section)
					|| Trim(TOML_StripInlineComment(Record.Text), " " . Chr(9) . Chr(13) . Chr(10))
						!= Trim(Record.Text, " " . Chr(9) . Chr(13) . Chr(10))
				Foreign := true
		} else if Record.Kind == "opaque"
			throw ValueError("Cannot retain an unclassified TOML source record")
	}
	if !Foreign
		return Candidate
	for Record in Canonical {
		if Record.Kind == "trivia" {
			Spacing .= Record.Text
			continue
		}
		if Record.Kind == "header" {
			if Spacing != "" && Separator == ""
				Separator := Spacing
			Spacing := ""
			Headers[Record.Section] := Record.Text
			Rows[Record.Section] := Map()
			Order.Push(Record.Section)
		} else if Record.Kind == "assignment"
			Rows[Record.Section][Record.Key] := Record.Text
	}
	Content := "", Seen := Map(), Current := ""
	Append(Text) {
		if Content != "" && !RegExMatch(Content, "[\r\n]$")
			Content .= "`n"
		Content .= Text
	}
	Flush(Section) {
		if !Rows.Has(Section)
			return
		Keys := []
		for Key in Rows[Section]
			Keys.Push(Key)
		for Key in SortArray(Keys)
			Append(Rows[Section][Key])
		Rows[Section].Clear()
	}
	for Record in Physical {
		if Record.Kind == "header" {
			if Seen.Has(Current)
				Flush(Current)
			Current := Record.Section
			if !_TOML_RecordSectionDropped(Current, Prefixes) {
				Append(Record.Text)
				Seen[Current] := true
			}
		} else if Record.Kind == "assignment" {
			if _TOML_RecordSectionDropped(Record.Section, Prefixes)
				continue
			if _TOML_RecordOwned(Record, Owners, Prefixes) {
				if Rows.Has(Record.Section) && Rows[Record.Section].Has(Record.Key)
					Append(Rows[Record.Section][Record.Key])
			} else
				Append(Record.Text)
			if Rows.Has(Record.Section) && Rows[Record.Section].Has(Record.Key)
				Rows[Record.Section].Delete(Record.Key)
		} else
			Append(Record.Text)
	}
	if Seen.Has(Current)
		Flush(Current)
	for Section in Order {
		if Seen.Has(Section)
			continue
		if Content != "" && Separator != ""
			Append(Separator)
		Append(Headers[Section])
		Flush(Section)
	}
	return Chr(0xFEFF) . Content
}
