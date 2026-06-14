; static/ergopti_plus/windows/modules/hotstrings.ahk

; ==============================================================================
; MODULE: Hotstrings
; DESCRIPTION:
; Loads all hotstring categories: distances reduction (QU, dead-key Ê,
; CommaJ, CommaFarLetters), SFBs reduction, rolls, autocorrection, and
; text expansion (personal info, date, magic key, emojis, symbols, repeat).
; ==============================================================================


; Registers every hotstring category into the engine. Wrapped in a function so
; the whole registration can be re-run in-process (live menu toggles) instead of
; restarting the script via Reload. Called once at boot from ErgoptiPlus.ahk
; right after the #Include, and again on every live hotstring toggle.
;
; The Ê deadkey and the "…" ellipsis used to be native AHK Hotstring()
; registrations, skipped on a live rebuild for input-level reasons. They are now
; HSE raw-callback hotstrings (CreateRawCallbackHotstring), so they carry no
; A_InputLevel dependency and register on every run — boot AND live rebuild — like
; every other HSE section. No native Hotstring() remains in this module.
;
; ``DeferHeavy`` is true ONLY for the boot pass: it skips the heaviest magic-key
; categories (emojis + symbols, ~3000 registrations / ~410 ms) so they do not sit
; on the critical boot path. ErgoptiPlus.ahk then arms a one-shot post-boot timer
; (RegisterEmojisSymbolsDeferred) that registers them off the critical path and
; rebuilds the prefix-watcher index. A live rebuild passes false → everything is
; registered synchronously, exactly as before.
RegisterAllHotstrings(DeferHeavy := false) {
	global Features, ScriptInformation, PersonalInformation, PersonalInformationLetters
	global DeadkeyMappingCircumflex, SpaceAroundSymbols, PersonalInformationHotstrings

	; Recompute SpaceAroundSymbols from the live Features on every run, so a live
	; toggle of distances_reduction.space_around_symbols re-bakes the rolls operator
	; replacements (":=", "->", …) with the new spacing — a cross-dependency that
	; would otherwise need a Reload. At boot this reproduces the exact value
	; ErgoptiPlus.ahk computed just before the #Include.
	_SpaceNode := (Features.Has("hotstrings")
		and Features["hotstrings"].Has("distances_reduction")
		and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
		? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
		: Map()
	SpaceAroundSymbols := (_SpaceNode.Has("enabled") and _SpaceNode["enabled"]) ? " " : ""





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

	; The "Ê" key enables the other symbols on the layer when we aren't inside a word.
	; The activation delay is passed explicitly so the registered callbacks stay
	; self-contained — CreateDeadkeyHotstring / ShouldActivateDeadkey live at module
	; scope (see end of file) and never close over this function's locals. They are
	; now HSE raw-callback hotstrings (no native Hotstring()), so they register on
	; every run — including a live rebuild — like every other HSE section.
	for MapKey, MappedValue in DeadkeyMappingCircumflexModified {
		CreateDeadkeyHotstring(MapKey, MappedValue, DeadKeyECircumflexDelay)
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
	; sends nbsp (U+00A0)+: on the Ergopti layout (French typography pairs ";"
	; with the narrow space and ":" with the full one); ¨+s also produces nbsp.
	; All act as the "shifted comma" — the Shift capitalises the J, so the
	; lowercase comma "je" becomes "Je". The vowel's own case carries through: a
	; lowercase vowel yields titlecase ("Je"), a Shift-held uppercase vowel yields
	; all-caps ("JE") — case-sensitive triggers are registered for each variant.
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
try BootProfile_Mark("HS sub: distances/SFBs/rolls registered")





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

	; We can't use the TimeActivationSeconds here, as previous character = current character = ".".
	; Now an HSE raw-callback hotstring (no native Hotstring()): _EllipsisRawCallback
	; expands "..." → "…" only after a letter (otherwise it breaks code like the JS
	; spread « [...a, ...b] ») and returns a { Bs, Ins } effect for buffer resync.
	CreateRawCallbackHotstring("*?", "...", _EllipsisRawCallback,
		Map("Category", "autocorrection", "Section", "multiple_punctuation_marks"))
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
try BootProfile_Mark("HS sub: autocorrection registered (excl. accents)")

if Features["hotstrings"]["autocorrection"]["accents"]["enabled"] {
	LoadHotstringsSection("autocorrection", "accents", Features["hotstrings"]["autocorrection"]["accents"])
}
try BootProfile_Mark("HS sub: autocorrection.accents registered")





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
	; Declared global at the top of RegisterAllHotstrings — re-init it on every run.
	PersonalInformationHotstrings := Map()
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
		global PersonalInformationHotstrings
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
try BootProfile_Mark("HS sub: @-personal-info combos registered")



; ======================================
; ===== 4.3) Text expansion with ★ =====
; ======================================

; The magic-key text-expansion sections are the MOST-USED feature (more than the
; rolls), so despite being a heavy registration category (~1060 conform specs,
; ~240 ms) they register ON the boot critical path, unconditionally, on BOTH the
; boot pass and live rebuilds. Rationale: "ready" must mean the user's everyday
; expansions already work, not that they come online ~half a second later; and the
; ~240 ms registration is far better paid at boot (nobody is typing) than on a
; post-"ready" timer that would freeze the single thread mid-keystroke. Only the
; truly heavy + rarely-instant emoji/symbol categories stay deferred (4.4-4.5).
_RegisterTextExpansionSections()
try BootProfile_Mark("HS sub: magickey text_expansion registered")



; ===============================================
; ===== 4.4-4.5) Emojis & symbols (deferrable) ===
; ===============================================

; The emoji + symbol categories are by far the heaviest (~3000 registrations,
; ~410 ms). On the boot pass (DeferHeavy = true) they are skipped here and loaded
; off the critical path by RegisterEmojisSymbolsDeferred() below; on a live
; rebuild (DeferHeavy = false) they load inline, exactly as before.
if !DeferHeavy {
	_RegisterEmojisSymbolsSections()
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

; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
; That means a letter will only be repeated if no hotstring defined above matches
if Features["hotstrings"]["magic_key"]["repeat_corrections"]["enabled"] {
	LoadHotstringsSection("magickey", "repeat_corrections", Features["hotstrings"]["magic_key"]["repeat_corrections"])
}
try BootProfile_Mark("HS sub: dynamic + repeat-key registered")

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
    ; Forward order: the user's first-declared (most prominent) section registers
    ; FIRST. HSE breaks equal-length trigger collisions by first-registered-wins
    ; (lowest Seq), so loading forward makes prominent sections win — the same
    ; effective precedence the old inline #InputLevel-0 loop produced before it
    ; was removed (it ran forward, ahead of this block, giving prominent the
    ; lowest Seq). The previous reverse iteration here was a stale carry-over
    ; from AHK-native "last-registered wins" semantics, which HSE does not use.
    for _SectionKey, _SectionCfg in _PersonalGroup {
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
try BootProfile_Mark("HS sub: personal + extension TOML registered")
}





; ==========================================================
; ==========================================================
; ======= 6.5/ Deferred emoji / symbol registration ========
; ==========================================================
; ==========================================================

; Delay (ms) before the deferred emoji/symbol pass fires after boot. Long enough
; that startup has settled and the user is very unlikely to have typed an
; emoji/symbol trigger yet, short enough that the expansions are available within
; a couple of seconds.
global HS_DEFERRED_REGISTRATION_DELAY_MS := 1500

; Delay (ms) before warming the prefix-watcher PREVIEW index off the boot path.
; text_expansion now registers ON the critical path (it is the most-used feature),
; so no heavy registration is deferred here — only the preview index is (re)built a
; short moment after "ready" so tooltips appear quickly without paying the index
; build on time-to-ready. The emoji/symbol pass rebuilds it again once those load.
global HS_PREFIX_INDEX_WARM_DELAY_MS := 300

; Single source of truth for WHICH emoji/symbol sections to register and how.
; Returns an Array of { Category, Section, FeatureConfig, ExtraOptions } for every
; ENABLED magic-key emoji/symbol section. Shared by the synchronous live rebuild
; (_RegisterEmojisSymbolsSections) and the chunked boot-deferred pass below so the
; two never drift on gating or load order.
_EmojiSymbolSectionSpecs() {
	global Features
	MK := Features["hotstrings"]["magic_key"]
	Specs := []
	if MK["text_expansion_emojis"]["enabled"]
		Specs.Push({ Category: "magickey", Section: "text_expansion_emojis",
			FeatureConfig: MK["text_expansion_emojis"], ExtraOptions: Map() })
	if MK["text_expansion_symbols"]["enabled"]
		Specs.Push({ Category: "magickey", Section: "text_expansion_symbols",
			FeatureConfig: MK["text_expansion_symbols"], ExtraOptions: Map() })
	if MK["text_expansion_symbols_typst"]["enabled"]
		Specs.Push({ Category: "magickey", Section: "text_expansion_symbols_typst",
			FeatureConfig: MK["text_expansion_symbols_typst"], ExtraOptions: Map("OnlyText", False) })
	return Specs
}

; Registers the heavy magic-key emoji + symbol sections in ONE synchronous pass.
; Used by the LIVE rebuild (a feature toggle / reload, where the user is not mid
; keystroke); the boot path uses the chunked deferred pass below instead.
_RegisterEmojisSymbolsSections() {
	for Spec in _EmojiSymbolSectionSpecs()
		LoadHotstringsSection(Spec.Category, Spec.Section, Spec.FeatureConfig, Spec.ExtraOptions)
}

; Rows registered per chunk on the deferred boot pass. ~150 rows is ~20-25 ms of
; registration — short enough that a keystroke arriving mid-pass waits at most one
; chunk, long enough that the per-chunk timer overhead stays negligible.
global _HS_DEFERRED_CHUNK_ROWS := 150
; Inter-chunk delay. A near-zero one-shot simply returns control to the message
; loop so any queued OnChar runs before the next chunk — it is NOT a throttle.
global _HS_DEFERRED_CHUNK_GAP_MS := 1
; Sections still to register, each { Category, Section, FeatureConfig, ExtraOptions,
; Cursor }. Drained one chunk per tick by _HsDeferredChunkTick.
global _HS_DeferredQueue := []

; Post-boot pass: registers the emoji + symbol categories the boot
; RegisterAllHotstrings(…, DeferHeavy := true) skipped, then rebuilds the
; prefix-watcher index so the live preview includes them. Armed via a one-shot
; SetTimer from ErgoptiPlus.ahk. The ~3000-row load is CHUNKED across timer ticks
; (see _HsDeferredChunkTick) so it never freezes the keystroke hook during the
; post-boot warm-up, when the user is often already typing. Wrapped in try so a
; transient failure can never crash the timer thread mid-startup.
RegisterEmojisSymbolsDeferred() {
	global _HS_DeferredQueue
	try {
		_HS_DeferredQueue := []
		for Spec in _EmojiSymbolSectionSpecs()
			_HS_DeferredQueue.Push({ Category: Spec.Category, Section: Spec.Section,
				FeatureConfig: Spec.FeatureConfig, ExtraOptions: Spec.ExtraOptions, Cursor: 1 })
		_HsDeferredChunkTick()
	} catch as e {
		try LoggerError("Hotstrings", "Deferred emoji/symbol registration failed to start: {1}", e.Message)
	}
}

; One chunk of the deferred registration, then re-arm on the message loop so any
; queued keystroke runs before the next chunk. When the queue drains it rebuilds
; the prefix-watcher index (the deferred triggers must appear in the live preview)
; and logs completion. A section that is not cache-backed is registered whole — the
; TOML parse fallback is not row-sliceable.
_HsDeferredChunkTick() {
	global _HS_DeferredQueue, _HS_CACHE_ROWS, _GENERATED_HOTSTRINGS
	global _HS_DEFERRED_CHUNK_ROWS, _HS_DEFERRED_CHUNK_GAP_MS
	try {
		if (_HS_DeferredQueue.Length == 0) {
			try HotstringPrefixWatcherRebuildIndex()
			try BootProfile_Mark("Emoji/symbol hotstrings registered (deferred, chunked)")
			try LoggerInfo("Hotstrings", "Deferred emoji/symbol registration complete.")
			return
		}
		Job := _HS_DeferredQueue[1]
		LoaderKey := StrLower(Job.Category) . "." . StrLower(Job.Section)
		HotstringsCacheEnsure()
		Sliceable := IsSet(_GENERATED_HOTSTRINGS) and _GENERATED_HOTSTRINGS.Has(LoaderKey) and _HS_CACHE_ROWS.Has(LoaderKey)
		if Sliceable {
			LoadHotstringsSection(Job.Category, Job.Section, Job.FeatureConfig, Job.ExtraOptions,
				Job.Cursor, _HS_DEFERRED_CHUNK_ROWS)
			Job.Cursor += _HS_DEFERRED_CHUNK_ROWS
			if (Job.Cursor > _HS_CACHE_ROWS[LoaderKey].Length)
				_HS_DeferredQueue.RemoveAt(1)
		} else {
			LoadHotstringsSection(Job.Category, Job.Section, Job.FeatureConfig, Job.ExtraOptions)
			_HS_DeferredQueue.RemoveAt(1)
		}
	} catch as e {
		try LoggerError("Hotstrings", "Deferred emoji/symbol chunk failed: {1}", e.Message)
		_HS_DeferredQueue := []   ; abort the remaining queue rather than spin on a broken chunk
	}
	SetTimer(_HsDeferredChunkTick, -_HS_DEFERRED_CHUNK_GAP_MS)
}

; Registers the magic-key text-expansion sections into the HSE. Shared by the boot
; deferred pass and the live rebuild so the two code paths never diverge (mirrors
; _RegisterEmojisSymbolsSections for the emoji/symbol categories).
_RegisterTextExpansionSections() {
	global Features
	if Features["hotstrings"]["magic_key"]["text_expansion"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion", Features["hotstrings"]["magic_key"]["text_expansion"])
	}
	if Features["hotstrings"]["magic_key"]["text_expansion_auto"]["enabled"] {
		LoadHotstringsSection("magickey", "text_expansion_auto", Features["hotstrings"]["magic_key"]["text_expansion_auto"])
	}
}





; =================================================
; =================================================
; ======= 7/ Deadkey helpers (module scope) =======
; =================================================
; =================================================

; These helpers are defined at module scope (not nested inside RegisterAllHotstrings)
; so the hotstring callbacks they register never close over the wrapper's locals:
; the activation delay flows in as the explicit Delay parameter. This keeps the
; registration re-runnable without rebuilding closures on every pass.
CreateDeadkeyHotstring(MapKey, MappedValue, Delay) {
	; The deadkey only activates at the start of a new word (symbols aren't put in
	; words); this corrects « même » giving « mê⁂e ». Registered as an HSE
	; raw-callback hotstring (no native Hotstring(), so no A_InputLevel dependency):
	; the callback inspects context and conditionally expands.
	Combination := "ê" . MapKey
	CreateRawCallbackHotstring(
		"*?C", Combination,
		(*) => ShouldActivateDeadkey(Combination, MappedValue, Delay),
		Map("TimeActivationSeconds", Delay, "Category", "distancesreduction", "Section", "dead_key_e_circumflex")
	)
}

; Returns the { Bs, Ins } buffer effect _HSE_DispatchRawCallback resyncs from: when
; the deadkey fires it has back-spaced 2 chars (the "ê" + the key) and sent
; MappedValue, so the net buffer change is { Bs: 2, Ins: MappedValue }; when it
; declines it sends nothing and returns { Bs: 0, Ins: "" } (buffer untouched).
ShouldActivateDeadkey(Combination, MappedValue, Delay) {
	if not IsTimeActivationExpired(GetLastSentCharacterAt(-2), Delay) {
		; We only activate the deadkey if it is the start of a new word, as symbols aren't put in words
		; This condition corrects problems such as writing "même" that give "mê⁂e"
		; We could simply have removed the "?" flag in the Hotstring definition, but we want to get the symbols also if we are typing numbers.
		; For example to write 01/02 by using the / on the deadkey.
		if (GetLastSentCharacterAt(-3) ~= "^[^A-Za-z★]$") { ; Everything except a letter
			; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
			SendNewResult("{BackSpace 2}", False)
			SendNewResult(MappedValue)
			return { Bs: 2, Ins: MappedValue }
		} else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
			SendNewResult("{BackSpace 2}", False)
			SendNewResult(MappedValue)
			return { Bs: 2, Ins: MappedValue }
		}
	}
	return { Bs: 0, Ins: "" }
}

; Ellipsis raw-callback: "..." → "…", but only after a letter (otherwise it would
; break code like the JS spread « [...a, ...b] »). Returns the { Bs, Ins } buffer
; effect for HSE resync (back-spaces the 3 dots, inserts "…").
_EllipsisRawCallback(*) {
	if (GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$") {
		SendNewResult("{BackSpace 3}…", False)
		return { Bs: 3, Ins: "…" }
	}
	return { Bs: 0, Ins: "" }
}
