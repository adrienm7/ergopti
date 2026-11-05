#Requires AutoHotkey v2.0+
#NoTrayIcon
#SingleInstance Off
; UNEXECUTED on Linux. Exact production assembly functions; registration is a recording seam only.
; No clipboard, native key send, GUI or real values.
global Records := Map()
global ScriptInformation := Map("MagicKey", Chr(0x2605))
global PersonalInformation := Map("last_name", "LEFT", "first_name", "RIGHT")
global PersonalInformationLetters := Map("n", "last_name", "p", "first_name")
global PERSONAL_INFO_TAGS := Map()
global PI_PREVIEW_MAX_TAG_LEN := 12
global PI_PREVIEW_CATEGORY := "personal"
global HSE_Buffer := ""
global HSE_Suppressed := false
global HSE_RebuildInProgress := false
global HSE_RegistryTransitionDepth := 0
global HSE_PersonalInfoCombosEnabled := true
CreateHotstring(Flags, Trigger, Replacement, Options) {
 global Records
 Records[Trigger] := {Replacement: Replacement, Options: Options}
}

		GeneratePersonalInformationHotstrings(
			PersonalInformationHotstrings,
			PersonalInformationLetters,
			Features["hotstrings"]["dynamic"][ConfigLeaf.TEXT_EXPANSION_PERSONAL_INFORMATION][ConfigLeaf.PATTERN_MAX_LENGTH]
		)

		GeneratePersonalInformationHotstrings(hotstrings, fieldsByLetter, maxLen) {
			keys := []
			; ``hotstrings`` is a Map keyed by the alias LETTER (n, t, …); the combo
			; generator needs those keys, not the personal-data values. The 2-var Map
			; enumerator binds (key, value), so iterate `k, _` and push the KEY -- a
			; mechanical `for _, k` rewrite once seeded the values here and killed every
			; @<letter> combo (a Map is not an Array)
			for k, _ in hotstrings
				keys.Push(k)
			loop maxLen
				Generate(keys, hotstrings, fieldsByLetter, "", A_Index)
		}

		EscapeSpecialChars(text) {
			return SendEscapeLiteral(text)
		}

		Generate(keys, hotstrings, fieldsByLetter, combo, len) {
			if (len == 0) {
				value := ""
				PreviewFields := []
				PreviewValues := []
				loop parse, combo {
					if (hotstrings.Has(A_LoopField) and fieldsByLetter.Has(A_LoopField)) {
						if (value != "") {
							value := value . "{Tab}"
						}

						value := value . hotstrings[A_LoopField]
						PreviewFields.Push(fieldsByLetter[A_LoopField])
						PreviewValues.Push(hotstrings[A_LoopField])
					}
				}
				if (value != "") {
					CreateHotstringCombo(combo, EscapeSpecialChars(value),
						PreviewFields, PreviewValues)
				}
				return
			}
			for _, key in keys {
				Generate(keys, hotstrings, fieldsByLetter, combo . key, len - 1)
			}
		}

		CreateHotstringCombo(combo, value, PreviewFields, PreviewValues) {
			CreateHotstring("*", "@" combo "" . ScriptInformation["MagicKey"], value, Map("OnlyText", False).Set(
				"FinalResult", True).Set("IsPrivate", True)
				.Set("Category", "personal")
				.Set("PreviewFields", PreviewFields).Set("PreviewValues", PreviewValues))
		}
SendEscapeLiteral(Text) {
	Escaped := ""
	loop parse, Text {
		Ch := A_LoopField
		if (Ch == "{")
			Escaped .= "{{}"
		else if (Ch == "}")
			Escaped .= "{}}"
		else
			Escaped .= Ch
	}
	; Asc-form for ^ and ~ because "{^}" is not a valid Send key name.
	Escaped := StrReplace(Escaped, "^", "{Asc 94}")
	Escaped := StrReplace(Escaped, "~", "{Asc 126}")
	Escaped := StrReplace(Escaped, "+", "{+}")
	Escaped := StrReplace(Escaped, "!", "{!}")
	Escaped := StrReplace(Escaped, "#", "{#}")
	return Escaped
}
_PIPreviewIsTagChar(Ch) {
	if (Ch == "") {
		return false
	}
	return (StrLower(Ch) !== StrUpper(Ch))
}

_PIPreviewTrailingTag(Buffer) {
	global PI_PREVIEW_MAX_TAG_LEN
	Len := StrLen(Buffer)
	I := Len
	Steps := 0
	while (I >= 1 and Steps <= PI_PREVIEW_MAX_TAG_LEN) {
		Ch := SubStr(Buffer, I, 1)
		if (Ch == "@") {
			; "@" with nothing after it is not a tag yet.
			return (I == Len) ? "" : SubStr(Buffer, I + 1)
		}
		if !_PIPreviewIsTagChar(Ch) {
			return ""
		}
		I -= 1
		Steps += 1
	}
	return ""
}

_PIPreviewFieldsForTag(Tag) {
	global PERSONAL_INFO_TAGS, PersonalInformationLetters
	Fields := []
	if (Tag == "") {
		return Fields
	}
	Key := StrLower(Tag)
	if (IsSet(PERSONAL_INFO_TAGS) and PERSONAL_INFO_TAGS.Has(Key)) {
		Fields.Push(PERSONAL_INFO_TAGS[Key])
		return Fields
	}
	if !IsSet(PersonalInformationLetters) {
		return Fields
	}
	Loop Parse, Key {
		; One unknown letter means the tag is not a combo at all. Returning the
		; letters that DID resolve would preview a partial expansion the engine
		; never registered.
		if !PersonalInformationLetters.Has(A_LoopField) {
			return []
		}
		Fields.Push(PersonalInformationLetters[A_LoopField])
	}
	return Fields
}
HSE_TryPersonalInfoCombo(MagicKey) {
		global HSE_Buffer, HSE_Suppressed, HSE_RebuildInProgress, HSE_RegistryTransitionDepth
		global HSE_PersonalInfoCombosEnabled, PersonalInformation, PI_PREVIEW_CATEGORY
		; Same live-rebuild fence as HSE_TryRepeatKey: while the registry is being
		; rewritten the matcher answers "" for every sequence, which means "cannot
		; answer now", not "nothing claims this". Expanding here during that window
		; would beat a registered tag that is about to come back.
		if (HSE_RebuildInProgress or HSE_RegistryTransitionDepth > 0
				or HSE_Suppressed or !HSE_PersonalInfoCombosEnabled) {
				return ""
		}
		MkLen := StrLen(MagicKey)
		BufLen := StrLen(HSE_Buffer)
		if (MkLen == 0 or BufLen <= MkLen) {
				return ""
		}
		if (SubStr(HSE_Buffer, -MkLen) !== MagicKey) {
				return ""
		}
		; The tag walker reads a buffer that ENDS at the tag, so hand it the buffer
		; with the magic key removed.
		Body := SubStr(HSE_Buffer, 1, BufLen - MkLen)
		Tag := _PIPreviewTrailingTag(Body)
		if (Tag == "") {
				return ""
		}
		Fields := _PIPreviewFieldsForTag(Tag)
		if (Fields.Length == 0) {
				return ""
		}
		; A Tab between fields: the values land in consecutive form fields, which is
		; what a multi-field combo is for.
		Replacement := ""
		PreviewValues := []
		for Index, Field in Fields {
				; An alias pointing at a field the user has not filled in must decline
				; the whole combo rather than expand a shorter one — a partial expansion
				; is silently wrong in a form, where the remaining fields shift up.
				if (!IsSet(PersonalInformation) or !PersonalInformation.Has(Field)) {
						return ""
				}
				Value := PersonalInformation[Field]
				if (Value == "") {
						return ""
				}
				PreviewValues.Push(Value)
				if (Index > 1) {
						Replacement .= "{Tab}"
				}
				Replacement .= SendEscapeLiteral(Value)
		}
		TriggerStr := "@" . Tag . MagicKey
		; IsPrivate is not optional here: every field this resolver can reach comes
		; from personal_info.toml, so the replacement is by construction the user's
		; own data and must not reach the metrics row or the fire trace.
		; FinalResult routes the send through SendFinalResult (SendInput), which is
		; what every other @ registration uses — measured, it is the path the
		; keystats's InputHook does not observe.
		return {
				Trigger:     TriggerStr,
				Length:      StrLen(TriggerStr),
				Star:        true,
				InWord:      true,
				Replacement: Replacement,
				OnlyText:    false,
				FinalResult: true,
				IsPrivate:   true,
				TransientKind: "personal_combo",
				PreviewFields:  Fields.Clone(),
				PreviewValues:  PreviewValues,
				Category:    IsSet(PI_PREVIEW_CATEGORY) ? PI_PREVIEW_CATEGORY : "personal"
		}
}
MK := ScriptInformation["MagicKey"]
GeneratePersonalInformationHotstrings(Map("n", "LEFT", "p", "RIGHT"), PersonalInformationLetters, 2)
Registered := Records["@np" . MK]
HSE_Buffer := "@np" . MK
Transient := HSE_TryPersonalInfoCombo(MK)
if Registered.Replacement != "LEFT{{}Tab{}}RIGHT"
 throw Error("Baseline: expected actual eager owner to escape the separator braces")
if !IsObject(Transient) || Transient.Replacement != "LEFT{Tab}RIGHT"
 throw Error("Healthy transient control did not retain a real Tab command")
Records.Clear()
PersonalInformation["last_name"] := ""
GeneratePersonalInformationHotstrings(Map("n", "", "p", "RIGHT"), PersonalInformationLetters, 2)
if !Records.Has("@np" . MK) || Records["@np" . MK].Replacement != "RIGHT"
 throw Error("Baseline: expected actual eager owner to admit the partial identity")
HSE_Buffer := "@np" . MK
if HSE_TryPersonalInfoCombo(MK) != ""
 throw Error("Healthy transient empty-field control must decline whole combo")
FileAppend("REPRODUCED production eager-owner separator/empty mismatch; transient healthy controls passed; no native receiving." . Chr(10), "*")
ExitApp(0)
