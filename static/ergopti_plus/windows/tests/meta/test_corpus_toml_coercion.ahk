; static/ergopti_plus/windows/tests/meta/test_corpus_toml_coercion.ahk

; ==============================================================================
; CORPUS CONSUMER: TOML Scalar Coercion — AHK
; Reads _shared/tests/corpus/toml/coercion_vectors.json and replays each
; vector through TomlCoerceValueExt(), asserting the output matches the
; expected AHK value. Pins the 3 AHK coercion sites against the shared corpus.
; ==============================================================================

#Requires AutoHotkey v2.0


; ===================================================
; ===================================================
; ======= 1/ Corpus Loading =========================
; ===================================================
; ===================================================

_TomlCoercionCorpus_LoadCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\toml\coercion_vectors.json"
	if !FileExist(Path) {
		return ""
	}
	Raw := FileRead(Path, "UTF-8")
	return JsonParse(Raw)
}


; ===================================================
; ===================================================
; ======= 2/ Pinned Coercion Clone ==================
; ===================================================
; ===================================================

; Clone of TomlCoerceValueExt from toml_config_loader.ahk.  The real module
; depends on full driver init and cannot load in the test harness.  This
; pinned copy is asserted identical by the JS drift gate.

_TomlCoercionCorpus_CoerceValueExt(Raw) {
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
		return _TomlCoercionCorpus_Unescape(body)
	}
	return Trimmed
}

_TomlCoercionCorpus_Unescape(s) {
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


; ===================================================
; ===================================================
; ======= 3/ Corpus Coercion Tests ==================
; ===================================================
; ===================================================

; Named test functions are used instead of fat-arrow lambdas: a block-body fat
; arrow (() => { ... }) is a v2.1-only construct that fails to parse under
; #Requires v2.0, and a per-vector lambda would capture the loop variable by
; reference — every lambda would see the LAST vector, silently testing only one.
; A single function looping over all vectors sidesteps both, keeping per-vector
; diagnostics via the id embedded in each assert message.

_TomlCoercionCorpus_TestStructure() {
	Data := _TomlCoercionCorpus_LoadCorpus()
	if (Data = "") {
		AssertTrue(false, "Corpus file not found at _shared/tests/corpus/toml/coercion_vectors.json")
		return
	}
	AssertTrue(Data.Has("vectors"), "corpus must have 'vectors' key")
	AssertTrue(Data["vectors"].Length >= 12, "corpus must have >= 12 vectors")
}
Test("[corpus:toml-coercion] corpus has vectors array", _TomlCoercionCorpus_TestStructure)

_TomlCoercionCorpus_TestAllVectors() {
	Data := _TomlCoercionCorpus_LoadCorpus()
	if (Data = "" || !Data.Has("vectors")) {
		AssertTrue(false, "Corpus not loadable with a vectors array")
		return
	}
	for Vec in Data["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "unknown"
		Input := Vec.Has("input") ? Vec["input"] : ""
		AssertTrue(Vec.Has("ahk"), "vector '" . Id . "' missing 'ahk' field")

		Result := _TomlCoercionCorpus_CoerceValueExt(Input)
		Expected := Vec["ahk"]

		if (Expected = true || Expected = false) {
			ExpectedBool := Expected = true
			ResultBool := Result = true || Result = 1
			AssertEqual(ResultBool, ExpectedBool,
				"vector '" . Id . "': boolean mismatch for '" . Input . "'")
		} else if (Expected is Number) {
			AssertTrue(Result is Number,
				"vector '" . Id . "': expected number, got " . Type(Result))
			AssertTrue(Abs(Result - Expected) < 0.0001,
				"vector '" . Id . "': number mismatch for '" . Input . "': got " . Result . ", expected " . Expected)
		} else {
			AssertEqual(String(Result), String(Expected),
				"vector '" . Id . "': string mismatch for '" . Input . "'")
		}
	}
}
Test("[corpus:toml-coercion] all vectors coerce to expected AHK values", _TomlCoercionCorpus_TestAllVectors)
