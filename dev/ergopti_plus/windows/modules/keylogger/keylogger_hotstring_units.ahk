; modules/keylogger/keylogger_hotstring_units.ahk

; ==============================================================================
; MODULE: Hotstring Count Unit Receipts
; DESCRIPTION: Preserve declared Windows accounting through redaction and mixed-device replay.
; ==============================================================================

#Requires AutoHotkey v2.0

class KLHotstringUnitError extends Error {
}

class KLHotstringUnits {
	static Prefix := "hotstring_count_unit:"
	static WindowsUnit := "utf16"

	; DeviceSql is the producer's already-quoted, validated device identity.
	static DeclarationSql(DeviceSql) {
		return "INSERT OR IGNORE INTO meta(key,value) VALUES('" . this.Prefix . "'||"
			. DeviceSql . ",'" . this.WindowsUnit . "');"
	}

	static Read(Db) {
		Units := Map()
		Units.CaseSense := "On"
		for Row in SQLite_Query(Db, "SELECT key,value FROM meta WHERE substr(key,1,"
			. StrLen(this.Prefix) . ")=" . SQLite_Q(this.Prefix) . ";") {
			Device := SubStr(Row["key"], StrLen(this.Prefix) + 1)
			if Device = "" || Row["value"] !== this.WindowsUnit
				throw KLHotstringUnitError("Unsupported hotstring count unit declaration.")
			Units[Device] := Row["value"]
		}
		return Units
	}

	static InputSql(Column, DeviceColumn) {
		Text := "COALESCE(" . Column . ",'')"
		Bytes := "CAST(" . Text . " AS BLOB)"
		Remaining := Bytes
		; Valid UTF-8 has one F0..F4 leading byte per supplementary scalar.
		; Removing those bytes adds exactly the extra UTF-16 code units.
		for Leader in ["F0", "F1", "F2", "F3", "F4"]
			Remaining := "REPLACE(" . Remaining . ",x'" . Leader . "',x'')"
		Utf16 := "LENGTH(" . Text . ")+LENGTH(" . Bytes . ")-LENGTH(CAST(" . Remaining . " AS BLOB))"
		return "CASE WHEN EXISTS(SELECT 1 FROM meta AS units WHERE units.key="
			. SQLite_Q(this.Prefix) . "||" . DeviceColumn . " AND units.value="
			. SQLite_Q(this.WindowsUnit) . ") THEN " . Utf16 . " ELSE LENGTH(" . Text . ") END"
	}
}

KLR_RebuildHotstringCounts(Db, Dates := 0, Device := unset) {
	Input := KLHotstringUnits.InputSql("h.trigger", "h.device_id")
	Scope := _KLR_DateScope(Dates, "h.date")
	if IsSet(Device)
		Scope .= " AND h.device_id=" . SQLite_Q(Device)
	return KLR_ExecAggregateStep(Db, "hotstring-fired",
		"INSERT INTO agg_app_day(device_id,date,app,hs_chars,hs_triggers,hs_input_chars) "
		. "SELECT h.device_id,h.date,h.app,SUM(COALESCE(h.net_saved_chars,0)+(" . Input . ")),"
		. "COUNT(*),SUM(" . Input . ") FROM events_hotstring AS h WHERE h.kind='fired'"
		. Scope . " GROUP BY h.device_id,h.date,h.app ON CONFLICT(device_id,date,app) DO UPDATE SET "
		. "hs_chars=excluded.hs_chars,hs_triggers=excluded.hs_triggers,hs_input_chars=excluded.hs_input_chars;")
}

; A first declaration changes the interpretation of older rows from this device.
; Recount only SQL-owned expansion fields, leaving historical walker state alone.
KLR_ApplyIncrementalWithCountUnits(Db, Tails, LogPath) {
	try {
		Before := KLHotstringUnits.Read(Db)
		Result := KLR_ApplyIncremental(Db, Tails, LogPath)
		if !Result.Get("ok", false)
			return Result
		After := KLHotstringUnits.Read(Db)
		for Device, Unit in Before
			if !After.Has(Device) || After[Device] != Unit
				throw KLHotstringUnitError("Hotstring count unit declaration changed after consumption.")
		for Device in After
			if !Before.Has(Device) && !KLR_RebuildHotstringCounts(Db, 0, Device)
				throw Error("Historical hotstring unit recount failed.")
		return Result
	} catch Error as Failure {
		try LoggerError("KLReader", "Hotstring count unit replay failed: {1}", Failure.Message)
		; Query/recount failures do not prove the source bytes are invalid.
		return Map("ok", false, "incomplete", false, "retry", !(Failure is KLHotstringUnitError))
	}
}
