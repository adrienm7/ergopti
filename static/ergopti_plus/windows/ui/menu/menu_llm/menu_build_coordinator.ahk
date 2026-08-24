; ui/menu/menu_llm/menu_build_coordinator.ahk

; ==============================================================================
; MODULE: LLM Menu Build Coordinator
; DESCRIPTION:
; Retains one monotonically versioned menu-build request across re-entry,
; Suspend, and failed detached construction. The active owner drains only the
; newest requested generation; publication is acknowledged only by a strict
; successful BuildFn result.
; ==============================================================================

#Requires AutoHotkey v2.0

class LLMMenuBuildCoordinator {
	__New(BuildFn, IsSuspendedFn, ErrorFn := 0) {
		if !HasMethod(BuildFn, "Call")
			throw TypeError("LLM menu build coordinator requires a build callback")
		if !HasMethod(IsSuspendedFn, "Call")
			throw TypeError("LLM menu build coordinator requires a suspend callback")
		if IsObject(ErrorFn) && !HasMethod(ErrorFn, "Call")
			throw TypeError("LLM menu build coordinator error callback must be callable")
		this.BuildFn := BuildFn
		this.IsSuspendedFn := IsSuspendedFn
		this.ErrorFn := ErrorFn
		this.RequestedGeneration := 0
		this.PublishedGeneration := 0
		this.Active := false
		this.LatestReason := ""
	}

	Request(Reason := "unspecified") {
		if !(Reason is String) || Reason == ""
			throw ValueError("LLM menu build reason must be a non-empty string")
		PreviousCritical := Critical("On")
		try {
			this.RequestedGeneration += 1
			this.LatestReason := Reason
			if this.Active
				return true
			if this._IsSuspended()
				return false
			this.Active := true
		} finally Critical(PreviousCritical)
		return this._Drain()
	}

	Service() {
		PreviousCritical := Critical("On")
		try {
			if this.Active
				return true
			if this.PublishedGeneration >= this.RequestedGeneration
				return true
			if this._IsSuspended()
				return false
			this.Active := true
		} finally Critical(PreviousCritical)
		return this._Drain()
	}

	_IsSuspended() {
		try Suspended := this.IsSuspendedFn.Call()
		catch
			return true
		return (Suspended is Integer) && Suspended != 0
	}

	_Release() {
		PreviousCritical := Critical("On")
		try this.Active := false
		finally Critical(PreviousCritical)
	}

	_Report(Err) {
		if !HasMethod(this.ErrorFn, "Call")
			return
		try this.ErrorFn.Call(Err)
	}

	_Drain() {
		loop {
			PreviousCritical := Critical("On")
			try {
				if this._IsSuspended() {
					this.Active := false
					return false
				}
				if this.PublishedGeneration >= this.RequestedGeneration {
					this.Active := false
					return true
				}
				TargetGeneration := this.RequestedGeneration
			} finally Critical(PreviousCritical)

			try Published := this.BuildFn.Call()
			catch as Err {
				this._Report(Err)
				this._Release()
				return false
			}
			if !((Published is Integer) && Published == 1) {
				this._Release()
				return false
			}

			PreviousCritical := Critical("On")
			try {
				this.PublishedGeneration := Max(
					this.PublishedGeneration, TargetGeneration)
				if this.PublishedGeneration >= this.RequestedGeneration {
					this.Active := false
					return true
				}
				if this._IsSuspended() {
					this.Active := false
					return false
				}
			} finally Critical(PreviousCritical)
		}
	}
}
