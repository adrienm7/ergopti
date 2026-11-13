; _shared/ai/data/local_server_fingerprint.ahk

; ==============================================================================
; MODULE: Local Server Fingerprint
; DESCRIPTION:
; AHK twin of _shared/ai/engine/local_servers/fingerprint.lua. Two catalogue rows may
; share a default address (oMLX and vLLM on 8000); the OpenAI models listing has
; the same shape for both, but each project fills a field of its model objects
; with its own value. This reads those declared values and decides which row of a
; shared address actually answered. Pure: the discovery controller calls it on
; the bodies it settles and keeps one row per answering address.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Catalogue ================
; =====================================
; =====================================

; Validates one declared rule; Reason names the refusal.
_LocalServerFingerprintRule(Id, Raw, &Reason) {
	Reason := ""
	if !(Raw is Map) {
		Reason := Id . ".fingerprint must be an object"
		return 0
	}
	Field := Raw.Get("model_field", 0)
	if !(Field is String) || !RegExMatch(Field, "^[A-Za-z_][A-Za-z0-9_]*$") {
		Reason := Id . ".fingerprint.model_field must be a field name"
		return 0
	}
	Equals := Raw.Get("equals", 0)
	if !(Equals is String) || Equals == "" {
		Reason := Id . ".fingerprint.equals must be a non-empty string"
		return 0
	}
	return Map("model_field", Field, "equals", Equals)
}

/**
 * Reads the fingerprints of the rows that share a default address. A rule on a
 * row whose address no other row shares is refused: nothing would ever be decided
 * with it.
 * @param {Map} Root Decoded local_servers.json.
 * @param {Array} Order Admitted catalogue ids in server_order.
 * @returns {Map} "identities": server id -> Map of "group" (ids sharing its address
 * in server_order, the first being the address's default row) and "rule" (0 when
 * none); "errors": the reasons a declared rule was refused, sorted.
 */
LocalServerFingerprintParse(Root, Order) {
	Identities := Map(), Errors := [], Groups := Map()
	Servers := (Root is Map) && (Root.Get("servers", 0) is Map) ? Root["servers"] : Map()
	for Id in Order {
		Server := Servers.Get(Id, 0)
		Address := (Server is Map) ? Server.Get("base_url", 0) : 0
		if Address is String {
			if !Groups.Has(Address)
				Groups[Address] := []
			Groups[Address].Push(Id)
		}
	}
	for Id in Order {
		Server := Servers.Get(Id, 0)
		if !(Server is Map)
			continue
		Address := Server.Get("base_url", 0)
		Group := (Address is String) && Groups.Has(Address) ? Groups[Address] : 0
		if (Group is Array) && Group.Length > 1 {
			Rule := 0
			if Server.Has("fingerprint") {
				Rule := _LocalServerFingerprintRule(Id, Server["fingerprint"], &Reason)
				if Reason != ""
					Errors.Push(Reason)
			}
			Identities[Id] := Map("group", Group.Clone(), "rule", Rule)
		} else if Server.Has("fingerprint") {
			Errors.Push(Id . ".fingerprint is declared on an address no other row shares")
		}
	}
	; Two rows of one address with the same rule could never be told apart
	for Id, Identity in Identities {
		for Other in Identity["group"] {
			Mine := Identity["rule"]
			Theirs := Identities.Has(Other) ? Identities[Other]["rule"] : 0
			if StrCompare(Other, Id, true) < 0 && (Mine is Map) && (Theirs is Map)
					&& Mine["model_field"] == Theirs["model_field"] && Mine["equals"] == Theirs["equals"] {
				Errors.Push(Id . ".fingerprint repeats the one of " . Other)
				Identity["rule"] := 0
				Identities[Other]["rule"] := 0
			}
		}
	}
	return Map("identities", Identities, "errors", _LocalServerFingerprintSorted(Errors))
}

_LocalServerFingerprintSorted(Texts) {
	Joined := ""
	for Text in Texts
		Joined .= (A_Index > 1 ? "`n" : "") . Text
	return Joined == "" ? [] : StrSplit(Sort(Joined, "C"), "`n")
}





; =====================================
; =====================================
; ======= 2/ Identification ===========
; =====================================
; =====================================

/**
 * Names the row of a shared address whose fingerprint a models body carries.
 * @param {Any} Body The raw models response body.
 * @param {String} Id The row that was probed.
 * @param {Map} Identities The "identities" of LocalServerFingerprintParse.
 * @returns {Map} "server": the fingerprinted row, "" when none decides; "decision":
 * "match", "unshared", "invalid", "unknown" or "ambiguous".
 */
LocalServerFingerprintIdentify(Body, Id, Identities) {
	Identity := (Identities is Map) ? Identities.Get(Id, 0) : 0
	if !(Identity is Map)
		return Map("server", "", "decision","unshared")
	Root := 0
	if Body is String {
		try Root := JsonParse(Body)
		catch
			Root := 0
	}
	if !(Root is Map) || !(Root.Get("data", 0) is Array)
		return Map("server", "", "decision","invalid")
	Found := ""
	for Candidate in Identity["group"] {
		Row := Identities.Get(Candidate, 0)
		Rule := (Row is Map) ? Row["rule"] : 0
		if !(Rule is Map)
			continue
		Matched := false
		for Model in Root["data"] {
			Value := (Model is Map) ? Model.Get(Rule["model_field"], 0) : 0
			if (Value is String) && Value == Rule["equals"] {
				Matched := true
				break
			}
		}
		if !Matched
			continue
		if Found != ""
			return Map("server", "", "decision","ambiguous")
		Found := Candidate
	}
	return Found == "" ? Map("server", "", "decision","unknown") : Map("server", Found, "decision","match")
}
