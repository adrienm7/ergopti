; _shared/modules/llm/local_model_policy.ahk

; ==============================================================================
; MODULE: Local Model Presence Policy
; DESCRIPTION:
; Pure AHK port of _shared/lua/llm/local_model_policy.lua. Native drivers own
; requests, cancellation, consent and downloads; the independent corpus owns
; model normalization, strict list receipts and missing-model classification.
; ==============================================================================

LLM_LocalModelNormalize(Name) {
	if !(Name is String) || Name == ""
		return ""
	Lowered := StrLower(Name)
	Parts := StrSplit(Lowered, "/")
	return InStr(Parts[Parts.Length], ":") ? Lowered : Lowered . ":latest"
}

LLM_LocalModelNames(Models) {
	Names := Map()
	for Row in Models {
		if !(Row is Map)
			continue
		for Field in ["name", "model"] {
			Name := LLM_LocalModelNormalize(Row.Get(Field, ""))
			if Name != ""
				Names[Name] := true
		}
	}
	return Names
}

; Unknown receipts never become a valid empty installation list.
LLM_LocalModelListReceipt(Result) {
	if !(Result is Map) || Result.Get("ok", false) != true || Result.Get("status", 0) != 200
		return Map("ok", false, "reason", "model_list_unavailable")
	try Root := JsonParse(Result.Get("body", ""))
	catch
		return Map("ok", false, "reason", "unreadable_model_list")
	if !(Root is Map) || !(Root.Get("models", 0) is Array)
		return Map("ok", false, "reason", "unreadable_model_list")
	for Row in Root["models"] {
		if !(Row is Map) || (LLM_LocalModelNormalize(Row.Get("name", "")) == ""
				&& LLM_LocalModelNormalize(Row.Get("model", "")) == "")
			return Map("ok", false, "reason", "unreadable_model_list")
	}
	return Map("ok", true, "names", LLM_LocalModelNames(Root["models"]))
}

LLM_LocalModelMissing(Status, ErrorText) {
	if Status != 404 || !(ErrorText is String)
		return ""
	Pattern := "^model [" . Chr(34) . "']([^" . Chr(34) . "']+)['" . Chr(34) . "] not found"
	return RegExMatch(ErrorText, Pattern, &Match) ? Match[1] : ""
}

LLM_LocalModelFailure(Model, BaseUrl) {
	return Map("reason", "model_missing", "model", Model, "base_url", BaseUrl)
}

LLM_LocalModelResponseFailure(Result, BaseUrl) {
	if !(Result is Map)
		return 0
	try Root := JsonParse(Result.Get("error_body", Result.Get("body", "")))
	catch
		return 0
	Model := LLM_LocalModelMissing(Result.Get("status", 0), (Root is Map) ? Root.Get("error", "") : "")
	return Model != "" ? LLM_LocalModelFailure(Model, BaseUrl) : 0
}

LLM_LocalModelIsMissing(Failure) {
	return Failure is Map && Failure.Get("reason", "") == "model_missing"
		&& LLM_LocalModelNormalize(Failure.Get("model", "")) != ""
		&& Failure.Get("base_url", 0) is String
}

LLM_LocalModelShouldNotify(Notified, Model) {
	Name := LLM_LocalModelNormalize(Model)
	return Name != "" && !Notified.Get(Name, false)
}
