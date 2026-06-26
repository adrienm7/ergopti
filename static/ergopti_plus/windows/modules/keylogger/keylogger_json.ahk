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
    out := ""
    Loop Parse, s {
        c := A_LoopField
        switch c {
            case '"' : out .= '\"'
            case '\' : out .= '\\'
            case '`n': out .= '\n'
            case '`r': out .= '\r'
            case '`t': out .= '\t'
            case '`b': out .= '\b'
            case '`f': out .= '\f'
            default:
                code := Ord(c)
                if (code < 0x20)
                    out .= Format('\u{:04x}', code)
                else
                    out .= c
        }
    }
    return '"' . out . '"'
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

KL_JsonDecode(s) {
    ; ScriptControl is x86-only — silently unavailable on 64-bit AHK hosts.
    ; A_PtrSize == 8 means 64-bit; skip the COM path entirely to avoid the
    ; "Too many parameters" crash that ComObject("ScriptControl") throws there.
    static sc := ""
    static sc_available := -1
    if (sc_available = -1)
        sc_available := (A_PtrSize = 4) ? 1 : 0
    if (!sc_available)
        return Map()
    if (sc = "") {
        try {
            sc := ComObject("ScriptControl")
            sc.Language := "JScript"
        } catch {
            sc_available := 0
            return Map()
        }
    }
    try {
        ; Wrap in parens so JS evaluates as expression, not block.
        result := sc.Eval("(function(){return " . s . ";})()")
        return KL_ComToMap(result)
    } catch {
        return Map()
    }
}

KL_ComToMap(v) {
    ; ScriptControl returns COM JS objects; recursively convert to Map/Array.
    if !IsObject(v)
        return v
    ; Try array indexing.
    try {
        if (HasProp(v, "length")) {
            arr := []
            Loop v.length
                arr.Push(KL_ComToMap(v[A_Index - 1]))
            return arr
        }
    }
    out := Map()
    try {
        for prop, _ in v
            out[prop] := KL_ComToMap(v[prop])
    }
    return out
}
