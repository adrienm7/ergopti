; _shared/modules/features/caps_word_auto_off_policy.ahk

; ==============================================================================
; MODULE: CapsWord Auto-Off Policy
; DESCRIPTION:
; AutoHotkey port of _shared/lua/caps_word/auto_off.lua: decides what ends
; CapsWord on its own from the [shortcuts.caps_word] settings (a delay without
; a keystroke, the word delimiters of the hotstring delimiter catalogue, the
; pointer kinds of [shortcuts.caps_word.pointer]). Both ports replay
; _shared/tests/corpus/caps_word/auto_off_vectors.json. The driver keeps event
; detection, timers and the deactivation itself.
;
; FEATURES & RATIONALE:
; 1. One Catalogue: the delimiters are the generated Terminators class's
;    built-in entries (_generated/terminators.ahk, from Terminators.spec.js),
;    never a list of this module's own.
; 2. Typed Values: AutoHotkey's `is Integer` admits numeric strings, so every
;    check reads Type(): a quoted "5" stays a refused delay, as in Lua.
; 3. Fail Fast: CapsWordAutoOffCompile refuses with the Lua reasons; asking
;    about an unknown delimiter key or an undeclared pointer kind throws.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Catalogue =======
; ============================
; ============================

; The built-in catalogue entries in their order, separators included, read
; once from the generated class (a fresh instance: user custom delimiters and
; the magic-key rename belong to the hotstring engine's own instance).
_CapsWordAutoOffCatalogue() {
	static Entries := Terminators().all()
	return Entries
}

; Built-in delimiter key -> its characters.
_CapsWordAutoOffCharsByKey() {
	static ByKey := ""
	if !(ByKey is Map) {
		ByKey := Map()
		for Entry in _CapsWordAutoOffCatalogue() {
			if Entry.Get("type", "") != "separator"
				ByKey[Entry["key"]] := Entry["chars"]
		}
	}
	return ByKey
}

; Whether Key names a built-in delimiter of the hotstring catalogue.
; @param Key {Any} Candidate delimiter key.
; @returns {Boolean}
CapsWordAutoOffIsTerminatorKey(Key) {
	return Type(Key) == "String" && _CapsWordAutoOffCharsByKey().Has(Key)
}

; AutoHotkey keeps TOML and JSON booleans as the integers 0 and 1.
_CapsWordAutoOffIsBoolean(Value) {
	return Type(Value) == "Integer" && (Value == 0 || Value == 1)
}





; ======================================
; ======================================
; ======= 2/ Settings Validation =======
; ======================================
; ======================================

; Validates the stored inactivity delay (seconds, 0 = never).
; @param Value {Any} Candidate number of seconds.
; @param Reason {VarRef} Receives the stable refusal reason.
; @returns {Boolean}
CapsWordAutoOffValidateIdleTimeout(Value, &Reason := "") {
	Reason := ""
	Kind := Type(Value)
	; NaN compares unequal to itself; an infinity survives no subtraction.
	if (Kind != "Integer" && Kind != "Float") || Value != Value || (Value - Value) != 0 || Value < 0 {
		Reason := "invalid_idle_timeout"
		return false
	}
	return true
}

; Validates the stored delimiter list: unique built-in catalogue keys.
; @param Value {Any} Candidate Array of delimiter keys.
; @param Reason {VarRef} Receives the stable refusal reason.
; @returns {Boolean}
CapsWordAutoOffValidateTerminators(Value, &Reason := "") {
	Reason := ""
	if !(Value is Array) {
		Reason := "invalid_terminators"
		return false
	}
	Seen := Map()
	for Key in Value {
		if !CapsWordAutoOffIsTerminatorKey(Key) {
			Reason := "unknown_terminator"
			return false
		}
		if Seen.Has(Key) {
			Reason := "duplicate_terminator"
			return false
		}
		Seen[Key] := true
	}
	return true
}

; Compiles validated settings into a policy Map.
; @param Values {Map} "idle_timeout_seconds", "terminators", "pointer".
; @param PointerKinds {Array} The declared pointer kind ids.
; @param Reason {VarRef} Receives the stable refusal reason.
; @returns {Map|String} The policy, or "" when refused.
CapsWordAutoOffCompile(Values, PointerKinds, &Reason := "") {
	Reason := ""
	if !(Values is Map) {
		Reason := "invalid_settings"
		return ""
	}
	if !(PointerKinds is Array) || PointerKinds.Length == 0 {
		Reason := "invalid_pointer_kinds"
		return ""
	}
	if !CapsWordAutoOffValidateIdleTimeout(Values.Get("idle_timeout_seconds", ""), &Reason)
		return ""
	if !CapsWordAutoOffValidateTerminators(Values.Get("terminators", ""), &Reason)
		return ""
	Pointer := Values.Get("pointer", "")
	if !(Pointer is Map) {
		Reason := "invalid_pointer"
		return ""
	}
	Declared := Map()
	Kinds := Map()
	for Kind in PointerKinds {
		if Type(Kind) != "String" || Kind == "" || Declared.Has(Kind) {
			Reason := "invalid_pointer_kinds"
			return ""
		}
		Declared[Kind] := true
		if !Pointer.Has(Kind) || !_CapsWordAutoOffIsBoolean(Pointer[Kind]) {
			Reason := "invalid_pointer"
			return ""
		}
		Kinds[Kind] := Pointer[Kind] == 1
	}
	for Kind in Pointer {
		if !Declared.Has(Kind) {
			Reason := "unknown_pointer_kind"
			return ""
		}
	}
	Keys := Map()
	Chars := Map()
	ByKey := _CapsWordAutoOffCharsByKey()
	for Key in Values["terminators"] {
		Keys[Key] := true
		for Char in ByKey[Key]
			Chars[Char] := true
	}
	Seconds := Values["idle_timeout_seconds"]
	return Map(
		"idle_ms", Seconds > 0 ? Round(Seconds * 1000) : 0,
		"keys", Keys,
		"chars", Chars,
		"pointer", Kinds)
}





; =====================================
; =====================================
; ======= 3/ Deactivation Rules =======
; =====================================
; =====================================

_CapsWordAutoOffRequirePolicy(Policy) {
	if !(Policy is Map) || !Policy.Has("keys") || !Policy.Has("chars") || !Policy.Has("pointer")
		throw ValueError("CapsWord auto-off: a compiled policy is required")
}

; Whether one typed payload ends CapsWord: any of its characters belongs to a
; checked delimiter (a spaced punctuation carrier or an IME commit is read
; character by character).
; @param Policy {Map} Compiled policy.
; @param Text {Any} Characters of one typed event.
; @returns {Boolean}
CapsWordAutoOffEndsOnText(Policy, Text) {
	_CapsWordAutoOffRequirePolicy(Policy)
	if Type(Text) != "String" || Text == ""
		return false
	Chars := Policy["chars"]
	if Chars.Has(Text)
		return true
	; Every catalogue character is in the BMP, so a UTF-16 unit is a character.
	Loop Parse Text {
		if Chars.Has(A_LoopField)
			return true
	}
	return false
}

; Whether a native key the driver binds itself ends CapsWord, by the delimiter
; key it types.
; @param Policy {Map} Compiled policy.
; @param Key {String} Built-in delimiter key.
; @returns {Boolean}
CapsWordAutoOffEndsOnKey(Policy, Key) {
	_CapsWordAutoOffRequirePolicy(Policy)
	if !CapsWordAutoOffIsTerminatorKey(Key)
		throw ValueError("CapsWord auto-off: unknown delimiter key " . String(Key))
	return Policy["keys"].Has(Key)
}

; Whether a pointer event of a declared kind ends CapsWord.
; @param Policy {Map} Compiled policy.
; @param Kind {String} Declared pointer kind id.
; @returns {Boolean}
CapsWordAutoOffEndsOnPointer(Policy, Kind) {
	_CapsWordAutoOffRequirePolicy(Policy)
	if Type(Kind) != "String" || !Policy["pointer"].Has(Kind)
		throw ValueError("CapsWord auto-off: undeclared pointer kind " . String(Kind))
	return Policy["pointer"][Kind]
}

; The inactivity delay in milliseconds, 0 when CapsWord never times out.
; @param Policy {Map} Compiled policy.
; @returns {Integer}
CapsWordAutoOffIdleDelayMs(Policy) {
	_CapsWordAutoOffRequirePolicy(Policy)
	return Policy["idle_ms"]
}

; Whether the delay has passed since the last keystroke.
; @param Policy {Map} Compiled policy.
; @param LastMs {Number} Clock of the last keystroke (or the activation).
; @param NowMs {Number} Same clock, now.
; @returns {Boolean}
CapsWordAutoOffIdleExpired(Policy, LastMs, NowMs) {
	_CapsWordAutoOffRequirePolicy(Policy)
	for Value in [LastMs, NowMs] {
		if Type(Value) != "Integer" && Type(Value) != "Float"
			throw ValueError("CapsWord auto-off: IdleExpired needs two clock readings")
	}
	return Policy["idle_ms"] > 0 && NowMs - LastMs >= Policy["idle_ms"]
}





; ===============================
; ===============================
; ======= 4/ Menu Helpers =======
; ===============================
; ===============================

; The delimiter checkbox rows, in catalogue order with its separators.
; @returns {Array} Maps with "key" and "label_key", or "separator" = true.
CapsWordAutoOffTerminatorRows() {
	Rows := []
	for Entry in _CapsWordAutoOffCatalogue() {
		if Entry.Get("type", "") == "separator"
			Rows.Push(Map("separator", true))
		else
			Rows.Push(Map("key", Entry["key"], "label_key", Entry["label_key"]))
	}
	return Rows
}

; The delimiter list with Key checked or unchecked, in catalogue order, so
; every driver stores the same array for the same choice.
; @param List {Array} Valid current delimiter list.
; @param Key {String} Built-in delimiter key.
; @param Checked {Integer} Wanted state, 1 or 0.
; @param Reason {VarRef} Receives the stable refusal reason.
; @returns {Array|String} The new list, or "" when refused.
CapsWordAutoOffWithTerminator(List, Key, Checked, &Reason := "") {
	Reason := ""
	if !CapsWordAutoOffValidateTerminators(List, &Reason)
		return ""
	if !CapsWordAutoOffIsTerminatorKey(Key) {
		Reason := "unknown_terminator"
		return ""
	}
	if !_CapsWordAutoOffIsBoolean(Checked) {
		Reason := "invalid_state"
		return ""
	}
	Wanted := Map()
	for Current in List
		Wanted[Current] := true
	if Checked
		Wanted[Key] := true
	else if Wanted.Has(Key)
		Wanted.Delete(Key)
	Out := []
	for Entry in _CapsWordAutoOffCatalogue() {
		if Entry.Get("type", "") != "separator" && Wanted.Has(Entry["key"])
			Out.Push(Entry["key"])
	}
	return Out
}
