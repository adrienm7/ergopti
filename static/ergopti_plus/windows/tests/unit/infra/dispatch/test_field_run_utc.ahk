; tests/unit/infra/dispatch/test_field_run_utc.ahk

; Field-run documents must not combine the date and time from different instants.
#Requires AutoHotkey v2.0

_FRU_OneUtcRead() {
	Body := _DriverFuncBody("_FieldRun_IsoNow")
	AssertEqual(1, StrSplit(Body, "A_NowUTC").Length - 1, "exactly one OS clock read")
	Assert(RegExMatch(Body, 'NowUtc\s*:=\s*A_NowUTC'), "the instant is captured before formatting")
	Assert(RegExMatch(Body, 'FormatTime\(\s*NowUtc\s*,\s*"yyyy-MM-dd"'), "date uses that instant")
	Assert(RegExMatch(Body, 'FormatTime\(\s*NowUtc\s*,\s*"HH:mm:ss"'), "time uses that instant")
}
Test("field run: one UTC instant supplies both timestamp fields (field-run-utc-snapshot)", _FRU_OneUtcRead)

_FRU_Boundaries() {
	for Vector in [
		["20261104235959", "2026-11-04T23:59:59Z"],
		["20261105000000", "2026-11-05T00:00:00Z"],
		["20240229235959", "2024-02-29T23:59:59Z"],
		["20250101000000", "2025-01-01T00:00:00Z"]
	] {
		AssertEqual(Vector[2], _FieldRun_IsoNow(Vector[1]), "the entire UTC document timestamp uses one supplied instant")
	}
}
Test("field run: UTC formatting preserves midnight and leap-day boundaries (field-run-utc-boundaries)", _FRU_Boundaries)
