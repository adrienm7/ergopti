; tests/unit/modules/updater/test_updater_list_cache_stage_custody.ahk

; ==============================================================================
; MODULE: Release-list cache stage custody
; DESCRIPTION:
; A completed real-list response must update the session cache without adopting
; another producer's stage. Only the filename clock is injected: native create,
; write, flush, rename, readback and restart parsing keep their real owners.
; ==============================================================================

#Requires AutoHotkey v2.0

_UTLC_StageSnapshot(Path) {
	File := FileOpen(Path, "r", "UTF-8-RAW")
	if !IsObject(File)
		throw Error("The release-list stage fixture could not read its native identity.")
	try return FSHandleSnapshot(File.Handle)
	finally File.Close()
}

_UTLC_StageCustody(Collision) {
	global _UpdaterFetchCache, _UpdaterListCacheDir, _UpdaterListDiskLoaded, _UpdaterListDiskEntry
	global UPDATER_LIST_CACHE_FILE
	static Sequence := 0
	Sequence += 1
	Saved := {Cache: _UpdaterFetchCache, Dir: _UpdaterListCacheDir,
		Loaded: _UpdaterListDiskLoaded, Entry: _UpdaterListDiskEntry}
	Dir := A_Temp . "\ergopti_list_stage_" . PLC_CurrentProcessId() . "_" . A_TickCount . "_" . Sequence
	FSCreateDirectoryExclusiveStrict(Dir)
	; A_TickCount is native 64-bit. A frozen high tick tests its actual suffix domain.
	StageTick := 0x100000000 + 71001
	Path := Dir . "\" . UPDATER_LIST_CACHE_FILE
	Stage := Path . "." . StageTick . ".tmp"
	SeedStage := Path . ".1.tmp"
	Url := Updater_ReleaseApiUrl()
	ListA := '[{"tag_name":"v1.2.0","prerelease":false,"body":"prior release"}]'
	ListB := '[{"tag_name":"v1.3.0","prerelease":false,"body":"current release é😀"}]'
	Foreign := "independent pending release-list bytes é😀`n"
	Clock := {Calls: 0}
	StageNow() {
		Clock.Calls += 1
		return StageTick
	}
	try {
		_UpdaterListCacheDir := Dir
		_UpdaterTest_ListCacheRestart()
		Seed := _Updater_InterpretResponse(200, ListA, '"prior-etag"', "main", Url, , 0, () => 1)
		AssertEqual("v1.2.0", Updater_ParseTagName(Seed), "the production response consumer must seed the prior cache")
		BeforeTarget := FSReadUtf8Exact(Path)
		if Collision {
			AssertTrue(FSWriteCreateDurable(Stage, Foreign), "CREATE_NEW must acquire the exact independently owned native stage")
			Before := _UTLC_StageSnapshot(Stage)
			AssertTrue(Before["ok"], "the independent stage must have a real native identity")
		}
		Selected := _Updater_InterpretResponse(200, ListB, '"current-etag"', "main", Url, , 0, StageNow)
		AssertEqual(1, Clock.Calls, "the actual cache writer must select the frozen stage exactly once")
		AssertEqual("v1.3.0", Updater_ParseTagName(Selected), "a refused disk save cannot discard the genuine fresh response")
		AssertEqual(ListB, _UpdaterFetchCache["main"].Json, "the real session cache keeps the new complete list")
		ExpectedTag := Collision ? "v1.2.0" : "v1.3.0"
		ExpectedEtag := Collision ? '"prior-etag"' : '"current-etag"'
		FileAppend("# updater-list-stage collision=" . Collision . " stage_present=" . !!FileExist(Stage)
			. " prior_target=" . (FSReadUtf8Exact(Path) == BeforeTarget) . " selected=" . Updater_ParseTagName(Selected) . "`n", "*")
		if Collision {
			AssertTrue(FileExist(Stage) != "", "the actual response consumer cannot publish another producer's stage")
			AssertEqual(Foreign, FSReadUtf8Exact(Stage), "the independent stage's exact text must survive")
			After := _UTLC_StageSnapshot(Stage)
			AssertTrue(After["ok"])
			for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
				AssertEqual(Before[Key], After[Key], "the independent stage keeps its native " . Key)
			AssertEqual(BeforeTarget, FSReadUtf8Exact(Path), "the refused save must preserve the complete previous cache")
		} else
			AssertFalse(FileExist(Stage), "the healthy native cache publication consumes only its acquired stage")
		_UpdaterTest_ListCacheRestart()
		Restored := _Updater_InterpretResponse(304, "", "", "main", Url)
		AssertEqual(ExpectedTag, Updater_ParseTagName(Restored), "a real disk reload and 304 must use the last genuinely published list")
		AssertEqual(ExpectedEtag, _UpdaterFetchCache["main"].Etag, "the restored validator must name the genuinely published list")
		FileAppend("# updater-list-stage collision=" . Collision . " restored=" . Updater_ParseTagName(Restored)
			. " stage_present=" . !!FileExist(Stage) . "`n", "*")
	} finally {
		_UpdaterFetchCache := Saved.Cache, _UpdaterListCacheDir := Saved.Dir
		_UpdaterListDiskLoaded := Saved.Loaded, _UpdaterListDiskEntry := Saved.Entry
		; Exclusive fixture creation proves these three known leaves are test-owned.
		for Leaf in [Path, Stage, SeedStage]
			if !FSDelete(Leaf)
				throw Error("The private release-list fixture could not retire an owned leaf.")
		DirDelete(Dir, false)
	}
}

Test("Updater: completed response preserves a foreign list-cache stage (updater-list-stage-custody)",
	_UTLC_StageCustody.Bind(true))
Test("Updater: completed response publishes its own list-cache stage (updater-list-stage-custody)",
	_UTLC_StageCustody.Bind(false))
