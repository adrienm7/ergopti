; infra/program_parameter.ahk

/**
 * Decodes executable/argv data using the native JSON string owner. The narrow
 * structural scan rejects duplicate keys, NUL and Boolean versions before the
 * generic Map/Array parser can erase those distinctions.
 * @param {Any} Value Persisted scalar JSON.
 * @returns {Map|false} Detached executable and literal argument vector.
 */
ProgramParameterParse(Value) {
	return _ProgramParameterParseWithStage(Value)
}

; Only fixed stage names leave this decoder; no input or exception text is diagnostic data.
_ProgramParameterParseWithStage(Value, &Stage := unset) {
	Stage := "input-type"
	if Type(Value) != "String"
		return false
	try {
		Stage := "object-open"
		Position := 1
		_ProgramParameterWs(Value, &Position)
		if SubStr(Value, Position++, 1) != "{"
			return false
		Stage := "object-map"
		Data := Map()
		Stage := "object-case"
		Data.CaseSense := "On"
		loop {
			Stage := "member-key"
			Key := _ProgramParameterString(Value, &Position)
			if Type(Key) != "String" || Data.Has(Key)
				|| !(Key == "version" || Key == "executable" || Key == "arguments")
				return false
			Stage := "member-colon"
			_ProgramParameterWs(Value, &Position)
			if SubStr(Value, Position++, 1) != ":"
				return false
			_ProgramParameterWs(Value, &Position)
			switch Key {
				case "version":
					Stage := "version-token"
					if !RegExMatch(SubStr(Value, Position), "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", &Token)
						return false
					Stage := "version-number"
					Data[Key] := JsonParse(Token[0])
					Stage := "version-value"
					if Data[Key] != 1
						return false
					Position += StrLen(Token[0])
				case "executable":
					Stage := "executable-string"
					Data[Key] := _ProgramParameterString(Value, &Position)
					if Type(Data[Key]) != "String" || Data[Key] = ""
						return false
				case "arguments":
					Stage := "arguments-open"
					if SubStr(Value, Position++, 1) != "["
						return false
					Stage := "arguments-array"
					Arguments := []
					_ProgramParameterWs(Value, &Position)
					if SubStr(Value, Position, 1) != "]" {
						loop {
							Stage := "argument-string"
							Argument := _ProgramParameterString(Value, &Position)
							if Type(Argument) != "String"
								return false
							Stage := "argument-push"
							Arguments.Push(Argument)
							_ProgramParameterWs(Value, &Position)
							if SubStr(Value, Position, 1) != ","
								break
							Position++
						}
					}
					Stage := "arguments-close"
					if SubStr(Value, Position++, 1) != "]"
						return false
					Data[Key] := Arguments
				default:
					return false
			}
			Stage := "member-separator"
			_ProgramParameterWs(Value, &Position)
			if SubStr(Value, Position, 1) != ","
				break
			Position++
		}
		Stage := "object-close-count"
		if SubStr(Value, Position++, 1) != "}" || Data.Count != 3
			return false
		Stage := "object-trailing"
		_ProgramParameterWs(Value, &Position)
		if Position <= StrLen(Value)
			return false
		Stage := "executable-path"
		Executable := Data["executable"]
		if !RegExMatch(Executable, "^[A-Za-z]:[/\\]") && !RegExMatch(Executable, "^\\\\[^\\/]+\\[^\\/]+\\.")
			return false
		Stage := "device-path"
		if RegExMatch(Executable, "^\\\\[?.]\\")
			return false
		Stage := "done"
		return Map("executable", Executable, "arguments", Data["arguments"])
	} catch as Err {
		; Classify only a finite set of native exception types, never their messages.
		Kind := Type(Err)
		if !(Kind == "Error" || Kind == "TypeError" || Kind == "ValueError"
			|| Kind == "UnsetError" || Kind == "PropertyError" || Kind == "MethodError"
			|| Kind == "IndexError" || Kind == "TargetError" || Kind == "MemoryError"
			|| Kind == "OSError")
			Kind := "other"
		Stage .= ":" . Kind
		return false
	}
}

_ProgramParameterWs(Value, &Position) {
	while Position <= StrLen(Value) && InStr(" `t`r`n", SubStr(Value, Position, 1))
		Position++
}

_ProgramParameterString(Value, &Position) {
	_ProgramParameterWs(Value, &Position)
	if SubStr(Value, Position, 1) != '"'
		return false
	Start := Position
	; Reuse the canonical lossless JSON string lexer and its exact cursor.
	; The raw span remains authoritative for NUL that native strings truncate.
	Decoded := _JsonParseString(&Value, &Position)
	Raw := SubStr(Value, Start, Position - Start)
	Index := 2
	while Index < StrLen(Raw) {
		if SubStr(Raw, Index, 1) = "\" {
			if SubStr(Raw, Index + 1, 5) == "u0000"
				return false
			Index += 2
		} else
			Index++
	}
	Index := 0
	while Index < StrLen(Decoded) {
		Unit := NumGet(StrPtr(Decoded), Index * 2, "UShort")
		if Unit >= 0xD800 && Unit <= 0xDBFF {
			Index++
			if Index >= StrLen(Decoded)
				return false
			Low := NumGet(StrPtr(Decoded), Index * 2, "UShort")
			if Low < 0xDC00 || Low > 0xDFFF
				return false
		} else if Unit >= 0xDC00 && Unit <= 0xDFFF
			return false
		Index++
	}
	return Decoded
}
