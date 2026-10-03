; _shared/modules/llm/enable_admission.ahk

; ==============================================================================
; MODULE: Local AI Enable Admission
; DESCRIPTION:
; Admits an Ollama enable only from a complete native version receipt and a
; current disabled preference. Native drivers retain HTTP and writer ownership.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Admission Policy =======
; ===================================
; ===================================

LLM_EnableVersionPath() {
	return "/api/version"
}

LLM_EnableRequiresProbe(Backend) {
	return Backend == "ollama"
}

LLM_EnableReceipt(Result) {
	if !(Result is Map) || !(Result.Get("ok", 0) is Integer) || Result.Get("ok", false) != true
			|| !(Result.Get("status", 0) is Integer) || Result.Get("status", 0) != 200
		return Map("admitted", false, "reason", "ollama_unreachable")
	if !(Result.Get("body", 0) is String)
			|| Result.Get("body_truncated", false) == true
		return Map("admitted", false, "reason", "unreadable_ollama_receipt")
	try Root := JsonParse(Result["body"])
	catch
		return Map("admitted", false, "reason", "unreadable_ollama_receipt")
	if !(Root is Map) || !(Root.Get("version", 0) is String)
			|| Root["version"] == ""
		return Map("admitted", false, "reason", "unreadable_ollama_receipt")
	return Map("admitted", true)
}

LLM_EnableCurrent(Captured, Live) {
	if !(Captured is Map) || !(Live is Map)
			|| Live.Get("enabled", true) != false
			|| Live.Get("paused", true) != false
			|| Live.Get("blocked", true) != false
		return false
	for Key in ["enabled", "paused", "blocked"] {
		if !(Live.Get(Key, 1) is Integer)
			return false
	}
	for Key in ["backend", "model", "origin"] {
		if !(Captured.Get(Key, 0) is String)
				|| !(Live.Get(Key, 0) is String)
				|| StrCompare(Captured[Key], Live[Key], true) != 0
			return false
	}
	Generation := Captured.Get("generation", -1)
	return Captured["backend"] == "ollama" && Captured["origin"] != ""
		&& (Generation is Integer) && Generation >= 0
		&& (Live.Get("generation", -1) is Integer)
		&& Live.Get("generation", -1) == Generation
}
