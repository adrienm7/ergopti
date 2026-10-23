; tests/fixtures/ollama_child_startup_diagnostics.ahk

; ==============================================================================
; MODULE: Ollama Child Startup Diagnostics
; DESCRIPTION:
; Observe generated-child startup before production owners initialize. Only
; builtin/native file operations are available at this boundary. The parent
; exclusively owns the directory, and CREATE_NEW refuses a foreign trace.
; ==============================================================================

#Requires AutoHotkey v2.0

_OCSD_Write(Text) {
	global _OCSD_TraceHandle
	if !_OCSD_TraceHandle
		throw Error("The private startup trace has no native owner.")
	Bytes := StrPut(Text, "UTF-8") - 1
	Encoded := Buffer(Bytes + 1, 0)
	StrPut(Text, Encoded, "UTF-8")
	Written := 0
	if !DllCall("Kernel32\WriteFile", "Ptr", _OCSD_TraceHandle, "Ptr", Encoded,
		"UInt", Bytes, "UInt*", &Written, "Ptr", 0, "Int")
		throw OSError()
	if Written != Bytes
		throw Error("The private startup trace was written only partially.")
	if !DllCall("Kernel32\FlushFileBuffers", "Ptr", _OCSD_TraceHandle, "Int")
		throw OSError()
}

_OCSD_Checkpoint(Phase) {
	global _OCSD_Phase
	if !(Phase is String) || StrLen(Phase) > 64 || !RegExMatch(Phase, "^[A-Za-z0-9-]+$")
		throw ValueError("A private startup phase must be a bounded ASCII identifier.")
	_OCSD_Phase := Phase
	Text := "STARTUP_CHECKPOINT phase=" . Phase . "`n"
	_OCSD_Write(Text)
	FileAppend(Text, "*", "UTF-8")
}

_OCSD_CloseTrace() {
	global _OCSD_TraceHandle
	if !_OCSD_TraceHandle
		return
	if !DllCall("Kernel32\CloseHandle", "Ptr", _OCSD_TraceHandle, "Int")
		throw OSError()
	_OCSD_TraceHandle := 0
}

_OCSD_Error(Failure, Mode) {
	global _OCSD_Phase
	Line := Failure is Error ? Failure.Line : 0
	Code := Failure is OSError ? Failure.Number : 0
	; Exception messages can contain script or user data. The owner phase and
	; source line identify the boundary without copying those contents.
	Text := "STARTUP_FAILURE phase=" . _OCSD_Phase . " type=" . Type(Failure)
		. " line=" . Line . " code=" . Code . "`n"
	try _OCSD_Write(Text)
	try FileAppend(Text, "*", "UTF-8")
	try _OCSD_CloseTrace()
	ExitApp(2)
}

_OCSD_Begin() {
	global _OCSD_TraceHandle
	if A_Args.Length != 2
		throw ValueError("A private Ollama child requires its mode and owned directory.")
	Path := A_Args[2] . "\startup.trace"
	; GENERIC_WRITE, FILE_SHARE_READ, CREATE_NEW: retain this one exact
	; handle until Finish or native process retirement; never reopen by path.
	Handle := DllCall("Kernel32\CreateFileW", "WStr", Path, "UInt", 0x40000000, "UInt", 1,
		"Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
	if Handle == -1 || Handle == 0
		throw OSError()
	_OCSD_TraceHandle := Handle
	_OCSD_Checkpoint("generated-entry")
}

_OCSD_Stop() {
	_OCSD_Checkpoint("before-fixture-include")
	; The original business fixture installs its own async observer unchanged.
	OnError(_OCSD_Error, 0)
}

; A breadcrumb failure must not skip business cleanup or replace its primary
; exception. Finish still rejects a successful run whose trace was not durable.
_OCSD_Note(Phase) {
	global _OCSD_DiagnosticFailure
	try _OCSD_Checkpoint(Phase)
	catch as Failure {
		if !IsObject(_OCSD_DiagnosticFailure)
			_OCSD_DiagnosticFailure := Failure
		try FileAppend("STARTUP_DIAGNOSTIC_FAILURE type=" . Type(Failure) . "`n", "*", "UTF-8")
	}
}

_OCSD_Finish() {
	global _OCSD_DiagnosticFailure
	Failure := _OCSD_DiagnosticFailure
	try _OCSD_CloseTrace()
	catch as CloseFailure {
		if !IsObject(Failure)
			Failure := CloseFailure
	}
	if IsObject(Failure)
		throw Failure
}

global _OCSD_DiagnosticFailure := 0
global _OCSD_TraceHandle := 0
global _OCSD_Phase := "diagnostic-entry"
OnError(_OCSD_Error)
_OCSD_Begin()
