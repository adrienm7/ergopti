; tests/unit/core/text/toml/test_document_quoted_runs.ahk

; ==============================================================================
; MODULE: TOML Document Lexer Quoted Runs Tests
; DESCRIPTION:
; The document lexer takes the text of a one-line string in one native search
; instead of one character at a time. It must still return what the plain lexer
; below returned, for every token, cursor, span and refusal.
; ==============================================================================

#Requires AutoHotkey v2.0

; The lexer as it was before toml-quoted-runs-2026-11-03: the oracle.
_TDQ_PlainToken(Text, &Position, Separator, &Separated := 0, &SpanStart := 0, &SpanEnd := 0, StopAfterContainer := false) {
	Separated := false
	SpanStart := 0, SpanEnd := 0
	Result := "", Quote := "", Closers := [], Length := StrLen(Text)
	Needle := StrLen(Separator) == 1 ? _TOML_DocumentRunNeedle(Separator) : ""
	while Position <= Length {
		if Needle != "" && Quote == "" && Type(Position) == "Integer" && Position > 0 {
			Stop := RegExMatch(Text, Needle, , Position)
			Stop := Stop ? Stop : Length + 1
			if Stop > Position {
				UnquotedRun := SubStr(Text, Position, Stop - Position)
				Solid := RTrim(UnquotedRun, " `t`r`n")
				if Solid != "" {
					if !SpanStart
						SpanStart := Position + RegExMatch(UnquotedRun, "[^ `t`r`n]") - 1
					SpanEnd := Position + StrLen(Solid) - 1
				}
				Result .= UnquotedRun
				Position := Stop
				continue
			}
		}
		Char := SubStr(Text, Position, 1)
		Triple := SubStr(Text, Position, 3)
		if Quote != "" || (Char != "#" && !InStr(" `t`r`n", Char)
				&& (Char != Separator || Closers.Length)) {
			if !SpanStart
				SpanStart := Position
			SpanEnd := Position
		}
		if Quote != "" {
			if StrLen(Quote) == 3 && Triple == Quote {
				QuoteRun := 3
				while SubStr(Text, Position + QuoteRun, 1) == Char
					QuoteRun += 1
				if QuoteRun > 5
					throw ValueError("Invalid TOML multiline string closure")
				SpanEnd := Position + QuoteRun - 1
				Result .= SubStr(Text, Position, QuoteRun)
				Position += QuoteRun
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
			if Type(Position) == "Integer" && Position > 0
					&& (CommentNewline := InStr(Text, Chr(10), true, Position))
				Position := CommentNewline
			else {
				while Position <= Length && SubStr(Text, Position, 1) != Chr(10)
					Position += 1
			}
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

; Every token of Text, one per call as the document reader cuts it, as a text
; trace: token, cursor, separation and span, or the refusal that ended it.
_TDQ_Trace(Lexer, Text, Separator, StopAfterContainer) {
	Trace := "", Position := 1, Calls := 0
	while Position <= StrLen(Text) && Calls < 200 {
		Calls += 1
		try {
			Token := Lexer.Call(Text, &Position, Separator, &Separated, &SpanStart, &SpanEnd, StopAfterContainer)
			Trace .= "[" . Token . "]@" . Position . "/" . Separated . "/" . SpanStart . "-" . SpanEnd . "`n"
		} catch ValueError as Err {
			return Trace . "refused: " . Err.Message
		}
	}
	return Trace
}

_TDQ_AssertSame(Text, Label) {
	for Separator in [Chr(10), "=", ",", "."] {
		for StopAfterContainer in [false, true] {
			AssertEqual(_TDQ_Trace(_TDQ_PlainToken, Text, Separator, StopAfterContainer),
				_TDQ_Trace(_TOML_DocumentToken, Text, Separator, StopAfterContainer),
				Label . " (separator " . Ord(Separator) . ", stop " . StopAfterContainer . ")")
		}
	}
}

_TDQ_ShapedRecordsMatch() {
	Q := Chr(34)
	for Text in [
		Q . "@am★" . Q . " = { output = " . Q . "adrien@x.fr" . Q . ", is_word = true }`n",
		"key = " . Q . "a\" . Q . "b\\c\u00e9" . Q . " # " . Q . "comment" . Q . "`n",
		"key = 'C:\path\to\" . Q . "x" . Q . "' # tail`n",
		"key = " . Q . "unterminated`nnext = 1`n",
		"key = " . Q . "carriage`rreturn" . Q . "`n",
		"key = 'literal`nbreak'`n",
		"key = " . Q . Q . Q . "multi`n" . Q . "line" . Q . Q . Q . Q . "`n",
		"key = '''multi`n'line''''`n",
		"key = [" . Q . "a,b" . Q . ", 'c=d', { x = " . Q . "}" . Q . " }]`n",
		"O'Brien = " . Q . "it's" . Q . "`n",
		Q . Q . " = " . Q . Q . "`n",
		"key = " . Q . "ends with backslash\" . Q,
		"key = " . Q . "trailing\",
		Q . "a.b" . Q . "." . Q . "c" . Q . " = 1`n"
	]
		_TDQ_AssertSame(Text, "shaped record " . A_Index)
}
Test("TOML document: quoted runs keep every token, cursor, span and refusal (toml-quoted-runs-2026-11-03)",
	_TDQ_ShapedRecordsMatch)

_TDQ_RandomRecordsMatch() {
	Alphabet := [Chr(34), Chr(34), "'", "\", "#", "[", "]", "{", "}", "=", ",", ".", " ", "`t",
		"`r", "`n", "a", "b", "é", "★", Chr(34) . Chr(34) . Chr(34), "'''"]
	Seed := 20261103
	loop 600 {
		Text := ""
		loop Mod(A_Index, 37) + 1 {
			Seed := Mod(Seed * 1103515245 + 12345, 2147483648)
			Text .= Alphabet[Mod(Seed // 65536, Alphabet.Length) + 1]
		}
		_TDQ_AssertSame(Text, "random record " . A_Index . " " . Text)
	}
}
Test("TOML document: quoted runs match the plain lexer on generated records (toml-quoted-runs-2026-11-03)",
	_TDQ_RandomRecordsMatch)
