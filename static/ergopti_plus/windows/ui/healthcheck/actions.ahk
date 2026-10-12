; ui/healthcheck/actions.ahk

; ==============================================================================
; MODULE: Healthcheck / Page Actions
; DESCRIPTION:
; AHK port of _shared/lua/healthcheck/actions.lua: validates what the
; diagnostics page asks the host to do before the host does it. The page is a
; web page, so a message is untrusted input; the host never opens a path, a URL
; or a file name it did not produce or allow itself.
;
; FEATURES & RATIONALE:
; 1. Ids, never paths or URLs: open_path names a path field of the schema and
;    the host opens the value it collected; open_settings names a permission
;    whose settings page the schema declares for this driver.
; 2. Bounded text: a copied, saved or reported text is a non-empty string of
;    at most max_export_bytes UTF-8 bytes.
; 3. A saved file keeps the report's prefix and suffix and only file-name-safe
;    characters, so it cannot leave the diagnostics folder.
; 4. A report prefills only the fields of the bug form, except its
;    report_field: the host fills that one with the report text itself.
; 5. Both ports replay _shared/tests/corpus/healthcheck/action_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Allowed Values =======
; =================================
; =================================

; True when a value is a string of 1..Max UTF-8 bytes.
; @param Value {Any}
; @param Max {Integer}
; @returns {Boolean}
_HCActions_BoundedText(Value, Max) {
	if !(Value is String) || (Value == "")
		return false
	return (StrPut(Value, "UTF-8") - 1) <= Max
}

; The ids of the schema's path fields that apply to a driver.
; @param Schema {Map}
; @param Driver {String}
; @returns {Map} Set of ids.
_HCActions_PathIds(Schema, Driver) {
	Ids := Map()
	for Section in Schema.Get("sections", []) {
		for Field in Section.Get("fields", []) {
			Applies := !Field.Has("platforms")
			if !Applies {
				for Platform in Field["platforms"]
					if (Platform == Driver)
						Applies := true
			}
			if (Field["type"] == "path" && Applies)
				Ids[Field["id"]] := true
		}
	}
	return Ids
}

; True when a report file name keeps the schema's prefix and suffix and only
; file-name-safe characters in between.
; @param Name {Any}
; @param Report {Map} schema.report
; @returns {Boolean}
_HCActions_ValidName(Name, Report) {
	if !(Name is String) || StrLen(Name) > Report["name_max_length"]
		return false
	Prefix := Report["name_prefix"]
	Suffix := Report["name_suffix"]
	if StrLen(Name) <= StrLen(Prefix) + StrLen(Suffix)
		return false
	if (SubStr(Name, 1, StrLen(Prefix)) !== Prefix) || (SubStr(Name, -StrLen(Suffix)) !== Suffix)
		return false
	Body := SubStr(Name, StrLen(Prefix) + 1, StrLen(Name) - StrLen(Prefix) - StrLen(Suffix))
	return RegExMatch(Body, "^[A-Za-z0-9._-]+$") > 0
}

; A refusal with its stable reason code.
; @param Reason {String}
; @returns {Map}
_HCActions_Refuse(Reason) {
	return Map("reason", Reason)
}





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

; Validates one message of the diagnostics page.
; @param Message {Any} The parsed message.
; @param Context {Map} { schema, templates, driver }: the parsed schema.json and
;   issue_templates.json, and this driver's id.
; @returns {Map} { action: Map } for an accepted action, { reason: String } for
;   a refusal.
HealthCheck_ValidateAction(Message, Context) {
	if !(Message is Map)
		return _HCActions_Refuse("not_a_message")
	Action := Message.Get("action", "")
	if !(Action is String)
		return _HCActions_Refuse("unknown_action")
	Schema := Context["schema"]
	Limit := Schema["max_export_bytes"]
	switch Action, true {
		case "copy":
			if !_HCActions_BoundedText(Message.Get("text", ""), Limit)
				return _HCActions_Refuse("bad_text")
			return Map("action", Map("action", "copy", "text", Message["text"]))
		case "save":
			if !_HCActions_BoundedText(Message.Get("text", ""), Limit)
				return _HCActions_Refuse("bad_text")
			if !_HCActions_ValidName(Message.Get("name", ""), Schema["report"])
				return _HCActions_Refuse("bad_name")
			return Map("action", Map("action", "save", "text", Message["text"], "name", Message["name"]))
		case "report":
			if !_HCActions_BoundedText(Message.Get("text", ""), Limit)
				return _HCActions_Refuse("bad_text")
			Given := Message.Get("fields", "")
			if !(Given is Map)
				return _HCActions_Refuse("bad_fields")
			Bug := Context["templates"]["templates"]["bug"]
			Allowed := Map()
			for Id in Bug["fields"]
				Allowed[Id] := true
			; The host fills the report field with the text itself
			Allowed.Delete(Bug["report_field"])
			Fields := Map()
			for Id, Value in Given {
				if !Allowed.Has(Id)
					return _HCActions_Refuse("unknown_field")
				if !_HCActions_BoundedText(Value, Limit)
					return _HCActions_Refuse("bad_fields")
				Fields[Id] := Value
			}
			return Map("action", Map("action", "report", "text", Message["text"], "fields", Fields))
		case "open_path":
			Id := Message.Get("id", "")
			if !(Id is String) || !_HCActions_PathIds(Schema, Context["driver"]).Has(Id)
				return _HCActions_Refuse("unknown_path")
			return Map("action", Map("action", "open_path", "id", Id))
		case "open_settings":
			Id := Message.Get("id", "")
			Permissions := Schema.Has("permissions") ? Schema["permissions"].Get(Context["driver"], Map()) : Map()
			Entry := (Id is String) ? Permissions.Get(Id, "") : ""
			if !(Entry is Map) || !Entry.Has("settings") || !(Entry["settings"] is String)
				return _HCActions_Refuse("unknown_settings")
			return Map("action", Map("action", "open_settings", "id", Id, "url", Entry["settings"]))
		case "refresh":
			; The AHK JSON reader turns true and false into 1 and 0
			Detailed := Message.Get("detailed", false)
			if !(Detailed is Integer) || (Detailed != 0 && Detailed != 1)
				return _HCActions_Refuse("bad_detailed")
			Extensive := Message.Get("extensive", false)
			if !(Extensive is Integer) || (Extensive != 0 && Extensive != 1)
				return _HCActions_Refuse("bad_extensive")
			return Map("action", Map("action", "refresh", "detailed", Detailed = 1, "extensive", Extensive = 1))
		case "export_snapshot":
			ExportSequence := Message.Get("export_sequence", 0)
			if !(ExportSequence is Integer) || ExportSequence <= 0 || ExportSequence > Schema["report"]["export_sequence_max"]
				return _HCActions_Refuse("bad_export_sequence")
			Normalized := Map("action", "export_snapshot", "export_sequence", ExportSequence)
			if Message.Has("page_checks") {
				Observations := HealthCheck_PageChecks(Message["page_checks"], Schema)
				if !(Observations is Map)
					return _HCActions_Refuse("bad_page_checks")
				Revision := Message.Get("snapshot_revision", 0)
				if !_HCActions_BoundedText(Message.Get("generated_at", ""), 40) || !(Revision is Integer)
					|| Revision <= 0 || Revision > Schema["report"]["export_sequence_max"]
					return _HCActions_Refuse("bad_snapshot_identity")
				Normalized["generated_at"] := Message["generated_at"]
				Normalized["snapshot_revision"] := Revision
				Normalized["page_check_observations"] := Observations
			}
			return Map("action", Normalized)
		case "cancel":
			return Map("action", Map("action", "cancel"))
		case "close":
			return Map("action", Map("action", "close"))
	}
	return _HCActions_Refuse("unknown_action")
}
