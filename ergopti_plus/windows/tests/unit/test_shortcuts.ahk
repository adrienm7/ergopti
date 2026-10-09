; static/ergopti_plus/windows/tests/unit/test_shortcuts.ahk

; ==============================================================================
; MODULE: Test Shortcuts
; DESCRIPTION:
; Unit tests for the keyboard shortcut dispatcher logic in
; modules/shortcuts/ (utils, ctrl, win).
; Verifies the shortcut registration helpers and the pure logic of the Win
; shortcuts. The key combinations (LAlt then CapsLock, AltGr then LAlt...)
; are tested in unit/test_key_combinations.ahk.
;
; FEATURES & RATIONALE:
; 1. No real OS hotkeys triggered: the modules are included after all stubs so
;    AddShortcut -> Hotkey() calls register silently and RunTests() exits
;    before any bound callback could fire.
; 2. Side-effects are captured via the existing _Stub_SentText / _Stub_SentInput
;    recorders defined in test_stubs.ahk.
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
; A key combination calls it to drop the one-shot Shift one of its keys
; armed; the stub counts the calls.
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
#Include ../../modules/shortcuts/ctrl.ahk
#Include ../../modules/shortcuts/win.ahk





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





; =================================================
; =================================================
; ======= 2/ Win-shortcuts Pure-Logic Tests =======
; =================================================
; =================================================

TestShortcuts_SearchPath_FileDetection() {
	; Retain the historical shape check; the additional dispatcher cases below
	; use an explicit launch port and verify real routing without OS effects.
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





; ==================================================
; ==================================================
; ======= 3/ Pause, menu rows and keep-awake =======
; ==================================================
; ==================================================
; Source-scan assertions where the claim is about AHK's native Suspend() and
; hotkey machinery, which the headless harness cannot fire a real hotkey
; through; behavioural checks where the claim can be exercised directly. The
; key-combination dispatch has its own file, unit/test_key_combinations.ahk.

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

; Execute the real dispatcher through its launch port; no browser or OS action.
_SPT_AssertRecordingBoundary() {
	Body := _DriverFuncBody("SearchPath")
	Code := _DriverMaskNonCode(&Body)
	AssertTrue(RegExMatch(Code, "i)^\s*SearchPath\(SelectedText, LaunchFn := Run\)"),
		"the search launch seam must retain its explicit native default")
	AssertFalse(RegExMatch(Code, "i)\bRun\s*\("), "the recording probe must never reach a raw native launch")
	Assignments := 0, Calls := 0
	Position := 1
	while RegExMatch(Code, "i)\bLaunchFn\s*:=", &Found, Position) {
		Assignments += 1
		Position := Found.Pos + Found.Len
	}
	AssertEqual(1, Assignments, "the launch parameter must not be retargeted inside the dispatcher")
	for Line in StrSplit(Code, "`n") {
		if RegExMatch(Line, "i)\bLaunchFn\.Call\(") {
			Calls += 1
			AssertTrue(RegExMatch(Line, "i)^\s*try LaunchFn\.Call\("),
				"each actual launch port must preserve its exception boundary")
		}
	}
	AssertEqual(5, Calls, "every original launch branch must use the recording boundary")
}

_SPT_SearchTarget(Input, Expected) {
	global Features
	Saved := Features
	Launches := []
	Launch := (Target, WorkingDir := "", Options := "") =>
		Launches.Push(Map("target", Target, "options", Options))
	try {
		_SPT_AssertRecordingBoundary()
		Features := Map("shortcuts", Map("search", Map(
			"search_engine", "https://search.invalid/",
			"search_engine_url_query", "https://search.invalid/?q=")))
		SearchPath(Input, Launch)
		AssertEqual(1, Launches.Length, "the actual dispatcher must launch exactly once")
		AssertTrue(Launches[1]["target"] == Expected,
			"the target must preserve URI delimiters or encode the query component exactly")
		AssertEqual("", Launches[1]["options"], "web targets keep ordinary launch options")
	} finally Features := Saved
}
for _SPT_VectorIndex, _SPT_Vector in [
	["https://example.invalid/?a=1&b=2#section", "https://example.invalid/?a=1&b=2#section"],
	["https://example.invalid/a+b?x=%2f&value=%25#part+2", "https://example.invalid/a+b?x=%2f&value=%25#part+2"],
	["https://example.invalid/%23%26%2B?q=100%25", "https://example.invalid/%23%26%2B?q=100%25"],
	["example.invalid/a+b?x=%2f&value=%25#part+2", "https://example.invalid/a+b?x=%2f&value=%25#part+2"],
	["example.invalid/", "https://example.invalid/"],
	["100% ready", "https://search.invalid/?q=100%25%20ready"],
	["literal %2F escape", "https://search.invalid/?q=literal%20%252F%20escape"],
	["café " . Chr(0x1F600), "https://search.invalid/?q=caf%C3%A9%20%F0%9F%98%80"],
	['notes & plus+ hash# quote" equals=?', "https://search.invalid/?q=notes%20%26%20plus%2B%20hash%23%20quote%22%20equals%3D%3F"],
	["first`r`nsecond", "https://search.invalid/?q=first%20second"],
	["first`nsecond", "https://search.invalid/?q=first%0Asecond"],
	["first`rsecond", "https://search.invalid/?q=first%0Dsecond"],
	["", "https://search.invalid/"]
]
	Test("Shortcuts/search: exact URI target " . _SPT_VectorIndex . " (search-uri-component)",
		_SPT_SearchTarget.Bind(_SPT_Vector[1], _SPT_Vector[2]))

; Actual filesystem observations retain the existing path-existence boundary.
_SPT_SearchFileBoundary() {
	global Features
	Saved := Features
	Root := A_Temp . "\ergopti-search-path-" . A_ScriptHwnd . "-" . Random(100000, 999999)
	Owned := false
	try {
		_SPT_AssertRecordingBoundary()
		AssertFalse(FileExist(Root), "the search fixture root must be new")
		if !DllCall("Kernel32\CreateDirectoryW", "Str", Root, "Ptr", 0, "Int")
			throw OSError(A_LastError, "The search fixture root could not be acquired.")
		Owned := true
		Existing := Root . "\existing & #+.txt"
		FileAppend("owned fixture", Existing, "UTF-8")
		Features := Map("shortcuts", Map("search", Map(
			"search_engine", "https://search.invalid/",
			"search_engine_url_query", "https://search.invalid/?q=")))
		Launches := []
		Launch := (Target, WorkingDir := "", Options := "") =>
			Launches.Push(Map("target", Target, "options", Options))
		SearchPath(Existing, Launch)
		AssertEqual(1, Launches.Length)
		AssertTrue(Launches[1]["target"] == Existing, "an existing file path remains byte-identical")
		AssertEqual("Max", Launches[1]["options"])
		Missing := Root . "\missing.txt"
		SearchPath(Missing, Launch)
		AssertEqual(2, Launches.Length)
		AssertTrue(Launches[2]["target"] == "https://search.invalid/?q=" . UriEncode(Missing),
			"a missing path still falls through to an encoded search")
		AssertEqual("", Launches[2]["options"])
	} finally {
		Features := Saved
		if Owned
			DirDelete(Root, true)
	}
}
Test("Shortcuts/search: existing and missing file boundaries (search-uri-component)",
	_SPT_SearchFileBoundary)

; WinKill calls MsgSleep for its native window delay. Recording that boundary
; allows a real timer to revoke the command without closing or launching a window.
_SRCT_CloseBoundary(State, Spec) {
	State["events"].Push("kill")
	if State["throw_close"]
		throw Error("owned close failure")
	if State["action"] != "none" {
		State["timer"] := _SRCT_Revoke.Bind(State)
		SetTimer(State["timer"], -10)
		Sleep(A_WinDelay)
	}
	return State["close_receipt"]
}

_SRCT_Revoke(State, *) {
	State["events"].Push("revoke")
	State["transitions"] += 1
	switch State["action"] {
		case "pause": Suspend(true)
		case "cancel": GetSelectionCancel()
		case "pause-resume":
			Suspend(true)
			; This is the real cancellation authority called by suspend teardown.
			; The full lifecycle is deliberately not invoked by this passive fixture.
			GetSelectionCancel()
			Suspend(false)
		default: throw Error("Unknown registry continuation fixture action.")
	}
}

_SRCT_RecordLaunch(State, Target) {
	State["events"].Push("run")
	State["launches"] += 1
	State["suspended_at_launch"] := A_IsSuspended
	AssertEqual("Regedit.exe", Target)
	if State["throw_launch"]
		throw Error("owned launch failure")
	return true
}

_SRCT_Continuation(Scenario) {
	global _SelectionCaptureJob, _SelectionCaptureNextId
	AssertFalse(IsObject(_SelectionCaptureJob), "fixture refuses a live selection capture")
	AssertEqual(0, CBClipboardOwner.active.Count, "fixture refuses active clipboard ownership")
	AssertFalse(CBClipboardOwner.restore_debt, "fixture refuses an inherited restore debt")
	PreviousId := _SelectionCaptureNextId
	PreviousSuspended := A_IsSuspended
	PreviousWinDelay := A_WinDelay
	PreviousCritical := Critical("Off")
	State := Map("events", [], "timer", 0, "transitions", 0, "launches", 0,
		"suspended_at_launch", false, "action", "none", "exists", true,
		"write_receipt", true, "close_receipt", true, "throw_close", false, "throw_launch", false)
	try {
		AssertFalse(A_IsSuspended, "fixture requires an admitted active command")
		SetWinDelay(100)
		switch Scenario {
			case "pause", "cancel", "pause-resume": State["action"] := Scenario
			case "absent": State["exists"] := false
			case "write-refused": State["write_receipt"] := false
			case "close-refused": State["close_receipt"] := false
			case "close-throws": State["throw_close"] := true
			case "launch-throws": State["throw_launch"] := true
			case "ordinary": State["action"] := "none"
			default: throw Error("Unknown registry continuation fixture case.")
		}
		Write := (Root, Name, Value) => (State["events"].Push("write"), State["write_receipt"])
		Exists := (Spec) => (State["events"].Push("exists"), State["exists"])
		Invoke := () => _RegJumpCommit("HKEY_CURRENT_USER\Software\Ergopti",
			Write, Exists, _SRCT_CloseBoundary.Bind(State), _SRCT_RecordLaunch.Bind(State))
		if InStr(Scenario, "refused") || InStr(Scenario, "throws") {
			AssertThrows(Invoke, "a refused or failed effect must keep the established error contract")
			AssertEqual(Scenario = "write-refused" ? 1 : (Scenario = "launch-throws" ? 4 : 3),
				State["events"].Length, "failure must stop the exact remaining effects")
			AssertEqual(Scenario = "launch-throws" ? 1 : 0, State["launches"])
		} else {
			Expected := State["action"] = "none"
			Result := Invoke.Call()
			if !Expected {
				AssertEqual(1, State["transitions"], "the actual timer must run inside the window-delay boundary")
				AssertEqual(Scenario = "pause", A_IsSuspended,
					"pause-resume must already be active when the old close returns")
				AssertEqual(PreviousId + (Scenario = "pause" ? 0 : 1), _SelectionCaptureNextId,
					"the real capture owner must publish each revocation")
			}
			AssertEqual(Expected, Result, "a cancelled continuation cannot claim a completed navigation")
			AssertEqual(Expected ? 1 : 0, State["launches"],
				"pause or capture revocation during close must suppress the subsequent launch")
			AssertEqual("write", State["events"][1], "persisting the key remains the first effect")
			AssertEqual("exists", State["events"][2])
			if Scenario != "absent"
				AssertEqual("kill", State["events"][3], "the already admitted close remains owned")
			if Expected
				AssertFalse(State["suspended_at_launch"])
		}
	} finally {
		if IsObject(State["timer"])
			SetTimer(State["timer"], 0)
		_SelectionCaptureNextId := PreviousId
		Suspend(PreviousSuspended)
		SetWinDelay(PreviousWinDelay)
		Critical(PreviousCritical)
	}
}
for _SRCT_Scenario in ["pause", "cancel", "pause-resume", "ordinary", "absent",
	"write-refused", "close-refused", "close-throws", "launch-throws"]
	Test("Shortcuts/win: registry continuation " . _SRCT_Scenario . " (regjump-continuation-revocation)",
		_SRCT_Continuation.Bind(_SRCT_Scenario))
