; tests/unit/modules/gestures/test_raw_touchpad_owner.ahk

; ==============================================================================
; MODULE: Raw Touchpad Owner and Incremental Tracker Tests
; DESCRIPTION:
; Drives the whole Windows incremental chain on synthetic Precision Touchpad
; reports: descriptor, reports, frames, live travel, the tracker
; (modules/gestures/incremental_tracker.ahk) and the owner
; (modules/gestures/raw_touchpad.ahk) with its queue and its ownership of the
; Precision Touchpad settings' shortcut. Natives are injected: no touchpad, no
; registration, no registry, no key is sent.
;
; ROOT CAUSE ENCODED:
; Windows stepped through no tab while the fingers moved, and an incremental
; owner beside the registry-mapped shortcut could fire a swipe twice. These pin
; one action per step and exactly one owner per swipe, whichever of the raw
; frames or the shortcut arrives first.
; ==============================================================================

#Requires AutoHotkey v2.0

; The pad of test_touchpad_hid.ahk: 32 logical units per mm along x.
global _RTO_UNITS_X := 32





; ============================================
; ============================================
; ======= 1/ Fixtures ========================
; ============================================
; ============================================

; An owner over fakes: Modes maps slot -> mode, every step is Step mm, each
; dispatched slot is recorded, and scheduled drains run when the test says.
class _RTO_Harness {
	__New(Modes, Step := 3.5) {
		this.dispatched := []
		this.scheduled := []
		this.modes := Modes
		this.step := Step
		this.reader := _TPH_Reader()
		this.owner := RawTouchpadOwner(Map(
			"minimums", Map("swipe_minimum_mm", 1.5, "pair_swipe_minimum_mm", 3.0, "pair_diagonal_minimum_mm", 5.0),
			"stable_frames", 2, "handoff_ms", 300,
			"mode_of", ObjBindMethod(this, "ModeOf"), "step_of", ObjBindMethod(this, "StepOf"),
			"dispatch", ObjBindMethod(this, "Dispatch"), "schedule", ObjBindMethod(this, "Schedule")))
	}

	ModeOf(Slot) => this.modes.Get(Slot, "")
	StepOf(Slot) => this.step

	Dispatch(Slot) {
		this.dispatched.Push(Slot)
		return true
	}

	Schedule(Callback) {
		this.scheduled.Push(Callback)
	}

	; Runs the scheduled drains, as the timer thread would.
	Run() {
		while this.scheduled.Length
			this.scheduled.RemoveAt(1).Call()
		return this
	}

	; A five-finger pad, or one with no physical size.
	Pad(Handle := 1, PhysicalX := 1000) {
		this.owner.AddDevice(Handle, _TPH_PadCaps(5, PhysicalX, PhysicalX = 0 ? 0 : 650), this.reader)
		return this
	}

	; One parallel report of N fingers at x offset Mm millimetres (y offset YMm).
	Report(Fingers, Mm, Now, YMm := 0, Handle := 1) {
		Links := []
		loop 5 {
			Down := A_Index <= Fingers
			Links.Push([A_Index, A_Index, Down ? Round(400 + A_Index * 200 + Mm * _RTO_UNITS_X) : 0,
				Down ? Round(600 + YMm * 2000 / 65) : 0, Down])
		}
		this.reader.Load(Fingers, Links*)
		this.owner.FeedReport(Handle, Now)
		return this
	}

	; The lift frame: every contact up.
	Lift(Now, Handle := 1) {
		this.reader.Load(1, [1, 1, 0, 0, false])
		this.owner.FeedReport(Handle, Now)
		return this
	}

	; Three fingers land and hold (two frames), at x offset Mm.
	Land(Fingers, Now, Mm := 0) {
		this.Report(Fingers, Mm, Now)
		this.Report(Fingers, Mm, Now + 8)
		return this
	}

	Joined() {
		Out := ""
		for Slot in this.dispatched
			Out .= (Out = "" ? "" : ",") . Slot
		return Out
	}
}

; Repeats a slot's name Count times, comma-joined.
_RTO_Times(Slot, Count) {
	Out := ""
	loop Count
		Out .= (A_Index = 1 ? "" : ",") . Slot
	return Out
}

_RTO_Modes() {
	return Map("swipe_3_left", "incremental", "swipe_3_right", "incremental",
		"swipe_3_up", "x1", "swipe_3_down", "x1", "swipe_4_left", "x1", "swipe_4_right", "x1")
}





; ============================================
; ============================================
; ======= 2/ Steps while the fingers move ====
; ============================================
; ============================================

_RTO_StepsWhileMoving() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	Now := 1016
	loop 20 {
		H.Report(3, A_Index, Now)
		Now += 8
	}
	; 20 mm at 3.5 mm a step: the first at 3.5 mm, then 7, 10.5, 14, 17.5.
	AssertEqual(0, H.dispatched.Length, "steps wait for the action thread")
	H.Run()
	AssertEqual(_RTO_Times("swipe_3_right", 5), H.Joined(), "one action per step, in order")
	H.Lift(Now)
	AssertEqual(5, H.dispatched.Length, "the lift fires nothing more")
}
Test("raw touchpad: an incremental slot steps while the fingers move (raw-touchpad)", _RTO_StepsWhileMoving)

_RTO_ReversalRebases() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	Now := 1016
	for Mm in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0] {
		H.Report(3, Mm, Now)
		Now += 8
	}
	H.Run()
	; Right fires at 4 and 7 mm (3.5, 7); coming back from the last fire (7 mm)
	; past 1.75 mm rebases at 5 mm, and 3.5 mm more leftward is one left step.
	AssertEqual("swipe_3_right,swipe_3_right,swipe_3_left", H.Joined(), "the reversal starts fresh")
}
Test("raw touchpad: coming back half a first step reverses the swipe (raw-touchpad)", _RTO_ReversalRebases)

_RTO_OnlyIncrementalSlotsStep() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	; Four fingers right: an x1 slot does not step.
	H.Land(4, 1000)
	Now := 1016
	loop 20 {
		H.Report(4, A_Index, Now)
		Now += 8
	}
	H.Lift(Now).Run()
	AssertEqual(0, H.dispatched.Length, "an x1 slot waits for its shortcut")
	; Two fingers is the system's scroll: Windows has no two-finger slot.
	H.Land(2, 2000)
	loop 20
		H.Report(2, A_Index, 2016 + A_Index * 8)
	H.Lift(2400).Run()
	AssertEqual(0, H.dispatched.Length, "a pair never steps")
}
Test("raw touchpad: only an incremental slot steps (raw-touchpad)", _RTO_OnlyIncrementalSlotsStep)

_RTO_DiagonalAnswersForItsDominantDirection() {
	; Windows has no diagonal slot: a diagonal mostly rightward counts along
	; right, as an unbound diagonal does on macOS and Linux.
	Answer := RawTouchpadAnsweringSlot("swipe_3_right_down", 3, "right_down", "right")
	AssertEqual("swipe_3_right", Answer.slot, "dominant slot")
	AssertEqual("right", Answer.direction, "dominant direction")
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	Now := 1016
	loop 12 {
		H.Report(3, A_Index, Now, A_Index * 0.8)
		Now += 8
	}
	H.Run()
	AssertTrue(H.dispatched.Length >= 1, "the diagonal steps")
	for Slot in H.dispatched
		AssertEqual("swipe_3_right", Slot, "along its dominant direction")
}
Test("raw touchpad: a diagonal steps along its dominant direction (raw-touchpad)", _RTO_DiagonalAnswersForItsDominantDirection)

_RTO_TrackerRefusesAJump() {
	Fired := []
	Fire(Slot, Fingers, Direction, Count) {
		Fired.Push(Count)
		return Count
	}
	Tracker := GestureIncrementalTracker(Map("units_x", 1, "units_y", 1,
		"minimums", Map("swipe_minimum_mm", 1.5, "pair_swipe_minimum_mm", 3.0, "pair_diagonal_minimum_mm", 5.0),
		"mode_of", (Slot) => "incremental", "step_of", (Slot) => 1.0,
		"slot_of", RawTouchpadAnsweringSlot, "fire", Fire))
	Tracker.Update({fingers: 3, dx: 500, dy: 0})
	AssertEqual(0, Fired.Length, "an implausible jump is refused, not truncated")
	Tracker.Update({fingers: 3, dx: 501, dy: 0})
	AssertEqual(0, Fired.Length, "the touch acts no more")
	AssertFalse(Tracker.Finish(), "nothing consumed")
	Tracker.Update({fingers: 3, dx: 2, dy: 0})
	AssertEqual(1, Fired.Length, "a new touch counts again")
	AssertTrue(Tracker.Finish(), "a touch that fired is consumed")
	AssertThrows(() => GestureIncrementalTracker(Map("units_x", 0)), "a tracker needs millimetres")
}
Test("raw touchpad: the tracker refuses a sensor jump (raw-touchpad)", _RTO_TrackerRefusesAJump)





; ============================================
; ============================================
; ======= 3/ One owner per swipe =============
; ============================================
; ============================================

_RTO_SteppedTouchSwallowsItsShortcut() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	Now := 1016
	loop 12 {
		H.Report(3, -A_Index, Now)
		Now += 8
		; Windows recognises the swipe halfway and sends its shortcut.
		if (A_Index = 6)
			AssertEqual("swallow", H.owner.ClaimShortcut("swipe_3_left", Now), "mid-touch shortcut of a stepped swipe")
	}
	H.Lift(Now)
	AssertEqual("swallow", H.owner.ClaimShortcut("swipe_3_left", Now + 100), "a shortcut after the lift")
	H.Run()
	; 12 mm: steps at 3.5, 7, 10.5; the shortcut adds none.
	AssertEqual(_RTO_Times("swipe_3_left", 3), H.Joined(), "exactly the steps, never the shortcut too")
	AssertEqual("dispatch", H.owner.ClaimShortcut("swipe_3_left", Now + 400), "a later shortcut is a new swipe")
}
Test("raw touchpad: a touch that stepped swallows its shortcut, before or after the lift (raw-touchpad)",
	_RTO_SteppedTouchSwallowsItsShortcut)

_RTO_ShortTouchFiresItsShortcutOnce() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	H.Report(3, -1, 1016).Report(3, -2, 1024)
	; 2 mm is below the first step: the shortcut waits for the touch's end.
	AssertEqual("defer", H.owner.ClaimShortcut("swipe_3_left", 1030), "the fingers may still step")
	H.Lift(1040).Run()
	AssertEqual("swipe_3_left", H.Joined(), "the shortcut fires once at the end")
	; An x1 slot's shortcut fires at once.
	H.Land(3, 2000)
	AssertEqual("dispatch", H.owner.ClaimShortcut("swipe_3_up", 2020), "x1 slot")
}
Test("raw touchpad: a touch that did not step fires its shortcut once (raw-touchpad)", _RTO_ShortTouchFiresItsShortcutOnce)

_RTO_SilentTouchExpires() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	AssertEqual("defer", H.owner.ClaimShortcut("swipe_3_right", 1010), "deferred")
	H.owner.Expire(1100, 300)
	H.Run()
	AssertEqual(0, H.dispatched.Length, "frames stopped only 92 ms ago")
	; No lift frame ever came: after the handoff window the touch is over.
	H.owner.Expire(1400, 300)
	H.Run()
	AssertEqual("swipe_3_right", H.Joined(), "a deferred shortcut is never lost")
}
Test("raw touchpad: a touch whose frames stop still releases its shortcut (raw-touchpad)", _RTO_SilentTouchExpires)

_RTO_PadWithoutMillimetres() {
	H := _RTO_Harness(_RTO_Modes())
	H.Pad(1, 0)
	H.Land(3, 1000)
	loop 20
		H.Report(3, A_Index, 1016 + A_Index * 8)
	AssertEqual("dispatch", H.owner.ClaimShortcut("swipe_3_right", 1200), "no millimetres: the shortcut acts")
	H.Run()
	AssertEqual(0, H.dispatched.Length, "and the pad steps nothing")
}
Test("raw touchpad: a pad without a physical size fires once per swipe (raw-touchpad)", _RTO_PadWithoutMillimetres)

_RTO_PauseDropsTheQueue() {
	H := _RTO_Harness(_RTO_Modes()).Pad()
	H.Land(3, 1000)
	loop 8
		H.Report(3, A_Index, 1016 + A_Index * 8)
	AssertTrue(H.owner.Queued() > 0, "steps are queued")
	H.owner.Reset(1200)
	H.Run()
	AssertEqual(0, H.dispatched.Length, "pause drops every queued step")
	; The next touch after the pause counts from zero.
	H.Land(3, 2000)
	loop 4
		H.Report(3, A_Index, 2016 + A_Index * 8)
	H.Run()
	AssertEqual("swipe_3_right", H.Joined(), "a fresh touch")
}
Test("raw touchpad: pause drops the touch and its queued steps (raw-touchpad)", _RTO_PauseDropsTheQueue)

_RTO_DevicesAreLearntOnceAndForgotten() {
	H := _RTO_Harness(_RTO_Modes())
	H.owner.RefuseDevice(9, "collection 0x1/0x2 is no touchpad")
	AssertTrue(H.owner.HasDevice(9), "a refused device is remembered")
	H.owner.FeedReport(9, 1000)
	AssertEqual("", H.owner.Device(9), "and read no more")
	H.Pad(3)
	H.owner.RemoveDevice(3, 1100)
	AssertFalse(H.owner.HasDevice(3), "a removed touchpad is forgotten")
	H.owner.RemoveDevice(3, 1100)
	AssertThrows(() => RawTouchpadOwner(Map()), "the owner needs its natives")
}
Test("raw touchpad: devices are learnt once and forgotten on removal (raw-touchpad)", _RTO_DevicesAreLearntOnceAndForgotten)

_RTO_ProductionGlueIsInertWithoutAnOwner() {
	global _RawTouchpadOwner
	AssertFalse(IsObject(_RawTouchpadOwner), "the headless runner starts no reader")
	AssertFalse(RawTouchpadClaimsShortcut("swipe_3_left"), "no reader: every shortcut acts")
	AssertTrue(RawTouchpadStop(), "stopping a reader that never started is a no-op")
	AssertTrue(RawTouchpadOnPause(), "and so is pausing it")
}
Test("raw touchpad: without a reader the shortcut path is unchanged (raw-touchpad)", _RTO_ProductionGlueIsInertWithoutAnOwner)
