; static/ergopti_plus/windows/tests/unit/test_updater_schedule_vectors.ahk

; ==============================================================================
; MODULE: Update-Check Schedule Vector Tests
; DESCRIPTION:
; Replays the shared _shared/modules/updater/schedule_vectors.json through the
; AHK port (modules/updater/schedule.ahk) over the generated timing data. The
; JavaScript module and the Lua port replay the same file, so the drivers
; cannot disagree on when an automatic check is due, how a retired interval
; snaps to a preset, or how a completed check updates the persisted record.
; ==============================================================================

_UpdSchedTest_Vectors() {
	Path := A_ScriptDir . "\..\..\_shared\modules\updater\schedule_vectors.json"
	AssertTrue(FileExist(Path) != "", "schedule vectors must exist at: " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Renders a flat record in key order so two records compare as text.
_UpdSchedTest_Describe(Record) {
	Keys := ""
	for Key in Record
		Keys .= Key . "`n"
	Keys := Sort(RTrim(Keys, "`n"))
	Text := ""
	loop parse Keys, "`n" {
		Value := Record[A_LoopField]
		Text .= A_LoopField . "=" . (Value is String ? '"' . Value . '"' : Value) . ";"
	}
	return "{" . Text . "}"
}

_UpdSchedTest_Timing() {
	Timing := UpdateSchedule_Timing()
	AssertEqual(86400, Timing["default_check_interval_sec"], "the default is one day")
	AssertEqual(30, Timing["boot_check_delay_sec"])
	Presets := UpdateSchedule_Presets()
	AssertEqual(10, Presets.Length, "ten presets, never included")
	AssertEqual("never", Presets[Presets.Length]["code"], "never is the last preset")
	AssertEqual(0, Presets[Presets.Length]["seconds"])
	AssertEqual("updater.check_state", Timing["state_storage_key"])
	Broken := UpdateScheduleData()
	Broken["check_interval_presets"].Pop()
	AssertThrows(() => UpdateSchedule_ValidateTiming(Broken),
		"a preset list without never must be refused, not degraded")
}
Test("Update schedule: the generated timing validates and lists the shared presets", _UpdSchedTest_Timing)

_UpdSchedTest_DueVectors() {
	Vectors := _UpdSchedTest_Vectors()["due"]
	AssertTrue(Vectors.Length >= 15, "due vectors: >=15 expected, got " . Vectors.Length)
	for _, V in Vectors {
		Sanitized := UpdateSchedule_SanitizeState(V["state"])
		AssertEqual(0, Sanitized.Dropped.Length, "due vector " . V["id"] . " holds a valid state")
		Due := UpdateSchedule_NextDue(V["now"], V["started_at"], V["interval"], Sanitized.State)
		AssertEqual(V["expect"]["reason"], Due.Reason, "due vector " . V["id"] . " reason")
		AssertEqual(V["expect"].Get("due_at", ""), Due.DueAt, "due vector " . V["id"] . " due_at")
	}
}
Test("Update schedule: due times match the shared vectors", _UpdSchedTest_DueVectors)

_UpdSchedTest_JitterVectors() {
	Vectors := _UpdSchedTest_Vectors()["jitter"]
	AssertTrue(Vectors.Length >= 8, "jitter vectors: >=8 expected")
	for _, V in Vectors
		AssertEqual(V["expect"], UpdateSchedule_JitterSeconds(V["seed"], V["anchor"], V["interval"]),
			"jitter vector " . V["id"])
}
Test("Update schedule: jitter matches the shared vectors", _UpdSchedTest_JitterVectors)

_UpdSchedTest_SnapVectors() {
	Vectors := _UpdSchedTest_Vectors()["snap"]
	AssertTrue(Vectors.Length >= 10, "snap vectors: >=10 expected")
	for _, V in Vectors {
		Snap := UpdateSchedule_SnapInterval(V["seconds"])
		AssertEqual(V["expect"], Snap.Seconds, "snap vector " . V["id"] . " seconds")
		AssertEqual(V["code"], Snap.Code, "snap vector " . V["id"] . " code")
		AssertEqual(V["snapped"] ? true : false, Snap.Snapped ? true : false, "snap vector " . V["id"] . " snapped")
	}
}
Test("Update schedule: retired intervals snap like the shared vectors", _UpdSchedTest_SnapVectors)

_UpdSchedTest_SanitizeVectors() {
	Vectors := _UpdSchedTest_Vectors()["sanitize"]
	AssertTrue(Vectors.Length >= 6, "sanitize vectors: >=6 expected")
	for _, V in Vectors {
		Result := UpdateSchedule_SanitizeState(V["raw"])
		AssertEqual(_UpdSchedTest_Describe(V["expect"]), _UpdSchedTest_Describe(Result.State),
			"sanitize vector " . V["id"])
		Dropped := ""
		for _, Field in Result.Dropped
			Dropped .= Field . ","
		Wanted := ""
		for _, Field in V["dropped"]
			Wanted .= Field . ","
		AssertEqual(Wanted, Dropped, "sanitize vector " . V["id"] . " dropped")
	}
}
Test("Update schedule: stored records keep only valid fields (shared vectors)", _UpdSchedTest_SanitizeVectors)

_UpdSchedTest_RecordVectors() {
	Vectors := _UpdSchedTest_Vectors()["record"]
	AssertTrue(Vectors.Length >= 4, "record vectors: >=4 expected")
	for _, V in Vectors {
		Before := _UpdSchedTest_Describe(V["state"])
		Next := UpdateSchedule_RecordCheck(V["state"], V["now"], V["ok"] ? true : false)
		AssertEqual(_UpdSchedTest_Describe(V["expect"]), _UpdSchedTest_Describe(Next), "record vector " . V["id"])
		AssertEqual(Before, _UpdSchedTest_Describe(V["state"]), "record vector " . V["id"] . " must not mutate its input")
	}
}
Test("Update schedule: a completed check updates the record like the shared vectors", _UpdSchedTest_RecordVectors)

_UpdSchedTest_DelayVectors() {
	Vectors := _UpdSchedTest_Vectors()["delay"]
	AssertTrue(Vectors.Length >= 4, "delay vectors: >=4 expected")
	for _, V in Vectors
		AssertEqual(V["expect"], UpdateSchedule_DelayUntil(V["due_at"], V["now"]), "delay vector " . V["id"])
}
Test("Update schedule: every timer is bounded by the re-evaluation period", _UpdSchedTest_DelayVectors)
