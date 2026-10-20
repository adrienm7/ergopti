; ui/healthcheck/configuration.ahk

; ==============================================================================
; MODULE: Healthcheck / Configuration Reducer
; DESCRIPTION:
; AHK port of _shared/lua/healthcheck/configuration.lua: turns the user's typed
; config.toml document into the closed rows of the diagnostics `configuration`
; section. Only manifest-declared settings are read, so a key the user invented
; never becomes a row.
;
; FEATURES & RATIONALE:
; 1. Booleans, numbers and manifest enum values are reported exactly.
; 2. Every other string is reduced to its length in characters, and every array
;    to its item count: a path or a sentence typed into a text setting cannot
;    leave the machine through this section.
; 3. Both ports replay
;    _shared/tests/corpus/healthcheck/configuration_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Value Reduction =======
; ==================================
; ==================================

; Counts Unicode characters: a surrogate pair is one character, not two units.
; @param Text {String}
; @returns {Integer}
_HCConfig_CharacterCount(Text) {
	Count := 0
	loop parse Text {
		Unit := Ord(A_LoopField)
		if Unit < 0xDC00 || Unit > 0xDFFF
			Count += 1
	}
	return Count
}

; Renders a number like the Lua port: an integer without a fraction, anything
; else with 14 significant digits.
; @param Value {Integer|Float}
; @returns {String} Empty for NaN and infinities.
_HCConfig_NumberText(Value) {
	if Value is Integer
		return String(Value)
	if Value != Value || Abs(Value) > 1.7e308
		return ""
	if Value == Floor(Value) && Abs(Value) < 1e15
		return String(Integer(Value))
	return RegExReplace(Format("{:.14g}", Value), "e([+-])0*(\d)", "e$1$2")
}

; Walks a dotted path through nested semantic tables.
; @param Document {Map}
; @param Path {String}
; @returns {Map} found plus value.
_HCConfig_Lookup(Document, Path) {
	Node := Document
	for Segment in StrSplit(Path, ".") {
		if !(Node is Map) || !Node.Has(Segment)
			return Map("found", false)
		Node := Node[Segment]
	}
	return Map("found", true, "value", Node)
}

; Reduces one decoded value to a row, or 0 when it is not a reportable leaf.
; @param Path {String}
; @param Value {Any}
; @param EnumValues {Array|0} The manifest enum, when the setting is one.
; @returns {Map|0}
_HCConfig_Reduce(Path, Value, EnumValues) {
	if Value is TOML_Bool
		return Map("setting", Path, "type", "boolean", "value", Value.Value ? "true" : "false")
	if Value is Integer || Value is Float {
		Text := _HCConfig_NumberText(Value)
		return Text == "" ? 0 : Map("setting", Path, "type", "number", "value", Text)
	}
	if Value is String {
		if EnumValues is Array {
			for Accepted in EnumValues
				if StrCompare(Value, Accepted, true) == 0
					return Map("setting", Path, "type", "enum", "value", Value)
		}
		return Map("setting", Path, "type", "text", "value", String(_HCConfig_CharacterCount(Value)))
	}
	if Value is Array
		return Map("setting", Path, "type", "list", "value", String(Value.Length))
	return 0
}





; ===============================
; ===============================
; ======= 2/ Row Building =======
; ===============================
; ===============================

; The reportable rows of a configuration document.
; @param Features {Array} Manifest entries: path, default, platforms, enum_values.
; @param Document {Map} Typed config.toml document.
; @param Driver {String} windows, macos or linux.
; @param Limit {Integer} Most rows to return.
; @returns {Array} Rows sorted by setting.
HealthCheck_ConfigurationRows(Features, Document, Driver, Limit) {
	Platforms := Map("windows", "ahk", "macos", "hs", "linux", "linux")
	if !Platforms.Has(Driver)
		throw ValueError("Unknown diagnostics driver: " . Driver)
	Token := Platforms[Driver]
	Rows := Map()
	Add(Path, Value, EnumValues) {
		Row := _HCConfig_Reduce(Path, Value, EnumValues)
		if Row is Map
			Rows[Path] := Row
	}
	for Feature in Features {
		Applies := false
		for Candidate in Feature["platforms"]
			if Candidate == Token
				Applies := true
		if !Applies
			continue
		if Feature["default"] is Map {
			for Key in Feature["default"] {
				Path := Feature["path"] . "." . Key
				Found := _HCConfig_Lookup(Document, Path)
				if Found["found"]
					Add(Path, Found["value"], 0)
			}
		} else {
			Found := _HCConfig_Lookup(Document, Feature["path"])
			if Found["found"]
				Add(Feature["path"], Found["value"], Feature.Get("enum_values", 0))
		}
	}
	Keys := ""
	for Path in Rows
		Keys .= Path . "`n"
	Sorted := []
	for Path in StrSplit(RTrim(Sort(Keys, "C"), "`n"), "`n") {
		if Path == "" || Sorted.Length >= Limit
			continue
		Sorted.Push(Rows[Path])
	}
	return Sorted
}
