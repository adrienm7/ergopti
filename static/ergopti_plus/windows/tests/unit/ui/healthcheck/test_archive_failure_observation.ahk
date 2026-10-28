; tests/unit/ui/healthcheck/test_archive_failure_observation.ahk
;
; ==============================================================================
; MODULE: Diagnostic Archive Failure Observation Tests
; DESCRIPTION:
; Actual private receipts identify an owned native failure and refuse foreign
; or malformed evidence without suppressing the original archive assertion.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../fixtures/diagnostics_archive_observation.ahk

_HC_TestArchiveObservationCase(Mode) {
	global _SharedDir
	static Serial := 0
	Directory := A_Temp . "\ergopti_archive_observation_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Directory)
	Owner := {Id: "private-archive-observation", Directory: Directory, Archive: Directory . "\report.zip",
		Result: Map("phase", "failed", "archive_created", false),
		Contract: JsonParse(FSReadStrict(_SharedDir . "\modules\diagnostics\collection.json"))}
	try {
		if Mode != "absent" {
			Text := Mode == "malformed" ? "{" : _HC_ValueToJson(Map("schema_version", 1,
				"session_id", Mode == "foreign" ? "different-private-session" : Mode == "case-foreign" ? StrUpper(Owner.Id) : Owner.Id,
				"reason", "archive_creation_failed", "error_code", -2147024891, "partial_retained", true))
			AssertTrue(FSWriteCreateDurable(Directory . "\archive-error.json", Text))
		}
		Observed := JsonParse(_HC_TestArchiveObservation(Owner))
		AssertEqual("failed", Observed["phase"])
		AssertEqual(0, Observed["archive_created"])
		AssertEqual(0, Observed["archive_exists"])
		AssertEqual(0, Observed["digest_retained"])
		Expected := Mode == "owned" ? "owned" : (Mode == "foreign" || Mode == "case-foreign") ? "foreign_or_invalid" : Mode == "malformed" ? "unreadable" : "absent"
		AssertEqual(Expected, Observed["archive_error_state"])
		if Mode == "owned" {
			AssertEqual("archive_creation_failed", Observed["reason"])
			AssertEqual(-2147024891, Observed["error_code"])
			AssertEqual(1, Observed["partial_retained"])
		} else
			AssertFalse(Observed.Has("error_code"), "unadmitted evidence cannot impersonate a native failure")
	} finally DirDelete(Directory, true)
}
for _HC_ArchiveObservationMode in ["absent", "owned", "foreign", "case-foreign", "malformed"]
	Test("Diagnostic archive failure observation: " . _HC_ArchiveObservationMode . " (archive-failure-observation)",
		_HC_TestArchiveObservationCase.Bind(_HC_ArchiveObservationMode))
