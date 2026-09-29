; modules/llm/tone.ahk

; ==============================================================================
; MODULE: Tone Ladder (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/tone.lua: the pure logic behind the
; "more formal" / "more familiar" actions, which register a selection moves
; to, and which text is rewritten into it.
;
; FEATURES & RATIONALE:
; 1. Four built-in rewrite profiles form a ladder, from familiar to very
;    formal. A selection the actions did not write starts at neutral.
; 2. Each step rewrites the ORIGINAL text into the target register, never the
;    previous rewrite, so going back and forth never drifts from what the user
;    wrote. The memory of the last rewrite ties a selection to its original.
; 3. Two flavours per direction: one stops at the end of the ladder, the
;    other wraps around to the opposite end.
; 4. The model answers with the rewrite tag; LLM_Tone_Extract reads that
;    answer without the typing-buffer alignment of the prediction parser,
;    because a selection is replaced whole.
;
; Whitespace is the Lua %s class (space, tab, LF, VT, FF, CR), spelled out:
; AutoHotkey's Trim only strips spaces and tabs. Every quote character is one
; UTF-16 code unit, so the unit lengths compare like the Lua byte lengths.
;
; Pinned with the Lua module by _shared/tests/corpus/llm/tone_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Module Constants =========
; =====================================
; =====================================

; Built-in profile ids, from the most familiar register to the most formal
global LLM_TONE_LADDER := ["tone_familiar", "tone_neutral", "tone_formal", "tone_very_formal"]

; Level of a selection the tone actions did not write: neutral
global LLM_TONE_START_LEVEL := 2

; Step directions
global LLM_TONE_MORE_FORMAL := 1
global LLM_TONE_MORE_FAMILIAR := -1

; The Lua %s class and its complement, as PCRE character classes
global LLM_TONE_SPACE_CLASS := "[ \t\n\x0B\f\r]"
global LLM_TONE_NON_SPACE_CLASS := "[^ \t\n\x0B\f\r]"

; Quote pairs a model may wrap its whole answer in
global LLM_TONE_QUOTE_PAIRS := [
	['"', '"'],
	[Chr(0x201C), Chr(0x201D)],
	[Chr(0x00AB), Chr(0x00BB)]
]





; ================================
; ================================
; ======= 2/ Public API ==========
; ================================
; ================================

/**
 * Returns the level one step away from Level.
 * @param {Integer} Level Current ladder index.
 * @param {Integer} Direction LLM_TONE_MORE_FORMAL or LLM_TONE_MORE_FAMILIAR.
 * @param {Boolean} Cycle Whether to wrap around at the ends of the ladder.
 * @returns {Integer} The next index, 0 at an end without cycling.
 */
LLM_Tone_Step(Level, Direction, Cycle) {
	global LLM_TONE_LADDER, LLM_TONE_MORE_FORMAL, LLM_TONE_MORE_FAMILIAR
	if !(Direction is Integer)
			|| (Direction != LLM_TONE_MORE_FORMAL && Direction != LLM_TONE_MORE_FAMILIAR)
		throw ValueError("LLM_Tone_Step: direction must be MORE_FORMAL or MORE_FAMILIAR.")
	if !(Level is Integer) || Level < 1 || Level > LLM_TONE_LADDER.Length
		throw ValueError("LLM_Tone_Step: level out of range: " . String(Level) . ".")
	Target := Level + Direction
	if (Target >= 1 && Target <= LLM_TONE_LADDER.Length)
		return Target
	if !Cycle
		return 0
	return (Target < 1) ? LLM_TONE_LADDER.Length : 1
}

/**
 * Plans one step for a selection.
 * @param {String} Selection The selected text.
 * @param {Map|String} Memory The last rewrite, Map("source", "output",
 *     "level"), or "" when there is none.
 * @param {Integer} Direction LLM_TONE_MORE_FORMAL or LLM_TONE_MORE_FAMILIAR.
 * @param {Boolean} Cycle Whether to wrap around at the ends of the ladder.
 * @param {VarRef} Reason Receives "empty_selection" or "end_of_ladder" when
 *     there is nothing to do, "" otherwise.
 * @returns {Map|String} Map("source", "level", "profile_id"), or "".
 */
LLM_Tone_Plan(Selection, Memory, Direction, Cycle, &Reason := "") {
	global LLM_TONE_LADDER, LLM_TONE_START_LEVEL, LLM_TONE_NON_SPACE_CLASS
	Reason := ""
	if !(Selection is String) || !RegExMatch(Selection, LLM_TONE_NON_SPACE_CLASS) {
		Reason := "empty_selection"
		return ""
	}
	Source := Selection
	Level := LLM_TONE_START_LEVEL
	if (Memory is Map && Memory.Get("output", "") is String && Memory.Get("output", "") == Selection) {
		Source := Memory["source"]
		Level := Memory["level"]
	}
	Target := LLM_Tone_Step(Level, Direction, Cycle)
	if !Target {
		Reason := "end_of_ladder"
		return ""
	}
	return Map("source", Source, "level", Target, "profile_id", LLM_TONE_LADDER[Target])
}

/**
 * Builds the memory that ties the rewrite now selected to its original.
 * @param {Map} Plan The plan that was rewritten.
 * @param {String} Output The text that replaced the selection.
 * @returns {Map} Map("source", "output", "level").
 */
LLM_Tone_Remember(Plan, Output) {
	return Map("source", Plan["source"], "output", Output, "level", Plan["level"])
}

/**
 * Extracts the rewritten text from a model answer.
 * @param {String} Block The raw model answer.
 * @returns {String} The rewrite, "" when the answer holds none.
 */
LLM_Tone_Extract(Block) {
	global LLM_TONE_SPACE_CLASS, LLM_TONE_QUOTE_PAIRS
	if !(Block is String)
		return ""
	Space := LLM_TONE_SPACE_CLASS
	; \z, not $: PCRE's $ would stop before a final line break the Lua $ keeps
	if !RegExMatch(Block, "is)rewrite" . Space . "*:" . Space . "*(.*?)" . Space . "*\z", &Match)
		return ""
	Text := Match[1]
	RegExMatch(Text, "^[^\r\n]*", &Line)
	Text := StrReplace(Line[0], "**", "")
	Text := _LLM_Tone_TrimSpace(Text)
	; Only a pair that wraps the whole answer is the model quoting it
	for Pair in LLM_TONE_QUOTE_PAIRS {
		Open := Pair[1]
		Close := Pair[2]
		if (StrLen(Text) > StrLen(Open) + StrLen(Close)
				&& SubStr(Text, 1, StrLen(Open)) == Open
				&& SubStr(Text, -StrLen(Close)) == Close) {
			Text := _LLM_Tone_TrimSpace(SubStr(Text, StrLen(Open) + 1,
				StrLen(Text) - StrLen(Open) - StrLen(Close)))
			break
		}
	}
	return Text
}





; =====================================
; =====================================
; ======= 3/ Internal Helpers =========
; =====================================
; =====================================

; @param {String} Text The text to trim.
; @returns {String} Text without leading or trailing Lua %s whitespace.
_LLM_Tone_TrimSpace(Text) {
	global LLM_TONE_SPACE_CLASS
	return RegExReplace(Text, "^" . LLM_TONE_SPACE_CLASS . "+|" . LLM_TONE_SPACE_CLASS . "+\z", "")
}
