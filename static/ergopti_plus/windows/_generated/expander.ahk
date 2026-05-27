; static/ergopti_plus/windows/_generated/expander.ahk

; ==========================================
; AUTO-GENERATED — do not edit manually
; Source: static/ergopti_plus/_shared/domain/expander.spec.js
; Run: npm run codegen:expander:ahk
; ==========================================

; ==============================================================================
; MODULE: Expander
; DESCRIPTION:
; AHK v2 implementation of the Expander domain contract. Given the current
; typing buffer and a tail character, queries the Registry for candidate
; mappings, selects the best match, and returns an ExpansionResult Map.
;
; FEATURES & RATIONALE:
; 1. Stateless expansion decision: Decide() is a pure function over the
;    Registry — it calls no OS API and owns no persistent buffer.
; 2. Word-boundary enforcement: mappings with is_word=true only fire when
;    the character immediately before the trigger is a non-word char or the
;    buffer starts at that position.
; 3. Magic-key cycling: CycleNext() selects the next mapping in the star
;    bucket for the same trigger base; Reset() clears that state.
; 4. Backspace count: trigger byte length (UTF-16 char count) plus 1 when
;    the terminator was consumed by the expansion.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Word-Boundary Helpers =======
; ========================================
; ========================================

; Returns true when ch is a word character (letter, digit, or underscore).
; Used by Expander.Decide() to enforce the is_word boundary rule.
;
; Param ch - A single character string.
; Returns boolean.
_Expander_IsWordChar(ch) {
	return RegExMatch(ch, "[\w]") > 0
}





; =================================
; =================================
; ======= 2/ Expander Class =======
; =================================
; =================================

class Expander {

	; ===============================
	; ===== 2.1) Instance State =====
	; ===============================

	; _registry : Registry
	; Injected Registry instance used for all MappingsForTail() queries.
	_registry := ""

	; _cycle_base : string
	; star_base of the last successfully expanded magic-key trigger.
	; Empty string when no cycle is in progress.
	_cycle_base := ""

	; _cycle_index : integer
	; Zero-based index into the current star-bucket for cycling.
	_cycle_index := 0

	; _cycle_bucket : Array
	; Snapshot of the star-bucket captured at the start of a cycle.
	_cycle_bucket := []



	; ============================
	; ===== 2.2) Constructor =====
	; ============================

	; Initialises the Expander with a Registry instance.
	;
	; Param registry - A Registry object exposing MappingsForTail(tailChar).
	__New(registry) {
		this._registry := registry
	}



	; =======================
	; ===== 2.3) Decide =====
	; =======================

	; Decides whether to expand based on buffer + tailChar.
	; Queries MappingsForTail(tailChar), iterates candidates longest-first,
	; checks suffix match and optional word-boundary, and returns the first hit.
	;
	; Param buffer   - Full typing buffer (everything since last reset).
	; Param tailChar - The character just typed (terminator or auto-trigger tail).
	; Param opts     - Map with optional key terminator_consumed (boolean).
	; Returns Map    - ExpansionResult fields, or empty Map() when no match.
	Decide(buffer, tailChar, opts) {
		local termConsumed := (opts.Has("terminator_consumed") && opts["terminator_consumed"])
		local candidates   := this._registry.MappingsForTail(tailChar)

		for m in candidates {
			local trigger := m["trigger"]
			local tlen    := m["tlen"]

			; Buffer must be at least as long as the trigger
			if (StrLen(buffer) < tlen) {
				continue
			}

			; Check suffix match: last tlen chars of buffer must equal trigger
			local suffix := SubStr(buffer, -(tlen - 1))
			if (suffix != trigger) {
				continue
			}

			; Word-boundary check when is_word is set
			if (m["is_word"]) {
				local bufLen  := StrLen(buffer)
				local preLen  := bufLen - tlen
				if (preLen > 0) {
					local preCh := SubStr(buffer, preLen, 1)
					if (_Expander_IsWordChar(preCh)) {
						continue ; Trigger is mid-word — skip
					}
				}
				; preLen = 0 means buffer starts at trigger — boundary satisfied
			}

			; Match found — compute backspace count
			; Backspaces = trigger char count + 1 if terminator was consumed
			local bsCount := tlen + (termConsumed ? 1 : 0)

			; Capture cycling state for potential CycleNext() call
			if (m["has_magic"]) {
				this._cycle_base   := m["star_base"]
				this._cycle_index  := 1
				this._cycle_bucket := this._BuildStarBucket(m["star_base"])
			} else {
				this._cycle_base   := ""
				this._cycle_index  := 0
				this._cycle_bucket := []
			}

			return Map(
				"replacement",       m["plain_repl"],
				"backspace_count",   bsCount,
				"consume_terminator", termConsumed,
				"is_final",          m["final_result"],
				"group",             m["group"],
				"trigger",           trigger,
				"color",             m["color"]
			)
		}

		; No candidate matched
		return Map()
	}



	; ==========================
	; ===== 2.4) CycleNext =====
	; ==========================

	; Advances to the next mapping in the magic-key star bucket.
	; Called when the user presses the magic key after a successful expansion.
	; Wraps around to the first candidate when the end of the bucket is reached.
	;
	; Param buffer - Buffer state at cycle time (used to validate star_base).
	; Returns Map  - Next ExpansionResult, or false when no cycle is active.
	CycleNext(buffer) {
		if (this._cycle_base = "" || this._cycle_bucket.Length = 0) {
			return false
		}

		local bucket := this._cycle_bucket
		local idx    := this._cycle_index

		; Wrap around if index exceeds bucket size
		if (idx > bucket.Length) {
			idx := 1
		}

		local m     := bucket[idx]
		local tlen  := m["tlen"]
		; Backspace count covers the previously inserted replacement + magic key
		; The caller is responsible for the replacement length; here we supply trigger length
		local bsCount := tlen + 1 ; +1 for the magic key itself

		; Advance index for the next call, wrapping at bucket end
		this._cycle_index := (idx >= bucket.Length) ? 1 : idx + 1

		return Map(
			"replacement",        m["plain_repl"],
			"backspace_count",    bsCount,
			"consume_terminator", true,
			"is_final",           m["final_result"],
			"group",              m["group"],
			"trigger",            m["trigger"],
			"color",              m["color"]
		)
	}



	; ======================
	; ===== 2.5) Reset =====
	; ======================

	; Clears all magic-key cycling state.
	; Call on Escape, window focus change, or buffer reset.
	Reset() {
		this._cycle_base   := ""
		this._cycle_index  := 0
		this._cycle_bucket := []
	}



	; ================================
	; ===== 2.6) Private Helpers =====
	; ================================

	; Collects all mappings sharing the given star_base from the registry.
	; The result is used as the cycling bucket for CycleNext().
	;
	; Param starBase - The trigger string without its trailing magic-key character.
	; Returns Array  - Sorted array of matching Mapping objects.
	_BuildStarBucket(starBase) {
		local starTailChar := (StrLen(starBase) > 0) ? SubStr(starBase, -0) : ""
		if (starTailChar = "") {
			return []
		}

		local candidates := this._registry.MappingsForTail(starTailChar)
		local bucket     := []
		for m in candidates {
			if (m["has_magic"] && m["star_base"] = starBase) {
				bucket.Push(m)
			}
		}
		return bucket
	}

}