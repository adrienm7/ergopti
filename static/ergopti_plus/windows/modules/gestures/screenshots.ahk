; modules/gestures/screenshots.ahk

; ==============================================================================
; MODULE: Gesture Screenshot Capture (AHK)
; DESCRIPTION:
; Owns every asynchronous screenshot worker from launch through cancellation,
; private staging, publication, and cleanup. PowerShell children may capture only
; into per-generation staging files; the current AHK owner alone may publish a
; final file or clipboard image after revalidating its epoch and lifecycle state.
;
; FEATURES & RATIONALE:
; 1. One worker registry - direct, instant, window, fullscreen, and region-save
;    paths share one cancellable ShellRunner lifecycle.
; 2. Side-effect fencing - a worker which survives suspend, timeout, supersession,
;    or shutdown can finish only a private stage and cannot touch user state.
; 3. Exact ownership - terminal callbacks, process termination, and stage cleanup
;    are each claimed once even when cancellation and completion are re-entrant.
; ==============================================================================

#Requires AutoHotkey v2.0

global _GestureRegionCapture := false
global _GestureRegionCaptureEpoch := 0
global _GestureDirectCaptures := Map()
global _GestureDirectCaptureEpoch := 0
global _GestureScreenshotPathNonce := 0
global GESTURE_REGION_CAPTURE_POLL_MS := 100
global GESTURE_REGION_CAPTURE_TIMEOUT_MS := 30000
global GESTURE_REGION_CAPTURE_SAVE_TIMEOUT_MS := 5000
global GESTURE_DIRECT_CAPTURE_TIMEOUT_MS := 5000
global GESTURE_REGION_CLIPWAIT_PROBE_SEC := 0.001
global GESTURE_REGION_CLIPWAIT_IMAGE_MODE := 2
global GESTURE_SM_XVIRTUALSCREEN := 76
global GESTURE_SM_YVIRTUALSCREEN := 77
global GESTURE_SM_CXVIRTUALSCREEN := 78
global GESTURE_SM_CYVIRTUALSCREEN := 79

; Test seams stay at zero in production. Tests replace only the OS boundaries,
; while the same ownership state machine and terminal paths execute unchanged.
class GestureScreenshotWorkerState {
	static generation := 0
	static jobs := Map()
	static spawn_fn := 0
	static file_exists_fn := 0
	static publish_file_fn := 0
	static publish_clipboard_fn := 0
	static cleanup_stage_fn := 0
	static rollback_file_fn := 0
	static clipboard_sequence_fn := 0
	static clipboard_has_image_fn := 0
	static clipboard_save_fn := 0
	static clipboard_restore_fn := 0
}





; ===========================================
; ===========================================
; ======= 1/ Files and OS publication =======
; ===========================================
; ===========================================

GestureScreenshotsDir() {
	Dir := EnvGet("USERPROFILE") . "\Pictures\screenshots"
	if !DirExist(Dir) {
		try DirCreate(Dir)
	}
	return Dir
}

GestureScreenshotPath() {
	global _GestureScreenshotPathNonce, DriverPid
	PreviousCritical := Critical("On")
	try Nonce := ++_GestureScreenshotPathNonce
	finally Critical(PreviousCritical)
	return GestureScreenshotsDir() . "\screenshot_"
		. FormatTime(, "yyyy_MM_dd_HH'h'_mm'min'_ss's'")
		. "_" . DriverPid . "_" . Nonce . ".png"
}

_GestureScreenshotDefaultFileExists(Path) {
	return FileExist(Path) != ""
}

_GestureScreenshotDefaultPublishFile(Stage, Destination) {
	try {
		if !FileExist(Stage) || FileExist(Destination)
			return false
		FileMove(Stage, Destination)
		return FileExist(Destination) != ""
	} catch as Err {
		LoggerError("gestures", "Screenshot file publication failed for '{1}': {2}.", Destination, Err.Message)
		return false
	}
}

_GestureScreenshotDefaultPublishClipboard(Stage) {
	return CB_WriteBitmapFile(Stage)
}

_GestureScreenshotDefaultDeleteFile(Path) {
	try {
		if FileExist(Path)
			FileDelete(Path)
		return FileExist(Path) = ""
	} catch as Err {
		LoggerError("gestures", "Screenshot staging cleanup failed for '{1}': {2}.", Path, Err.Message)
		return false
	}
}

_GestureScreenshotDefaultClipboardSequence() {
	return CB_GetSequenceNumber()
}

_GestureScreenshotDefaultClipboardHasImage() {
	return CB_HasImage()
}

_GestureScreenshotDefaultClipboardSave() {
	return CB_SaveAll()
}

_GestureScreenshotDefaultClipboardRestore(Snapshot, PublishedSequence) {
	return CB_RestoreOwnedAllEventually(Snapshot, PublishedSequence, 0,
		"gesture_direct_screenshot", false)
}

_GestureScreenshotFileExists(Path) {
	Fn := IsObject(GestureScreenshotWorkerState.file_exists_fn)
		? GestureScreenshotWorkerState.file_exists_fn : _GestureScreenshotDefaultFileExists
	return Fn.Call(Path)
}

_GestureScreenshotPublishFile(Stage, Destination) {
	Fn := IsObject(GestureScreenshotWorkerState.publish_file_fn)
		? GestureScreenshotWorkerState.publish_file_fn : _GestureScreenshotDefaultPublishFile
	return Fn.Call(Stage, Destination)
}

_GestureScreenshotPublishClipboard(Stage) {
	Fn := IsObject(GestureScreenshotWorkerState.publish_clipboard_fn)
		? GestureScreenshotWorkerState.publish_clipboard_fn : _GestureScreenshotDefaultPublishClipboard
	return Fn.Call(Stage)
}

_GestureScreenshotCleanupStage(Job) {
	PreviousCritical := Critical("On")
	try {
		if Job.Get("cleanup_claimed", false)
			return false
		Job["cleanup_claimed"] := true
	} finally {
		Critical(PreviousCritical)
	}
	Fn := IsObject(GestureScreenshotWorkerState.cleanup_stage_fn)
		? GestureScreenshotWorkerState.cleanup_stage_fn : _GestureScreenshotDefaultDeleteFile
	try return Fn.Call(Job["stage"])
	catch as Err {
		LoggerError("gestures", "Screenshot staging cleanup threw for '{1}': {2}.", Job["stage"], Err.Message)
		return false
	}
}

_GestureScreenshotRollbackFile(Destination) {
	Fn := IsObject(GestureScreenshotWorkerState.rollback_file_fn)
		? GestureScreenshotWorkerState.rollback_file_fn : _GestureScreenshotDefaultDeleteFile
	try return Fn.Call(Destination)
	catch as Err {
		LoggerError("gestures", "Canceled screenshot file rollback threw for '{1}': {2}.", Destination, Err.Message)
		return false
	}
}

_GestureScreenshotClipboardSequence() {
	Fn := IsObject(GestureScreenshotWorkerState.clipboard_sequence_fn)
		? GestureScreenshotWorkerState.clipboard_sequence_fn : _GestureScreenshotDefaultClipboardSequence
	return Fn.Call()
}

_GestureScreenshotClipboardHasImage() {
	Fn := IsObject(GestureScreenshotWorkerState.clipboard_has_image_fn)
		? GestureScreenshotWorkerState.clipboard_has_image_fn : _GestureScreenshotDefaultClipboardHasImage
	return Fn.Call()
}

_GestureScreenshotClipboardSave() {
	Fn := IsObject(GestureScreenshotWorkerState.clipboard_save_fn)
		? GestureScreenshotWorkerState.clipboard_save_fn : _GestureScreenshotDefaultClipboardSave
	return Fn.Call()
}

_GestureScreenshotRollbackClipboard(Snapshot, PublishedSequence) {
	Fn := IsObject(GestureScreenshotWorkerState.clipboard_restore_fn)
		? GestureScreenshotWorkerState.clipboard_restore_fn : _GestureScreenshotDefaultClipboardRestore
	try return Fn.Call(Snapshot, PublishedSequence)
	catch as Err {
		LoggerError("gestures", "Canceled screenshot clipboard rollback threw: {1}.", Err.Message)
		return false
	}
}





; ==========================================
; ==========================================
; ======= 2/ Shared worker lifecycle =======
; ==========================================
; ==========================================

_GestureScreenshotPowerShellArgs(Script, NeedsSta := false) {
	Args := ["-NoProfile", "-NonInteractive"]
	if NeedsSta
		Args.Push("-Sta")
	Args.Push("-WindowStyle", "Hidden", "-Command", Script)
	return Args
}

_GestureScreenshotCreateWorker(Kind, OwnerEpoch, Stage, Args, OwnerDone) {
	PreviousCritical := Critical("On")
	try WorkerId := ++GestureScreenshotWorkerState.generation
	finally Critical(PreviousCritical)
	Spawn := IsObject(GestureScreenshotWorkerState.spawn_fn)
		? GestureScreenshotWorkerState.spawn_fn : ShellRunner_SpawnTreeOwned
	try Handle := Spawn.Call("powershell.exe", Args, GestureScreenshotWorkerDone.Bind(WorkerId))
	catch as Err {
		LoggerError("gestures", "Screenshot worker construction failed ({1}): {2}.", Kind, Err.Message)
		return 0
	}
	if !IsObject(Handle) {
		LoggerError("gestures", "Screenshot worker construction returned no handle ({1}).", Kind)
		return 0
	}
	Job := Map(
		"id", WorkerId,
		"kind", Kind,
		"owner_epoch", OwnerEpoch,
		"stage", Stage,
		"handle", Handle,
		"on_done", OwnerDone,
		"worker_done", false,
		"cancel_requested", false,
		"terminate_requested", false,
		"cleanup_claimed", false)
	PreviousCritical := Critical("On")
	try GestureScreenshotWorkerState.jobs[WorkerId] := Job
	finally Critical(PreviousCritical)
	return WorkerId
}

_GestureScreenshotStartWorker(WorkerId) {
	PreviousCritical := Critical("On")
	try {
		if !GestureScreenshotWorkerState.jobs.Has(WorkerId)
			return false
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		if Job["cancel_requested"]
			return false
	} finally {
		Critical(PreviousCritical)
	}
	try Started := Job["handle"].start()
	catch as Err {
		LoggerError("gestures", "Screenshot worker start failed ({1}): {2}.", Job["kind"], Err.Message)
		return false
	}
	; A test seam or a very short process may complete synchronously from start().
	; The vanished registry entry proves that terminal already won ownership.
	PreviousCritical := Critical("On")
	try return !GestureScreenshotWorkerState.jobs.Has(WorkerId) ? true : (Started ? true : false)
	finally Critical(PreviousCritical)
}

_GestureScreenshotDiscardUnstartedWorker(WorkerId) {
	PreviousCritical := Critical("On")
	try {
		if !GestureScreenshotWorkerState.jobs.Has(WorkerId)
			return false
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		GestureScreenshotWorkerState.jobs.Delete(WorkerId)
	} finally {
		Critical(PreviousCritical)
	}
	_GestureScreenshotCleanupStage(Job)
	return true
}

GestureScreenshotCancelWorker(WorkerId, Reason) {
	PreviousCritical := Critical("On")
	try {
		if !GestureScreenshotWorkerState.jobs.Has(WorkerId)
			return false
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		if Job["cancel_requested"]
			return false
		Job["cancel_requested"] := true
		Job["cancel_reason"] := Reason
		if Job["worker_done"]
			return true
		; Claim before calling the handle: a fake or future handle may report done
		; synchronously while it processes the termination request.
		Job["terminate_requested"] := true
		Handle := Job["handle"]
	} finally {
		Critical(PreviousCritical)
	}
	Requested := false
	try Requested := Handle.requestTerminate()
	catch as Err
		LoggerError("gestures", "Screenshot worker termination threw ({1}, {2}): {3}.", Job["kind"], Reason, Err.Message)
	if !Requested {
		PreviousCritical := Critical("On")
		try {
			if GestureScreenshotWorkerState.jobs.Has(WorkerId)
				GestureScreenshotWorkerState.jobs[WorkerId]["termination_failed"] := true
		} finally {
			Critical(PreviousCritical)
		}
		LoggerError("gestures", "Screenshot worker termination request failed ({1}, {2}); publication remains fenced.", Job["kind"], Reason)
	}
	; On shutdown no AHK completion callback can run. Delete an already-written
	; stage now; a worker still inside Save performs the matching parent-death
	; cleanup in its final PowerShell statement.
	if Reason == "shutdown"
		_GestureScreenshotCleanupStage(Job)
	return Requested
}

GestureScreenshotWorkerDone(WorkerId, ExitCode, Stdout, Stderr) {
	PreviousCritical := Critical("On")
	try {
		if !GestureScreenshotWorkerState.jobs.Has(WorkerId)
			return
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		Job["worker_done"] := true
		Canceled := Job["cancel_requested"]
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if !Canceled {
			try Job["on_done"].Call(WorkerId, Job, ExitCode, Stdout, Stderr)
			catch as Err
				LoggerError("gestures", "Screenshot owner completion failed ({1}): {2}.", Job["kind"], Err.Message)
		}
	} finally {
		_GestureScreenshotCleanupStage(Job)
		PreviousCritical := Critical("On")
		try {
			if GestureScreenshotWorkerState.jobs.Has(WorkerId)
				GestureScreenshotWorkerState.jobs.Delete(WorkerId)
		} finally {
			Critical(PreviousCritical)
		}
	}
}

GestureScreenshotCancelAll(Reason := "canceled") {
	global _GestureDirectCaptures, _GestureRegionCapture
	PreviousCritical := Critical("On")
	try {
		DirectSnapshot := _GestureDirectCaptures.Clone()
		RegionEpoch := (_GestureRegionCapture is Map) ? _GestureRegionCapture["epoch"] : 0
	} finally {
		Critical(PreviousCritical)
	}
	for Epoch, _ in DirectSnapshot
		GestureDirectCaptureFinish(Epoch, false, Reason, true)
	if RegionEpoch
		GestureRegionCaptureFinish(RegionEpoch, Reason, true)
	; Cover a worker whose owner was retired re-entrantly before cancellation
	; reached the shared registry. The per-job claim prevents duplicate kills.
	PreviousCritical := Critical("On")
	try WorkerSnapshot := GestureScreenshotWorkerState.jobs.Clone()
	finally Critical(PreviousCritical)
	for WorkerId, _ in WorkerSnapshot
		GestureScreenshotCancelWorker(WorkerId, Reason)
}





; ========================================
; ========================================
; ======= 3/ Direct screen capture =======
; ========================================
; ========================================

_GestureScreenshotDirectScript(X, Y, W, H, Mode, Stage) {
	global DriverPid
	EscapedStage := StrReplace(Stage, "'", "''")
	FormatName := (Mode == "clipboard") ? "Bmp" : "Png"
	return "Add-Type -AssemblyName System.Drawing;"
		. "$bmp = New-Object System.Drawing.Bitmap " . W . "," . H . ";"
		. "$g = [System.Drawing.Graphics]::FromImage($bmp);"
		. "$g.CopyFromScreen(" . X . "," . Y . ",0,0,(New-Object System.Drawing.Size " . W . "," . H . "));"
		. "$bmp.Save('" . EscapedStage . "', [System.Drawing.Imaging.ImageFormat]::" . FormatName . ");"
		. "$g.Dispose(); $bmp.Dispose();"
		. "$parentAlive = Get-Process -Id " . DriverPid . " -ErrorAction SilentlyContinue;"
		. "if (-not $parentAlive) { Remove-Item -LiteralPath '" . EscapedStage . "' -Force -ErrorAction SilentlyContinue }"
}

GestureCaptureRegion(X, Y, W, H, Mode, Path := "", OnComplete := "") {
	global _GestureDirectCaptures, _GestureDirectCaptureEpoch, GESTURE_DIRECT_CAPTURE_TIMEOUT_MS
	global DriverPid
	Completion := IsObject(OnComplete) ? OnComplete : 0
	if (Mode != "save" && Mode != "clipboard") || W <= 0 || H <= 0
		return _GestureScreenshotRejectDirect(Completion, "invalid capture request")
	if (Mode == "save" && Path == "")
		return _GestureScreenshotRejectDirect(Completion, "save path is empty")
	if A_IsSuspended
		return _GestureScreenshotRejectDirect(Completion, "driver suspended")

	GestureScreenshotCancelAll("superseded")
	; Reserve worker and owner atomically. The spawn adapter only constructs a
	; handle here; native process creation occurs after Critical is restored.
	PreviousCritical := Critical("On")
	try {
		Epoch := ++_GestureDirectCaptureEpoch
		Extension := (Mode == "clipboard") ? "bmp" : "png"
		Stage := A_Temp . "\ergopti_screenshot_direct_" . DriverPid . "_" . Epoch . "." . Extension
		Script := _GestureScreenshotDirectScript(X, Y, W, H, Mode, Stage)
		WorkerId := _GestureScreenshotCreateWorker("direct_" . Mode, Epoch, Stage,
			_GestureScreenshotPowerShellArgs(Script), GestureDirectCaptureWorkerDone.Bind(Epoch))
		if WorkerId {
			_GestureDirectCaptures[Epoch] := Map(
				"epoch", Epoch,
				"worker_id", WorkerId,
				"mode", Mode,
				"path", Path,
				"started_tick", A_TickCount,
				"timeout_ms", GESTURE_DIRECT_CAPTURE_TIMEOUT_MS,
				"callback", Completion)
		}
	} finally {
		Critical(PreviousCritical)
	}
	if !WorkerId
		return _GestureScreenshotRejectDirect(Completion, "worker construction failed")
	if A_IsSuspended {
		GestureDirectCaptureFinish(Epoch, false, "driver suspended", true)
		_GestureScreenshotDiscardUnstartedWorker(WorkerId)
		return false
	}
	if !_GestureScreenshotStartWorker(WorkerId) {
		_GestureScreenshotDiscardUnstartedWorker(WorkerId)
		GestureDirectCaptureFinish(Epoch, false, "worker could not start")
		return false
	}
	if _GestureDirectCaptures.Has(Epoch)
		SetTimer(GestureDirectCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
	return true
}

_GestureScreenshotRejectDirect(Completion, Reason) {
	LoggerError("gestures", "Screenshot failed: {1}.", Reason)
	if IsObject(Completion) {
		try Completion.Call(false, Reason)
		catch as Err
			LoggerError("gestures", "Screenshot launch-failure callback failed: {1}.", Err.Message)
	}
	return false
}

_GestureDirectCaptureState(Epoch, WorkerId := 0) {
	global _GestureDirectCaptures
	PreviousCritical := Critical("On")
	try {
		if !_GestureDirectCaptures.Has(Epoch)
			return 0
		State := _GestureDirectCaptures[Epoch]
		if WorkerId && State["worker_id"] != WorkerId
			return 0
		return State
	} finally {
		Critical(PreviousCritical)
	}
}

GestureDirectCapturePoll(Epoch) {
	State := _GestureDirectCaptureState(Epoch)
	if !IsObject(State)
		return
	if A_IsSuspended {
		GestureDirectCaptureFinish(Epoch, false, "driver suspended", true)
		return
	}
	if TickExpired(State["started_tick"], State["timeout_ms"]) {
		GestureDirectCaptureFinish(Epoch, false, "capture timeout", true)
		return
	}
	if !GestureScreenshotWorkerState.jobs.Has(State["worker_id"]) {
		GestureDirectCaptureFinish(Epoch, false, "worker ownership disappeared")
		return
	}
	SetTimer(GestureDirectCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
}

GestureDirectCaptureWorkerDone(Epoch, WorkerId, Job, ExitCode, Stdout, Stderr) {
	State := _GestureDirectCaptureState(Epoch, WorkerId)
	if !IsObject(State) || Job["cancel_requested"]
		return
	if A_IsSuspended || TickExpired(State["started_tick"], State["timeout_ms"]) {
		GestureDirectCaptureFinish(Epoch, false,
			A_IsSuspended ? "driver suspended" : "capture timeout", true)
		return
	}
	if ExitCode != 0 || !_GestureScreenshotFileExists(Job["stage"]) {
		GestureDirectCaptureFinish(Epoch, false, "worker exited without staged output")
		return
	}

	if State["mode"] == "save" {
		DestinationExistedBefore := _GestureScreenshotFileExists(State["path"])
		Published := _GestureScreenshotPublishFile(Job["stage"], State["path"])
		DestinationExistsAfter := _GestureScreenshotFileExists(State["path"])
		OwnsDestination := !DestinationExistedBefore && DestinationExistsAfter
		if !IsObject(_GestureDirectCaptureState(Epoch, WorkerId))
				|| A_IsSuspended || Job["cancel_requested"] {
			if OwnsDestination
				_GestureScreenshotRollbackFile(State["path"])
			return
		}
		Ok := Published && DestinationExistsAfter
		if !Ok && OwnsDestination
			_GestureScreenshotRollbackFile(State["path"])
	} else {
		ClipboardSnapshot := _GestureScreenshotClipboardSave()
		if Type(ClipboardSnapshot) == "String"
				&& ClipboardSnapshot == "__CB_SAVE_ERROR__" {
			GestureDirectCaptureFinish(Epoch, false,
				"clipboard snapshot failed before publication")
			return
		}
		BeforeSequence := _GestureScreenshotClipboardSequence()
		Published := _GestureScreenshotPublishClipboard(Job["stage"])
		PublishedSequence := _GestureScreenshotClipboardSequence()
		ClipboardChanged := PublishedSequence != BeforeSequence
		if !IsObject(_GestureDirectCaptureState(Epoch, WorkerId))
				|| A_IsSuspended || Job["cancel_requested"] {
			if ClipboardChanged
				_GestureScreenshotRollbackClipboard(ClipboardSnapshot, PublishedSequence)
			return
		}
		Ok := Published && ClipboardChanged
			&& _GestureScreenshotClipboardHasImage()
		if !Ok && ClipboardChanged
			_GestureScreenshotRollbackClipboard(ClipboardSnapshot, PublishedSequence)
	}
	; Cancellation can interrupt after the validation above but before this claim.
	; Treat a lost final claim as stale publication and undo it while our clipboard
	; sequence/file destination is still the one just written by this generation.
	if !GestureDirectCaptureFinish(Epoch, Ok,
			Ok ? "" : "worker output could not be published") && Ok {
		if State["mode"] == "save" && OwnsDestination
			_GestureScreenshotRollbackFile(State["path"])
		else if State["mode"] != "save" && ClipboardChanged
			_GestureScreenshotRollbackClipboard(ClipboardSnapshot, PublishedSequence)
	}
}

GestureDirectCaptureFinish(Epoch, Ok, Reason := "", CancelWorker := false) {
	global _GestureDirectCaptures
	PreviousCritical := Critical("On")
	try {
		if !_GestureDirectCaptures.Has(Epoch)
			return false
		State := _GestureDirectCaptures[Epoch]
		_GestureDirectCaptures.Delete(Epoch)
	} finally {
		Critical(PreviousCritical)
	}
	if CancelWorker
		GestureScreenshotCancelWorker(State["worker_id"], Reason)
	Callback := State["callback"]
	if IsObject(Callback) {
		try Callback.Call(Ok, Reason)
		catch as Err
			LoggerError("gestures", "Screenshot completion callback failed: {1}.", Err.Message)
	}
	return true
}

GestureScreenshotComplete(Kind, Mode, Path, Ok, Reason := "") {
	if !Ok {
		LoggerError("gestures", "{1} screenshot failed: {2}.", Kind, Reason)
		return
	}
	if Mode == "save" {
		LoggerSuccess("gestures", "{1} screenshot saved: '{2}'.", Kind, Path)
		TrayTip(t("notify.screenshot_saved"), Path, "Iconi Mute")
	} else {
		LoggerSuccess("gestures", "{1} screenshot copied to clipboard.", Kind)
		TrayTip(t("notify.screenshot_copied"), t("notify.clipboard"), "Iconi Mute")
	}
}

GestureScreenshotWindow(Mode) {
	HWnd := WMGetFocused()["hwnd"]
	if !HWnd {
		LoggerWarn("gestures", "screenshot_window: no active window.")
		return
	}
	try WinGetPos(&X, &Y, &W, &H, "ahk_id " . HWnd)
	catch {
		LoggerWarn("gestures", "screenshot_window: WinGetPos failed.")
		return
	}
	if Mode == "save" {
		Path := GestureScreenshotPath()
		LoggerStart("gestures", "Capturing window to '{1}'…", Path)
		GestureCaptureRegion(X, Y, W, H, "save", Path,
			GestureScreenshotComplete.Bind("Window", "save", Path))
	} else {
		LoggerStart("gestures", "Capturing window to clipboard…")
		GestureCaptureRegion(X, Y, W, H, "clipboard", "",
			GestureScreenshotComplete.Bind("Window", "clipboard", ""))
	}
}

GestureScreenshotFullscreen(Mode) {
	X := SysGet(GESTURE_SM_XVIRTUALSCREEN)
	Y := SysGet(GESTURE_SM_YVIRTUALSCREEN)
	W := SysGet(GESTURE_SM_CXVIRTUALSCREEN)
	H := SysGet(GESTURE_SM_CYVIRTUALSCREEN)
	if Mode == "save" {
		Path := GestureScreenshotPath()
		LoggerStart("gestures", "Capturing fullscreen to '{1}'…", Path)
		GestureCaptureRegion(X, Y, W, H, "save", Path,
			GestureScreenshotComplete.Bind("Fullscreen", "save", Path))
	} else {
		LoggerStart("gestures", "Capturing fullscreen to clipboard…")
		GestureCaptureRegion(X, Y, W, H, "clipboard", "",
			GestureScreenshotComplete.Bind("Fullscreen", "clipboard", ""))
	}
}





; =====================================
; =====================================
; ======= 4/ Interactive region =======
; =====================================
; =====================================

GestureScreenshotRegion(Mode) {
	global _GestureRegionCapture, _GestureRegionCaptureEpoch
	if A_IsSuspended
		return
	GestureScreenshotCancelAll("superseded")
	if Mode == "clipboard" {
		LoggerStart("gestures", "Region screenshot to clipboard — opening Snip & Sketch…")
		TextPressKey("s", ["Shift", "Win"])
		LoggerSuccess("gestures", "Snip & Sketch invoked (clipboard mode).")
		return
	}
	if Mode != "save" {
		LoggerError("gestures", "Region screenshot rejected invalid mode '{1}'.", Mode)
		return
	}

	Path := GestureScreenshotPath()
	LoggerStart("gestures", "Region screenshot to disk — opening Snip & Sketch…")
	PreviousCritical := Critical("On")
	try Epoch := ++_GestureRegionCaptureEpoch
	finally Critical(PreviousCritical)
	OldClip := ""
	OwnerToken := 0
	ExpectedChange := 0
	StatePublished := false
	try {
		OldClip := CB_SaveAll()
		if (Type(OldClip) == "String" && OldClip == "__CB_SAVE_ERROR__")
			throw Error("clipboard snapshot failed")
		OwnerToken := CB_BeginOwnedTransaction("gesture_region_capture")
		if !CB_Write("")
			throw Error("clipboard clear failed")
		ExpectedChange := CB_ExpectOwnedChange()
		if A_IsSuspended
			throw Error("driver suspended before Snipping Tool launch")
		State := Map(
			"epoch", Epoch,
			"path", Path,
			"original_clipboard", OldClip,
			"clipboard_sequence", CB_GetSequenceNumber(),
			"owner_token", OwnerToken,
			"expected_change", ExpectedChange,
			"selection_started_tick", A_TickCount,
			"selection_timeout_ms", GESTURE_REGION_CAPTURE_TIMEOUT_MS,
			"save_started_tick", 0,
			"save_timeout_ms", GESTURE_REGION_CAPTURE_SAVE_TIMEOUT_MS,
			"save_started", false,
			"worker_id", 0)
		PreviousCritical := Critical("On")
		try {
			_GestureRegionCapture := State
			StatePublished := true
		} finally {
			Critical(PreviousCritical)
		}
		SendEvent("#+s")
		if A_IsSuspended {
			GestureRegionCaptureFinish(Epoch, "suspended", true)
			return
		}
		if IsObject(_GestureRegionCaptureState(Epoch))
			SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
	} catch as Err {
		if StatePublished {
			GestureRegionCaptureFinish(Epoch, "start failure", true)
		} else {
			if ExpectedChange
				CB_CancelExpectedChange(ExpectedChange)
			if OwnerToken {
				try CB_RestoreOwnedAllEventually(OldClip, CB_GetSequenceNumber(),
					OwnerToken, "gesture_region_capture_rollback", true, true)
			}
		}
		LoggerError("gestures", "Region screenshot could not start: {1}.", Err.Message)
	}
}

_GestureScreenshotRegionSaveScript(Stage) {
	global DriverPid
	EscapedStage := StrReplace(Stage, "'", "''")
	return "Add-Type -AssemblyName System.Windows.Forms;"
		. "Add-Type -AssemblyName System.Drawing;"
		. "$img = [System.Windows.Forms.Clipboard]::GetImage();"
		. "if ($img) { $img.Save('" . EscapedStage . "', [System.Drawing.Imaging.ImageFormat]::Png) };"
		. "$parentAlive = Get-Process -Id " . DriverPid . " -ErrorAction SilentlyContinue;"
		. "if (-not $parentAlive) { Remove-Item -LiteralPath '" . EscapedStage . "' -Force -ErrorAction SilentlyContinue }"
}

_GestureRegionCaptureState(Epoch, WorkerId := 0) {
	global _GestureRegionCapture
	PreviousCritical := Critical("On")
	try {
		if !(_GestureRegionCapture is Map) || _GestureRegionCapture["epoch"] != Epoch
			return 0
		State := _GestureRegionCapture
		if WorkerId && State["worker_id"] != WorkerId
			return 0
		return State
	} finally {
		Critical(PreviousCritical)
	}
}

GestureRegionCaptureStartSaveWorker(Epoch) {
	global _GestureRegionCapture, DriverPid
	PreviousCritical := Critical("On")
	try {
		if !(_GestureRegionCapture is Map) || _GestureRegionCapture["epoch"] != Epoch
			return false
		State := _GestureRegionCapture
		Stage := A_Temp . "\ergopti_screenshot_region_" . DriverPid . "_" . Epoch . ".png"
		WorkerId := _GestureScreenshotCreateWorker("region_save", Epoch, Stage,
			_GestureScreenshotPowerShellArgs(_GestureScreenshotRegionSaveScript(Stage), true),
			GestureRegionSaveWorkerDone.Bind(Epoch))
		if WorkerId {
			State["worker_id"] := WorkerId
			State["save_started"] := true
			State["save_started_tick"] := A_TickCount
		}
	} finally {
		Critical(PreviousCritical)
	}
	if !WorkerId
		return false
	if A_IsSuspended {
		GestureRegionCaptureFinish(Epoch, "suspended", true)
		_GestureScreenshotDiscardUnstartedWorker(WorkerId)
		return false
	}
	if !_GestureScreenshotStartWorker(WorkerId) {
		_GestureScreenshotDiscardUnstartedWorker(WorkerId)
		return false
	}
	return true
}

GestureRegionCapturePoll(Epoch) {
	State := _GestureRegionCaptureState(Epoch)
	if !IsObject(State)
		return
	if A_IsSuspended {
		GestureRegionCaptureFinish(Epoch, "suspended", true)
		return
	}

	if !State["save_started"] {
		if TickExpired(State["selection_started_tick"], State["selection_timeout_ms"]) {
			LoggerWarn("gestures", "Region screenshot: no image captured (timeout or cancel).")
			GestureRegionCaptureFinish(Epoch, "selection timeout", true)
			return
		}
		if !ClipWait(GESTURE_REGION_CLIPWAIT_PROBE_SEC,
				GESTURE_REGION_CLIPWAIT_IMAGE_MODE) || !CB_HasImage() {
			SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
			return
		}
		; ClipWait and clipboard probes can yield. Revalidate the epoch before
		; mutating state so an intervening supersession cannot be resurrected.
		State := _GestureRegionCaptureState(Epoch)
		if !IsObject(State)
			return
		PreviousCritical := Critical("On")
		try {
			if IsObject(_GestureRegionCaptureState(Epoch))
				State["clipboard_sequence"] := CB_GetSequenceNumber()
		} finally {
			Critical(PreviousCritical)
		}
		if !GestureRegionCaptureStartSaveWorker(Epoch) {
			LoggerError("gestures", "Region screenshot save worker could not start.")
			GestureRegionCaptureFinish(Epoch, "save launch failure", true)
			return
		}
		SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
		return
	}

	if TickExpired(State["save_started_tick"], State["save_timeout_ms"]) {
		LoggerWarn("gestures", "Region screenshot: clipboard image was not saved.")
		GestureRegionCaptureFinish(Epoch, "save timeout", true)
		return
	}
	if !GestureScreenshotWorkerState.jobs.Has(State["worker_id"]) {
		GestureRegionCaptureFinish(Epoch, "save worker ownership disappeared")
		return
	}
	SetTimer(GestureRegionCapturePoll.Bind(Epoch), -GESTURE_REGION_CAPTURE_POLL_MS)
}

GestureRegionSaveWorkerDone(Epoch, WorkerId, Job, ExitCode, Stdout, Stderr) {
	State := _GestureRegionCaptureState(Epoch, WorkerId)
	if !IsObject(State) || Job["cancel_requested"]
		return
	if A_IsSuspended || TickExpired(State["save_started_tick"], State["save_timeout_ms"]) {
		GestureRegionCaptureFinish(Epoch,
			A_IsSuspended ? "suspended" : "save timeout", true)
		return
	}
	if ExitCode != 0 || !_GestureScreenshotFileExists(Job["stage"]) {
		LoggerError("gestures", "Region screenshot save worker produced no staged image.")
		GestureRegionCaptureFinish(Epoch, "save worker failed")
		return
	}

	DestinationExistedBefore := _GestureScreenshotFileExists(State["path"])
	Published := _GestureScreenshotPublishFile(Job["stage"], State["path"])
	DestinationExistsAfter := _GestureScreenshotFileExists(State["path"])
	OwnsDestination := !DestinationExistedBefore && DestinationExistsAfter
	if !IsObject(_GestureRegionCaptureState(Epoch, WorkerId))
			|| A_IsSuspended || Job["cancel_requested"] {
		if OwnsDestination
			_GestureScreenshotRollbackFile(State["path"])
		return
	}
	if !Published || !DestinationExistsAfter {
		if OwnsDestination
			_GestureScreenshotRollbackFile(State["path"])
		LoggerError("gestures", "Region screenshot staging file could not be published.")
		GestureRegionCaptureFinish(Epoch, "save publication failed")
		return
	}
	if !GestureRegionCaptureFinish(Epoch, "saved") {
		_GestureScreenshotRollbackFile(State["path"])
		return
	}
	LoggerSuccess("gestures", "Region screenshot saved: '{1}'.", State["path"])
	TrayTip(t("notify.screenshot_saved"), State["path"], "Iconi Mute")
}

GestureRegionCaptureFinish(Epoch, Reason, CancelWorker := false) {
	global _GestureRegionCapture
	PreviousCritical := Critical("On")
	try {
		if !(_GestureRegionCapture is Map) || _GestureRegionCapture["epoch"] != Epoch
			return false
		State := _GestureRegionCapture
		_GestureRegionCapture := false
	} finally {
		Critical(PreviousCritical)
	}
	if CancelWorker && State.Get("worker_id", 0)
		GestureScreenshotCancelWorker(State["worker_id"], Reason)
	if State.Get("expected_change", 0)
		CB_CancelExpectedChange(State["expected_change"])
	OwnedSequence := State.Get("clipboard_sequence", 0)
	if !CB_RestoreOwnedAllEventually(State["original_clipboard"], OwnedSequence,
			State.Get("owner_token", 0), "gesture_region_capture_" . Reason,
			true, !OwnedSequence)
		LoggerWarn("gestures",
			"Region screenshot clipboard restore is pending after a transient failure ({1}).",
			Reason)
	return true
}
