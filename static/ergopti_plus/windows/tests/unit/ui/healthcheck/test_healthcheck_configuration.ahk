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
