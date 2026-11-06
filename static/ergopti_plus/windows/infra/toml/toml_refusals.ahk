; infra/toml/toml_refusals.ahk

; ==============================================================================
; MODULE: Native TOML Session Refusals
; DESCRIPTION:
; Retains source refusals and incomplete native publication effects for one
; session. Shared pure reporting is available without loading the TOML parser.
; ==============================================================================

#Requires AutoHotkey v2.0

; Paths this session must not write, with the reason. The config migration
; registers a config.toml it could not version (a newer schema, a failed
; migration): the batch writer then refuses it in both modes, so neither a
; targeted save, a full save nor a transactional candidate can replace a file
; this build does not understand. Deliberately never lifted: a restart
; re-evaluates the file.
_TOML_WriteRefusals() {
	static Refusals := Map()
	return Refusals
}

_TOML_WriteRefusalKey(Path) {
	return StrLower(StrReplace(String(Path), "/", "\"))
}

TOML_RefuseWrites(Path, Reason) {
	if !(Path is String) || Path == "" || !(Reason is String) || Reason == ""
		throw ValueError("TOML_RefuseWrites needs a path and a reason")
	Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
	Previous := Refusals.Get(Key, "")
	if Previous is Object && Previous.HasOwnProp("partial") && Previous.partial
		Previous.reason := Reason
	else
		Refusals[Key] := Reason
}

; Why writes to Path are refused this session, or "".
TOML_WriteRefusal(Path) {
	Refusals := _TOML_WriteRefusals()
	Key := _TOML_WriteRefusalKey(Path)
	Value := Refusals.Get(Key, "")
	return Value is String ? Value : Value.reason
}

; A structured receipt records a session effect, never fresh write admission.
_TOML_RecordPartialPublication(Path, Publication) {
	if !(Publication is Object) || !Publication.renamed || Publication.durable
		throw ValueError("A partial TOML publication requires a real incomplete rename receipt.")
	Message := "a native publication in this session was not fully acknowledged; restart before further writes"
	_TOML_WriteRefusals()[_TOML_WriteRefusalKey(Path)] := {reason: Message, partial: true}
}

; Pure reporting query. A blocked retry did not perform another native rename.
_TOML_SessionHasPartialPublication(Path) {
	if !(Path is String) || Path == ""
		return false
	Value := _TOML_WriteRefusals().Get(_TOML_WriteRefusalKey(Path), "")
	return Value is Object && Value.HasOwnProp("partial") && Value.partial
}
