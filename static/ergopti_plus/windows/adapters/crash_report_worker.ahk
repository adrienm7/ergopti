; adapters/crash_report_worker.ahk

; ==============================================================================
; MODULE: Crash Report Worker Adapter
; DESCRIPTION:
; Owns the isolated crash-report process and transfers its JSON snapshot through
; a bounded pagefile-backed mapping. Only a short mapping name crosses argv, so
; crash diagnostics are not constrained by cmd.exe's command-line ceiling and
; the AHK interpreter never writes the report payload to disk.
;
; FEATURES & RATIONALE:
; 1. Bounded memory transport: a length-prefixed UTF-8 snapshot lives in a named
;    mapping retained until the exact worker callback claims it.
; 2. Exact lifecycle: start refusal, completion, exceptions, and shutdown each
;    close the mapping once and cannot retire a newer worker.
; 3. Minimal isolated fallback: if the schema-enrichment script cannot launch
;    or complete, a small encoded child reads the same mapping and writes the
;    snapshot before the owner is retired.
; ==============================================================================





; ==================================
; ==================================
; ======= 1/ Constants and State ===
; ==================================
; ==================================

global CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES := 1048576
global CRASH_REPORT_WORKER_MAX_OUTPUT_BYTES := 65536
global CRASH_REPORT_WORKER_PAGE_READWRITE := 0x04
global CRASH_REPORT_WORKER_FILE_MAP_WRITE := 0x0002
global _CrashReportWorkerOwners := Map()
global _CrashReportWorkerSerial := 0



; ==================================
; ===== 1.1) Diagnostics ===========
; ==================================

_CrashReportWorkerLogError(FormatString, Args*) {
	try LoggerError("CrashReporter", FormatString, Args*)
	catch
		try OutputDebug("[CrashReporter] " . Format(FormatString, Args*))
}



; ==========================================
; ==========================================
; ======= 2/ Pagefile Mapping Owner ========
; ==========================================
; ==========================================

_CrashReportWorkerCreateMapping(Payload, OwnerId) {
	global CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES
	global CRASH_REPORT_WORKER_PAGE_READWRITE, CRASH_REPORT_WORKER_FILE_MAP_WRITE

	if !(Payload is String)
		throw TypeError("Crash-report worker payload must be a String")
	Utf8 := Buffer(StrPut(Payload, "UTF-8"), 0)
	StrPut(Payload, Utf8, "UTF-8")
	PayloadBytes := Utf8.Size - 1
	if (PayloadBytes <= 0 or PayloadBytes > CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES)
		throw ValueError("Crash-report worker payload exceeds its bounded mapping")

	MappingName := "Local\ErgoptiCrash_" . DllCall("GetCurrentProcessId", "UInt")
		. "_" . OwnerId . "_" . (A_TickCount & 0xFFFFFFFF)
	MappingBytes := PayloadBytes + 4
	MappingHandle := DllCall("CreateFileMappingW",
		"Ptr", -1, "Ptr", 0, "UInt", CRASH_REPORT_WORKER_PAGE_READWRITE,
		"UInt", 0, "UInt", MappingBytes, "Str", MappingName, "Ptr")
	if !MappingHandle
		throw OSError(A_LastError, "CreateFileMappingW")

	View := 0
	try {
		View := DllCall("MapViewOfFile", "Ptr", MappingHandle,
			"UInt", CRASH_REPORT_WORKER_FILE_MAP_WRITE,
			"UInt", 0, "UInt", 0, "UPtr", MappingBytes, "Ptr")
		if !View
			throw OSError(A_LastError, "MapViewOfFile")
		NumPut("UInt", PayloadBytes, View, 0)
		DllCall("RtlMoveMemory", "Ptr", View + 4, "Ptr", Utf8.Ptr, "UPtr", PayloadBytes)
	} catch {
		DllCall("CloseHandle", "Ptr", MappingHandle)
		throw
	} finally {
		if View
			DllCall("UnmapViewOfFile", "Ptr", View)
	}

	return Map(
		"name", MappingName,
		"handle", MappingHandle,
		"bytes", PayloadBytes,
		"closed", false)
}

_CrashReportWorkerCloseMapping(Mapping) {
	if !(Mapping is Map) or Mapping.Get("closed", true)
		return false
	Mapping["closed"] := true
	Handle := Mapping.Get("handle", 0)
	Mapping["handle"] := 0
	if Handle
		DllCall("CloseHandle", "Ptr", Handle)
	return true
}





; ==============================================
; ==============================================
; ======= 3/ Worker Command Construction =======
; ==============================================
; ==============================================

_CrashReportWorkerEncodePowerShell(Command) {
	Bytes := Buffer(StrLen(Command) * 2, 0)
	if Bytes.Size
		DllCall("RtlMoveMemory", "Ptr", Bytes.Ptr, "Ptr", StrPtr(Command), "UPtr", Bytes.Size)
	return CryptoBase64Encode(Bytes)
}

_CrashReportWorkerFallbackSource(MappingName) {
	SafeName := StrReplace(MappingName, '"', "")
	return '$ErrorActionPreference="Stop";'
		. '$m=[IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("' . SafeName . '",[IO.MemoryMappedFiles.MemoryMappedFileRights]::Read);'
		. '$v=$m.CreateViewAccessor(0,0,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read);'
		. '$n=$v.ReadInt32(0);if($n-lt 1-or $n-gt ' . CRASH_REPORT_WORKER_MAX_PAYLOAD_BYTES . '){throw "invalid payload length"};'
		. '$b=New-Object byte[] $n;$null=$v.ReadArray(4,$b,0,$n);$v.Dispose();$m.Dispose();'
		. '$s=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json;'
		. '$d=Join-Path $s._transport_config_dir "autohotkey\crash_reports";[IO.Directory]::CreateDirectory($d)|Out-Null;'
		. '$r=@{error_msg="[redacted error message]";error_extra="[redacted error context]";error_what="[redacted error context]";error_file="[redacted source path]";stack_trace="[redacted stack]";script_dir="[redacted path]";active_window_title="[redacted window title]";active_window_process="[redacted process]";config_dir="[redacted path]";log_tail="[redacted log]"};'
		. 'foreach($k in $r.Keys){if(($s.PSObject.Properties.Name-contains $k)-and [string]$s.$k-ne ""){$s.$k=$r[$k]}};'
		. '$s.PSObject.Properties.Remove("_transport_script_dir");$s.PSObject.Properties.Remove("_transport_config_dir");'
		. '$p=Join-Path $d ((Get-Date -Format "yyyy-MM-ddTHH-mm-ss")+"_"+[guid]::NewGuid().ToString("N")+".json");'
		. '[IO.File]::WriteAllText($p,($s|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));Write-Output ("OK:"+$p)'
}

_CrashReportWorkerPowerShellPath() {
	return A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
}

_CrashReportWorkerSpawnOwned(Executable, Args, Done) {
	global CRASH_REPORT_WORKER_MAX_OUTPUT_BYTES
	return ShellRunner_SpawnTreeOwned(Executable, Args, Done,
		, , CRASH_REPORT_WORKER_MAX_OUTPUT_BYTES, true)
}

_CrashReportWorkerPrimaryArgs(Owner) {
	Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", Owner["worker_path"], "-MappingName", Owner["mapping"]["name"]]
	Options := Owner["options"]
	DelayMs := Options.Get("delay_ms", 0)
	if DelayMs
		Args.Push("-DelayMs", String(DelayMs))
	Faults := Options.Get("faults", "")
	if Faults != ""
		Args.Push("-Faults", String(Faults))
	return Args
}

_CrashReportWorkerFallbackArgs(Owner) {
	return ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-EncodedCommand", _CrashReportWorkerEncodePowerShell(
			_CrashReportWorkerFallbackSource(Owner["mapping"]["name"]))]
}



; =====================================
; =====================================
; ======= 4/ Exact Worker Lifecycle ===
; =====================================
; =====================================

_CrashReportWorkerClaim(OwnerId, ExpectedOwner := 0) {
	global _CrashReportWorkerOwners
	PreviousCritical := Critical("On")
	try {
		if !_CrashReportWorkerOwners.Has(OwnerId)
			return 0
		Owner := _CrashReportWorkerOwners[OwnerId]
		if IsObject(ExpectedOwner) and ObjPtr(Owner) != ObjPtr(ExpectedOwner)
			return 0
		_CrashReportWorkerOwners.Delete(OwnerId)
		return Owner
	} finally Critical(PreviousCritical)
}

_CrashReportWorkerDone(OwnerId, Attempt, ExitCode, Stdout, Stderr) {
	global _CrashReportWorkerOwners
	PreviousCritical := Critical("On")
	Owner := 0
	Phase := ""
	Cancelled := false
	try {
		if !_CrashReportWorkerOwners.Has(OwnerId)
			return
		Candidate := _CrashReportWorkerOwners[OwnerId]
		if Candidate["attempt"] != Attempt
			return
		Owner := Candidate
		Owner["task"] := 0
		Phase := Owner["phase"]
		Cancelled := Owner.Get("cancel_requested", false)
	} finally Critical(PreviousCritical)
	if Cancelled {
		Claimed := _CrashReportWorkerClaim(OwnerId, Owner)
		if IsObject(Claimed)
			_CrashReportWorkerCloseMapping(Claimed["mapping"])
		return
	}
	if (Phase = "primary" and ExitCode != 0) {
		_CrashReportWorkerLogError(
			"Primary crash-report worker failed after launch (exit={1}); trying the isolated minimal writer.",
			ExitCode)
		try {
			if _CrashReportWorkerStartAttempt(Owner, "fallback", _CrashReportWorkerFallbackArgs(Owner))
				return
		} catch as Err {
			_CrashReportWorkerLogError("Crash-report fallback launch threw: {1}.", Err.Message)
		}
	}
	_CrashReportWorkerFinish(Owner, ExitCode, Stdout, Stderr)
}

_CrashReportWorkerFinish(Owner, ExitCode, Stdout, Stderr) {
	Claimed := _CrashReportWorkerClaim(Owner["id"], Owner)
	if !IsObject(Claimed)
		return false
	_CrashReportWorkerCloseMapping(Claimed["mapping"])
	try Claimed["on_done"].Call(ExitCode, Stdout, Stderr)
	catch as Err
		_CrashReportWorkerLogError("Crash-report completion callback threw: {1}.", Err.Message)
	return true
}

_CrashReportWorkerStartAttempt(Owner, Phase, Args) {
	global _CrashReportWorkerOwners
	PreviousCritical := Critical("On")
	try {
		if !_CrashReportWorkerOwners.Has(Owner["id"])
			return false
		if ObjPtr(_CrashReportWorkerOwners[Owner["id"]]) != ObjPtr(Owner)
			return false
		Owner["phase"] := Phase
		Owner["attempt"] += 1
		Owner["state"] := "spawning"
		Attempt := Owner["attempt"]
	} finally Critical(PreviousCritical)
	Done := _CrashReportWorkerDone.Bind(Owner["id"], Attempt)
	Task := Owner["spawn_fn"].Call(_CrashReportWorkerPowerShellPath(), Args, Done)
	if !IsObject(Task)
		return false
	PublishTask := false
	PreviousCritical := Critical("On")
	try {
		if _CrashReportWorkerOwners.Has(Owner["id"])
				&& ObjPtr(_CrashReportWorkerOwners[Owner["id"]]) = ObjPtr(Owner)
				&& Owner["attempt"] = Attempt
				&& !Owner.Get("cancel_requested", false) {
			Owner["task"] := Task
			Owner["state"] := "starting"
			PublishTask := true
		}
	} finally Critical(PreviousCritical)
	if !PublishTask {
		Terminated := false
		try Terminated := Task.terminate() == true
		if Terminated {
			Claimed := _CrashReportWorkerClaim(Owner["id"], Owner)
			if IsObject(Claimed)
				_CrashReportWorkerCloseMapping(Claimed["mapping"])
		}
		return false
	}
	Started := false
	try Started := Task.start()
	catch as Err {
		_CrashReportWorkerLogError("Crash-report worker start threw: {1}.", Err.Message)
	}
	if !Started {
		Terminated := false
		try Terminated := Task.terminate() == true
		PreviousCritical := Critical("On")
		try {
			if _CrashReportWorkerOwners.Has(Owner["id"])
					&& ObjPtr(_CrashReportWorkerOwners[Owner["id"]]) = ObjPtr(Owner)
					&& Owner["attempt"] = Attempt {
				if Terminated {
					Owner["task"] := 0
					Owner["state"] := "idle"
				} else
					Owner["state"] := "start_failed"
			}
		} finally Critical(PreviousCritical)
		return false
	}
	PreviousCritical := Critical("On")
	try {
		if !_CrashReportWorkerOwners.Has(Owner["id"])
			return false
		if ObjPtr(_CrashReportWorkerOwners[Owner["id"]]) != ObjPtr(Owner)
			return false
		if Owner["attempt"] != Attempt
			return false
		if Owner.Get("cancel_requested", false)
			return false
		Owner["state"] := "running"
		return true
	} finally Critical(PreviousCritical)
}

/**
 * Starts an isolated crash-report worker with a retained memory mapping.
 * @param {String} SnapshotJson Canonical crash snapshot encoded as UTF-8 JSON.
 * @param {Func} OnDone Completion callback receiving exit code, stdout, stderr.
 * @param {Func|unset} SpawnFn Injectable ShellRunner-compatible spawn function.
 * @param {String|unset} WorkerPath Injectable worker path for integration tests.
 * @param {Map|unset} Options Bounded test seams: delay_ms and faults.
 * @return {Map|Integer} Retained owner Map on success, otherwise 0.
 */
CrashReportWorker_Start(SnapshotJson, OnDone, SpawnFn?, WorkerPath?, Options?) {
	global _CrashReportWorkerOwners, _CrashReportWorkerSerial, _VendorDir
	if !HasMethod(OnDone, "Call")
		throw TypeError("CrashReportWorker_Start requires a callback")
	ResolvedSpawn := IsSet(SpawnFn) ? SpawnFn : _CrashReportWorkerSpawnOwned
	if !HasMethod(ResolvedSpawn, "Call")
		throw TypeError("CrashReportWorker_Start requires a spawn function")
	ResolvedPath := IsSet(WorkerPath) ? WorkerPath : _VendorDir . "\ergopti_crash_worker.ps1"
	if !(ResolvedPath is String)
		throw TypeError("CrashReportWorker_Start requires a worker path")
	ResolvedOptions := IsSet(Options) && Options is Map ? Options : Map()
	PreviousCritical := Critical("On")
	try OwnerId := ++_CrashReportWorkerSerial
	finally Critical(PreviousCritical)
	Mapping := _CrashReportWorkerCreateMapping(SnapshotJson, OwnerId)
	Owner := Map(
		"id", OwnerId, "mapping", Mapping, "on_done", OnDone,
		"spawn_fn", ResolvedSpawn, "worker_path", ResolvedPath,
		"options", ResolvedOptions, "phase", "", "attempt", 0, "task", 0,
		"state", "idle", "cancel_requested", false)
	PreviousCritical := Critical("On")
	try _CrashReportWorkerOwners[OwnerId] := Owner
	finally Critical(PreviousCritical)

	try {
		if FileExist(ResolvedPath)
			if _CrashReportWorkerStartAttempt(Owner, "primary", _CrashReportWorkerPrimaryArgs(Owner))
				return Owner
		_CrashReportWorkerLogError("Primary crash-report worker could not start; trying the isolated minimal writer.")
		if _CrashReportWorkerStartAttempt(Owner, "fallback", _CrashReportWorkerFallbackArgs(Owner))
			return Owner
	} catch as Err {
		_CrashReportWorkerLogError("Crash-report worker launch failed: {1}.", Err.Message)
	}
	PreviousCritical := Critical("On")
	try TaskStillOwned := _CrashReportWorkerOwners.Has(OwnerId)
		&& IsObject(Owner.Get("task", 0))
	finally Critical(PreviousCritical)
	if TaskStillOwned
		_CrashReportWorkerCancelOwner(Owner)
	else {
		Claimed := _CrashReportWorkerClaim(OwnerId, Owner)
		if IsObject(Claimed)
			_CrashReportWorkerCloseMapping(Claimed["mapping"])
	}
	return 0
}

_CrashReportWorkerCancelOwner(Owner) {
	global _CrashReportWorkerOwners
	PreviousCritical := Critical("On")
	try {
		OwnerId := Owner.Get("id", 0)
		if !_CrashReportWorkerOwners.Has(OwnerId)
			return true
		if ObjPtr(_CrashReportWorkerOwners[OwnerId]) != ObjPtr(Owner)
			return true
		Owner["cancel_requested"] := true
		Task := Owner.Get("task", 0)
		if !IsObject(Task)
			return false
		Owner["state"] := "cancelling"
	} finally Critical(PreviousCritical)
	Terminated := false
	try Terminated := Task.terminate() == true
	catch as Err
		_CrashReportWorkerLogError("Crash-report worker termination threw: {1}.", Err.Message)
	if !Terminated {
		PreviousCritical := Critical("On")
		try {
			if _CrashReportWorkerOwners.Has(OwnerId)
					&& ObjPtr(_CrashReportWorkerOwners[OwnerId]) = ObjPtr(Owner)
				Owner["state"] := "running"
		} finally Critical(PreviousCritical)
		return false
	}
	Claimed := _CrashReportWorkerClaim(OwnerId, Owner)
	if IsObject(Claimed)
		_CrashReportWorkerCloseMapping(Claimed["mapping"])
	return true
}

CrashReportWorker_StopAll() {
	global _CrashReportWorkerOwners
	PreviousCritical := Critical("On")
	try {
		Owners := []
		for _, Owner in _CrashReportWorkerOwners
			Owners.Push(Owner)
	} finally Critical(PreviousCritical)
	AllStopped := true
	for _, Owner in Owners {
		if !_CrashReportWorkerCancelOwner(Owner)
			AllStopped := false
	}
	PreviousCritical := Critical("On")
	try return AllStopped && _CrashReportWorkerOwners.Count = 0
	finally Critical(PreviousCritical)
}
