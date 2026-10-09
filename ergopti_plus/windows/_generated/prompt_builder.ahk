; static/ergopti_plus/windows/_generated/prompt_builder.ahk

; ==========================================
; AUTO-GENERATED — do not edit manually
; Source: static/ergopti_plus/_shared/lua/llm/prompt_builder.lua
; Run: npm run codegen:prompt-builder:ahk
; ==========================================

; ==============================================================================
; MODULE: PromptBuilder
; DESCRIPTION:
; AHK v2 implementation of the PromptBuilder domain contract. Derives all
; LLM request parameters (context, token budget, temperature, context tail)
; from the current typing buffer and a configuration Map.
;
; This module is the AHK counterpart of:
;   static/ergopti_plus/_shared/lua/llm/prompt_builder.lua
;   static/ergopti_plus/_shared/core/domain/PromptBuilder.js
; All constants and algorithms MUST stay in sync with those references.
;
; CONSTANTS (canonical — all drivers MUST use these exact values):
;   CONTEXT_TAIL_WORDS      = 5
;   DEFAULT_MAX_TOKENS      = 150
;   MIN_MAX_TOKENS          = 15
;   WORDS_TO_TOKENS_RATIO   = 6
;   TOKEN_BUDGET_OVERHEAD   = 10
;   TEMP_DIVERSITY_CAP      = 1.0
;   TEMP_INCREMENT_PER_PRED = 0.1
;   GREEDY_TEMP_THRESHOLD   = 0.15
;   CONTEXT_CHARS_PER_WORD  = 40
;   CONTEXT_MIN_CHARS       = 100
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Module Constants =======
; ===================================
; ===================================

; Number of words from the buffer tail kept as rolling context window
global PB_CONTEXT_TAIL_WORDS      := 5

; Token budget when max_words is uncapped (= 0)
global PB_DEFAULT_MAX_TOKENS      := 150

; Hard floor on the token budget regardless of word settings
global PB_MIN_MAX_TOKENS          := 15

; Conservative words-to-tokens multiplier for token budget estimation
global PB_WORDS_TO_TOKENS_RATIO   := 6

; Fixed overhead appended to the computed token budget
global PB_TOKEN_BUDGET_OVERHEAD   := 10

; Upper bound when auto_raise_temperature is active
global PB_TEMP_DIVERSITY_CAP      := 1.0

; Temperature step per extra prediction requested beyond 1
global PB_TEMP_INCREMENT_PER_PRED := 0.1

; Greedy threshold: snap temperature to 0 when single prediction and temp <= this
global PB_GREEDY_TEMP_THRESHOLD   := 0.15

; Chars of context allocated per predicted output word
global PB_CONTEXT_CHARS_PER_WORD  := 40

; Hard floor: always forward at least this many context characters
global PB_CONTEXT_MIN_CHARS        := 100





; ======================================
; ======================================
; ======= 2/ PromptBuilder Class =======
; ======================================
; ======================================

class PromptBuilder {

	; =================================
	; ===== 2.1) Internal Helpers =====
	; =================================

	; Extracts the last PB_CONTEXT_TAIL_WORDS words from the buffer.
	; Returns a string of those whitespace-delimited tokens joined by spaces.
	;
	; Param buffer - The current typing buffer string.
	; Returns string - The tail words joined with single spaces.
	_ExtractTail(buffer) {
		if (!buffer || RegExMatch(buffer, "^\s*$")) {
			return ""
		}

		; Split on any whitespace run to get all tokens
		local parts := StrSplit(Trim(buffer), [" ", "`t", "`n", "`r"])
		local words  := []
		for p in parts {
			if (p != "") {
				words.Push(p)
			}
		}

		local total    := words.Length
		local startIdx := Max(1, total - PB_CONTEXT_TAIL_WORDS + 1)
		local tail     := ""
		loop (total - startIdx + 1) {
			local w := words[startIdx + A_Index - 1]
			tail    := (tail = "") ? w : tail . " " . w
		}
		return tail
	}



	; Computes the token budget from the max_words setting.
	; Returns PB_DEFAULT_MAX_TOKENS when max_words is 0 (unlimited).
	;
	; Param maxWords - Maximum predicted words (0 = unlimited).
	; Returns integer - The computed token budget.
	_ComputeMaxTokens(maxWords) {
		if (!maxWords || maxWords <= 0) {
			return PB_DEFAULT_MAX_TOKENS
		}
		return Max(PB_MIN_MAX_TOKENS, maxWords * PB_WORDS_TO_TOKENS_RATIO + PB_TOKEN_BUDGET_OVERHEAD)
	}



	; Computes the effective temperature for a request.
	; Optionally raises temperature per extra prediction for diversity,
	; then snaps to 0 for single-prediction greedy decoding.
	;
	; Param baseTemp       - User-configured base temperature.
	; Param numPredictions - Number of predictions requested (1+).
	; Param autoRaise      - True = raise temperature for diversity.
	; Returns float - The effective temperature to send to the backend.
	_ComputeTemperature(baseTemp, numPredictions, autoRaise) {
		local t := baseTemp

		if (autoRaise && numPredictions > 1) {
			t := Min(PB_TEMP_DIVERSITY_CAP, t + PB_TEMP_INCREMENT_PER_PRED * (numPredictions - 1))
		}

		; Greedy decoding for single prediction and low temperature
		if (numPredictions = 1 && t <= PB_GREEDY_TEMP_THRESHOLD) {
			t := 0
		}

		return t
	}



	; Truncates the context to a char limit proportional to max_words.
	; Prevents oversized prefill tokens from driving up TTFT on short predictions.
	;
	; Param buffer     - The full context buffer.
	; Param maxWords   - Max predicted words (0 = unlimited).
	; Param ctxChars   - User-configured hard char cap (0 = no override). When
	;                    positive this is AUTHORITATIVE and wins over maxWords,
	;                    mirroring the shared Lua cap_context(). Omitting it is why
	;                    llm_context_length had no effect on the automatic path.
	; Returns string   - The possibly truncated context.
	_CapContext(buffer, maxWords, ctxChars := 0) {
		if (ctxChars && ctxChars > 0) {
			local bufLenOverride := StrLen(buffer)
			if (bufLenOverride <= ctxChars) {
				return buffer
			}
			return SubStr(buffer, bufLenOverride - ctxChars + 1)
		}
		if (!maxWords || maxWords <= 0) {
			return buffer
		}
		local charLimit := Max(PB_CONTEXT_MIN_CHARS, maxWords * PB_CONTEXT_CHARS_PER_WORD)
		local bufLen    := StrLen(buffer)
		if (bufLen <= charLimit) {
			return buffer
		}
		; Take the trailing charLimit characters (mirrors Lua's buffer:sub(-charLimit))
		return SubStr(buffer, bufLen - charLimit + 1)
	}



	; ======================
	; ===== 2.2) Build =====
	; ======================

	; Derives all LLM request parameters from the buffer and configuration.
	; This is the AHK counterpart of PromptBuilder.lua:build_params().
	;
	; Param buffer - The current typing buffer string.
	; Param config - Map with optional keys:
	;   max_words       (integer, default 0)
	;   min_words       (integer, default 1)
	;   num_predictions (integer, default 1)
	;   temperature     (float,   default 0.1)
	;   auto_raise_temp (boolean, default false)
	;   language        (string,  default "fr")
	; Returns Map - Keys: context, context_tail, max_tokens, temperature,
	;   min_words, max_words, language, num_predictions.
	Build(buffer, config := Map()) {
		local maxWords       := config.Has("max_words")       ? config["max_words"]       : 0
		local minWords       := config.Has("min_words")       ? config["min_words"]       : 1
		local numPredictions := config.Has("num_predictions") ? config["num_predictions"] : 1
		local temperature    := config.Has("temperature")     ? config["temperature"]     : 0.1
		local autoRaise      := config.Has("auto_raise_temp") ? config["auto_raise_temp"] : false
		local language       := config.Has("language")        ? config["language"]        : "fr"

		local tail    := this._ExtractTail(buffer)
		local ctxChars       := config.Has("context_window_chars") ? config["context_window_chars"] : 0
		local context := this._CapContext(buffer, maxWords, ctxChars)

		return Map(
			"context",          context,
			"context_tail",     tail,
			"max_tokens",       this._ComputeMaxTokens(maxWords),
			"temperature",      this._ComputeTemperature(temperature, numPredictions, autoRaise),
			"min_words",        minWords,
			"max_words",        maxWords,
			"language",         language,
			"num_predictions",  numPredictions
		)
	}

}