; modules/hotstrings/hotstrings_text_expansion.ahk

; ==============================================================================
; MODULE: Hotstrings — Text Expansion & Dynamic Hotstrings
; DESCRIPTION:
; Registers the text-expansion categories (suffixes_a, personal-info @-combos,
; magic-key text-expansion) and the dynamic hotstrings (dates, phone/SSN/IBAN
; prefixes, repeat key). Extracted from modules/hotstrings.ahk to keep the
; expansion logic readable in isolation.
;
; FEATURES & RATIONALE:
; 1. Personal info combos: @bic★, @ss★, @tel★, and all multi-letter combos
;    generated at startup from the user's personal_info.toml. Tab-separated when
;    multiple fields are combined.
; 2. Magic-key text expansion: delegates to _RegisterTextExpansionSections()
;    so the boot and live-rebuild paths share exactly one code path.
; 3. Dynamic hotstrings: dates resolved at fire time (never stale), and phone /
;    SSN / IBAN prefix triggers that auto-expand the full number.
; ==============================================================================





; ============================================================================
; ============================================================================
; ======= 1/ Text expansion & dynamic hotstrings registration function =======
; ============================================================================
; ============================================================================

; Registers Sections 4–5 of modules/hotstrings.ahk (text expansion + dynamic).
; DeferHeavy must match the caller's intent — true on the boot pass, false on
; live rebuilds. _RegisterTextExpansionSections() and SpaceAroundSymbols are
; defined outside this function (hotstrings_helpers.ahk and the orchestrator).
_HS_RegisterTextExpansionAndDynamic(DeferHeavy := false) {
	global Features, ScriptInformation, PersonalInformation, PersonalInformationLetters
	global PersonalInformationHotstrings, DYN_HOTSTRINGS_DEFAULT_DELAY, SpaceAroundSymbols
	global PERSONAL_INFO_TAGS, PERSONAL_INFO_TAG_ORDER, HSE_PersonalInfoCombosEnabled





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
		; The single-field @-tags (@bic, @cb, @cc, @iban, @rib, @ss, @tel, @tél).
		; Both the tag set and the field each one names come from
		; PERSONAL_INFO_TAGS (infra/personal_info_preview.ahk), which the
		; preview reads too — eight hand-written call sites here and a second copy
		; of the same map over there is exactly how a tag comes to expand one field
		; and preview another. PERSONAL_INFO_TAG_ORDER drives the loop because a
		; Map does not enumerate in insertion order and registration order is the
		; engine's last collision tie-break.
		for _, InfoTag in PERSONAL_INFO_TAG_ORDER {
			if !PERSONAL_INFO_TAGS.Has(InfoTag) {
				LoggerWarn("hotstrings", "Personal-info tag '@{1}' is listed in the registration order but absent from the tag map -- skipped.", InfoTag)
				continue
			}
			InfoTagField := PERSONAL_INFO_TAGS[InfoTag]
			if !PersonalInformation.Has(InfoTagField) {
				LoggerWarn("hotstrings", "Personal-info tag '@{1}' names the unknown field '{2}' -- skipped.", InfoTag, InfoTagField)
				continue
			}
			; IsPrivate is what keeps the resolved value — an IBAN, a card number,
			; a social-security number — out of the metrics row the fire writes and
			; out of the debug fire-trace. Without it the expansion is recorded
			; verbatim, twice per row, into a log that is replicated to every other
			; device and kept for fourteen days.
			CreateHotstring("*", "@" . InfoTag . ScriptInformation["MagicKey"],
				PersonalInformation[InfoTagField], Map("FinalResult", True).Set("IsPrivate", True))
		}

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
			; ``hotstrings`` is a Map keyed by the alias LETTER (n, t, …); the combo
			; generator needs those keys, not the personal-data values. The 2-var Map
			; enumerator binds (key, value), so iterate `k, _` and push the KEY -- a
			; mechanical `for _, k` rewrite once seeded the values here and killed every
			; @<letter> combo (a Map is not an Array)
			for k, _ in hotstrings
				keys.Push(k)
			loop maxLen
				Generate(keys, hotstrings, "", A_Index)
		}

		; In case email is "^a" we want to send raw string and not Ctrl + A.
		; The transform itself is SendEscapeLiteral (infra/text_utils.ahk): the
		; fire-time @-combo resolver needs the same escaping on the same values, and
		; a nested copy here would be a second implementation to keep in step.
		EscapeSpecialChars(text) {
			return SendEscapeLiteral(text)
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

		; Every combo concatenates one or more personal_info fields, so the whole
		; generated family is private for the same reason the single-field tags are.
		CreateHotstringCombo(combo, value) {
			CreateHotstring("*", "@" combo "" . ScriptInformation["MagicKey"], value, Map("OnlyText", False).Set(
				"FinalResult", True).Set("IsPrivate", True))
		}

		; Every combo LONGER than pattern_max_length is resolved at fire time by
		; HSE_TryPersonalInfoCombo instead of being registered here.
		;
		; This replaced a hand-written list of thirty-one CreateHotstringComboAuto
		; calls. With thirteen alias letters the space is 169 combos at length two,
		; 2 197 at three and 28 561 at four, so the list could only ever be a
		; sample — and it was missing @npdt and @nt, which is how this surfaced:
		; the letters resolved, the values existed, and the only thing absent was a
		; line in a list. Nothing logged, nothing failed, the key just did nothing.
		;
		; Two behaviours changed with it, both toward the other drivers:
		;   - No trailing Tab. The hand-listed combos appended one after the LAST
		;     field; Generate() below never did, and neither does macOS
		;     (modules/dynamic_hotstrings/personal_info.lua fires its tab only while
		;     `i < #parts`). The bubble never showed one either, so preview and fire
		;     now agree where they used to differ by a keystroke.
		;   - An unknown letter declines the whole combo instead of skipping it, so
		;     a typo cannot silently type a partial identity into a form.
		HSE_PersonalInfoCombosEnabled := true
	} else {
		; Fail closed rather than leaving the resolver armed from a previous run:
		; live rebuilds re-enter this function, and a toggle that only ever turns ON
		; is a feature the user cannot switch off.
		HSE_PersonalInfoCombosEnabled := false
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





	; ==========================================
	; ==========================================
	; ======= 5/ Dynamic hotstrings ============
	; ==========================================
	; ==========================================

	; Moved to modules/dynamic_hotstrings/, which is the folder name macOS and
	; Linux already use for the same behaviour. The CALL stays here: registration
	; order feeds the engine's collision tiebreak, so this must still run after
	; the emoji/symbol sections and before the repeat key below.
	_DynHS_RegisterAll()




	; ===========================
	; ===== 4.6) Repeat key =====
	; ===========================

	; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
	; That means a letter will only be repeated if no hotstring defined above matches
	if Features["hotstrings"]["magic_key"]["repeat_corrections"]["enabled"] {
		LoadHotstringsSection("magickey", "repeat_corrections", Features["hotstrings"]["magic_key"]["repeat_corrections"])
	}
	try BootProfile_Mark("HS sub: dynamic + repeat-key registered")
}
