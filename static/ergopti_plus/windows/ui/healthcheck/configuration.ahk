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
; 1. Booleans, numbers and manifest enum values are reported exactly; an enum
;    row is only a declared string member, compared exactly.
; 2. Every other string is reduced to its length in characters, and every array
;    to its item count: a path or a sentence typed into a text setting cannot
;    leave the machine through this section.
; 3. Both ports replay
;    _shared/tests/corpus/healthcheck/configuration_vectors.json.
; 4. HealthCheck_ConfigurationFiles and HealthCheck_CollectConfiguration report
;    the state of each configuration file in the order they apply: ok, missing,
;    unreadable or invalid. A file that cannot be read is named, never skipped,
;    and nothing is cached or written.
; 5. HealthCheck_ConfigurationProbe runs that collection as the local
;    `configuration` probe of the schema, against its deadline: phase A only
;    publishes empty sections and a pending probe. Flows without a page (the
;    Debug menu's report, the native fallback window) call
;    HealthCheck_CompleteConfiguration instead.
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
		; Only a declared string member, compared exactly: an enum may also
		; declare booleans, which the manifest holds as 1 and 0, and a typed
		; "1" is not one of them
		if EnumValues is Array {
			for Accepted in EnumValues
				if Accepted is String && StrCompare(Value, Accepted, true) == 0
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





; ==============================
; ==============================
; ======= 3/ File States =======
; ==============================
; ==============================

; Where each configuration file lives on this driver.
; @param Id {String} A file id of the schema's configuration.files.
; @returns {String}
_HCConfig_PathOf(Id) {
	global _ConfigDir, _AhkSubDir
	Names := HealthCheck_Config()["schema"]["configuration"]["file_names"]
	if !Names.Has(Id)
		throw ValueError("Unknown configuration file: " . Id)
	; The driver keeps its own settings in a subfolder; the layers file is shared
	; between drivers and sits in the configuration folder itself.
	return _ConfigDir . (Id == "layers" ? "" : _AhkSubDir) . Names[Id]
}

; Reads the configuration files in the order they apply and reports each state:
; ok, missing, unreadable (a folder, a lock, a bad encoding) or invalid (the
; config.toml that does not parse). Nothing is cached or written.
; @param Ids {Array} File ids, defaults first.
; @param PathOf {Func} Maps an id to its path.
; @returns {Map} items (rows {id, state}) and document (typed config.toml or 0).
HealthCheck_ConfigurationFiles(Ids, PathOf) {
	Items := [], Document := 0
	for Id in Ids {
		State := "ok"
		if Id != "defaults" {
			Path := PathOf.Call(Id)
			Attributes := FileExist(Path)
			if Attributes == "" {
				State := "missing"
			} else if InStr(Attributes, "D") {
				State := "unreadable"
			} else {
				try {
					; config.toml must match the runtime's exact UTF-8 admission:
					; the general reader repairs malformed bytes and accepts native BOMs.
					Content := Id == "config" ? FSReadUtf8Exact(Path) : FSReadStrict(Path)
					if !(Content is String)
						State := "unreadable"
				} catch {
					Content := false
					State := "unreadable"
				}
				if Content is String && Id == "config" {
					try {
						Document := TOML_ParseDocument(Content)
					} catch {
						State := "invalid"
					}
				}
			}
		}
		Items.Push(Map("id", Id, "state", State))
	}
	return Map("items", Items, "document", Document)
}

; Collects both configuration sections of the snapshot.
; @param Schema {Map} The diagnostics schema.
; @param PathOf {Func} Maps a file id to its path.
; @returns {Map} files and settings, each a Map with its items.
HealthCheck_CollectConfiguration(Schema, PathOf := _HCConfig_PathOf) {
	global FEATURES_MANIFEST
	Spec := Schema["configuration"]
	Read := HealthCheck_ConfigurationFiles(Spec["files"]["windows"], PathOf)
	Rows := Read["document"] is Map
		? HealthCheck_ConfigurationRows(FEATURES_MANIFEST["features"], Read["document"], "windows", Spec["max_rows"])
		: []
	return Map("files", Map("items", Read["items"]), "settings", Map("items", Rows))
}





; ============================
; ============================
; ======= 4/ The Probe =======
; ============================
; ============================

; One collection against the probe's deadline. An answer later than the probe's
; timeout_ms is discarded as a timeout, so a slow disk is reported, never
; silently waited for or half published.
; @param Schema {Map} The diagnostics schema.
; @param Overrides {Map|Integer} Replacements for tests: path_of, clock.
; @returns {Map} result ({ state, cleanup, ms, detail? }) and sections.
HealthCheck_ConfigurationProbe(Schema, Overrides := 0) {
	PathOf := (Overrides is Map && Overrides.Has("path_of")) ? Overrides["path_of"] : _HCConfig_PathOf
	Clock := (Overrides is Map && Overrides.Has("clock")) ? Overrides["clock"] : _HealthCheck_NowMs
	Started := Clock.Call()
	Collected := HealthCheck_CollectConfiguration(Schema, PathOf)
	Elapsed := Clock.Call() - Started
	Ms := Round(Elapsed)
	if Elapsed > Schema["probes"]["configuration"]["timeout_ms"]
		return Map("result", Map("state", "timeout", "detail", "deadline_expired", "cleanup", "settled", "ms", Ms),
			"sections", Map())
	return Map("result", Map("state", "ok", "cleanup", "settled", "ms", Ms),
		"sections", Map("configuration_files", Collected["files"], "configuration", Collected["settings"]))
}

; Completes a snapshot's configuration sections at once, for the flows that have
; no page to keep responsive (a report from the Debug menu). A collection that
; raises leaves the sections empty and the probe in the error state.
; @param Snapshot {Map} A phase A snapshot.
; @param Schema {Map} The diagnostics schema.
; @param Overrides {Map|Integer} See HealthCheck_ConfigurationProbe.
; @returns {Boolean} Whether the collection answered.
HealthCheck_CompleteConfiguration(Snapshot, Schema, Overrides := 0) {
	try {
		Answer := HealthCheck_ConfigurationProbe(Schema, Overrides)
	} catch as Err {
		LoggerError("Healthcheck", "The configuration could not be collected: {1}", Err.Message)
		Snapshot["probes"]["configuration"] := Map("state", "error", "cleanup", "settled", "ms", 0)
		return false
	}
	Snapshot["probes"]["configuration"] := Answer["result"]
	for Id, Values in Answer["sections"]
		Snapshot["sections"][Id] := Values
	return Answer["result"]["state"] == "ok"
}
