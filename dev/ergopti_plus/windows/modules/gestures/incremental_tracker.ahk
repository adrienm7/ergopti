; modules/gestures/incremental_tracker.ahk

; ==============================================================================
; MODULE: Incremental Swipe Tracker (Windows)
; DESCRIPTION:
; Fires an incremental slot's action while the fingers move, one action per
; step of travel, as linux/modules/gestures/incremental_tracker.lua and the
; macOS engine do: three fingers moving across the pad step through tabs one
; by one instead of switching one tab per swipe. Its travel comes from the raw
; HID digitizer reader (modules/gestures/raw_touchpad.ahk).
;
; FEATURES & RATIONALE:
; 1. Millimetres, as on macOS and Linux: the reader's travel is in logical HID
;    units, and the touchpad's own descriptor (logical span over physical size)
;    converts it, so one sensitivity means the same distance on every system.
; 2. The shared step rule (modules/gestures/incremental.ahk, the port of
;    _shared/gestures/engine/incremental.lua): the first action after the first
;    step, each further one after one more step; a shrinking distance keeps
;    the actions fired.
; 3. Reversal from the last fire: coming back half a first step rebases the
;    swipe there, so the opposite direction starts fresh.
; 4. The mode and step are those of the slot that answers (SlotOf): Windows
;    has no diagonal slot, so a diagonal answers for its dominant straight one.
; 5. Pure: travel in, fire requests out, through the caller's functions. The
;    caller owns dispatch, pause and ownership of the completed swipe.
; ==============================================================================

#Requires AutoHotkey v2.0

class GestureIncrementalTracker {
	/**
	 * @param {Map} Options units_x, units_y (logical units per millimetre);
	 *     minimums (Map of the [gestures] *_minimum_mm timings); mode_of(slot);
	 *     step_of(slot); slot_of(slot, fingers, direction, dominant) -> an
	 *     object {slot, direction} naming the slot whose mode and step apply;
	 *     fire(slot, fingers, direction, count) -> the actions it accepted.
	 */
	__New(Options) {
		if !(Options is Map)
			throw TypeError("The incremental tracker needs its options.")
		for Name in ["units_x", "units_y"] {
			if !Options.Has(Name) || !(Options[Name] is Number) || Options[Name] <= 0
				throw ValueError("The incremental tracker needs the touchpad resolution in units per millimetre.")
		}
		for Name in ["mode_of", "step_of", "slot_of", "fire"] {
			if !Options.Has(Name) || !HasMethod(Options[Name], "Call")
				throw TypeError("The incremental tracker needs " . Name . ".")
		}
		if !Options.Has("minimums") || !(Options["minimums"] is Map)
			throw TypeError("The incremental tracker needs the swipe minimums.")
		this._units_x := Options["units_x"]
		this._units_y := Options["units_y"]
		this._mode_of := Options["mode_of"]
		this._step_of := Options["step_of"]
		this._slot_of := Options["slot_of"]
		this._fire := Options["fire"]
		this._minimums := Options["minimums"]
		this._state := ""
	}

	; Whether the touch in progress already acted while moving.
	; @returns {Boolean}
	Fired() {
		return IsObject(this._state) && this._state.fired
	}

	; Feeds the reader's live travel of one frame.
	; @param Progress {Object|String} {fingers, dx, dy} in logical units since
	;     the finger count started, or "" when no swipe moves.
	Update(Progress) {
		if !IsObject(Progress)
			return
		X := Progress.dx / this._units_x, Y := Progress.dy / this._units_y
		Fingers := Progress.fingers
		if !IsObject(this._state) || this._state.fingers != Fingers {
			; The travel already starts where this finger count started.
			; The finger count's minimums are read once per count, not per frame.
			GestureDirectionMinimumsMm(Fingers, this._minimums, &Minimum, &DiagonalMinimum)
			this._state := {fingers: Fingers, ox: 0, oy: 0, committed: 0, sign: 0, lx: "", ly: "",
				slot: "", dead: false, fired: IsObject(this._state) && this._state.fired,
				minimum: Minimum, diagonal_minimum: DiagonalMinimum}
		}
		State := this._state
		if State.dead
			return
		Rx := X - State.ox, Ry := Y - State.oy
		; Only a decided axis counts: a swipe in the diagonal sector below its
		; minimum would otherwise restart its count when its name turns diagonal.
		Axis := GestureDirectionDecidedAxis(Rx, Ry, State.minimum, State.diagonal_minimum)
		if (Axis = "")
			return
		Direction := GestureDirectionName(Axis, Rx, Ry)
		Slot := Format("swipe_{1}_{2}", Min(Fingers, 5), Direction)
		Answer := this._slot_of.Call(Slot, Fingers, Direction,
			Axis = "diag" ? GestureDirectionDominant(Rx, Ry) : "")
		if !IsObject(Answer) || !Answer.HasOwnProp("slot") || !Answer.HasOwnProp("direction")
			throw TypeError("slot_of must name the slot and the direction that answer.")
		if (Answer.direction != Direction) {
			; An unbound diagonal counts and fires along its dominant direction.
			Direction := Answer.direction
			Slot := Format("swipe_{1}_{2}", Min(Fingers, 5), Direction)
		}
		if (this._mode_of.Call(Answer.slot) != "incremental")
			return
		StepSize := this._step_of.Call(Answer.slot)

		if (State.sign != 0 && State.lx != "") {
			Back := GestureDirectionAlong(Direction, X - State.lx, Y - State.ly)
			BackSign := Back > 0 ? 1 : (Back < 0 ? -1 : 0)
			if (BackSign != 0 && BackSign != State.sign
				&& Abs(Back) >= GestureIncrementalReverseMin(StepSize, GestureIncrementalReverseFloor())) {
				State.ox := X, State.oy := Y, State.committed := 0, State.sign := 0
				State.lx := "", State.ly := "", State.slot := ""
				return
			}
		}
		if (State.slot != "" && State.slot != Slot) {
			; The swipe turned onto another direction without coming back a
			; reversal's worth: it starts counting from here.
			State.ox := X, State.oy := Y, State.committed := 0, State.sign := 0
			State.lx := "", State.ly := "", State.slot := Slot
			return
		}
		State.slot := Slot

		Distance := GestureDirectionAlong(Direction, Rx, Ry)
		Wanted := GestureIncrementalSteps(Abs(Distance), StepSize) - State.committed
		if (Wanted <= 0)
			return
		if (Wanted > GestureIncrementalMaxActions()) {
			; An implausible sensor jump is refused, not truncated.
			State.dead := true
			LoggerWarn("gestures.incremental", "Refused a jump of {1} steps on {2}; the touch acts no more.", Wanted, Slot)
			return
		}
		Fired := this._fire.Call(Slot, Fingers, Direction, Wanted)
		if !(Fired is Integer) || Fired <= 0
			return
		State.committed += Fired
		State.sign := Distance > 0 ? 1 : -1
		State.lx := X, State.ly := Y
		State.fired := true
	}

	; Ends the touch.
	; @returns {Boolean} True when the swipe already acted while moving, so its
	;     completed form must not fire once more.
	Finish() {
		Consumed := this.Fired()
		this._state := ""
		return Consumed
	}
}
