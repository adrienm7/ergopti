; tests/unit/test_screenshot_worker_ownership.ahk

; ==============================================================================
; MODULE: Screenshot Worker Ownership Regression Tests
; DESCRIPTION:
; Exercises the AHK-13 process state machine with fake ShellRunner handles. The
; tests prove cancellation claims every screenshot owner before termination,
; remains safe when the kill request fails, rejects late completion side effects,
; and cleans each private stage exactly once.
; ==============================================================================

#Requires AutoHotkey v2.0

global _GSWO_Handles := []
global _GSWO_Terminals := []
global _GSWO_ExistingFiles := Map()
global _GSWO_FilePublishes := 0
global _GSWO_ClipboardPublishes := 0
global _GSWO_StageCleanups := Map()
global _GSWO_FileRollbacks := 0
global _GSWO_ClipboardRestores := 0
global _GSWO_ClipboardSequence := 100
global _GSWO_ClipboardHasImage := false





; =====================================
; =====================================
; ======= 1/ Fake OS boundaries =======
; =====================================
; =====================================

_GSWO_FakeStart(Record, *) {
	return Record["start_result"]
}

_GSWO_FakeRequestTerminate(Record, *) {
	Record["terminate_calls"] += 1
	if Record["complete_on_terminate"]
		Record["done"].Call(1, "", "terminated")
	return Record["terminate_result"]
}

_GSWO_FakeSpawn(Executable, Args, Done) {
	global _GSWO_Handles
	Record := Map(
		"executable", Executable,
		"args", Args,
		"done", Done,
		"start_result", true,
		"terminate_result", true,
		"terminate_calls", 0,
		"complete_on_terminate", false)
	Handle := {}
	Handle.start := _GSWO_FakeStart.Bind(Record)
	Handle.requestTerminate := _GSWO_FakeRequestTerminate.Bind(Record)
	Record["handle"] := Handle
	_GSWO_Handles.Push(Record)
	return Handle
}

_GSWO_FakeFileExists(Path) {
	global _GSWO_ExistingFiles
	return _GSWO_ExistingFiles.Get(Path, false)
}

_GSWO_FakePublishFile(Stage, Destination) {
	global _GSWO_ExistingFiles, _GSWO_FilePublishes
	_GSWO_FilePublishes += 1
	if !_GSWO_ExistingFiles.Get(Stage, false)
		return false
	_GSWO_ExistingFiles.Delete(Stage)
	_GSWO_ExistingFiles[Destination] := true
	return true
}

_GSWO_FakePublishFilePartialFailure(Stage, Destination) {
	global _GSWO_ExistingFiles, _GSWO_FilePublishes
	_GSWO_FilePublishes += 1
	if !_GSWO_ExistingFiles.Get(Stage, false)
		return false
	_GSWO_ExistingFiles.Delete(Stage)
	_GSWO_ExistingFiles[Destination] := true
	return false
}

_GSWO_FakePublishClipboard(Stage) {
	global _GSWO_ExistingFiles, _GSWO_ClipboardPublishes
	global _GSWO_ClipboardSequence, _GSWO_ClipboardHasImage
	_GSWO_ClipboardPublishes += 1
	if !_GSWO_ExistingFiles.Get(Stage, false)
		return false
	_GSWO_ClipboardSequence += 1
	_GSWO_ClipboardHasImage := true
	return true
}

_GSWO_FakePublishClipboardPartialFailure(Stage) {
	global _GSWO_ExistingFiles, _GSWO_ClipboardPublishes
	global _GSWO_ClipboardSequence, _GSWO_ClipboardHasImage
	_GSWO_ClipboardPublishes += 1
	if !_GSWO_ExistingFiles.Get(Stage, false)
		return false
	; Models EmptyClipboard succeeding before SetClipboardData fails.
	_GSWO_ClipboardSequence += 1
	_GSWO_ClipboardHasImage := false
	return false
}

_GSWO_FakeCleanupStage(Path) {
	global _GSWO_ExistingFiles, _GSWO_StageCleanups
	_GSWO_StageCleanups[Path] := _GSWO_StageCleanups.Get(Path, 0) + 1
	if _GSWO_ExistingFiles.Has(Path)
		_GSWO_ExistingFiles.Delete(Path)
	return true
}

_GSWO_FakeRollbackFile(Path) {
	global _GSWO_ExistingFiles, _GSWO_FileRollbacks
	_GSWO_FileRollbacks += 1
	if _GSWO_ExistingFiles.Has(Path)
		_GSWO_ExistingFiles.Delete(Path)
	return true
}

_GSWO_FakeClipboardSequence() {
	global _GSWO_ClipboardSequence
	return _GSWO_ClipboardSequence
}

_GSWO_FakeClipboardHasImage() {
	global _GSWO_ClipboardHasImage
	return _GSWO_ClipboardHasImage
}

_GSWO_FakeClipboardHasImageAndSuspend() {
	global _GSWO_ClipboardHasImage
	GestureScreenshotCancelAll("suspended")
	return _GSWO_ClipboardHasImage
}

_GSWO_FakeClipboardSave() {
	return "fake clipboard snapshot"
}

_GSWO_FakeClipboardRestore(Snapshot, PublishedSequence) {
	global _GSWO_ClipboardRestores, _GSWO_ClipboardSequence, _GSWO_ClipboardHasImage
	if PublishedSequence != _GSWO_ClipboardSequence
		return false
	_GSWO_ClipboardRestores += 1
	_GSWO_ClipboardSequence += 1
	_GSWO_ClipboardHasImage := false
	return true
}

_GSWO_RecordTerminal(Ok, Reason := "") {
	global _GSWO_Terminals
	_GSWO_Terminals.Push(Map("ok", Ok, "reason", Reason))
}





; ========================================
; ========================================
; ======= 2/ Harness state control =======
; ========================================
; ========================================

_GSWO_Install() {
	global _GestureDirectCaptures, _GestureDirectCaptureEpoch
	global _GestureRegionCapture, _GestureRegionCaptureEpoch
	global _GSWO_Handles, _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_FilePublishes, _GSWO_ClipboardPublishes, _GSWO_StageCleanups
	global _GSWO_FileRollbacks, _GSWO_ClipboardRestores
	global _GSWO_ClipboardSequence, _GSWO_ClipboardHasImage
	Old := Map(
		"jobs", GestureScreenshotWorkerState.jobs,
		"generation", GestureScreenshotWorkerState.generation,
		"spawn_fn", GestureScreenshotWorkerState.spawn_fn,
		"file_exists_fn", GestureScreenshotWorkerState.file_exists_fn,
		"publish_file_fn", GestureScreenshotWorkerState.publish_file_fn,
		"publish_clipboard_fn", GestureScreenshotWorkerState.publish_clipboard_fn,
		"cleanup_stage_fn", GestureScreenshotWorkerState.cleanup_stage_fn,
		"rollback_file_fn", GestureScreenshotWorkerState.rollback_file_fn,
		"clipboard_sequence_fn", GestureScreenshotWorkerState.clipboard_sequence_fn,
		"clipboard_has_image_fn", GestureScreenshotWorkerState.clipboard_has_image_fn,
		"clipboard_save_fn", GestureScreenshotWorkerState.clipboard_save_fn,
		"clipboard_restore_fn", GestureScreenshotWorkerState.clipboard_restore_fn,
		"direct", _GestureDirectCaptures,
		"direct_epoch", _GestureDirectCaptureEpoch,
		"region", _GestureRegionCapture,
		"region_epoch", _GestureRegionCaptureEpoch)

	GestureScreenshotWorkerState.jobs := Map()
	GestureScreenshotWorkerState.generation := 0
	GestureScreenshotWorkerState.spawn_fn := _GSWO_FakeSpawn
	GestureScreenshotWorkerState.file_exists_fn := _GSWO_FakeFileExists
	GestureScreenshotWorkerState.publish_file_fn := _GSWO_FakePublishFile
	GestureScreenshotWorkerState.publish_clipboard_fn := _GSWO_FakePublishClipboard
	GestureScreenshotWorkerState.cleanup_stage_fn := _GSWO_FakeCleanupStage
	GestureScreenshotWorkerState.rollback_file_fn := _GSWO_FakeRollbackFile
	GestureScreenshotWorkerState.clipboard_sequence_fn := _GSWO_FakeClipboardSequence
	GestureScreenshotWorkerState.clipboard_has_image_fn := _GSWO_FakeClipboardHasImage
	GestureScreenshotWorkerState.clipboard_save_fn := _GSWO_FakeClipboardSave
	GestureScreenshotWorkerState.clipboard_restore_fn := _GSWO_FakeClipboardRestore
	_GestureDirectCaptures := Map()
	_GestureDirectCaptureEpoch := 0
	_GestureRegionCapture := false
	_GestureRegionCaptureEpoch := 0
	_GSWO_Handles := []
	_GSWO_Terminals := []
	_GSWO_ExistingFiles := Map()
	_GSWO_FilePublishes := 0
	_GSWO_ClipboardPublishes := 0
	_GSWO_StageCleanups := Map()
	_GSWO_FileRollbacks := 0
	_GSWO_ClipboardRestores := 0
	_GSWO_ClipboardSequence := 100
	_GSWO_ClipboardHasImage := false
	return Old
}

_GSWO_Restore(Old) {
	global _GestureDirectCaptures, _GestureDirectCaptureEpoch
	global _GestureRegionCapture, _GestureRegionCaptureEpoch
	GestureScreenshotWorkerState.jobs := Old["jobs"]
	GestureScreenshotWorkerState.generation := Old["generation"]
	GestureScreenshotWorkerState.spawn_fn := Old["spawn_fn"]
	GestureScreenshotWorkerState.file_exists_fn := Old["file_exists_fn"]
	GestureScreenshotWorkerState.publish_file_fn := Old["publish_file_fn"]
	GestureScreenshotWorkerState.publish_clipboard_fn := Old["publish_clipboard_fn"]
	GestureScreenshotWorkerState.cleanup_stage_fn := Old["cleanup_stage_fn"]
	GestureScreenshotWorkerState.rollback_file_fn := Old["rollback_file_fn"]
	GestureScreenshotWorkerState.clipboard_sequence_fn := Old["clipboard_sequence_fn"]
	GestureScreenshotWorkerState.clipboard_has_image_fn := Old["clipboard_has_image_fn"]
	GestureScreenshotWorkerState.clipboard_save_fn := Old["clipboard_save_fn"]
	GestureScreenshotWorkerState.clipboard_restore_fn := Old["clipboard_restore_fn"]
	_GestureDirectCaptures := Old["direct"]
	_GestureDirectCaptureEpoch := Old["direct_epoch"]
	_GestureRegionCapture := Old["region"]
	_GestureRegionCaptureEpoch := Old["region_epoch"]
}

_GSWO_JobByOwner(Kind, Epoch) {
	for _, Job in GestureScreenshotWorkerState.jobs {
		if Job["kind"] == Kind && Job["owner_epoch"] == Epoch
			return Job
	}
	return 0
}

_GSWO_CompleteHandle(Index, ExitCode := 0) {
	global _GSWO_Handles
	_GSWO_Handles[Index]["done"].Call(ExitCode, "", "")
}

_GSWO_SeedRegion(Epoch := 1) {
	global _GestureRegionCapture, _GestureRegionCaptureEpoch
	_GestureRegionCaptureEpoch := Epoch
	_GestureRegionCapture := Map(
		"epoch", Epoch,
		"path", A_Temp . "\gswo_region_final_" . Epoch . ".png",
		"original_clipboard", "snapshot",
		"clipboard_sequence", 0,
		"owner_token", 0,
		"expected_change", 0,
		"selection_started_tick", A_TickCount,
		"selection_timeout_ms", 1000,
		"save_started_tick", 0,
		"save_timeout_ms", 1000,
		"save_started", false,
		"worker_id", 0)
}





; ======================================
; ======================================
; ======= 3/ Cancellation proofs =======
; ======================================
; ======================================

_GSWO_SuspendKillFailureFencesLateClipboard() {
	global _GSWO_Handles, _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_ClipboardPublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		Assert(GestureCaptureRegion(0, 0, 20, 20, "clipboard", "", _GSWO_RecordTerminal),
			"direct clipboard capture must reserve and start one fake worker")
		Job := _GSWO_JobByOwner("direct_clipboard", 1)
		Assert(IsObject(Job) && _GSWO_Handles.Length = 1,
			"direct clipboard capture must retain its shared worker identity")
		_GSWO_Handles[1]["terminate_result"] := false
		GestureScreenshotCancelAll("suspended")
		Assert(_GSWO_Handles[1]["terminate_calls"] = 1,
			"suspend must request exactly one process-tree termination")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"suspend must claim the user terminal before process cancellation")
		Assert(_GSWO_ClipboardPublishes = 0,
			"a failed termination request must not publish clipboard output")

		_GSWO_ExistingFiles[Job["stage"]] := true
		_GSWO_CompleteHandle(1)
		_GSWO_CompleteHandle(1)
		GestureScreenshotCancelAll("suspended")
		Assert(_GSWO_ClipboardPublishes = 0 && _GSWO_Terminals.Length = 1,
			"late and duplicate completion must stay stale after suspend")
		Assert(_GSWO_StageCleanups.Get(Job["stage"], 0) = 1,
			"the private stage must be cleaned exactly once after late completion")
		Assert(!_GSWO_ExistingFiles.Get(Job["stage"], false),
			"cleanup must occur after late output exists, not retire an empty path too early")
		Assert(GestureScreenshotWorkerState.jobs.Count = 0,
			"late completion must reap the canceled worker tombstone")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: suspend fences clipboard when termination fails",
	_GSWO_SuspendKillFailureFencesLateClipboard)

_GSWO_DirectTimeoutFencesLateDisk() {
	global _GestureDirectCaptures, _GSWO_Handles, _GSWO_Terminals
	global _GSWO_ExistingFiles, _GSWO_FilePublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		Destination := A_Temp . "\gswo_direct_timeout.png"
		Assert(GestureCaptureRegion(0, 0, 20, 20, "save", Destination, _GSWO_RecordTerminal),
			"direct save timeout test must start one fake worker")
		Job := _GSWO_JobByOwner("direct_save", 1)
		_GestureDirectCaptures[1]["timeout_ms"] := 0
		GestureDirectCapturePoll(1)
		Assert(_GSWO_Handles[1]["terminate_calls"] = 1,
			"direct timeout must request exactly one process-tree termination")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"direct timeout must emit one failed terminal")

		_GSWO_ExistingFiles[Job["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_FilePublishes = 0 && !_GSWO_ExistingFiles.Get(Destination, false),
			"a timed-out worker may finish only its private stage, never the final path")
		Assert(_GSWO_StageCleanups.Get(Job["stage"], 0) = 1,
			"timed-out direct capture must clean its stage exactly once")
		Assert(!_GSWO_ExistingFiles.Get(Job["stage"], false),
			"timed-out late output must not survive its terminal cleanup")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: direct timeout fences late disk publication",
	_GSWO_DirectTimeoutFencesLateDisk)

_GSWO_RegionSuspendAndTimeoutOwnWorkers() {
	global _GestureRegionCapture, _GSWO_Handles, _GSWO_ExistingFiles
	global _GSWO_FilePublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		_GSWO_SeedRegion(1)
		Assert(GestureRegionCaptureStartSaveWorker(1),
			"region save must start through the shared fake worker")
		FirstJob := _GSWO_JobByOwner("region_save", 1)
		GestureRegionCaptureFinish(1, "suspended", true)
		Assert(_GSWO_Handles[1]["terminate_calls"] = 1,
			"region suspend must terminate its retained save worker exactly once")
		_GSWO_ExistingFiles[FirstJob["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_FilePublishes = 0
			&& _GSWO_StageCleanups.Get(FirstJob["stage"], 0) = 1,
			"region suspend must suppress late final publication and reap the stage")
		Assert(!_GSWO_ExistingFiles.Get(FirstJob["stage"], false),
			"region suspend cleanup must remove late private output")

		_GSWO_SeedRegion(2)
		Assert(GestureRegionCaptureStartSaveWorker(2),
			"region timeout test must start a second fake worker")
		SecondJob := _GSWO_JobByOwner("region_save", 2)
		_GestureRegionCapture["save_timeout_ms"] := 0
		GestureRegionCapturePoll(2)
		Assert(_GSWO_Handles[2]["terminate_calls"] = 1,
			"region save timeout must terminate its retained worker exactly once")
		_GSWO_ExistingFiles[SecondJob["stage"]] := true
		_GSWO_CompleteHandle(2)
		Assert(_GSWO_FilePublishes = 0
			&& _GSWO_StageCleanups.Get(SecondJob["stage"], 0) = 1,
			"region timeout must suppress late publication and clean exactly once")
		Assert(!_GSWO_ExistingFiles.Get(SecondJob["stage"], false),
			"region timeout cleanup must remove late private output")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: region suspend and timeout own save workers",
	_GSWO_RegionSuspendAndTimeoutOwnWorkers)

_GSWO_SupersessionPublishesOnlyNewest() {
	global _GSWO_Handles, _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_FilePublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		FirstPath := A_Temp . "\gswo_first.png"
		SecondPath := A_Temp . "\gswo_second.png"
		Assert(GestureCaptureRegion(0, 0, 20, 20, "save", FirstPath, _GSWO_RecordTerminal),
			"first supersession worker must start")
		FirstJob := _GSWO_JobByOwner("direct_save", 1)
		Assert(GestureCaptureRegion(0, 0, 20, 20, "save", SecondPath, _GSWO_RecordTerminal),
			"newest supersession worker must start")
		SecondJob := _GSWO_JobByOwner("direct_save", 2)
		Assert(_GSWO_Handles[1]["terminate_calls"] = 1,
			"new capture must terminate the superseded worker exactly once")

		_GSWO_ExistingFiles[FirstJob["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_FilePublishes = 0 && !_GSWO_ExistingFiles.Get(FirstPath, false),
			"superseded completion must not publish its final path")
		_GSWO_ExistingFiles[SecondJob["stage"]] := true
		_GSWO_CompleteHandle(2)
		Assert(_GSWO_FilePublishes = 1 && _GSWO_ExistingFiles.Get(SecondPath, false),
			"the current generation must still publish successfully")
		Assert(_GSWO_Terminals.Length = 2 && !_GSWO_Terminals[1]["ok"]
			&& _GSWO_Terminals[2]["ok"],
			"supersession and success must each emit one non-contradictory terminal")
		Assert(_GSWO_StageCleanups.Get(FirstJob["stage"], 0) = 1
			&& _GSWO_StageCleanups.Get(SecondJob["stage"], 0) = 1,
			"both superseded and successful stages must be cleaned exactly once")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: supersession publishes only the newest generation",
	_GSWO_SupersessionPublishesOnlyNewest)

_GSWO_CurrentClipboardPublishesExactlyOnce() {
	global _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_ClipboardPublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		Assert(GestureCaptureRegion(0, 0, 20, 20, "clipboard", "", _GSWO_RecordTerminal),
			"current clipboard capture must start one fake worker")
		Job := _GSWO_JobByOwner("direct_clipboard", 1)
		_GSWO_ExistingFiles[Job["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_ClipboardPublishes = 1,
			"the live generation must publish its staged bitmap exactly once")
		Assert(_GSWO_Terminals.Length = 1 && _GSWO_Terminals[1]["ok"],
			"successful clipboard publication must emit one success terminal")
		Assert(_GSWO_StageCleanups.Get(Job["stage"], 0) = 1,
			"successful clipboard publication must still clean its stage exactly once")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: current clipboard generation publishes exactly once",
	_GSWO_CurrentClipboardPublishesExactlyOnce)

_GSWO_SuspendDuringClipboardPublishRollsBack() {
	global _GSWO_Handles, _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_ClipboardPublishes, _GSWO_ClipboardRestores
	global _GSWO_ClipboardHasImage, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		GestureScreenshotWorkerState.clipboard_has_image_fn := _GSWO_FakeClipboardHasImageAndSuspend
		Assert(GestureCaptureRegion(0, 0, 20, 20, "clipboard", "", _GSWO_RecordTerminal),
			"re-entrant clipboard cancellation test must start one fake worker")
		Job := _GSWO_JobByOwner("direct_clipboard", 1)
		_GSWO_ExistingFiles[Job["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_ClipboardPublishes = 1 && _GSWO_ClipboardRestores = 1,
			"suspend which wins during publication must restore the prior clipboard")
		Assert(!_GSWO_ClipboardHasImage,
			"the canceled screenshot image must not remain in the clipboard")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"re-entrant suspend must own the only user-visible terminal")
		Assert(_GSWO_Handles[1]["terminate_calls"] = 0,
			"a worker already in completion must be fenced without a redundant kill")
		Assert(_GSWO_StageCleanups.Get(Job["stage"], 0) = 1
			&& GestureScreenshotWorkerState.jobs.Count = 0,
			"re-entrant cancellation must still reap the worker and its stage exactly once")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: suspend during clipboard publication rolls back",
	_GSWO_SuspendDuringClipboardPublishRollsBack)

_GSWO_PartialClipboardFailureRestoresSnapshot() {
	global _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_ClipboardPublishes, _GSWO_ClipboardRestores
	global _GSWO_ClipboardHasImage
	Old := _GSWO_Install()
	try {
		GestureScreenshotWorkerState.publish_clipboard_fn :=
			_GSWO_FakePublishClipboardPartialFailure
		Assert(GestureCaptureRegion(0, 0, 20, 20, "clipboard", "", _GSWO_RecordTerminal),
			"partial clipboard publication test must start one fake worker")
		Job := _GSWO_JobByOwner("direct_clipboard", 1)
		_GSWO_ExistingFiles[Job["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_ClipboardPublishes = 1 && _GSWO_ClipboardRestores = 1,
			"a failed publish which changed the clipboard must restore its snapshot")
		Assert(!_GSWO_ClipboardHasImage,
			"failed partial publication must not leave screenshot clipboard state")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"a partial clipboard failure must emit exactly one failed terminal")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: partial clipboard failure restores prior content",
	_GSWO_PartialClipboardFailureRestoresSnapshot)

_GSWO_PartialFileFailureRollsBackEveryOwner() {
	global _GestureRegionCapture
	global _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_FilePublishes, _GSWO_FileRollbacks
	Old := _GSWO_Install()
	try {
		GestureScreenshotWorkerState.publish_file_fn := _GSWO_FakePublishFilePartialFailure
		DirectDestination := A_Temp . "\gswo_direct_partial.png"
		Assert(GestureCaptureRegion(0, 0, 20, 20, "save", DirectDestination,
			_GSWO_RecordTerminal),
			"direct partial file publication test must start one fake worker")
		DirectJob := _GSWO_JobByOwner("direct_save", 1)
		_GSWO_ExistingFiles[DirectJob["stage"]] := true
		_GSWO_CompleteHandle(1)
		Assert(!_GSWO_ExistingFiles.Get(DirectDestination, false),
			"direct owner must remove a destination created by a failed publication")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"direct partial file publication must emit one failed terminal")

		_GSWO_SeedRegion(2)
		RegionDestination := _GestureRegionCapture["path"]
		Assert(GestureRegionCaptureStartSaveWorker(2),
			"region partial file publication test must start one fake worker")
		RegionJob := _GSWO_JobByOwner("region_save", 2)
		_GSWO_ExistingFiles[RegionJob["stage"]] := true
		_GSWO_CompleteHandle(2)
		Assert(!_GSWO_ExistingFiles.Get(RegionDestination, false),
			"region owner must remove a destination created by a failed publication")
		Assert(_GSWO_FilePublishes = 2 && _GSWO_FileRollbacks = 2,
			"both disk owners must detect and roll back partial publication")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: partial file failure rolls back every owner",
	_GSWO_PartialFileFailureRollsBackEveryOwner)

_GSWO_ShutdownCancelsAndCleansWorker() {
	global _GSWO_Handles, _GSWO_Terminals, _GSWO_ExistingFiles
	global _GSWO_FilePublishes, _GSWO_StageCleanups
	Old := _GSWO_Install()
	try {
		Destination := A_Temp . "\gswo_shutdown_final.png"
		Assert(GestureCaptureRegion(0, 0, 20, 20, "save", Destination, _GSWO_RecordTerminal),
			"shutdown test must start one fake worker")
		Job := _GSWO_JobByOwner("direct_save", 1)
		_GSWO_ExistingFiles[Job["stage"]] := true
		GestureScreenshotCancelAll("shutdown")
		Assert(_GSWO_Handles[1]["terminate_calls"] = 1,
			"shutdown must request exactly one process-tree termination")
		Assert(_GSWO_Terminals.Length = 1 && !_GSWO_Terminals[1]["ok"],
			"shutdown must claim the failed terminal before child teardown")
		Assert(_GSWO_FilePublishes = 0
			&& _GSWO_StageCleanups.Get(Job["stage"], 0) = 1
			&& !_GSWO_ExistingFiles.Get(Job["stage"], false),
			"shutdown must remove an existing private stage without publishing it")
		_GSWO_CompleteHandle(1)
		Assert(_GSWO_FilePublishes = 0
			&& _GSWO_StageCleanups.Get(Job["stage"], 0) = 1
			&& GestureScreenshotWorkerState.jobs.Count = 0,
			"late shutdown completion must remain fenced and cleanup idempotent")
	} finally {
		_GSWO_Restore(Old)
	}
}

Test("screenshot-worker-ownership: shutdown cancels and cleans retained workers",
	_GSWO_ShutdownCancelsAndCleansWorker)





; ====================================
; ====================================
; ======= 4/ Whole-class guard =======
; ====================================
; ====================================

_GSWO_AllEntryPointsShareOwnership() {
	Instant := _DriverFuncBody("GestureScreenshotInstant")
	Window := _DriverFuncBody("GestureScreenshotWindow")
	Fullscreen := _DriverFuncBody("GestureScreenshotFullscreen")
	Region := _DriverFuncBody("GestureScreenshotRegion")
	ScreenshotPath := _DriverFuncBody("GestureScreenshotPath")
	DirectScript := _DriverFuncBody("_GestureScreenshotDirectScript")
	RegionScript := _DriverFuncBody("_GestureScreenshotRegionSaveScript")
	ClipboardPublish := _DriverFuncBody("CB_WriteBitmapFile")
	DefaultClipboardPublish := _DriverFuncBody("_GestureScreenshotDefaultPublishClipboard")
	SuspendBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	TreeSpawner := _DriverFuncBody("ShellRunner_SpawnTreeOwned")
	TreeCreate := _DriverFuncBody("_SR_TreeCreateSuspended")
	TreeStart := _DriverFuncBody("_SR_TreeHandleStart")
	TreeTerminator := _DriverFuncBody("_SR_TreeHandleTerminate")
	TreeQuiesce := _DriverFuncBody("_SR_TreeQuiesceNative")
	TreeAccounting := _DriverFuncBody("_SR_TreeActiveProcessCount")
	TreeConfirm := _DriverFuncBody("_SR_TreeConfirmJobEmpty")
	CancelWorker := _DriverFuncBody("GestureScreenshotCancelWorker")
	for Name, Body in Map(
		"instant", Instant, "window", Window, "fullscreen", Fullscreen,
		"region", Region, "screenshot path", ScreenshotPath,
		"direct script", DirectScript,
		"region script", RegionScript,
		"clipboard publish", ClipboardPublish,
		"default clipboard publish", DefaultClipboardPublish,
		"suspend", SuspendBody,
		"shutdown", ShutdownBody,
		"tree-owned spawner", TreeSpawner,
		"tree-owned native create", TreeCreate,
		"tree-owned start", TreeStart,
		"tree-owned terminator", TreeTerminator,
		"tree-owned quiesce", TreeQuiesce,
		"tree-owned accounting", TreeAccounting,
		"tree-owned confirmation", TreeConfirm,
		"worker cancel", CancelWorker) {
		Assert(Body != "", "screenshot-worker-ownership premise: " . Name . " source must exist")
	}
	Assert(InStr(Instant, "GestureCaptureRegion(") > 0
		&& InStr(Window, "GestureCaptureRegion(") > 0
		&& InStr(Fullscreen, "GestureCaptureRegion(") > 0,
		"instant, window, and fullscreen actions must converge on the direct owner")
	Assert(InStr(Instant, "GestureScreenshotPath()") > 0
		&& InStr(Window, "GestureScreenshotPath()") > 0
		&& InStr(Fullscreen, "GestureScreenshotPath()") > 0
		&& InStr(Region, "GestureScreenshotPath()") > 0,
		"every disk entry point must use the shared collision-free destination builder")
	Assert(InStr(ScreenshotPath, "++_GestureScreenshotPathNonce") > 0
		&& InStr(ScreenshotPath, "DriverPid") > 0
		&& InStr(ScreenshotPath, "Nonce") > 0,
		"two save actions in one second must never resolve to the same destination")

	; Derive the screenshot action class from the live catalogue. The count guard
	; makes a newly added sibling fail until it is explicitly routed through one
	; of the lifecycle-owned entry points below.
	global _DriverDirConcatFn
	GestureSource := _StripFullLineComments(_DriverDirConcatFn.Call("modules/gestures"))
	ExpectedRoutes := Map(
		"screenshot_window_clipboard", 'GestureScreenshotWindow("clipboard")',
		"screenshot_window_save", 'GestureScreenshotWindow("save")',
		"screenshot_region_clipboard", 'GestureScreenshotRegion("clipboard")',
		"screenshot_region_save", 'GestureScreenshotRegion("save")',
		"screenshot_fullscreen_clipboard", 'GestureScreenshotFullscreen("clipboard")',
		"screenshot_fullscreen_save", 'GestureScreenshotFullscreen("save")',
		"screen_capture_instant", "GestureScreenshotInstant()")
	SeenRoutes := Map()
	SearchPos := 1
	while RegExMatch(GestureSource,
		'm)^\s*"(screenshot_[^"]+|screen_capture_instant)",\s*\{', &Match, SearchPos) {
		ActionId := Match[1]
		SeenRoutes[ActionId] := true
		SearchPos := Match.Pos + Match.Len
	}
	Assert(SeenRoutes.Count > 0,
		"screenshot ownership guard must match the live action catalogue")
	Assert(SeenRoutes.Count = ExpectedRoutes.Count,
		"every screenshot action in GESTURE_ACTIONS must be enumerated by the ownership guard")
	for ActionId, Delegate in ExpectedRoutes {
		Assert(SeenRoutes.Has(ActionId),
			"missing screenshot action catalogue entry: " . ActionId)
		EntryPos := InStr(GestureSource, '"' . ActionId . '"')
		Assert(InStr(SubStr(GestureSource, EntryPos, 220), Delegate) > 0,
			"screenshot action must route through its lifecycle-owned delegate: " . ActionId)
	}
	Assert(InStr(Region, "GestureScreenshotCancelAll") > 0,
		"interactive region capture must supersede every previous screenshot owner")
	Assert(InStr(DirectScript, "Clipboard]::SetImage") = 0
		&& InStr(DirectScript, "Stage") > 0 && InStr(DirectScript, '"Bmp"') > 0,
		"direct workers may write only a private stage, never the clipboard")
	Assert(InStr(DefaultClipboardPublish, "CB_WriteBitmapFile(Stage)") > 0
		&& InStr(ClipboardPublish, "LoadImageW") > 0
		&& InStr(ClipboardPublish, "SetClipboardData") > 0
		&& InStr(ClipboardPublish, "_CB_BeginOwnedMutation") > 0,
		"only the current AHK owner may publish a staged bitmap through clipboard provenance")
	Assert(InStr(ClipboardPublish, "OpenClipboard")
		< InStr(ClipboardPublish, "_CB_BeginOwnedMutation")
		&& InStr(ClipboardPublish, "_CB_BeginOwnedMutation")
		< InStr(ClipboardPublish, "EmptyClipboard"),
		"clipboard provenance must be reserved only after the file load and lock, immediately before mutation")
	Assert(InStr(RegionScript, "Stage") > 0 && InStr(RegionScript, 'State["path"]') = 0,
		"region-save workers may write only their private stage, never the final path")
	Assert(InStr(DirectScript, "Get-Process -Id") > 0
		&& InStr(RegionScript, "Get-Process -Id") > 0
		&& InStr(DirectScript, "Remove-Item -LiteralPath") > 0
		&& InStr(RegionScript, "Remove-Item -LiteralPath") > 0,
		"every worker must self-delete its private stage if shutdown removes its AHK owner")
	Assert(InStr(SuspendBody, 'GestureScreenshotCancelAll("suspended")') > 0
		&& InStr(ShutdownBody, 'GestureScreenshotCancelAll("shutdown")') > 0,
		"both suspend and shutdown must cancel the complete screenshot worker class")
	Assert(InStr(ShutdownBody, 'GestureScreenshotCancelAll("shutdown")') < InStr(ShutdownBody, "KL_Stop()"),
		"shutdown must fence screenshot children before slower subsystem teardown can yield")
	Assert(InStr(CancelWorker, 'Reason == "shutdown"') > 0
		&& InStr(CancelWorker, "_GestureScreenshotCleanupStage") > 0,
		"shutdown cancellation must clean a stage which already exists before AHK exits")
	Assert(InStr(TreeSpawner,
		"handle.requestTerminate := _SR_TreeOwnedRequestTerminate") > 0
		&& InStr(TreeSpawner, "_SR_TreeHandleTerminate(state, true)") > 0,
		"screenshot cancellation must retain completion ownership while using the synchronous native tree fence")
	CreatePos := InStr(TreeCreate, 'DllCall("Kernel32\CreateProcessW"')
	AssignPos := InStr(TreeCreate, 'DllCall("Kernel32\AssignProcessToJobObject"')
	CreateCallPos := InStr(TreeStart, "_SR_TreeCreateSuspended")
	ResumePos := InStr(TreeStart, 'DllCall("Kernel32\ResumeThread"')
	Assert(CreatePos > 0 && AssignPos > CreatePos
		&& InStr(TreeCreate, "SR_TREE_CREATE_SUSPENDED") > 0
		&& CreateCallPos > 0 && ResumePos > CreateCallPos,
		"the cmd.exe wrapper must be created suspended and assigned to its Job Object before the spawner can resume it")
	Assert(InStr(TreeTerminator, "_SR_TreeClaimTaskLocked") > 0
		&& InStr(TreeTerminator, "_SR_TreeQuiesceNative") > 0
		&& InStr(TreeQuiesce, 'DllCall("Kernel32\TerminateJobObject"') > 0
		&& InStr(TreeConfirm, "_SR_TreeActiveProcessCount") > 0
		&& InStr(TreeAccounting, "QueryInformationJobObject") > 0
		&& InStr(TreeAccounting, "SR_TREE_ACTIVE_PROCESSES_OFFSET") > 0,
		"requestTerminate must take exact native handles and confirm ActiveProcesses reaches zero before returning true")
	ReleasePos := InStr(TreeQuiesce,
		'_SR_TreeCloseNativeHandle("process"')
	ConfirmPos := InStr(TreeQuiesce, "_SR_TreeConfirmJobEmpty")
	Assert(ReleasePos > 0 && ConfirmPos > ReleasePos
		&& InStr(TreeQuiesce, "WaitForSingleObject") = 0,
		"termination must release the retained root process HANDLE before accounting can reach zero, and must never wait on the Job HANDLE")

	ShortcutSource := _StripFullLineComments(_DriverDirConcatFn.Call("modules/shortcuts"))
	Assert(InStr(ShortcutSource, "SC029::") > 0
		&& InStr(ShortcutSource, "GestureScreenshotInstant()") > 0,
		"the physical SC029 entry point must delegate instead of spawning a sibling worker")
}

Test("screenshot-worker-ownership: every entry point and lifecycle boundary shares one owner",
	_GSWO_AllEntryPointsShareOwnership)
