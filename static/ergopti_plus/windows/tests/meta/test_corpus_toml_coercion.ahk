; static/ergopti_plus/windows/tests/meta/test_corpus_toml_coercion.ahk

; ==============================================================================
; CORPUS CONSUMER: TOML Scalar Coercion — AHK (P0-G.6)
; Reads _shared/tests/corpus/toml/coercion_vectors.json and replays each
; vector through TomlCoerceValueExt(), asserting the output matches the
; expected AHK value. Pins the 3 AHK coercion sites against the shared corpus.
; ==============================================================================

#Requires Autohotkey v2.0+

global _SharedDir := A_ScriptDir . "\..\..\_shared"
global _TestResult := ""
global _TestFailed := 0

; Lightweight JSON parser for the coercion vectors.
_TestParseCorpus(Path) {
    if !FileExist(Path) {
        _TestResult .= "FAIL: corpus file not found: " . Path . "`n"
        _TestFailed += 1
        return []
    }
    raw := ""
    try raw := FileRead(Path, "UTF-8")
    if (raw = "") {
        _TestResult .= "FAIL: empty corpus: " . Path . "`n"
        _TestFailed += 1
        return []
    }
    ; Extract each vector object manually — the full dkjson dependency is
    ; heavy; a simple line-by-line parser is sufficient for this flat corpus.
    vectors := []
    in_vector := false
    current := Map()
    current_key := ""
    loop parse, raw, "`n", "`r" {
        line := Trim(A_LoopField)
        if (line = "{" && !in_vector) {
            in_vector := true
            current := Map()
            continue
        }
        if (line = "}," or line = "}" && in_vector) {
            if current.Has("input") {
                vectors.Push(current)
            }
            in_vector := false
            current := Map()
            continue
        }
        if !in_vector
            continue
        ; Match "key": value, or "key": "value"
        if RegExMatch(line, '"([^"]+)"\s*:\s*(.+)', &M) {
            key := M[1]
            val := Trim(M[2])
            ; Strip trailing comma
            if (SubStr(val, -1) = ",")
                val := Trim(SubStr(val, 1, StrLen(val) - 1))
            ; Boolean/number
            if (val = "true") {
                current[key] := true
            } else if (val = "false") {
                current[key] := false
            } else {
                ; Number?
                if RegExMatch(val, "^-?\d+(\.\d+)?$") {
                    current[key] := Number(val)
                } else {
                    ; String — strip surrounding quotes
                    val := Trim(val, '"')
                    ; Unescape JSON strings. Order matters (\n/\t before \\)
                    ; so a JSON literal like "line1\\nline2" (backslash+n)
                    ; doesn't have its \\ collapsed to \ then \n→newline.
                    val := StrReplace(val, '\"', '"')
                    val := StrReplace(val, "\n", "`n")
                    val := StrReplace(val, "\t", "`t")
                    val := StrReplace(val, "\\", "\")
                    current[key] := val
                }
            }
        }
    }
    return vectors
}

; Clone TomlCoerceValueExt from toml_config_loader.ahk — the real module
; depends on the full driver init and can't load in the test harness.
; This is a PINNED COPY, asserted identical by the JS drift gate.
_TestTomlCoerceValueExt(Raw) {
    Trimmed := Trim(Raw, " `t")
    Lower := StrLower(Trimmed)
    if (Lower = "true")
        return 1
    if (Lower = "false")
        return 0
    if RegExMatch(Trimmed, "^-?\d+$")
        return Integer(Trimmed)
    if RegExMatch(Trimmed, "^-?\d+\.\d+$")
        return Float(Trimmed)
    Q := Chr(34)
    if (StrLen(Trimmed) >= 2 && SubStr(Trimmed, 1, 1) = Q
        && SubStr(Trimmed, StrLen(Trimmed), 1) = Q) {
        body := SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
        ; Single-pass unescape matching UnescapeTomlString from toml_loader.ahk
        return _TestUnescape(body)
    }
    return Trimmed
}

_TestUnescape(s) {
    if !InStr(s, "\")
        return s
    Result := ""
    i := 1
    n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "\" && i < n) {
            nc := SubStr(s, i + 1, 1)
            if (nc = "\") {
                Result .= "\"
            } else if (nc = '"') {
                Result .= '"'
            } else if (nc = "n") {
                Result .= "`n"
            } else if (nc = "t") {
                Result .= "`t"
            } else if (nc = "r") {
                Result .= "`r"
            } else {
                Result .= nc
            }
            i += 2
        } else {
            Result .= c
            i += 1
        }
    }
    return Result
}


; ==============================================================================
; Main test runner
; ==============================================================================

_TestCorpusTotoCoercion() {
    global _TestResult, _TestFailed

    CorpusPath := _SharedDir . "\tests\corpus\toml\coercion_vectors.json"
    vectors := _TestParseCorpus(CorpusPath)

    if (vectors.Length = 0) {
        _TestResult .= "FAIL: no vectors parsed from corpus.`n"
        _TestFailed += 1
        return
    }

    for v in vectors {
        if !v.Has("input") {
            _TestResult .= "FAIL: vector missing 'input' field.`n"
            _TestFailed += 1
            continue
        }
        input := v["input"]
        result := _TestTomlCoerceValueExt(input)

        if v.Has("ahk") {
            expected := v["ahk"]
            ; Normalize boolean: corpus stores 1/0, coercion returns Integer 1/0
            if (expected = true || expected = false || (expected is Integer && (expected = 1 || expected = 0))) {
                ; Boolean comparison
                expected_bool := (expected = true || expected = 1)
                result_bool := (result = true || result = 1)
                if (expected_bool != result_bool) {
                    _TestResult .= "FAIL: coerce('" . input . "') boolean mismatch: got " . result . ", expected " . expected . "`n"
                    _TestFailed += 1
                }
            } else if (expected is Number) {
                if !(result is Number) || Abs(result - expected) > 0.0001 {
                    _TestResult .= "FAIL: coerce('" . input . "') number mismatch: got " . result . ", expected " . expected . "`n"
                    _TestFailed += 1
                }
            } else {
                ; String comparison — AHK backtick escapes vs literal chars
                expected_str := String(expected)
                result_str := String(result)
                if (expected_str != result_str) {
                    _TestResult .= "FAIL: coerce('" . input . "') string mismatch: got '" . result_str . "', expected '" . expected_str . "'`n"
                    _TestFailed += 1
                }
            }
        }
    }

    if (_TestFailed = 0) {
        _TestResult .= "OK: corpus TOML coercion — " . vectors.Length . " vector(s) passed.`n"
    }
}

_TestCorpusTotoCoercion()
