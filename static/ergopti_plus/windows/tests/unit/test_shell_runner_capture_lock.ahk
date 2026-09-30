; tests/unit/test_shell_runner_capture_lock.ahk

; ==============================================================================
; MODULE: Shell Capture Lock Tests
; DESCRIPTION:
; Opening the versions window logged "tree-owned task 12 output deletion
; failed: (32)": another process still held the capture of a task whose whole
; tree had exited. Every launch passed its child all the driver's inheritable
; handles, including the capture of a task launching in the same window. Pin
; the exact inheritance of a launch.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../support/filesystem_write_lock.ahk

; Win32 values the fixtures pass themselves, independent of the adapter's own
global SRCL_EXTENDED_STARTUPINFO_PRESENT := 0x00080000
global SRCL_DUPLICATE_SAME_ACCESS := 0x00000002
global SRCL_GENERIC_WRITE := 0x40000000
global SRCL_SHARE_READ_WRITE := 3
global SRCL_CREATE_ALWAYS := 2





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
