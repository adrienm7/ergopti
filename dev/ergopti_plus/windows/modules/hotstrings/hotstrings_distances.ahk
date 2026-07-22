; modules/hotstrings/hotstrings_distances.ahk

; ==============================================================================
; MODULE: Hotstrings — Distances & Rolls
; DESCRIPTION:
; Registers the distance-reduction and same-finger-bigram (SFB) hotstrings, and
; all roll-based operator expansions. Extracted from modules/hotstrings.ahk as a
; standalone sub-module so each category can be read and reasoned about in isolation.
;
; FEATURES & RATIONALE:
; 1. QU: comma-J vowel combos, comma far-letters, dead-key Ê circumflex mapping.
; 2. SFB reduction: comma, Ê, È, À buckets.
; 3. Rolls: left-hand (chevron, ez, comment) and right-hand (hashtag, operators).
; ==============================================================================





; =============================================================================
; ==========================================================================
; ======= 1/ Distances & SFB reduction + rolls registration function =======
; ==========================================================================
; =============================================================================

; Registers all Section 1 (distances / SFBs) and Section 2 (rolls) hotstrings.
; Called once by RegisterAllHotstrings() in modules/hotstrings.ahk. SpaceAroundSymbols
; must be computed by the orchestrator before this function is called.
_HS_RegisterDistancesAndRolls() {
	global Features, ScriptInformation, DeadkeyMappingCircumflex, SpaceAroundSymbols





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
			; Also remove the uppercase variant — CreateCaseSensitiveHotstrings registers
			; both cases; leaving the uppercase entry in the Map causes a duplicate
			; registration in the CreateDeadkeyHotstring loop below, wasting CPU at startup
			; and on every live rebuild (hotstrings-deadkey-uppercase-duplicate).
			UpperVowel := StrUpper(Vowel)
			if (UpperVowel != Vowel)
				DeadkeyMappingCircumflexModified.Delete(UpperVowel)
		}
		DeadkeyMappingCircumflexModified.Delete("e") ; For the rolling "êe" that gives "œ"
		DeadkeyMappingCircumflexModified.Delete("E") ; Uppercase variant of the above
		DeadkeyMappingCircumflexModified.Delete("t") ; To be able to type "être"
		DeadkeyMappingCircumflexModified.Delete("T") ; Uppercase variant of the above

		; The "Ê" key enables the other symbols on the layer when we aren't inside a word.
		; The activation delay is passed explicitly so the registered callbacks stay
		; self-contained — CreateDeadkeyHotstring / ShouldActivateDeadkey live at module
		; scope (see hotstrings_helpers.ahk) and never close over this function's locals.
		; They are now HSE raw-callback hotstrings (no native Hotstring()), so they register
		; on every run — including a live rebuild — like every other HSE section.
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
			"*?", "ié" . ScriptInformation["MagicKey"], "ébu",
			Map("TimeActivationSeconds", HotstringsResolve("sfbsreduction", "bu").Delay)
		)
	}
	if Features["hotstrings"]["sfbs_reduction"]["bu"]["enabled"] {
		CreateCaseSensitiveHotstrings(
			"*?", "à" . ScriptInformation["MagicKey"], "bu",
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
}
