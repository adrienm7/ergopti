; static/ergopti_plus/windows/tests/meta/test_hotstring_check_constraint_widened.ahk

#Requires AutoHotkey v2.0

_HotstringCheck_SchemaAllowsNearMissAndManualTyped() {
	; events_hotstring.kind's CHECK constraint used to allow only
	; 'fired'/'suggested'/'dismissed'; hotstring_near_miss and
	; manual_typed_known_trigger rows silently vanished on every SQLite
	; replay of data.sql (F20).
	SchemaPath := A_ScriptDir . "\..\..\_shared\data\db\schema.sql"
	AssertTrue(FileExist(SchemaPath) != "", "schema.sql must exist at: " . SchemaPath)
	Schema := FileRead(SchemaPath)
	Idx := InStr(Schema, "CHECK (kind IN (")
	Assert(Idx > 0, "events_hotstring.kind must have a CHECK constraint (hotstring-kind-check-constraint-too-narrow)")
	Close := InStr(Schema, ")", , Idx)
	Clause := SubStr(Schema, Idx, Close - Idx + 1)
	Assert(InStr(Clause, "'hotstring_near_miss'") > 0, "CHECK constraint must allow hotstring_near_miss (hotstring-kind-check-constraint-too-narrow)")
	Assert(InStr(Clause, "'manual_typed_known_trigger'") > 0, "CHECK constraint must allow manual_typed_known_trigger (hotstring-kind-check-constraint-too-narrow)")
}
Test("schema: events_hotstring.kind CHECK constraint allows hotstring_near_miss/manual_typed_known_trigger (hotstring-kind-check-constraint-too-narrow)", _HotstringCheck_SchemaAllowsNearMissAndManualTyped)

_SqliteExec_LogsOnNonDoneStepCode() {
	; SQLite_Exec's step loop only checked "!= ROW" and silently treated
	; CONSTRAINT/ERROR the same as DONE, so a rejected row left zero trace
	; anywhere (F20). It must now log when the terminal code is not DONE.
	Body := _DriverFuncBody("SQLite_Exec")
	Idx := InStr(Body, "step_rc != SQLiteConst.DONE")
	Assert(Idx > 0, "SQLite_Exec must distinguish DONE from CONSTRAINT/ERROR after the step loop (sqlite-exec-step-rc-not-logged)")
	Tail := SubStr(Body, Idx, 400)
	Assert(InStr(Tail, "LoggerWarn") > 0 || InStr(Tail, "LoggerError") > 0, "SQLite_Exec must log a WARNING/ERROR when sqlite3_step does not return DONE (sqlite-exec-step-rc-not-logged)")
}
Test("sqlite: SQLite_Exec logs when sqlite3_step returns a non-DONE terminal code (sqlite-exec-step-rc-not-logged)", _SqliteExec_LogsOnNonDoneStepCode)
