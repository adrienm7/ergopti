; tests/live/managed_relay_owner.ahk

; ==============================================================================
; MODULE: Managed Runtime Owner Live Fixture
; DESCRIPTION:
; Runs the real OllamaRuntimeOwner, with its real ShellRunner job, over the real
; launcher, and writes whether the owner admitted the receipt the launcher wrote.
; A launcher field the owner does not list leaves the daemon never ready with no
; error at all: only this path, not a source comparison, shows the owner and the
; launcher really agree (regression c378cbe402). tools/test/
; test-windows-proxy-relay-e2e.cjs builds the plan and reads the result.
;
; FEATURES & RATIONALE:
; 1. The logger is not included: its file sink would write the maintainer's
;    %LOCALAPPDATA%\Ergopti logs, which a test must never touch. Warnings go
;    to the result instead, so a refused receipt still names its cause.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; The driver's other modules assign what these adapters read; this fixture omits them.
#Warn VarUnset, Off

global _RelayOwnerErrors := []
OnError(_RelayOwnerFatal)

LoggerWarn(Tag, Message, Values*) => _RelayOwnerErrors.Push(Tag . ": " . Message)
LoggerInfo(*) => 0
LoggerDebug(*) => 0
LoggerError(Tag, Message, Values*) => _RelayOwnerErrors.Push(Tag . ": " . Message)

#Include ..\..\core\text\engine\json.ahk
#Include ..\..\core\crypto\crypto.ahk
#Include ..\..\core\fs\adapters\file_system.ahk
#Include ..\..\core\process\adapters\lifecycle.ahk
#Include ..\..\core\process\adapters\shell_runner.ahk
#Include ..\..\core\network\adapters\proxy_override.ahk
#Include ..\..\ai\engine\ollama\runtime_owner.ahk

_RelayOwnerMain(A_Args[1])

/** A dialog would hang a headless run: name the failure and leave. */
_RelayOwnerFatal(Err, *) {
	FileAppend("owner fixture failed: " . Err.Message . " at " . Err.What . " " . Err.Line . "`n", "**", "UTF-8")
	ExitApp(3)
}

/**
 * Starts the owner from the plan, waits for readiness, stops it and writes the result.
 * @param {String} PlanPath The JSON plan.
 */
_RelayOwnerMain(PlanPath) {
	Plan := JsonParse(FileRead(PlanPath, "UTF-8"))
	Options := Map("launcher", Plan["launcher"], "helper", Plan["helper"],
		"helper_sha256", Plan["helper_sha256"], "environment", Plan["environment"],
		"environment_sha256", Plan["environment_sha256"], "proxy", Plan["proxy"],
		"on_retired", (*) => true,
		"on_error", (Kind, Err) => _RelayOwnerErrors.Push(Kind . ": " . Err.Message))
	Owner := OllamaRuntimeOwner(Options)
	Terminal := []
	Authority := Map("authorize", (*) => true, "is_current", (*) => true)
	Admitted := 0
	OnReady := (Target, Receipt) => (Admitted := Receipt)
	OnExit := (Code, Target) => Terminal.Push(Code)
	Started := Owner.Start(Plan["target"], Authority, OnReady, OnExit)
	Deadline := A_TickCount + Plan["timeout_ms"]
	Ready := false
	while Started && !Ready && !Terminal.Length && A_TickCount < Deadline {
		Ready := Owner.ObserveReady() == true
		if !Ready
			Sleep(50)
	}
	Fields := Ready ? Admitted.Count : 0
	Relay := Ready ? Admitted["proxy_relay"] : ""
	Stopped := Owner.Stop()
	Errors := ""
	for Message in _RelayOwnerErrors
		Errors .= (Errors == "" ? "" : "; ") . StrReplace(StrReplace(Message, "\", "\\"), '"', "'")
	File := FileOpen(Plan["result"], "w", "UTF-8-RAW")
	File.Write('{"started":' . (Started ? "true" : "false") . ',"ready":' . (Ready ? "true" : "false")
		. ',"field_count":' . Fields . ',"expected_field_count":' . OLLAMA_RUNTIME_RECEIPT_FIELDS.Length
		. ',"proxy_relay":"' . Relay . '","stopped":' . (Stopped ? "true" : "false")
		. ',"terminal":' . Terminal.Length . ',"errors":"' . Errors . '"}')
	File.Close()
	ExitApp(0)
}
