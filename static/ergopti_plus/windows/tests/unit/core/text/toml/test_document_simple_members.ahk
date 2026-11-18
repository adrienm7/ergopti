; tests/unit/core/text/toml/test_document_simple_members.ahk

; ==============================================================================
; MODULE: TOML Document Simple Member Tests
; DESCRIPTION:
; The document reader splits a member list of bare keys and one-line scalars by
; native matches, decodes a one-line basic string or a Boolean directly, and
; takes a quoted key without escapes as its own text. Each shortcut must give
; what the general path gives, refusals included, and the member list of a
; hotstring entry must cost no lexer step.
; ==============================================================================

#Requires AutoHotkey v2.0

; The member split as it was before toml-simple-members-2026-11-18: the oracle.
_TDS_PlainSplit(Body, Separator) {
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

; The scalar decode as it was before toml-simple-members-2026-11-18.
_TDS_PlainScalar(Raw) {
	Raw := Trim(Raw, " " . Chr(9) . Chr(13) . Chr(10))
	Spelled := _TOML_DocumentSpelledInteger(Raw)
	return Spelled != "" ? Spelled : TOML_CoerceValue(Raw, true)
}

; The key path decode as it was before toml-simple-members-2026-11-18.
_TDS_PlainKeyPath(Text, Strict := false) {
	Trimmed := Trim(Text, " " . Chr(9))
	if RegExMatch(Trimmed, "^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\z")
		return StrSplit(Trimmed, ".")
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

; A decoded value or the refusal that replaced it, as comparable text.
_TDS_Outcome(Fn, Args*) {
	try
		return "value " . _TDS_Dump(Fn.Call(Args*))
	catch as Err
		return "refused: " . Type(Err) . " " . Err.Message
}

_TDS_Dump(Value) {
	if Value is TOML_Bool
		return "bool(" . Value.Value . ")"
	if Value is Array {
		Text := "["
		for Item in Value
			Text .= _TDS_Dump(Item) . ","
		return Text . "]"
	}
	return Type(Value) . "(" . Value . ")"
}

; A deterministic pseudo-random choice, so a failure replays.
_TDS_Pick(&Seed, Items) {
	Seed := Mod(Seed * 1103515245 + 12345, 2147483648)
	return Items[Mod(Seed // 65536, Items.Length) + 1]
}

; Member lists near the simple shape: valid ones and every near miss the split
; must leave to the lexer (empty or trailing members, newlines, comments, quotes
; of either kind, containers, escapes at the end of a string).
_TDS_MemberBodies() {
	Q := Chr(34)
	Bodies := [
		" output = " . Q . "user@example.org" . Q . ", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true ",
		"output=" . Q . "a\" . Q . "b" . Q . ",priority=30",
		"output = " . Q . Q . ", is_word = false",
		"output = " . Q . "{Left}#[x]'" . Q . " ,	is_word = true",
		"a = 1,",
		"a = 1,, b = 2",
		", a = 1",
		"",
		"   ",
		"a = " . Q . "x`ny" . Q,
		"a = " . Q . "x\" . Q,
		"a = 'literal', b = 1",
		"a = 1 # note",
		"a = [1, 2], b = 3",
		"a = { b = 1 }",
		Q . "quoted" . Q . " = 1",
		"a.b = 1",
		"a = 1`r",
		"a = 1 b = 2",
		"a = é"
	]
	Keys := ["a", "is_word", "x-1", "é", ""]
	Values := [Q . "plain" . Q, Q . "with \" . Q . " and \\" . Q, Q . "#{[,='" . Q, "true", "1.5e+3", "-", Q . "x\", "'lit'", "[1]"]
	Joins := [",", ", ", " ,", ",,", " , ", "`t,`t"]
	Seed := 20261118
	loop 400 {
		Body := "", Count := Mod(A_Index, 4) + 1
		loop Count {
			Body .= _TDS_Pick(&Seed, Keys) . _TDS_Pick(&Seed, [" = ", "=", " =", "= "]) . _TDS_Pick(&Seed, Values)
			if A_Index < Count
				Body .= _TDS_Pick(&Seed, Joins)
		}
		Bodies.Push(Body)
	}
	return Bodies
}

_TDS_SplitMatchesLexer() {
	for Body in _TDS_MemberBodies()
		AssertEqual(_TDS_Outcome(_TDS_PlainSplit, Body, ","), _TDS_Outcome(_TOML_DocumentSplit, Body, ","),
			"member list " . A_Index . ": " . Body)
}
Test("TOML document: native member split gives the lexer's members and refusals (toml-simple-members-2026-11-18)",
	_TDS_SplitMatchesLexer)

; The regression this guards: a hotstring entry's member list going back
; through the lexer, one classified character per quote, comma and brace. A
; 33 KB personal file has about 260 of them in its boot parse.
_TDS_EntryMembersTakeNoLexerStep() {
	global _TOML_DocumentSlowSteps
	Q := Chr(34)
	Body := " output = " . Q . "background-color:" . Q . ", is_word = true, auto_expand = true,"
		. " is_case_sensitive = true, final_result = true, priority = 30 "
	Before := _TOML_DocumentSlowSteps
	Parts := _TOML_DocumentSplit(Body, ",")
	AssertEqual(0, _TOML_DocumentSlowSteps - Before, "a hotstring entry's members take no lexer step")
	AssertEqual(6, Parts.Length, "every member is split")
	AssertEqual("output = " . Q . "background-color:" . Q, Parts[1], "a member keeps its exact text")
}
Test("TOML document: a hotstring entry's member list takes no lexer step (toml-simple-members-2026-11-18)",
	_TDS_EntryMembersTakeNoLexerStep)

_TDS_ScalarsMatchCoercion() {
	Q := Chr(34)
	Raws := [Q . "plain" . Q, " " . Q . "padded" . Q . " ", Q . Q, Q, Q . "a\nbé\\" . Q, Q . "a" . Q . " " . Q . "b" . Q,
		Q . "x\" . Q, Q . "\uD800" . Q, "true", "false", "True", "FALSE", " true", "truex", "1", "+1", "0x1F", "1.5", "bare",
		"'literal'", "", Q . "★" . Q]
	Alphabet := [Q, Q, "\", "n", "u", "0", "t", "r", "e", "f", "a", "l", "s", " ", "'", "1"]
	Seed := 20261118
	loop 400 {
		Raw := ""
		loop Mod(A_Index, 9) + 1
			Raw .= _TDS_Pick(&Seed, Alphabet)
		Raws.Push(Raw)
	}
	for Raw in Raws {
		Trimmed := Trim(Raw, " " . Chr(9) . Chr(13) . Chr(10))
		; Containers and multi-line strings dispatch before either path.
		if RegExMatch(Trimmed, "^(?:[\[{]|" . Q . Q . Q . "|''')")
			continue
		AssertEqual(_TDS_Outcome(_TDS_PlainScalar, Raw), _TDS_Outcome(_TOML_DocumentValue, Raw), "scalar " . A_Index . ": " . Raw)
	}
}
Test("TOML document: a basic string or a Boolean decodes as scalar coercion does (toml-simple-members-2026-11-18)",
	_TDS_ScalarsMatchCoercion)

_TDS_KeyPathsMatchElementScan() {
	Q := Chr(34)
	Keys := [Q . "@am★" . Q, " " . Q . "spaced" . Q . " ", Q . Q, Q . "a.b" . Q, Q . "a" . Q . "." . Q . "b" . Q,
		Q . "esc\" . Q . "aped" . Q, Q . "tab`there" . Q, Q . "del" . Chr(0x7F) . Q, Q . "nul" . Chr(0) . "x" . Q,
		Q . "unterminated", Q . "a" . Q . "b", "bare.key", "'literal'", Q . "xA" . Q, Q . "x\q" . Q]
	Alphabet := [Q, Q, "\", ".", " ", "a", "é", "'", "u", "0", "`t"]
	Seed := 20261118
	loop 400 {
		Key := ""
		loop Mod(A_Index, 8) + 1
			Key .= _TDS_Pick(&Seed, Alphabet)
		Keys.Push(Key)
	}
	for Key in Keys {
		for Strict in [false, true]
			AssertEqual(_TDS_Outcome(_TDS_PlainKeyPath, Key, Strict), _TDS_Outcome(TOML_ParseKeyPath, Key, Strict),
				"key " . A_Index . " strict " . Strict . ": " . Key)
	}
}
Test("TOML key path: a quoted key without escapes is its own segment, as the element scan finds (toml-simple-members-2026-11-18)",
	_TDS_KeyPathsMatchElementScan)

; The two decoders have no counter to observe, so their order in the source is
; the check: each shortcut answers before the general path it replaces runs.
_TDS_ShortcutsPrecedeGeneralPaths() {
	Value := _StripFullLineComments(_DriverFuncBody("_TOML_DocumentValue"))
	Assert(Value != "", "_TOML_DocumentValue is found")
	Shortcut := InStr(Value, "return TOML_UnescapeBasicStringContents(")
	Assert(Shortcut > 0 && Shortcut < InStr(Value, "_TOML_DocumentSpelledInteger("),
		"a basic string is decoded before the integer spellings are tried")
	BooleanAt := InStr(Value, 'return TOML_Bool(Raw == "true")')
	Assert(BooleanAt > 0 && BooleanAt < InStr(Value, "_TOML_DocumentSpelledInteger("),
		"a Boolean is decoded before the integer spellings are tried")
	KeyPath := _StripFullLineComments(_DriverFuncBody("TOML_ParseKeyPath"))
	Assert(KeyPath != "", "TOML_ParseKeyPath is found")
	Quoted := InStr(KeyPath, "return [SubStr(Trimmed, 2, StrLen(Trimmed) - 2)]")
	Assert(Quoted > 0 && Quoted < InStr(KeyPath, "TOML_SplitArrayElements("),
		"a quoted key without escapes returns before the element scan")
}
Test("TOML document: the scalar and quoted-key shortcuts run before the general paths (toml-simple-members-2026-11-18)",
	_TDS_ShortcutsPrecedeGeneralPaths)
