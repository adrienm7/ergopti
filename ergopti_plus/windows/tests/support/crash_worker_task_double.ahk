; tests/support/crash_worker_task_double.ahk

; ==============================================================================
; MODULE: Crash Worker Task Double
; DESCRIPTION:
; Preserves the native distinction between revoking termination and termination
; with a single completion notification. Refused stops retain task ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

class _CRWT_TaskDouble {
	__New(Done, Stop) {
		this.Done := Done
		this.Stop := Stop
		this.Stopped := false
		this.Detached := false
		this.Notified := false
	}

	start() {
		return !this.Stopped
	}

	_Stop() {
		if !this.Stopped
			this.Stopped := this.Stop.Call() == true
		return this.Stopped
	}

	terminate() {
		this.Detached := true
		return this._Stop()
	}

	requestTerminate() {
		Stopped := this._Stop()
		if Stopped && !this.Detached && !this.Notified {
			this.Notified := true
			this.Done.Call(1, "", "")
		}
		return Stopped
	}
}
