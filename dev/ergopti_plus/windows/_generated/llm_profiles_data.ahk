; static/ergopti_plus/windows/_generated/llm_profiles_data.ahk

; ==========================================
; AUTO-GENERATED — do not edit manually
; Sources: static/ergopti_plus/_shared/modules/llm/legacy_ids.json, static/ergopti_plus/_shared/modules/llm/profiles.json
; Run: npm run codegen:llm-profiles-data:ahk
; ==========================================

; ==============================================================================
; MODULE: LLM Profiles Data (generated)
; DESCRIPTION:
; Two small domain facts extracted from the shared LLM profile registry so the
; AHK driver never hand-maintains a copy that can drift from the JSON source:
;   LLM_LEGACY_IDS   — profile-ID migration table.
;   LLM_GetBasicPrompt() — the "basic" profile system prompt, used as the
;     resolver fallback when no profile-specific prompt is available.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Legacy Profile ID Migration =======
; ==============================================
; ==============================================

; Renamed profile ids from earlier releases -> their current id.
global LLM_LEGACY_IDS := Map(
	"parallel", "basic",
	"batch", "batch_advanced",
	"parallel_advanced", "advanced",
	"base_completion", "raw"
)





; ========================================
; ========================================
; ======= 2/ Basic Prompt Fallback =======
; ========================================
; ========================================

; Returns the "basic" profile system prompt — the resolver fallback when a
; profile is missing or malformed. Sourced from profiles.json so it can never
; drift from the profile the user actually sees when nothing else applies.
LLM_GetBasicPrompt() {
	return "You are an ultra-concise keyboard completion engine.`nUser context: {context}`n`nOutput strictly the immediate continuation of the context.`nABSOLUTE RULE: generate AT LEAST {min_words} words and AT MOST {max_words} words. NOT ONE WORD MORE OR LESS.`nMatch the language of the context. If the context language is ambiguous, default to {language}.`nNo explanation, no comment, no list, no bullet, no quote, no rephrasing of the context.`nReturn only the words to append."
}