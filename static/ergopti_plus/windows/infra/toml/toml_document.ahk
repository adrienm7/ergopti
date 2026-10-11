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
_TOML_DocumentToken(Text, &Position, Separator, &Separated := 0, &SpanStart := 0, &SpanEnd := 0, StopAfterContainer := false) {
	Separated := false
	SpanStart := 0, SpanEnd := 0
	Result := "", Quote := "", Closers := [], Length := StrLen(Text)
	while Position <= Length {
		Char := SubStr(Text, Position, 1)
		Triple := SubStr(Text, Position, 3)
		; Report original token offsets without changing the decoded token. Quote
		; contents own whitespace; comments and outside trivia never own its span.
		if Quote != "" || (Char != "#" && !InStr(" `t`r`n", Char)
				&& (Char != Separator || Closers.Length)) {
			if !SpanStart
				SpanStart := Position
			SpanEnd := Position
		}
		if Quote != "" {
			if StrLen(Quote) == 3 && Triple == Quote {
				QuoteRunLength := 3
				while SubStr(Text, Position + QuoteRunLength, 1) == Char
					QuoteRunLength += 1
				if QuoteRunLength > 5
					throw ValueError("Invalid TOML multiline string closure")
				SpanEnd := Position + QuoteRunLength - 1
				Result .= SubStr(Text, Position, QuoteRunLength)
				Position += QuoteRunLength
				Quote := ""
				continue
			}
			if SubStr(Quote, 1, 1) == Chr(34) && Char == "\" {
				SpanEnd := Position + 1
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
			SpanEnd := Position + 2
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
			if StopAfterContainer && !Closers.Length {
				Result .= Char
				Position += 1
				return Trim(Result, " " . Chr(9) . Chr(13) . Chr(10))
			}
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

; Only the semantic inline-table reader uses this canonical strict delegation.
; Keep the generic inline-table splitter unchanged for all existing callers.
_TOML_DocumentSplit(Body, Separator := ",", Strict := true) {
	Parts := [], Position := 1
	while Position <= StrLen(Body) {
		Token := _TOML_DocumentToken(Body, &Position, Separator, &Separated)
		if Token == "" {
			if Separated || Parts.Length
				throw ValueError("Empty TOML inline table member")
			break
		}
		Parts.Push(Token)
		if Separated && Trim(SubStr(Body, Position), " " . Chr(9) . Chr(13) . Chr(10)) == ""
			throw ValueError("Empty TOML inline table member")
	}
	return Parts
}

; Native Boolean intent stays typed; bare legacy strings keep the old scalar
; contract rather than turning an unknown setting into a whole-file refusal.
_TOML_DocumentValue(Raw) {
	Raw := Trim(Raw, " " . Chr(9) . Chr(13) . Chr(10))
	if SubStr(Raw, 1, 3) == Chr(34) . Chr(34) . Chr(34)
			|| SubStr(Raw, 1, 3) == Chr(39) . Chr(39) . Chr(39)
		return _TOML_DocumentMultilineBody(Raw)
	if SubStr(Raw, 1, 1) == "{"
		return TOML_ParseInlineTable(Raw, _TOML_DocumentValue, _TOML_DocumentSplit)
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
	Document := TOML_ParseDocument(Source, &Records, &Physical)
	Roots := _TOML_ForeignArrayRoots(Physical)
	Projection := _TOML_FlatDocument(_TOML_ArrayProjectionSections(Before, Roots))
	TOML_ParseDocument(Candidate)
	InlineAdmitted := _TOML_AdmitInlineTerminatorParent(Source, Document, Physical, Before, After, Candidate, Updates, Prefixes)
	if InlineAdmitted is Map
		return InlineAdmitted
	if TOML_SameValue(Document, Projection) {
		Content := _TOML_RetainForeignRecords(Source, Candidate, Updates, Prefixes)
		if !TOML_SameValue(TOML_ParseDocument(Content), _TOML_FlatDocument(After))
			throw ValueError("The physical TOML candidate differs from the requested model")
		return Map("content", Content, "preserve_source", false)
	}
	; A disjoint table-array partition has its own exact source proof. Other
	; unrepresentable namespaces still require a semantic no-op; flat equality
	; alone misses deletes and aliases the old reader cannot see.
	if !_TOML_DocumentUpdatesAreNoOp(Document, Projection, Records, Before, After, Updates, Prefixes) {
		Retained := _TOML_AdmitForeignTableArrays(Source, Document, Projection, After, Candidate, Updates, Prefixes)
		if Retained is Map
			return Retained
		throw ValueError("The canonical TOML writer cannot preserve the source namespaces")
	}
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


; Configuration saves have semantic destinations; generic data-file callers keep
; their existing flat writer. Only explicit updates and replacement prefixes own
; source values, so future namespaces and table-array generations stay physical.
_TOML_ConfigPath(Section, Key := unset) {
	Parts := Section == "" ? [] : TOML_ParseKeyPath(Section, true)
	if IsSet(Key) {
		if !(Key is String)
			throw TypeError("Configuration update keys must be strings")
		Parts.Push(Key)
	}
	return Parts
}

_TOML_ConfigPathName(Parts) {
	Name := ""
	for Index, Part in Parts
		Name .= (Index == 1 ? "" : ".") . TOML_RenderKey(Part)
	return Name
}

_TOML_ConfigPathUnder(Parts, Prefix) {
	if Parts.Length < Prefix.Length
		return false
	for Index, Part in Prefix {
		if StrCompare(Parts[Index], Part, true) != 0
			return false
	}
	return true
}

_TOML_ConfigPathDropped(Parts, Prefixes) {
	for Prefix in Prefixes {
		if _TOML_ConfigPathUnder(Parts, Prefix)
			return true
	}
	return false
}

; Ordinary writes cannot turn a retired scalar or array into a new namespace.
; Deletion is explicit ownership; absent deletion never manufactures a table.
_TOML_ConfigSet(Document, Parts, Update) {
	Deleting := Update.HasOwnProp("Delete") && Update.Delete == 1
	if Update.HasOwnProp("Delete") && (!(Update.Delete is Integer)
			|| (Update.Delete != 0 && Update.Delete != 1))
		throw TypeError("Delete must be the Integer 0 or 1")
	Node := Document
	loop Parts.Length - 1 {
		Key := Parts[A_Index]
		if !Node.Has(Key) {
			if Deleting
				return
			Node[Key] := _TOML_DocumentTable()
		}
		if !(Node[Key] is Map)
			throw ValueError("Configuration update collides with a retained scalar or array")
		Node := Node[Key]
	}
	Key := Parts[Parts.Length]
	if Deleting {
		if Node.Has(Key)
			Node.Delete(Key)
		return
	}
	Value := _TOML_DocumentValue(TOML_RenderValue(Update.Value))
	if Node.Has(Key) && ((Node[Key] is Map) != (Value is Map)
			|| (Node[Key] is Array) != (Value is Array))
		throw ValueError("Configuration update cannot replace a retained value container")
	Node[Key] := Value
}

; A changed descendant does not own a containing inline assignment. Its source
; spans come from the existing strict lexical owner, not a second key grammar.
_TOML_ConfigInlineNewRows(Value, Parts, Covered, Rows) {
	Descendants := false
	for Prefix in Covered {
		if _TOML_ConfigPathUnder(Parts, Prefix)
			return
		if _TOML_ConfigPathUnder(Prefix, Parts)
			Descendants := true
	}
	if Value is Map && (!Parts.Length || Descendants) {
		; Deleting the last dotted member still retains its sealed inline parent.
		if Parts.Length && !Value.Count {
			Rows.Push(_TOML_ConfigPathName(Parts) . " = " . TOML_RenderValue(Value))
			return
		}
		for Key, Child in Value {
			ChildParts := Parts.Clone()
			ChildParts.Push(Key)
			_TOML_ConfigInlineNewRows(Child, ChildParts, Covered, Rows)
		}
	} else
		Rows.Push(_TOML_ConfigPathName(Parts) . " = " . TOML_RenderValue(Value))
}

_TOML_ConfigInlineValue(Raw, Before, After, Path, Owned) {
	if TOML_SameValue(Before, After)
		return Raw
	Position := 1
	Token := _TOML_DocumentToken(Raw, &Position, "", , &SpanStart, &SpanEnd)
	if !SpanStart || !TOML_SameValue(_TOML_DocumentValue(Token), Before)
		throw ValueError("An inline source span is not its exact typed member")
	if !(Before is Map && After is Map) || Owned.Has(_TOML_ConfigPathName(Path))
		return SubStr(Raw, 1, SpanStart - 1) . TOML_RenderValue(After) . SubStr(Raw, SpanEnd + 1)
	if SubStr(Raw, SpanStart, 1) != "{" || SubStr(Raw, SpanEnd, 1) != "}"
		throw ValueError("An inline container lost its physical braces")
	Body := SubStr(Raw, SpanStart + 1, SpanEnd - SpanStart - 1)
	Rows := [], Covered := [], Carry := "", ClosingTrivia := "", Position := 1
	while Position <= StrLen(Body) {
		Start := Position
		Member := _TOML_DocumentToken(Body, &Position, ",", &Separated, , &MemberEnd)
		Text := SubStr(Body, Start, Position - Start - (Separated ? 1 : 0))
		if Member == "" {
			if Separated
				throw ValueError("An inline source has an empty member")
			ClosingTrivia := Text
			break
		}
		if !Separated {
			ClosingTrivia := SubStr(Text, MemberEnd - Start + 2)
			Text := SubStr(Text, 1, MemberEnd - Start + 1)
		}
		ValuePosition := 1
		KeyText := _TOML_DocumentToken(Text, &ValuePosition, "=", &Assigned, &KeyStart)
		if !Assigned
			throw ValueError("An inline member has no exact assignment delimiter")
		Parts := TOML_ParseKeyPath(KeyText, true)
		Original := _TOML_DocumentLookup(Before, Parts)
		Desired := _TOML_DocumentLookup(After, Parts)
		if !Original["found"] || Original["blocked"] || Desired["blocked"]
			throw ValueError("An inline member has no unique semantic destination")
		Covered.Push(Parts)
		ValueRaw := SubStr(Text, ValuePosition)
		if !Desired["found"] {
			TailPosition := 1
			_TOML_DocumentToken(ValueRaw, &TailPosition, "", , , &ValueEnd)
			Carry .= SubStr(Text, 1, KeyStart - 1) . SubStr(ValueRaw, ValueEnd + 1)
			continue
		}
		ChildPath := Path.Clone()
		for Part in Parts
			ChildPath.Push(Part)
		Rows.Push(Carry . SubStr(Text, 1, ValuePosition - 1)
			. _TOML_ConfigInlineValue(ValueRaw, Original["value"], Desired["value"], ChildPath, Owned))
		Carry := ""
	}
	NewRows := []
	_TOML_ConfigInlineNewRows(After, [], Covered, NewRows)
	Content := ""
	for Index, Row in Rows
		Content .= (Index == 1 ? "" : ",") . Row
	for Row in NewRows {
		Content .= (Content == "" ? "" : ", ") . Carry . Row
		Carry := ""
	}
	Content .= Carry . ClosingTrivia
	return SubStr(Raw, 1, SpanStart) . Content . SubStr(Raw, SpanEnd)
}

_TOML_ConfigInlineAssignment(Text, Record, Desired, Owned) {
	Position := 1
	_TOML_DocumentToken(Text, &Position, "=", &Assigned)
	if !Assigned
		throw ValueError("A configuration inline assignment lost its source delimiter")
	return SubStr(Text, 1, Position - 1)
		. _TOML_ConfigInlineValue(SubStr(Text, Position), Record.Value, Desired, Record.Path, Owned)
}

; Inline assignments own their complete existing container shape, including
; empty members. Header ancestry alone does not confer that explicit ownership.
_TOML_ConfigRetainedContainers(Value, Parts, Owners, Dropped) {
	if !(Value is Map) || _TOML_ConfigPathDropped(Parts, Dropped)
		return
	Owners[_TOML_ConfigPathName(Parts)] := true
	for Key, Child in Value {
		ChildParts := Parts.Clone()
		ChildParts.Push(Key)
		_TOML_ConfigRetainedContainers(Child, ChildParts, Owners, Dropped)
	}
}

; A removed leaf cannot leave an implicit table that has no physical declaration.
; Preserve surviving source headers and inline containers instead of pruning
; every empty map or changing the generic semantic setter's contract.
_TOML_ConfigPruneDeletedAncestors(Expected, Deleted, Records, Physical, Dropped, Owned) {
	if !Deleted.Length
		return
	Owners := Map()
	Owners.CaseSense := "On"
	for PhysicalRecord in Physical {
		if PhysicalRecord.Kind != "header" || SubStr(Trim(PhysicalRecord.Text), 1, 2) == "[["
			continue
		Parts := _TOML_ConfigPath(PhysicalRecord.Section)
		if !_TOML_ConfigPathDropped(Parts, Dropped)
			Owners[_TOML_ConfigPathName(Parts)] := true
	}
	for Record in Records
		_TOML_ConfigRetainedContainers(Record.Value, Record.Path, Owners, Dropped)
	for Name, Parts in Owned {
		Desired := _TOML_DocumentLookup(Expected, Parts)
		if Desired["found"]
			_TOML_ConfigRetainedContainers(Desired["value"], Parts, Owners, [])
	}
	for DeletedParts in Deleted {
		Parts := DeletedParts.Clone()
		Parts.Pop()
		while Parts.Length {
			Existing := _TOML_DocumentLookup(Expected, Parts)
			if Existing["blocked"]
				break
			if Existing["found"] {
				if !(Existing["value"] is Map) || Existing["value"].Count
						|| Owners.Has(_TOML_ConfigPathName(Parts))
					break
				_TOML_ConfigSet(Expected, Parts, { Delete: 1 })
			}
			Parts.Pop()
		}
	}
}

/**
 * Renders explicit configuration effects against the complete semantic source.
 * @param {String} Source Exact source image captured by the existing I/O owner.
 * @param {Array} Updates Section paths and literal leaf keys, never flat aliases.
 * @param {Array} Prefixes Explicitly replaced semantic namespaces.
 * @returns {Map} Qualified complete content and unchanged-source acknowledgement.
 */
TOML_BuildConfigDocumentCandidate(Source, Updates, Prefixes) {
	Document := TOML_ParseDocument(Source, &Records, &Physical)
	Expected := TOML_ParseDocument(Source)
	for PhysicalRecord in Physical {
		if PhysicalRecord.Kind == "opaque"
			throw ValueError("Cannot retain an unclassified configuration source record")
	}
	Dropped := [], Deleted := []
	for Prefix in Prefixes {
		Parts := _TOML_ConfigPath(Prefix)
		if !Parts.Length
			throw ValueError("A configuration namespace replacement cannot own the root")
		Dropped.Push(Parts)
		Deleted.Push(Parts)
		_TOML_ConfigSet(Expected, Parts, { Delete: 1 })
	}
	Owned := Map()
	Owned.CaseSense := "On"
	for Update in Updates {
		Parts := _TOML_ConfigPath(Update.Section, Update.Key)
		_TOML_ConfigSet(Expected, Parts, Update)
		if Update.HasOwnProp("Delete") && Update.Delete == 1
			Deleted.Push(Parts)
		Owned[_TOML_ConfigPathName(Parts)] := Parts
	}
	_TOML_ConfigPruneDeletedAncestors(Expected, Deleted, Records, Physical, Dropped, Owned)
	if TOML_SameValue(Document, Expected)
		return Map("content", Source, "preserve_source", true)

	; Find the deepest surviving explicit table for each newly introduced leaf.
	; Appending a root dotted row after a header would silently change its owner.
	Headers := [], RecordIndex := 0, HeaderSource := ""
	for PhysicalRecord in Physical {
		if PhysicalRecord.Kind == "opaque"
			throw ValueError("Cannot retain an unclassified configuration source record")
		if PhysicalRecord.Kind == "header" {
			Parts := _TOML_ConfigPath(PhysicalRecord.Section)
			if _TOML_ConfigPathDropped(Parts, Dropped)
				continue
			if SubStr(Trim(PhysicalRecord.Text), 1, 2) != "[["
					&& !_ConfigTomlArrayMember(Document, Parts)
				Headers.Push(Parts)
		} else if PhysicalRecord.Kind == "assignment" {
			RecordIndex += 1
			if _TOML_ConfigPathDropped(Records[RecordIndex].Path, Dropped)
				continue
		}
		if HeaderSource != "" && !RegExMatch(HeaderSource, "[\r\n]$")
			HeaderSource .= "`n"
		HeaderSource .= PhysicalRecord.Text
	}
	Pending := Map()
	Pending.CaseSense := "On"
	NewTables := Map()
	NewTables.CaseSense := "On"
	HeaderAdmission := Map()
	HeaderAdmission.CaseSense := "On"
	for Name, Parts in Owned {
		Desired := _TOML_DocumentLookup(Expected, Parts)
		if !Desired["found"]
			continue
		Covered := false
		for Record in Records {
			if !_TOML_ConfigPathDropped(Record.Path, Dropped)
					&& _TOML_ConfigPathUnder(Parts, Record.Path) {
				Covered := true
				break
			}
		}
		if Covered
			continue
		SectionParts := []
		loop Parts.Length - 1
			SectionParts.Push(Parts[A_Index])
		Identity := _TOML_ConfigPathName(SectionParts)
		; New sections need explicit headers for the still-live native flat reader.
		; The semantic parser decides whether that declaration is legal: existing
		; dotted or inline namespaces may already have closed the requested table.
		; Explicit replacements first release only their classified physical owners.
		if SectionParts.Length && !HeaderAdmission.Has(Identity) {
			HeaderAdmission[Identity] := false
			try {
				TOML_ParseDocument(HeaderSource . "`n[" . Identity . "]`n")
				HeaderAdmission[Identity] := true
			} catch ValueError {
				; Existing physical ownership remains the only legal insertion route.
			}
		}
		if SectionParts.Length && HeaderAdmission[Identity] {
			if !NewTables.Has(Identity)
				NewTables[Identity] := []
			NewTables[Identity].Push(TOML_RenderKey(Parts[Parts.Length]) . " = "
				. TOML_RenderValue(Desired["value"]) . "`n")
			continue
		}
		Owner := []
		for Header in Headers {
			if Header.Length < Parts.Length && Header.Length > Owner.Length
					&& _TOML_ConfigPathUnder(Parts, Header)
				Owner := Header
		}
		Identity := _TOML_ConfigPathName(Owner)
		if !Pending.Has(Identity)
			Pending[Identity] := []
		Relative := []
		loop Parts.Length - Owner.Length
			Relative.Push(Parts[Owner.Length + A_Index])
		Pending[Identity].Push(_TOML_ConfigPathName(Relative) . " = "
			. TOML_RenderValue(Desired["value"]) . "`n")
	}
	Content := "", Current := "", RecordIndex := 0
	Append(Text) {
		if Content != "" && !RegExMatch(Content, "[\r\n]$")
			Content .= "`n"
		Content .= Text
	}
	Flush(Identity) {
		if !Pending.Has(Identity)
			return
		for Text in Pending[Identity]
			Append(Text)
		Pending.Delete(Identity)
	}
	for PhysicalRecord in Physical {
		switch PhysicalRecord.Kind {
			case "header":
				Flush(Current)
				Parts := _TOML_ConfigPath(PhysicalRecord.Section)
				Current := _TOML_ConfigPathName(Parts)
				if !_TOML_ConfigPathDropped(Parts, Dropped)
					Append(PhysicalRecord.Text)
			case "assignment":
				RecordIndex += 1
				Record := Records[RecordIndex]
				if _TOML_ConfigPathDropped(Record.Path, Dropped)
					continue
				Desired := _TOML_DocumentLookup(Expected, Record.Path)
				; Table-array members have no unique update destination. Their
				; complete original generations are retained, never flattened.
				if Desired["blocked"] {
					Append(PhysicalRecord.Text)
					continue
				}
				if !Desired["found"]
					continue
				if TOML_SameValue(Record.Value, Desired["value"])
					Append(PhysicalRecord.Text)
				else if Record.Value is Map && Desired["value"] is Map
						&& !Owned.Has(_TOML_ConfigPathName(Record.Path))
					Append(_TOML_ConfigInlineAssignment(PhysicalRecord.Text, Record, Desired["value"], Owned))
				else {
					Position := 1
					KeyText := _TOML_DocumentToken(PhysicalRecord.Text, &Position, "=")
					Append(KeyText . " = " . TOML_RenderValue(Desired["value"]) . "`n")
				}
			default:
				Append(PhysicalRecord.Text)
		}
	}
	Flush(Current)
	for Identity, Entries in NewTables {
		Append("[" . Identity . "]`n")
		for Text in Entries
			Append(Text)
	}
	if Pending.Count
		throw ValueError("A configuration update lost its physical table owner")
	Candidate := Chr(0xFEFF) . Content
	if !TOML_SameValue(TOML_ParseDocument(Candidate), Expected)
		throw ValueError("The physical configuration candidate differs from its requested semantic model")
	return Map("content", Candidate, "preserve_source", false)
}

; Foreign table arrays cannot lend their collapsed flat row to the writer.
; Only independently representable siblings may change; every array subtree
; and its lexical spans stay with the typed source owner.
_TOML_AdmitForeignTableArrays(Source, Document, Projection, After, Candidate, Updates, Prefixes) {
	TOML_ParseDocument(Source, , &Physical)
	Roots := _TOML_ForeignArrayRoots(Physical)
	if !Roots.Length
		return false
	if !TOML_SameValue(_TOML_WithoutNamespaces(Document, Roots),
			_TOML_WithoutNamespaces(Projection, Roots))
		return false
	for Root in Roots {
		Original := _TOML_DocumentLookup(Document, Root)
		if !Original["found"] || !(Original["value"] is Array)
			return false
		for Update in Updates {
			Parts := TOML_ParseKeyPath(Update.Section, true)
			Parts.Push(Update.Key)
			; The physical owner uses case-insensitive native identities. Refuse
			; both spellings rather than allow an alias to acquire the array.
			if _TOML_NamespaceContains(Root, Parts, false)
					|| _TOML_NamespaceContains(Parts, Root, false)
				return false
		}
		for Prefix in Prefixes {
			Parts := TOML_ParseKeyPath(Prefix, true)
			if _TOML_NamespaceContains(Root, Parts, false)
					|| _TOML_NamespaceContains(Parts, Root, false)
				return false
		}
	}
	Content := _TOML_RetainForeignRecords(Source, Candidate, Updates, Prefixes)
	Result := TOML_ParseDocument(Content)
	for Root in Roots {
		Old := _TOML_DocumentLookup(Document, Root)
		Kept := _TOML_DocumentLookup(Result, Root)
		if !Kept["found"] || !TOML_SameValue(Old["value"], Kept["value"])
			throw ValueError("The canonical TOML candidate changed a foreign table array")
	}
	if !TOML_SameValue(_TOML_WithoutNamespaces(Result, Roots),
			_TOML_WithoutNamespaces(_TOML_FlatDocument(_TOML_ArrayProjectionSections(After, Roots)), Roots))
		throw ValueError("The canonical TOML candidate differs outside its retained table arrays")
	return Map("content", Content, "preserve_source", false)
}

; Select the minimal typed namespaces: a nested array belongs to the outer
; array record, not a second flat destination that could cross its row context.
_TOML_ForeignArrayRoots(Physical) {
	Candidates := [], Roots := []
	for Record in Physical {
		if Record.Kind != "header"
			continue
		Header := Trim(TOML_StripInlineComment(Record.Text), " " . Chr(9) . Chr(13) . Chr(10))
		if SubStr(Header, 1, 2) == "[["
			Candidates.Push(TOML_ParseKeyPath(Record.Section, true))
	}
	for ArrayCandidateIndex, Parts in Candidates {
		ArrayIsNested := false
		for OtherIndex, Other in Candidates {
			if OtherIndex == ArrayCandidateIndex
				continue
			if _TOML_NamespaceContains(Other, Parts)
					&& (Other.Length < Parts.Length || OtherIndex < ArrayCandidateIndex) {
				ArrayIsNested := true
				break
			}
		}
		if !ArrayIsNested
			Roots.Push(Parts)
	}
	return Roots
}

_TOML_NamespaceContains(Parent, Child, CaseSensitive := true) {
	if Parent.Length > Child.Length
		return false
	loop Parent.Length
		if StrCompare(Parent[A_Index], Child[A_Index], CaseSensitive) != 0
			return false
	return true
}

; Clone only the traversed Maps. Borrowed array/scalar values are never mutated.
_TOML_WithoutNamespaces(Document, Roots) {
	Result := Document.Clone()
	for Parts in Roots {
		Node := Result, Found := true
		loop Parts.Length - 1 {
			Part := Parts[A_Index]
			if !Node.Has(Part) || !(Node[Part] is Map) {
				Found := false
				break
			}
			Node[Part] := Node[Part].Clone()
			Node := Node[Part]
		}
		Last := Parts[Parts.Length]
		if Found && Node.Has(Last)
			Node.Delete(Last)
	}
	return Result
}

; Remove only foreign array sections from the rendering model. Implicit table
; ancestors stay in the semantic partition even when no direct leaf names them.
_TOML_ArrayProjectionSections(Sections, Roots) {
	if !Roots.Length
		return Sections
	Result := Sections.Clone()
	for Section in Sections {
		Parts := TOML_ParseKeyPath(Section, true)
		for Root in Roots {
			if _TOML_NamespaceContains(Root, Parts) {
				Result.Delete(Section)
				break
			}
		}
	}
	for Root in Roots {
		if Root.Length < 2
			continue
		Parent := Root.Clone(), Present := false
		Parent.Pop()
		for Section in Result {
			Parts := TOML_ParseKeyPath(Section, true)
			if Parts.Length == Parent.Length && _TOML_NamespaceContains(Parent, Parts) {
				Present := true
				break
			}
		}
		if !Present {
			Section := ""
			for Part in Parent
				Section .= (Section == "" ? "" : ".") . TOML_RenderKey(Part)
			Result[Section] := Map()
		}
	}
	return Result
}

_TOML_ForeignArrayRenderingSections(Source, Sections) {
	RenderingDocument := TOML_ParseDocument(Source, , &Physical)
	RenderingRoots := _TOML_ForeignArrayRoots(Physical)
	if _TOML_InlineTerminatorParent(Physical, RenderingDocument)
		RenderingRoots.Push(["hotstrings"])
	return _TOML_ArrayProjectionSections(Sections, RenderingRoots)
}





; =======================================================
; =======================================================
; ======= 4/ Owned Inline Terminator Parent Edits =======
; =======================================================
; =======================================================

; A root inline parent is one physical record. Only its requested member may
; change; the existing lexical owner locates containers and member boundaries.
_TOML_InlineTableRewriteRecord(RecordText, Changes) {
	InlinePosition := 1
	_TOML_DocumentToken(RecordText, &InlinePosition, "=", &InlineSeparated)
	if !InlineSeparated
		throw ValueError("An inline edit requires an assignment record")
	while InlinePosition <= StrLen(RecordText) && InStr(" " . Chr(9), SubStr(RecordText, InlinePosition, 1))
		InlinePosition += 1
	InlineStart := InlinePosition
	if SubStr(RecordText, InlineStart, 1) != "{"
		throw ValueError("An inline edit requires a table container")
	_TOML_DocumentToken(RecordText, &InlinePosition, Chr(0), , , , true)
	InlineFinish := InlinePosition - 1
	InlineBody := SubStr(RecordText, InlineStart + 1, InlineFinish - InlineStart - 1)
	MemberPosition := 1, Fragments := [], SeenMembers := Map()
	SeenMembers.CaseSense := "On"
	while MemberPosition <= StrLen(InlineBody) {
		MemberStart := MemberPosition
		MemberToken := _TOML_DocumentToken(InlineBody, &MemberPosition, ",", &MemberSeparated)
		if MemberToken == ""
			break
		MemberWidth := MemberPosition - MemberStart - (MemberSeparated ? 1 : 0)
		KeyPosition := 1
		MemberKey := _TOML_DocumentToken(MemberToken, &KeyPosition, "=", &KeySeparated)
		if !KeySeparated
			throw ValueError("An inline member requires an assignment")
		MemberParts := TOML_ParseKeyPath(MemberKey), MemberRoot := MemberParts[1]
		if !Changes.Has(MemberRoot) {
			Fragments.Push(SubStr(InlineBody, MemberStart, MemberWidth))
			continue
		}
		if SeenMembers.Has(MemberRoot)
			continue
		SeenMembers[MemberRoot] := true
		MemberChange := Changes[MemberRoot]
		if !MemberChange["delete"]
			Fragments.Push(" " . TOML_RenderKey(MemberRoot) . " = " . TOML_RenderValue(MemberChange["value"]))
	}
	for MemberRoot, MemberChange in Changes
		if !SeenMembers.Has(MemberRoot) && !MemberChange["delete"]
			Fragments.Push(" " . TOML_RenderKey(MemberRoot) . " = " . TOML_RenderValue(MemberChange["value"]))
	InlineImage := ""
	for Fragment in Fragments
		InlineImage .= (InlineImage == "" ? "" : ",") . Fragment
	return SubStr(RecordText, 1, InlineStart) . InlineImage . SubStr(RecordText, InlineFinish)
}

; Only the declared record parent gets this physical projection. Ignored root
; assignments and literal dotted root names still lack native write authority.
_TOML_InlineTerminatorParent(Physical, Document) {
	ParentTable := Document.Get("hotstrings", 0)
	if !(ParentTable is Map) || (!ParentTable.Has("terminators") && !ParentTable.Has("terminator_states"))
		return false
	for ParentRow in Physical {
		if ParentRow.Kind != "assignment" || ParentRow.Section != ""
			continue
		ParentParts := TOML_ParseKeyPath(ParentRow.Key)
		if ParentParts.Length == 1 && ParentParts[1] == "hotstrings"
			return true
	}
	return false
}

; Canonical sibling saves share the typed editor's lexical member owner. They
; cannot acquire the custom record/state subtree or replace the whole parent.
_TOML_AdmitInlineTerminatorParent(Source, Document, Physical, Before, After, Candidate, Updates, Prefixes) {
	if !_TOML_InlineTerminatorParent(Physical, Document)
		return false
	InlineRoots := _TOML_ForeignArrayRoots(Physical), ArrayRoots := InlineRoots.Clone()
	InlineRoots.Push(["hotstrings"])
	OldProjection := _TOML_FlatDocument(_TOML_ArrayProjectionSections(Before, InlineRoots))
	if !TOML_SameValue(_TOML_WithoutNamespaces(Document, InlineRoots),
			_TOML_WithoutNamespaces(OldProjection, InlineRoots))
		throw ValueError("The inline parent cannot excuse another unrepresented namespace")
	for ParentPrefix in Prefixes {
		PrefixParts := TOML_ParseKeyPath(ParentPrefix, true)
		for ProtectedRoot in InlineRoots
			if _TOML_NamespaceContains(ProtectedRoot, PrefixParts, false)
					|| _TOML_NamespaceContains(PrefixParts, ProtectedRoot, false)
				throw ValueError("An inline or array parent cannot lend namespace replacement authority")
	}
	ParentChanges := Map(), OutsideUpdates := [], ParentExpected := Document["hotstrings"].Clone()
	ParentChanges.CaseSense := "On"
	for ParentUpdate in Updates {
		UpdateParts := TOML_ParseKeyPath(ParentUpdate.Section, true)
		UpdateParts.Push(ParentUpdate.Key)
		for ProtectedRoot in ArrayRoots
			if _TOML_NamespaceContains(ProtectedRoot, UpdateParts, false)
					|| _TOML_NamespaceContains(UpdateParts, ProtectedRoot, false)
				throw ValueError("An array cannot lend inline sibling write authority")
		if StrCompare(UpdateParts[1], "hotstrings", false) != 0 {
			OutsideUpdates.Push(ParentUpdate)
			continue
		}
		if UpdateParts.Length != 2 || StrCompare(UpdateParts[1], "hotstrings", true) != 0
				|| StrCompare(ParentUpdate.Key, "terminators", false) == 0
				|| StrCompare(ParentUpdate.Key, "terminator_states", false) == 0
			throw ValueError("The record owner requires its dedicated typed editor")
		ParentDelete := ParentUpdate.HasOwnProp("Delete") && ParentUpdate.Delete == 1
		ParentChanges[ParentUpdate.Key] := Map("delete", ParentDelete)
		if ParentDelete {
			if ParentExpected.Has(ParentUpdate.Key)
				ParentExpected.Delete(ParentUpdate.Key)
		} else {
			ParentChanges[ParentUpdate.Key]["value"] := ParentUpdate.Value
			ParentExpected[ParentUpdate.Key] := ParentUpdate.Value
		}
	}
	NewProjection := _TOML_FlatDocument(_TOML_ArrayProjectionSections(After, InlineRoots))
	if TOML_SameValue(ParentExpected, Document["hotstrings"])
			&& TOML_SameValue(_TOML_WithoutNamespaces(NewProjection, InlineRoots),
				_TOML_WithoutNamespaces(OldProjection, InlineRoots))
		return Map("content", Source, "preserve_source", true)
	InlineSource := SubStr(Source, 1, 1) == Chr(0xFEFF) ? Chr(0xFEFF) : ""
	for ParentRow in Physical {
		ParentParts := ParentRow.Kind == "assignment" && ParentRow.Section == ""
			? TOML_ParseKeyPath(ParentRow.Key) : []
		InlineSource .= ParentParts.Length == 1 && ParentParts[1] == "hotstrings"
			? _TOML_InlineTableRewriteRecord(ParentRow.Text, ParentChanges) : ParentRow.Text
	}
	InlineContent := _TOML_RetainForeignRecords(InlineSource, Candidate, OutsideUpdates, Prefixes)
	InlineResult := TOML_ParseDocument(InlineContent)
	if !InlineResult.Has("hotstrings") || !TOML_SameValue(ParentExpected, InlineResult["hotstrings"])
		throw ValueError("The inline parent changed outside its requested members")
	for ProtectedRoot in ArrayRoots {
		OldArray := _TOML_DocumentLookup(Document, ProtectedRoot)
		NewArray := _TOML_DocumentLookup(InlineResult, ProtectedRoot)
		if !NewArray["found"] || !TOML_SameValue(OldArray["value"], NewArray["value"])
			throw ValueError("The inline parent changed a foreign array")
	}
	if !TOML_SameValue(_TOML_WithoutNamespaces(InlineResult, InlineRoots),
			_TOML_WithoutNamespaces(NewProjection, InlineRoots))
		throw ValueError("The inline candidate differs outside its admitted partitions")
	return Map("content", InlineContent, "preserve_source", false)
}
