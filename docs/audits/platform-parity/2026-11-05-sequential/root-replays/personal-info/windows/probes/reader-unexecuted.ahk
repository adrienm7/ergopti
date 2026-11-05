#Requires AutoHotkey v2.0+
#NoTrayIcon
#SingleInstance Off
; UNEXECUTED. Actual ReadPersonalInfoToml and actual decoding helpers on synthetic artifact files only.
global PersonalInformation := Map("first_name", "PLACEHOLDER")
global PersonalInformationLetters := Map("p", "first_name")
global _ReadPersonalInfoTomlCache := false
global _TomlUnreadableFiles := Map()
global LogCalls := 0
LoggerWarn(Args*) {
 global LogCalls
 LogCalls += 1
}
LoggerError(Args*) {
 global LogCalls
 LogCalls += 1
}
FSStrictExists(Path) => FileExist(Path) != ""
FSReadBytesStrict(Path) => FileRead(Path, "RAW")
UnescapeTomlString(s) {
		return TOML_UnescapeBasicStringContents(s)
}
TOML_UnescapeBasicStringContents(s) {
	s := String(s)
	if !InStr(s, "\")
		return s
	Result := "", i := 1, n := StrLen(s)
	while (i <= n) {
		Char := SubStr(s, i, 1)
		if (Char != "\" || i == n) {
			Result .= Char
			i += 1
			continue
		}
		NextChar := SubStr(s, i + 1, 1)
		switch NextChar {
			case "b": Result .= Chr(8)
			case "t": Result .= "`t"
			case "n": Result .= "`n"
			case "f": Result .= Chr(12)
			case "r": Result .= "`r"
			case '"': Result .= '"'
			case "\": Result .= "\"
			case "u", "U":
				Digits := NextChar == "u" ? 4 : 8
				Hex := SubStr(s, i + 2, Digits)
				if (StrLen(Hex) == Digits && RegExMatch(Hex, "^[0-9A-Fa-f]+$")) {
					Code := Integer("0x" . Hex)
					if (Code == 0 || Code > 0x10FFFF
							|| (Code >= 0xD800 && Code <= 0xDFFF))
						throw ValueError("TOML string contains an unsupported Unicode scalar.")
					Result .= Chr(Code)
					i += 2 + Digits
					continue
				}
				; Preserve the legacy unknown-escape behavior for malformed input.
				Result .= NextChar
			default: Result .= NextChar
		}
		i += 2
	}
	return Result
}
_PersonalInfoDecodeSourceBytes(Bytes) {
	if !(Bytes is Buffer)
		throw TypeError("A personal-information source must be raw bytes.")
	if Bytes.Size == 0
		return ""
	if Bytes.Size >= 2 && NumGet(Bytes, 0, "UChar") == 0xFF && NumGet(Bytes, 1, "UChar") == 0xFE {
		Units := (Bytes.Size - 2) // 2
		return Units ? StrGet(Bytes.Ptr + 2, -Units, "UTF-16") : ""
	}
	Offset := Bytes.Size >= 3 && NumGet(Bytes, 0, "UChar") == 0xEF
		&& NumGet(Bytes, 1, "UChar") == 0xBB && NumGet(Bytes, 2, "UChar") == 0xBF ? 3 : 0
	Length := Bytes.Size - Offset
	return Length ? StrGet(Bytes.Ptr + Offset, -Length, "UTF-8") : ""
}
ReadPersonalInfoToml(FilePath) {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	PreviousCritical := Critical("On")
	try {
		Cache := _ReadPersonalInfoTomlCache
		if Cache is Map && (!Cache.Has("source")
			|| (Cache["source"] is Map && Cache["source"].Get("path", 0) == FilePath)) {
			PersonalInformation := Cache["info"].Clone()
			PersonalInformationLetters := Cache["letters"].Clone()
			return
		}
		; A diagnostic or native read can pump another reader or durable writer.
		; Retain the admitted identities before I/O, not whichever maps a later
		; callback leaves behind when this older parse resumes.
		OpeningInformation := PersonalInformation
		OpeningLetters := PersonalInformationLetters
	} finally Critical(PreviousCritical)
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ReadPersonalInfoToml(FilePath)
		finally Critical(InheritedCritical)
	}

	global _TomlUnreadableFiles
	try {
		if !FSStrictExists(FilePath)
			return
		Bytes := FSReadBytesStrict(FilePath)
		FileContent := _PersonalInfoDecodeSourceBytes(Bytes)
	} catch as e {
		; Latch the failure the way the personal_hotstrings.toml sibling above
		; already does. The placeholder identity left in PersonalInformation
		; ("Prénom", "FR00 0000 …", "1234 5678 9012 3456", "1 99 99 99 999 999
		; 99") is byte-for-byte what a user who never filled the form produces,
		; so WritePersonalInfoToml cannot tell the two apart at write time — and
		; by then the transient lock has cleared, so every write-time re-check
		; would pass. Without the latch, opening the editor once and clicking OK
		; overwrites the user's real IBAN, card number and SSN with the shipped
		; placeholders, unrecoverably.
		PreviousCritical := Critical("On")
		try {
			if PersonalInformation != OpeningInformation || PersonalInformationLetters != OpeningLetters
				|| _ReadPersonalInfoTomlCache != Cache
				return
			if IsSet(_TomlUnreadableFiles)
				_TomlUnreadableFiles[FilePath] := true
		} finally Critical(PreviousCritical)
		LoggerError("hotstrings", "Could not read personal info TOML '{1}': {2}. Writes to this file are blocked so the placeholder identity cannot replace its contents.", FilePath, e.Message)
		return
	}
	; Only the still-current admission may clear an unreadable-source latch.
	PreviousCritical := Critical("On")
	try {
		if PersonalInformation != OpeningInformation || PersonalInformationLetters != OpeningLetters
			|| _ReadPersonalInfoTomlCache != Cache
			return
		if (IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(FilePath))
			_TomlUnreadableFiles.Delete(FilePath)
		NextInformation := OpeningInformation.Clone()
	} finally Critical(PreviousCritical)
	NextLetters := Map()
	SawLetters := false
	FileContent := StrReplace(FileContent, "`r`n", "`n")
	FileContent := StrReplace(FileContent, "`r", "`n")
	CurrentSection := ""

	loop parse, FileContent, "`n" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}
		; Section header
		if RegExMatch(Line, "^\[([a-z_]+)\]$", &HM) {
			CurrentSection := HM[1]
			; An explicit empty section clears aliases; an omitted one keeps defaults.
			if (CurrentSection == "letters")
				SawLetters := true
			continue
		}
		; Key = "value" pair
		if RegExMatch(Line, 'i)^(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
			Key := KM[1]
			Val := UnescapeTomlString(KM[2])
			if (CurrentSection == "info") {
				if NextInformation.Has(Key)
					NextInformation[Key] := Val
			} else if (CurrentSection == "letters") {
				if (StrLen(Key) != 1) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because it is not one character.", Key)
					continue
				}
				if !NextInformation.Has(Val) {
					LoggerWarn("hotstrings", "Ignoring personal-info letter alias '{1}' because '{2}' is not an info key.", Key, Val)
					continue
				}
				if NextLetters.Has(Key) {
					LoggerWarn("hotstrings", "Ignoring duplicate personal-info letter alias '{1}'.", Key)
					continue
				}
				NextLetters[Key] := Val
			}
		}
	}
	PreviousCritical := Critical("On")
	try {
		; Publish maps and their source cache only while this parse still owns
		; the original admission. A completed newer transaction stays authoritative.
		if PersonalInformation != OpeningInformation || PersonalInformationLetters != OpeningLetters
			|| _ReadPersonalInfoTomlCache != Cache
			return
		PersonalInformation := NextInformation
		if SawLetters
			PersonalInformationLetters := NextLetters
		_ReadPersonalInfoTomlCache := Map("info", PersonalInformation.Clone(),
			"letters", PersonalInformationLetters.Clone(),
			"source", Map("admitted", true, "present", true, "bytes", Bytes, "path", FilePath))
	} finally Critical(PreviousCritical)
}

for Case in ["double", "literal", "quoted-key"] {
 PersonalInformation := Map("first_name", "PLACEHOLDER")
 PersonalInformationLetters := Map("p", "first_name")
 _ReadPersonalInfoTomlCache := false
 LogCalls := 0
 Path := A_ScriptDir . "\reader-" . Case . ".toml"
 ReadPersonalInfoToml(Path)
 Expected := Case == "double" ? "SYNTHETIC" : "PLACEHOLDER"
 if PersonalInformation["first_name"] != Expected
  throw Error("Unexpected actual reader result for " . Case)
 if !_ReadPersonalInfoTomlCache["source"]["admitted"]
  throw Error("Actual reader did not publish admitted source")
 if LogCalls != 0 || _TomlUnreadableFiles.Has(Path)
  throw Error("This path unexpectedly diagnosed/latches unsupported valid syntax")
}
FileAppend("REPRODUCED actual reader known-field literal/quoted-key omission with admitted source; healthy double-quoted control; no clipboard/native desktop." . Chr(10), "*")
ExitApp(0)
