; modules/keystats/keystats_app_category_store.ahk

; ==============================================================================
; MODULE: App Category Store Codec
; DESCRIPTION:
; Owns the legacy string map and explicit versioned category-edit records.
; Unedited legacy strings remain classifications, not historical score overrides.
; Unknown JSON members retain their canonical parser-owned source fragments.
; ==============================================================================

_KL_AppCat_JsonSource(Content) {
	return SubStr(Content, 1, 1) == Chr(0xFEFF) ? SubStr(Content, 2) : Content
}

_KL_AppCat_ScoreValid(Score) {
	return (Score is Integer || Score is Float)
		&& Score >= KLAppCatConst.MIN_SCORE && Score <= KLAppCatConst.MAX_SCORE
}

_KL_AppCat_LabelValid(Label) {
	return Label is String && Trim(Label, " `t`r`n") != ""
}

; The parser remains authoritative; original spans distinguish true from 1 and
; retain unknown booleans/null without the keystats encoder's primitive aliases.
_KL_AppCat_DecodeStore(Content, Path := "") {
	Source := _KL_AppCat_JsonSource(Content)
	Document := JsonParse(Source)
	if !(Document is Map)
		throw TypeError("App categories require a JSON object.")
	Members := JsonObjectMemberSpans(Source)
	Legacy := true
	for Key, Value in Document
		if !(Value is String)
			Legacy := false
	; Legacy process keys were unrestricted, so a valid all-string map cannot
	; acquire schema semantics merely because one process was named "schema".
	Versioned := !Legacy && Document.Has("schema")
		&& Document["schema"] == KLAppCatConst.STORE_SCHEMA
	if Versioned {
		if !Document.Has("version") || !(Document["version"] is Integer)
			|| Document["version"] != KLAppCatConst.STORE_VERSION
			|| Trim(Members["version"]["text"]) != String(KLAppCatConst.STORE_VERSION)
			throw ValueError("Unsupported app category store version.")
		if !Document.Has("apps") || !(Document["apps"] is Map)
			throw TypeError("App category records require an apps object.")
		Apps := Document["apps"]
		AppMembers := JsonObjectMemberSpans(Source, ["apps"])
	} else {
		Apps := Document
		AppMembers := Members
	}
	Categories := Map(), OriginalKeys := Map(), Records := Map()
	for Key, Value in Apps {
		if !(Key is String) || Key == ""
			throw TypeError("An app category key must be a nonempty process name.")
		if Value is String {
			if Value == ""
				throw ValueError("A legacy app category cannot be empty.")
		} else if Versioned && Value is Map {
			Fields := JsonObjectMemberSpans(AppMembers[Key]["text"])
			if !Value.Has("type") || !_KL_AppCat_LabelValid(Value["type"])
				|| !Value.Has("score") || !_KL_AppCat_ScoreValid(Value["score"])
				|| !RegExMatch(Trim(Fields["score"]["text"]), "^[-0-9]")
				throw ValueError("An app category edit requires a label and finite score between -2 and 2.")
			Records[StrLower(Key)] := Fields
		} else {
			throw TypeError("Invalid app category entry or unknown store schema.")
		}
		Categories[StrLower(Key)] := Value
		OriginalKeys[StrLower(Key)] := Key
	}
	return Map("path", Path, "source", Content, "versioned", Versioned,
		"categories", Categories, "members", Members, "original_keys", OriginalKeys,
		"records", Records)
}

_KL_AppCat_RecordLabel(Value) {
	return Value is Map ? Value["type"] : Value
}

_KL_AppCat_RecordWithLabel(Value, Label) {
	if !(Value is Map)
		return Label
	Candidate := Map()
	for Key, Field in Value
		Candidate[Key] := Field
	Candidate["type"] := Label
	return Candidate
}

_KL_AppCat_RenderRecord(Value, Fields) {
	Parts := [JsonStringLiteral("type") . ":" . JsonStringLiteral(Value["type"]),
		JsonStringLiteral("score") . ":" . String(Value["score"])]
	for Key, Span in Fields
		if !(Key == "type") && !(Key == "score")
			Parts.Push(Span["member_text"])
	return "{" . KL_JoinArray(Parts, ",") . "}"
}

_KL_AppCat_RenderStore(Categories, Model := 0, ForceVersion := false) {
	Versioned := ForceVersion || (Model is Map && Model["versioned"])
	Keys := [], Parts := []
	for Key, Value in Categories {
		Keys.Push(Key)
		if Value is Map
			Versioned := true
	}
	for Key in KL_SortArray(Keys) {
		Value := Categories[Key]
		Fields := Model is Map ? Model["records"].Get(Key, Map()) : Map()
		Name := Model is Map ? Model["original_keys"].Get(Key, Key) : Key
		Encoded := Value is Map ? _KL_AppCat_RenderRecord(Value, Fields) : JsonStringLiteral(Value)
		Parts.Push(JsonStringLiteral(Name) . ":" . Encoded)
	}
	Apps := "{" . KL_JoinArray(Parts, ",") . "}"
	if !Versioned
		return KL_JsonEncodeObject(Categories)
	Parts := [JsonStringLiteral("schema") . ":" . JsonStringLiteral(KLAppCatConst.STORE_SCHEMA),
		JsonStringLiteral("version") . ":" . String(KLAppCatConst.STORE_VERSION),
		JsonStringLiteral("apps") . ":" . Apps]
	if Model is Map && Model["versioned"] {
		for Key, Span in Model["members"]
			if !(Key == "schema") && !(Key == "version") && !(Key == "apps")
				Parts.Push(Span["member_text"])
	}
	return "{" . KL_JoinArray(Parts, ",") . "}"
}

; Only an explicit record overrides already persisted history. Plain legacy
; strings continue to classify future events through KL_AppCat_Get unchanged.
_KL_AppCat_ProjectStore(Model, Apps) {
	Out := Map()
	for App in Apps {
		Value := Model["categories"].Get(StrLower(App), "")
		if Value is Map
			Out[App] := Map("type", Value["type"], "score", Value["score"])
	}
	return Out
}

_KL_AppCat_OwnerModel(Owner) {
	Model := Owner["model"]
	return Model is Map && Model["path"] == Owner["path"] ? Model : 0
}

; Public mutations replace records rather than editing them in place. Identity
; therefore compares the detached runtime snapshot without serializing metadata.
_KL_AppCat_MapsEqual(Left, Right) {
	if Left.Count != Right.Count
		return false
	for Key, Value in Left
		if !Right.Has(Key) || Type(Value) != Type(Right[Key]) || !(Value == Right[Key])
			return false
	return true
}

; Get is the only public producer of unpersisted entries: non-default processes
; absent from the admitted file enter as "unknown" until their deferred save.
_KL_AppCat_IsDiscovery(Key, Value, Model) {
	return Value is String && Value == "unknown" && !KLAppCatConst.DEFAULTS.Has(Key)
		&& (!(Model is Map) || !Model["categories"].Has(Key))
}
