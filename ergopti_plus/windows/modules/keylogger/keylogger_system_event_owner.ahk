; modules/keylogger/keylogger_system_event_owner.ahk

; ==============================================================================
; MODULE: System Event Publication Ownership
; DESCRIPTION: Preserve physical transitions and exact pending measurements across delivery attempts.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include keylogger_system_intervals.ahk

class KLSystemEventOwner {
	__New(ClockFn, AppendFn, AllowedFn) {
		for Port in [ClockFn, AppendFn, AllowedFn]
			if !HasMethod(Port, "Call")
				throw TypeError("System event ownership requires callable clock, append and admission ports.")
		this.ClockFn := ClockFn
		this.AppendFn := AppendFn
		this.AllowedFn := AllowedFn
		this.Intervals := KLSystemIntervals()
		this.Pending := []
		this.Draining := false
		this.Stopping := false
		this.Stopped := false
		this.LastFailure := ""
	}

	Reset() {
		PreviousCritical := Critical("On")
		try {
			this.Intervals.Reset()
			this.Pending := []
		} finally Critical(PreviousCritical)
	}

	; Pause hides the opposite physical edge, but completed records remain exact.
	Pause() {
		PreviousCritical := Critical("On")
		try this.Intervals.Reset()
		finally Critical(PreviousCritical)
	}

	Capture() {
		Frame := this.ClockFn.Call()
		if !(Frame is Map) || !Frame.Has("tick") || !Frame.Has("timestamp")
			throw TypeError("System event clock must return tick and timestamp.")
		this.Intervals.ValidateTick(Frame["tick"])
		if !(Frame["timestamp"] is String) || Frame["timestamp"] = ""
			throw ValueError("System event timestamp must be a nonempty string.")
		return Map("tick", Frame["tick"], "timestamp", Frame["timestamp"])
	}

	Enqueue(Action, Metadata, Timestamp) {
		Entry := Map("type", "system_event", "action", Action, "timestamp", Timestamp)
		for Key, Value in Metadata
			Entry[Key] := Value
		this.Pending.Push(Map("entry", Entry, "committed", false))
	}

	/**
	 * Records a physical edge and attempts delivery of raw and completed interval records.
	 * @param Action The observed lock, unlock, sleep or wake edge.
	 * @returns {Integer} True when no technical delivery debt remains; privacy drops are terminal.
	 */
	Observe(Action) {
		PreviousCritical := Critical("On")
		try {
			if this.Stopping || this.Stopped
				throw Error("A stopped system event owner cannot observe transitions.")
			if !this.AllowedFn.Call() {
				this.Pause()
				return this.Pending.Length = 0
			}
			Generation := this.Intervals.Generation
			Frame := this.Capture()
			if Generation != this.Intervals.Generation
				return false
			Completed := this.Intervals.Observe(Action, Frame["tick"])
			this.Enqueue(Action, Map(), Frame["timestamp"])
			if Completed
				this.Enqueue("passive_period", Completed, Frame["timestamp"])
		} finally Critical(PreviousCritical)
		return this.Drain()
	}

	IsCurrent(Record, Generation) {
		return !this.Stopped && Generation = this.Intervals.Generation
			&& this.Pending.Length && this.Pending[1] == Record
			&& this.AllowedFn.Call()
	}

	Commit(Record, Generation) {
		if !this.IsCurrent(Record, Generation)
			throw Error("An invalidated system event cannot commit.")
		Record["committed"] := true
	}

	RemoveHead(Record) {
		if this.Pending.Length && this.Pending[1] == Record
			this.Pending.RemoveAt(1)
	}

	; The append port must pair queue mutation and Commit under its own guard.
	; False means privacy/validation refusal, which must never be replayed later.
	Drain() {
		PreviousCritical := Critical("On")
		try {
			if this.Draining
				return true
			this.Draining := true
		} finally Critical(PreviousCritical)
		this.LastFailure := ""
		try {
			if !this.AllowedFn.Call() {
				this.Pause()
				this.LastFailure := this.Pending.Length ? "collection-paused" : ""
				return this.Pending.Length = 0
			}
			while this.Pending.Length {
				if !this.AllowedFn.Call() {
					this.Pause()
					this.LastFailure := "collection-paused"
					return false
				}
				Record := this.Pending[1]
				Generation := this.Intervals.Generation
				if !this.IsCurrent(Record, Generation) {
					this.LastFailure := "publication-invalidated"
					return false
				}
				try Accepted := this.AppendFn.Call(Record["entry"],
					this.IsCurrent.Bind(this, Record, Generation), this.Commit.Bind(this, Record, Generation))
				catch Error {
					if Record["committed"]
						this.RemoveHead(Record)
					this.LastFailure := "append-exception"
					return false
				}
				if Record["committed"]
					this.RemoveHead(Record)
				if !(Accepted is Integer) || (Accepted != 0 && Accepted != 1)
					|| (Accepted = 1 && !Record["committed"])
					|| (Accepted = 0 && Record["committed"]) {
					this.LastFailure := "append-contract"
					return false
				}
				if !Accepted
					this.RemoveHead(Record)
			}
			return true
		} finally this.Draining := false
	}

	/**
	 * Closes the observed interval once, retaining exact delivery debt for repeated stops.
	 * @returns {Integer} True once every authorized closing record has left this owner.
	 */
	Stop() {
		if this.Stopped
			return true
		PreviousCritical := Critical("On")
		try {
			if !this.Stopping {
				if this.AllowedFn.Call() {
					Generation := this.Intervals.Generation
					Frame := this.Capture()
					if Generation != this.Intervals.Generation
						return false
					Completed := this.Intervals.Finish(Frame["tick"])
					if Completed
						this.Enqueue("passive_period", Completed, Frame["timestamp"])
				} else
					this.Pause()
				this.Stopping := true
			}
		} finally Critical(PreviousCritical)
		; A reentrant stop must leave the outer drain responsible for its queue.
		if this.Draining
			return false
		if !this.Drain()
			return false
		this.Stopped := true
		return true
	}
}
