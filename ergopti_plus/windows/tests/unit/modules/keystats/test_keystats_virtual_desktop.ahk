; tests/unit/modules/keystats/test_keystats_virtual_desktop.ahk

; ==============================================================================
; MODULE: Virtual Desktop Change Tests
; DESCRIPTION:
; Windows emitted no space_change, so the shared space-change KPI read zero on
; every PC. These tests drive the observation through its ports.
; ==============================================================================

#Requires AutoHotkey v2.0

_KVD_Observe(Events, Ids) {
	KL_Desktop_Reset()
	LogFn := (Entry) => Events.Push(Entry)
	for Id in Ids
		KL_Desktop_Observe(Id, LogFn, () => "2026-11-06 09:00:00.000")
}

_KVD_ChangesAreCountedOnce() {
	Events := []
	_KVD_Observe(Events, ["AA", "AA", "BB", "BB", "AA"])
	AssertEqual(2, Events.Length, "the baseline and the unchanged readings log nothing")
	AssertEqual("system_event", Events[1]["type"])
	AssertEqual("space_change", Events[1]["action"])
	AssertEqual("BB", Events[1]["space_id"])
	AssertEqual("AA", Events[2]["space_id"])
}
Test("keystats virtual desktop: each desktop change is one space_change (windows-space-change)",
	_KVD_ChangesAreCountedOnce)

_KVD_GapsDropTheBaseline() {
	Events := []
	; An unreadable tick, and a reset (collection paused), each start over.
	_KVD_Observe(Events, ["AA", "", "BB"])
	AssertEqual(0, Events.Length, "a change across an unreadable reading is not credited")
	KL_Desktop_Observe("CC", (Entry) => Events.Push(Entry), () => "t")
	KL_Desktop_Reset()
	KL_Desktop_Observe("DD", (Entry) => Events.Push(Entry), () => "t")
	AssertEqual(1, Events.Length, "a reset drops the baseline")
}
Test("keystats virtual desktop: a gap in the readings is never a change (windows-space-change)",
	_KVD_GapsDropTheBaseline)
