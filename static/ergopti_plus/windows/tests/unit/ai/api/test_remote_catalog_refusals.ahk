; tests/unit/ai/api/test_remote_catalog_refusals.ahk

; ==============================================================================
; MODULE: Remote API Catalogue Refusals And Walk Count
; DESCRIPTION:
; Feeds malformed api_providers.json catalogues to the real loader
; (_LLMRemote_LoadCatalog) and pins each refusal with its exact message: the
; whole catalogue for a syntax or shape error, one provider for a malformed
; thinking_dialect. Then counts the complete-document passes of one load.
;
; ROOT CAUSE ENCODED:
; The boot decoded the catalogue, validated the whole text again to find each
; provider's source, then validated each provider's source once more for its
; thinking_dialect: about 45-60 ms of the AI catalogue stage repeated work the
; decode had already done. The refusals below were captured on that loader and
; must not change.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Fixture loader =========
; ===================================
; ===================================

; A descriptor every rule of _LLMRemote_CatalogDescriptorIsValid accepts.
_RCR_Descriptor(Extra := "") {
	return '{"label": "P", "base_url": "https://p.example/v1", "default_model": "m", "format": "openai"'
		. (Extra == "" ? "" : ", " . Extra) . "}"
}

; Loads one catalogue text from a private shared root, then restores every
; global the load publishes.
; @param {String} Text The api_providers.json source.
; @returns {Map} "thrown" (the load's error message, "" when it returned),
;     "logged" (every log line of the load), "providers" (the published
;     provider registry) and "tally" (JsonDecodeTally deltas of the load).
_RCR_Load(Text) {
	global _SharedDir, LLM_API_PROVIDERS
	static Serial := 0
	Serial += 1
	Published := _RemoteCatalog_SnapshotPublished()
	OldSharedDir := _SharedDir
	Root := A_Temp . "\ergopti-catalog-refusal-" . DllCall("GetCurrentProcessId") . "-" . Serial
	Lines := []
	Result := Map("thrown", "", "logged", Lines)
	try {
		DirCreate(Root . "\ai\data")
		FileAppend(Text, Root . "\ai\data\api_providers.json", "UTF-8-RAW")
		_SharedDir := Root
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Before := JsonDecodeTally()
		try _LLMRemote_LoadCatalog()
		catch as Err
			Result["thrown"] := Err.Message
		After := JsonDecodeTally()
		Delta := Map()
		for Name, Value in After
			Delta[Name] := Value - Before[Name]
		Result["tally"] := Delta
		Result["providers"] := LLM_API_PROVIDERS
	} finally {
		LoggerClearTestSink()
		_SharedDir := OldSharedDir
		_RemoteCatalog_RestorePublished(Published)
		try DirDelete(Root, true)
	}
	return Result
}

; True when one logged line holds Needle.
_RCR_Logged(Result, Needle) {
	for Line in Result["logged"]
		if InStr(Line, Needle, true)
			return true
	return false
}





; ===========================================
; ===========================================
; ======= 2/ Whole-catalogue refusals =======
; ===========================================
; ===========================================

_RCR_WholeCatalogueRefusals() {
	Valid := '"provider_order": ["p"], "providers": {"p": ' . _RCR_Descriptor() . '}, "model_prices": {}'
	Cases := [
		['{"provider_order": [', "api_providers.json parse failed: JSON: unexpected end of input."],
		['{} x', "api_providers.json parse failed: JSON: unexpected trailing data at position 4."],
		['{"a": 1,}', "api_providers.json parse failed: JSON: expected string key at position 9."],
		['{"a\u0000": 1}', "api_providers.json parse failed: JSON: NUL object key cannot be represented at position 6."],
		['{"a": "\q"}', "api_providers.json parse failed: JSON: invalid escape sequence at position 10."],
		['{"a": "\udc00"}', "api_providers.json parse failed: JSON: isolated low surrogate at position 10."],
		['{"a": tru}', "api_providers.json parse failed: JSON: expected boolean literal at position 7."],
		['[]', "api_providers.json root must be an object"],
		['"text"', "api_providers.json root must be an object"],
		['{"providers": {"p": ' . _RCR_Descriptor() . '}, "model_prices": {}}',
			"api_providers.json: provider_order must be a non-empty array"],
		['{"provider_order": [], "providers": {"p": ' . _RCR_Descriptor() . '}, "model_prices": {}}',
			"api_providers.json: provider_order must be a non-empty array"],
		['{"provider_order": ["p"], "providers": [], "model_prices": {}}',
			"api_providers.json: providers must be a non-empty object"],
		['{"provider_order": ["p"], "providers": {}, "model_prices": {}}',
			"api_providers.json: providers must be a non-empty object"],
		['{"provider_order": ["p"], "providers": {"p": ' . _RCR_Descriptor() . '}}',
			"api_providers.json: model_prices must be an object"],
		; The decoder keeps the last of two equal keys: a later scalar providers wins
		['{' . Valid . ', "providers": "x"}', "api_providers.json: providers must be a non-empty object"]
	]
	; One more nesting level than the decoder accepts
	Deep := ""
	loop JSON_MAX_NESTING_DEPTH + 1
		Deep .= "["
	Cases.Push(['{"a": ' . Deep, "api_providers.json parse failed: JSON: maximum nesting depth exceeded at position "
		. (JSON_MAX_NESTING_DEPTH + 6) . "."])
	for Row in Cases {
		Result := _RCR_Load(Row[1])
		AssertEqual(Row[2], Result["thrown"], "the refusal of " . SubStr(Row[1], 1, 60))
	}
	AssertEqual("", _RCR_Load('{' . Valid . '}')["thrown"], "the minimal valid catalogue loads")
}
Test("api_providers.json: a malformed catalogue is refused whole with its message", _RCR_WholeCatalogueRefusals)





; ==========================================
; ==========================================
; ======= 3/ One provider's dialect ========
; ==========================================
; ==========================================

_RCR_DialectRefusals() {
	Refused := [
		["p_string", '"x"', "Selected JSON member is not an object."],
		["p_null", "null", "Selected JSON member is not an object."],
		["p_array", "[]", "Selected JSON member is not an object."],
		["p_number", "1", "Selected JSON member is not an object."],
		["p_unknown", '{"bogus": {"a": 1}}', "thinking_dialect has an unknown kind bogus."],
		["p_fields_array", '{"toggle": []}', "thinking_dialect.toggle has invalid fields."],
		["p_fields_empty", '{"toggle": {}}', "thinking_dialect.toggle has invalid fields."],
		["p_fields_name", '{"toggle": {"1x": false}}', "thinking_dialect.toggle has invalid fields."],
		["p_fields_null", '{"toggle": {"a": null}}', "thinking_dialect.toggle has invalid fields."],
		["p_fields_nested_empty", '{"toggle": {"a": {}}}', "thinking_dialect.toggle has invalid fields."],
		["p_fields_nested_array", '{"toggle": {"a": {"b": [1]}}}', "thinking_dialect.toggle has invalid fields."],
		["p_no_level", '{"effort": {"reasoning_effort": "low"}}', "thinking_dialect.effort needs a level."],
		["p_toggle_level", '{"toggle": {"x": "$level"}}', "thinking_dialect.toggle cannot hold a level."],
		; Map order: the first kind in key order is checked first
		["p_two_errors", '{"toggle": {"x": "$level"}, "effort": {"e": "low"}}', "thinking_dialect.effort needs a level."]
	]
	Accepted := [
		["v_none", "", ""],
		["v_empty", "{}", ""],
		["v_comment", '{"_note": [1, null], "toggle": {"thinking": {"type": "disabled", "on": false}}}',
			'{"thinking": {"type": "disabled", "on": false}}'],
		["v_effort", '{"effort": {"reasoning_effort": "$level"}}', '{"reasoning_effort": "$level"}']
	]
	Order := "", Providers := ""
	for Row in Refused {
		Order .= (Order == "" ? "" : ", ") . '"' . Row[1] . '"'
		Providers .= (Providers == "" ? "" : ", ") . '"' . Row[1] . '": ' . _RCR_Descriptor('"thinking_dialect": ' . Row[2])
	}
	for Row in Accepted {
		Order .= ', "' . Row[1] . '"'
		Providers .= ', "' . Row[1] . '": ' . _RCR_Descriptor(Row[2] == "" ? "" : '"thinking_dialect": ' . Row[2])
	}
	; An escaped member name is the same key to the decoder and to the span walk
	Order .= ', "p_escaped_key", "d_last_wins", "d_inner_last_wins", "d_inner_last_refused"'
	Providers .= ', "p_escaped_key": ' . _RCR_Descriptor('"thinking_dialect": "x"')
		. ', "d_last_wins": ' . _RCR_Descriptor('"thinking_dialect": "x"')
		. ', "d_last_wins": ' . _RCR_Descriptor('"thinking_dialect": {"toggle": {"t": false}}')
		. ', "d_inner_last_wins": ' . _RCR_Descriptor('"thinking_dialect": 1, "thinking_dialect": {"toggle": {"t": true}}')
		. ', "d_inner_last_refused": ' . _RCR_Descriptor('"thinking_dialect": {"toggle": {"t": true}}, "thinking_dialect": 1')
	Result := _RCR_Load('{"provider_order": [' . Order . '], "providers": {' . Providers . '}, "model_prices": {}}')
	AssertEqual("", Result["thrown"], "a refused dialect refuses its provider only")
	Published := Result["providers"]
	for Row in Refused {
		AssertFalse(Published.Has(Row[1]), Row[1] . " is refused")
		AssertTrue(_RCR_Logged(Result, "api_providers.json: providers." . Row[1] . ".thinking_dialect is invalid ("
			. Row[3] . ") — skipped."), Row[1] . " is refused with: " . Row[3])
	}
	for Row in Accepted {
		AssertTrue(Published.Has(Row[1]), Row[1] . " publishes")
		Dialect := Published[Row[1]]["ThinkingDialect"]
		AssertEqual(Row[3] == "" ? 0 : 1, Dialect.Count, Row[1] . " keeps each kind it declares")
		if (Row[3] != "")
			AssertEqual(Row[3], Dialect.Has("toggle") ? Dialect["toggle"] : Dialect["effort"],
				Row[1] . " keeps the fields' exact source, a JSON false included")
	}
	AssertFalse(Published.Has("p_escaped_key"), "an escaped thinking_dialect name is still read")
	AssertTrue(_RCR_Logged(Result, "providers.p_escaped_key.thinking_dialect is invalid (Selected JSON member is not an object.)"),
		"the escaped name's dialect is refused like the plain one")
	AssertEqual('{"t": false}', Published["d_last_wins"]["ThinkingDialect"]["toggle"],
		"the dialect comes from the provider the decoder kept, the last one")
	AssertEqual('{"t": true}', Published["d_inner_last_wins"]["ThinkingDialect"]["toggle"],
		"the last of two thinking_dialect members is the one read")
	AssertFalse(Published.Has("d_inner_last_refused"), "a later malformed thinking_dialect still refuses its provider")
}
Test("api_providers.json: a malformed thinking_dialect refuses its provider with its message", _RCR_DialectRefusals)





; ===========================================
; ===========================================
; ======= 4/ Complete-document passes =======
; ===========================================
; ===========================================

; The catalogue owner walks its text as one complete document, whatever it
; holds: the decode is that walk, and finding each provider's thinking_dialect
; source walks no text again, neither the whole file nor a provider's or a
; dialect's slice of it. The other owners the load calls (the local servers and
; the thinking families, absent from the private root) cost the same for any
; catalogue, so the shipped catalogue may cost a one-provider catalogue's passes
; and no more, and exactly its extra code units, once.
_RCR_ShippedCatalogueWalkedOnce() {
	global _SharedDir
	Minimal := '{"provider_order": ["p"], "providers": {"p": ' . _RCR_Descriptor() . '}, "model_prices": {}}'
	Shipped := FileRead(_SharedDir . "\ai\data\api_providers.json", "UTF-8")
	Small := _RCR_Load(Minimal)
	Large := _RCR_Load(Shipped)
	AssertEqual("", Small["thrown"], "the one-provider catalogue loads")
	AssertEqual("", Large["thrown"], "the shipped catalogue loads")
	Dialects := 0
	for ProviderId, Provider in Large["providers"]
		Dialects += Provider.Has("ThinkingDialect") && Provider["ThinkingDialect"].Count > 0
	AssertTrue(Dialects > 1, "the shipped catalogue still carries several thinking dialects to read")
	AssertEqual(Small["tally"]["document_passes"], Large["tally"]["document_passes"],
		"a provider or a dialect adds no complete-document pass to the load")
	AssertEqual(StrLen(Shipped) - StrLen(Minimal),
		Large["tally"]["document_units"] - Small["tally"]["document_units"],
		"the catalogue's text is walked once, so its extra code units count once")
}
Test("api_providers.json: one load walks the catalogue text once", _RCR_ShippedCatalogueWalkedOnce)
