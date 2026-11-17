; tests/unit/gestures/engine/test_display_mirror_toggle.ahk

; ==============================================================================
; MODULE: Display Mirror Toggle (Windows)
; DESCRIPTION:
; Runs display_mirror_toggle on the real SystemControl with only its one native
; seam answered: User32's three calls fill real DISPLAYCONFIG_PATH_INFO buffers,
; so the row layout, the buffer protocol and the toggle are all exercised without
; ever changing the screens of the machine that runs the suite.
;
; ROOT CAUSES ENCODED:
; 1. The action had no Windows handler: its reason sent the user to Win+P.
; 2. MonitorGetCount cannot count here: duplicated displays are one monitor, so
;    a toggle back from a mirror would have been refused as "one display".
; ==============================================================================

#Requires AutoHotkey v2.0

; SystemControl with DisplayConfigCall answered from a list of connected targets.
class _MirrorSystem extends SystemControl {
	__New(Targets, Topology) {
		this.Targets := Targets
		this.Topology := Topology
		this.Applied := []
		this.Notices := []
		this.BufferMisses := 0
		this.ApplyStatus := 0
		this.QueryStatus := 0
	}
	Notify(Text) => this.Notices.Push(Text)
	DisplayConfigCall(Name, Args*) {
		switch Name {
			case "GetDisplayConfigBufferSizes":
				NumPut("UInt", this.Targets.Length, Args[4])
				NumPut("UInt", 1, Args[6])
				return 0
			case "QueryDisplayConfig":
				return this._Query(Args)
			case "SetDisplayConfig":
				if (Args[10] & 0x80) = 0
					throw ValueError("SetDisplayConfig without SDC_APPLY.")
				if this.ApplyStatus = 0 {
					this.Applied.Push(Args[10] & 0xF)
					this.Topology := Args[10] & 0xF
				}
				return this.ApplyStatus
		}
		throw ValueError("Unexpected display call.", -1, Name)
	}
	_Query(Args) {
		if this.BufferMisses > 0 {
			this.BufferMisses -= 1
			return 122
		}
		if this.QueryStatus != 0
			return this.QueryStatus
		AsksTopology := Args[2] = 0x4
		AssertEqual(AsksTopology, Args[12] != 0, "only the database view names a topology pointer")
		if AsksTopology
			NumPut("UInt", this.Topology, Args[12])
		for Index, Target in this.Targets {
			Row := Args[6] + (Index - 1) * 72
			NumPut("UInt", Target.Adapter, Row + 20)
			NumPut("Int", 0, Row + 24)
			NumPut("UInt", Target.Id, Row + 28)
			NumPut("UInt", Target.Available, Row + 60)
		}
		return 0
	}
}

_Mirror_Reset() {
	global _GestureMirrorPriorTopology
	_GestureMirrorPriorTopology := 0
}

_Mirror_Two() => [{ Adapter: 7, Id: 1, Available: 1 }, { Adapter: 7, Id: 2, Available: 1 }]

_Mirror_RestoresPrior() {
	for Prior in [0x1, 0x4, 0x8] {
		_Mirror_Reset()
		Sys := _MirrorSystem(_Mirror_Two(), Prior)
		AssertTrue(GestureDisplayMirrorToggle(Sys), "the first press mirrors")
		AssertEqual(0x2, Sys.Topology, "the displays are mirrored")
		AssertTrue(GestureDisplayMirrorToggle(Sys), "the second press goes back")
		AssertEqual(Prior, Sys.Topology, "the topology it found is the one it restores")
		AssertEqual(2, Sys.Applied.Length, "one change per press")
	}
}
Test("display mirror: the toggle restores the topology it found (display-mirror)", _Mirror_RestoresPrior)

_Mirror_OneDisplayRefuses() {
	_Mirror_Reset()
	; One screen seen through two sources, plus a port with nothing plugged in.
	Sys := _MirrorSystem([{ Adapter: 7, Id: 1, Available: 1 }, { Adapter: 7, Id: 1, Available: 1 },
		{ Adapter: 7, Id: 2, Available: 0 }], 0x4)
	AssertFalse(GestureDisplayMirrorToggle(Sys), "one display cannot be mirrored")
	AssertEqual(0, Sys.Applied.Length, "the screens are left alone")
	AssertEqual(1, Sys.Notices.Length, "the refusal is said in words")
	AssertEqual(t("shortcuts.no_other_monitor"), Sys.Notices[1])
}
Test("display mirror: one connected display refuses in words (display-mirror)", _Mirror_OneDisplayRefuses)

_Mirror_MirrorCountsBothDisplays() {
	_Mirror_Reset()
	; Same target id on two adapters are two displays; a mirror this run did not start.
	Sys := _MirrorSystem([{ Adapter: 7, Id: 1, Available: 1 }, { Adapter: 8, Id: 1, Available: 1 }], 0x2)
	AssertEqual(2, Sys.ConnectedDisplayCount())
	AssertTrue(GestureDisplayMirrorToggle(Sys), "a foreign mirror is not refused as one display")
	AssertEqual(0x4, Sys.Topology, "a mirror with no remembered topology leaves for Extend")
}
Test("display mirror: a mirror counts its displays and has a way back (display-mirror)", _Mirror_MirrorCountsBothDisplays)

_Mirror_RetriesAResizedConfiguration() {
	_Mirror_Reset()
	Sys := _MirrorSystem(_Mirror_Two(), 0x4)
	Sys.BufferMisses := 2
	AssertEqual(2, Sys.ConnectedDisplayCount(), "a display plugged in mid-read only costs a new read")
	Sys.BufferMisses := 3
	AssertThrows(() => Sys.ConnectedDisplayCount(), "the read is bounded")
}
Test("display mirror: a configuration changing mid-read is read again, boundedly (display-mirror)", _Mirror_RetriesAResizedConfiguration)

_Mirror_FailuresAreNotHidden() {
	global _GestureMirrorPriorTopology
	_Mirror_Reset()
	Sys := _MirrorSystem(_Mirror_Two(), 0x4)
	Sys.ApplyStatus := 1610
	AssertThrows(() => GestureDisplayMirrorToggle(Sys), "a refused change is an error")
	AssertEqual(0, _GestureMirrorPriorTopology, "a change that did not happen is not remembered")
	Sys.ApplyStatus := 0
	Sys.QueryStatus := 5
	AssertThrows(() => GestureDisplayMirrorToggle(Sys), "a refused read is an error")
	AssertEqual(0, Sys.Applied.Length)
	Unknown := _MirrorSystem(_Mirror_Two(), 0)
	AssertThrows(() => GestureDisplayMirrorToggle(Unknown), "an unknown topology is not guessed")
	AssertEqual(0, Unknown.Applied.Length)
}
Test("display mirror: a refused read or change is an error, not a remembered state (display-mirror)", _Mirror_FailuresAreNotHidden)

_Mirror_ActionIsOffered() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	AssertTrue(GESTURE_ACTIONS.Has("display_mirror_toggle"), "the action has a handler")
	AssertTrue(GESTURE_ACTION_CATALOGUE.Actions.Has("display_mirror_toggle"), "the action is offered on Windows")
}
Test("display mirror: the action is offered on Windows (display-mirror)", _Mirror_ActionIsOffered)

; Read-only: the real API answers this machine's layout, whatever it is, without
; a mirror ever being applied.
_Mirror_RealReadAnswers() {
	Sys := SystemControl()
	AssertTrue(Sys.ConnectedDisplayCount() >= 1, "the machine running the suite has a display")
	AssertTrue(Sys.DisplayTopology() is Integer, "the current topology is read")
}
Test("display mirror: the real configuration read answers on this machine (display-mirror)", _Mirror_RealReadAnswers)
