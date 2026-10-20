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

; The configuration is a probe, never phase A. The fixture is a slow reader: the
; driver's own config.toml made long enough that collecting it costs many
; times the phase A budget. Phase A, measured by the snapshot itself, must stay
; far below that cost, with the sections empty and the probe pending (a
; regression that collects it synchronously again pays the whole read).
_HCCfgT_PhaseANeverReads() {
	global _ConfigDir, _AhkSubDir
	SavedDir := _ConfigDir, SavedSub := _AhkSubDir
	Schema := HealthCheck_Config()["schema"]
	Budget := Schema["phase_a_budget_ms"]
	Root := A_Temp . "\cfgdiag_phase_a_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Root . "\autohotkey")
	Text := ""
	loop 1000
		Text .= "[s" . A_Index . "]`nk = " . Chr(34) . "x" . Chr(34) . "`n"
	FileAppend(Text, Root . "\autohotkey\config.toml", "UTF-8")
	try {
		_ConfigDir := Root . "\", _AhkSubDir := "autohotkey\"
		Started := _HealthCheck_NowMs()
		Collected := HealthCheck_CollectConfiguration(Schema)
		ReadMs := _HealthCheck_NowMs() - Started
		AssertEqual("ok", Collected["files"]["items"][2]["state"], "the slow fixture is the config.toml read")
		AssertTrue(ReadMs > 20 * Budget, "the fixture must cost many phase A budgets to read, not " . ReadMs . " ms")
		Snapshot := HealthCheck_Run()
		PhaseA := Snapshot["sections"]["developer"]["phase_a_ms"]
		AssertTrue(PhaseA < ReadMs / 2,
			"phase A took " . PhaseA . " ms against a " . Round(ReadMs) . " ms read: the configuration was read synchronously")
		AssertEqual(0, Snapshot["sections"]["configuration"]["items"].Length)
		AssertEqual(0, Snapshot["sections"]["configuration_files"]["items"].Length)
		AssertEqual("pending", Snapshot["probes"]["configuration"]["state"])
		AssertEqual("not_run", Snapshot["probes"]["github_api"]["state"])
	} finally {
		_ConfigDir := SavedDir, _AhkSubDir := SavedSub
		DirDelete(Root, true)
	}
}
Test("diagnostics configuration: phase A never reads the configuration (healthcheck-configuration-phase-a)",
	_HCCfgT_PhaseANeverReads)

_HCCfgT_PendingProbes() {
	Schema := HealthCheck_Config()["schema"]
	Quick := _HealthCheck_PendingProbes(Schema, 0)
	AssertEqual("pending", Quick["configuration"]["state"], "a local probe needs no opt-in")
	for Id, Result in Quick {
		if Id != "configuration"
			AssertEqual("not_run", Result["state"], Id . " stays opt-in")
	}
	for Id, Result in _HealthCheck_PendingProbes(Schema, 1)
		AssertEqual("pending", Result["state"], Id)
}
Test("diagnostics configuration: only the local probe is pending without the opt-in (healthcheck-configuration-not-run)",
	_HCCfgT_PendingProbes)

_HCCfgT_ProbeDeadline() {
	Schema := HealthCheck_Config()["schema"]
	Deadline := Schema["probes"]["configuration"]["timeout_ms"]
	Root := _HCCfgT_Fixture('[script]`nlog_level = "INFO"`n')
	try {
		PathOf := (Id) => Root . "\" . Id . ".toml"
		Fast := 0
		FastClock := () => (Fast += 10)
		Ok := HealthCheck_ConfigurationProbe(Schema, Map("path_of", PathOf, "clock", FastClock))
		AssertEqual("ok", Ok["result"]["state"])
		AssertEqual("settled", Ok["result"]["cleanup"])
		AssertEqual(10, Ok["result"]["ms"])
		AssertEqual(2, Ok["sections"].Count, "both sections are filled")
		Slow := 0
		SlowClock := () => (Slow += Deadline + 1)
		Late := HealthCheck_ConfigurationProbe(Schema, Map("path_of", PathOf, "clock", SlowClock))
		AssertEqual("timeout", Late["result"]["state"])
		AssertEqual("deadline_expired", Late["result"]["detail"])
		AssertEqual("settled", Late["result"]["cleanup"])
		AssertEqual(0, Late["sections"].Count, "a late answer must not fill the sections")
	} finally {
		DirDelete(Root, true)
	}
}
Test("diagnostics configuration: an answer past the deadline is a timeout without sections (healthcheck-configuration-timeout)",
	_HCCfgT_ProbeDeadline)

; A reader whose disk fails on every file.
_HCCfgT_BrokenReader(Id) {
	throw Error("disk on fire")
}

_HCCfgT_CompleteStates() {
	Schema := HealthCheck_Config()["schema"]
	Root := _HCCfgT_Fixture('[script]`nlog_level = "INFO"`n')
	try {
		Snapshot := Map("probes", Map("configuration", Map("state", "pending")),
			"sections", Map("configuration_files", Map("items", []), "configuration", Map("items", [])))
		AssertTrue(HealthCheck_CompleteConfiguration(Snapshot, Schema, Map("path_of", (Id) => Root . "\" . Id . ".toml")))
		AssertEqual("ok", Snapshot["probes"]["configuration"]["state"])
		AssertEqual(1, Snapshot["sections"]["configuration"]["items"].Length)
		Broken := Map("probes", Map("configuration", Map("state", "pending")),
			"sections", Map("configuration_files", Map("items", []), "configuration", Map("items", [])))
		AssertFalse(HealthCheck_CompleteConfiguration(Broken, Schema, Map("path_of", _HCCfgT_BrokenReader)))
		AssertEqual("error", Broken["probes"]["configuration"]["state"], "a failing reader is an error, never an empty success")
		AssertEqual(0, Broken["sections"]["configuration"]["items"].Length)
	} finally {
		DirDelete(Root, true)
	}
}
Test("diagnostics configuration: a completed report names ok and error explicitly (healthcheck-configuration-complete)",
	_HCCfgT_CompleteStates)

; The probe runs on a timer after the caller returned, alone when local-only.
_HCCfgT_LocalProbeRun() {
	Schema := HealthCheck_Config()["schema"]
	Root := _HCCfgT_Fixture('[script]`nlog_level = "INFO"`n')
	Published := []
	Publish := (Epoch, Id, Result, Sections) => Published.Push(Map("id", Id, "result", Result, "sections", Sections))
	try {
		HealthCheck_StartProbes(1, Schema, Publish, true, Map("path_of", (Id) => Root . "\" . Id . ".toml"))
		AssertEqual(0, Published.Length, "nothing is published before the timer runs")
		Waited := 0
		while Published.Length < 1 && Waited < 3000 {
			Sleep(25)
			Waited += 25
		}
		Sleep(200)
		AssertEqual(1, Published.Length, "only the local probe answers")
		AssertEqual("configuration", Published[1]["id"])
		AssertEqual("ok", Published[1]["result"]["state"])
		AssertEqual(1, Published[1]["sections"]["configuration"]["items"].Length)
		; A cancelled run publishes nothing
		Published := []
		Publish := (Epoch, Id, Result, Sections) => Published.Push(Map("id", Id))
		HealthCheck_StartProbes(2, Schema, Publish, true, Map("path_of", (Id) => Root . "\" . Id . ".toml"))
		HealthCheck_CancelProbes()
		Sleep(300)
		AssertEqual(0, Published.Length, "a cancelled run publishes nothing")
	} finally {
		HealthCheck_CancelProbes()
		DirDelete(Root, true)
	}
}
Test("diagnostics configuration: the local probe answers alone on a timer and honours cancel (healthcheck-configuration-probe-run)",
	_HCCfgT_LocalProbeRun)
