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
 * @returns {Map} Case-sensitive semantic document; malformed namespaces throw.
 */
TOML_ParseDocument(Source, &Records := 0) {
	if !(Source is String)
		throw TypeError("TOML document source must be a String")
	if SubStr(Source, 1, 1) == Chr(0xFEFF)
		Source := SubStr(Source, 2)
	Root := _TOML_DocumentTable(), Current := Root, CurrentPath := []
	Declared := Map(), Dotted := Map(), Arrays := Map(), Sealed := Map()
	Records := [], Position := 1
	while Position <= StrLen(Source) {
		Record := _TOML_DocumentToken(Source, &Position, Chr(10))
		if Record == ""
			continue
		if SubStr(Record, 1, 1) == "[" {
			ArrayHeader := SubStr(Record, 1, 2) == "[["
			Width := ArrayHeader ? 2 : 1
			if SubStr(Record, -Width) != (ArrayHeader ? "]]" : "]")
				throw ValueError("Malformed TOML table header")
			Parts := TOML_ParseKeyPath(SubStr(Record, Width + 1, StrLen(Record) - 2 * Width), true)
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
			continue
		}
		SplitPosition := 1
		KeyText := _TOML_DocumentToken(Record, &SplitPosition, "=", &Separated)
		if !Separated
			continue
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
		Records.Push({ Path: Path, Raw: Raw, Value: Value, Owner: Node, Key: Key })
	}
	return Root
}
