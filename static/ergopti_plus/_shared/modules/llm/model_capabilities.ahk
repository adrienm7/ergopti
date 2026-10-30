; _shared/modules/llm/model_capabilities.ahk

; ==============================================================================
; MODULE: Model Capabilities
; DESCRIPTION:
; Some providers say in their model listing which reasoning controls each
; model takes: OpenRouter's /models supported_parameters, the Anthropic Models
; API capabilities, Gemini's models.list thinking flag. A control a listing
; says a model lacks is not sent (LLM_ThinkingOffResolve), so the request goes
; out right the first time instead of through an HTTP 400 and its retry.
;
; FEATURES & RATIONALE:
; 1. Pure: the driver fetches the listing off the prediction path (a deferred,
;    separate request) and hands the decoded answer here; no key or address
;    reaches this module.
; 2. A model the listing does not describe, or a field it does not state,
;    lacks nothing: only an explicit "not supported" skips a control.
;    JsonParse reads true and false as 1 and 0, so a flag is any 0 or 1.
; 3. A per-provider cache with a time to live (thinking_off.json
;    capability_listing.ttl_hours): a stale or missing listing is fetched
;    again once, never twice at the same time, and the old one serves
;    meanwhile.
; 4. Bounded: at most LLM_MODEL_CAPABILITIES_MAX_MODELS models per listing.
;
; The shared Lua implementation is _shared/lua/llm/model_capabilities.lua.
; Both replay _shared/tests/corpus/llm/model_capabilities_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Constants =================
; ======================================
; ======================================

; Most models one listing keeps; OpenRouter lists a few hundred
global LLM_MODEL_CAPABILITIES_MAX_MODELS := 2000

; The listing dialects and the array of models each one answers
global LLM_MODEL_CAPABILITIES_LISTINGS := Map("openrouter", "data", "anthropic", "data", "gemini", "models")

; A provider id, as api_providers.json names them
global LLM_MODEL_CAPABILITIES_PROVIDER_PATTERN := "^[a-z0-9_]+$"

; A page query: one name=number pair
global LLM_MODEL_CAPABILITIES_PAGE_QUERY_PATTERN := "^[A-Za-z]+=[0-9]+$"





; ======================================
; ======================================
; ======= 2/ Configuration =============
; ======================================
; ======================================

/**
 * Validates thinking_off.json capability_listing.
 * @param {Any} Raw The decoded section.
 * @returns {Map} Map("ttl_sec", "providers" (id -> listing), "page_query" (listing -> query)).
 * @throws {Error} A malformed section, refused whole.
 */
LLM_ModelCapsParseConfig(Raw) {
	global LLM_MODEL_CAPABILITIES_LISTINGS, LLM_MODEL_CAPABILITIES_PROVIDER_PATTERN
	global LLM_MODEL_CAPABILITIES_PAGE_QUERY_PATTERN
	if !(Raw is Map)
		throw ValueError("capability_listing must be an object.")
	Hours := Raw.Get("ttl_hours", 0)
	if !(Hours is Integer) || Hours <= 0
		throw ValueError("capability_listing.ttl_hours must be a positive integer.")
	if !(Raw.Get("providers", 0) is Map) || Raw["providers"].Count == 0
		throw ValueError("capability_listing.providers must be a non-empty object.")
	Providers := Map(), PageQuery := Map()
	for Id, Listing in Raw["providers"] {
		if !RegExMatch(Id, LLM_MODEL_CAPABILITIES_PROVIDER_PATTERN) || !(Listing is String)
				|| !LLM_MODEL_CAPABILITIES_LISTINGS.Has(Listing)
			throw ValueError("capability_listing.providers holds an invalid entry " . Id . ".")
		Providers[Id] := Listing
	}
	if !(Raw.Get("page_query", 0) is Map)
		throw ValueError("capability_listing.page_query must be an object.")
	for Listing, Query in Raw["page_query"] {
		if (SubStr(Listing, 1, 1) == "_")
			continue
		if !LLM_MODEL_CAPABILITIES_LISTINGS.Has(Listing) || !(Query is String)
				|| !RegExMatch(Query, LLM_MODEL_CAPABILITIES_PAGE_QUERY_PATTERN)
			throw ValueError("capability_listing.page_query holds an invalid entry " . Listing . ".")
		PageQuery[Listing] := Query
	}
	return Map("ttl_sec", Hours * 3600, "providers", Providers, "page_query", PageQuery)
}





; ======================================
; ======================================
; ======= 3/ Listing ===================
; ======================================
; ======================================

; Tells whether a stored flag says "not supported" (a decoded 0, never "").
_LLM_ModelCapsNo(Flag) {
	return (Flag is Integer) && Flag == 0
}

; A flag JsonParse decoded (1 or 0), "" when unstated.
_LLM_ModelCapsFlag(Node) {
	if !(Node is Map) || !Node.Has("supported")
		return ""
	Value := Node["supported"]
	return (Value is Integer && (Value == 0 || Value == 1)) ? Value : ""
}

; The flags of a node's named children (thinking types, effort levels).
_LLM_ModelCapsChildren(Node) {
	Out := Map()
	if !(Node is Map)
		return Out
	for Name, Child in Node {
		Flag := _LLM_ModelCapsFlag(Child)
		if (Flag != "")
			Out[Name] := Flag
	}
	return Out
}

; Reads one model of a listing into Out; ignores a model it cannot describe.
_LLM_ModelCapsRead(Listing, Item, Out) {
	if (Listing == "openrouter") {
		if !(Item.Get("id", 0) is String) || !(Item.Get("supported_parameters", 0) is Array)
			return false
		Params := Map()
		for Param in Item["supported_parameters"] {
			if !(Param is String)
				return false
			Params[Param] := 1
		}
		Id := Item["id"], Record := Map("params", Params)
	} else if (Listing == "anthropic") {
		if !(Item.Get("id", 0) is String) || !(Item.Get("capabilities", 0) is Map)
			return false
		Caps := Item["capabilities"]
		Id := Item["id"], Record := Map()
		if (Caps.Get("thinking", 0) is Map)
			Record["thinking"] := Map("supported", _LLM_ModelCapsFlag(Caps["thinking"]),
				"types", _LLM_ModelCapsChildren(Caps["thinking"].Get("types", 0)))
		if (Caps.Get("effort", 0) is Map)
			Record["effort"] := Map("supported", _LLM_ModelCapsFlag(Caps["effort"]),
				"levels", _LLM_ModelCapsChildren(Caps["effort"]))
	} else {
		Thinking := Item.Get("thinking", "")
		if !(Item.Get("name", 0) is String) || !(Thinking is Integer && (Thinking == 0 || Thinking == 1))
			return false
		Id := RegExReplace(Item["name"], "^models/"), Record := Map("gemini_thinking", Thinking)
	}
	if Out.Has(Id)
		return false
	Out[Id] := Record
	return true
}

/**
 * Reads a decoded listing answer into per-model records.
 * @param {String} Listing "openrouter", "anthropic" or "gemini".
 * @param {Any} Decoded The JsonParse'd body.
 * @param {VarRef} Reason Receives "unsupported" or "unreadable" on a refusal.
 * @returns {Map|String} Model id -> record, "" when refused.
 */
LLM_ModelCapsParse(Listing, Decoded, &Reason := "") {
	global LLM_MODEL_CAPABILITIES_LISTINGS, LLM_MODEL_CAPABILITIES_MAX_MODELS
	Reason := ""
	if !(Listing is String) || !LLM_MODEL_CAPABILITIES_LISTINGS.Has(Listing) {
		Reason := "unsupported"
		return ""
	}
	Key := LLM_MODEL_CAPABILITIES_LISTINGS[Listing]
	if !(Decoded is Map) || !(Decoded.Get(Key, 0) is Array) {
		Reason := "unreadable"
		return ""
	}
	Records := Map()
	for Item in Decoded[Key] {
		if (Records.Count >= LLM_MODEL_CAPABILITIES_MAX_MODELS)
			break
		if (Item is Map)
			_LLM_ModelCapsRead(Listing, Item, Records)
	}
	return Records
}

/**
 * The record a listing holds for a model, "" when it says nothing.
 * @param {Map|String} Records LLM_ModelCapsParse's output.
 * @param {String} Model The model id as the request names it.
 * @returns {Map|String}
 */
LLM_ModelCapsRecord(Records, Model) {
	if !(Records is Map) || !(Model is String)
		return ""
	if Records.Has(Model)
		return Records[Model]
	Bare := RegExReplace(Model, "^models/")
	return Records.Has(Bare) ? Records[Bare] : ""
}

/**
 * Tells whether a listing says a model lacks a control.
 * @param {Map|String} Record LLM_ModelCapsRecord's output.
 * @param {String} Kind The control kind (thinking_off.json).
 * @param {Any} Level The control's level, "" for a toggle.
 * @param {String} FieldsText The dialect template's JSON source.
 * @returns {Boolean}
 */
LLM_ModelCapsLacks(Record, Kind, Level, FieldsText) {
	if !(Record is Map)
		return false
	if Record.Has("params") {
		for Name in JsonObjectMemberSpans(FieldsText) {
			if !Record["params"].Has(Name)
				return true
		}
		return false
	}
	if (Kind == "anthropic_thinking" && Record.Has("thinking")) {
		Node := Record["thinking"]
		return _LLM_ModelCapsNo(Node["supported"]) || (Level is String && _LLM_ModelCapsNo(Node["types"].Get(Level, "")))
	}
	if (Kind == "anthropic_effort" && Record.Has("effort")) {
		Node := Record["effort"]
		return _LLM_ModelCapsNo(Node["supported"]) || (Level is String && _LLM_ModelCapsNo(Node["levels"].Get(Level, "")))
	}
	if (Kind == "gemini_budget" || Kind == "gemini_level")
		return _LLM_ModelCapsNo(Record.Get("gemini_thinking", ""))
	return false
}





; ======================================
; ======================================
; ======= 4/ Cache =====================
; ======================================
; ======================================

/**
 * Tells whether a provider's listing must be fetched: none yet, or older than
 * the time to live, and no fetch under way.
 * @param {Map} Cache Provider id -> Map("records", "at", "pending").
 * @param {String} Provider
 * @param {Number} Now Epoch seconds.
 * @param {Number} TtlSec
 * @returns {Boolean}
 */
LLM_ModelCapsNeedsFetch(Cache, Provider, Now, TtlSec) {
	if !Cache.Has(Provider)
		return true
	Entry := Cache[Provider]
	if Entry.Get("pending", false)
		return false
	At := Entry.Get("at", "")
	return At == "" || Now - At >= TtlSec || At > Now
}

; Marks a provider's fetch as under way.
LLM_ModelCapsBegin(Cache, Provider) {
	if !Cache.Has(Provider)
		Cache[Provider] := Map()
	Cache[Provider]["pending"] := true
}

/**
 * Ends a provider's fetch: new records replace the old ones; a failed fetch
 * keeps them and waits for the time to live before the next attempt.
 * @param {Map} Cache
 * @param {String} Provider
 * @param {Map|String} Records LLM_ModelCapsParse's output, "" when the fetch failed.
 * @param {Number} Now Epoch seconds.
 */
LLM_ModelCapsFinish(Cache, Provider, Records, Now) {
	if !Cache.Has(Provider)
		Cache[Provider] := Map()
	Entry := Cache[Provider]
	Entry["pending"] := false
	Entry["at"] := Now
	if (Records is Map)
		Entry["records"] := Records
}

; The records a provider's cache holds, "" when none.
LLM_ModelCapsRecords(Cache, Provider) {
	return Cache.Has(Provider) ? Cache[Provider].Get("records", "") : ""
}
