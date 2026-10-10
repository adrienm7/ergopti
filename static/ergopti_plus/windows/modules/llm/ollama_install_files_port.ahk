; modules/llm/ollama_install_files_port.ahk

; ==============================================================================
; MODULE: Windows Ollama Managed File Port Candidate
; DESCRIPTION:
; Owns one native file-helper task and its physical completion independently of
; stale logical results. Shared code owns release data, consent and policies.
; The lazy ShellRunner bridge adopts the task before start; native acceptance
; and the shared acquisition orchestrator remain separate prerequisites.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Native helper admission with exact construction and physical cleanup debt. */
class OllamaInstallFilesPort {
	/**
	 * @param {Map} Options Native helper/powershell paths, capture_bytes and
	 * atomic spawn are required. spawn(exe, argv, on_done, adopt_construction,
	 * capture_bytes) publishes the lazy task before start. The canonical
	 * OllamaInstallFiles_Spawn bridge preserves ShellRunner parameter positions;
	 * its constructor acquires no native resources. Injected spawners must retain
	 * every construction capability before any yielding native acquisition.
	 * Task.requestTerminate() returns strict true only after confirmed native
	 * tree/handle retirement. That ACK carries no exit, output or file proof;
	 * on_physical must still acknowledge the independent file debts.
	 * on_physical receives raw terminal evidence independently of is_current and
	 * returns true only after file debts are adopted/retired by the shared owner.
	 */
	__New(Options) {
		if !(Options is Map) || !this._Local(Options.Get("helper", ""))
				|| !this._Local(Options.Get("powershell", ""))
				|| !(Options.Get("capture_bytes", 0) is Integer)
				|| Options["capture_bytes"] <= 0
			throw TypeError("File port requires explicit native paths and captured output policy.")
		for Name in ["spawn", "on_physical", "on_error"]
			if !HasMethod(Options.Get(Name, 0), "Call")
				throw TypeError("File port requires a callable native owner.", -1, Name)
		this.Options := Options.Clone()
		this.Record := 0
	}

	/**
	 * @param {String} Action Explicit download, prepare, publish, cleanup or cleanup_partial.
	 * @param {Map} Request Captured native argument values; no shell text.
	 * @param {Map} Authority authorize/is_current from the shared request owner.
	 * @param {Func} OnResult Guarded logical completion; physical evidence always
	 * belongs to on_physical even after cancellation, suspension or source drift.
	 * @returns {Boolean} Native dispatch accepted, never installation/AI success.
	 */
	Run(Action, Request, Authority, OnResult) {
		PreviousCritical := Critical("Off")
		try return this._RunNonCritical(Action, Request, Authority, OnResult)
		finally Critical(PreviousCritical)
	}

	_RunNonCritical(Action, Request, Authority, OnResult) {
		if !(Request is Map) || !(Authority is Map)
				|| Action != "download" && Action != "prepare" && Action != "publish" && Action != "cleanup" && Action != "cleanup_partial"
				|| !HasMethod(OnResult, "Call")
				|| !HasMethod(Authority.Get("authorize", 0), "Call")
				|| !HasMethod(Authority.Get("is_current", 0), "Call")
			throw TypeError("File operation needs captured source-owned admission.")
		Record := Map("action", Action, "request", Request.Clone(),
			"authority", Authority.Clone(), "on_result", OnResult,
			"task", 0, "building", true, "cancelled", false,
			"terminal", 0, "physical_busy", false, "physical_acked", false)
		; Clone before claiming, then atomically recheck/acquire with no ports or
		; native IO inside Critical. A timer cannot overwrite another exact owner.
		PreviousCritical := Critical("On")
		try {
			if (this.Record is Map) || (!this._CleanupAction(Action) && A_IsSuspended)
				return false
			this.Record := Record
		} finally Critical(PreviousCritical)
		Accepted := false
		try {
			if !this._Current(Record)
				return false
			if !this._True(Record["authority"]["authorize"].Call(Action, Record["request"].Clone()))
					|| !this._Current(Record)
				return false
			Arguments := this._Arguments(Action, Record["request"])
			Task := this.Options["spawn"].Call(this.Options["powershell"], Arguments,
				ObjBindMethod(this, "_Terminal", Record),
				ObjBindMethod(this, "_AdoptConstruction", Record), this.Options["capture_bytes"])
			if !IsObject(Task) || Task != Record["task"]
				throw TypeError("Spawn must return the exact previously adopted construction task.")
			if !this._Current(Record)
				return false
			if !this._True(Task.start()) || !this._Current(Record)
				return false
			Accepted := true
			return true
		} catch as Err {
			this.Options["on_error"].Call("dispatch", Err)
			return false
		} finally {
			Record["building"] := false
			if !Accepted
				this.Cancel()
			else if IsObject(Record["terminal"])
				this._PublishPhysical(Record)
		}
	}

	/** @returns {Array} Closed typed argv; no task is constructed on refusal. */
	_Arguments(Action, Request) {
		if Action != "download" {
			Arguments := ["-NoLogo", "-NoProfile", "-NonInteractive",
				"-ExecutionPolicy", "Bypass", "-File", this.Options["helper"], "-Action", Action]
			for Name, Value in Request {
				if Name != "ManagedRoot" && Name != "CataloguePath" && Name != "CatalogueSha256"
						&& Name != "AssetId" && Name != "ArchivePath" && Name != "TicketId"
						&& Name != "StageIdentity" && Name != "ManifestSha256"
						&& Name != "CreationWalIdentity" && Name != "CreationWalSha256"
						&& Name != "MaxExpandedBytes" && Name != "MaxEntries"
					throw ValueError("Unknown native file argument.", -1, Name)
				Arguments.Push("-" . Name, String(Value))
			}
			return Arguments
		}
		if !this._Local(this.Options.Get("download_helper", ""))
			throw ValueError("Download requires its explicit captured helper.")
		Names := ["ManagedRoot", "CataloguePath", "CatalogueSha256", "AssetId", "TicketId",
			"ManagedHelperPath", "ManagedHelperSha256", "AcquisitionHelperPath", "AcquisitionHelperSha256",
			"VendorDirectory", "VendorSha256", "ProxyPolicyPath", "ProxyPolicySha256",
			"UpdaterDefaultsPath", "UpdaterDefaultsSha256", "ConnectTimeoutMs", "DeadlineMs", "StartedTick"]
		if Request.Count != Names.Length
			throw ValueError("Download requires its complete captured argument inventory.")
		for Name, Value in Request {
			Known := false
			for Allowed in Names
				if Name == Allowed
					Known := true
			if !Known
				throw ValueError("Unknown native download argument.", -1, Name)
		}
		for Name in Names {
			if !Request.Has(Name)
				throw ValueError("Missing native download argument.", -1, Name)
			Value := Request[Name]
			if Name == "ConnectTimeoutMs" || Name == "DeadlineMs" || Name == "StartedTick" {
				if !(Value is Integer) || Value <= 0 || (Name != "StartedTick" && Value > 2147483647)
					throw ValueError("Download requires the admitted original clock.", -1, Name)
			} else {
				if !(Value is String)
					throw TypeError("Download source fields must be strings.", -1, Name)
				if InStr(Name, "Sha256") {
					if !RegExMatch(Value, "^[0-9a-f]{64}\z")
						throw ValueError("Download requires an exact source digest.", -1, Name)
				} else if Name == "TicketId" {
					if !RegExMatch(Value, "^[0-9a-f]{32}\z")
						throw ValueError("Download requires its original ticket.")
				} else if Name == "AssetId" {
					if Value != "windows-amd64" && Value != "windows-arm64"
						throw ValueError("Download requires a canonical Windows asset.")
				} else if !this._Local(Value)
					throw ValueError("Download source paths must be explicit and absolute.", -1, Name)
			}
		}
		Arguments := ["-NoLogo", "-NoProfile", "-NonInteractive",
			"-ExecutionPolicy", "Bypass", "-File", this.Options["download_helper"], "-Action", Action]
		for Name, Value in Request
			Arguments.Push("-" . Name, String(Value))
		return Arguments
	}

	/** @returns {Boolean} Includes native task, interrupted build and file debt. */
	HasOwner() {
		return this.Record is Map
	}

	/** Invalidates logical publication; retirement may continue while paused. */
	Cancel() {
		PreviousCritical := Critical("Off")
		try return this._CancelNonCritical()
		finally Critical(PreviousCritical)
	}

	_CancelNonCritical() {
		Record := this.Record
		if !(Record is Map)
			return true
		Record["cancelled"] := true
		Record["on_result"] := 0
		Task := Record["task"]
		if IsObject(Task) {
			; Preserve the exact completion callback so the private-file owner sees
			; physical retirement even when a stale logical request is canceled.
			try {
				Quiesced := this._True(Task.requestTerminate())
				; The canonical strict ACK confirms the tree and native handles only.
				; A callback delivered during termination keeps its richer evidence.
				PreviousCritical := Critical("On")
				try {
					if Quiesced && this._Owns(Record) && Record["task"] == Task
							&& !IsObject(Record["terminal"]) {
						Record["task"] := 0
						Record["terminal"] := Map("kind", "native_quiescence",
							"dispatched", false, "exit_observed", false, "output_observed", false)
					}
				} finally Critical(PreviousCritical)
			}
			catch as Err {
				this.Options["on_error"].Call("termination", Err)
			}
			return this._PublishPhysical(Record)
		}
		if Record["building"]
			return false
		if !IsObject(Record["terminal"])
			Record["terminal"] := Map("exit", 0, "stdout", "", "stderr", "", "dispatched", false)
		return this._PublishPhysical(Record)
	}

	_AdoptConstruction(Record, Task) {
		if !this._Owns(Record) || IsObject(Record["task"])
				|| !HasMethod(Task, "start") || !HasMethod(Task, "requestTerminate")
			throw TypeError("Construction receipt must identify one exact retained task.")
		Record["task"] := Task
		return true
	}

	_Terminal(Record, ExitCode, Stdout, Stderr) {
		PreviousCritical := Critical("Off")
		try this._TerminalNonCritical(Record, ExitCode, Stdout, Stderr)
		finally Critical(PreviousCritical)
	}

	_TerminalNonCritical(Record, ExitCode, Stdout, Stderr) {
		if !this._Owns(Record) || IsObject(Record["terminal"])
			return
		Record["task"] := 0
		Record["terminal"] := Map("exit", ExitCode, "stdout", Stdout, "stderr", Stderr, "dispatched", true)
		if !Record["building"]
			this._PublishPhysical(Record)
	}

	_PublishPhysical(Record) {
		if !this._Owns(Record) || Record["building"] || IsObject(Record["task"])
				|| !IsObject(Record["terminal"]) || Record["physical_busy"]
			return false
		if !Record["physical_acked"] {
			Record["physical_busy"] := true
			try Record["physical_acked"] := this._True(this.Options["on_physical"].Call(
				Record["action"], Record["request"].Clone(), Record["terminal"].Clone()))
			catch as Err {
				this.Options["on_error"].Call("physical retirement", Err)
				Record["physical_acked"] := false
			} finally Record["physical_busy"] := false
		}
		if !Record["physical_acked"] || !this._Owns(Record)
			return false
		Current := false
		try Current := this._Current(Record)
		catch as Err {
			this.Options["on_error"].Call("result authority", Err)
		}
		Callback := Record["on_result"]
		this.Record := 0
		Record["on_result"] := 0
		if Current && HasMethod(Callback, "Call")
			Callback.Call(Record["terminal"].Clone())
		return true
	}

	_Current(Record) {
		if !this._Owns(Record) || Record["cancelled"]
				|| (!this._CleanupAction(Record["action"]) && A_IsSuspended)
			return false
		Valid := this._True(Record["authority"]["is_current"].Call(Record["action"], Record["request"].Clone()))
		return Valid && this._Owns(Record) && !Record["cancelled"]
			&& (this._CleanupAction(Record["action"]) || !A_IsSuspended)
	}

	_Owns(Record) {
		return this.Record is Map && this.Record == Record
	}

	_CleanupAction(Action) {
		return Action == "cleanup" || Action == "cleanup_partial"
	}

	_Local(Path) {
		return Path is String && RegExMatch(Path, "^[A-Za-z]:\\") && !InStr(Path, "`n") && !InStr(Path, "`r")
	}

	_True(Value) {
		return Value is Integer && Value == true
	}
}

/**
 * Adopts the canonical lazy tree task before its caller can start native work.
 * @param {String} Executable Explicit PowerShell executable.
 * @param {Array} Arguments Native argv, without shell expansion.
 * @param {Func} OnDone Physical terminal observer retained by requestTerminate.
 * @param {Func} AdoptConstruction Exact task publication owned by the file port.
 * @param {Integer} CaptureBytes Positive caller-owned output limit.
 * @param {Func} SpawnFn Optional constructor-only regression port.
 * @returns {Object} The same task already accepted by AdoptConstruction.
 */
OllamaInstallFiles_Spawn(Executable, Arguments, OnDone, AdoptConstruction,
        CaptureBytes, SpawnFn?) {
	if !(Arguments is Array) || !HasMethod(OnDone, "Call")
			|| !HasMethod(AdoptConstruction, "Call")
			|| !(CaptureBytes is Integer) || CaptureBytes <= 0
		throw TypeError("File bridge requires exact callbacks and bounded capture.")
	Factory := IsSet(SpawnFn) ? SpawnFn : ShellRunner_SpawnTreeOwned
	if !HasMethod(Factory, "Call")
		throw TypeError("File bridge requires a lazy task constructor.")
	; The fifth ShellRunner slot is a post-Job native fault seam, not adoption.
	; Capture remains sixth; private diagnostics keep paths out of error logs.
	Task := Factory.Call(Executable, Arguments, OnDone, , , CaptureBytes, true, true)
	AdoptConstruction.Call(Task)
	return Task
}
