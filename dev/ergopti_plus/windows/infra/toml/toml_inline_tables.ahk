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
		Pair := TOML_SplitArrayElements(Member, "=", true)
		if Pair.Length != 2 || Pair[1] == "" || Pair[2] == ""
			throw ValueError("TOML inline table members require a key and value")
		Keys := TOML_SplitArrayElements(Pair[1], ".", true)
		Parent := Result
		for Index, Token in Keys {
			if RegExMatch(Token, "^[A-Za-z0-9_-]+$")
				Key := Token
			else if RegExMatch(Token, '^"(?:[^"\\]|\\.)*"$')
				Key := TOML_UnescapeBasicStringContents(SubStr(Token, 2, StrLen(Token) - 2))
			else if RegExMatch(Token, "^'[^']*'$")
				Key := SubStr(Token, 2, StrLen(Token) - 2)
			else
				throw ValueError("Invalid TOML inline table key")
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
