; tests/unit/test_gesture_clear_boot_marker.ahk

; The restart copy exercises the real marker reader and consumer without arming
; a native timer or touching PrecisionTouchPad registry settings.
_GestureClearBootMarker(Scope, Mode, Outcome := "complete") {
	global _PersonalShortcutsRegistry, KeyboardShortcutAssignments, GestureActionParameters, _SharedDir
	global GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS
	OldRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	OldKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	OldParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	Fixture := _HotstringsScopeFixture()
	Original := '[gestures]`nenabled = true`ntap_4 = "open_url"`nauto_configure_on_next_start = true`nunknown_user = "keep"`n[private]`ncredential = "keep"`n'
	Assert(FSWriteDurable(Fixture.path, Original))
	TapPath := Fixture.directory . "\tap_hold.toml"
	Assert(FSWriteDurable(TapPath, '[tap_hold.keys.space]`ntap_action = "open_url"`n'))
	Fixture.options["tap_hold_path"] := TapPath
	Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
	Bundle := 0, Accepted := 0, Refusal := 0, Launches := 0, Backups := 0
	Launch(Success, Borrowed, Refused) {
		Bundle := Borrowed, Accepted := Success, Refusal := Refused, Launches += 1
		return true
	}
	Backup(Path, Content) {
		Backups += 1
		return Outcome == "backup" ? false : FSWriteCreateDurable(Path, Content)
	}
	Fixture.options["reload"] := Launch, Fixture.options["backup"] := Backup
	Scheduled := 0
	Schedule(Action, Delay) {
		Scheduled += 1
		AssertEqual("_DeferredGestureAutoConfigure", Action.Name)
		AssertEqual(-GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS, Delay)
	}
	try {
		_PersonalShortcutsRegistry := Map("__Order", [])
		KeyboardShortcutAssignments := Map(), GestureActionParameters := Map()
		Receipt := Scope == "global" ? ConfigGlobalScopeApply(Mode, Fixture.options)
			: _GES_ApplyScope(Mode, Fixture.options)
		Assert(Backups > 0, "the actual admitted writer must reach its backup boundary")
		if Outcome == "backup" {
			AssertEqual(0, Launches)
			AssertEqual("refused", Receipt["status"])
		} else {
			AssertEqual(1, Launches)
			AssertEqual("pending", Receipt["status"])
			if Outcome == "refused" {
				Refusal.Call("native replacement refused")
				AssertEqual("refused", Receipt["status"])
			} else {
				Accepted.Call()
				AssertEqual("committed", Receipt["status"])
			}
		}
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		if Outcome != "complete"
			AssertEqual(Original, FSReadUtf8Exact(Fixture.path), "refusal restores the exact queued intent")
		RestartPath := Fixture.directory . "\restart-config.toml"
		Assert(FSWriteDurable(RestartPath, FSReadUtf8Exact(Fixture.path)))
		Parsed := TOML_ParseFreshFile(RestartPath)
		AssertEqual("keep", Parsed["gestures"]["unknown_user"])
		AssertEqual("keep", Parsed["private"]["credential"])
		if Mode == "recommended" && Outcome == "complete"
			AssertEqual("alt_tab_monitor", Parsed["gestures"]["tap_4"], "explicit restore imports the monitor-local tap")
		; The clear once deleted the switch with the assignments, so the next
		; gesture the user set did nothing until the switch was found again.
		if Mode == "clear" && Outcome == "complete" {
			Assert(!Parsed["gestures"].Has("tap_4"), "the clear removes the assignments")
			AssertEqual(true, Parsed["gestures"]["enabled"],
				Scope . " clear owns the assignments, not the Gestures switch (gestures-clear-keeps-switch)")
		}
		Raw := IniCacheGet(Parsed, "gestures", "auto_configure_on_next_start")
		if _GestureAutoConfigureFlagEnabled(Raw)
			Assert(GestureConsumeAutoConfigureFlag(RestartPath, 0, (*) => 0, Schedule))
		Expected := Mode == "clear" && Outcome == "complete" ? 0 : 1
		AssertEqual(Expected, Scheduled, "a completed Clear cannot schedule native setup on the next boot")
		if Expected == 0
			Assert(!Parsed["gestures"].Has("auto_configure_on_next_start"), "Clear must remain sparse")
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_PersonalShortcutsRegistry := IsSet(OldRegistry) ? OldRegistry : unset
		KeyboardShortcutAssignments := IsSet(OldKeyboard) ? OldKeyboard : unset
		GestureActionParameters := IsSet(OldParameters) ? OldParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("gesture-clear-boot: completed Gestures Clear cancels queued native setup", _GestureClearBootMarker.Bind("gestures", "clear"))
Test("gesture-clear-boot: completed global Clear cancels queued native setup", _GestureClearBootMarker.Bind("global", "clear"))
Test("gesture-clear-boot: explicit Gestures Restore preserves queued authorization", _GestureClearBootMarker.Bind("gestures", "recommended"))
Test("gesture-clear-boot: explicit global Restore preserves queued authorization", _GestureClearBootMarker.Bind("global", "recommended"))
Test("gesture-clear-boot: native refusal restores the queued Gestures intent", _GestureClearBootMarker.Bind("gestures", "clear", "refused"))
Test("gesture-clear-boot: backup refusal preserves the queued global intent", _GestureClearBootMarker.Bind("global", "clear", "backup"))
Test("gesture-clear-boot: native refusal restores the queued global intent", _GestureClearBootMarker.Bind("global", "clear", "refused"))
Test("gesture-clear-boot: backup refusal preserves the queued Gestures intent", _GestureClearBootMarker.Bind("gestures", "clear", "backup"))
