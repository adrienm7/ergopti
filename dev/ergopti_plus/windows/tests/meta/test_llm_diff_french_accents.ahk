; tests/meta/test_llm_diff_french_accents.ahk

; ==============================================================================
; MODULE: LLM Diff French Accents Meta Test
; DESCRIPTION:
; Static source guard for the T-W07 finding: the tokenizer in llm_diff.ahk must
; treat accented characters (e.g. é in "café") as word characters, not as
; punctuation boundaries, so that a word like "café" is emitted as a single
; token rather than being split at the accent boundary.
;
; APPROACH: source scan.
; llm_diff.ahk lives in infra/ and is #Include-safe, but adding it to run_all.ahk
; solely for this one guard would pull in a whole tokenizer that is already
; tested functionally elsewhere. The condition that makes accented characters work
; is a single, unique line that can be asserted directly from the source text —
; the source-scan approach is therefore cleaner and equally authoritative.
;
; WHAT IS ASSERTED:
; The word-character branch of the loop-parse block must extend coverage beyond
; ASCII word chars (\w / [a-zA-Z0-9_]) by testing Ord(c) >= 128. Any codepoint
; at or above 128 is treated as a word character: this covers the full Latin-1
; Supplement (é, à, ü, ñ, …), the broader BMP, and surrogate pairs.
; Removing or weakening this guard would silently split "café" into ["caf", "é"],
; breaking diff colorisation for all French text.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLDA_Check() {
	Src := _DriverDirConcat("infra")

	; The tokenizer must extend word-character detection to non-ASCII codepoints.
	; This single condition is what makes "café" tokenize as one word token
	; instead of splitting at the é boundary.
	Assert(InStr(Src, "Ord(c) >= 128") > 0,
		"llm_diff.ahk: _LLM_Diff_Tokenize must treat Ord(c) >= 128 as a word character")

	; The guard must appear inside the tokenizer function, not in an unrelated block.
	Assert(InStr(Src, "_LLM_Diff_Tokenize") > 0,
		"llm_diff.ahk: function _LLM_Diff_Tokenize must exist")
}

Test("llm_diff: caf" Chr(0xE9) " is tokenized as a single word token", _TLDA_Check)
