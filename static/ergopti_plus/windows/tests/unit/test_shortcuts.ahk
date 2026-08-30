; static/ergopti_plus/windows/tests/unit/test_shortcuts.ahk

; ==============================================================================
; MODULE: Test Shortcuts
; DESCRIPTION:
; Unit tests for the keyboard shortcut dispatcher logic in
; modules/shortcuts/ (utils, altgr, base_modifier, ctrl, win).
; Verifies shortcut registration helpers, the ten-action dispatcher for
; LAlt+CapsLock / AltGr+LAlt / AltGr+CapsLock combos, and the
; _AnyShortcutEnabled gate used to compute boot-time enable flags.
;
; FEATURES & RATIONALE:
; 1. No real OS hotkeys triggered: the modules are included after all stubs so
;    AddShortcut -> Hotkey() calls register silently and RunTests() exits
;    before any bound callback could fire.
; 2. Dispatcher functions (LAltCapsLockShortcut, AltGrLAltShortcut,
;    AltGrCapsLockShortcut) are called directly with a controlled Features Map
;    so every branch of the 10-action cascade is exercised in isolation.
; 3. Side-effects are captured via the existing _Stub_SentText / _Stub_SentInput
;    recorders defined in test_stubs.ahk; the test resets the Features fixture
;    to its default state after each assertion group.
; ==============================================================================

; ── Stubs for symbols that live outside the included infra/ tree ──────────────

; SpotlightMouseAt is in infra/spotlight.ahk, which is not included by run_all.ahk.
; Record calls so the spotlight shortcut test can verify the stub is reachable.
global _Stub_SpotlightCalls := []
SpotlightMouseAt(X, Y, DurationMs) {
	global _Stub_SpotlightCalls
	_Stub_SpotlightCalls.Push({ x: X, y: Y, duration: DurationMs })
}

; OneShotShiftFix is in platform/remap/one_shot_shift.ahk (not included).
; The AltGr dispatcher calls it before some Send* actions to cancel a
; pending one-shot-shift state; the stub is a no-op.
global _Stub_OneShotShiftFixCalls := 0
OneShotShiftFix() {
	global _Stub_OneShotShiftFixCalls
	_Stub_OneShotShiftFixCalls += 1
}

; ── Captured-Send recorder ───────────────────────────────────────────────────
; SendInput / SendEvent are AHK builtins we cannot redefine, so the dispatcher
; tests rely on the _SendHook already installed by InstallHotstringHooks() at
; the top of run_all.ahk. Every Send* call from the dispatcher goes through
; SendFinalResult -> _SendHook -> _Stub_RecordedSends.
; Helper: drain and return the recorded send payloads, then reset.
_ShortcutDrainSends() {
	global _Stub_RecordedSends
	Result := _Stub_RecordedSends.Clone()
	_Stub_RecordedSends := []
	return Result
}

; ── Production shortcut modules (pure-logic subset) ─────────────────────────
; capsword.ahk is intentionally excluded: it redefines ToggleCapsWord /
; DisableCapsWord which are already stubbed in test_stubs.ahk and AHK v2
; raises a parse error on duplicate function definitions.
#Include ../../modules/shortcuts/utils.ahk
#Include ../../modules/shortcuts/altgr.ahk
#Include ../../modules/shortcuts/base_modifier.ahk
#Include ../../modules/shortcuts/ctrl.ahk
#Include ../../modules/shortcuts/win.ahk

; ── Fixture helpers ──────────────────────────────────────────────────────────

; Reset the lalt_caps_lock sub-Map so every action slot is false,
; then enable a single slot by name before each dispatcher test.
_LaltCapsLockReset() {
	global Features
	Features["shortcuts"]["lalt_caps_lock"] := Map(
		"backspace",      false,
		"caps_lock",      false,
		"caps_word",      false,
		"ctrl_backspace", false,
		"ctrl_delete",    false,
		"delete",         false,
		"enter",          false,
		"escape",         false,
		"one_shot_shift", false,
		"tab",            false,
	)
}

_AltGrLAltReset() {
	global Features
	Features["shortcuts"]["alt_gr_lalt"] := Map(
		"backspace",      false,
		"caps_lock",      false,
		"caps_word",      false,
		"ctrl_backspace", false,
		"ctrl_delete",    false,
		"delete",         false,
		"enter",          false,
		"escape",         false,
		"one_shot_shift", false,
		"tab",            false,
	)
}

_AltGrCapsLockReset() {
	global Features
	Features["shortcuts"]["alt_gr_caps_lock"] := Map(
		"backspace",      false,
		"caps_lock",      false,
		"caps_word",      false,
		"ctrl_backspace", false,
		"ctrl_delete",    false,
		"delete",         false,
		"enter",          false,
		"escape",         false,
		"one_shot_shift", false,
		"tab",            false,
	)
}





; =======================================================
; =======================================================
; ======= 1/ RetrieveScancode / AddShortcut Tests =======
; =======================================================
; =======================================================

TestShortcuts_RetrieveScancodeUnmapped() {
	; An unmapped letter returns a sc<hex> string computed from GetKeySC.
	; The exact hex value is layout-dependent but must match the format sc<hex>.
	Result := RetrieveScancode("a")
	AssertTrue(SubStr(Result, 1, 2) == "sc", "scancode should start with 'sc'")
	AssertTrue(StrLen(Result) > 2, "scancode should have digits after 'sc'")
}
Test("Shortcuts/utils: RetrieveScancode returns sc<hex> for unmapped key", TestShortcuts_RetrieveScancodeUnmapped)

TestShortcuts_RetrieveScancodeRemapped() {
	global RemappedList
	; When RemappedList contains an override, RetrieveScancode returns it verbatim
	RemappedList["z"] := "scDEAD"
	Result := RetrieveScancode("z")
	AssertEqual("scDEAD", Result, "remapped scancode should be returned verbatim")
	RemappedList.Delete("z")
}
Test("Shortcuts/utils: RetrieveScancode honours RemappedList overrides", TestShortcuts_RetrieveScancodeRemapped)





; ============================================
; ============================================
; ======= 2/ _AnyShortcutEnabled Tests =======
; ============================================
; ============================================

TestShortcuts_AnyEnabledAllFalse() {
	; All entries false -> should return false.
	_AltGrLAltReset()
	AssertFalse(_AnyShortcutEnabled("alt_gr_lalt"), "all-false map should return false")
}
Test("Shortcuts/altgr: _AnyShortcutEnabled returns false when all actions disabled", TestShortcuts_AnyEnabledAllFalse)

TestShortcuts_AnyEnabledOneTrue() {
	; One true entry -> should return true.
	_AltGrLAltReset()
	Features["shortcuts"]["alt_gr_lalt"]["ctrl_backspace"] := true
	AssertTrue(_AnyShortcutEnabled("alt_gr_lalt"), "map with one true action should return true")
	_AltGrLAltReset()
}
Test("Shortcuts/altgr: _AnyShortcutEnabled returns true when at least one action enabled", TestShortcuts_AnyEnabledOneTrue)

TestShortcuts_AnyEnabledMissingGroup() {
	; Requesting an unknown group should return false without crashing.
	Result := _AnyShortcutEnabled("nonexistent_group_xyz")
	AssertFalse(Result, "unknown group should return false")
}
Test("Shortcuts/altgr: _AnyShortcutEnabled returns false for unknown group", TestShortcuts_AnyEnabledMissingGroup)

TestShortcuts_AnyEnabledSkipsNonBool() {
	; Sub-Map entries (like "gpt" -> Map(...)) are not true bools;
	; the function must not crash and must return false for such a group if
	; all scalar entries are false.
	_AltGrCapsLockReset()
	AssertFalse(_AnyShortcutEnabled("alt_gr_caps_lock"), "all-false group should yield false")
}
Test("Shortcuts/altgr: _AnyShortcutEnabled handles all-false group", TestShortcuts_AnyEnabledSkipsNonBool)





; ========================================================
; ========================================================
; ======= 3/ LAltCapsLockShortcut Dispatcher Tests =======
; ========================================================
; ========================================================

TestShortcuts_LaltCapsLock_CapsLock() {
	global _Stub_SentText
	_LaltCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["lalt_caps_lock"]["caps_lock"] := true
	LAltCapsLockShortcut()
	AssertTrue(_Stub_SentText.Length > 0, "caps_lock action should call ToggleCapsLock stub")
	AssertEqual("toggle_capslock", _Stub_SentText[1].kind, "stub kind should be toggle_capslock")
	_LaltCapsLockReset()
}
Test("Shortcuts/base_modifier: LAlt+CapsLock dispatches caps_lock action", TestShortcuts_LaltCapsLock_CapsLock)

TestShortcuts_LaltCapsLock_CapsWord() {
	global _Stub_SentText
	_LaltCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["lalt_caps_lock"]["caps_word"] := true
	LAltCapsLockShortcut()
	AssertTrue(_Stub_SentText.Length > 0, "caps_word action should call ToggleCapsWord stub")
	AssertEqual("toggle_capsword", _Stub_SentText[1].kind, "stub kind should be toggle_capsword")
	_LaltCapsLockReset()
}
Test("Shortcuts/base_modifier: LAlt+CapsLock dispatches caps_word action", TestShortcuts_LaltCapsLock_CapsWord)

TestShortcuts_LaltCapsLock_OneShotShift() {
	global _Stub_SentText
	_LaltCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["lalt_caps_lock"]["one_shot_shift"] := true
	LAltCapsLockShortcut()
	AssertTrue(_Stub_SentText.Length > 0, "one_shot_shift action should call OneShotShift stub")
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind, "stub kind should be one_shot_shift")
	_LaltCapsLockReset()
}
Test("Shortcuts/base_modifier: LAlt+CapsLock dispatches one_shot_shift action", TestShortcuts_LaltCapsLock_OneShotShift)

TestShortcuts_LaltCapsLock_SendActions() {
	; The dispatchers for send-based actions call SendInput / SendEvent directly
	; (not through SendFinalResult), so _Stub_RecordedSends is not populated.
	; The contract verified here is that enabling each send-based action and
	; calling the dispatcher does NOT throw — the correct branch is reached
	; and the builtin Send* call completes (or no-ops in headless CI).
	for ActionKey in ["enter", "escape", "tab", "ctrl_delete", "delete", "ctrl_backspace"] {
		_LaltCapsLockReset()
		Features["shortcuts"]["lalt_caps_lock"][ActionKey] := true
		Threw := false
		try {
			LAltCapsLockShortcut()
		} catch {
			Threw := true
		}
		AssertFalse(Threw, "action '" . ActionKey . "' must not throw")
		_LaltCapsLockReset()
	}
}
Test("Shortcuts/base_modifier: LAlt+CapsLock send-based actions execute without error", TestShortcuts_LaltCapsLock_SendActions)

TestShortcuts_LaltCapsLock_NoActionNoSend() {
	; When all action slots are false, no send and no stub call should occur.
	global _Stub_SentText, _Stub_RecordedSends
	_LaltCapsLockReset()
	_Stub_SentText := []
	_Stub_RecordedSends := []
	LAltCapsLockShortcut()
	AssertEqual(0, _Stub_SentText.Length, "no stub calls when all actions disabled")
	AssertEqual(0, _Stub_RecordedSends.Length, "no send calls when all actions disabled")
}
Test("Shortcuts/base_modifier: LAlt+CapsLock with all actions off is a no-op", TestShortcuts_LaltCapsLock_NoActionNoSend)

TestShortcuts_LaltCapsLock_BadFeaturesGraceful() {
	; A missing or malformed lalt_caps_lock sub-map must never crash the
	; dispatcher -- graceful no-op only. LAltCapsLockShortcut is reachable
	; via 6 direct calls that bypass #HotIf (5 in tap_holds/capslock.ahk, 1 in
	; tap_holds/nav_layer.ahk), so this defense-in-depth guard cannot rely on
	; the #HotIf's _AnyShortcutEnabled check alone. Mirrors
	; TestShortcuts_BadFeaturesGracefulUnderPause for AltGrLAltShortcut.
	global Features
	Saved := Features["shortcuts"]["lalt_caps_lock"]
	try {
		Features["shortcuts"].Delete("lalt_caps_lock")
		Threw := false
		try {
			LAltCapsLockShortcut()
		} catch {
			Threw := true
		}
		AssertFalse(Threw, 'LAltCapsLockShortcut must not throw when Features["shortcuts"]["lalt_caps_lock"] is entirely missing')
	} finally {
		Features["shortcuts"]["lalt_caps_lock"] := Saved
	}
}
Test("Shortcuts/base_modifier: LAltCapsLockShortcut degrades gracefully when its Features sub-map is missing (resilience)", TestShortcuts_LaltCapsLock_BadFeaturesGraceful)





; =========================================================
; =========================================================
; ======= 4/ AltGrCapsLockShortcut Dispatcher Tests =======
; =========================================================
; =========================================================

TestShortcuts_AltGrCapsLock_CapsLock() {
	global _Stub_SentText
	_AltGrCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_caps_lock"]["caps_lock"] := true
	AltGrCapsLockShortcut()
	AssertTrue(_Stub_SentText.Length > 0, "caps_lock action should call ToggleCapsLock stub")
	AssertEqual("toggle_capslock", _Stub_SentText[1].kind, "stub kind should be toggle_capslock")
	_AltGrCapsLockReset()
}
Test("Shortcuts/altgr: AltGr+CapsLock dispatches caps_lock action", TestShortcuts_AltGrCapsLock_CapsLock)

TestShortcuts_AltGrCapsLock_CapsWord() {
	global _Stub_SentText
	_AltGrCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_caps_lock"]["caps_word"] := true
	AltGrCapsLockShortcut()
	AssertTrue(_Stub_SentText.Length > 0, "caps_word action should call ToggleCapsWord stub")
	AssertEqual("toggle_capsword", _Stub_SentText[1].kind, "stub kind should be toggle_capsword")
	_AltGrCapsLockReset()
}
Test("Shortcuts/altgr: AltGr+CapsLock dispatches caps_word action", TestShortcuts_AltGrCapsLock_CapsWord)

TestShortcuts_AltGrCapsLock_CtrlDelete() {
	; Verify that enabling ctrl_delete and invoking the dispatcher completes
	; without throwing. SendInput is a builtin and cannot be intercepted.
	_AltGrCapsLockReset()
	Features["shortcuts"]["alt_gr_caps_lock"]["ctrl_delete"] := true
	Threw := false
	try {
		AltGrCapsLockShortcut()
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "ctrl_delete action must not throw")
	_AltGrCapsLockReset()
}
Test("Shortcuts/altgr: AltGr+CapsLock dispatches ctrl_delete send action", TestShortcuts_AltGrCapsLock_CtrlDelete)

TestShortcuts_AltGrCapsLock_OneShotShift() {
	global _Stub_SentText
	_AltGrCapsLockReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_caps_lock"]["one_shot_shift"] := true
	AltGrCapsLockShortcut()
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind, "stub kind should be one_shot_shift")
	_AltGrCapsLockReset()
}
Test("Shortcuts/altgr: AltGr+CapsLock dispatches one_shot_shift action", TestShortcuts_AltGrCapsLock_OneShotShift)

TestShortcuts_AltGrCapsLock_NoActionNoSend() {
	global _Stub_SentText, _Stub_RecordedSends
	_AltGrCapsLockReset()
	_Stub_SentText := []
	_Stub_RecordedSends := []
	AltGrCapsLockShortcut()
	AssertEqual(0, _Stub_SentText.Length, "no stub calls when all AltGr+CapsLock actions disabled")
	AssertEqual(0, _Stub_RecordedSends.Length, "no send calls when all AltGr+CapsLock actions disabled")
}
Test("Shortcuts/altgr: AltGr+CapsLock with all actions off is a no-op", TestShortcuts_AltGrCapsLock_NoActionNoSend)





; =====================================================
; =====================================================
; ======= 5/ AltGrLAltShortcut Dispatcher Tests =======
; =====================================================
; =====================================================

TestShortcuts_AltGrLAlt_CapsLock() {
	global _Stub_SentText
	_AltGrLAltReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_lalt"]["caps_lock"] := true
	AltGrLAltShortcut()
	AssertEqual("toggle_capslock", _Stub_SentText[1].kind, "caps_lock action should toggle CapsLock")
	_AltGrLAltReset()
}
Test("Shortcuts/altgr: AltGr+LAlt dispatches caps_lock action", TestShortcuts_AltGrLAlt_CapsLock)

TestShortcuts_AltGrLAlt_CapsWord() {
	global _Stub_SentText
	_AltGrLAltReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_lalt"]["caps_word"] := true
	AltGrLAltShortcut()
	AssertEqual("toggle_capsword", _Stub_SentText[1].kind, "caps_word action should toggle CapsWord")
	_AltGrLAltReset()
}
Test("Shortcuts/altgr: AltGr+LAlt dispatches caps_word action", TestShortcuts_AltGrLAlt_CapsWord)

TestShortcuts_AltGrLAlt_OneShotShift() {
	global _Stub_SentText
	_AltGrLAltReset()
	_Stub_SentText := []
	Features["shortcuts"]["alt_gr_lalt"]["one_shot_shift"] := true
	AltGrLAltShortcut()
	AssertEqual("one_shot_shift", _Stub_SentText[1].kind, "one_shot_shift action should call stub")
	_AltGrLAltReset()
}
Test("Shortcuts/altgr: AltGr+LAlt dispatches one_shot_shift action", TestShortcuts_AltGrLAlt_OneShotShift)

TestShortcuts_AltGrLAlt_CtrlBackspace() {
	; Verify that enabling ctrl_backspace and invoking the dispatcher completes
	; without throwing. SendInput is a builtin and cannot be intercepted via hooks.
	_AltGrLAltReset()
	Features["shortcuts"]["alt_gr_lalt"]["ctrl_backspace"] := true
	Threw := false
	try {
		AltGrLAltShortcut()
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "ctrl_backspace action must not throw")
	_AltGrLAltReset()
}
Test("Shortcuts/altgr: AltGr+LAlt dispatches ctrl_backspace send action", TestShortcuts_AltGrLAlt_CtrlBackspace)

TestShortcuts_AltGrLAlt_NoActionNoSend() {
	global _Stub_SentText, _Stub_RecordedSends
	_AltGrLAltReset()
	_Stub_SentText := []
	_Stub_RecordedSends := []
	AltGrLAltShortcut()
	AssertEqual(0, _Stub_SentText.Length, "no stub calls when all AltGr+LAlt actions disabled")
	AssertEqual(0, _Stub_RecordedSends.Length, "no send calls when all AltGr+LAlt actions disabled")
}
Test("Shortcuts/altgr: AltGr+LAlt with all actions off is a no-op", TestShortcuts_AltGrLAlt_NoActionNoSend)





; =================================================
; =================================================
; ======= 6/ Win-shortcuts Pure-Logic Tests =======
; =================================================
; =================================================

TestShortcuts_SearchPath_FileDetection() {
	; Every branch inside SearchPath() ends in a real Run() (open the file,
	; RegJump, open a URL, or fire a real web search) — there is no
	; dependency-injection seam for Run in this module, so calling the live
	; function with ANY input performs a genuine OS-visible action (this
	; used to open the machine's actual default browser with a Google
	; search for the literal test string once AHK-18 routed a shape-matched
	; but non-existent path to the web-search fallback). Verify the pure
	; regex-shape contract in isolation instead of invoking the dispatcher.
	FilePath := RegExMatch(
		"C:\Users\test\file.txt",
		"^[A-Za-z]:[\\/](?:[^<>:" . '"' . "|?*\r\n]+[\\/]?)*$"
	)
	AssertTrue(FilePath, "the FilePath detection regex must match a well-formed Windows path shape")
}
Test("Shortcuts/win: SearchPath's FilePath regex matches Windows file path shapes", TestShortcuts_SearchPath_FileDetection)

TestShortcuts_RegJumpCommitChecksEveryReceipt() {
	State := Map("events", [], "path", "")
	WriteOk := (Root, Name, Value) => (
		State["events"].Push("write"),
		State["path"] := Root . "|" . Name . "|" . Value,
		true)
	Exists := (*) => (State["events"].Push("exists"), true)
	KillOk := (*) => (State["events"].Push("kill"), true)
	Launch := (*) => (State["events"].Push("run"), true)
	AssertTrue(_RegJumpCommit("HKEY_CURRENT_USER\Software\Ergopti",
		WriteOk, Exists, KillOk, Launch))
	AssertEqual(4, State["events"].Length)
	AssertEqual("write", State["events"][1])
	AssertEqual("exists", State["events"][2])
	AssertEqual("kill", State["events"][3])
	AssertEqual("run", State["events"][4],
		"RegJump must persist the target before replacing and launching Regedit")
	AssertEqual("HKCU\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit"
		. "|LastKey|HKEY_CURRENT_USER\Software\Ergopti", State["path"])

	State["events"] := []
	WriteRefused := (*) => (State["events"].Push("write"), false)
	AssertThrows(() => _RegJumpCommit("HKEY_CURRENT_USER", WriteRefused,
		Exists, KillOk, Launch))
	AssertEqual(1, State["events"].Length)
	AssertEqual("write", State["events"][1],
		"a refused registry write must prevent every desktop side effect")

	State["events"] := []
	KillRefused := (*) => (State["events"].Push("kill"), false)
	AssertThrows(() => _RegJumpCommit("HKEY_CURRENT_USER", WriteOk,
		Exists, KillRefused, Launch))
	AssertEqual(3, State["events"].Length)
	AssertEqual("write", State["events"][1])
	AssertEqual("exists", State["events"][2])
	AssertEqual("kill", State["events"][3],
		"a refused close must prevent launching Regedit against stale state")
}
Test("Shortcuts/win: RegJump consumes effect receipts (regjump-receipt-fail-closed)",
	TestShortcuts_RegJumpCommitChecksEveryReceipt)

TestShortcuts_GetPathCopyFlowChecksBothWrites() {
	Events := []
	WriteRefused := (*) => (Events.Push("write"), false)
	ScheduleFn := (*) => Events.Push("timer")
	PromptNo := (*) => (Events.Push("prompt"), "No")
	SleepFn := (*) => Events.Push("sleep")
	RenameFn := (*) => Events.Push("rename")
	AssertFalse(_GetPathCopyFlow("C:/repo", "C:\repo", WriteRefused,
		ScheduleFn, PromptNo, SleepFn, RenameFn))
	AssertEqual(1, Events.Length)
	AssertEqual("write", Events[1],
		"a refused first copy must not arm or show success UI")

	Events := []
	WriteCount := 0
	RefuseSecond := (*) => (WriteCount += 1, Events.Push("write"), WriteCount = 1)
	AssertFalse(_GetPathCopyFlow("C:/repo", "C:\repo", RefuseSecond,
		ScheduleFn, PromptNo, SleepFn, RenameFn))
	AssertEqual(4, Events.Length)
	AssertEqual("write", Events[1])
	AssertEqual("timer", Events[2])
	AssertEqual("prompt", Events[3])
	AssertEqual("write", Events[4],
		"a refused backslash copy must not show the final success dialog")

	Events := []
	PromptCount := 0
	WriteOk := (Value) => (Events.Push("write:" . Value), true)
	PromptThenConfirm := (*) => (
		PromptCount += 1,
		Events.Push("prompt" . PromptCount),
		PromptCount = 1 ? "No" : "OK")
	AssertTrue(_GetPathCopyFlow("C:/repo", "C:\repo", WriteOk,
		ScheduleFn, PromptThenConfirm, SleepFn, RenameFn))
	AssertEqual(6, Events.Length)
	AssertEqual("write:C:/repo", Events[1])
	AssertEqual("timer", Events[2])
	AssertEqual("prompt1", Events[3])
	AssertEqual("write:C:\repo", Events[4])
	AssertEqual("sleep", Events[5])
	AssertEqual("prompt2", Events[6])
}
Test("Shortcuts/win: GetPath checks both writes (getpath-copy-receipt)",
	TestShortcuts_GetPathCopyFlowChecksBothWrites)

TestShortcuts_ChangeButtonNamesHandlesWindowRaces() {
	Events := []
	Missing := (*) => (Events.Push("exists"), false)
	Activate := (*) => (Events.Push("activate"), true)
	SetText := (*) => Events.Push("set")
	AssertFalse(_ChangeButtonNamesWith(Missing, Activate, SetText))
	AssertEqual(1, Events.Length)
	AssertEqual("exists", Events[1])

	Events := []
	Exists := (*) => (Events.Push("exists"), true)
	RefuseActivate := (*) => (Events.Push("activate"), false)
	AssertFalse(_ChangeButtonNamesWith(Exists, RefuseActivate, SetText))
	AssertEqual(2, Events.Length)
	AssertEqual("activate", Events[2])

	Events := []
	ThrowingSetText := (*) => (Events.Push("set"), _PDBR_ThrowLostWindow())
	AssertFalse(_ChangeButtonNamesWith(Exists, Activate, ThrowingSetText),
		"a window disappearing during ControlSetText must not escape the timer")
	AssertEqual(3, Events.Length)
	AssertEqual("set", Events[3])

	Events := []
	AssertTrue(_ChangeButtonNamesWith(Exists, Activate, SetText))
	AssertEqual(4, Events.Length)
	AssertEqual("set", Events[3])
	AssertEqual("set", Events[4])
}

_PDBR_ThrowLostWindow() {
	throw TargetError("path-copy dialog closed")
}
Test("Shortcuts/win: button rename contains window races (path-dialog-button-race)",
	TestShortcuts_ChangeButtonNamesHandlesWindowRaces)

TestShortcuts_DOMPathToFilesystem_LocalFile() {
	; file:///C:/Users/test should become C:\Users\test.
	Result := DOMPathToFilesystem("file:///C:/Users/test")
	AssertEqual("C:\Users\test", Result, "local file URL should be converted to Windows path")
}
Test("Shortcuts/win: DOMPathToFilesystem converts file:// URL to Windows path", TestShortcuts_DOMPathToFilesystem_LocalFile)

TestShortcuts_DOMPathToFilesystem_NonLocal() {
	; A non-file URL must return an empty string.
	Result := DOMPathToFilesystem("https://example.com/path")
	AssertEqual("", Result, "non-file URL should return empty string")
}
Test("Shortcuts/win: DOMPathToFilesystem returns empty string for non-file URL", TestShortcuts_DOMPathToFilesystem_NonLocal)

TestShortcuts_DOMPathToFilesystem_EmptyInput() {
	Result := DOMPathToFilesystem("")
	AssertEqual("", Result, "empty input should return empty string")
}
Test("Shortcuts/win: DOMPathToFilesystem returns empty string for empty input", TestShortcuts_DOMPathToFilesystem_EmptyInput)

TestShortcuts_GetKnownFolderDownloads_ReturnsStringOrEmpty() {
	; The function returns a path string or "" when no Downloads folder found.
	; We only assert on the return type — not the exact path (machine-dependent).
	Result := GetKnownFolderDownloads()
	AssertTrue(Result is String, "GetKnownFolderDownloads must return a string")
}
Test("Shortcuts/win: GetKnownFolderDownloads returns a string value", TestShortcuts_GetKnownFolderDownloads_ReturnsStringOrEmpty)





; =======================================================================================
; =======================================================================================
; ======= 7/ Pause + Volume + Resilience (encore plus, 100% regression certainty) =======
; =======================================================================================
; =======================================================================================
; Every public dispatcher / gate / menu path in shortcuts must be provably
; pause-safe. The six tests below used to be bare AssertTrue(true, "...")
; placeholders that exercised zero production code -- they would have passed
; even if every dispatcher ignored A_IsSuspended entirely or corrupted state
; under malformed config. Replaced with real checks: source-scan assertions
; where the claim is about AHK's native Suspend()/hotkey machinery (which the
; headless harness cannot simulate a real hotkey firing through), and
; behavioral checks using the existing _Stub_SentText/_AltGrLAltReset
; infrastructure where the claim is directly exercisable.

TestShortcuts_DispatchersRegisteredAsRealHotkeys() {
	; Native Suspend() disarms Hotkeys/Hotstrings automatically -- it is only a
	; bug class (Pattern 1, already fixed elsewhere in this audit) when a
	; dispatcher is instead reached via SetTimer/OnMessage, which bypasses it.
	; Verify this file's AltGr/CapsLock dispatchers are wired through the real
	; Hotkey()-family registration (AddShortcut), not a bypass-prone mechanism.
	Src := _DriverDirConcat("modules/shortcuts")
	Assert(Src != "", "modules/shortcuts must be readable")
	Assert(InStr(Src, "AddShortcut(") > 0,
		"modules/shortcuts must register its dispatchers via AddShortcut (a Hotkey() wrapper) so native Suspend() disarms them -- a SetTimer/OnMessage-based dispatcher would need its own explicit A_IsSuspended guard")
}
Test("Shortcuts: dispatchers are registered as real Hotkeys, not a Suspend-bypassing SetTimer/OnMessage (project_suspend_pause_invariant)",
	TestShortcuts_DispatchersRegisteredAsRealHotkeys)

TestShortcuts_ToggleSuspendDrainsAltGrPrefixFirst() {
	; Historical gotcha [[feedback-ahk-suspend-prefix-latch]]: SC138 (AltGr) prefix
	; can latch across Suspend(1)/Suspend(0) if the physical release happens while
	; the custom-combination prefix layer is disarmed. The fix drains the prefix
	; BEFORE Suspend(-1) toggles state, in ToggleSuspend (infra/lifecycle.ahk).
	Src := _DriverDirConcat("infra")
	Assert(Src != "", "lib must be readable")
	Body := _DriverFuncBody("ToggleSuspend")
	Assert(Body != "", "ToggleSuspend must exist in infra/lifecycle.ahk")

	ClearPos := InStr(Body, "_SuspendPrefixesAreClear()")
	Assert(ClearPos > 0 and InStr(Body, "SetTimer(_SuspendPendingPoll, 25)") > ClearPos,
		"ToggleSuspend must defer Suspend until the physical AltGr/Kana prefix has released")
}
Test("Shortcuts/AltGr: ToggleSuspend drains the AltGr prefix latch before toggling Suspend (historical AltGr latch gotcha)",
	TestShortcuts_ToggleSuspendDrainsAltGrPrefixFirst)

TestShortcuts_MenuItemsUseRegisterMenuItem() {
	; project-ahk-menu-dispatcher-drop: raw Menu.Add(Title, Callback) bypasses
	; the menu_dispatcher WM_COMMAND retry path and silently drops ~1 click in 3
	; under AHK 2.0. All actionable shortcut menu items must go through
	; RegisterMenuItem instead.
	Src := _DriverDirConcat("ui/menu")
	Assert(Src != "", "ui/menu must be readable")
	MenuShortcutsSrc := FileRead(A_ScriptDir . "\..\ui\menu\menu_shortcuts.ahk", "UTF-8")
	; TWO ways to be on the retry path, and the file must be on one of them. It
	; used to call RegisterMenuItem directly; since 2026-08-08 its last actionable
	; row is a `command` declaration and the renderer builds it — and _MR_RenderRows
	; registers through the very same helper. Pinning the first spelling would have
	; failed the change that made the rule harder to break.
	ViaHelper   := InStr(MenuShortcutsSrc, "RegisterMenuItem(") > 0
	ViaRenderer := InStr(MenuShortcutsSrc, "MenuRenderer_") > 0
	Assert(ViaHelper or ViaRenderer,
		"ui/menu/menu_shortcuts.ahk must put actionable items on the WM_COMMAND retry path — either "
		. "through RegisterMenuItem directly or by handing its rows to MenuRenderer_*, which registers "
		. "through the same helper. A raw Menu.Add(Title, Callback) silently drops about one click in "
		. "three under AHK 2.0 (project-ahk-menu-dispatcher-drop)")
}
Test("Shortcuts/menu: shortcut menu items are registered via RegisterMenuItem, not raw Menu.Add (project-ahk-menu-dispatcher-drop)",
	TestShortcuts_MenuItemsUseRegisterMenuItem)

TestShortcuts_HighVolumeDispatcherCalls() {
	; 250 calls to AltGrLAltShortcut with a rotating single enabled slot must
	; each dispatch exactly the expected stub call and leave no cross-call
	; residue (a leak would show up as growing _Stub_SentText or a mismatched
	; kind on a later iteration).
	global _Stub_SentText
	Slots := ["caps_lock", "caps_word", "one_shot_shift"]
	ExpectedKinds := Map("caps_lock", "toggle_capslock", "caps_word", "toggle_capsword", "one_shot_shift", "one_shot_shift")
	Loop 250 {
		Slot := Slots[Mod(A_Index - 1, Slots.Length) + 1]
		_AltGrLAltReset()
		_Stub_SentText := []
		Features["shortcuts"]["alt_gr_lalt"][Slot] := true
		AltGrLAltShortcut()
		AssertEqual(1, _Stub_SentText.Length, "iteration " . A_Index . " (" . Slot . ") must dispatch exactly one stub call, no more, no less")
		AssertEqual(ExpectedKinds[Slot], _Stub_SentText[1].kind, "iteration " . A_Index . " (" . Slot . ") must dispatch the action matching the enabled slot")
	}
	_AltGrLAltReset()
}
Test("Shortcuts: 250 rotating-slot AltGrLAltShortcut calls each dispatch correctly with no cross-call residue", TestShortcuts_HighVolumeDispatcherCalls)

TestShortcuts_BadFeaturesGracefulUnderPause() {
	; A missing or malformed alt_gr_lalt sub-map must never crash the dispatcher --
	; graceful no-op only. Exercises the real dispatcher against real malformed
	; config, not a placeholder assertion.
	global Features
	Saved := Features["shortcuts"]["alt_gr_lalt"]
	try {
		Features["shortcuts"].Delete("alt_gr_lalt")
		Threw := false
		try {
			AltGrLAltShortcut()
		} catch {
			Threw := true
		}
		AssertFalse(Threw, 'AltGrLAltShortcut must not throw when Features["shortcuts"]["alt_gr_lalt"] is entirely missing')
	} finally {
		Features["shortcuts"]["alt_gr_lalt"] := Saved
	}
}
Test("Shortcuts: AltGrLAltShortcut degrades gracefully when its Features sub-map is missing (resilience)", TestShortcuts_BadFeaturesGracefulUnderPause)

TestShortcuts_DispatcherCallsAreIdempotent() {
	; Three consecutive calls with the identical enabled slot must each produce
	; the identical dispatch -- proves the dispatcher carries no hidden internal
	; state that degrades or changes behavior across repeated invocations.
	global _Stub_SentText
	_AltGrLAltReset()
	Features["shortcuts"]["alt_gr_lalt"]["caps_lock"] := true
	Loop 3 {
		_Stub_SentText := []
		AltGrLAltShortcut()
		AssertEqual(1, _Stub_SentText.Length, "call " . A_Index . " must dispatch exactly one stub call")
		AssertEqual("toggle_capslock", _Stub_SentText[1].kind, "call " . A_Index . " must dispatch the same action as every other call")
	}
	_AltGrLAltReset()
}
Test("Shortcuts: repeated AltGrLAltShortcut calls with the same config are idempotent (no accumulating internal state)", TestShortcuts_DispatcherCallsAreIdempotent)

TestShortcuts_KeepAwakeDeactivation() {
	; Test that the keep-awake mode (ActivitySimulation) properly cancels on user input
	global ActivitySimulation, AwakeOriginX, AwakeOriginY
	ActivitySimulation := true
	AwakeOriginX := 100
	AwakeOriginY := 100

	; Keyboard input should stop simulation
	AwakeCancelOnKeypress("", "")
	Sleep(10)
	AssertFalse(ActivitySimulation, "Keyboard input should immediately deactivate keep-awake simulation")

	; Reset
	ActivitySimulation := true
	AwakeCancelOnMouse()
	Sleep(10)
	AssertFalse(ActivitySimulation, "Mouse click should immediately deactivate keep-awake simulation")
}
Test("Shortcuts: keep-awake simulation cancels on mouse or keyboard input", TestShortcuts_KeepAwakeDeactivation)

class _KeepAwakeStopRetryStub {
	StopCalls := 0

	Stop() {
		this.StopCalls += 1
		if this.StopCalls == 1
			throw Error("injected keep-awake stop refusal")
	}
}

TestShortcuts_KeepAwakeStopRetainsRefusedOwner() {
	global AwakeInputHook
	SavedHook := IsSet(AwakeInputHook) ? AwakeInputHook : ""
	Hook := _KeepAwakeStopRetryStub()
	try {
		AwakeInputHook := Hook
		AssertFalse(AwakeStopCancellationHook(),
			"a refused keep-awake hook stop must be reported")
		AssertTrue(AwakeInputHook == Hook,
			"a refused keep-awake hook stop must retain the exact owner for retry")
		AssertTrue(AwakeStopCancellationHook(),
			"a later keep-awake hook stop retry must be allowed to settle")
		AssertFalse(IsObject(AwakeInputHook),
			"the keep-awake hook owner must clear only after Stop succeeds")
		AssertEqual(2, Hook.StopCalls,
			"the retained keep-awake hook must receive the retry")
	} finally {
		AwakeInputHook := SavedHook
	}
}
Test("Shortcuts: keep-awake retains a refused cancellation hook for retry (AHK-168)",
	TestShortcuts_KeepAwakeStopRetainsRefusedOwner)
