; tests/unit/test_toml_stage_cleanup.ahk

; ==============================================================================
; MODULE: TOML Failed Stage Cleanup Tests
; DESCRIPTION: Failed saves retire owned stages and expose native cleanup refusal.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSC_FailedReplace(LockStage) {
	global _ParseTomlCache, _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	Saved := [_ParseTomlCache, _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED]
	_KLRDC_Reset()
	Path := _KLRDC_Root() . "settings.toml"
	Foreign := Path . ".foreign.tmp"
	Original := '[sample]`nvalue = "old"`n'
	TargetLock := 0
	StageLock := 0
	OwnedStage := ""
	SawPrimary := false
	SawCleanup := false
	Capture(Line) {
		if InStr(Line, "Write-through atomic replace") {
			SawPrimary := true
			if LockStage && !IsObject(StageLock) {
				loop files Path . "." . A_ScriptHwnd . "-*.tmp", "F" {
					OwnedStage := A_LoopFileFullPath
					StageLock := FileOpen(OwnedStage, "r-wd")
				}
			}
		}
		if InStr(Line, "Owned staging file cleanup failed")
			SawCleanup := true
	}
	try {
		_ParseTomlCache := Map()
		_LOGGER_ERROR_ENABLED := true
		LoggerSetTestSink(Capture)
		AssertTrue(FSWriteCreateDurable(Path, Original) != 0)
		AssertTrue(FSWriteCreateDurable(Foreign, "foreign sentinel") != 0)
		TargetLock := FileOpen(Path, "r-wd")
		AssertTrue(IsObject(TargetLock))
		Updates := [{Section: "sample", Key: "value", Value: "new"}]
		loop LockStage ? 1 : 2 {
			AssertFalse(TOML_BatchWrite(Path, Updates))
			AssertEqual(Original, FileRead(Path, "UTF-8"))
		}
		AssertTrue(SawPrimary, "the native target lock must reach atomic replacement refusal")
		if LockStage {
			AssertTrue(IsObject(StageLock), "the diagnostic hook must lock the actual abandoned stage")
			AssertTrue(SawCleanup, "a refused deletion must remain visible alongside the primary save failure")
			AssertTrue(FileExist(OwnedStage))
			StageLock.Close()
			StageLock := 0
			AssertTrue(_TOML_RemoveOwnedStage(OwnedStage))
		}
		Count := 0
		loop files Path . "." . A_ScriptHwnd . "-*.tmp", "F"
			Count += 1
		AssertEqual(0, Count, "failed saves must not accumulate known abandoned stages while the driver stays alive")
		AssertEqual("foreign sentinel", FileRead(Foreign, "UTF-8"))
		TargetLock.Close()
		TargetLock := 0
		AssertTrue(TOML_BatchWrite(Path, Updates))
		AssertEqual("new", ParseTomlFile(Path)["sample"]["value"])
	} finally {
		if IsObject(StageLock)
			StageLock.Close()
		if IsObject(TargetLock)
			TargetLock.Close()
		_ParseTomlCache := Saved[1]
		LoggerSetTestSink(Saved[2])
		_LOGGER_ERROR_ENABLED := Saved[3]
		_KLRDC_Cleanup()
	}
}
for LockStage in [false, true]
	Test("TOML failed save: retire owned stage cleanup-locked=" . LockStage . " (toml-stage-cleanup)",
		_KLRDC_CheckTeardown.Bind(_TSC_FailedReplace.Bind(LockStage)))
