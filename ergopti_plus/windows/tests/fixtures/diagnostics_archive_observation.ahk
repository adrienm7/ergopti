; tests/fixtures/diagnostics_archive_observation.ahk
;
; ==============================================================================
; MODULE: Diagnostic Archive Failure Observation
; DESCRIPTION:
; Reports bounded native archive state when a component assertion fails.
; Foreign or unreadable error receipts never replace the original failure.
; ==============================================================================

#Requires AutoHotkey v2.0

_HC_TestArchiveObservation(Owner) {
	Observation := Map("phase", Owner.Result["phase"], "archive_created", Owner.Result["archive_created"],
		"archive_exists", !!FileExist(Owner.Archive), "digest_retained", Owner.HasProp("ArchiveDigest"),
		"archive_error_state", "absent")
	Path := Owner.Directory . "\archive-error.json"
	if FileExist(Path) {
		try {
			if FileGetSize(Path) > Owner.Contract["max_output_bytes"]
				throw Error("Archive error receipt exceeded its admitted output bound.")
			Receipt := JsonParse(FSReadStrict(Path))
			if !(Receipt is Map) || !(Receipt.Get("session_id", "") == Owner.Id) {
				Observation["archive_error_state"] := "foreign_or_invalid"
			} else {
				Observation["archive_error_state"] := "owned"
				for Key in ["reason", "error_code", "partial_retained"]
					if Receipt.Has(Key)
						Observation[Key] := Receipt[Key]
			}
		} catch as ReceiptError {
			Observation["archive_error_state"] := "unreadable"
			Observation["receipt_failure"] := ReceiptError.Message
		}
	}
	return _HC_ValueToJson(Observation)
}
