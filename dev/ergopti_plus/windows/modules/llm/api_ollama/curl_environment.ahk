; modules/llm/api_ollama/curl_environment.ahk

; ==============================================================================
; MODULE: Curl Child Environment
; DESCRIPTION:
; Builds a private Unicode environment for native curl command launches without
; mutating parent variables or exposing literal paths to shell expansion.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLM_CurlBuildEnvironment(Overrides) {
	if !(Overrides is Map)
		throw TypeError("Curl environment overrides must be a Map.")
	Values := Map()
	Values.CaseSense := "Off"
	EnvironmentPtr := DllCall("Kernel32\GetEnvironmentStringsW", "Ptr")
	if !EnvironmentPtr
		throw OSError(A_LastError)
	try {
		Cursor := EnvironmentPtr
		while NumGet(Cursor, 0, "UShort") {
			Entry := StrGet(Cursor, "UTF-16")
			Cursor += (StrLen(Entry) + 1) * 2
			; Hidden drive-current-directory entries start with '=' and must survive.
			Separator := InStr(Entry, "=", true, 2)
			if !Separator
				throw Error("The inherited environment contains an invalid entry.")
			Name := SubStr(Entry, 1, Separator - 1)
			; An inherited ERRORLEVEL masks cmd's dynamic process status.
			if StrLower(Name) != "errorlevel"
				Values[Name] := SubStr(Entry, Separator + 1)
		}
	} finally DllCall("Kernel32\FreeEnvironmentStringsW", "Ptr", EnvironmentPtr)
	for Name, Value in Overrides {
		if !(Name is String) or Name == "" or InStr(Name, "=") or !(Value is String)
			throw TypeError("Curl environment entries require valid names and string values.")
		if StrLower(Name) == "errorlevel"
			throw ValueError("Curl environment overrides must not shadow the process exit status.")
		Values[Name] := Value
	}
	; Native environment blocks use case-insensitive ordinal ordering. Sort keys
	; without a text delimiter, since inherited names and values may contain one.
	Names := []
	CharacterCount := 1
	for Name, Value in Values {
		Low := 1
		High := Names.Length
		while Low <= High {
			Middle := (Low + High) // 2
			Comparison := DllCall("Kernel32\CompareStringOrdinal", "Str", Name, "Int", -1,
				"Str", Names[Middle], "Int", -1, "Int", true, "Int")
			if !Comparison
				throw OSError(A_LastError)
			if Comparison == 1
				High := Middle - 1
			else
				Low := Middle + 1
		}
		Names.InsertAt(Low, Name)
		CharacterCount += StrLen(Name) + StrLen(Value) + 2
	}
	; Each entry includes its own NUL; the zero-filled tail supplies the second.
	Result := Buffer(Max(2, CharacterCount) * 2, 0)
	Offset := 0
	for Name in Names {
		Entry := Name . "=" . Values[Name]
		StrPut(Entry, Result.Ptr + Offset, StrLen(Entry) + 1, "UTF-16")
		Offset += (StrLen(Entry) + 1) * 2
	}
	return Result
}
