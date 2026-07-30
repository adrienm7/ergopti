; tests/meta/test_corpus_tap_hold.ahk

; ==============================================================================
; MODULE: Tap-Hold Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/tap_hold/vectors.json and validates each vector
; against the AHK tap-hold loader  --  ensuring that a tap-hold configuration
; round-trips through LoadTapHoldToml + accessor functions with the expected
; values.
;
; COVERAGE:
; 1. Corpus integrity  --  every vector has required fields (id, key, expected).
; 2. Accessor semantics  --  for configured vectors, a synthesized TOML snippet
;    is written to a temp file, loaded via LoadTapHoldToml, and the resulting
;    map is queried with TapHoldIsConfigured, TapHoldTapAction,
;    TapHoldDuration, TapHoldHoldModifier, TapHoldHoldLayer.
; 3. Unconfigured vectors  --  keys absent from the config return configured=false.
;
; NOTE:
; The Hammerspoon-specific TOML codec round-trip is exercised in the HS
; test_corpus_tap_hold.lua. This file focuses on the AHK accessor invariants
; shared across both drivers.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusTH_Root() {
	; Resolve the corpus path relative to the main script's directory (tests/).
	; A_ScriptDir is always the dir of run_all.ahk, i.e. windows/tests/.
	; Two levels up from tests/ (windows/tests/ → windows/ → ergopti_plus/) where _shared/ lives.
	return A_ScriptDir . "\..\..\_shared\tests\corpus\tap_hold\vectors.json"
}

; THROWS when the corpus is missing or malformed. It used to return "", and
; every consumer below opened with `if Corpus = "" { return }` — so moving or
; breaking the corpus produced ONE red (the readability test) and EIGHT silent
; greens. A cross-driver contract that can be deleted without the suite noticing
; is not a contract.
_CorpusTH_Load() {
	Path := _CorpusTH_Root()
	if not FileExist(Path)
		throw Error("tap-hold corpus not found at '" . Path . "' — the shared vectors are a cross-driver contract; a missing corpus must fail this suite, never skip it")
	return FileRead(Path, "UTF-8")
}

_CorpusTH_Parse() {
	Corpus := JsonParse(_CorpusTH_Load())
	if (Corpus = "")
		throw Error("tap-hold corpus at '" . _CorpusTH_Root() . "' did not parse into an object — a malformed corpus must fail this suite, never skip it")
	return Corpus
}




; ============================================
; ============================================
; ======= 2/ Corpus integrity tests ==========
; ============================================
; ============================================

_CorpusTH_FileIsReadableAndParseable() {
	; Readability and parseability are now enforced by the loader itself, which
	; throws with the resolved path — asserting them again here would only
	; restate what already cannot be false.
	Corpus := _CorpusTH_Parse()
	AssertTrue(Corpus.Has("vectors"), "corpus must have a vectors key")
	AssertTrue(Corpus["vectors"].Length > 0, "corpus must contain at least one vector")
}
Test("tap_hold corpus  --  corpus file is readable and parseable", _CorpusTH_FileIsReadableAndParseable)

_CorpusTH_EveryVectorHasRequiredFields() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		AssertTrue(Vec.Has("id") and Vec["id"] != "",
			"vector missing id")
		AssertTrue(Vec.Has("key") and Vec["key"] != "",
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing key")
		AssertTrue(Vec.Has("expected"),
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing expected")
	}
}
Test("tap_hold corpus  --  every vector has required fields: id, key, expected", _CorpusTH_EveryVectorHasRequiredFields)

_CorpusTH_ConfiguredTrueHasNonNullConfig() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if Expected.Has("configured") and Expected["configured"] = true {
			; JSON null parses to JSON_NULL (an Object, not a Map); use type check
			AssertTrue(Vec.Has("config") and Type(Vec["config"]) = "Map",
				"vector '" . Vec["id"] . "' has configured=true but config is null")
		}
	}
}
Test("tap_hold corpus  --  configured=true vectors have a non-null config block", _CorpusTH_ConfiguredTrueHasNonNullConfig)

_CorpusTH_ConfiguredFalseHasNullConfig() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if Expected.Has("configured") and Expected["configured"] = false {
			; JSON null parses to JSON_NULL (Object type, not Map); treat it as absent.
			; An empty string or JSON_NULL are both acceptable representations of null.
			HasConfig := Vec.Has("config") and Type(Vec["config"]) = "Map"
			AssertTrue(!HasConfig,
				"vector '" . Vec["id"] . "' has configured=false but config is non-null")
		}
	}
}
Test("tap_hold corpus  --  configured=false vectors have config = null", _CorpusTH_ConfiguredFalseHasNullConfig)




; ==============================================
; ==============================================
; ======= 3/ Accessor round-trip tests =========
; ==============================================
; ==============================================

; Helper: build a minimal TOML snippet for a single key config map.
_CorpusTH_BuildToml(KeyId, Cfg) {
	Lines := "[tap_hold.keys." . KeyId . "]`r`n"
	if Cfg.Has("tap_action") and Cfg["tap_action"] != "" {
		Lines .= 'tap_action = "' . Cfg["tap_action"] . '"' . "`r`n"
	}
	if Cfg.Has("time_activation_seconds") {
		Lines .= "time_activation_seconds = " . Cfg["time_activation_seconds"] . "`r`n"
	}
	if Cfg.Has("hold_modifier") and Cfg["hold_modifier"] != "" {
		Lines .= 'hold_modifier = "' . Cfg["hold_modifier"] . '"' . "`r`n"
	}
	if Cfg.Has("hold_layer") and Cfg["hold_layer"] != "" {
		Lines .= 'hold_layer = "' . Cfg["hold_layer"] . '"' . "`r`n"
	}
	if Cfg.Has("enabled") {
		Lines .= "enabled = " . (Cfg["enabled"] ? "true" : "false") . "`r`n"
	}
	return Lines
}

; Helper: write a temp TOML and return its path.
_CorpusTH_TmpPath() => A_ScriptDir . "\test_corpus_tap_hold_tmp.toml"

_CorpusTH_WriteToml(Content) {
	Path := _CorpusTH_TmpPath()
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}

_CorpusTH_CleanToml() {
	global _TomlFileCache
	Path := _CorpusTH_TmpPath()
	if FileExist(Path) {
		FileDelete(Path)
	}
	if _TomlFileCache.Has(Path) {
		_TomlFileCache.Delete(Path)
	}
}

_CorpusTH_ConfiguredVectorsRoundTrip() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		; JSON null parses to JSON_NULL (Object), not a Map — skip null configs
		if not (Vec.Has("config") and Type(Vec["config"]) = "Map") {
			continue
		}
		Cfg     := Vec["config"]
		KeyId   := Vec["key"]
		Content := _CorpusTH_BuildToml(KeyId, Cfg)
		Path    := _CorpusTH_WriteToml(Content)
		TH      := LoadTapHoldToml(Path)
		_CorpusTH_CleanToml()

		AssertTrue(TapHoldIsConfigured(TH, KeyId),
			"vector '" . Vec["id"] . "': key '" . KeyId . "' must be configured after load")
	}
}
Test("tap_hold corpus  --  configured vectors: TapHoldIsConfigured returns true", _CorpusTH_ConfiguredVectorsRoundTrip)

_CorpusTH_TapActionPreserved() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		; JSON null parses to JSON_NULL (Object), not a Map — skip null configs
		if not (Vec.Has("config") and Type(Vec["config"]) = "Map") {
			continue
		}
		Expected := Vec["expected"]
		if not Expected.Has("tap_action") {
			continue
		}
		Cfg     := Vec["config"]
		KeyId   := Vec["key"]
		Content := _CorpusTH_BuildToml(KeyId, Cfg)
		Path    := _CorpusTH_WriteToml(Content)
		TH      := LoadTapHoldToml(Path)
		_CorpusTH_CleanToml()

		AssertEqual(Expected["tap_action"], TapHoldTapAction(TH, KeyId),
			"vector '" . Vec["id"] . "': tap_action mismatch after round-trip")
	}
}
Test("tap_hold corpus  --  tap_action is preserved after TOML round-trip", _CorpusTH_TapActionPreserved)

_CorpusTH_DurationPreserved() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		; JSON null parses to JSON_NULL (Object), not a Map — skip null configs
		if not (Vec.Has("config") and Type(Vec["config"]) = "Map") {
			continue
		}
		Expected := Vec["expected"]
		if not Expected.Has("duration") {
			continue
		}
		Cfg     := Vec["config"]
		KeyId   := Vec["key"]
		Content := _CorpusTH_BuildToml(KeyId, Cfg)
		Path    := _CorpusTH_WriteToml(Content)
		TH      := LoadTapHoldToml(Path)
		_CorpusTH_CleanToml()

		AssertEqual(Expected["duration"], TapHoldDuration(TH, KeyId),
			"vector '" . Vec["id"] . "': time_activation_seconds mismatch after round-trip")
	}
}
Test("tap_hold corpus  --  time_activation_seconds is preserved after TOML round-trip", _CorpusTH_DurationPreserved)

_CorpusTH_HoldModifierPreserved() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		; JSON null parses to JSON_NULL (Object), not a Map — skip null configs
		if not (Vec.Has("config") and Type(Vec["config"]) = "Map") {
			continue
		}
		Expected := Vec["expected"]
		if not Expected.Has("hold_modifier") {
			continue
		}
		; Skip null hold_modifier — JSON null parses to JSON_NULL (Object) and
		; the AHK accessor returns "" for an absent field; both are skipped here.
		if Expected["hold_modifier"] = "" or Type(Expected["hold_modifier"]) != "String" {
			continue
		}
		Cfg     := Vec["config"]
		KeyId   := Vec["key"]
		Content := _CorpusTH_BuildToml(KeyId, Cfg)
		Path    := _CorpusTH_WriteToml(Content)
		TH      := LoadTapHoldToml(Path)
		_CorpusTH_CleanToml()

		AssertEqual(Expected["hold_modifier"], TapHoldHoldModifier(TH, KeyId),
			"vector '" . Vec["id"] . "': hold_modifier mismatch after round-trip")
	}
}
Test("tap_hold corpus  --  hold_modifier is preserved after TOML round-trip", _CorpusTH_HoldModifierPreserved)

_CorpusTH_UnconfiguredKeyReturnsNotConfigured() {
	Corpus := _CorpusTH_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("configured") and Expected["configured"] = false) {
			continue
		}
		; Build an empty config that does not contain the queried key
		Content := "[tap_hold.keys.other_key]`r`n" . 'tap_action = "x"' . "`r`n"
		Path    := _CorpusTH_WriteToml(Content)
		TH      := LoadTapHoldToml(Path)
		_CorpusTH_CleanToml()

		AssertTrue(!TapHoldIsConfigured(TH, Vec["key"]),
			"vector '" . Vec["id"] . "': absent key must return configured=false")
	}
}
Test("tap_hold corpus  --  unconfigured key: TapHoldIsConfigured returns false", _CorpusTH_UnconfiguredKeyReturnsNotConfigured)
