; tests/unit/test_shell_runner_capture_lock.ahk

; ==============================================================================
; MODULE: Shell Capture Lock Tests
; DESCRIPTION:
; Opening the versions window logged "tree-owned task 12 output deletion
; failed: (32)": another process still held the capture of a task whose whole
; tree had exited. Every launch passed its child all the driver's inheritable
; handles, including the capture of a task launching in the same window, and a
; refused deletion was an ERROR that dropped the file. Pin the exact inheritance
; of a launch, then the retained, bounded and swept capture cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../support/filesystem_write_lock.ahk

; Win32 values the fixtures pass themselves, independent of the adapter's own
global SRCL_ERROR_SHARING_VIOLATION := 32
global SRCL_EXTENDED_STARTUPINFO_PRESENT := 0x00080000
global SRCL_DUPLICATE_SAME_ACCESS := 0x00000002
global SRCL_GENERIC_READ := 0x80000000
global SRCL_GENERIC_WRITE := 0x40000000
global SRCL_SHARE_READ_WRITE := 3
global SRCL_CREATE_ALWAYS := 2
global SRCL_OPEN_EXISTING := 3
; Windows assigns process IDs in multiples of four, so no process owns this one
global SRCL_DEAD_OWNER_PID := 2147483647





; ================================
; ================================
; ======= 1/ Shared probes =======
; ================================
; ================================

; Opens Path the way a task's capture stands while that task launches: an
; inheritable handle shared for reading and writing, never for deletion.
_SRCL_OpenCaptureLikeHandle(Path, Access, Disposition) {
	Security := Buffer(A_PtrSize = 8 ? 24 : 12, 0)
	NumPut("UInt", Security.Size, Security, 0)
	NumPut("Int", true, Security, A_PtrSize = 8 ? 16 : 8)
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", Access,
		"UInt", SRCL_SHARE_READ_WRITE, "Ptr", Security.Ptr, "UInt", Disposition,
		"UInt", 0x80, "Ptr", 0, "Ptr")
	if Handle = -1 || Handle = 0
		throw OSError(A_LastError, "CreateFileW")
	return Handle
}

; Whether the child's handle table holds, at Value, the very object Value names
; in this process: an inherited handle keeps its value in the child.
_SRCL_ChildHolds(ChildProcess, Value) {
	Copy := 0
	if !DllCall("Kernel32\DuplicateHandle", "Ptr", ChildProcess, "Ptr", Value,
			"Ptr", DllCall("Kernel32\GetCurrentProcess", "Ptr"), "Ptr*", &Copy,
			"UInt", 0, "Int", false, "UInt", SRCL_DUPLICATE_SAME_ACCESS, "Int")
		return false
	try return DllCall("KernelBase\CompareObjectHandles", "Ptr", Copy, "Ptr", Value, "Int") != 0
	finally DllCall("Kernel32\CloseHandle", "Ptr", Copy, "Int")
}

; Captures every line the logger emits, all levels on, until _SRCL_EndLog.
_SRCL_BeginLog() {
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	Context := {Lines: [], Saved: [_LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED,
		_LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED]}
	_LOGGER_DEBUG_ENABLED := true
	_LOGGER_INFO_ENABLED := true
	_LOGGER_WARN_ENABLED := true
	_LOGGER_ERROR_ENABLED := true
	LoggerSetTestSink(_SRCL_Collect.Bind(Context.Lines))
	return Context
}

_SRCL_Collect(Lines, Line) {
	Lines.Push(Line)
}

_SRCL_EndLog(Context) {
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	LoggerClearTestSink()
	_LOGGER_DEBUG_ENABLED := Context.Saved[1]
	_LOGGER_INFO_ENABLED := Context.Saved[2]
	_LOGGER_WARN_ENABLED := Context.Saved[3]
	_LOGGER_ERROR_ENABLED := Context.Saved[4]
}

; Counts the shell runner's lines at Level whose text contains Needle.
_SRCL_Count(Lines, Level, Needle := "") {
	Count := 0
	for Line in Lines {
		if InStr(Line, "[" . Level . "] [adapters.shell_runner]")
			&& (Needle = "" || InStr(Line, Needle))
			Count += 1
	}
	return Count
}

; A finished tree-owned claim as the poller hands it to _SR_TreeFinishClaim:
; its empty native bundle settled, Output waiting in its private capture.
_SRCL_FinishedTreeClaim(Output, OnDone) {
	global _SR_TaskCounter
	CaptureDir := _SR_AcquireCaptureDirectory()
	FileAppend(Output, CaptureDir . "output.tmp", "UTF-8-RAW")
	Claim := Map("ProcessHandle", 0, "ThreadHandle", 0, "JobHandle", 0,
		"Assigned", false, "TreeQuiesced", false, "NativeErrors", [],
		"TaskId", ++_SR_TaskCounter, "TmpFile", CaptureDir . "output.tmp",
		"CaptureDir", CaptureDir, "MaxOutputBytes", 0, "ExitCode", 0)
	_SR_CompletionInitClaim(Claim, _SR_CompletionNewToken(OnDone))
	AssertTrue(_SR_TreeQuiesceNative(Claim, false),
		"a claim owning no process settles its empty native bundle")
	return Claim
}

; Retries the retained captures until Claim's is gone, for at most half the
; lock budget: a scanner may still open the fixture's freshly written file.
_SRCL_DrainUntilReleased(Claim, DeleteFn) {
	Started := A_TickCount
	loop {
		_SR_TreeDrainCaptureDebts(DeleteFn)
		if !_SR_TreeCaptureDebts.Has(ObjPtr(Claim))
			|| TickElapsed(Started) >= SR_CAPTURE_LOCK_BUDGET_MS // 2
			return
		Sleep(SRTOW_PID_POLL_MS)
	}
}

_SRCL_DropTreeClaim(Claim) {
	if !(Claim is Map)
		return
	if _SR_TreeCaptureDebts.Has(ObjPtr(Claim))
		_SR_TreeCaptureDebts.Delete(ObjPtr(Claim))
	_SRTLC_DeleteCapture(Claim["TmpFile"])
	if DirExist(Claim["CaptureDir"])
		DirDelete(Claim["CaptureDir"])
}





; ===================================================
; ===================================================
; ======= 2/ A launch passes only its streams =======
; ===================================================
; ===================================================

; Another task's capture is open, inheritable, while this launch runs: exactly
; the window in which a driver thread started a second task. The child must
; receive its own streams and nothing else, and no driver thread may interleave.
_SRCL_LaunchPassesOnlyItsStreams(OwnTree) {
	CanaryPath := _FSWL_Path()
	CapturePath := _FSWL_Path()
	Canary := _SRCL_OpenCaptureLikeHandle(CanaryPath, SRCL_GENERIC_WRITE, SRCL_CREATE_ALWAYS)
	Seen := {Created: false, Critical: false, Extended: false, OwnOutput: false,
		Canary: false, ProbeError: ""}
	Observe(Application, Command, Flags, Startup, ProcessInfo) {
		Seen.Critical := A_IsCritical != 0
		Seen.Extended := (Flags & SRCL_EXTENDED_STARTUPINFO_PRESENT) != 0
		PLC_CreateProcessWithInheritedHandles(Application, Command, Flags, Startup, ProcessInfo)
		Seen.Created := true
		; A throw here would read as a failed creation and orphan the child
		try {
			Child := NumGet(ProcessInfo, 0, "Ptr")
			Seen.OwnOutput := _SRCL_ChildHolds(Child, NumGet(Startup, A_PtrSize = 8 ? 88 : 60, "Ptr"))
			Seen.Canary := _SRCL_ChildHolds(Child, Canary)
		} catch as Err
			Seen.ProbeError := Err.Message
	}
	Owner := 0
	PreviousCritical := Critical("Off")
	try {
		Owner := _SR_TreeCreateSuspended(A_ComSpec, '"' . A_ComSpec . '" /d /c exit 0',
			CapturePath, OwnTree, Observe)
	} finally {
		Critical(PreviousCritical)
		try {
			if Owner is Map
				AssertTrue(_SR_TreeQuiesceNative(Owner, true), "the suspended probe child must stop")
		} finally {
			DllCall("Kernel32\CloseHandle", "Ptr", Canary, "Int")
			_SRTLC_DeleteCapture(CanaryPath)
			_SRTLC_DeleteCapture(CapturePath)
		}
	}
	AssertTrue(Seen.Created, "the launch must reach the observed native creator")
	AssertEqual("", Seen.ProbeError, "the inheritance probe must run")
	AssertTrue(Seen.OwnOutput,
		"positive control: the child must hold its own capture handle, or the probe cannot see inheritance")
	AssertFalse(Seen.Canary,
		"a launch must not hand its child another task's capture: that copy keeps the capture locked after the other task's tree has exited")
	AssertTrue(Seen.Extended, "the launch must name the inherited handles in an explicit list")
	AssertTrue(Seen.Critical, "no driver thread may launch while this launch's inheritable streams are open")
}
for SRCL_OwnTree in [true, false]
	Test("shell runner: a launch passes its child only its own streams tree=" . SRCL_OwnTree
		. " (shell-capture-lock)", _SRCL_LaunchPassesOnlyItsStreams.Bind(SRCL_OwnTree))





; =============================================
; =============================================
; ======= 3/ A held capture is retained =======
; =============================================
; =============================================

; Mode "stub" refuses DeleteFileW twice with ERROR_SHARING_VIOLATION; mode
; "handle" holds the capture open without FILE_SHARE_DELETE, as a leaked copy
; or a scanner does. Completion is delivered at once, removal is retried by the
; poller, and nothing reaches the ERROR level.
_SRCL_TreeHeldCaptureIsRetained(Mode) {
	Results := []
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output})
	}
	Refusals := 0
	RefuseTwice(Path) {
		if Refusals < 2 {
			Refusals += 1
			DllCall("Kernel32\SetLastError", "UInt", SRCL_ERROR_SHARING_VIOLATION)
			return false
		}
		return DllCall("Kernel32\DeleteFileW", "WStr", Path, "Int")
	}
	DeleteFn := Mode = "stub" ? RefuseTwice : 0
	Lock := 0, Log := 0, Claim := 0
	PreviousCritical := Critical("On")
	try {
		Claim := _SRCL_FinishedTreeClaim("captured output", OnDone)
		if Mode = "handle"
			Lock := _SRCL_OpenCaptureLikeHandle(Claim["TmpFile"], SRCL_GENERIC_READ, SRCL_OPEN_EXISTING)
		Log := _SRCL_BeginLog()
		AssertTrue(_SR_TreeFinishClaim(Claim, 0, DeleteFn))
		AssertEqual(1, Results.Length, "a held capture must not delay the completion")
		AssertEqual("captured output", Results[1].Output)
		AssertTrue(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "the held capture must stay owned for a retry")
		AssertTrue(FileExist(Claim["TmpFile"]) != "")
		AssertTrue(_SR_TreePollRunning, "a retained capture must keep the tree poller armed")
		if Mode = "stub" {
			_SR_TreeDrainCaptureDebts(DeleteFn)
			AssertTrue(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)),
				"a second refusal within the budget keeps the debt")
		} else {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int"))
			Lock := 0
		}
		_SRCL_DrainUntilReleased(Claim, DeleteFn)
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "the released capture must retire its debt")
		AssertFalse(FileExist(Claim["TmpFile"]) != "")
		AssertFalse(DirExist(Claim["CaptureDir"]) != "")
		AssertEqual(1, Results.Length, "a cleanup retry never delivers the completion again")
	} finally {
		if IsObject(Log)
			_SRCL_EndLog(Log)
		if Lock
			DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int")
		_SRCL_DropTreeClaim(Claim)
		Critical(PreviousCritical)
	}
	AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"),
		"a capture another process holds is not an error: " . _DescribeValue(Log.Lines))
	AssertEqual(0, _SRCL_Count(Log.Lines, "WARNING"), "a lock released within the budget needs no warning")
	AssertEqual(1, _SRCL_Count(Log.Lines, "DEBUG", "is held by another process (Win32 32)"),
		"the first refusal is traced once")
	AssertEqual(1, _SRCL_Count(Log.Lines, "DEBUG", "capture removed"),
		"the delayed removal is traced once")
}
for SRCL_Mode in ["stub", "handle"]
	Test("shell runner: a held tree capture is retained, not an error mode=" . SRCL_Mode
		. " (shell-capture-lock)", _SRCL_TreeHeldCaptureIsRetained.Bind(SRCL_Mode))

; A lock outliving the budget is handed to the next start's sweep with exactly
; one warning, and the poller stops retrying it.
_SRCL_TreeHeldCaptureOutlivesBudget() {
	Calls := 0
	AlwaysRefuse(Path) {
		Calls += 1
		DllCall("Kernel32\SetLastError", "UInt", SRCL_ERROR_SHARING_VIOLATION)
		return false
	}
	Results := []
	OnDone(Code, *) {
		Results.Push(Code)
	}
	Log := 0, Claim := 0
	PreviousCritical := Critical("On")
	try {
		Claim := _SRCL_FinishedTreeClaim("captured output", OnDone)
		Log := _SRCL_BeginLog()
		AssertTrue(_SR_TreeFinishClaim(Claim, 0, AlwaysRefuse))
		AssertEqual(1, Results.Length, "a held capture must not delay the completion")
		AssertTrue(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)))
		Claim["CaptureLockSince"] -= SR_CAPTURE_LOCK_BUDGET_MS
		_SR_TreeDrainCaptureDebts(AlwaysRefuse)
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)),
			"an exhausted budget hands the capture to the next start's sweep")
		CallsAfterBudget := Calls
		_SR_TreeDrainCaptureDebts(AlwaysRefuse)
		AssertEqual(CallsAfterBudget, Calls, "an abandoned capture is no longer retried")
		AssertTrue(FileExist(Claim["TmpFile"]) != "", "the held capture is left in place for the sweep")
	} finally {
		if IsObject(Log)
			_SRCL_EndLog(Log)
		_SRCL_DropTreeClaim(Claim)
		Critical(PreviousCritical)
	}
	AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"), "a held capture is never an error")
	AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "the next start's sweep removes it"),
		"an exhausted budget warns exactly once: " . _DescribeValue(Log.Lines))
	AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", Claim["CaptureDir"]),
		"the warning names the folder a Windows handle check must look at")
}
Test("shell runner: a tree capture held past its budget warns once (shell-capture-lock)",
	_SRCL_TreeHeldCaptureOutlivesBudget)

_SRCL_CaptureBudgetCrossesDwordBoundary() {
	Claim := Map("TmpFile", "private-wrap-fixture", "CaptureDir", "private-wrap-directory")
	Origin := 0xFFFFFFF0
	BeforeExpiry := Origin + SR_CAPTURE_LOCK_BUDGET_MS - 1
	AtExpiry := Origin + SR_CAPTURE_LOCK_BUDGET_MS
	Log := _SRCL_BeginLog()
	try {
		AssertEqual("retry", _SR_CaptureSettle(Claim, SRCL_ERROR_SHARING_VIOLATION, "native crossing fixture", Origin))
		AssertEqual(Origin, Claim["CaptureLockSince"])
		AssertEqual("retry", _SR_CaptureSettle(Claim, SRCL_ERROR_SHARING_VIOLATION, "native crossing fixture", BeforeExpiry))
		AssertEqual("abandoned", _SR_CaptureSettle(Claim, SRCL_ERROR_SHARING_VIOLATION, "native crossing fixture", AtExpiry),
			"capture-budget-tick-wrap: a locked capture cannot keep its poller past the budget")
	} finally _SRCL_EndLog(Log)
	AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"))
	AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "the next start's sweep removes it"))
}
Test("shell runner capture-budget-tick-wrap: native age crosses DWORD boundary without truncation",
	_SRCL_CaptureBudgetCrossesDwordBoundary)

; The legacy poller shares the policy: a held capture defers the release within
; the budget, then releases it to the sweep with one warning and no error.
_SRCL_LegacyHeldCaptureIsNotAnError() {
	global _SR_TaskCounter
	CaptureDir := _SR_AcquireCaptureDirectory()
	CapturePath := CaptureDir . "output.tmp"
	Lock := 0, Claim := 0, Log := 0
	Calls := []
	OnDone(Code, Output, Diagnostic) {
		Calls.Push(Code)
	}
	PreviousCritical := Critical("On")
	try {
		FileAppend("captured output", CapturePath, "UTF-8-RAW")
		Lock := _SRCL_OpenCaptureLikeHandle(CapturePath, SRCL_GENERIC_READ, SRCL_OPEN_EXISTING)
		State := _SR_LegacyNewState(++_SR_TaskCounter, CapturePath, OnDone)
		State["CaptureDir"] := CaptureDir
		_SR_LegacyBeginStart(State)
		AssertTrue(_SR_LegacyPublishStart(State, 424242)["Published"])
		Claim := _SR_LegacyClaimCompletion(State["TaskId"], State)
		Log := _SRCL_BeginLog()
		AssertTrue(_SR_LegacyFinishCompletion(Claim, 37))
		AssertEqual(1, Calls.Length)
		AssertTrue(Claim["CapturePending"], "a held capture stays pending within the budget")
		AssertFalse(_SR_LegacyDrainReleases(), "the pending capture still defers the release")
		Claim["CaptureLockSince"] -= SR_CAPTURE_LOCK_BUDGET_MS
		AssertTrue(_SR_LegacyDrainReleases(), "an exhausted budget releases the claim to the sweep")
		AssertFalse(Claim["CapturePending"])
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertTrue(FileExist(CapturePath) != "", "the held capture is left in place for the sweep")
		AssertEqual(1, Calls.Length, "cleanup never delivers the completion again")
	} finally {
		if IsObject(Log)
			_SRCL_EndLog(Log)
		if Lock
			DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int")
		if IsObject(Claim) && _SR_LegacyReleaseOwners.Has(ObjPtr(Claim))
			_SR_LegacyReleaseOwners.Delete(ObjPtr(Claim))
		_SRTLC_DeleteCapture(CapturePath)
		if DirExist(CaptureDir)
			DirDelete(CaptureDir)
		Critical(PreviousCritical)
	}
	AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"),
		"a legacy capture another process holds is not an error: " . _DescribeValue(Log.Lines))
	AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "the next start's sweep removes it"))
}
Test("shell runner: a held legacy capture is not an error (shell-capture-lock)",
	_SRCL_LegacyHeldCaptureIsNotAnError)





; ====================================================
; ====================================================
; ======= 4/ The next start sweeps dead owners =======
; ====================================================
; ====================================================

_SRCL_SweepRemovesOnlyDeadOwnersFolders() {
	Root := _FSWL_Path() . ".sweep"
	OwnPid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	Dead := Root . "\" . SR_CAPTURE_DIR_PREFIX . SRCL_DEAD_OWNER_PID . "_1"
	Held := Root . "\" . SR_CAPTURE_DIR_PREFIX . SRCL_DEAD_OWNER_PID . "_2"
	Live := Root . "\" . SR_CAPTURE_DIR_PREFIX . OwnPid . "_1"
	Unrelated := Root . "\" . SR_CAPTURE_DIR_PREFIX . "notes"
	Lock := 0, Log := 0
	AssertEqual(0, ProcessExist(SRCL_DEAD_OWNER_PID), "the fixture owner PID must name no process")
	try {
		for Folder in [Dead, Held, Live, Unrelated] {
			DirCreate(Folder)
			FileAppend("left behind", Folder . "\output.tmp", "UTF-8-RAW")
		}
		Lock := _SRCL_OpenCaptureLikeHandle(Held . "\output.tmp", SRCL_GENERIC_READ, SRCL_OPEN_EXISTING)
		Log := _SRCL_BeginLog()
		try First := _SR_CaptureSweepStale(Root, OwnPid)
		finally _SRCL_EndLog(Log)
		AssertEqual(1, First["removed"], "the dead owner's folder must be removed")
		AssertEqual(1, First["kept"], "a folder another process still holds must be kept")
		AssertFalse(DirExist(Dead) != "")
		AssertTrue(FileExist(Held . "\output.tmp") != "")
		AssertTrue(FileExist(Live . "\output.tmp") != "", "this process's own folder is never swept")
		AssertTrue(FileExist(Unrelated . "\output.tmp") != "", "a folder the adapter did not name is ignored")
		Second := _SR_CaptureSweepStale(Root, 0)
		AssertEqual(0, Second["removed"], "a live owner's folder waits for a later start")
		AssertTrue(FileExist(Live . "\output.tmp") != "")
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int"))
		Lock := 0
		Third := _SR_CaptureSweepStale(Root, OwnPid)
		AssertEqual(1, Third["removed"], "the released folder goes at the next sweep")
		AssertEqual(0, Third["kept"])
		AssertFalse(DirExist(Held) != "")
	} finally {
		if Lock
			DllCall("Kernel32\CloseHandle", "Ptr", Lock, "Int")
		if DirExist(Root)
			DirDelete(Root, true)
	}
	AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"), "a stale folder is never an error")
	AssertEqual(1, _SRCL_Count(Log.Lines, "INFO", "Removed 1 capture folder(s)"))
	AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "could not be removed"),
		"a held stale folder warns once per sweep: " . _DescribeValue(Log.Lines))
}
Test("shell runner: the capture sweep removes only exited owners' folders (shell-capture-lock)",
	_SRCL_SweepRemovesOnlyDeadOwnersFolders)





; =================================================
; =================================================
; ======= 5/ Removal stays inside its claim =======
; =================================================
; =================================================

; A scanner may briefly hold a newly closed file; retry only that known native
; refusal. The test still fails if cleanup never reaches the requested outcome.
_SRCL_RemoveUntilOutcome(Capture, Expected) {
	Started := A_TickCount
	loop {
		Refusal := _SR_CaptureRemove(Capture)
		if (Refusal == Expected)
			return Refusal
		Assert(TickElapsed(Started) < SR_CAPTURE_LOCK_BUDGET_MS,
			"native capture removal must settle its bounded transient refusal")
		Sleep(SRTOW_PID_POLL_MS)
	}
}

_SRCL_RemovalKeepsOtherOwners(Nonempty) {
	Owned := _SR_AcquireCaptureDirectory()
	Other := _SR_AcquireCaptureDirectory()
	Output := Owned . "output.tmp"
	OtherOutput := Other . "output.tmp"
	Canary := Owned . "keep.txt"
	try {
		FileAppend("owned output", Output, "UTF-8-RAW")
		FileAppend("other owner", OtherOutput, "UTF-8-RAW")
		if Nonempty
			FileAppend("unclaimed file", Canary, "UTF-8-RAW")
		Capture := Map("TmpFile", Output, "CaptureDir", Owned)
		Expected := Nonempty ? SR_ERROR_DIR_NOT_EMPTY : 0
		AssertEqual(Expected, _SRCL_RemoveUntilOutcome(Capture, Expected))
		AssertFalse(FileExist(Output) != "", "only the claimed output is removed")
		AssertTrue(Capture.Get("CaptureFileRemoved", false), "the claim records its completed file removal")
		AssertEqual("other owner", FileRead(OtherOutput, "UTF-8"), "the adjacent owner stays byte-exact")
		if Nonempty {
			AssertEqual("unclaimed file", FileRead(Canary, "UTF-8"), "removal never recursively deletes an unclaimed file")
			Assert(DirExist(Owned), "a nonempty capture directory is retained for recovery")
		} else
			AssertFalse(DirExist(Owned) != "", "the empty claimed directory is removed")
	} finally {
		_SRTLC_DeleteCapture(Output)
		_SRTLC_DeleteCapture(Canary)
		_SRTLC_DeleteCapture(OtherOutput)
		if DirExist(Owned)
			DirDelete(Owned)
		if DirExist(Other)
			DirDelete(Other)
	}
}
Test("shell runner: capture removal keeps an adjacent owner's output",
	_SRCL_RemovalKeepsOtherOwners.Bind(false))
Test("shell runner: capture removal keeps an unclaimed file in its directory",
	_SRCL_RemovalKeepsOtherOwners.Bind(true))


; The capture policy stores an unmasked native origin on its first refusal.
; These claims own no path or native resource; only policy and log effects run.
_SRCL_Native64Budget(Elapsed, Expected) {
	static Serial := 0
	Serial += 1
	Owner := "native64 capture budget " . Serial
	Claim := Map("TmpFile", "unopened owned capture", "CaptureDir", "unopened owned directory")
	Log := _SRCL_BeginLog()
	try {
		Before := A_TickCount
		AssertEqual("retry", _SR_CaptureSettle(Claim, 32, Owner))
		After := A_TickCount
		Origin := Claim["CaptureLockSince"]
		Assert(Origin >= Before && Origin <= After, "the actual owner must publish a native64 origin")
		AssertEqual(32, Claim["CaptureLockCode"], "the first refusal code remains owned")
		AssertEqual(Expected, _SR_CaptureSettle(Claim, 33, Owner, Origin + Elapsed),
			"a legal full native age must exhaust the literal capture budget")
		AssertEqual(Origin, Claim["CaptureLockSince"], "later refusals never renew the origin")
		AssertEqual(32, Claim["CaptureLockCode"], "later refusals never replace the first code")
		AssertEqual(Expected == "abandoned" ? 1 : 0,
			_SRCL_Count(Log.Lines, "WARNING", "the next start's sweep removes it"),
			"bounded lock warning: " . _DescribeValue(Log.Lines))
		if Expected == "abandoned" {
			AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "after " . Elapsed . " ms"),
				"the warning retains the complete elapsed age")
			AssertEqual(1, _SRCL_Count(Log.Lines, "WARNING", "Win32 33"),
				"the warning describes the current refusal without changing its owned first code")
		}
		AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"))
	} finally _SRCL_EndLog(Log)
}

_SRCL_Native64RemovalDuration(Elapsed) {
	static Serial := 0
	Serial += 1
	Owner := "native64 capture removal " . Serial
	Claim := Map("TmpFile", "unopened owned capture")
	Log := _SRCL_BeginLog()
	try {
		AssertEqual("retry", _SR_CaptureSettle(Claim, 32, Owner))
		Origin := Claim["CaptureLockSince"]
		AssertEqual("done", _SR_CaptureSettle(Claim, 0, Owner, Origin + Elapsed),
			"successful removal always wins over elapsed budget")
		AssertEqual(1, _SRCL_Count(Log.Lines, "DEBUG", "capture removed " . Elapsed . " ms"),
			"recovered capture diagnostics retain the full native age: " . _DescribeValue(Log.Lines))
		AssertEqual(0, _SRCL_Count(Log.Lines, "WARNING"))
		AssertEqual(0, _SRCL_Count(Log.Lines, "ERROR"))
	} finally _SRCL_EndLog(Log)
}

_SRCL_Native64UnlockedRemoval() {
	Claim := Map("TmpFile", "unopened owned capture")
	Log := _SRCL_BeginLog()
	try {
		AssertEqual("done", _SR_CaptureSettle(Claim, 0, "native64 unlocked capture"))
		AssertFalse(Claim.Has("CaptureLockSince"), "unrefused removal creates no retry debt")
		AssertEqual(0, Log.Lines.Length, "unrefused removal emits no lock diagnostic")
	} finally _SRCL_EndLog(Log)
}

Test("shell capture native64: before literal budget (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(4999, "retry"))
Test("shell capture native64: exact literal budget (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(5000, "abandoned"))
Test("shell capture native64: after literal budget (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(5001, "abandoned"))
Test("shell capture native64: full cycle cannot renew debt (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(4294967296, "abandoned"))
Test("shell capture native64: cycle before remainder budget (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(4294972295, "abandoned"))
Test("shell capture native64: cycle exact remainder budget (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(4294972296, "abandoned"))
Test("shell capture native64: two full cycles cannot renew debt (shell-capture-native64)",
	_SRCL_Native64Budget.Bind(8589934592, "abandoned"))
Test("shell capture native64: short recovered duration (shell-capture-native64)",
	_SRCL_Native64RemovalDuration.Bind(5001))
Test("shell capture native64: full recovered duration (shell-capture-native64)",
	_SRCL_Native64RemovalDuration.Bind(4294972297))
Test("shell capture native64: unrefused removal owns no debt (shell-capture-native64)",
	_SRCL_Native64UnlockedRemoval)
