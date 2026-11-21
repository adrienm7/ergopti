; tests/unit/modules/shortcuts/test_keepawake_end_notice.ahk

; ==============================================================================
; MODULE: Keep-Awake End Notice Vectors (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/shortcuts/keep_awake_end_notice_vectors.json:
; every end of a running keep-awake session shows one short notice with the
; shared locale key, and a session that was not running shows none (maintainer
; decision SNU-12, 21 November 2026). macOS and Linux replay the same file.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Ends the session the way the case's cause does on Windows.
 * @param {String} Cause toggle, activity or pause.
 */
_KAEN_End(Cause) {
	switch Cause {
		case "toggle":
			ToggleActivitySimulation()
		case "activity":
			; The mouse-button observer; the pointer and keypress observers queue
			; the same StopActivitySimulation call.
			AwakeCancelOnMouse()
		case "pause":
			; The lifecycle's keep-awake pause step (core/lifecycle/engine/lifecycle.ahk).
			StopActivitySimulation()
		default:
			throw ValueError("Unknown keep-awake end cause: " . Cause)
	}
}

_KAEN_ReplayVectors() {
	global ActivitySimulation, AwakeInputHook
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\shortcuts\keep_awake_end_notice_vectors.json"
	Data := JsonParse(FileRead(Path, "UTF-8"))
	Expected := t(Data["key"])
	AssertTrue(Expected != "", "the shared end key must resolve")
	Replayed := 0
	for Vector in Data["cases"] {
		Applies := false
		for Driver in Vector["drivers"]
			Applies := Applies || Driver == "windows"
		if !Applies
			continue
		AssertFalse(ActivitySimulation, Vector["id"] . ": the replay starts from an idle production state")
		Shown := []
		NotifierSetDisplaySink((Message, Title, Flag) => (Shown.Push(Message), 1))
		try {
			ActivitySimulation := Vector["active"]
			_KAEN_End(Vector["cause"])
		} finally {
			NotifierSetDisplaySink(0)
			ActivitySimulation := false
			AwakeInputHook := ""
		}
		AssertEqual(Vector["notices"], Shown.Length, Vector["id"] . ": one notice per end of a running session")
		for Message in Shown
			AssertEqual(Expected, Message, Vector["id"] . ": the notice is the shared end key's text")
		Replayed += 1
	}
	AssertEqual(4, Replayed, "every Windows case of the shared vectors is replayed")
}
Test("keep-awake: every end of a running session shows the shared end notice once (snu-12-2026-11-21)",
	_KAEN_ReplayVectors)
