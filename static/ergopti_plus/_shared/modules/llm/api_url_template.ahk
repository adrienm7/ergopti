; _shared/modules/llm/api_url_template.ahk

; ==============================================================================
; MODULE: API URL Template
; DESCRIPTION:
; The address of a provider whose host or path depends on the user's account:
; api_providers.json writes its base_url as a template such as
; "https://{resource}.openai.azure.com/openai/v1", the add-entry form asks one
; value per placeholder, and the filled address becomes the entry's BaseUrl.
; Port of _shared/lua/llm/api_url_template.lua; both replay
; _shared/tests/corpus/llm/api_url_template_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Public API ===========
; =================================
; =================================

/**
 * The longest value one placeholder takes: a DNS name. A function, so it
 * holds whatever the include order of the driver or the suite.
 * @returns {Integer}
 */
ApiUrlTemplateMaxValueLength() {
	return 253
}

/**
 * Whether an address still holds a placeholder: such an address never reaches
 * the network.
 * @param {Any} Url
 * @returns {Boolean}
 */
ApiUrlTemplateHasPlaceholder(Url) {
	return (Url is String) && InStr(Url, "{") > 0
}

/**
 * The placeholders of a template, in order, each once.
 * @param {Any} Template A catalogue base_url.
 * @returns {Map} Map("fields", Array, "valid", Boolean); valid is false when a
 *     brace stands outside a {name} placeholder (name: a-z, 0-9, _).
 */
ApiUrlTemplateFields(Template) {
	Fields := [], Seen := Map()
	if !(Template is String)
		return Map("fields", Fields, "valid", true)
	Position := 1
	while (Position := RegExMatch(Template, "\{([a-z0-9_]+)\}", &Found, Position)) {
		if !Seen.Has(Found[1]) {
			Seen[Found[1]] := true
			Fields.Push(Found[1])
		}
		Position += Found.Len[0]
	}
	if RegExMatch(RegExReplace(Template, "\{[a-z0-9_]+\}", ""), "[{}]")
		return Map("fields", [], "valid", false)
	return Map("fields", Fields, "valid", true)
}

/**
 * Whether one value may fill a placeholder: a host label or a path segment,
 * so it cannot add a scheme, a user, a port, a path or a query.
 * @param {Any} Value
 * @returns {Boolean}
 */
ApiUrlTemplateValidValue(Value) {
	return (Value is String) && StrLen(Value) > 0 && StrLen(Value) <= ApiUrlTemplateMaxValueLength()
		&& RegExMatch(Value, "^[A-Za-z0-9][A-Za-z0-9._-]*$") > 0
}

/**
 * Fills a template.
 * @param {String} Template A catalogue base_url.
 * @param {Map} Values name -> value, one per placeholder.
 * @returns {Map} Map("url", String) when filled, else Map("field", String)
 *     naming the placeholder whose value is missing or invalid.
 */
ApiUrlTemplateExpand(Template, Values) {
	if !(Template is String)
		throw TypeError("ApiUrlTemplateExpand requires a template string.")
	if !(Values is Map)
		throw TypeError("ApiUrlTemplateExpand requires a Map of values.")
	Parsed := ApiUrlTemplateFields(Template)
	if !Parsed["valid"]
		throw ValueError("ApiUrlTemplateExpand: a brace outside a {name} placeholder.")
	Url := Template
	for Name in Parsed["fields"] {
		Value := Values.Get(Name, "")
		if !ApiUrlTemplateValidValue(Value)
			return Map("field", Name)
		Url := StrReplace(Url, "{" . Name . "}", Value)
	}
	return Map("url", Url)
}
