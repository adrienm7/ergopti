; infra/json.ahk

; ==============================================================================
; MODULE: Minimal JSON Codec
; DESCRIPTION:
; Pure-AHK v2 recursive-descent JSON parser. Returns Map for objects, Array for
; arrays, plain numbers/strings/booleans for primitives, and the JSON_NULL
; sentinel for null. JsonStringLiteral is the shared encoder for strings placed
; in JSON documents or JavaScript source; schema-specific writers own containers.
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





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

/**
 * Parses a JSON document into AHK structures.
 * @param {string} text - The raw JSON text.
 * @returns The root value (Map / Array / String / Number / Boolean / JSON_NULL).
 */
JsonParse(text) {
	pos := 1
	val := _JsonParseValue(&text, &pos)
	_JsonSkipWs(&text, &pos)
	if (pos <= StrLen(text))
		throw Error("JSON: unexpected trailing data at position " . pos . ".", -1)
	return val
}

/**
 * Encodes one value as a complete JSON string literal.
 * @param value Value converted to String before encoding.
 * @param {boolean} escapeHtml Also neutralise HTML parser delimiters when the
 * literal is embedded in an inline script element.
 * @returns {string} A quoted JSON/JavaScript string literal.
 */
JsonStringLiteral(value, escapeHtml := false) {
	text := String(value)
	out := '"'
	Loop Parse, text {
		char := A_LoopField
		code := Ord(char)
		switch code {
			case 0x08: out .= "\b"
			case 0x09: out .= "\t"
			case 0x0A: out .= "\n"
			case 0x0C: out .= "\f"
			case 0x0D: out .= "\r"
			case 0x22: out .= '\"'
			case 0x5C: out .= "\\"
			default:
				if (code < 0x20 or code = 0x2028 or code = 0x2029
						or (escapeHtml and (code = 0x26 or code = 0x3C or code = 0x3E)))
					out .= Format("\u{:04x}", code)
				else
					out .= char
		}
	}
	return out . '"'
}





; ==================================
; ==================================
; ======= 3/ Internal Parser =======
; ==================================
; ==================================

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
		if (Ord(c) < 0x20)
			throw Error("JSON: unescaped control character at position " . pos . ".", -1)
		if (c == '"') {
			pos++
			return out
		}
		if (c == '``') {  ; AHK escape — we won't see literal backtick in JSON
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
					; Standard JSON \uXXXX escape — decode with surrogate-pair support.
					hex := SubStr(text, pos, 4)
					if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
						throw Error("JSON: invalid \u escape at position " . pos . ".", -1)
					pos += 4
					cp := Integer("0x" . hex)
					; UTF-16 surrogate pair: high surrogate (D800-DBFF) must be followed
					; by a low surrogate (DC00-DFFF) to form a non-BMP codepoint.
					if (cp >= 0xD800 and cp <= 0xDBFF) {
						if (SubStr(text, pos, 2) != "\u")
							throw Error("JSON: high surrogate without low surrogate at position " . pos . ".", -1)
						hex2 := SubStr(text, pos + 2, 4)
						if !RegExMatch(hex2, "^[0-9A-Fa-f]{4}$")
							throw Error("JSON: invalid low surrogate at position " . (pos + 2) . ".", -1)
						low := Integer("0x" . hex2)
						if (low < 0xDC00 or low > 0xDFFF)
							throw Error("JSON: high surrogate without low surrogate at position " . pos . ".", -1)
						pos += 6
						cp := 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
					} else if (cp >= 0xDC00 and cp <= 0xDFFF) {
						throw Error("JSON: isolated low surrogate at position " . (pos - 4) . ".", -1)
					}
					out .= Chr(cp)
				default:
					throw Error("JSON: invalid escape sequence at position " . pos . ".", -1)
			}
		} else {
			; Fast-path: copy the whole run of plain characters up to the next
			; delimiter (" / \ / backtick) in one slice instead of appending one
			; char at a time — the per-char ``out .= c`` is O(n^2) over the long
			; unescaped spans that dominate locale strings (parsed once at boot
			; for every i18n value). Behaviour is identical: the loop stops on the
			; same delimiter the outer switch already handles
			runStart := pos
			pos++
			while (pos <= len) {
				cc := SubStr(text, pos, 1)
				if (Ord(cc) < 0x20)
					throw Error("JSON: unescaped control character at position " . pos . ".", -1)
				if (cc == '"' or cc == "\" or cc == '``')
					break
				pos++
			}
			out .= SubStr(text, runStart, pos - runStart)
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
	; Validate before coercion using the full JSON number grammar so malformed
	; inputs like "1.2.3", "1e", "123-456" are caught here rather than
	; propagating to AHK's + 0 coercion which surfaces a confusing internal error.
	; JSON number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
	if (s == "" or !RegExMatch(s, "^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"))
		throw Error("JSON: invalid number at position " . start . ".", -1)
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
