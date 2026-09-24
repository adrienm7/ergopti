; infra/text_case.ahk

; ==============================================================================
; MODULE: Text Case
; DESCRIPTION:
; Pure case conversions behind the selection case actions (selection_uppercase,
; selection_lowercase, selection_titlecase and the uppercase_selection /
; titlecase_selection toggles). No side effect, so the unit suite replays the
; shared corpus _shared/tests/corpus/text_case/vectors.json against them.
;
; FEATURES & RATIONALE:
; 1. Operating-system mappings: StrUpper / StrLower convert every accented
;    letter (é, à, ç) through Windows' own simple case mappings. The macOS and
;    Linux drivers read a complete generated Unicode table instead; the corpus
;    limits the few vectors where the two differ (ß, the Greek final sigma,
;    title-case digraphs) to those drivers.
; 2. One title-case rule for the three drivers. Format("{:T}") capitalized after
;    a digit ("3e" -> "3E") and not after a hyphen ("jean-pierre" ->
;    "Jean-pierre"), while the Lua drivers only started a word after whitespace.
;    The rule below is the one the corpus pins: whitespace and dashes start a
;    word, other punctuation before a word is kept and does not take the capital.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Case conversion =======
; ==================================
; ==================================

; @param {String} Text
; @returns {String} Text in uppercase.
TextCaseUpper(Text) {
	return StrUpper(Text)
}

; @param {String} Text
; @returns {String} Text in lowercase.
TextCaseLower(Text) {
	return StrLower(Text)
}

; @param {String} Text
; @returns {Boolean} True when a character of Text still has an uppercase form.
TextCaseHasLowercase(Text) {
	return StrUpper(Text) !== Text
}

; Title case: lowercase everything, then uppercase the first character of each
; word. A word starts at the beginning of the text and after whitespace or a
; dash ("jean-pierre" -> "Jean-Pierre"). Punctuation before a word ("«", "(",
; a quote) is kept and does not take the capital; an apostrophe inside a word
; does not start a new one ("l'été" -> "L'été"). A digit or symbol that starts
; a word ends the word start ("3e" stays "3e").
; @param {String} Text
; @returns {String}
TextCaseTitle(Text) {
	Lowered := StrLower(Text)
	Result := ""
	AtWordStart := true
	Position := 1
	while (Position := RegExMatch(Lowered, "s)(*UCP).", &Character, Position)) {
		Char := Character[0]
		Position += StrLen(Char)
		if RegExMatch(Char, "(*UCP)^[\s\p{Pd}]$") {
			AtWordStart := true
			Result .= Char
		} else if (!AtWordStart || RegExMatch(Char, "(*UCP)^\p{P}$")) {
			Result .= Char
		} else {
			AtWordStart := false
			Result .= StrUpper(Char)
		}
	}
	return Result
}

; The uppercase toggle: uppercase while a character can still be uppercased,
; lowercase otherwise, so pressing the action twice undoes it.
; @param {String} Text
; @returns {String}
TextCaseToggleUpper(Text) {
	return TextCaseHasLowercase(Text) ? StrUpper(Text) : StrLower(Text)
}

; The title-case toggle: lowercase when Text is already in title case, title
; case otherwise.
; @param {String} Text
; @returns {String}
TextCaseToggleTitle(Text) {
	Titled := TextCaseTitle(Text)
	return (Titled == Text) ? StrLower(Text) : Titled
}
