; static/drivers/autohotkey/lib/hotstrings.ahk

; ==============================================================================
; MODULE: Hotstrings
; DESCRIPTION:
; Loads all hotstring categories: distances reduction (QU, dead-key Ê,
; CommaJ, CommaFarLetters), SFBs reduction, rolls, autocorrection, and
; text expansion (personal info, date, magic key, emojis, symbols, repeat).
; ==============================================================================




; =====================================================
; =====================================================
; ======= 1/ REDUCTION OF DISTANCES AND SFBs =======
; =====================================================
; =====================================================


; ===================================================
; ===== 1.1) Q becomes QU if a vowel is after =====
; ===================================================

if Features["DistancesReduction"]["QU"].Enabled {
	LoadHotstringsSection("distancesreduction", "qu", Features["DistancesReduction"]["QU"])
}


; ================================================
; ===== 1.2) Ê acts like a deadkey =====
; ================================================

if Features["DistancesReduction"]["DeadKeyECircumflex"].Enabled {
	DeadkeyMappingCircumflexModified := DeadkeyMappingCircumflex.Clone()
	for Vowel in ["a", "à", "i", "o", "u", "s"] {
		; We specify the result with the vowels first to be sure it will override any problems
		CreateCaseSensitiveHotstrings(
			"*?", "ê" . Vowel, DeadkeyMappingCircumflex[Vowel],
			Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
			)
		)
		; Necessary for things to work, as we define them already
		DeadkeyMappingCircumflexModified.Delete(Vowel)
	}
	DeadkeyMappingCircumflexModified.Delete("e") ; For the rolling "êe" that gives "œ"
	DeadkeyMappingCircumflexModified.Delete("t") ; To be able to type "être"

	; The "Ê" key will enable to use the other symbols on the layer if we aren't inside a word
	for MapKey, MappedValue in DeadkeyMappingCircumflexModified {
		CreateDeadkeyHotstring(MapKey, MappedValue)
	}

	CreateDeadkeyHotstring(MapKey, MappedValue) {
		; We only activate the deadkey if it is the start of a new word, as symbols aren't put in words
		; This condition corrects problems such as writing "même" that give "mê⁂e"
		Combination := "ê" . MapKey
		Hotstring(
			":*?CB0:" . Combination,
			(*) => ShouldActivateDeadkey(Combination, MappedValue)
		)
	}

	ShouldActivateDeadkey(Combination, MappedValue) {
		if not IsTimeActivationExpired(GetLastSentCharacterAt(-2), Features["DistancesReduction"][
			"DeadKeyECircumflex"]
		.TimeActivationSeconds
		) {
			; We only activate the deadkey if it is the start of a new word, as symbols aren't put in words
			; This condition corrects problems such as writing "même" that give "mê⁂e"
			; We could simply have removed the "?" flag in the Hotstring definition, but we want to get the symbols also if we are typing numbers.
			; For example to write 01/02 by using the / on the deadkey.
			if (GetLastSentCharacterAt(-3) ~= "^[^A-Za-z★]$") { ; Everything except a letter
				; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
				SendNewResult("{BackSpace 2}", Map("OnlyText", False))
				SendNewResult(MappedValue)
			} else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
				SendNewResult("{BackSpace 2}", Map("OnlyText", False))
				SendNewResult(MappedValue)
			}
		}
	}
}

if Features["DistancesReduction"]["ECircumflexE"].Enabled {
	LoadHotstringsSection("distancesreduction", "ecircumflexe", Features["DistancesReduction"]["ECircumflexE"])
}


; ========================================================
; ===== 1.3) Comma becomes a J with the vowels =====
; ========================================================

if Features["DistancesReduction"]["CommaJ"].Enabled {
	CreateCaseSensitiveHotstrings(
		"*?", ",à", "j",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",a", "ja",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",e", "je",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",é", "jé",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",i", "ji",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",o", "jo",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",u", "ju",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",ê", "ju",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", ",'", "j'",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
	; To fix a problem of "J'" for ,'
	CreateHotstring(
		"*?C", ",'", "j'",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
	)
}


; ============================================================================
; ===== 1.4) Comma makes it possible to type letters that are hard to reach =====
; ============================================================================

if Features["DistancesReduction"]["CommaFarLetters"].Enabled {
	; === Top row ===
	CreateCaseSensitiveHotstrings("*?", ",è", "z",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings("*?", ",y", "k",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings("*?", ",c", "ç",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings("*?", ",x", "où" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
	)

	; === Middle row ===
	CreateCaseSensitiveHotstrings("*?", ",s", "q",
		Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
	)
}


; =============================================
; ===== 1.5) SFBs reduction with Comma =====
; =============================================

if Features["SFBsReduction"]["Comma"].Enabled {
	LoadHotstringsSection("sfbsreduction", "comma", Features["SFBsReduction"]["Comma"])
}


; ==========================================
; ===== 1.6) SFBs reduction with Ê =====
; ==========================================

if Features["SFBsReduction"]["ECirc"].Enabled {
	LoadHotstringsSection("sfbsreduction", "ecirc", Features["SFBsReduction"]["ECirc"])
}


; ==========================================
; ===== 1.7) SFBs reduction with È =====
; ==========================================

if Features["SFBsReduction"]["EGrave"].Enabled {
	LoadHotstringsSection("sfbsreduction", "egrave", Features["SFBsReduction"]["EGrave"])
}


; ==========================================
; ===== 1.8) SFBs reduction with À =====
; ==========================================

if Features["SFBsReduction"]["BU"].Enabled and Features["MagicKey"]["TextExpansion"].Enabled {
	; Those hotstrings must be defined before bu, otherwise they won't get activated
	CreateCaseSensitiveHotstrings("*", "il a mà" . ScriptInformation["MagicKey"], "il a mis à jour")
	CreateCaseSensitiveHotstrings("*", "la mà" . ScriptInformation["MagicKey"], "la mise à jour")
	CreateCaseSensitiveHotstrings("*", "ta mà" . ScriptInformation["MagicKey"], "ta mise à jour")
	CreateCaseSensitiveHotstrings("*", "ma mà" . ScriptInformation["MagicKey"], "ma mise à jour")
	CreateCaseSensitiveHotstrings("*?", "e mà" . ScriptInformation["MagicKey"], "e mise à jour")
	CreateCaseSensitiveHotstrings("*?", "es mà" . ScriptInformation["MagicKey"], "es mises à jour")
	CreateCaseSensitiveHotstrings("*", "mà" . ScriptInformation["MagicKey"], "mettre à jour")
	CreateCaseSensitiveHotstrings("*", "mià" . ScriptInformation["MagicKey"], "mise à jour")
	CreateCaseSensitiveHotstrings("*", "pià" . ScriptInformation["MagicKey"], "pièce jointe")
	CreateCaseSensitiveHotstrings("*", "tà" . ScriptInformation["MagicKey"], "toujours")
}
if Features["SFBsReduction"]["IÉ"].Enabled and Features["SFBsReduction"]["BU"].Enabled {
	CreateCaseSensitiveHotstrings(
		; Fix éà★ ➜ ébu insteaf of iéé
		"*?", "ié★", "ébu",
		Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
	)
}
if Features["SFBsReduction"]["BU"].Enabled {
	CreateCaseSensitiveHotstrings(
		"*?", "à★", "bu",
		Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", "àu", "ub",
		Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
	)
}
if Features["SFBsReduction"]["IÉ"].Enabled {
	CreateCaseSensitiveHotstrings(
		"*?", "àé", "éi",
		Map("TimeActivationSeconds", Features["SFBsReduction"]["IÉ"].TimeActivationSeconds)
	)
	CreateCaseSensitiveHotstrings(
		"*?", "éà", "ié",
		Map("TimeActivationSeconds", Features["SFBsReduction"]["IÉ"].TimeActivationSeconds)
	)
}


; ========================
; ========================
; ======= 2/ ROLLS =======
; ========================
; ========================


; ======================================
; ===== 2.1) Rolls on left hand =====
; ======================================

; === Top row ===
if Features["Rolls"]["CloseChevronTag"].Enabled {
	; The original call used flags "*?P" — the "P" flag is lost via TOML
	; extraction but the remaining "*?" still yields the same behavior here
	LoadHotstringsSection("rolls", "closechevrontag", Features["Rolls"]["CloseChevronTag"])
}

; === Middle row ===
if Features["Rolls"]["EZ"].Enabled {
	LoadHotstringsSection("rolls", "ez", Features["Rolls"]["EZ"])
}

; === Bottom row ===
if Features["Rolls"]["Comment"].Enabled {
	LoadHotstringsSection("rolls", "comment", Features["Rolls"]["Comment"])
}


; =======================================
; ===== 2.2) Rolls on right hand =====
; =======================================

; === Top row ===
if Features["Rolls"]["HashtagParenthesis"].Enabled {
	LoadHotstringsSection("rolls", "hashtagparenthesis", Features["Rolls"]["HashtagParenthesis"])
}
if Features["Rolls"]["HashtagBracket"].Enabled {
	LoadHotstringsSection("rolls", "hashtagbracket", Features["Rolls"]["HashtagBracket"])
}
if Features["Rolls"]["HC"].Enabled {
	LoadHotstringsSection("rolls", "hc", Features["Rolls"]["HC"])
}
if Features["Rolls"]["Assign"].Enabled {
	CreateHotstring(
		"*?", " #ç", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", " #!", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "#ç", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "#!", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["NotEqual"].Enabled {
	CreateHotstring(
		"*?", " ç#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", " !#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "ç#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "!#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["SX"].Enabled {
	LoadHotstringsSection("rolls", "sx", Features["Rolls"]["SX"])
}
if Features["Rolls"]["CX"].Enabled {
	LoadHotstringsSection("rolls", "cx", Features["Rolls"]["CX"])
}

; === Middle row ===
if Features["Rolls"]["EqualString"].Enabled {
	CreateHotstring(
		"*?", " [)", SpaceAroundSymbols . "=" . SpaceAroundSymbols . "`"`"{Left}",
		Map("OnlyText", False).Set("TimeActivationSeconds", Features["Rolls"]["EqualString"].TimeActivationSeconds
		)
	)
	CreateHotstring(
		"*?", "[)", SpaceAroundSymbols . "=" . SpaceAroundSymbols . "`"`"{Left}",
		Map("OnlyText", False).Set("TimeActivationSeconds", Features["Rolls"]["EqualString"].TimeActivationSeconds
		)
	)
}
if Features["Rolls"]["EnglishNegation"].Enabled and Features["Autocorrection"]["TypographicApostrophe"].Enabled {
	CreateHotstring(
		"*?", "nt'", "n't",
		Map("TimeActivationSeconds", Features["Rolls"]["EnglishNegation"].TimeActivationSeconds)
	)
} else if Features["Rolls"]["EnglishNegation"].Enabled {
	CreateHotstring(
		"*?", "nt'", "n't",
		Map("TimeActivationSeconds", Features["Rolls"]["EnglishNegation"].TimeActivationSeconds)
	)
}

; === Bottom row ===
if Features["Rolls"]["LeftArrow"].Enabled {
	CreateHotstring(
		"*?", " =+", SpaceAroundSymbols . "➜" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["LeftArrow"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "=+", SpaceAroundSymbols . "➜" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["LeftArrow"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["AssignArrowEqualRight"].Enabled {
	CreateHotstring(
		"*?", " $=", SpaceAroundSymbols . "=>" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualRight"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "$=", SpaceAroundSymbols . "=>" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualRight"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["AssignArrowEqualLeft"].Enabled {
	CreateHotstring(
		"*?", " =$", SpaceAroundSymbols . "<=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualLeft"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "=$", SpaceAroundSymbols . "<=" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualLeft"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["AssignArrowMinusRight"].Enabled {
	CreateHotstring(
		"*?", " +?", SpaceAroundSymbols . "->" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusRight"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "+?", SpaceAroundSymbols . "->" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusRight"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["AssignArrowMinusLeft"].Enabled {
	CreateHotstring(
		"*?", " ?+", SpaceAroundSymbols . "<-" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusLeft"].TimeActivationSeconds)
	)
	CreateHotstring(
		"*?", "?+", SpaceAroundSymbols . "<-" . SpaceAroundSymbols,
		Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusLeft"].TimeActivationSeconds)
	)
}
if Features["Rolls"]["CT"].Enabled {
	LoadHotstringsSection("rolls", "ct", Features["Rolls"]["CT"])
}


; ================================
; ================================
; ======= 3/ AUTOCORRECTION =======
; ================================
; ================================


; ===========================================================================
; ===== 3.1) Automatic conversion of apostrophe into a typographic one =====
; ===========================================================================

if Features["Autocorrection"]["TypographicApostrophe"].Enabled {
	LoadHotstringsSection("autocorrection", "typographicapostrophe", Features["Autocorrection"][
		"TypographicApostrophe"])

	; Create all hotstrings y'a → y'a, y'b → y'b, etc.
	; This prevents false positives like writing ['key'] ➜ ['key']
	for Letter in StrSplit("abcdefghijklmnopqrstuvwxyz") {
		CreateCaseSensitiveHotstrings(
			"*?", "y'" . Letter, "y'" . Letter,
			Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
		)
	}
}


; ============================================
; ===== 3.2) Errors autocorrection =====
; ============================================

if Features["Autocorrection"]["Errors"].Enabled {
	LoadHotstringsSection("autocorrection", "errors", Features["Autocorrection"]["Errors"])
}

if Features["Autocorrection"]["OU"].Enabled {
	LoadHotstringsSection("autocorrection", "ou", Features["Autocorrection"]["OU"])
}

if Features["Autocorrection"]["MultiplePunctuationMarks"].Enabled {
	LoadHotstringsSection("autocorrection", "multiplepunctuationmarks", Features["Autocorrection"][
		"MultiplePunctuationMarks"])

	; We can't use the TimeActivationSeconds here, as previous character = current character = "."
	Hotstring(
		":*?B0:" . "...",
		; Needs to be activated only after a word, otherwise can cause problem in code, like in js: [...a, ...b]
		(*) => GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$" ?
			SendNewResult("{BackSpace 3}…", Map("OnlyText", False)) : ""
	)
}

if Features["Autocorrection"]["SuffixesAChaining"].Enabled {
	LoadHotstringsSection("autocorrection", "suffixesachaining", Features["Autocorrection"]["SuffixesAChaining"])
}


; =============================================
; ===== 3.3) Add minus sign automatically =====
; =============================================

if Features["Autocorrection"]["Minus"].Enabled {
	LoadHotstringsSection("autocorrection", "minus", Features["Autocorrection"]["Minus"])
}

if Features["Autocorrection"]["MinusApostrophe"].Enabled {
	LoadHotstringsSection("autocorrection", "minusapostrophe", Features["Autocorrection"]["MinusApostrophe"])
}


; ====================================================================
; ===== 3.3.1) Phone number & social security auto-complete =====
; ====================================================================

if Features["Autocorrection"]["PhoneNumberAutoComplete"].Enabled {
	CreateHotstring("*", "+33" . SubStr(PersonalInformation["PhoneNumber"], 1, 2), "+33" . PersonalInformation[
		"PhoneNumber"]) ; +3306X
	CreateHotstring("*", "+33" . SubStr(PersonalInformation["PhoneNumber"], 2, 3), "+33" . PersonalInformation[
		"PhoneNumber"]) ; +336X
	CreateHotstring("*", SubStr(PersonalInformation["PhoneNumber"], 1, 4), PersonalInformation["PhoneNumber"]) ; 06XX
	CreateHotstring("*", SubStr(PersonalInformation["PhoneNumber"], 2, 5), PersonalInformation["PhoneNumber"]) ; 6XXX

	CreateHotstring("*", SubStr(PersonalInformation["PhoneNumberClean"], 1, 5), PersonalInformation["PhoneNumberClean"]) ; 06 XX
	CreateHotstring("*", SubStr(PersonalInformation["PhoneNumberClean"], 2, 5), SubStr(PersonalInformation[
		"PhoneNumberClean"], 2)) ; 6 XX
	CreateHotstring("*", SubStr(PersonalInformation["SocialSecurityNumber"], 1, 5), PersonalInformation[
		"SocialSecurityNumber"])
}


; ==========================================
; ===== 3.4) Caps autocorrection =====
; ==========================================

if Features["Autocorrection"]["Caps"].Enabled {
	LoadHotstringsSection("autocorrection", "caps", Features["Autocorrection"]["Caps"])

	; For these apps, we only capitalize them when used in context of apps, and not as English words
	apps := ["excel", "teams", "word", "office"]
	prefixes := [
		"avec",
		"dans",
		"en",
		"et",
		"fichier",
		"fichiers",
		"le",
		"mon",
		"sur",
		"son",
		"ton",
	]
	for prefix in prefixes {
		for app in apps {
			from := prefix . " " . app
			to := prefix . " " . Capitalize(app)
			CreateHotstring("", from, to)
		}
	}
	Capitalize(str) {
		return StrUpper(SubStr(str, 1, 1)) . SubStr(str, 2)
	}
}


; ===========================================
; ===== 3.5) Accents autocorrection =====
; ===========================================

if Features["Autocorrection"]["Names"].Enabled {
	LoadHotstringsSection("autocorrection", "names", Features["Autocorrection"]["Names"])
}

if Features["Autocorrection"]["Accents"].Enabled {
	LoadHotstringsSection("autocorrection", "accents", Features["Autocorrection"]["Accents"])
}


; ================================
; ================================
; ======= 4/ TEXT EXPANSION =======
; ================================
; ================================


; ===================================
; ===== 4.1) Suffixes with À =====
; ===================================

if Features["DistancesReduction"]["SuffixesA"].Enabled {
	LoadHotstringsSection("distancesreduction", "suffixesa", Features["DistancesReduction"]["SuffixesA"])
}


; ==============================================================
; ===== 4.2) Personal information shortcuts with @ =====
; ==============================================================

if Features["MagicKey"]["TextExpansionPersonalInformation"].Enabled {
	CreateHotstring("*", "@bic" . ScriptInformation["MagicKey"], PersonalInformation["BIC"], Map("FinalResult",
		True))
	CreateHotstring("*", "@cb" . ScriptInformation["MagicKey"], PersonalInformation["CreditCard"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@cc" . ScriptInformation["MagicKey"], PersonalInformation["CreditCard"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@iban" . ScriptInformation["MagicKey"], PersonalInformation["IBAN"], Map("FinalResult",
		True))
	CreateHotstring("*", "@rib" . ScriptInformation["MagicKey"], PersonalInformation["IBAN"], Map("FinalResult",
		True))
	CreateHotstring("*", "@ss" . ScriptInformation["MagicKey"], PersonalInformation["SocialSecurityNumber"], Map(
		"FinalResult", True))
	CreateHotstring("*", "@tel" . ScriptInformation["MagicKey"], PersonalInformation["PhoneNumber"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@tél" . ScriptInformation["MagicKey"], PersonalInformation["PhoneNumber"], Map(
		"FinalResult",
		True))

	; Map a letter to a value (n ➜ Nom, t ➜ 0606060606, etc.)
	global PersonalInformationHotstrings := Map()
	for InfoKey, InfoValue in PersonalInformationLetters {
		PersonalInformationHotstrings[InfoKey] := PersonalInformation[InfoValue]
	}

	; Generate all possible combinations of letters between 1 and PatternMaxLength characters
	GeneratePersonalInformationHotstrings(
		PersonalInformationHotstrings,
		Features["MagicKey"]["TextExpansionPersonalInformation"].PatternMaxLength
	)

	GeneratePersonalInformationHotstrings(hotstrings, maxLen) {
		keys := []
		for k in hotstrings
			keys.Push(k)
		loop maxLen
			Generate(keys, hotstrings, "", A_Index)
	}

	; In case email is "^a" we want to send raw string and not Ctrl + A
	EscapeSpecialChars(text) {
		text := StrReplace(text, "{", "{{}")
		text := StrReplace(text, "}", "{}}")
		text := StrReplace(text, "^", "{Asc 94}")
		text := StrReplace(text, "~", "{Asc 126}")
		text := StrReplace(text, "+", "{+}")
		text := StrReplace(text, "!", "{!}")
		text := StrReplace(text, "#", "{#}")
		return text
	}

	Generate(keys, hotstrings, combo, len) {
		if (len == 0) {
			value := ""
			loop parse, combo {
				if (hotstrings.Has(A_LoopField)) {
					if (value != "") {
						value := value . "{Tab}"
					}

					value := value . hotstrings[A_LoopField]
				}
			}
			if (value != "") {
				CreateHotstringCombo(combo, EscapeSpecialChars(value))
			}
			return
		}
		for key in keys {
			Generate(keys, hotstrings, combo . key, len - 1)
		}
	}

	CreateHotstringCombo(combo, value) {
		CreateHotstring("*", "@" combo "" . ScriptInformation["MagicKey"], value, Map("OnlyText", False).Set(
			"FinalResult", True))
	}

	; Generate manually longer shortcuts, as increasing PatternMaxLength expands memory exponentially
	CreateHotstringComboAuto(Combo) {
		Value := ""
		loop StrLen(Combo) {
			ComboLetter := SubStr(Combo, A_Index, 1)
			Value := Value . PersonalInformationHotstrings[ComboLetter] . "{Tab}"
		}
		CreateHotstring("*", "@" . Combo . ScriptInformation["MagicKey"], Value, Map("OnlyText", False).Set(
			"FinalResult", True))
	}
	CreateHotstringComboAuto("mm")
	CreateHotstringComboAuto("mnp")
	CreateHotstringComboAuto("mpn")
	CreateHotstringComboAuto("np")
	CreateHotstringComboAuto("npam")
	CreateHotstringComboAuto("npamm")
	CreateHotstringComboAuto("npd")
	CreateHotstringComboAuto("npdm")
	CreateHotstringComboAuto("npdmm")
	CreateHotstringComboAuto("npdmmt")
	CreateHotstringComboAuto("npdmt")
	CreateHotstringComboAuto("npm")
	CreateHotstringComboAuto("npmd")
	CreateHotstringComboAuto("npmm")
	CreateHotstringComboAuto("npmmd")
	CreateHotstringComboAuto("npmt")
	CreateHotstringComboAuto("npt")
	CreateHotstringComboAuto("nptm")
	CreateHotstringComboAuto("nptmm")
	CreateHotstringComboAuto("pn")
	CreateHotstringComboAuto("pnam")
	CreateHotstringComboAuto("pnamm")
	CreateHotstringComboAuto("pnd")
	CreateHotstringComboAuto("pndm")
	CreateHotstringComboAuto("pndmm")
	CreateHotstringComboAuto("pnm")
	CreateHotstringComboAuto("pnmm")
	CreateHotstringComboAuto("pntm")
	CreateHotstringComboAuto("pntmd")
	CreateHotstringComboAuto("pntmm")
	CreateHotstringComboAuto("pntmmd")
}


; ==========================================
; ===== 4.2.1) Date expansion with dt★ =====
; ==========================================

if Features["MagicKey"]["TextExpansionDate"].Enabled {
	MK := ScriptInformation["MagicKey"]
	Abbreviation := "dt" . MK
	Hotstring(":*B0:" . Abbreviation, DateHotstringCallback.Bind(Abbreviation))
	DateHotstringCallback(Abbr, *) {
		SendFinalResult("{BackSpace " . StrLen(Abbr) . "}", Map("OnlyText", False))
		SendFinalResult(FormatTime(, "dd/MM/yyyy"))
	}
}


; ===========================================
; ===== 4.3) Text expansion with ★ =====
; ===========================================

if Features["MagicKey"]["TextExpansion"].Enabled {
	LoadHotstringsSection("magickey", "textexpansion", Features["MagicKey"]["TextExpansion"])
}

if Features["MagicKey"]["TextExpansionAuto"].Enabled {
	LoadHotstringsSection("magickey", "textexpansionauto", Features["MagicKey"]["TextExpansionAuto"])
}


; ==============================
; ===== 4.4) Emojis =====
; ==============================

if Features["MagicKey"]["TextExpansionEmojis"].Enabled {
	LoadHotstringsSection("magickey", "textexpansionemojis", Features["MagicKey"]["TextExpansionEmojis"])
}


; ==============================
; ===== 4.5) Symbols =====
; ==============================

if Features["MagicKey"]["TextExpansionSymbols"].Enabled {
	LoadHotstringsSection("magickey", "textexpansionsymbols", Features["MagicKey"]["TextExpansionSymbols"])
}

if Features["MagicKey"]["TextExpansionSymbolsTypst"].Enabled {
	LoadHotstringsSection("magickey", "textexpansionsymbolstypst", Features["MagicKey"]["TextExpansionSymbolsTypst"],
		Map("OnlyText", False))
}


; ==============================
; ===== 4.6) Repeat key =====
; ==============================

#InputLevel 1 ; Mandatory for this section to work, it needs to be below the inputlevel of the key remappings

; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
; That means a letter will only be repeated if no hotstring defined above matches
if Features["MagicKey"]["Repeat"].Enabled {
	LoadHotstringsSection("magickey", "repeat", Features["MagicKey"]["Repeat"])
}

CreateHotstring("*", "clé" . ScriptInformation["MagicKey"], "🔑")
