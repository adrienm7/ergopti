; modules/keylogger/keylogger_json.ahk

; ==============================================================================
; MODULE: Keylogger - JSON Helpers
; DESCRIPTION:
; Minimal JSON encode/decode helpers for the keylogger device + metadata files.
;
; Extracted from keylogger.ahk (audit F1) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

; AHK v2 ships no built-in JSON parser. We use a minimal encoder/decoder
; tailored for our types (Maps, Arrays, strings, numbers, booleans, null).
; For larger payloads (events array on typing flush) the encoder emits a
; compact one-line representation suitable for JSONL.

KL_JsonEncode(v) {
		if (v = "")           ; AHK distinguishes empty string from unset.
				return '""'
		if v is Map
				return KL_JsonEncodeMap(v)
		if v is Array
				return KL_JsonEncodeArray(v)
		if (v is Number)
				return String(v)
		if (Type(v) = "String")
				return KL_JsonEncodeString(v)
		if (v = true)
				return "true"
		if (v = false)
				return "false"
		return "null"
}

KL_JsonEncodeString(s) {
		return JsonStringLiteral(s)
}

KL_JsonEncodeMap(m) {
		parts := []
		for k, v in m
				parts.Push(KL_JsonEncodeString(String(k)) . ":" . KL_JsonEncode(v))
		return "{" . KL_JoinArray(parts, ",") . "}"
}

KL_JsonEncodeArray(a) {
		parts := []
		for _, v in a
				parts.Push(KL_JsonEncode(v))
		return "[" . KL_JoinArray(parts, ",") . "]"
}

KL_JoinArray(arr, sep) {
		out := ""
		for i, v in arr
				out .= (i = 1 ? "" : sep) . v
		return out
}

; Hand-rolled recursive-descent JSON parser so cross-process replay + state.json
; restore work on the shipped 64-bit binary - ComObject("ScriptControl") is x86-only,
; so the old COM path returned an empty Map() on 64-bit, silently dropping every
; today.log line AND the persisted offset (which then reset to 0 and lost the resume
; point). Parses exactly what KL_JsonEncode emits (compact objects/arrays/strings with
; \"/\\/\n/\r/\t/\b/\f/\uXXXX escapes, numbers, true/false/null). Returns Map() on any
; parse error so a malformed line is skipped, never crashing the ingest tick
; (keylogger-json-64bit-decode).
KL_JsonDecode(s) {
		pos := 1
		try {
				return _KL_JsonParseValue(s, &pos)
		} catch {
				return Map()
		}
}

_KL_JsonSkipWs(s, &pos) {
		len := StrLen(s)
		while (pos <= len) {
				c := SubStr(s, pos, 1)
				if (c = " " or c = "`t" or c = "`n" or c = "`r")
						pos++
				else
						break
		}
}

_KL_JsonParseValue(s, &pos) {
		_KL_JsonSkipWs(s, &pos)
		c := SubStr(s, pos, 1)
		if (c = "{")
				return _KL_JsonParseObject(s, &pos)
		if (c = "[")
				return _KL_JsonParseArray(s, &pos)
		if (c = '"')
				return _KL_JsonParseString(s, &pos)
		if (c = "t") {
				pos += 4
				return true
		}
		if (c = "f") {
				pos += 5
				return false
		}
		if (c = "n") {
				pos += 4
				return ""
		}
		return _KL_JsonParseNumber(s, &pos)
}

_KL_JsonParseObject(s, &pos) {
		obj := Map()
		pos++
		_KL_JsonSkipWs(s, &pos)
		if (SubStr(s, pos, 1) = "}") {
				pos++
				return obj
		}
		loop {
				_KL_JsonSkipWs(s, &pos)
				key := _KL_JsonParseString(s, &pos)
				_KL_JsonSkipWs(s, &pos)
				if (SubStr(s, pos, 1) != ":")
						throw Error("expected colon")
				pos++
				obj[key] := _KL_JsonParseValue(s, &pos)
				_KL_JsonSkipWs(s, &pos)
				c := SubStr(s, pos, 1)
				if (c = ",") {
						pos++
						continue
				}
				if (c = "}") {
						pos++
						break
				}
				throw Error("bad object")
		}
		return obj
}

_KL_JsonParseArray(s, &pos) {
		arr := []
		pos++
		_KL_JsonSkipWs(s, &pos)
		if (SubStr(s, pos, 1) = "]") {
				pos++
				return arr
		}
		loop {
				arr.Push(_KL_JsonParseValue(s, &pos))
				_KL_JsonSkipWs(s, &pos)
				c := SubStr(s, pos, 1)
				if (c = ",") {
						pos++
						continue
				}
				if (c = "]") {
						pos++
						break
				}
				throw Error("bad array")
		}
		return arr
}

_KL_JsonParseString(s, &pos) {
		if (SubStr(s, pos, 1) != '"')
				throw Error("expected string")
		pos++
		out := ""
		len := StrLen(s)
		while (pos <= len) {
				c := SubStr(s, pos, 1)
				if (c = '"') {
						pos++
						return out
				}
				if (c = '\') {
						pos++
						e := SubStr(s, pos, 1)
						switch e {
								case '"': out .= '"'
								case '\': out .= '\'
								case "/": out .= "/"
								case "n": out .= "`n"
								case "r": out .= "`r"
								case "t": out .= "`t"
								case "b": out .= "`b"
								case "f": out .= "`f"
								case "u":
										out .= Chr(Integer("0x" . SubStr(s, pos + 1, 4)))
										pos += 4
								default: out .= e
						}
						pos++
				} else {
						out .= c
						pos++
				}
		}
		throw Error("unterminated string")
}

_KL_JsonParseNumber(s, &pos) {
		start := pos
		len := StrLen(s)
		while (pos <= len) {
				c := SubStr(s, pos, 1)
				if (InStr("0123456789+-.eE", c) > 0)
						pos++
				else
						break
		}
		numStr := SubStr(s, start, pos - start)
		if (numStr = "")
				throw Error("expected number")
		if (InStr(numStr, ".") or InStr(numStr, "e") or InStr(numStr, "E"))
				return numStr + 0.0
		return Integer(numStr)
}
