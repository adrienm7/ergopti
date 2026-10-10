; modules/llm/ollama_runtime_owner.ahk

; ==============================================================================
; MODULE: Exact Windows Ollama Runtime Owner Candidate
; DESCRIPTION:
; Owns only one foreground server task through the existing ShellRunner Job
; Object. Shared consent, source identity, immutable version leases, HTTP
; readiness and configuration publication remain with their respective owners.
; Readiness observes only the launcher receipt of this retained runtime task.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Holds one exact server task; accepted launch never means AI is enabled. */
class OllamaRuntimeOwner {
	/**
	 * @param {Map} Options Trusted launcher path is required. Optional native
	 * spawn and error ports are narrow regression boundaries, not new owners.
	 */
	__New(Options) {
		if !(Options is Map) || !this._LocalPath(Options.Get("launcher", ""))
				|| !this._LocalPath(Options.Get("helper", ""))
				|| !RegExMatch(Options.Get("helper_sha256", ""), "^[0-9a-f]{64}$")
			throw TypeError("Runtime ownership requires a trusted launcher path.")
		if !HasMethod(Options.Get("on_retired", 0), "Call")
			throw TypeError("Runtime ownership requires an independent physical retirement observer.")
		for Name in ["spawn", "factory", "read_ready", "clock", "on_error", "on_retired"]
			if Options.Has(Name) && !HasMethod(Options[Name], "Call")
				throw TypeError("Runtime native port must be callable.", -1, Name)
		this.Options := Options.Clone()
		this.Record := 0
		this.Generation := 0
	}

	/**
	 * @param {Map} Target Captured executable, models_dir, origin and port.
	 * @param {Map} Authority Shared owner exposing one-shot authorize and
	 * is_current callbacks. These cover explicit consent, source/pause revisions,
	 * verified immutable-version lease and managed directory authority.
	 * @param {Func} OnReady Optional one-shot source/process readiness observer.
	 * @param {Func} OnExit Optional exact-source native terminal observer.
	 * @returns {Boolean} Launch accepted; HTTP readiness is a separate receipt.
	 */
	Start(Target, Authority, OnReady := 0, OnExit := 0) {
		PreviousCritical := Critical("Off")
		try return this._StartNonCritical(Target, Authority, OnReady, OnExit)
		finally Critical(PreviousCritical)
	}

	_StartNonCritical(Target, Authority, OnReady, OnExit) {
		if !this._ValidTarget(Target) || !(Authority is Map)
				|| !HasMethod(Authority.Get("authorize", 0), "Call")
				|| !HasMethod(Authority.Get("is_current", 0), "Call")
				|| (IsObject(OnReady) && !HasMethod(OnReady, "Call"))
				|| (IsObject(OnExit) && !HasMethod(OnExit, "Call"))
			throw TypeError("Runtime start requires a captured target and source-owned consent.")
		PreviousCritical := Critical("On")
		try {
			; Starting and retained cancellation records block every successor.
			if (this.Record is Map) || A_IsSuspended
				return false
			Record := Map("generation", ++this.Generation,
				"target", Target.Clone(), "authority", Authority.Clone(),
				"on_exit", OnExit, "on_ready", OnReady, "ready", false,
				"ready_file_identity", "", "ready_image_sha256", "",
				"task", 0, "building", true,
				"cancelled", false, "terminal", false, "accepted", false,
				"retirement_busy", false, "retirement_acked", false)
			this.Record := Record
		} finally Critical(PreviousCritical)
		Accepted := false
		try {
			if !this._Current(Record)
				return false
			Permission := Record["authority"]["authorize"].Call(Record["target"].Clone())
			if !this._True(Permission) || !this._Current(Record)
				return false
			Target := Record["target"]
			PowerShell := this.Options.Get("powershell",
				A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe")
			if !this._LocalPath(PowerShell)
				throw ValueError("The native PowerShell executable must be local and absolute.")
			Arguments := ["-NoLogo", "-NoProfile", "-NonInteractive",
				"-ExecutionPolicy", "Bypass", "-File", this.Options["launcher"],
				"-ManagedHelperPath", this.Options["helper"],
				"-ManagedHelperSha256", this.Options["helper_sha256"]]
			for Pair in [["ManagedRoot", "managed_root"], ["RootIdentity", "root_identity"],
				["PublishedPath", "version_path"], ["StageIdentity", "version_identity"],
				["TicketId", "ticket"], ["ManifestSha256", "manifest_sha256"],
				["RuntimeTicket", "runtime_ticket"], ["Port", "port"],
				["StartedTick", "started_tick"], ["DeadlineMs", "deadline_ms"]] {
				Arguments.Push("-" . Pair[1], String(Target[Pair[2]]))
			}
			Spawn := this.Options.Get("spawn", ObjBindMethod(this, "_NativeSpawn"))
			Task := Spawn.Call(PowerShell, Arguments, ObjBindMethod(this, "_OnTerminal", Record),
				ObjBindMethod(this, "_AdoptConstruction", Record))
			if !IsObject(Task) || !HasMethod(Task, "start") || !HasMethod(Task, "requestTerminate")
					|| !HasMethod(Task, "processId") || Record["task"] != Task
				throw TypeError("Runtime launch requires its exact adopted tree-owned task.")
			if !this._Current(Record)
				return false
			Started := Task.start()
			if !this._True(Started) || !this._Current(Record)
				return false
			Record["accepted"] := true
			Accepted := true
			return true
		} catch as Err {
			this._Report("start", Err)
			return false
		} finally {
			Record["building"] := false
			if !Accepted
				this._CancelRecord(Record)
			else if Record["terminal"]
				this._Release(Record)
		}
	}

	/**
	 * Invalidates publication before retiring only the exact retained task.
	 * @returns {Boolean} No runtime task or interrupted construction remains.
	 */
	Stop() {
		PreviousCritical := Critical("Off")
		try {
			Record := this.Record
			return !(Record is Map) || this._CancelRecord(Record)
		} finally Critical(PreviousCritical)
	}

	/** @returns {Boolean} Includes stable ownership and unacknowledged cleanup. */
	HasOwner() {
		return this.Record is Map
	}

	_Current(Record) {
		if !this._Owns(Record) || Record["cancelled"] || Record["terminal"] || A_IsSuspended
			return false
		Valid := Record["authority"]["is_current"].Call(Record["target"].Clone())
		return this._True(Valid) && this._Owns(Record)
			&& !Record["cancelled"] && !Record["terminal"] && !A_IsSuspended
	}

	_Owns(Record) {
		return this.Record is Map && this.Record == Record
			&& this.Generation == Record["generation"]
	}

	_CancelRecord(Record) {
		if !this._Owns(Record)
			return !(this.Record is Map)
		PreviousCritical := Critical("On")
		try {
			Record["cancelled"] := true
			Record["on_exit"] := 0
			Record["on_ready"] := 0
			Task := Record["task"]
		} finally Critical(PreviousCritical)
		Stopped := !IsObject(Task)
		if IsObject(Task) {
			try Stopped := this._True(Task.requestTerminate())
			catch as Err {
				this._Report("termination", Err)
				Stopped := false
			}
		}
		PreviousCritical := Critical("On")
		try {
			if Stopped && this._Owns(Record) && Record["task"] == Task
				Record["task"] := 0
		} finally Critical(PreviousCritical)
		if !Stopped || Record["building"]
			return false
		return this._Owns(Record) ? this._Release(Record) : !(this.Record is Map)
	}

	_OnTerminal(Record, ExitCode, Stdout, Stderr) {
		PreviousCritical := Critical("Off")
		try this._OnTerminalNonCritical(Record, ExitCode)
		finally Critical(PreviousCritical)
	}

	_OnTerminalNonCritical(Record, ExitCode) {
		; ShellRunner calls this only after its exact job is quiescent. This
		; callback never reopens a numeric PID or inspects another runtime task.
		if !this._Owns(Record)
			return
		Current := false
		try Current := Record["accepted"] && !Record["cancelled"] && this._Current(Record)
		catch as Err {
			this._Report("terminal authority", Err)
		}
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record)
				return
			Callback := Current && !Record["cancelled"] && !A_IsSuspended
				? Record["on_exit"] : 0
			Record["terminal"] := true
			Record["task"] := 0
			Record["on_exit"] := 0
		} finally Critical(PreviousCritical)
		try {
			if HasMethod(Callback, "Call")
				Callback.Call(ExitCode, Record["target"].Clone())
		} finally {
			if !Record["building"]
				this._Release(Record)
		}
	}

	_Release(Record) {
		; Physical retirement is independent of logical source/pause admission.
		; Its refusal retains this exact owner and immutable-version lease debt.
		if !this._Owns(Record) || Record["building"] || IsObject(Record["task"])
				|| Record["retirement_busy"]
			return false
		if !Record["retirement_acked"] {
			Record["retirement_busy"] := true
			RetirementTarget := Record["target"].Clone()
			RetirementTarget["ready_file_identity"] := Record["ready_file_identity"]
			RetirementTarget["ready_image_sha256"] := Record["ready_image_sha256"]
			try Record["retirement_acked"] := this._True(
				this.Options["on_retired"].Call(RetirementTarget))
			catch as Err {
				this._Report("physical retirement", Err)
				Record["retirement_acked"] := false
			} finally Record["retirement_busy"] := false
			if !Record["retirement_acked"] || !this._Owns(Record)
				return false
		}
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record) || Record["building"] || IsObject(Record["task"])
				return false
			this.Record := 0
			Record["on_exit"] := 0
			return true
		} finally Critical(PreviousCritical)
	}

	/** Observes an exact source/process receipt; never probes a global daemon. */
	ObserveReady() {
		Record := this.Record
		if !(Record is Map) || !Record["accepted"] || Record["ready"] || !this._Current(Record)
				|| !this._ReadyDeadline(Record)
			return false
		Read := this.Options.Get("read_ready", ObjBindMethod(this, "_NativeReadReady"))
		try Observation := Read.Call(Record["target"].Clone())
		catch as Err {
			this._Report("readiness receipt", Err)
			return false
		}
		if !(Observation is Map) || Observation.Count != 2
				|| !(Observation.Get("image_sha256", 0) is String)
				|| !RegExMatch(Observation["image_sha256"], "^[0-9a-f]{64}$")
			return false
		Receipt := Observation.Get("receipt", 0)
		if !(Receipt is Map) || Receipt.Count != 10 || !IsObject(Record["task"]) || !this._Current(Record)
				|| !this._ReadyDeadline(Record)
			return false
		Target := Record["target"]
		for Name in ["runtime_ticket", "ticket", "root_identity", "version_identity", "manifest_sha256", "origin"]
			if !(Receipt.Get(Name, 0) is String) || Receipt[Name] !== Target[Name]
				return false
		Pid := Record["task"].processId()
		if !(Pid is Integer) || Pid <= 0 || Receipt.Get("launcher_pid", 0) !== Pid
				|| !(Receipt.Get("child_pid", 0) is Integer) || Receipt["child_pid"] <= 0
				|| Receipt["child_pid"] == Pid || !this._True(Receipt.Get("leases_held", 0))
				|| !(Receipt.Get("ready_file_identity", 0) is String)
				|| !RegExMatch(Receipt.Get("ready_file_identity", ""), "^[0-9a-f]{8}:[0-9a-f]{16}$")
			return false
		PreviousCritical := Critical("On")
		try {
			if !this._Owns(Record) || Record["cancelled"] || Record["terminal"] || Record["ready"]
				return false
			Record["ready"] := true
			Record["ready_file_identity"] := Receipt["ready_file_identity"]
			Record["ready_image_sha256"] := Observation["image_sha256"]
			Callback := Record["on_ready"]
			Record["on_ready"] := 0
		} finally Critical(PreviousCritical)
		if !this._Current(Record) || !this._ReadyDeadline(Record)
			return false
		if HasMethod(Callback, "Call")
			Callback.Call(Target.Clone(), Receipt.Clone())
		return true
	}

	_AdoptConstruction(Record, Task) {
		if !this._Owns(Record) || IsObject(Record["task"]) || !HasMethod(Task, "start")
				|| !HasMethod(Task, "requestTerminate") || !HasMethod(Task, "processId")
			throw TypeError("Runtime construction requires one exact lazy task.")
		Record["task"] := Task
		return true
	}

	_ReadyDeadline(Record) {
		Clock := this.Options.Get("clock", OllamaRuntime_Now)
		Now := Clock.Call()
		if !(Now is Integer)
			throw TypeError("Runtime readiness requires an exact monotonic observation.")
		Elapsed := Now - Record["target"]["started_tick"]
		return Elapsed >= 0 && Elapsed < Record["target"]["deadline_ms"]
	}

	_NativeReadReady(Target) {
		Path := Target["managed_root"] . "\.runtime-" . Target["runtime_ticket"] . ".json"
		if !FileExist(Path)
			return false
		Image := FSReadUtf8ExactBounded(Path, 4096)
		return Map("receipt", JsonParse(Image), "image_sha256", CryptoSha256(Image))
	}

	_ValidTarget(Target) {
		if !(Target is Map) || !(Target.Get("port", 0) is Integer)
				|| Target["port"] < 1 || Target["port"] > 65535
			return false
		for Name in ["managed_root", "version_path", "executable", "models_dir"]
			if !this._LocalPath(Target.Get(Name, ""))
				return false
		for Name in ["root_identity", "version_identity"]
			if !RegExMatch(Target.Get(Name, ""), "^[0-9a-f]{8}:[0-9a-f]{16}$")
				return false
		for Name in ["ticket", "runtime_ticket"]
			if !RegExMatch(Target.Get(Name, ""), "^[0-9a-f]{32}$")
				return false
		return RegExMatch(Target.Get("manifest_sha256", ""), "^[0-9a-f]{64}$")
			&& Target["executable"] == Target["version_path"] . "\ollama.exe"
			&& Target["models_dir"] == Target["managed_root"] . "\models"
			&& Target.Get("origin", "") == ("http://127.0.0.1:" . Target["port"])
			&& Target.Get("started_tick", 0) is Integer && Target["started_tick"] > 0
			&& Target.Get("deadline_ms", 0) is Integer && Target["deadline_ms"] > 0 && Target["deadline_ms"] <= 2147483647
	}

	_LocalPath(Path) {
		return Path is String && RegExMatch(Path, "^[A-Za-z]:\\")
			&& !InStr(Path, "`r") && !InStr(Path, "`n")
	}

	_True(Value) {
		return Value is Integer && Value == true
	}

	_Report(Kind, Err) {
		Report := this.Options.Get("on_error", 0)
		if HasMethod(Report, "Call")
			Report.Call(Kind, Err)
		else
			LoggerWarn("LLM.runtime", "Owned Ollama {1} failed: {2}.", Kind, Err.Message)
	}

	_NativeSpawn(Executable, Arguments, OnDone, Adopt) {
		Factory := this.Options.Get("factory", ShellRunner_SpawnTreeOwned)
		Task := Factory.Call(Executable, Arguments, OnDone, , , 0, false, true)
		Adopt.Call(Task)
		return Task
	}
}

/** @returns {String} Native host architecture, independent of interpreter bitness. */
OllamaRuntime_HostArchitecture(NativeMachineFn := unset) {
	Machine := IsSet(NativeMachineFn) ? NativeMachineFn.Call() : _OllamaRuntimeNativeMachine()
	if !(Machine is Integer)
		throw TypeError("Native host architecture observation must be an integer.")
	if Machine == 0x8664
		return "x86_64"
	if Machine == 0xaa64
		return "arm64"
	throw ValueError("This native host architecture has no admitted managed Ollama asset.")
}

_OllamaRuntimeNativeMachine() {
	ProcessMachine := 0
	NativeMachine := 0
	if !DllCall("kernel32\IsWow64Process2", "Ptr", -1,
		"UShort*", &ProcessMachine, "UShort*", &NativeMachine, "Int")
		throw OSError(A_LastError, "Native host architecture observation was refused.")
	return NativeMachine
}

/** Shares the native monotonic epoch with the PowerShell readiness owner. */
OllamaRuntime_Now() {
	return DllCall("kernel32\GetTickCount64", "UInt64")
}
