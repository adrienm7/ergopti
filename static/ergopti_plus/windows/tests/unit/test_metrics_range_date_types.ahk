; tests/unit/test_metrics_range_date_types.ahk

; ==============================================================================
; MODULE: Metrics Range Date Type Tests
; DESCRIPTION: Invalid date shapes must preserve request identity without throwing.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRDT_Normalize(Field, Kind) {
	Payload := Map("request_id", 91, "start_date", "2026-01-01",
		"end_date", "2026-01-02", "apps", ["fixture.exe"])
	switch Kind {
		case "object": Payload[Field] := Map("unexpected", "synthetic")
		case "array": Payload[Field] := ["2026-01-01"]
		case "number": Payload[Field] := 20260101
		case "open": Payload[Field] := ""
		case "valid": ; Retain the valid bound.
	}
	Result := KLWV_NormalizeRangeRequest(KL_JsonEncode(Payload))
	AssertTrue(Result is Map)
	AssertEqual(91, Result["request_id"], "rejection must remain associated with its request")
	if Kind == "open" || Kind == "valid" {
		AssertTrue(Result["query"] is Map, "valid and open date bounds remain supported")
		AssertEqual(Payload[Field], Result["query"][Field])
		AssertEqual("fixture.exe", Result["query"]["apps"][1])
	} else {
		AssertEqual(0, Result["query"], "an invalid date type must not reach a worker")
	}
}

for Field in ["start_date", "end_date"]
	for Kind in ["object", "array", "number", "open", "valid"]
		Test("metrics range: " . Field . " type=" . Kind . " (metrics-range-date-types)",
			_MRDT_Normalize.Bind(Field, Kind))

_MRDT_Calendar(Day, Valid) {
	Payload := Map("request_id", 92, "start_date", Day, "end_date", Day, "apps", [])
	Result := KLWV_NormalizeRangeRequest(KL_JsonEncode(Payload))
	AssertEqual(92, Result["request_id"])
	AssertEqual(Valid, Result["query"] is Map,
		"range bounds must be real calendar days or the explicit open bound")
}

for Index, Spec in [["2024-02-29", true], ["2000-02-29", true], ["", true],
	["2026-02-29", false], ["2100-02-29", false], ["2026-04-31", false],
	["2026-00-10", false], ["2026-01-00", false], ["2026-13-01", false],
	["2026-01-01`n", false]]
	Test("metrics range: calendar case " . Index . " (metrics-range-calendar)",
		_MRDT_Calendar.Bind(Spec[1], Spec[2]))
