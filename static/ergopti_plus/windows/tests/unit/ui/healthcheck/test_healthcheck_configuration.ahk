; tests/unit/ui/healthcheck/test_healthcheck_configuration.ahk

; ==============================================================================
; MODULE: Diagnostics Configuration Reducer Tests (Windows / AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/healthcheck/configuration_vectors.json through
; HealthCheck_ConfigurationRows, the AHK port of healthcheck.configuration:
; booleans, numbers and manifest enum values are exact, every other string keeps
; only its length, every list only its item count, and a key the manifest does
; not declare never becomes a row. The macOS and Linux suites replay the same
; vectors through the Lua module.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCCfgT_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\healthcheck\configuration_vectors.json", "UTF-8"))
}

_HCCfgT_Vectors() {
	Corpus := _HCCfgT_Corpus()
	AssertTrue(Corpus["vectors"].Length >= 10, "the corpus must hold its vectors")
	for Vector in Corpus["vectors"] {
		Rows := HealthCheck_ConfigurationRows(Corpus["features"], TOML_ParseDocument(Vector["toml"]),
			Vector["driver"], 800)
		Expected := Vector["expected"]
		AssertEqual(Expected.Length, Rows.Length, Vector["id"] . ": row count")
		for Index, Row in Rows {
			for Key in ["setting", "type", "value"]
				AssertEqual(Expected[Index][Key], Row[Key], Vector["id"] . ": " . Key . " of row " . Index)
		}
		Encoded := ""
		for Row in Rows
			Encoded .= Row["setting"] . "=" . Row["value"] . "`n"
		for Canary in Corpus["canaries"]
			AssertFalse(InStr(Encoded, Canary), Vector["id"] . " leaked " . Canary)
	}
}
Test("diagnostics configuration: the shared vectors reduce identically (healthcheck-configuration-vectors)",
	_HCCfgT_Vectors)

_HCCfgT_Limit() {
	Corpus := _HCCfgT_Corpus()
	Document := TOML_ParseDocument('[script]`nlog_level = "INFO"`nshow_error_dialog = true`n`n[metrics]`nkeep_days = 3`n')
	AssertEqual(2, HealthCheck_ConfigurationRows(Corpus["features"], Document, "windows", 2).Length)
}
Test("diagnostics configuration: the row count is bounded (healthcheck-configuration-limit)", _HCCfgT_Limit)

_HCCfgT_UnknownDriver() {
	AssertThrows(HealthCheck_ConfigurationRows.Bind(_HCCfgT_Corpus()["features"], Map(), "beos", 10))
}
Test("diagnostics configuration: an unknown driver is refused (healthcheck-configuration-driver)", _HCCfgT_UnknownDriver)

; The closed sharing projection: a path, a sentence or a token cannot be shared
; whatever type a row claims (negative controls replayed by model.js and
; share.lua from the same file).
_HCCfgT_SharingControls() {
	global _SharedDir
	Controls := JsonParse(FileRead(_SharedDir . "\tests\corpus\healthcheck\configuration_share_vectors.json", "UTF-8"))
	Schema := HealthCheck_Config()["schema"]
	for Driver in ["windows", "macos", "linux"] {
		for Vector in Controls["vectors"] {
			Label := Driver . ": " . Vector["id"]
			Snapshot := Map("schema_version", 2, "driver", Driver, "generated_at", "2026-10-20T10:00:00Z",
				"detailed", 0, "extensive", 0, "sections", Map("configuration", Map("items", Vector["items"]),
					"configuration_files", Map("items", Controls["files"])))
			Document := HealthCheck_ShareDocument(Snapshot, Schema)
			Kept := Document["snapshot"]["sections"]["configuration"]["items"]
			AssertEqual(Vector["expected"].Length, Kept.Length, Label . ": kept rows")
			for Index, Row in Kept
				for Key in ["setting", "type", "value"]
					AssertEqual(Vector["expected"][Index][Key], Row[Key], Label . ": " . Key)
			Files := Document["snapshot"]["sections"]["configuration_files"]["items"]
			for Index, Row in Files
				for Key in ["id", "state"]
					AssertEqual(Controls["expected_files"][Index][Key], Row[Key], Label . ": file " . Key)
			for Canary in Controls["canaries"]
				AssertFalse(InStr(Document["text"], Canary), Label . " leaked " . Canary)
			for Row in Vector["expected"]
				AssertContains(Document["text"], "| " . Row["setting"] . " | " . Row["type"] . ": " . Row["value"] . " |")
		}
	}
}
Test("diagnostics configuration: sharing refuses paths, sentences and tokens (healthcheck-configuration-sharing)",
	_HCCfgT_SharingControls)

_HCCfgT_SharingBound() {
	Rows := []
	loop 801
		Rows.Push(Map("setting", "script.k" . A_Index, "type", "boolean", "value", "true"))
	Snapshot := Map("schema_version", 2, "driver", "windows", "generated_at", "2026-10-20T10:00:00Z",
		"detailed", 0, "extensive", 0, "sections", Map("configuration", Map("items", Rows)))
	Safe := HealthCheck_ShareSnapshot(Snapshot, HealthCheck_Config()["schema"])
	AssertEqual(800, Safe["sections"]["configuration"]["items"].Length)
}
Test("diagnostics configuration: shared rows are bounded (healthcheck-configuration-bound)", _HCCfgT_SharingBound)

_HCCfgT_EndToEnd() {
	Corpus := _HCCfgT_Corpus()
	Schema := HealthCheck_Config()["schema"]
	for Vector in Corpus["vectors"] {
		Rows := HealthCheck_ConfigurationRows(Corpus["features"], TOML_ParseDocument(Vector["toml"]), Vector["driver"], 800)
		Snapshot := Map("schema_version", 2, "driver", Vector["driver"], "generated_at", "2026-10-20T10:00:00Z",
			"detailed", 0, "extensive", 0, "sections", Map("configuration", Map("items", Rows)))
		Text := HealthCheck_ShareDocument(Snapshot, Schema)["text"]
		for Canary in Corpus["canaries"]
			AssertFalse(InStr(Text, Canary), Vector["id"] . " leaked " . Canary)
	}
}
Test("diagnostics configuration: a collected configuration shares no canary (healthcheck-configuration-end-to-end)",
	_HCCfgT_EndToEnd)

; Controlled fixtures: one folder holds an admitted config.toml, a layers.toml
; that is missing, a tap_hold.toml that is a folder (unreadable), and a variant
; with a config.toml that does not parse.
_HCCfgT_Fixture(ConfigText) {
	Root := A_Temp . "\ergopti_cfgdiag_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Root)
	DirCreate(Root . "\tap_hold.toml")
	if ConfigText != ""
		FileAppend(ConfigText, Root . "\config.toml", "UTF-8")
	return Root
}

_HCCfgT_FileStates() {
	Root := _HCCfgT_Fixture('[script]`nlog_level = "DEBUG"`nlocale = ' . Chr(39)
		. 'C:\Users\PRIVATE_USER_ZEBRA\notes' . Chr(39) . '`n')
	try {
		Schema := HealthCheck_Config()["schema"]
		Result := HealthCheck_CollectConfiguration(Schema, (Id) => Root . "\" . Id . ".toml")
		States := Map()
		for Item in Result["files"]["items"]
			States[Item["id"]] := Item["state"]
		AssertEqual("ok", States["defaults"])
		AssertEqual("ok", States["config"])
		AssertEqual("missing", States["layers"])
		AssertEqual("unreadable", States["tap_hold"])
		Ids := ""
		for Item in Result["files"]["items"]
			Ids .= Item["id"] . ","
		AssertEqual("defaults,config,layers,tap_hold,", Ids, "files are listed in the order they apply")
		Settings := Map()
		for Row in Result["settings"]["items"]
			Settings[Row["setting"]] := Row["type"] . ":" . Row["value"]
		AssertEqual("enum:DEBUG", Settings["script.log_level"])
		AssertEqual("text:33", Settings["script.locale"], "a path keeps only its length")
		AssertFalse(InStr(_HC_ValueToJson(Result), "PRIVATE_USER_ZEBRA"), "the collected sections carry no path")
	} finally {
		DirDelete(Root, true)
	}
}
Test("diagnostics configuration: file states and settings come from controlled fixtures (healthcheck-configuration-files)",
	_HCCfgT_FileStates)

_HCCfgT_InvalidAndMissingConfig() {
	Root := _HCCfgT_Fixture('[script`nlog_level = "DEBUG"`n')
	Empty := _HCCfgT_Fixture("")
	try {
		Schema := HealthCheck_Config()["schema"]
		Invalid := HealthCheck_CollectConfiguration(Schema, (Id) => Root . "\" . Id . ".toml")
		AssertEqual("invalid", Invalid["files"]["items"][2]["state"])
		AssertEqual(0, Invalid["settings"]["items"].Length, "an unparsable config yields no setting")
		Missing := HealthCheck_CollectConfiguration(Schema, (Id) => Empty . "\" . Id . ".toml")
		AssertEqual("missing", Missing["files"]["items"][2]["state"])
		AssertEqual(0, Missing["settings"]["items"].Length)
	} finally {
		DirDelete(Root, true)
		DirDelete(Empty, true)
	}
}
Test("diagnostics configuration: invalid and missing inputs are explicit (healthcheck-configuration-states)",
	_HCCfgT_InvalidAndMissingConfig)
