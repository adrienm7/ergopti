; _shared/modules/llm/local_server_auth.ahk

; ==============================================================================
; MODULE: Local API Authentication
; DESCRIPTION:
; The shared catalogue grants optional authentication to known local providers.
; Native drivers retain configured URL, credential storage and HTTP ownership.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Catalogue And Authentication =======
; ===============================================
; ===============================================

LocalServerAuthCatalogue(Root, Occupied) {
	Order := [], Servers := Map()
	if !(Root is Map) || !(Occupied is Map)
			|| !(Root.Get("server_order", 0) is Array) || !(Root.Get("servers", 0) is Map)
		return Map("order", Order, "servers", Servers)
	for Id in Root["server_order"] {
		if !(Id is String) || !RegExMatch(Id, "^[a-z][a-z0-9_]*$")
				|| Occupied.Has(Id) || Servers.Has(Id)
			continue
		Desc := Root["servers"].Get(Id, 0)
		if !(Desc is Map) || !(Desc.Get("auth", 0) is String)
				|| StrCompare(Desc["auth"], "optional", true) != 0
				|| !(Desc.Get("label", 0) is String) || StrLen(Desc["label"]) == 0
				|| !(Desc.Get("base_url", 0) is String) || !RegExMatch(Desc["base_url"], "^https?://\S+$")
			continue
		Servers[Id] := Map("id", Id, "label", Desc["label"], "base_url", Desc["base_url"], "auth", Desc["auth"])
		Order.Push(Id)
	}
	return Map("order", Order, "servers", Servers)
}

LocalServerAuthTokenAllowed(ProviderId, Token, Servers) {
	if !(ProviderId is String) || StrLen(ProviderId) == 0 || !(Token is String)
		return false
	if StrLen(Token) > 0
		return true
	Server := (Servers is Map) ? Servers.Get(ProviderId, 0) : 0
	return (Server is Map) && (Server.Get("auth", 0) is String)
		&& StrCompare(Server["auth"], "optional", true) == 0
}

LocalServerAuthModelsReceipt(Result) {
	if !(Result is Map) || !(Result.Get("ok", 0) is Integer) || Result["ok"] != true
			|| !(Result.Get("status", 0) is Integer) || Result["status"] != 200
		return false
	if !(Result.Get("body", 0) is String) || Result.Get("body_truncated", false) == true
		return false
	try Root := JsonParse(Result["body"])
	catch
		return false
	if !(Root is Map) || !(Root.Get("data", 0) is Array)
		return false
	Ids := []
	for Row in Root["data"] {
		if !(Row is Map) || !(Row.Get("id", 0) is String) || StrLen(Row["id"]) == 0
			return false
		Ids.Push(Row["id"])
	}
	return Ids
}

/**
 * Matches a configured API identity without inferring a product from its payload.
 * @param {String} Provider Persisted provider identity.
 * @param {String} BaseUrl Explicit configured endpoint for generic providers.
 * @param {String} ServerId Declared local catalogue identity.
 * @param {Map} Servers Validated local catalogue.
 * @returns {Boolean} Exact provider ownership or canonical loopback affinity.
 */
LocalServerAuthEntryMatches(Provider, BaseUrl, ServerId, Servers) {
	if !(Provider is String) || !(BaseUrl is String) || !(ServerId is String)
			|| !(Servers is Map) || !(Servers.Get(ServerId, 0) is Map)
		return false
	if Provider == ServerId
		return true
	if !(Provider == "openai") && !(Provider == "openai_compat")
		return false
	Configured := _LocalServerAuthLoopbackIdentity(BaseUrl)
	Declared := _LocalServerAuthLoopbackIdentity(Servers[ServerId].Get("base_url", 0))
	return Configured is Map && Declared is Map
		&& Configured["scheme"] == Declared["scheme"] && Configured["port"] == Declared["port"]
		&& Configured["path"] == Declared["path"]
}

; Only equivalent loopback spellings share affinity. Host aliases do not turn a
; custom port, alternate path, remote credential or payload into product identity.
_LocalServerAuthLoopbackIdentity(Url) {
	if !(Url is String) || RegExMatch(Url, "[[:space:][:cntrl:]]")
			|| InStr(Url, "\") || InStr(Url, "@") || InStr(Url, "?") || InStr(Url, "#")
		return false
	if !RegExMatch(Url, "i)^(https?)://([^/:]+|\[[^]]+\])(?::([0-9]+))?(/.*)?$", &Parts)
		return false
	Host := StrLower(Parts[2])
	if !(Host == "localhost") && !(Host == "127.0.0.1") && !(Host == "[::1]")
		return false
	try Port := Parts[3] == "" ? (StrLower(Parts[1]) == "http" ? 80 : 443) : Integer(Parts[3])
	catch
		return false
	if Port < 1 || Port > 65535
		return false
	return Map("scheme", StrLower(Parts[1]), "port", Port, "path", RTrim(Parts[4], "/"))
}

/**
 * Keeps optional authentication tied to the configured native endpoint.
 * @param {String} Provider Original provider identity; never rewritten locally.
 * @param {String} Token Exact configured credential.
 * @param {String} BaseUrl Explicit configured endpoint.
 * @param {Map} Servers Validated local catalogue for ordinary provider policy.
 * @returns {Boolean} Provider authentication or explicitly keyless loopback API.
 */
LocalServerAuthEntryTokenAllowed(Provider, Token, BaseUrl, Servers) {
	if LocalServerAuthTokenAllowed(Provider, Token, Servers)
		return true
	return Token is String && Token == "" && Provider is String
		&& ((Provider == "openai") || (Provider == "openai_compat"))
		&& _LocalServerAuthLoopbackIdentity(BaseUrl) is Map
}
