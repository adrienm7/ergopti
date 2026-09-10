; modules/keylogger/keylogger_system_intervals.ahk

; ==============================================================================
; MODULE: System Passive Interval Ownership
; DESCRIPTION: Partition observed lock and sleep time without overlapping intervals.
; ==============================================================================

#Requires AutoHotkey v2.0

class KLSystemIntervals {
	__New() {
		this.Generation := 0
		this.Reset()
	}

	; A collection boundary invalidates intervals whose opposite edge was hidden.
	Reset() {
		this.Generation += 1
		this.Locked := false
		this.Sleeping := false
		this.Kind := ""
		this.Since := 0
		this.LastTick := 0
	}

	ValidateTick(Tick) {
		if !(Tick is Integer) || Tick < this.LastTick
			throw ValueError("System intervals require a monotonic integer clock.")
	}

	/**
	 * Observes a physical transition and detaches any completed passive interval.
	 * @param Action One of lock, unlock, sleep or wake.
	 * @param Tick Monotonic milliseconds, including time spent asleep.
	 * @returns {Map|Integer} Completed kind/duration_ms, or zero when no interval ended.
	 */
	Observe(Action, Tick) {
		if !(Action == "lock" || Action == "unlock" || Action == "sleep" || Action == "wake")
			throw ValueError("Unknown system interval transition.")
		this.ValidateTick(Tick)
		this.LastTick := Tick
		if Action == "lock"
			this.Locked := true
		else if Action == "unlock"
			this.Locked := false
		else if Action == "sleep"
			this.Sleeping := true
		else
			this.Sleeping := false
		; Sleep takes precedence while the workstation remains locked.
		Next := this.Sleeping ? "sleep" : this.Locked ? "lock" : ""
		if Next == this.Kind
			return 0
		Completed := this.CompletedAt(Tick)
		this.Kind := Next
		this.Since := Tick
		return Completed
	}

	CompletedAt(Tick) {
		return this.Kind != "" && Tick > this.Since
			? Map("kind", this.Kind, "duration_ms", Tick - this.Since) : 0
	}

	/**
	 * Detaches the final observed interval before the owner's durable shutdown drain.
	 * @param Tick Monotonic shutdown boundary in milliseconds.
	 * @returns {Map|Integer} The completed interval, or zero after an empty/repeated finish.
	 */
	Finish(Tick) {
		this.ValidateTick(Tick)
		Completed := this.CompletedAt(Tick)
		this.Locked := false
		this.Sleeping := false
		this.Kind := ""
		this.Since := Tick
		this.LastTick := Tick
		return Completed
	}
}
