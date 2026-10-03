; infra/toml/toml_inline_tables.ahk

; ==============================================================================
; MODULE: TOML Inline Tables
; DESCRIPTION:
; Decode object structure without replacing each consumer's scalar contract.
; ==============================================================================

#Requires AutoHotkey v2.0

; Legacy bare values may contain apostrophes (O'Brien). A literal string opens
; only at a token boundary, never in the middle of such a value.
_TOML_IsLiteralStart(Text, Position) {
	Index := Position - 1
	while Index > 0 && InStr(" `t`r`n", SubStr(Text, Index, 1))
		Index -= 1
	return Index == 0 || InStr("[{,=.", SubStr(Text, Index, 1)) > 0
}

/**
 * Decodes one dotted identity with the native quoted-key owner.
 * @param {String} Text - Bare or quoted segments separated by dots.
 * @param {Integer} Strict - Document keys reject nonstandard token whitespace.
 * @returns {Array} Exact semantic segments; malformed paths throw.
 */
TOML_ParseKeyPath(Text, Strict := false) {
	Keys := TOML_SplitArrayElements(Text, ".", true)
	if !Keys.Length
		throw ValueError("A TOML key path requires a segment")
	Parts := []
	End := Strict ? "\z" : "$"
	for Token in Keys {
		if RegExMatch(Token, "^[A-Za-z0-9_-]+" . End)
			Key := Token
		else if RegExMatch(Token, '^"(?:[^"\\]|\\.)*"' . End) {
			Body := SubStr(Token, 2, StrLen(Token) - 2)
			if Strict {
				Index := 1
				while Index <= StrLen(Body) {
					Char := SubStr(Body, Index, 1)
					if Ord(Char) < 0x20 || Ord(Char) == 0x7F
						throw ValueError("A TOML key contains a control character")
					if Char == "\" {
						Escaped := SubStr(Body, Index + 1, 1)
						if Escaped == "u" || Escaped == "U" {
							Width := Escaped == "u" ? 4 : 8
							if !RegExMatch(SubStr(Body, Index + 2, Width), "^[0-9A-Fa-f]{" . Width . "}\z")
								throw ValueError("A TOML key contains an invalid Unicode escape")
							Index += Width
						} else if !InStr('btnfr"\', Escaped) || Escaped == ""
							throw ValueError("A TOML key contains an invalid escape")
						Index += 1
					}
					Index += 1
				}
			}
			Key := TOML_UnescapeBasicStringContents(Body)
		} else if RegExMatch(Token, "^'[^']*'" . End) {
			Key := SubStr(Token, 2, StrLen(Token) - 2)
			if Strict && RegExMatch(Key, "[\x00-\x1F\x7F]")
				throw ValueError("A TOML literal key contains a control character")
		} else
			throw ValueError("Invalid TOML key path")
		Parts.Push(Key)
	}
	return Parts
}

/**
 * Decodes one key token using the same string codec as its rendered value.
 * @param Token {String} Bare, basic-quoted or literal-quoted key.
 * @param Strict {Boolean} Require the inline-table bare-key grammar.
 * @returns {String} The original key identity, with basic escapes decoded once.
 */
TOML_DecodeKey(Token, Strict := false) {
	if RegExMatch(Token, '^"(?:[^"\\]|\\.)*"$')
		return TOML_UnescapeBasicStringContents(SubStr(Token, 2, StrLen(Token) - 2))
	if RegExMatch(Token, "^'[^']*'$")
		return SubStr(Token, 2, StrLen(Token) - 2)
	if Strict && !RegExMatch(Token, "^[A-Za-z0-9_-]+$")
		throw ValueError("Invalid TOML inline table key")
	return Token
}

/** Parses inline members using the caller's scalar and array decoder. */
TOML_ParseInlineTable(Raw, Coerce) {
	Raw := Trim(Raw)
	if SubStr(Raw, 1, 1) != "{" || SubStr(Raw, -1) != "}"
		throw ValueError("Unterminated TOML inline table")
	Result := Map()
	Result.CaseSense := "On"
	; Only implicitly created dotted parents can be extended by another member.
	; An explicit inline table is closed even when the supplied value is empty.
	DottedParents := Map()
	for Member in TOML_SplitArrayElements(SubStr(Raw, 2, StrLen(Raw) - 2), ",", true) {
		; The strict outer scan has checked quotes and nesting. Ordinary registry
		; members need neither a second delimiter scan nor a dotted-key scan.
		if RegExMatch(Member, '^([A-Za-z0-9_-]+)[ \t]*=[ \t]*("(?:[^"\\]|\\.)*"|[A-Za-z0-9_-]+)\z', &SimpleMember) {
			if Result.Has(SimpleMember[1])
				throw ValueError("Duplicate TOML inline table key")
			Result[SimpleMember[1]] := Coerce.Call(SimpleMember[2])
			continue
		}
		Pair := TOML_SplitArrayElements(Member, "=", true)
		if Pair.Length != 2 || Pair[1] == "" || Pair[2] == ""
			throw ValueError("TOML inline table members require a key and value")
		Keys := TOML_ParseKeyPath(Pair[1])
		Parent := Result
		for Index, Key in Keys {
			if Index == Keys.Length {
				if Parent.Has(Key)
					throw ValueError("Duplicate TOML inline table key")
				Parent[Key] := Coerce.Call(Pair[2])
			} else {
				if !Parent.Has(Key) {
					Child := Map()
					Child.CaseSense := "On"
					Parent[Key] := Child
					DottedParents[Child] := true
				}
				if !(Parent[Key] is Map) || !DottedParents.Has(Parent[Key])
					throw ValueError("TOML inline table key extends a closed value")
				Parent := Parent[Key]
			}
		}
	}
	return Result
}
