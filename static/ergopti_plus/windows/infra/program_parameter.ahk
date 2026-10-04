; infra/program_parameter.ahk

/**
 * Decodes executable/argv data using the native JSON string owner. The narrow
 * structural scan rejects duplicate keys, NUL and Boolean versions before the
 * generic Map/Array parser can erase those distinctions.
 * @param {Any} Value Persisted scalar JSON.
 * @returns {Map|false} Detached executable and literal argument vector.
 */
ProgramParameterParse(Value) {
	if Type(Value) != "String"
		return false
	try {
		Position := 1
		_ProgramParameterWs(Value, &Position)
		if SubStr(Value, Position++, 1) != "{"
			return false
		Data := Map()
		Data.CaseSense := "On"
		loop {
			Key := _ProgramParameterString(Value, &Position)
			if Type(Key) != "String" || Data.Has(Key)
				|| !(Key == "version" || Key == "executable" || Key == "arguments")
				return false
			_ProgramParameterWs(Value, &Position)
			if SubStr(Value, Position++, 1) != ":"
				return false
			_ProgramParameterWs(Value, &Position)
			switch Key {
				case "version":
					if !RegExMatch(SubStr(Value, Position), "^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", &Token)
						return false
					Data[Key] := JsonParse(Token[0])
					if Data[Key] != 1
						return false
					Position += StrLen(Token[0])
				case "executable":
					Data[Key] := _ProgramParameterString(Value, &Position)
					if Type(Data[Key]) != "String" || Data[Key] = ""
						return false
				case "arguments":
					if SubStr(Value, Position++, 1) != "["
						return false
					Arguments := []
					_ProgramParameterWs(Value, &Position)
					if SubStr(Value, Position, 1) != "]" {
						loop {
							Argument := _ProgramParameterString(Value, &Position)
							if Type(Argument) != "String"
								return false
							Arguments.Push(Argument)
							_ProgramParameterWs(Value, &Position)
							if SubStr(Value, Position, 1) != ","
								break
							Position++
						}
					}
					if SubStr(Value, Position++, 1) != "]"
						return false
					Data[Key] := Arguments
				default:
					return false
			}
			_ProgramParameterWs(Value, &Position)
			if SubStr(Value, Position, 1) != ","
				break
			Position++
		}
		if SubStr(Value, Position++, 1) != "}" || Data.Count != 3
			return false
		_ProgramParameterWs(Value, &Position)
		if Position <= StrLen(Value)
			return false
		Executable := Data["executable"]
		if !RegExMatch(Executable, "^[A-Za-z]:[/\\]") && !RegExMatch(Executable, "^\\\\[^\\/]+\\[^\\/]+\\.")
			return false
		if RegExMatch(Executable, "^\\\\[?.]\\")
			return false
		return Map("executable", Executable, "arguments", Data["arguments"])
	} catch {
		return false
	}
}

_ProgramParameterWs(Value, &Position) {
	while InStr(" `t`r`n", SubStr(Value, Position, 1)) && Position <= StrLen(Value)
		Position++
}

_ProgramParameterString(Value, &Position) {
	_ProgramParameterWs(Value, &Position)
	if !RegExMatch(SubStr(Value, Position), '^"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*"', &Token)
		return false
	Raw := Token[0]
	Index := 2
	while Index < StrLen(Raw) {
		if SubStr(Raw, Index, 1) = "\" {
			if SubStr(Raw, Index + 1, 5) == "u0000"
				return false
			Index += 2
		} else
			Index++
	}
	Position += StrLen(Raw)
	Decoded := JsonParse(Raw)
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
