; tests/unit/test_metrics_range_json_equivalence.ahk

; ==============================================================================
; MODULE: Range JSON Equivalence Tests
; DESCRIPTION: Compare selected-range serializers across devices and calendar bounds.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRJE_Projection(Db) {
	AssertTrue(KLR_LoadSchema(Db))
	TokensPerCell := 8
	Tables := Map()
	for Code, Table in KLR_NGRAM_TYPE_TABLE
		Tables[Table] := "token"
	Tables["ngram_shortcuts"] := "token"
	Tables["ngram_shortcut_bigrams"] := "token"
	Tables["ngram_keycodes"] := "keycode"
	Tables["ngram_scancodes"] := "scancode"
	for Table, Key in Tables {
		AssertTrue(SQLite_Exec(Db, "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<" . TokensPerCell . ") "
			. "INSERT INTO " . Table . " (device_id,date,app," . Key . ",c) "
			. "SELECT d.id,day.value,a.name,n.x,1 FROM n "
			. "CROSS JOIN (SELECT 'one' AS id UNION ALL SELECT 'two') d "
			. "CROSS JOIN (SELECT '2030-01-01' AS value UNION ALL SELECT '2030-01-02' UNION ALL SELECT '2030-01-03') day "
			. "CROSS JOIN (SELECT 'editor.exe' AS name UNION ALL SELECT 'Unknown' UNION ALL SELECT 'excluded.exe') a;"))
	}
	for Bounds in [["", ""], ["2030-01-01", "2030-01-01"], ["2030-01-02", "2030-01-03"]] {
		Apps := ["editor.exe"]
		Legacy := KLR_ReadRangeSplitToday(Db, Bounds[1], Bounds[2], Apps, "2030-01-02")
		Encoded := JsonParse(KLR_BuildRangeSplitTodayJson(Db, Bounds[1], Bounds[2], Apps, "2030-01-02"))
		AssertEqual(_MMJ_Canonical(Legacy), _MMJ_Canonical(Encoded),
			"both complete serializers must retain the same device totals, app filters and split")
		AssertEqual(13, Encoded["historical"].Count)
		AssertEqual(2, Encoded["today"].Count, "selected app plus Unknown must survive; excluded app must not")
		for Code, Bucket in Encoded["historical"] {
			AssertEqual(Bounds[1] == "2030-01-02" ? 0 : TokensPerCell, Bucket.Count)
			for Token, Item in Bucket
				AssertEqual(4, Item["c"], "history sums two devices across selected and Unknown apps")
			for App in ["editor.exe", "Unknown"] {
				AssertEqual(TokensPerCell, Encoded["today"][App][Code].Count)
				for Token, Item in Encoded["today"][App][Code]
					AssertEqual(2, Item["c"], "today retains per-app totals across both devices")
			}
		}
	}
}

Test("metrics range JSON: device app and date boundaries agree (metrics-range-json-equivalence)",
	_SQLRD_WithDatabase.Bind(_MRJE_Projection))
