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

; Cross-process replay and state restore share the strict resident JSON parser.
; Keep the historical empty-Map error sentinel so one malformed durable line is
; skipped without escaping through the ingest timer, and translate JSON null back
; to the keylogger codec's legacy empty-string representation.
KL_JsonDecode(s) {
		try {
				return _KL_JsonNormalizeNull(JsonParse(s))
		} catch {
				return Map()
		}
}

_KL_JsonNormalizeNull(Value) {
		global JSON_NULL
		if !IsObject(Value)
				return Value
		if (ObjPtr(Value) == ObjPtr(JSON_NULL))
				return ""
		if Value is Map {
				for Key, Item in Value
						Value[Key] := _KL_JsonNormalizeNull(Item)
				return Value
		}
		if Value is Array {
				for Index, Item in Value
						Value[Index] := _KL_JsonNormalizeNull(Item)
		}
		return Value
}
