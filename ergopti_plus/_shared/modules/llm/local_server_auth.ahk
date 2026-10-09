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
