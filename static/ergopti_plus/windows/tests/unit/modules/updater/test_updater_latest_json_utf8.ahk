; tests/unit/modules/updater/test_updater_latest_json_utf8.ahk

; ==============================================================================
; MODULE: Latest Release Managed JSON Encoding Tests
; DESCRIPTION:
; Call the public latest-release fetch through original-byte managed receipts
; and verify both the selected JSON and the native conditional cache admission.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../fixtures/updater_managed_json_harvest.ahk

_ULJ_Fetch(*) {
	return Updater_FetchLatestJson("main")
}

for Mode in ["invalid", "valid", "replacement"]
	Test("updater JSON encoding: latest-sync " . Mode . " (updater-latest-json-utf8)",
		_UGH_Case.Bind("latest-sync", _ULJ_Fetch, false, true, Mode))
