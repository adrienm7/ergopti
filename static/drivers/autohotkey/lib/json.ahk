; lib/json.ahk

; ==============================================================================
; MODULE: Minimal JSON Parser
; DESCRIPTION:
; Pure-AHK v2 recursive-descent JSON parser. Returns Map for objects, Array for
; arrays, plain numbers/strings/booleans for primitives, and the JSON_NULL
; sentinel for null. There is no JSON encoder here — the modules that need to
; persist data already do so via hand-rolled writers tuned to their schema.
;
; FEATURES & RATIONALE:
; 1. Self-contained: AHK ships no JSON parser and we deliberately avoid
;    ComObject('MSScriptControl.ScriptControl') because it is unavailable on
;    64-bit AHK and deprecated on modern Windows. A 150-line hand-rolled
;    parser keeps the driver dependency-free.
; 2. Map for objects: AHK v2's Map preserves insertion order, which we rely
;    on to keep models.json's curated provider / family ordering intact when
;    rendering the tray menu.
; 3. JSON_NULL sentinel: AHK Maps cannot store the language's "no value", so
;    a global sentinel object stands in for JSON null. Callers must compare
;    against ``JSON_NULL`` rather than checking for an unset value.
; 4. Throws on syntax error: catches up the call site with a descriptive
;    Error rather than silently producing a corrupted half-tree.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ==============================
; ======= 1/ Constants =========
; ==============================
; ==============================

; Sentinel used in place of JSON ``null`` — Maps cannot hold AHK's nil value,
; so callers compare against this object identity (``v == JSON_NULL``) to
; detect a JSON null field.
global JSON_NULL := Object()




; ============================
; ============================
; ======= 2/ Public API ======
; ============================
; ============================

/**
 * Parses a JSON document into AHK structures.
 * @param {string} text - The raw JSON text.
 * @returns The root value (Map / Array / String / Number / Boolean / JSON_NULL).
 */
JsonParse(text) {
	pos := 1
	val := _JsonParseValue(&text, &pos)
	_JsonSkipWs(&text, &pos)
	return val
}




; =================================
; =================================
; ======= 3/ Internal Parser ======
; =================================
; =================================

_JsonSkipWs(&text, &pos) {
	len := StrLen(text)
	while (pos <= len) {
		c := SubStr(text, pos, 1)
		if (c == " " or c == "`t" or c == "`r" or c == "`n")
			pos++
		else
			return
	}
}

_JsonParseValue(&text, &pos) {
	_JsonSkipWs(&text, &pos)
	if (pos > StrLen(text))
		throw Error("JSON: unexpected end of input.", -1)
	c := SubStr(text, pos, 1)
	if (c == "{")
		return _JsonParseObject(&text, &pos)
	if (c == "[")
		return _JsonParseArray(&text, &pos)
	if (c == '"')
		return _JsonParseString(&text, &pos)
	if (c == "t" or c == "f")
		return _JsonParseBool(&text, &pos)
	if (c == "n")
		return _JsonParseNull(&text, &pos)
	return _JsonParseNumber(&text, &pos)
}

_JsonParseObject(&text, &pos) {
	pos++  ; consume {
	obj := Map()
	; Default case sensitivity is on — keep it so JSON keys keep their casing
	; semantics (e.g. capitalised AHK Map keys would otherwise collide with
	; lower-cased JSON keys at lookup time).
	_JsonSkipWs(&text, &pos)
	if (SubStr(text, pos, 1) == "}") {
		pos++
		return obj
	}
	loop {
		_JsonSkipWs(&text, &pos)
		if (SubStr(text, pos, 1) != '"')
			throw Error("JSON: expected string key at position " . pos . ".", -1)
		key := _JsonParseString(&text, &pos)
		_JsonSkipWs(&text, &pos)
		if (SubStr(text, pos, 1) != ":")
			throw Error("JSON: expected ':' at position " . pos . ".", -1)
		pos++  ; consume :
		val := _JsonParseValue(&text, &pos)
		obj[key] := val
		_JsonSkipWs(&text, &pos)
		c := SubStr(text, pos, 1)
		if (c == ",") {
			pos++
			continue
		}
		if (c == "}") {
			pos++
			return obj
		}
		throw Error("JSON: expected ',' or '}' at position " . pos . ".", -1)
	}
}

_JsonParseArray(&text, &pos) {
	pos++  ; consume [
	arr := []
	_JsonSkipWs(&text, &pos)
	if (SubStr(text, pos, 1) == "]") {
		pos++
		return arr
	}
	loop {
		val := _JsonParseValue(&text, &pos)
		arr.Push(val)
		_JsonSkipWs(&text, &pos)
		c := SubStr(text, pos, 1)
		if (c == ",") {
			pos++
			continue
		}
		if (c == "]") {
			pos++
			return arr
		}
		throw Error("JSON: expected ',' or ']' at position " . pos . ".", -1)
	}
}

_JsonParseString(&text, &pos) {
	pos++  ; consume opening "
	out := ""
	len := StrLen(text)
	while (pos <= len) {
		c := SubStr(text, pos, 1)
		if (c == '"') {
			pos++
			return out
		}
		if (c == "``") {  ; AHK escape — we won't see literal backtick in JSON
			pos++
			out .= c
			continue
		}
		if (c == "\") {
			pos++
			esc := SubStr(text, pos, 1)
			pos++
			switch esc {
				case '"': out .= '"'
				case "\": out .= "\"
				case "/": out .= "/"
				case "b": out .= Chr(8)
				case "f": out .= Chr(12)
				case "n": out .= "`n"
				case "r": out .= "`r"
				case "t": out .= "`t"
				case "u":
					; Standard JSON \uXXXX escape — decode to a single code unit.
					hex := SubStr(text, pos, 4)
					pos += 4
					out .= Chr("0x" . hex)
				default:
					throw Error("JSON: invalid escape sequence at position " . pos . ".", -1)
			}
		} else {
			out .= c
			pos++
		}
	}
	throw Error("JSON: unterminated string starting near position " . pos . ".", -1)
}

_JsonParseNumber(&text, &pos) {
	start := pos
	len := StrLen(text)
	if (SubStr(text, pos, 1) == "-")
		pos++
	while (pos <= len) {
		c := SubStr(text, pos, 1)
		if (c == "")
			break
		; AHK v2's relational operators (>= / <=) coerce both sides to a
		; number when one looks numeric — so ``c >= "0"`` throws on a
		; non-numeric char like "," with "Expected a Number but got a
		; String." Resolve via Ord() instead: code 48-57 is "0"-"9".
		code := Ord(c)
		if (code >= 48 and code <= 57)
			pos++
		else if (c == "." or c == "e" or c == "E" or c == "+" or c == "-")
			pos++
		else
			break
	}
	s := SubStr(text, start, pos - start)
	; Coerce to number — AHK's ``+ 0`` returns Integer or Float depending on
	; whether the source had a decimal point or exponent.
	return s + 0
}

_JsonParseBool(&text, &pos) {
	if (SubStr(text, pos, 4) == "true") {
		pos += 4
		return true
	}
	if (SubStr(text, pos, 5) == "false") {
		pos += 5
		return false
	}
	throw Error("JSON: expected boolean literal at position " . pos . ".", -1)
}

_JsonParseNull(&text, &pos) {
	if (SubStr(text, pos, 4) == "null") {
		pos += 4
		return JSON_NULL
	}
	throw Error("JSON: expected 'null' literal at position " . pos . ".", -1)
}
