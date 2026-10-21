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
; 4. Throws on syntax errors and NUL object keys, which native Maps cannot
;    represent, rather than silently producing a corrupted half-tree.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include number.ahk
#Include ../adapters/native_text.ahk




; ==============================
; ==============================
; ======= 1/ Constants =========
; ==============================
; ==============================

; Sentinel used in place of JSON ``null`` — Maps cannot hold AHK's nil value,
; so callers compare against this object identity (``v == JSON_NULL``) to
; detect a JSON null field.
global JSON_NULL := Object()
global JSON_MAX_NESTING_DEPTH := 128

; Cumulative decode accounting of this process: containers (objects and arrays)
; built and string code units decoded. Validated values that a caller did not
; ask for are never built, so a decode budget is a deterministic count rather
; than a wall-clock measure.
global _JsonTallyContainers := 0
global _JsonTallyStringUnits := 0





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
	val := _JsonParseValue(&text, &pos, 0)
	_JsonSkipWs(&text, &pos)
	if (pos <= StrLen(text))
		throw Error("JSON: unexpected trailing data at position " . pos . ".", -1)
	return val
}

/**
 * Returns original JSON member spans for an object selected by decoded key parts.
 * Validates the complete document first and retains the parser's last-member-wins
 * identity. Offsets are one-based UTF-16 positions for SubStr, not byte offsets.
 * @param {string} text Complete JSON source.
 * @param {Array} pathParts Decoded object keys, or omitted for the root object.
 * @returns {Map} Decoded key -> value/member start, length and exact source text.
 * @throws {Error} Invalid JSON, a missing key or a selected non-object value.
 */
JsonObjectMemberSpans(text, pathParts := unset) {
	JsonParse(text)
	parts := IsSet(pathParts) ? pathParts : []
	if !(parts is Array)
		throw TypeError("JSON member paths require an array of decoded string keys.")
	position := 1
	for part in parts {
		if !(part is String)
			throw TypeError("JSON member paths require decoded string keys.")
		; Native Map keys stop at NUL; reject the complete decoded part before lookup.
		loop StrLen(part)
			if NumGet(StrPtr(part), (A_Index - 1) * 2, "UShort") = 0
				throw ValueError("JSON member paths cannot contain NUL code units.")
		members := _JsonObjectMemberSpansAt(&text, position)
		if !members.Has(part)
			throw ValueError("JSON object has no selected member.", -1, part)
		position := members[part]["start"]
	}
	return _JsonObjectMemberSpansAt(&text, position)
}

; The public span owner validates the whole source before walking selected objects.
; Reuse the codec's own token progress rather than a second JSON scanner.
_JsonObjectMemberSpansAt(&text, position) {
	_JsonSkipWs(&text, &position)
	if (SubStr(text, position, 1) != "{")
		throw TypeError("Selected JSON member is not an object.")
	position++
	members := Map()
	_JsonSkipWs(&text, &position)
	if (SubStr(text, position, 1) == "}")
		return members
	loop {
		_JsonSkipWs(&text, &position)
		memberStart := position
		key := _JsonParseString(&text, &position, true)
		_JsonSkipWs(&text, &position)
		position++
		_JsonSkipWs(&text, &position)
		valueStart := position
		_JsonParseValue(&text, &position, 1)
		members[key] := Map("start", valueStart, "length", position - valueStart,
			"text", SubStr(text, valueStart, position - valueStart),
			"member_start", memberStart, "member_length", position - memberStart,
			"member_text", SubStr(text, memberStart, position - memberStart))
		_JsonSkipWs(&text, &position)
		if (SubStr(text, position, 1) == "}")
			return members
		position++
	}
}

/**
 * Returns exact source spans for ordered elements of a complete JSON array.
 * Validates the whole document in the same single pass that records the spans,
 * with the canonical parser's own grammar, depth and trailing-data rules.
 * Native numeric/Boolean aliases therefore retain provenance in "text".
 * Offsets are one-based UTF-16 positions for SubStr, not byte offsets.
 * @param {string} text Complete JSON array source.
 * @returns {Array} Element start, length, original validated source text and
 *   decoded value (as JsonParse returns it).
 * @throws {Error} Invalid JSON or a root that is not an array.
 */
JsonArrayElementSpans(text) {
	position := 1
	_JsonSkipWs(&text, &position)
	if SubStr(text, position, 1) != "[" {
		; Invalid input keeps the parser's own syntax diagnostic.
		JsonParse(text)
		throw TypeError("Selected JSON source is not an array.")
	}
	position++
	spans := []
	_JsonSkipWs(&text, &position)
	if SubStr(text, position, 1) == "]" {
		position++
	} else {
		; Mirrors _JsonParseArray at the root's depth, keeping each element's span.
		loop {
			_JsonSkipWs(&text, &position)
			start := position
			value := _JsonParseValue(&text, &position, 1)
			spans.Push(Map("start", start, "length", position - start,
				"text", SubStr(text, start, position - start), "value", value))
			_JsonSkipWs(&text, &position)
			c := SubStr(text, position, 1)
			if (c == "]") {
				position++
				break
			}
			if (c != ",")
				throw Error("JSON: expected ',' or ']' at position " . position . ".", -1)
			position++
		}
	}
	_JsonSkipWs(&text, &position)
	if (position <= StrLen(text))
		throw Error("JSON: unexpected trailing data at position " . position . ".", -1)
	return spans
}

/**
 * Returns the source spans of the objects of a complete JSON array, with the
 * decoded values of only the named top-level members of each object. The whole
 * document is validated in the same single pass, with the canonical parser's
 * own grammar, depth, number and NUL-key rules; every other value is validated
 * but never built, so nested data nobody reads costs no allocation, and no
 * element text is copied (SubStr(text, start, length) is the caller's).
 * Duplicate members keep the parser's last-member-wins identity.
 * Offsets are one-based UTF-16 positions for SubStr, not byte offsets.
 * @param {string} text Complete JSON array source.
 * @param {Array} memberKeys Decoded keys whose values are decoded.
 * @returns {Array} Element "start", "length" and "members" (Map of each named
 *   member present to its decoded value).
 * @throws {Error} Invalid JSON; TypeError when the root or an element is not an
 *   object, at the first violation met.
 */
JsonArrayObjectMembers(text, memberKeys) {
	wanted := _JsonMemberSelection(memberKeys)
	position := 1
	_JsonSkipWs(&text, &position)
	if SubStr(text, position, 1) != "[" {
		; Invalid input keeps the parser's own syntax diagnostic.
		JsonParse(text)
		throw TypeError("Selected JSON source is not an array.")
	}
	position++
	spans := []
	; One native pass proves the text has no lone surrogate, which lets the
	; skipped values' fast path accept characters above U+FFFF.
	wellFormed := NativeTextIsWellFormedUtf16(StrPtr(text), StrLen(text))
	selection := { Keys: wanted, Run: _JsonSkipMembersRun(memberKeys, wellFormed) }
	_JsonSkipWs(&text, &position)
	if SubStr(text, position, 1) == "]" {
		position++
	} else {
		; Mirrors JsonArrayElementSpans at the root's depth; each element must be
		; an object, whose members are read by the parser's own object grammar.
		loop {
			_JsonSkipWs(&text, &position)
			start := position
			if SubStr(text, position, 1) != "{" {
				; A truncated document keeps its syntax diagnostic.
				_JsonSkipValue(&text, &position, 1, wellFormed)
				throw TypeError("JSON array element " . (spans.Length + 1) . " is not an object.")
			}
			members := _JsonParseObject(&text, &position, 1, selection, wellFormed)
			spans.Push(Map("start", start, "length", position - start, "members", members))
			_JsonSkipWs(&text, &position)
			c := SubStr(text, position, 1)
			if (c == "]") {
				position++
				break
			}
			if (c != ",")
				throw Error("JSON: expected ',' or ']' at position " . position . ".", -1)
			position++
		}
	}
	_JsonSkipWs(&text, &position)
	if (position <= StrLen(text))
		throw Error("JSON: unexpected trailing data at position " . position . ".", -1)
	return spans
}

/**
 * Decodes only the named top-level members of a complete JSON object, the
 * single-object form of JsonArrayObjectMembers: the whole document is
 * validated with the canonical parser's rules, and every other member value is
 * validated but never built.
 * @param {string} text Complete JSON object source.
 * @param {Array} memberKeys Decoded keys whose values are decoded.
 * @returns {Map} Each named member present, to its decoded value.
 * @throws {Error} Invalid JSON; TypeError when the root is not an object.
 */
JsonObjectMembers(text, memberKeys) {
	wanted := _JsonMemberSelection(memberKeys)
	position := 1
	_JsonSkipWs(&text, &position)
	if SubStr(text, position, 1) != "{" {
		; Invalid input keeps the parser's own syntax diagnostic.
		JsonParse(text)
		throw TypeError("Selected JSON source is not an object.")
	}
	wellFormed := NativeTextIsWellFormedUtf16(StrPtr(text), StrLen(text))
	selection := { Keys: wanted, Run: _JsonSkipMembersRun(memberKeys, wellFormed) }
	members := _JsonParseObject(&text, &position, 0, selection, wellFormed)
	_JsonSkipWs(&text, &position)
	if (position <= StrLen(text))
		throw Error("JSON: unexpected trailing data at position " . position . ".", -1)
	return members
}

; The decoded keys of a member selection, as a case-sensitive Map.
_JsonMemberSelection(memberKeys) {
	if !(memberKeys is Array)
		throw TypeError("JSON member selections require an array of decoded string keys.")
	wanted := Map()
	for key in memberKeys {
		if !(key is String)
			throw TypeError("JSON member selections require decoded string keys.")
		wanted[key] := true
	}
	return wanted
}

/**
 * Returns the cumulative decode accounting of this process.
 * @returns {Map} "containers" (objects and arrays built) and "string_units"
 *   (decoded string code units, keys included).
 */
JsonDecodeTally() {
	global _JsonTallyContainers, _JsonTallyStringUnits
	return Map("containers", _JsonTallyContainers, "string_units", _JsonTallyStringUnits)
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
	; Most manifest keys need no escaping; scan natively before allocating per character.
	if !RegExMatch(text, '[\x00-\x1f"\\\x{2028}\x{2029}]')
			&& (!escapeHtml || !RegExMatch(text, '[&<>]'))
		return '"' . text . '"'
	out := '"'
	; Loop Parse stops at NUL. Walk the stored UTF-16 length so escaping cannot
	; silently discard that code unit and every character following it.
	loop StrLen(text) {
		code := NumGet(StrPtr(text), (A_Index - 1) * 2, "UShort")
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
					out .= SubStr(text, A_Index, 1)
		}
	}
	return out . '"'
}

/**
 * Encodes the contents of a JSON string without the surrounding quotes.
 * @param value Value converted to String before encoding.
 * @param {boolean} escapeHtml Also neutralise HTML parser delimiters.
 * @returns {string} Escaped JSON string contents.
 */
JsonStringContents(value, escapeHtml := false) {
	literal := JsonStringLiteral(value, escapeHtml)
	return SubStr(literal, 2, StrLen(literal) - 2)
}

/**
 * Decodes JSON string contents whose surrounding quotes are owned by a caller.
 * @param {string} contents Valid escaped contents from a JSON string token.
 * @returns {string} The decoded string value.
 */
JsonStringDecodeContents(contents) {
	return JsonParse('"' . String(contents) . '"')
}





; ==================================
; ==================================
; ======= 3/ Internal Parser =======
; ==================================
; ==================================

; The NUL-terminated UTF-16 set of JSON insignificant whitespace.
_JsonWhitespaceUnits() {
	static Units := 0
	if !Units {
		Units := Buffer(10, 0)
		for Index, Unit in [0x20, 0x09, 0x0D, 0x0A]
			NumPut("UShort", Unit, Units, (Index - 1) * 2)
	}
	return Units
}

; Compact documents have no whitespace at most token boundaries, so one code
; unit is checked first; an indented one (GitHub's API answers indented) skips
; each run in one native scan instead of one SubStr per space.
_JsonSkipWs(&text, &pos) {
	if (pos > StrLen(text))
		return
	code := NumGet(StrPtr(text), (pos - 1) * 2, "UShort")
	if (code == 0x20 or code == 0x09 or code == 0x0D or code == 0x0A)
		pos += NativeTextSpanIncluding(StrPtr(text) + (pos - 1) * 2, _JsonWhitespaceUnits())
}

_JsonParseValue(&text, &pos, depth) {
	global JSON_MAX_NESTING_DEPTH
	if (depth > JSON_MAX_NESTING_DEPTH)
		throw Error("JSON: maximum nesting depth exceeded at position " . pos . ".", -1)
	_JsonSkipWs(&text, &pos)
	if (pos > StrLen(text))
		throw Error("JSON: unexpected end of input.", -1)
	c := SubStr(text, pos, 1)
	if (depth == JSON_MAX_NESTING_DEPTH and (c == "{" or c == "["))
		throw Error("JSON: maximum nesting depth exceeded at position " . pos . ".", -1)
	if (c == "{")
		return _JsonParseObject(&text, &pos, depth)
	if (c == "[")
		return _JsonParseArray(&text, &pos, depth)
	if (c == '"')
		return _JsonParseString(&text, &pos)
	if (c == "t" or c == "f")
		return _JsonParseBool(&text, &pos)
	if (c == "n")
		return _JsonParseNull(&text, &pos)
	return _JsonParseNumber(&text, &pos)
}

; With a selection { Keys, Run }, only the members Keys names are decoded into
; the returned Map. Every other member is validated, never built: a run of them
; by the Run pattern (_JsonSkipMembersRun), the rest by _JsonSkipValue
; (WellFormed is passed on to it).
_JsonParseObject(&text, &pos, depth, selection := 0, WellFormed := false) {
	global _JsonTallyContainers, JSON_MAX_NESTING_DEPTH
	pos++  ; consume {
	; Default case sensitivity is on — keep it so JSON keys keep their casing
	; semantics (e.g. capitalised AHK Map keys would otherwise collide with
	; lower-cased JSON keys at lookup time).
	obj := Map()
	_JsonTallyContainers += 1
	selective := IsObject(selection)
	wanted := selective ? selection.Keys : 0
	; The run's member values nest two levels below their own (depth + 1).
	useRun := selective && selection.Run != "" && depth + 3 <= JSON_MAX_NESTING_DEPTH
	_JsonSkipWs(&text, &pos)
	if (SubStr(text, pos, 1) == "}") {
		pos++
		return obj
	}
	loop {
		if useRun {
			try {
				found := RegExMatch(text, selection.Run, &match, pos)
			} catch {
				; The engine's match limit: the member walk below decides instead.
				found := 0
			}
			if (found && match.Len > 0) {
				pos += match.Len
				if (match[1] != "")
					return obj
			}
		}
		_JsonSkipWs(&text, &pos)
		if (SubStr(text, pos, 1) != '"')
			throw Error("JSON: expected string key at position " . pos . ".", -1)
		key := _JsonParseString(&text, &pos, true)
		_JsonSkipWs(&text, &pos)
		if (SubStr(text, pos, 1) != ":")
			throw Error("JSON: expected ':' at position " . pos . ".", -1)
		pos++  ; consume :
		if (!selective || wanted.Has(key))
			obj[key] := _JsonParseValue(&text, &pos, depth + 1)
		else
			_JsonSkipValue(&text, &pos, depth + 1, WellFormed)
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

_JsonParseArray(&text, &pos, depth) {
	global _JsonTallyContainers
	pos++  ; consume [
	arr := []
	_JsonTallyContainers += 1
	_JsonSkipWs(&text, &pos)
	if (SubStr(text, pos, 1) == "]") {
		pos++
		return arr
	}
	loop {
		val := _JsonParseValue(&text, &pos, depth + 1)
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

; The anchored patterns of _JsonSkipValue's fast path, built once. Each one
; accepts only text the exact walk accepts too, and fails (never accepts) on
; anything it does not model:
; - a string holds no control character and only the escapes the decoder
;   accepts, \u limited to non-surrogates. PCRE reads a high surrogate and the
;   unit after it as one code point without checking that unit, so a lone high
;   surrogate would swallow the quote after it (the reason the string decoder
;   avoids PCRE). Code points above U+FFFF are therefore accepted only by the
;   WellFormed set, used on text proved to hold no lone surrogate; the other set
;   accepts no surrogate code unit at all;
; - a key also has no escape at all, so a NUL key is never accepted;
; - a number is an integer of at most 18 digits, always in range, that ends
;   where the decoder's candidate run ends;
; - a value nests at most two containers deep (an asset object holding its
;   uploader object), with no recursion in the pattern.
; "members" consumes the "key":value, members of an object and, when the last
; one is followed by its closer, that member and the "}" (capture 1); "elements"
; does the same for the elements of an array; "value" is one value.
_JsonSkipPatterns(WellFormed) {
	static Sets := Map()
	if !Sets.Has(WellFormed) {
		; Negated, the well-formed class needs no range lookup above U+00FF.
		Plain := WellFormed
			? '[^"\\\x00-\x1F]'
			: "[\x20\x21\x23-\x5B\x5D-\x{D7FF}\x{E000}-\x{FFFF}]"
		Escape := '\\(?:["\\/bfnrt]|u(?:[0-9A-Ca-cEeFf][0-9A-Fa-f]{3}|[Dd][0-7][0-9A-Fa-f]{2}))'
		Str := '"(?:' . Plain . '++|' . Escape . ')*+"'
		Key := '"' . Plain . '*+"'
		Ws := "[ \t\r\n]*+"
		Level0 := "(?:" . Str . "|-?(?:0|[1-9][0-9]{0,17})(?![0-9.eE+\-])|true|false|null)"
		Level1 := _JsonSkipPatternLevel(Level0, Level0, Key, Ws)
		Level2 := _JsonSkipPatternLevel(Level0, Level1, Key, Ws)
		MemberTail := Ws . ":" . Ws . Level2 . Ws
		Member := Ws . Key . MemberTail
		Element := Ws . Level2 . Ws
		Sets[WellFormed] := Map(
			"members", _JsonSkipRunPattern(Member, "\}"),
			"elements", _JsonSkipRunPattern(Element, "\]"),
			"value", "\G" . Level2,
			"plain", Plain, "ws", Ws, "member_tail", MemberTail)
	}
	return Sets[WellFormed]
}

; A run of Items each followed by ",", then optionally one last Item and its
; container's Closer, captured as group 1.
_JsonSkipRunPattern(Item, Closer) {
	return "\G(?:" . Item . ",)*+(?:" . Item . "(" . Closer . "))?"
}

; The run pattern of a member selection: like "members" of _JsonSkipPatterns,
; but a member whose key is a selected one ends the run, so the object walk
; decodes it. A key that cannot be quoted literally disables the run ("").
_JsonSkipMembersRun(Keys, WellFormed) {
	Parts := _JsonSkipPatterns(WellFormed)
	Excluded := ""
	for Key in Keys {
		if InStr(Key, "\E", true)
			return ""
		Excluded .= (Excluded == "" ? "" : "|") . "\Q" . Key . "\E"
	}
	Guard := Excluded == "" ? "" : '(?!(?:' . Excluded . ')")'
	Member := Parts["ws"] . '"' . Guard . Parts["plain"] . '*+"' . Parts["member_tail"]
	return _JsonSkipRunPattern(Member, "\}")
}

; One nesting level of _JsonSkipPatterns: a scalar, or an object or array
; whose members or elements are Inner values.
_JsonSkipPatternLevel(Scalar, Inner, Key, Ws) {
	Item := Ws . Inner . Ws
	Pair := Ws . Key . Ws . ":" . Item
	return "(?:" . Scalar
		. "|\{(?:" . Pair . "(?:," . Pair . ")*+|" . Ws . ")\}"
		. "|\[(?:" . Item . "(?:," . Item . ")*+|" . Ws . ")\])"
}

; Validates one value exactly as _JsonParseValue would decode it (grammar,
; nesting depth, escapes, NUL keys, number range) without building anything.
; A value nobody reads, such as the assets of a release list, then costs no
; allocation. The walk is one loop with whitespace and string runs inlined:
; an AHK function call per token cost more than the token's own native scan.
; Where a run of scalar members or elements, or a string, starts, one anchored
; native match (_JsonSkipPatterns) consumes it whole; whatever it does not
; model, or a match the engine gives up on, is left to the exact walk.
; WellFormed states that the whole text holds no lone surrogate.
; The container stack holds the opening code unit, 0x7B "{" or 0x5B "[".
_JsonSkipValue(&text, &pos, depth, WellFormed := false) {
	global JSON_MAX_NESTING_DEPTH
	static Delimiters := _JsonStringRunDelimiters()
	static Whitespace := _JsonWhitespaceUnits()
	Patterns := _JsonSkipPatterns(WellFormed)
	ptr := StrPtr(text)
	len := StrLen(text)
	stack := []
	; Expecting: 1 a value, 2 an object key, 3 a separator or closer.
	expect := 1
	; After a run stopped short of its container's end, the next token is the
	; one the run could not model: it goes to the exact walk directly.
	afterRun := false
	loop {
		if (expect == 3 && stack.Length == 0)
			return
		; Every state starts on a token: skip the whitespace before it. The code
		; unit after the last one is the string's NUL terminator, so pos may
		; reach len + 1 safely.
		code := NumGet(ptr, (pos - 1) * 2, "UShort")
		if (code == 0x20 || code == 0x0A || code == 0x0D || code == 0x09) {
			pos += NativeTextSpanIncluding(ptr + (pos - 1) * 2, Whitespace)
			code := NumGet(ptr, (pos - 1) * 2, "UShort")
		}
		; A pattern value holds containers two levels below its own, so it may
		; start only where those levels stay within the nesting limit.
		if (expect != 3 && !afterRun && depth + stack.Length + 2 <= JSON_MAX_NESTING_DEPTH) {
			kind := expect == 2 ? "members"
				: (stack.Length && stack[stack.Length] == 0x5B) ? "elements" : "value"
			try {
				found := RegExMatch(text, Patterns[kind], &match, pos)
			} catch {
				; The engine's match limit: the exact walk decides instead.
				found := 0
			}
			if (found && match.Len > 0) {
				pos += match.Len
				if (kind == "value" || match[1] != "") {
					if (kind != "value")
						stack.Pop()
					expect := 3
				} else {
					afterRun := true
				}
				continue
			}
		}
		afterRun := false
		if (expect == 3) {
			open := stack[stack.Length]
			if (code == 0x2C) {  ; ,
				pos++
				expect := open == 0x7B ? 2 : 1
			} else if ((open == 0x7B && code == 0x7D) || (open == 0x5B && code == 0x5D)) {
				pos++
				stack.Pop()
			} else if (open == 0x7B) {
				throw Error("JSON: expected ',' or '}' at position " . pos . ".", -1)
			} else {
				throw Error("JSON: expected ',' or ']' at position " . pos . ".", -1)
			}
			continue
		}
		if (expect == 1) {
			level := depth + stack.Length
			if (level > JSON_MAX_NESTING_DEPTH)
				throw Error("JSON: maximum nesting depth exceeded at position " . pos . ".", -1)
			if (pos > len)
				throw Error("JSON: unexpected end of input.", -1)
			if (code == 0x7B || code == 0x5B) {  ; { or [
				if (level == JSON_MAX_NESTING_DEPTH)
					throw Error("JSON: maximum nesting depth exceeded at position " . pos . ".", -1)
				pos++
				code2 := NumGet(ptr, (pos - 1) * 2, "UShort")
				if (code2 == 0x20 || code2 == 0x0A || code2 == 0x0D || code2 == 0x09) {
					pos += NativeTextSpanIncluding(ptr + (pos - 1) * 2, Whitespace)
					code2 := NumGet(ptr, (pos - 1) * 2, "UShort")
				}
				if (code2 == (code == 0x7B ? 0x7D : 0x5D)) {
					pos++
					expect := 3
				} else {
					stack.Push(code)
					expect := code == 0x7B ? 2 : 1
				}
				continue
			}
			if (code != 0x22) {
				if (code == 0x74 || code == 0x66)  ; t or f
					_JsonParseBool(&text, &pos)
				else if (code == 0x6E)  ; n
					_JsonParseNull(&text, &pos)
				else
					_JsonParseNumber(&text, &pos)
				expect := 3
				continue
			}
			isKey := false
		} else {
			if (pos > len || code != 0x22)
				throw Error("JSON: expected string key at position " . pos . ".", -1)
			isKey := true
		}
		; A string token, validated as _JsonParseString decodes it.
		pos++  ; consume opening "
		loop {
			pos += NativeTextSpanExcluding(ptr + (pos - 1) * 2, Delimiters)
			if (pos > len)
				throw Error("JSON: unterminated string starting near position " . pos . ".", -1)
			code := NumGet(ptr, (pos - 1) * 2, "UShort")
			if (code == 0x22)
				break
			if (code < 0x20)
				throw Error("JSON: unescaped control character at position " . pos . ".", -1)
			pos++
			if (code == 0x60)  ; a backtick is plain text
				continue
			; A backslash: the escape letter follows.
			esc := SubStr(text, pos, 1)
			pos++
			if (esc == "u")
				_JsonParseUnicodeEscape(&text, &pos, isKey)
			else if (esc == "" || !InStr('"\/bfnrt', esc, true))
				throw Error("JSON: invalid escape sequence at position " . pos . ".", -1)
		}
		pos++  ; consume closing "
		if !isKey {
			expect := 3
			continue
		}
		code := NumGet(ptr, (pos - 1) * 2, "UShort")
		if (code == 0x20 || code == 0x0A || code == 0x0D || code == 0x09) {
			pos += NativeTextSpanIncluding(ptr + (pos - 1) * 2, Whitespace)
			code := NumGet(ptr, (pos - 1) * 2, "UShort")
		}
		if (pos > len || code != 0x3A)
			throw Error("JSON: expected ':' at position " . pos . ".", -1)
		pos++  ; consume :
		expect := 1
	}
}

; The NUL-terminated UTF-16 set that ends a plain string run: quote,
; backslash, backtick and every control character except NUL (which ends the
; native scan by itself).
_JsonStringRunDelimiters() {
	static Delimiters := 0
	if !Delimiters {
		Units := [0x22, 0x5C, 0x60]
		loop 31
			Units.Push(A_Index)
		Set := Buffer((Units.Length + 1) * 2, 0)
		for Index, Unit in Units
			NumPut("UShort", Unit, Set, (Index - 1) * 2)
		Delimiters := Set
	}
	return Delimiters
}

; Reads the four hex digits after "\u" (pos is on the first digit) and, for a
; high surrogate, its "\u" low half: the code point, with pos after the escape.
; The single owner of the \u grammar for decoded and validated strings alike.
_JsonParseUnicodeEscape(&text, &pos, ObjectKey) {
	hex := SubStr(text, pos, 4)
	if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
		throw Error("JSON: invalid \u escape at position " . pos . ".", -1)
	pos += 4
	cp := Integer("0x" . hex)
	; Native Map truncates keys at NUL, silently aliasing distinct
	; JSON fields. Refuse that representation before assigning a value.
	if ObjectKey && cp = 0
		throw Error("JSON: NUL object key cannot be represented at position " . (pos - 4) . ".", -1)
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
	return cp
}

_JsonParseString(&text, &pos, ObjectKey := false) {
	global _JsonTallyStringUnits
	static Delimiters := _JsonStringRunDelimiters()
	pos++  ; consume opening "
	out := ""
	len := StrLen(text)
	while (pos <= len) {
		c := SubStr(text, pos, 1)
		if (Ord(c) < 0x20)
			throw Error("JSON: unescaped control character at position " . pos . ".", -1)
		if (c == '"') {
			pos++
			_JsonTallyStringUnits += StrLen(out)
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
					out .= Chr(_JsonParseUnicodeEscape(&text, &pos, ObjectKey))
				default:
					throw Error("JSON: invalid escape sequence at position " . pos . ".", -1)
			}
		} else {
			; Fast-path: copy the whole run of plain characters up to the next
			; delimiter (" / \ / backtick) in one slice instead of appending one
			; char at a time — the per-char ``out .= c`` is O(n^2) over the long
			; unescaped spans that dominate locale strings (parsed once at boot
			; for every i18n value). One native code-unit scan finds the run end;
			; a per-character AHK loop made a 6 MB GitHub release list take 33 s.
			; PCRE is not used here: in UTF-16 mode it reads a lone high
			; surrogate as half of a pair and swallows the delimiter after it.
			; Behaviour is identical: the run stops on the same delimiters the
			; outer switch handles, and on a control character, which is
			; refused; the scan stops at an embedded NUL, which is refused too.
			runStart := pos
			pos += NativeTextSpanExcluding(StrPtr(text) + (pos - 1) * 2, Delimiters)
			if (pos <= len && Ord(SubStr(text, pos, 1)) < 0x20)
				throw Error("JSON: unescaped control character at position " . pos . ".", -1)
			out .= SubStr(text, runStart, pos - runStart)
		}
	}
	throw Error("JSON: unterminated string starting near position " . pos . ".", -1)
}

; The NUL-terminated UTF-16 set a number's candidate run is made of.
_JsonNumberRunUnits() {
	static Units := 0
	if !Units {
		Chars := "0123456789.eE+-"
		Units := Buffer((StrLen(Chars) + 1) * 2, 0)
		loop StrLen(Chars)
			NumPut("UShort", Ord(SubStr(Chars, A_Index, 1)), Units, (A_Index - 1) * 2)
	}
	return Units
}

_JsonParseNumber(&text, &pos) {
	start := pos
	if (SubStr(text, pos, 1) == "-")
		pos++
	; The candidate run is every following digit, ".", "e", "E", "+" or "-",
	; measured by one native scan; the grammar below then decides.
	pos += NativeTextSpanIncluding(StrPtr(text) + (pos - 1) * 2, _JsonNumberRunUnits())
	s := SubStr(text, start, pos - start)
	; Validate before coercion using the full JSON number grammar so malformed
	; inputs like "1.2.3", "1e", "123-456" are caught here rather than
	; propagating to AHK's + 0 coercion which surfaces a confusing internal error.
	; JSON number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
	if (s == "" or !RegExMatch(s, "^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"))
		throw Error("JSON: invalid number at position " . start . ".", -1)
	if !InStr(s, ".") and !InStr(s, "e") and !InStr(s, "E") {
		if !NumberTryParseSignedInteger(s, &value)
			throw Error("JSON: integer out of range at position " . start . ".", -1)
		return value
	}
	; AHK publishes +/-infinity for an overflowing decimal float. Infinity is
	; not a JSON number and later numeric validators otherwise accept +infinity.
	if !NumberTryParseFiniteFloat(s, &value)
		throw Error("JSON: number must be finite at position " . start . ".", -1)
	return value
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
