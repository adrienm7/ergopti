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

	/** Emits closed request metadata without forcing file I/O or altering admission. */
	_ObserveBuild(Reason, Generation) {
		if !(Generation is Integer) || Generation < 1
			return
		static Known := Map("boot", true, "post_pull", true,
			"aux_completion", true, "backend_committed", true, "backend_lifecycle", true,
			"deps_failure", true, "live_mode", true, "local_servers_applied", true,
			"local_servers_deferred_discovery", true, "local_servers_initialized", true,
			"local_servers_lifecycle_repaired", true, "local_servers_published", true,
			"local_servers_rescan", true, "local_servers_view_prepared", true,
			"model_committed", true, "ollama_port_committed", true,
			"standard_committed", true, "toggle_committed", true)
		ClosedReason := Known.Has(Reason) ? Reason : "other"
		try LoggerInfo("LLMBuildObservation." . ClosedReason,
			"Build entered; generation={1}.", Generation)
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
				TargetReason := this.LatestReason
			} finally Critical(PreviousCritical)

			this._ObserveBuild(TargetReason, TargetGeneration)
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
