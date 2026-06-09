; static/ergopti_plus/windows/modules/hotstrings.ahk

; ==============================================================================
; MODULE: Hotstrings
; DESCRIPTION:
; Loads all hotstring categories: distances reduction (QU, dead-key Ê,
; CommaJ, CommaFarLetters), SFBs reduction, rolls, autocorrection, and
; text expansion (personal info, date, magic key, emojis, symbols, repeat).
; ==============================================================================





; =====================================================
; ==================================================
; ======= 1/ REDUCTION OF DISTANCES AND SFBs =======
; ==================================================
; =====================================================



; =================================================
; ===== 1.1) Q becomes QU if a vowel is after =====
; =================================================

if Features["hotstrings"]["distances_reduction"]["qu"]["enabled"] {
	LoadHotstringsSection("distancesreduction", "qu", Features["hotstrings"]["distances_reduction"]["qu"])
}



; ======================================
; ===== 1.2) Ê acts like a deadkey =====
; ======================================

if Features["hotstrings"]["distances_reduction"]["dead_key_e_circumflex"]["enabled"] {
	DeadkeyMappingCircumflexModified := DeadkeyMappingCircumflex.Clone()
	; Resolve the activation delay once at registration time — the Features
	; object only carries Enabled, the actual delay lives in the TOML metadata.
	DeadKeyECircumflexDelay := HotstringsResolve("distancesreduction", "dead_key_e_circumflex").Delay
	for Vowel in ["a", "à", "i", "o", "u", "s"] {
		; We specify the result with the vowels first to be sure it will override any problems
		CreateCaseSensitiveHotstrings(
			"*?", "ê" . Vowel, DeadkeyMappingCircumflex[Vowel],
			Map("TimeActivationSeconds", DeadKeyECircumflexDelay)
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
		if not IsTimeActivationExpired(GetLastSentCharacterAt(-2), DeadKeyECircumflexDelay) {
			; We only activate the deadkey if it is the start of a new word, as symbols aren't put in words
			; This condition corrects problems such as writing "même" that give "mê⁂e"
			; We could simply have removed the "?" flag in the Hotstring definition, but we want to get the symbols also if we are typing numbers.
			; For example to write 01/02 by using the / on the deadkey.
			if (GetLastSentCharacterAt(-3) ~= "^[^A-Za-z★]$") { ; Everything except a letter
				; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
				SendNewResult("{BackSpace 2}", False)
				SendNewResult(MappedValue)
			} else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
				SendNewResult("{BackSpace 2}", False)
				SendNewResult(MappedValue)
			}
		}
	}
}

if Features["hotstrings"]["distances_reduction"]["e_circumflex_e"]["enabled"] {
	LoadHotstringsSection("distancesreduction", "e_circumflex_e", Features["hotstrings"]["distances_reduction"]["e_circumflex_e"])
}



; ==================================================
; ===== 1.3) Comma becomes a J with the vowels =====
; ==================================================

if Features["hotstrings"]["distances_reduction"]["comma_j"]["enabled"] {
	CommaJOptions := Map("TimeActivationSeconds", HotstringsResolve("distancesreduction", "comma_j").Delay)
	CreateCaseSensitiveHotstrings("*?", ",à", "j", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",a", "ja", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",e", "je", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",é", "jé", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",i", "ji", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",o", "jo", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",u", "ju", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",ê", "ju", CommaJOptions)
	CreateCaseSensitiveHotstrings("*?", ",'", "j'", CommaJOptions)
	; To fix a problem of "J'" for ,'
	CreateHotstring("*?C", ",'", "j'", CommaJOptions)

	; Uppercase-J variants: Shift+SC02F sends nnbsp (U+202F)+; and Shift+SC022
	; sends nnbsp+: on the Ergopti layout; ¨+s produces nbsp (U+00A0). Both act
	; as the "shifted comma" — the Shift capitalises the J, so the lowercase
	; comma "je" becomes "Je". The vowel's own case carries through: a lowercase
	; vowel yields titlecase ("Je"), a Shift-held uppercase vowel yields all-caps
	; ("JE") — case-sensitive triggers are registered for each variant.
	; Registered explicitly here because CreateCaseSensitiveHotstrings cannot
	; handle triggers that contain a terminator character (like : or ;) as an
	; internal part of the trigger — the HSE end-char path would intercept it.
	; These triggers are independent of the nbsp/nnbsp terminator settings.
	_CommaJVowels := Map(
		"à", "J",  "a", "Ja", "e", "Je", "é", "Jé",
		"i", "Ji", "o", "Jo", "u", "Ju", "ê", "Ju",
		"A", "JA", "E", "JE", "É", "JÉ",
		"I", "JI", "O", "JO", "U", "JU", "Ê", "JU", "À", "J",
		Chr(0x27), "J'", Chr(0x2019), "J'"
	)
	; The bare ";" (comma-layer key, un-shifted) is included alongside the
	; nnbsp/nbsp-prefixed forms so the J expansion fires from it too. Like the
	; prefixed forms it uses "*?C" (in-word) — the J is guaranteed regardless of
	; surrounding context (e.g. "test;e" → "testJe"), by deliberate design. The
	; bare ":" is intentionally absent: only ";" doubles as the comma-layer J key.
	for _Vowel, _Output in _CommaJVowels {
		for _Prefix in [Chr(0x202F) Chr(0x3B), Chr(0x202F) ":", Chr(0x00A0) Chr(0x3B), Chr(0x00A0) ":", Chr(0x3B)] {
			CreateHotstring("*?C", _Prefix . _Vowel, _Output, CommaJOptions)
		}
	}
}



; ===============================================================================
; ===== 1.4) Comma makes it possible to type letters that are hard to reach =====
; ===============================================================================

if Features["hotstrings"]["distances_reduction"]["comma_far_letters"]["enabled"] {
	CommaFarOptions := Map("TimeActivationSeconds", HotstringsResolve("distancesreduction", "comma_far_letters").Delay)
	; === Top row ===
	CreateCaseSensitiveHotstrings("*?", ",è", "z", CommaFarOptions)
	CreateCaseSensitiveHotstrings("*?", ",y", "k", CommaFarOptions)
	CreateCaseSensitiveHotstrings("*?", ",c", "ç", CommaFarOptions)
	CreateCaseSensitiveHotstrings("*?", ",x", "où" . SpaceAroundSymbols, CommaFarOptions)

	; === Middle row ===
	CreateCaseSensitiveHotstrings("*?", ",s", "q", CommaFarOptions)
}



; ==========================================
; ===== 1.5) SFBs reduction with Comma =====
; ==========================================

if Features["hotstrings"]["sfbs_reduction"]["comma"]["enabled"] {
	LoadHotstringsSection("sfbsreduction", "comma", Features["hotstrings"]["sfbs_reduction"]["comma"])
}



; ======================================
; ===== 1.6) SFBs reduction with Ê =====
; ======================================

if Features["hotstrings"]["sfbs_reduction"]["e_circ"]["enabled"] {
	LoadHotstringsSection("sfbsreduction", "e_circ", Features["hotstrings"]["sfbs_reduction"]["e_circ"])
}



; ======================================
; ===== 1.7) SFBs reduction with È =====
; ======================================

if Features["hotstrings"]["sfbs_reduction"]["e_grave"]["enabled"] {
	LoadHotstringsSection("sfbsreduction", "e_grave", Features["hotstrings"]["sfbs_reduction"]["e_grave"])
}



; ======================================
; ===== 1.8) SFBs reduction with À =====
; ======================================

if Features["hotstrings"]["sfbs_reduction"]["bu"]["enabled"] and Features["hotstrings"]["magic_key"]["text_expansion"]["enabled"] {
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
if Features["hotstrings"]["sfbs_reduction"]["i_e_acute"]["enabled"] and Features["hotstrings"]["sfbs_reduction"]["bu"]["enabled"] {
	CreateCaseSensitiveHotstrings(
		; Fix éà★ ➜ ébu insteaf of iéé
		"*?", "ié★", "ébu",
		Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "bu").Delay)
	)
}
if Features["hotstrings"]["sfbs_reduction"]["bu"]["enabled"] {
	CreateCaseSensitiveHotstrings(
		"*?", "à★", "bu",
		Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "bu").Delay)
	)
	CreateCaseSensitiveHotstrings(
		"*?", "àu", "ub",
		Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "bu").Delay)
	)
}
if Features["hotstrings"]["sfbs_reduction"]["i_e_acute"]["enabled"] {
	CreateCaseSensitiveHotstrings(
		"*?", "àé", "éi",
		Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "i_e_acute").Delay)
	)
	CreateCaseSensitiveHotstrings(
		"*?", "éà", "ié",
		Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "i_e_acute").Delay)
	)
}





; ========================
; ========================
; ======= 2/ ROLLS =======
; ========================
; ========================



; ===================================
; ===== 2.1) Rolls on left hand =====
; ===================================

; === Top row ===
if Features["hotstrings"]["rolls"]["close_chevron_tag"]["enabled"] {
	; The original call used flags "*?P" — the "P" flag is lost via TOML
	; extraction but the remaining "*?" still yields the same behavior here
	LoadHotstringsSection("rolls", "close_chevron_tag", Features["hotstrings"]["rolls"]["close_chevron_tag"])
}

; === Middle row ===
if Features["hotstrings"]["rolls"]["ez"]["enabled"] {
	LoadHotstringsSection("rolls", "ez", Features["hotstrings"]["rolls"]["ez"])
}

; === Bottom row ===
if Features["hotstrings"]["rolls"]["comment_open"]["enabled"] {
	LoadHotstringsSection("rolls", "comment_open", Features["hotstrings"]["rolls"]["comment_open"])
}
if Features["hotstrings"]["rolls"]["comment_close"]["enabled"] {
	LoadHotstringsSection("rolls", "comment_close", Features["hotstrings"]["rolls"]["comment_close"])
}



; ====================================
; ===== 2.2) Rolls on right hand =====
; ====================================

; === Top row ===
if Features["hotstrings"]["rolls"]["hashtag_parenthesis"]["enabled"] {
	LoadHotstringsSection("rolls", "hashtag_parenthesis", Features["hotstrings"]["rolls"]["hashtag_parenthesis"])
}
if Features["hotstrings"]["rolls"]["hashtag_open_bracket"]["enabled"] {
	LoadHotstringsSection("rolls", "hashtag_open_bracket", Features["hotstrings"]["rolls"]["hashtag_open_bracket"])
}
if Features["hotstrings"]["rolls"]["hashtag_close_bracket"]["enabled"] {
	LoadHotstringsSection("rolls", "hashtag_close_bracket", Features["hotstrings"]["rolls"]["hashtag_close_bracket"])
}
if Features["hotstrings"]["rolls"]["hc"]["enabled"] {
	LoadHotstringsSection("rolls", "hc", Features["hotstrings"]["rolls"]["hc"])
}
if Features["hotstrings"]["rolls"]["assign"]["enabled"] {
	AssignOptions := Map("TimeActivationSeconds", HotstringsResolve("rolls", "assign").Delay)
	AssignReplacement := SpaceAroundSymbols . ":=" . SpaceAroundSymbols
	CreateHotstring("*?", " #ç", AssignReplacement, AssignOptions)
	CreateHotstring("*?", " #!", AssignReplacement, AssignOptions)
	CreateHotstring("*?", "#ç", AssignReplacement, AssignOptions)
	CreateHotstring("*?", "#!", AssignReplacement, AssignOptions)
}
if Features["hotstrings"]["rolls"]["not_equal"]["enabled"] {
	NotEqualOptions := Map("TimeActivationSeconds", HotstringsResolve("rolls", "not_equal").Delay)
	NotEqualReplacement := SpaceAroundSymbols . "!=" . SpaceAroundSymbols
	CreateHotstring("*?", " ç#", NotEqualReplacement, NotEqualOptions)
	CreateHotstring("*?", " !#", NotEqualReplacement, NotEqualOptions)
	CreateHotstring("*?", "ç#", NotEqualReplacement, NotEqualOptions)
	CreateHotstring("*?", "!#", NotEqualReplacement, NotEqualOptions)
}
if Features["hotstrings"]["rolls"]["sx"]["enabled"] {
	LoadHotstringsSection("rolls", "sx", Features["hotstrings"]["rolls"]["sx"])
}
if Features["hotstrings"]["rolls"]["cx"]["enabled"] {
	LoadHotstringsSection("rolls", "cx", Features["hotstrings"]["rolls"]["cx"])
}

; === Middle row ===
if Features["hotstrings"]["rolls"]["equal_string"]["enabled"] {
	EqualStringOpts := Map("OnlyText", False, "TimeActivationSeconds", HotstringsResolve("rolls", "equal_string").Delay)
	EqualStringRepl := SpaceAroundSymbols . "=" . SpaceAroundSymbols . '""{Left}'
	CreateHotstring("*?", " [)", EqualStringRepl, EqualStringOpts)
	CreateHotstring("*?", "[)", EqualStringRepl, EqualStringOpts)
}
if Features["hotstrings"]["rolls"]["english_negation"]["enabled"] {
	; Works identically whether TypographicApostrophe is on or off — the
	; straight apostrophe is converted downstream when relevant.
	CreateHotstring(
		"*?", "nt'", "n't",
		Map("TimeActivationSeconds", HotstringsResolve("rolls", "english_negation").Delay)
	)
}

; === Bottom row ===
; Each operator roll registers two triggers: one with a leading space (so the
; operator fires mid-sentence) and one without (start of expression / line).
if Features["hotstrings"]["rolls"]["left_arrow"]["enabled"] {
	Opts := Map("TimeActivationSeconds", HotstringsResolve("rolls", "left_arrow").Delay)
	Repl := SpaceAroundSymbols . "➜" . SpaceAroundSymbols
	CreateHotstring("*?", " =+", Repl, Opts)
	CreateHotstring("*?", "=+", Repl, Opts)
}
if Features["hotstrings"]["rolls"]["assign_arrow_equal_right"]["enabled"] {
	Opts := Map("TimeActivationSeconds", HotstringsResolve("rolls", "assign_arrow_equal_right").Delay)
	Repl := SpaceAroundSymbols . "=>" . SpaceAroundSymbols
	CreateHotstring("*?", " $=", Repl, Opts)
	CreateHotstring("*?", "$=", Repl, Opts)
}
if Features["hotstrings"]["rolls"]["assign_arrow_equal_left"]["enabled"] {
	Opts := Map("TimeActivationSeconds", HotstringsResolve("rolls", "assign_arrow_equal_left").Delay)
	Repl := SpaceAroundSymbols . "<=" . SpaceAroundSymbols
	CreateHotstring("*?", " =$", Repl, Opts)
	CreateHotstring("*?", "=$", Repl, Opts)
}
if Features["hotstrings"]["rolls"]["assign_arrow_minus_right"]["enabled"] {
	Opts := Map("TimeActivationSeconds", HotstringsResolve("rolls", "assign_arrow_minus_right").Delay)
	Repl := SpaceAroundSymbols . "->" . SpaceAroundSymbols
	CreateHotstring("*?", " +?", Repl, Opts)
	CreateHotstring("*?", "+?", Repl, Opts)
}
if Features["hotstrings"]["rolls"]["assign_arrow_minus_left"]["enabled"] {
	Opts := Map("TimeActivationSeconds", HotstringsResolve("rolls", "assign_arrow_minus_left").Delay)
	Repl := SpaceAroundSymbols . "<-" . SpaceAroundSymbols
	CreateHotstring("*?", " ?+", Repl, Opts)
	CreateHotstring("*?", "?+", Repl, Opts)
}
if Features["hotstrings"]["rolls"]["ct"]["enabled"] {
	LoadHotstringsSection("rolls", "ct", Features["hotstrings"]["rolls"]["ct"])
}





; ================================
; =================================
; ======= 3/ AUTOCORRECTION =======
; =================================
; ================================



; ==========================================================================
; ===== 3.1) Automatic conversion of apostrophe into a typographic one =====
; ==========================================================================

if Features["hotstrings"]["autocorrection"]["typographic_apostrophe"]["enabled"] {
	LoadHotstringsSection("autocorrection", "typographic_apostrophe", Features["hotstrings"]["autocorrection"]["typographic_apostrophe"])

	; Create all hotstrings y'a → y'a, y'b → y'b, etc.
	; This prevents false positives like writing ['key'] ➜ ['key']
	for _, Letter in StrSplit("abcdefghijklmnopqrstuvwxyz") {
		CreateCaseSensitiveHotstrings(
			"*?", "y'" . Letter, "y'" . Letter,
			Map("TimeActivationSeconds", HotstringsResolve("autocorrection", "typographic_apostrophe").Delay)
		)
	}
}



; ======================================
; ===== 3.2) Errors autocorrection =====
; ======================================

if Features["hotstrings"]["autocorrection"]["errors"]["enabled"] {
	LoadHotstringsSection("autocorrection", "errors", Features["hotstrings"]["autocorrection"]["errors"])
}

if Features["hotstrings"]["autocorrection"]["ou"]["enabled"] {
	LoadHotstringsSection("autocorrection", "ou", Features["hotstrings"]["autocorrection"]["ou"])
}

if Features["hotstrings"]["autocorrection"]["multiple_punctuation_marks"]["enabled"] {
	LoadHotstringsSection("autocorrection", "multiple_punctuation_marks", Features["hotstrings"]["autocorrection"]["multiple_punctuation_marks"])

	; We can't use the TimeActivationSeconds here, as previous character = current character = "."
	Hotstring(
		":*?B0:" . "...",
		; Needs to be activated only after a word, otherwise can cause problem in code, like in js: [...a, ...b]
		(*) => GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$" ?
			SendNewResult("{BackSpace 3}…", False) : ""
	)
}

if Features["hotstrings"]["autocorrection"]["suffixes_a_chaining"]["enabled"] {
	LoadHotstringsSection("autocorrection", "suffixes_a_chaining", Features["hotstrings"]["autocorrection"]["suffixes_a_chaining"])
}



; =============================================
; ===== 3.3) Add minus sign automatically =====
; =============================================

if Features["hotstrings"]["autocorrection"]["minus"]["enabled"] {
	LoadHotstringsSection("autocorrection", "minus", Features["hotstrings"]["autocorrection"]["minus"])
}

if Features["hotstrings"]["autocorrection"]["minus_apostrophe"]["enabled"] {
	LoadHotstringsSection("autocorrection", "minus_apostrophe", Features["hotstrings"]["autocorrection"]["minus_apostrophe"])
}



; ====================================
; ===== 3.4) Caps autocorrection =====
; ====================================

if Features["hotstrings"]["autocorrection"]["caps"]["enabled"] {
	LoadHotstringsSection("autocorrection", "caps", Features["hotstrings"]["autocorrection"]["caps"])

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
	for _, prefix in prefixes {
		for _, app in apps {
			from := prefix . " " . app
			to := prefix . " " . Capitalize(app)
			CreateHotstring("", from, to)
		}
	}
	Capitalize(str) {
		return StrUpper(SubStr(str, 1, 1)) . SubStr(str, 2)
	}
}



; =======================================
; ===== 3.5) Accents autocorrection =====
; =======================================

if Features["hotstrings"]["autocorrection"]["names"]["enabled"] {
	LoadHotstringsSection("autocorrection", "names", Features["hotstrings"]["autocorrection"]["names"])
}

if Features["hotstrings"]["autocorrection"]["accents"]["enabled"] {
	LoadHotstringsSection("autocorrection", "accents", Features["hotstrings"]["autocorrection"]["accents"])
}





; ================================
; =================================
; ======= 4/ TEXT EXPANSION =======
; =================================
; ================================



; ================================
; ===== 4.1) Suffixes with À =====
; ================================

if Features["hotstrings"]["distances_reduction"]["suffixes_a"]["enabled"] {
	LoadHotstringsSection("distancesreduction", "suffixes_a", Features["hotstrings"]["distances_reduction"]["suffixes_a"])
}



; ======================================================
; ===== 4.2) Personal information shortcuts with @ =====
; ======================================================

if Features["hotstrings"]["dynamic"]["text_expansion_personal_information"]["enabled"] {
	CreateHotstring("*", "@bic" . ScriptInformation["MagicKey"], PersonalInformation["bic"], Map("FinalResult",
		True))
	CreateHotstring("*", "@cb" . ScriptInformation["MagicKey"], PersonalInformation["credit_card"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@cc" . ScriptInformation["MagicKey"], PersonalInformation["credit_card"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@iban" . ScriptInformation["MagicKey"], PersonalInformation["iban"], Map("FinalResult",
		True))
	CreateHotstring("*", "@rib" . ScriptInformation["MagicKey"], PersonalInformation["iban"], Map("FinalResult",
		True))
	CreateHotstring("*", "@ss" . ScriptInformation["MagicKey"], PersonalInformation["social_security_number"], Map(
		"FinalResult", True))
	CreateHotstring("*", "@tel" . ScriptInformation["MagicKey"], PersonalInformation["phone_number"], Map(
		"FinalResult",
		True))
	CreateHotstring("*", "@tél" . ScriptInformation["MagicKey"], PersonalInformation["phone_number"], Map(
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
		Features["hotstrings"]["dynamic"]["text_expansion_personal_information"]["pattern_max_length"]
	)

	GeneratePersonalInformationHotstrings(hotstrings, maxLen) {
		keys := []
		for _, k in hotstrings
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
		for _, key in keys {
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



; ======================================
; ===== 4.3) Text expansion with ★ =====
; ======================================

if Features["hotstrings"]["magic_key"]["text_expansion"]["enabled"] {
	LoadHotstringsSection("magickey", "text_expansion", Features["hotstrings"]["magic_key"]["text_expansion"])
}

if Features["hotstrings"]["magic_key"]["text_expansion_auto"]["enabled"] {
	LoadHotstringsSection("magickey", "text_expansion_auto", Features["hotstrings"]["magic_key"]["text_expansion_auto"])
}



; =======================
; ===== 4.4) Emojis =====
; =======================

if Features["hotstrings"]["magic_key"]["text_expansion_emojis"]["enabled"] {
	LoadHotstringsSection("magickey", "text_expansion_emojis", Features["hotstrings"]["magic_key"]["text_expansion_emojis"])
}



; ========================
; ===== 4.5) Symbols =====
; ========================

if Features["hotstrings"]["magic_key"]["text_expansion_symbols"]["enabled"] {
	LoadHotstringsSection("magickey", "text_expansion_symbols", Features["hotstrings"]["magic_key"]["text_expansion_symbols"])
}

if Features["hotstrings"]["magic_key"]["text_expansion_symbols_typst"]["enabled"] {
	LoadHotstringsSection("magickey", "text_expansion_symbols_typst", Features["hotstrings"]["magic_key"]["text_expansion_symbols_typst"],
		Map("OnlyText", False))
}





; =====================================
; =====================================
; ======= 5/ Dynamic hotstrings =======
; =====================================
; =====================================

; Effective activation delay for the dynamic hotstrings: the user's
; "dynamichotstrings" delay override when set, otherwise the shared default
; DYN_HOTSTRINGS_DEFAULT_DELAY (defined in lib/hotstrings/hotstrings_config.ahk,
; the early-loaded layer the tray menu also reads). No category TOML backs this
; key, so HotstringsResolve reports HasOverride=false until the user sets one
; from the tray "Delays" submenu (mirrors the macOS dynamichotstrings delay item).
_DynamicHotstringDelay() {
	global DYN_HOTSTRINGS_DEFAULT_DELAY
	R := HotstringsResolve("dynamichotstrings", "")
	return R.HasOverride ? R.Delay : DYN_HOTSTRINGS_DEFAULT_DELAY
}

; Returns the shortest prefix of a spaced string that contains exactly RawCount
; non-space characters. Used to build the "spaced" trigger for SSN and IBAN.
SpacedPrefix(SpacedStr, RawCount) {
	Seen := 0
	Loop Parse, SpacedStr {
		if A_LoopField != " "
			Seen++
		if Seen >= RawCount
			return SubStr(SpacedStr, 1, A_Index)
	}
	return SpacedStr  ; Fallback — fewer raw chars than requested
}



; =====================
; ===== 5.1) Date =====
; =====================

; @dt★, @td★, @date★ resolved at fire time — cannot be static TOML entries.
; "??" flag required: after a prior expansion the output lands immediately
; before the next "@", so the word boundary before "@" is a digit or letter —
; not a terminator. Without "?", HSE rejects the match and the shorter
; "t★" (InWord=true) wins instead.
_DateShortFr(*) {
	return FormatTime(, "dd/MM/yyyy")
}
_DateLongFr(*) {
	; A_WDay: 1=Sunday, 2=Monday, …, 7=Saturday
	days   := ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
	months := ["janvier", "février", "mars", "avril", "mai", "juin",
	           "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
	return days[A_WDay] . " " . FormatTime(, "d") . " " . months[FormatTime(, "M") + 0] . " " . FormatTime(, "yyyy")
}
_DateIso(*) {
	return FormatTime(, "yyyy_MM_dd")
}
MK := ScriptInformation["MagicKey"]
; The dynamic hotstrings (dates + phone/SSN/IBAN prefixes) share one activation
; delay gate so they fire only when the trigger was typed within the configured
; window. Resolve it once and reuse the options Map for every registration below.
_DynOpts := Map("FinalResult", True, "TimeActivationSeconds", _DynamicHotstringDelay())
if Features["hotstrings"]["dynamic"]["date_fr"]["enabled"] {
	CreateHotstring("*?", "@dt" . MK, _DateShortFr, _DynOpts)
}
if Features["hotstrings"]["dynamic"]["date_long_fr"]["enabled"] {
	CreateHotstring("*?", "@date" . MK, _DateLongFr, _DynOpts)
}
if Features["hotstrings"]["dynamic"]["date"]["enabled"] {
	CreateHotstring("*?", "@td" . MK, _DateIso, _DynOpts)
}



; ==================================================
; ===== 5.2) Phone, SSN and IBAN prefix expand =====
; ==================================================

; Prefix-based hotstrings derived from the user's personal data.
; Registered once at startup from PersonalInformation — same logic as HS rules_engine.
; Each trigger auto-expands without end-char (*) and is case-sensitive (C).
Phone  := PersonalInformation["phone_number"]        ; e.g. "0606060606"
FPhone := PersonalInformation["phone_number_clean"]   ; e.g. "06 06 06 06 06"
Ssn    := PersonalInformation["social_security_number"] ; e.g. "1 99 99 99 999 999 99"
Iban   := PersonalInformation["iban"]               ; e.g. "FR00 0000 0000 0000 0000 0000 000"

; Strip spaces for matching purposes (SSN / IBAN contain decorative spaces)
SsnRaw  := StrReplace(Ssn,  " ", "")
IbanRaw := StrReplace(Iban, " ", "")

if Features["hotstrings"]["dynamic"]["phone_prefixes"]["enabled"] {
	; Mirrors HS: phone[1:2]+★, +33+phone[1:2], phone[1:4], +33+phone[2:4], phone[2:5], fphone[1:5]
	MK := ScriptInformation["MagicKey"]
	if StrLen(Phone) >= 2 {
		CreateHotstring("*C", SubStr(Phone, 1, 2) . MK, (*) => Phone, _DynOpts)
		CreateHotstring("*C", "+33" . SubStr(Phone, 1, 2), (*) => "+33" . SubStr(Phone, 2), _DynOpts)
	}
	if StrLen(Phone) >= 4 {
		CreateHotstring("*C", SubStr(Phone, 1, 4), (*) => Phone, _DynOpts)
		CreateHotstring("*C", "+33" . SubStr(Phone, 2, 3), (*) => "+33" . SubStr(Phone, 2), _DynOpts)
	}
	if StrLen(Phone) >= 6 {
		CreateHotstring("*C", SubStr(Phone, 2, 4), (*) => Phone, _DynOpts)
	}
	if StrLen(FPhone) >= 5 {
		CreateHotstring("*C", SubStr(FPhone, 1, 5), (*) => FPhone, _DynOpts)
	}
}

if Features["hotstrings"]["dynamic"]["ssn_prefixes"]["enabled"] {
	; No-space trigger → SSN without spaces; spaced trigger → SSN with spaces.
	; Both use the first 5 raw digits as the distinguishing prefix.
	if StrLen(SsnRaw) >= 5 {
		SsnRawPrefix  := SubStr(SsnRaw, 1, 5)
		SsnSpacedPfx  := SpacedPrefix(Ssn, 5)
		CreateHotstring("*C", SsnRawPrefix,  (*) => SsnRaw, _DynOpts)
		if SsnSpacedPfx != SsnRawPrefix {
			CreateHotstring("*C", SsnSpacedPfx, (*) => Ssn, _DynOpts)
		}
	}
}

if Features["hotstrings"]["dynamic"]["iban_prefixes"]["enabled"] {
	; 6 raw chars (case-insensitive) → IBAN without spaces.
	; 7 spaced chars (e.g. "FR76 XX") → IBAN with spaces.
	; Both triggers fire at the 6th raw character typed.
	if StrLen(IbanRaw) >= 6 {
		IbanRawPrefix    := SubStr(IbanRaw, 1, 6)
		IbanSpacedPfx    := SpacedPrefix(Iban, 6)
		; No C flag = case-insensitive matching for the letter prefix (e.g. "fr76")
		CreateHotstring("*", IbanRawPrefix,  (*) => StrReplace(Iban, " ", ""), _DynOpts)
		if IbanSpacedPfx != IbanRawPrefix {
			CreateHotstring("*", IbanSpacedPfx, (*) => Iban, _DynOpts)
		}
	}
}



; ===========================
; ===== 4.6) Repeat key =====
; ===========================

#InputLevel 1 ; Mandatory for this section to work, it needs to be below the inputlevel of the key remappings

; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
; That means a letter will only be repeated if no hotstring defined above matches
if Features["hotstrings"]["magic_key"]["repeat_corrections"]["enabled"] {
	LoadHotstringsSection("magickey", "repeat_corrections", Features["hotstrings"]["magic_key"]["repeat_corrections"])
}

CreateHotstring("*", "clé" . ScriptInformation["MagicKey"], "🔑")





; ===========================================
; ======================================
; ======= 6/ Personal hotstrings =======
; ======================================
; ===========================================

; Load every section declared in personal_hotstrings.toml (e.g. emailshortcuts,
; code, professionalvocabulary, autocorrection). Each section has its own
; toggle in Features["hotstrings"]["personal"] — disabled sections are
; skipped silently.
;
; Order matters: AHK fires the LAST-registered hotstring that matches, so we
; must register longer / more-specific triggers AFTER shorter ones. Sections
; whose triggers start with a special prefix (@, ., :, etc.) are typically
; longer composites of plain triggers, so we load them LAST. We achieve this
; by iterating the v2 Map in reverse — ApplyConfigToml preserves the
; insertion order of the [hotstrings.personal.*] sections from the user's
; config.toml, so reversing here gives "load prominent sections last".
if Features.Has("hotstrings") and Features["hotstrings"].Has("personal") {
    _PersonalGroup := Features["hotstrings"]["personal"]
    _PersonalKeys := []
    for _Key, _ in _PersonalGroup {
        _PersonalKeys.Push(_Key)
    }
    ; Reverse so the user's first-declared section (most prominent) loads
    ; last — AHK fires the last registered hotstring on prefix collisions.
    _Idx := _PersonalKeys.Length
    while (_Idx >= 1) {
        _SectionKey := _PersonalKeys[_Idx]
        _Idx -= 1
        _SectionCfg := _PersonalGroup[_SectionKey]
        if !(IsObject(_SectionCfg) and _SectionCfg.Has("enabled") and _SectionCfg["enabled"]) {
            continue
        }
        ; Section key is already the lowercase TOML key (mirror preserves
        ; .TomlSection naming verbatim) — pass it through unchanged.
        LoadHotstringsSection("personal", _SectionKey, _SectionCfg)
    }
}

; Extension personal TOML files — any *.toml in the hotstrings\ folder other than
; personal_hotstrings.toml is loaded as an extension pack (all sections enabled,
; no per-section toggle). Sub-folders generate hierarchical category labels.
if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalHotstringsDir") {
	HsExtDir := ScriptInformation["PersonalHotstringsDir"]
	if DirExist(HsExtDir) {
		_LoadPersonalExtRecursive(dir, prefix) {
			Loop Files dir . "\*", "DF" {
				if (A_LoopFileAttrib ~= "D") {
					; Recurse into sub-folder
					_LoadPersonalExtRecursive(A_LoopFileFullPath, (prefix == "" ? "" : prefix . " / ") . A_LoopFileName)
				} else if (A_LoopFileName ~= "i)\.toml$") {
					if (prefix == "" and A_LoopFileName == "personal_hotstrings.toml")
						continue
					SplitPath A_LoopFileFullPath, , , , &_ExtStem
					FullLabel := (prefix == "" ? "" : prefix . " / ") . _ExtStem
					LoadExtTomlFile(A_LoopFileFullPath, FullLabel)
				}
			}
		}
		_LoadPersonalExtRecursive(RegExReplace(HsExtDir, "[/\\]+$"), "")
	}
}
