; tests/meta/test_layout_poll_native_arming.ahk

; ==============================================================================
; MODULE: Native Layout Poll Arming Regression
; DESCRIPTION:
; Startup smoke exits before the live layout timer is armed. Execute the actual
; source arming statements in an owned child with a recording callback so a
; disabled timer cannot pass readiness qualification. No layout or hook is read.
; ==============================================================================

#Requires AutoHotkey v2.0

; Source helpers preserve the owner statements if the entry file moves. Anchored
; executable rows reject comment markers and ambiguous duplicate owners.
_LPNA_Statements(Source) {
	AssertTrue(Source != "", "the actual driver source is required")
	Declarations := [], Arms := []
	for Line in StrSplit(Source, "`n", "`r") {
		if RegExMatch(Line, "^global _LAYOUT_POLL_INTERVAL_MS := [0-9]+$")
			Declarations.Push(Line)
		if RegExMatch(Line, "^SetTimer\(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS\)$")
			Arms.Push(Line)
	}
	AssertEqual(1, Declarations.Length, "one executable layout cadence owner is required")
	AssertEqual(1, Arms.Length, "one executable layout timer arming owner is required")
	return Declarations[1] . "`n" . Arms[1] . "`n"
}

; CreateProcess returns the exact native handles directly; teardown never kills
; or waits on a PID that Windows could recycle. This child cannot spawn workers.
_LPNA_RunChild(Statements) {
	Guid := Buffer(16)
	if DllCall("Ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
		throw Error("The layout fixture could not obtain an exclusive identity.")
	GuidText := Buffer(78)
	DllCall("Ole32\StringFromGUID2", "Ptr", Guid, "Ptr", GuidText, "Int", 39)
	; Exercise a legal backtick escape sequence in every owned child path.
	Root := A_Temp . "\ergopti-layout-arming-``n-" . StrGet(GuidText)
	AssertFalse(DirExist(Root), "the fixture root must be exclusively new")
	DirCreate(Root)
	Script := Root . "\probe.ahk", Receipt := Root . "\receipt.txt", ErrorReceipt := Root . "\error.txt"
	ReceiptLiteral := StrReplace(Receipt, Chr(96), Chr(96) . Chr(96))
	Code := '#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#ErrorStdOut`n'
	Code .= 'global Observed := 0`nCheckKeyboardLayoutChange() {`n global Observed`n Observed += 1`n}`n'
	; Relative ASCII error receipt avoids a second embedded-path dependency.
	Code .= 'OnError(_LPNA_ChildError)`n_LPNA_ChildError(Err, *) {`n try FileAppend(SubStr(Err.Message, 1, 1024), "error.txt", "UTF-8-RAW")`n finally ExitApp(1)`n}`n'
	Code .= Statements
	Code .= 'Started := DllCall("Kernel32\GetTickCount64", "UInt64")`nwhile DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 1500`n Sleep(20)`n'
	Code .= 'SetTimer(CheckKeyboardLayoutChange, 0)`nFileAppend(Observed, "' . ReceiptLiteral . '", "UTF-8-RAW")`nExitApp(0)`n'
	ProcessHandle := 0, ThreadHandle := 0
	try {
		FileAppend(Code, Script, "UTF-8")
		Command := '"' . A_AhkPath . '" /ErrorStdOut "' . Script . '"'
		CommandBuffer := Buffer(StrPut(Command, "UTF-16") * 2)
		StrPut(Command, CommandBuffer, "UTF-16")
		Startup := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
		NumPut("UInt", Startup.Size, Startup, 0)
		Info := Buffer(2 * A_PtrSize + 8, 0)
		if !DllCall("Kernel32\CreateProcessW", "Str", A_AhkPath, "Ptr", CommandBuffer,
			"Ptr", 0, "Ptr", 0, "Int", false, "UInt", 0x08000000, "Ptr", 0,
			"Str", Root, "Ptr", Startup, "Ptr", Info, "Int")
			throw OSError(A_LastError, "The owned layout probe could not start.")
		ProcessHandle := NumGet(Info, 0, "Ptr"), ThreadHandle := NumGet(Info, A_PtrSize, "Ptr")
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", ProcessHandle, "UInt", 8000, "UInt"),
			"the exact owned probe must finish within its native deadline")
		ExitCode := 1
		AssertTrue(DllCall("Kernel32\GetExitCodeProcess", "Ptr", ProcessHandle, "UInt*", &ExitCode, "Int"))
		Failure := FileExist(ErrorReceipt) ? FileRead(ErrorReceipt, "UTF-8") : ""
		AssertEqual(0, ExitCode, "the native probe must exit cleanly: " . Failure)
		AssertTrue(FileExist(Receipt), "the owned recording callback receipt is required")
		Count := FileRead(Receipt, "UTF-8")
		AssertTrue(RegExMatch(Count, "^[0-9]+$") > 0, "the callback receipt must be an integer")
		AssertTrue(Integer(Count) > 0, "the actual source arming must deliver a native timer callback")
	} finally {
		if ProcessHandle {
			if DllCall("Kernel32\WaitForSingleObject", "Ptr", ProcessHandle, "UInt", 0, "UInt") != 0 {
				DllCall("Kernel32\TerminateProcess", "Ptr", ProcessHandle, "UInt", 1)
				DllCall("Kernel32\WaitForSingleObject", "Ptr", ProcessHandle, "UInt", 2000)
			}
			DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle)
		}
		if ThreadHandle
			DllCall("Kernel32\CloseHandle", "Ptr", ThreadHandle)
		if FileExist(Receipt)
			FileDelete(Receipt)
		if FileExist(ErrorReceipt)
			FileDelete(ErrorReceipt)
		if FileExist(Script)
			FileDelete(Script)
		DirDelete(Root)
	}
}

_LPNA_ActualArming() => _LPNA_RunChild(_LPNA_Statements(_DriverSourceNoComments()))
Test("layout poll: actual source delivers a native timer callback (layout-poll-native-arming)", _LPNA_ActualArming)
