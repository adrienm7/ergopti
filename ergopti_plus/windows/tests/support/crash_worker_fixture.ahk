; tests/support/crash_worker_fixture.ahk

; ==============================================================================
; MODULE: Crash Worker Fixture Ownership
; DESCRIPTION:
; Owns an exclusively acquired output directory and every exact task created by
; a crash-worker fixture. Failed waits cannot release files before their writers.
; Unconfirmed cleanup remains explicitly retained for a later bounded retry.
; ==============================================================================

#Requires AutoHotkey v2.0

global _CRWF_PendingCleanup := Map()

_CRWF_DrainPending() {
	global _CRWF_PendingCleanup
	Pending := []
	PreviousCritical := Critical("On")
	try {
		for _, Fixture in _CRWF_PendingCleanup
			Pending.Push(Fixture)
	} finally Critical(PreviousCritical)
	Complete := true
	for Fixture in Pending {
		if !Fixture.Cleanup()
			Complete := false
	}
	return Complete
}

_CRWF_CreateDirectory(Path) {
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Path, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Exclusive crash fixture directory creation")
	return Path
}

_CRWF_DeleteDirectory(Path) {
	DirDelete(Path, true)
	return true
}

class _CRWF_Fixture {
	__New(Label := "worker", DeleteDirectory := _CRWF_DeleteDirectory) {
		static Serial := 0
		if !(Label is String) || !RegExMatch(Label, "^[A-Za-z0-9_-]{1,64}$")
			throw ValueError("Crash fixture label must be a bounded filename component")
		if !HasMethod(DeleteDirectory, "Call")
			throw TypeError("Crash fixture deletion port must be callable")
		if !_CRWF_DrainPending()
			throw Error("Previous crash fixture cleanup remains unconfirmed")
		this.Tasks := Map()
		this.Owners := Map()
		this.Confirmed := Map()
		this.InFlight := 0
		this.Closing := false
		this.Cleaning := false
		this.Closed := false
		this.Errors := []
		this.DeleteDirectory := DeleteDirectory
		; CreateDirectory, unlike DirCreate, refuses a preexisting candidate.
		this._Directory := _CRWF_CreateDirectory(A_Temp . "\ergopti_crash_fixture_"
			. Label . "_" . DllCall("GetCurrentProcessId", "UInt") . "_" . A_ScriptHwnd . "_" . ++Serial)
	}

	Directory {
		get => this._Directory
	}

	Spawn(SpawnFn, Executable, Args, Done) {
		PreviousCritical := Critical("On")
		try {
			if this.Closing
				return false
			this.InFlight += 1
		} finally Critical(PreviousCritical)
		Task := 0
		try {
			Task := SpawnFn.Call(Executable, Args, Done)
			return Task
		} finally {
			PreviousCritical := Critical("On")
			try {
				if IsObject(Task)
					this.Tasks[ObjPtr(Task)] := Task
				this.InFlight -= 1
			} finally Critical(PreviousCritical)
		}
	}

	CaptureOwners() {
		global _CrashReportWorkerOwners
		PreviousCritical := Critical("On")
		try {
			for _, Owner in _CrashReportWorkerOwners {
				Task := Owner.Get("task", 0)
				if IsObject(Task) && this.Tasks.Has(ObjPtr(Task))
					this.Owners[ObjPtr(Owner)] := Owner
			}
		} finally Critical(PreviousCritical)
	}

	Start(Payload, Done, SpawnFn := _CrashReportWorkerSpawnOwned, WorkerPath?, Options?) {
		if this.Closing
			return 0
		Spawn := (Executable, Args, Callback) => this.Spawn(SpawnFn, Executable, Args, Callback)
		try return CrashReportWorker_Start(Payload, Done, Spawn, WorkerPath?, Options?)
		finally this.CaptureOwners()
	}

	Cleanup() {
		global _CRWF_PendingCleanup
		PreviousCritical := Critical("On")
		try {
			if this.Closed
				return true
			this.Closing := true
			_CRWF_PendingCleanup[ObjPtr(this)] := this
			if this.Cleaning || this.InFlight
				return false
			this.Cleaning := true
		} finally Critical(PreviousCritical)
		this.Errors := []
		try {
			this.CaptureOwners()
			Matched := Map()
			for _, Owner in this.Owners {
				Task := Owner.Get("task", 0)
				if IsObject(Task)
					Matched[ObjPtr(Task)] := true
				try {
					if !_CrashReportWorkerCancelOwner(Owner)
						throw Error("Exact crash worker termination remains unconfirmed")
					if IsObject(Task)
						this.Confirmed[ObjPtr(Task)] := true
				} catch as Err
					this.Errors.Push(Err.Message)
			}
			for Identity, Task in this.Tasks {
				if Matched.Has(Identity) || this.Confirmed.Has(Identity)
					continue
				try {
					if Task.terminate() != true
						throw Error("Unpublished or completed fixture task termination remains unconfirmed")
					this.Confirmed[Identity] := true
				} catch as Err
					this.Errors.Push(Err.Message)
			}
			if this.Errors.Length
				return false
			try {
				if this.DeleteDirectory.Call(this._Directory) != true
					throw Error("Crash fixture directory deletion was refused")
			}
			catch as Err {
				this.Errors.Push(Err.Message)
				return false
			}
			this.Closed := true
			this.Tasks.Clear()
			this.Owners.Clear()
			this.Confirmed.Clear()
			_CRWF_PendingCleanup.Delete(ObjPtr(this))
			return true
		} finally this.Cleaning := false
	}

	Finish(Failure := 0) {
		try {
			if this.Cleanup()
				return
		} catch as Err
			this.Errors.Push(Err.Message)
		Detail := "Crash fixture cleanup retained " . this._Directory
			. ": " . _DescribeValue(this.Errors)
		if Failure is Error
			Failure.Message .= "`n" . Detail
		else
			throw Error(Detail)
	}

	Run(Callback) {
		Failure := 0
		try return Callback.Call(this)
		catch as Err {
			Failure := Err
			throw Err
		} finally this.Finish(Failure)
	}
}
