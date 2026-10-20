; modules/llm/api_ollama/curl_tree_owner.ahk

; ==============================================================================
; MODULE: Wrapped Curl Process Tree
; DESCRIPTION:
; Keeps cmd terminal writers and their curl descendants under the canonical
; ShellRunner Job owner. A native completion receipt means the entire Job is
; quiescent; the wrapper PID alone never authorizes physical retirement.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLM_CurlArtifactRunTree(CommandLine, Environment, WorkingDir, &Pid, &ProcessOwner, FactoryFn := unset) {
	if !(CommandLine is String) || CommandLine == ""
		throw TypeError("A wrapped curl launch requires a nonempty command string.")
	Factory := IsSet(FactoryFn) ? FactoryFn : ShellRunner_SpawnTreeOwnedCommand
	if !HasMethod(Factory, "Call")
		throw TypeError("The wrapped curl tree factory must be callable.")
	Owner := Map("pid", 0, "handle", 0, "released", false, "releasing", false,
		"cleanup_debt_id", 0, "tree", 0, "terminal", 0)
	Task := Factory.Call(A_ComSpec, CommandLine, Environment, WorkingDir,
		_LLM_CurlTreeCompleted.Bind(Owner), , , 0, false, true)
	if !IsObject(Task) || !HasMethod(Task, "start") || !HasMethod(Task, "requestTerminate")
			|| !HasMethod(Task, "processId")
		throw TypeError("The wrapped curl launch requires its canonical tree task.")
	Owner["tree"] := Task
	; Publish custody before start can yield or create any native process.
	ProcessOwner := Owner
	PreviousCritical := Critical("On")
	try {
		Started := Task.start()
		if !(Started is Integer) || Started != true
			throw Error("The wrapped curl tree could not start.")
		; A very short wrapper can be reaped by the canonical poll timer.
		; Capture its diagnostic PID before that timer can zero the live slot.
		Pid := Task.processId()
		if !(Pid is Integer) || Pid <= 0
			throw Error("The wrapped curl tree returned an invalid native identity.")
		Owner["pid"] := Pid
	} finally Critical(PreviousCritical)
}

_LLM_CurlTreeCompleted(Owner, ExitCode, Stdout := "", Stderr := "") {
	; The canonical callback follows Job accounting and complete native teardown.
	Owner["terminal"] := Map("exit", ExitCode)
}

_LLM_CurlTryReleaseTree(ProcessOwner, Terminate) {
	if Terminate {
		Quiesced := false
		try {
			Receipt := ProcessOwner["tree"].requestTerminate()
			Quiesced := Receipt is Integer && Receipt == true
		}
		if !Quiesced
			return false
	} else if !(ProcessOwner.Get("terminal", 0) is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		ProcessOwner["tree"] := 0
		ProcessOwner["released"] := true
	} finally Critical(PreviousCritical)
	return true
}
