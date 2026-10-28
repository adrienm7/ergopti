; tests/unit/modules/hotstrings/personal/test_user_hotstrings_native.ahk

; ==============================================================================
; MODULE: Programmable Hotstrings Native Owners
; DESCRIPTION:
; Programmable hotstrings through their actual native owners: the deferred
; terminal owner, the menu projection, boot persistence, source admission,
; privacy and pause, scoped restore, Notepad invalidation and the native
; event and window boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0





_UCHDeferredPublicationFences() {
	global _THTO_Runner, _THTO_Payloads, _THTO_NativeState
	for Dimension in ["source", "control", "enable", "generation"] {
		_THTO_Reset()
		Receipt := Map("source", "A", "control", "edit1", "enable", true, "generation", 7)
		Owner := _THTO_MakeOwner()
		Owner["PublicationCurrent"] := () => Receipt["source"] == "A" && Receipt["control"] == "edit1"
			&& Receipt["enable"] && Receipt["generation"] == 7
		Assert(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
		Receipt[Dimension] := Dimension == "enable" ? false : (Dimension == "generation" ? 8 : "B")
		AssertEqual(false, _THTO_Runner.Call())
		AssertEqual(0, _THTO_Payloads.Length, "Deferred native sender must retain the original programmable publication owner")
		AssertEqual(1, _THTO_NativeState["AbortCalls"].Length)
		AssertEqual(false, _THTO_NativeState["Capturing"])
	}
	_THTO_Reset()
	Receipt := Map("current", true)
	Owner := _THTO_MakeOwner()
	Owner["PublicationCurrent"] := () => Receipt["current"]
	Owner["DelayFn"] := (Delay, Duration) => (Receipt["current"] := false, true)
	Assert(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	AssertEqual(false, _THTO_Runner.Call())
	AssertEqual(0, _THTO_Payloads.Length, "Recheck at the actual sender after the native key-delay boundary")
	OutputHostResolverConfigure()
}
Test("programmable hotstrings: actual deferred terminal owner fences source control enable and late publication", _UCHDeferredPublicationFences)

_UCHNativeMenuProjection() {
	_HSCS_WithDynamicBootState(Project)
	Project() {
		global _ConfigDir, _UserHotstringsOwner
		SavedDirectory := _ConfigDir, SavedOwner := _UserHotstringsOwner
		Directory := A_Temp . "\ergopti_user_menu_" . A_TickCount . "_" . Random(1, 999999)
		Assert(DllCall("CreateDirectoryW", "Str", Directory, "Ptr", 0))
		_ConfigDir := Directory . "\"
		Fixture := _UCHFixture(), _UserHotstringsOwner := Fixture.owner
		Root := _MR_GetManifestRoot(), Original := Root["programmable_hotstrings"]
		try {
			AssertFalse(FSStrictExists(UserHotstringsSourcePath()), "menu projection must not create personal source")
			Declarations := _MR_GetMenuDef("programmable_hotstrings")
			Rows := _HS_ProgrammableHotstringRows()
			AssertEqual(4, Rows.Length)
			AssertEqual(t("menu.hotstrings.user_code.title") . " (1)", Rows[1]["label"])
			AssertFalse(Rows[1]["checked"], "the canonical shipped request remains disabled")
			AssertEqual(0, Fixture.calls, "native row projection reads static metadata only")
			Root["programmable_hotstrings"] := [Declarations[4], Declarations[2], Declarations[1], Declarations[3]]
			Reordered := _HS_ProgrammableHotstringRows()
			AssertEqual(t("menu.hotstrings.user_code.create_example"), Reordered[1]["label"],
				"shared declaration order drives the actual native projection")
			AssertFalse(Reordered[2]["action"].Call(), "opening absent source must not create or execute it")
			AssertFalse(FSStrictExists(UserHotstringsSourcePath()))
			AssertTrue(Reordered[1]["action"].Call(), "the explicit declared example command creates source")
			Bytes := FSReadUtf8Exact(UserHotstringsSourcePath())
			Assert(Bytes is String && InStr(Bytes, "ErgoptiDynamicHotstrings(api)"))
			AssertEqual(Chr(0xFEFF), SubStr(Bytes, 1, 1), "the explicit AHK example uses UTF-8 with BOM")
			AssertTrue(Reordered[1]["action"].Call(), "a second create keeps the existing file, loading it only when on")
			AssertEqual(Bytes, FSReadUtf8Exact(UserHotstringsSourcePath()), "an existing personal source is byte-preserved")
			AssertEqual(0, Fixture.calls, "creation never loads or calls the example")
		} finally {
			Root["programmable_hotstrings"] := Original
			FSDelete(UserHotstringsSourcePath())
			_ConfigDir := SavedDirectory, _UserHotstringsOwner := SavedOwner
			DirDelete(Directory)
		}
	}
}
Test("programmable hotstrings: actual native menu projects shared order and owns explicit create only", _UCHNativeMenuProjection)

_UCHNativePreferences() {
	_HSCS_WithDynamicBootState(Preferences)
	Preferences() {
		global Features, _ConfigDir, ConfigurationFile, CategoryEnabled
		global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch
		global _UserHotstringsLastRepair, _UserHotstringsProblem
		Saved := [_ConfigDir, ConfigurationFile, _UserHotstringsOwner, _UserHotstringsLoader, CategoryEnabled,
			_UserHotstringsLoadEpoch, _UserHotstringsLastRepair, _UserHotstringsProblem]
		State := MasterGateState(), SavedState := State.Clone()
		Config := '[hotstrings.dynamic.user_code]`nenabled = false`ntime_activation_seconds = 0.75`n'
			. '[private]`ncredential = "retain-user-code-preferences"`n'
		Fixture := _ScopeOwnerFixture(Config), SourcePath := Fixture.directory . "\personal_dynamic_hotstrings.ahk"
		Config := Fixture.source
		Sentinel := Fixture.directory . "\factory-ran.txt"
		try {
			State["initialized"] := false
			Shown := TestMsgBoxCount()
			_ConfigDir := Fixture.directory . "\", ConfigurationFile := Fixture.path
			CategoryEnabled := Map("Hotstrings", true)
			Node := Features["hotstrings"]["dynamic"]["user_code"]
			AssertFalse(Node["enabled"], "canonical boot preference is off")
			Node["time_activation_seconds"] := 0.75
			Assert(FSWriteDurable(Fixture.path, Config))
			Source := 'ErgoptiDynamicHotstrings(api) {`n`tFileAppend("unexpected", "' . Sentinel
				. '", "UTF-8-RAW")`n`treturn []`n}`n'
			Assert(FSWriteCreateDurable(SourcePath, Source))
			_UserHotstringsOwner := 0
			Assert(UserHotstringsInit(), "actual boot initialization accepts the default-off source")
			Sleep(50)
			AssertFalse(FSStrictExists(Sentinel), "default-off boot never executes an existing factory")
			AssertFalse(_UserHotstringsOwner.enabled)
			AssertEqual(Source, FSReadUtf8Exact(SourcePath))
			Assert(FSDelete(SourcePath))
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && Receipt.ok, "the actual live menu adapter persists enable")
			AssertFalse(_UserHotstringsOwner.enabled, "an absent requested source cannot acknowledge native activation")
			AssertFalse(_UserHotstringsOwner.ready)
			Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"), "the actual native owner reports the missing source")
			AssertEqual("missing", UserHotstringsProblem(), "the menu shows the missing source")
			AssertEqual(Shown, TestMsgBoxCount(), "enabling without a source opens no dialog")
			AssertEqual(0, UserHotstringsCount(), "an absent requested source admits no invented mappings")
			Parsed := TOML_ParseFreshFileTyped(Fixture.path)
			AssertTrue(Parsed["hotstrings.dynamic.user_code"]["enabled"].Value)
			AssertEqual(0.75, Parsed["hotstrings.dynamic.user_code"]["time_activation_seconds"])
			AssertEqual("retain-user-code-preferences", Parsed["private"]["credential"])
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && Receipt.ok)
			AssertFalse(_UserHotstringsOwner.enabled)
			AssertEqual("", UserHotstringsProblem(), "a disabled source has no problem to show")
			Before := FSReadUtf8Exact(Fixture.path)
			WasSuspended := A_IsSuspended
			try {
				Suspend(true)
				Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
				Assert(Receipt.handled && !Receipt.ok, "a retained live toggle cannot activate code while paused")
				AssertEqual(Before, FSReadUtf8Exact(Fixture.path))
			} finally Suspend(WasSuspended)
			OwnerFixture := _UCHFixture(), _UserHotstringsOwner := OwnerFixture.owner
			Assert(OwnerFixture.owner.Request("@clock"))
			OwnerFixture.cancelAck := false
			Receipt := _HS_TryLiveToggleV2("hotstrings.dynamic.user_code")
			Assert(Receipt.handled && !Receipt.ok, "unacknowledged cancellation refuses persistence")
			AssertEqual(Before, FSReadUtf8Exact(Fixture.path), "refused native cancellation preserves exact preference bytes")
			AssertFalse(ReadFeatureStateV2("hotstrings.dynamic.user_code")["enabled"])
			OwnerFixture.cancelAck := true
			Assert(UserHotstringsInvalidate("test-retirement"))
		} finally {
			Assert(UserHotstringsInvalidate("fixture-cleanup"))
			_ConfigDir := Saved[1], ConfigurationFile := Saved[2]
			_UserHotstringsOwner := Saved[3], _UserHotstringsLoader := Saved[4], CategoryEnabled := Saved[5]
			_UserHotstringsLoadEpoch := Saved[6], _UserHotstringsLastRepair := Saved[7], _UserHotstringsProblem := Saved[8]
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("programmable hotstrings: actual boot live persistence and cancellation refusal preserve source and preferences", _UCHNativePreferences)

_UCHActualSourceAdmission() {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _UserHotstringsLastRepair, _UserHotstringsProblem, _DriverMenuReady
	AssertEqual(0, _UserHotstringsJobs.Count)
	AssertFalse(IsObject(_UserHotstringsLoader), "source admission fixtures require prior loader retirement")
	Saved := [_ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch,
		_UserHotstringsLastRepair, _UserHotstringsProblem]
	SavedMenuReady := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	PackageRoots := _UCHPackageRoots(), Fixture := _ScopeOwnerFixture(), Hold := 0
	Sentinel := Fixture.directory . "\empty-factory-ran.txt"
	try {
		_ConfigDir := Fixture.directory . "\", _DriverMenuReady := false, _UserHotstringsProblem := ""
		_UserHotstringsOwner := UserHotstringOwner(Map("capture", _UserHotstringsCaptureRule,
			"current", _UserHotstringsCurrent, "invoke", _UserHotstringsInvoke,
			"commit", _UserHotstringsCommit, "report", _UserHotstringsReport))
		Path := UserHotstringsSourcePath()
		AssertFalse(FSStrictExists(Path))
		AssertFalse(UserHotstringsSetEnabled(true), "explicit enable cannot load an absent source")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(0, _UserHotstringsJobs.Count, "absence never launches an interpreter")
		Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"))
		AssertEqual("missing", UserHotstringsProblem())
		BeforeCreateEpoch := _UserHotstringsLoadEpoch
		Assert(UserHotstringsCreateExample(), "source repair is a deliberate create-only action")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(BeforeCreateEpoch, _UserHotstringsLoadEpoch, "creation never loads or admits the example")
		AssertEqual(0, _UserHotstringsJobs.Count)
		ExampleSource := FSReadUtf8Exact(Path)
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled)
		AssertTrue(_UserHotstringsOwner.ready)
		AssertEqual(1, UserHotstringsCount(), "the actual repaired source publishes its declared rule")
		AssertEqual("", UserHotstringsProblem(), "a published source clears the problem")
		Assert(FSDelete(Path))
		AssertFalse(UserHotstringsSetEnabled(true), "repeated enable must reprove the source after disappearance")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(1, _UserHotstringsOwner.Count(), "the old metadata remains quarantined")
		Assert(FSWriteCreateDurable(Path, ExampleSource))
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled)
		AssertTrue(_UserHotstringsOwner.ready)
		Assert(FSDelete(Path))
		AssertFalse(UserHotstringsReload(), "explicit absent reload never claims a successful load")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		Assert(InStr(_UserHotstringsLastRepair, ":source-missing:load"))
		EmptySource := 'ErgoptiDynamicHotstrings(api) {`n`tFileAppend("loaded", "' . Sentinel
			. '", "UTF-8-RAW")`n`treturn []`n}`n'
		Assert(FSWriteCreateDurable(Path, EmptySource))
		Assert(UserHotstringsSetEnabled(true))
		WaitForActualLoader()
		AssertTrue(_UserHotstringsOwner.enabled, "a present valid empty factory can acknowledge its native gate")
		AssertTrue(_UserHotstringsOwner.ready)
		AssertEqual(0, UserHotstringsCount())
		AssertEqual("loaded", FSReadUtf8Exact(Sentinel), "the real interpreter executed the independent empty factory")
		Hold := DllCall("CreateFileW", "Str", Path, "UInt", 0x80000000, "UInt", 0, "Ptr", 0,
			"UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		Assert(Hold && Hold != -1, "the fixture owns an actual exclusive source read lock")
		AssertFalse(UserHotstringsReload(), "an actual unreadable source must refuse reload")
		AssertFalse(UserHotstringsSetEnabled(true), "an actual unreadable source cannot acknowledge enable")
		AssertFalse(_UserHotstringsOwner.enabled)
		AssertFalse(_UserHotstringsOwner.ready)
		AssertEqual(0, _UserHotstringsJobs.Count)
		Assert(InStr(_UserHotstringsLastRepair, ":source-unreadable:load"))
		AssertEqual("failed", UserHotstringsProblem(), "an unreadable source shows as failed")
		Assert(DllCall("CloseHandle", "Ptr", Hold))
		Hold := 0
		AssertEqual(EmptySource, FSReadUtf8Exact(Path), "native refusal never edits executable source")
	} finally {
		if Hold && Hold != -1
			DllCall("CloseHandle", "Ptr", Hold)
		Assert(UserHotstringsInvalidate("source-admission-fixture-cleanup"))
		_ConfigDir := Saved[1], _UserHotstringsOwner := Saved[2], _UserHotstringsLoader := Saved[3]
		_UserHotstringsLoadEpoch := Saved[4], _UserHotstringsLastRepair := Saved[5], _UserHotstringsProblem := Saved[6]
		_DriverMenuReady := IsSet(SavedMenuReady) ? SavedMenuReady : unset
		_UCHRestorePackageRoots(PackageRoots)
		_ScopeOwnerCleanup(Fixture)
	}
	WaitForActualLoader() {
		Started := A_TickCount
		while _UserHotstringsJobs.Count && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(0, _UserHotstringsJobs.Count, "the actual packaged loader and all stages must retire")
		AssertFalse(IsObject(_UserHotstringsLoader))
	}
}
Test("programmable hotstrings: actual absent repaired empty disappeared and unreadable sources acknowledge honest admission", _UCHActualSourceAdmission)

/**
 * A missing programmable source used to open a modal Yes/No offer, first over
 * the boot thread, then once boot was ready, at every start with the option on
 * and no file. Now no dialog opens: one WARNING (never the error window), and
 * the Hotstrings menu row shows the problem with its repair, the example that
 * loads at once.
 */
_UCHMissingSourceIsShownNotAsked() {
	_HSCS_WithDynamicBootState(_UCHMissingSourceBody)
}

_UCHMissingSourceBody() {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs
	global _UserHotstringsLoadEpoch, _UserHotstringsLastRepair, _UserHotstringsProblem
	global _DriverMenuReady, Features, CategoryEnabled
	AssertEqual(0, _UserHotstringsJobs.Count)
	Saved := [_ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch,
		_UserHotstringsLastRepair, _UserHotstringsProblem, CategoryEnabled]
	SavedMenuReady := IsSet(_DriverMenuReady) ? _DriverMenuReady : unset
	Node := Features["hotstrings"]["dynamic"]["user_code"]
	SavedEnabled := Node["enabled"]
	PackageRoots := _UCHPackageRoots(), Fixture := _ScopeOwnerFixture()
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		_ConfigDir := Fixture.directory . "\", _DriverMenuReady := false, _UserHotstringsProblem := ""
		CategoryEnabled := Map("Hotstrings", true)
		Node["enabled"] := true
		_UserHotstringsOwner := 0
		Shown := TestMsgBoxCount()
		AssertFalse(UserHotstringsInit(), "an enabled boot without a source does not claim a load")
		AssertEqual(Shown, TestMsgBoxCount(), "no dialog opens for a missing source")
		AssertEqual("missing", UserHotstringsProblem())
		Errors := 0, Warnings := 0
		for Line in Lines {
			if InStr(Line, "[UserHotstrings]") {
				Errors += InStr(Line, "[ERROR]") ? 1 : 0
				Warnings += InStr(Line, "[WARNING]") ? 1 : 0
			}
		}
		AssertEqual(0, Errors, "a missing personal source is no driver error: the error window stays shut")
		AssertEqual(1, Warnings, "one warning names the missing source")

		Labels := Map()
		for Row in _HS_ProgrammableHotstringRows()
			Labels[Row["label"]] := Row
		Title := t("menu.hotstrings.user_code.title") . " — " . t("menu.hotstrings.user_code.problem_missing")
		Found := false
		for Label in Labels
			Found := Found || InStr(Label, Title) == 1
		AssertTrue(Found, "the feature row shows the missing source")
		Open := Labels[t("menu.hotstrings.user_code.open_source")]
		AssertTrue(Open.Get("disabled", false), "a source that does not exist cannot be opened")
		Create := Labels[t("menu.hotstrings.user_code.create_example")]
		AssertFalse(Create.Get("disabled", false), "the example is offered")

		Create["action"].Call()
		Started := A_TickCount
		while _UserHotstringsJobs.Count && TickElapsed(Started) < 10000
			Sleep(10)
		AssertEqual(0, _UserHotstringsJobs.Count, "the example loader retires")
		AssertTrue(FSStrictExists(UserHotstringsSourcePath()), "the example was created")
		AssertTrue(_UserHotstringsOwner.ready, "the example loads at once")
		AssertEqual("", UserHotstringsProblem(), "and the menu has no problem left to show")
		AssertEqual(Shown, TestMsgBoxCount(), "still no dialog")
		; The boot no longer schedules any offer once it is ready.
		AssertFalse(InStr(_DriverSourceConcat(), "UserHotstringsOfferPendingRepair"),
			"no boot step offers a repair dialog")
	} finally {
		LoggerClearTestSink()
		Assert(UserHotstringsInvalidate("missing-source-fixture-cleanup"))
		Node["enabled"] := SavedEnabled
		_ConfigDir := Saved[1], _UserHotstringsOwner := Saved[2], _UserHotstringsLoader := Saved[3]
		_UserHotstringsLoadEpoch := Saved[4], _UserHotstringsLastRepair := Saved[5], _UserHotstringsProblem := Saved[6]
		CategoryEnabled := Saved[7]
		_DriverMenuReady := IsSet(SavedMenuReady) ? SavedMenuReady : unset
		_UCHRestorePackageRoots(PackageRoots)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("programmable hotstrings: a missing source is shown in the menu, never asked in a dialog (no-repair-modal)", _UCHMissingSourceIsShownNotAsked)

_UCHNativePrivacyAndPause() {
	global _ConfigDir, CategoryEnabled, HSE_Buffer, SFD_FIELD_CACHE
	global _UserHotstringsOwner
	global _UserHotstringsInputSerial, _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	Saved := [_ConfigDir, CategoryEnabled, HSE_Buffer, SFD_FIELD_CACHE.Clone(), A_IsSuspended, WinExist("A"), _UserHotstringsOwner]
	Fixture := _ScopeOwnerFixture(), Window := Gui("+ToolWindow", "Programmable hotstrings native privacy fixture")
	Normal := Window.Add("Edit", "w280", "ordinary input")
	Password := Window.Add("Edit", "w280 Password", "private input")
	try {
		_ConfigDir := Fixture.directory . "\", CategoryEnabled := Map("Hotstrings", true)
		Assert(FSWriteCreateDurable(UserHotstringsSourcePath(), "; Exact native source receipt.`n"))
		Source := _UserHotstringsReadSource()
		HSE_Buffer := "@clock", Suspend(false)
		Window.Show("w310 h120")
		WinActivate("ahk_id " . Window.Hwnd)
		Assert(WinWaitActive("ahk_id " . Window.Hwnd, , 2), "native privacy fixture requires the actual foreground window")
		Normal.Focus()
		SFD_InvalidateFocus()
		AssertFalse(SFD_IsSecureField(), "the actual native Edit style is conclusively ordinary")
		Capture := CaptureCurrent()
		AssertTrue(_UserHotstringsCurrent(Capture, Source), "the exact normal native destination admits publication")
		OriginalOwner := _UCHFixture().owner, _UserHotstringsOwner := OriginalOwner
		AssertTrue(_UserHotstringsPublicationCurrent(OriginalOwner, Capture, Source, OriginalOwner.generation))
		ForeignOwner := _UCHFixture().owner, _UserHotstringsOwner := ForeignOwner
		AssertEqual(OriginalOwner.generation, ForeignOwner.generation, "independent owners may reuse a generation number")
		AssertFalse(_UserHotstringsPublicationCurrent(OriginalOwner, Capture, Source, OriginalOwner.generation),
			"the actual deferred publication fence retains the exact native owner identity")
		_UserHotstringsOwner := OriginalOwner
		Suspend(true)
		AssertFalse(_UserHotstringsCurrent(Capture, Source), "actual suspended input refuses before callback/output")
		Suspend(false)
		Password.Focus()
		SFD_InvalidateFocus()
		AssertTrue(SFD_IsSecureField(), "the actual ES_PASSWORD native control is private")
		PrivateCapture := CaptureCurrent()
		AssertFalse(_UserHotstringsCurrent(PrivateCapture, Source), "privacy refuses even an otherwise current captured control")
		Normal.Focus()
		SFD_InvalidateFocus()
		AssertFalse(SFD_IsSecureField())
		AssertFalse(_UserHotstringsCurrent(PrivateCapture, Source), "changing the real control revokes its old receipt")
		Capture := CaptureCurrent()
		AssertTrue(_UserHotstringsCurrent(Capture, Source))
		Assert(FSWriteDurable(UserHotstringsSourcePath(), "; External source edit.`n"))
		AssertFalse(_UserHotstringsCurrent(Capture, Source), "external source edits revoke an otherwise current native destination")
	} finally {
		Suspend(Saved[5])
		Window.Destroy()
		_ConfigDir := Saved[1], CategoryEnabled := Saved[2], HSE_Buffer := Saved[3], SFD_FIELD_CACHE := Saved[4]
		_UserHotstringsOwner := Saved[7]
		if Saved[6] && WinExist("ahk_id " . Saved[6])
			WinActivate("ahk_id " . Saved[6])
		_ScopeOwnerCleanup(Fixture)
	}
	CaptureCurrent() {
		Hwnd := WinExist("A")
		return Map("input", _UserHotstringsInputSerial, "hwnd", Hwnd,
			"process", _UserHotstringsWindowProcess(Hwnd), "control", WIGetFocusedControlToken(),
			"field", SFD_FocusSnapshot(), "buffer", HSE_Buffer,
			"context", _PrefixInputContextGeneration, "deferred", _PrefixDeferredGeneration,
			"registry", HSE_RegistryGeneration, "decision", HSE_RuntimeDecisionGeneration)
	}
}
Test("programmable hotstrings: real native ordinary password pause control and source receipts fence publication", _UCHNativePrivacyAndPause)

_UCHScopedConfiguration(ScopeId, Mode, CancellationRefused := false) {
	global _ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch, _UserHotstringsJobs
	global _PersonalShortcutsRegistry, KeyboardShortcutAssignments, GestureActionParameters, _SharedDir
	AssertEqual(0, _UserHotstringsJobs.Count, "scope fixtures cannot borrow live programmable worker ownership")
	AssertFalse(IsObject(_UserHotstringsLoader), "scope fixtures require the previous source loader to be retired")
	Saved := [_ConfigDir, _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsLoadEpoch]
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	SavedKeyboard := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	InitialSuffix := '[hotstrings.dynamic.user_code]`nenabled = true`ntime_activation_seconds = 0.75`nunknown_source_choice = "retain"`n'
	Fixture := _HotstringsScopeFixture(1, InitialSuffix), Borrowed := 0, Refusal := 0, Launches := 0
	Native := _UCHFixture()
	SourcePath := Fixture.directory . "\personal_dynamic_hotstrings.ahk"
	Source := Chr(0xFEFF) . 'ErgoptiDynamicHotstrings(api) {`n`tthrow Error("source must remain unexecuted by scope publication")`n}`n'
	Initial := Fixture.source
	Launch(_Success, Bundle, Refused) {
		Borrowed := Bundle, Refusal := Refused, Launches += 1
		; The production shutdown preflight consumes this exact cancellation
		; verdict before handing the complete WAL to the replacement driver.
		if !UserHotstringsInvalidate("scoped-configuration-native-preflight")
			return false
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		_ConfigDir := Fixture.directory . "\", _UserHotstringsOwner := Native.owner, _UserHotstringsLoader := 0
		_PersonalShortcutsRegistry := Map("__Order", []), KeyboardShortcutAssignments := Map(), GestureActionParameters := Map()
		Assert(FSWriteDurable(Fixture.path, Initial))
		Assert(FSWriteCreateDurable(SourcePath, Source))
		if ScopeId == "global" {
			Fixture.options["tap_hold_path"] := Fixture.directory . "\tap_hold.toml"
			Fixture.options["tap_hold_defaults"] := _SharedDir . "\tap_hold\defaults.toml"
			Fixture.options["layers_config_dir"] := Fixture.directory
			Assert(FSWriteDurable(Fixture.options["tap_hold_path"], '[tap_hold]`ninherit_defaults = true`n'))
		}
		Assert(Native.owner.Request("@clock"))
		Native.cancelAck := !CancellationRefused
		Commands := ScopeId == "global" ? _MI_GlobalScopeCommands(Fixture.options) : _HS_ScopeCommands(Fixture.options)
		Receipt := Commands[Mode == "clear" ? "scope_clear" : "scope_restore"].Call()
		AssertEqual(1, Launches, "the real scoped journal reaches one native cancellation/handoff boundary")
		AssertEqual(Source, FSReadUtf8Exact(SourcePath), "scope restore and clear never alter executable personal source")
		AssertEqual(0, Native.calls, "scoped configuration never re-evaluates the source factory or callback")
		if CancellationRefused {
			AssertEqual("refused", Receipt["status"], "unacknowledged native cancellation rolls back the complete scope")
			Assert(Native.owner.debt.Length > 0, "the exact failed cancellation remains owned after scoped rollback")
			AssertEqual(0, Native.owner.Find("@clock"), "retained cancellation debt keeps callback admission closed")
		} else {
			AssertEqual("pending", Receipt["status"])
			Parsed := TOML_ParseFreshFileTyped(Fixture.path)
			Node := Parsed["hotstrings.dynamic.user_code"]
			AssertFalse(Node.Has("enabled"), "both default and recommendation clear the sparse false switch")
			AssertFalse(Node.Has("time_activation_seconds"), "both scopes restore the canonical activation interval sparsely")
			AssertEqual("retain", Node["unknown_source_choice"], "unknown programmable source choices remain user-owned")
			AssertEqual(0, Native.owner.debt.Length)
			Refusal.Call("replacement native driver refused readiness")
			AssertEqual("refused", Receipt["status"])
		}
		AssertEqual(Initial, FSReadUtf8Exact(Fixture.path), "native refusal restores exact original programmable preference bytes")
		AssertEqual(Source, FSReadUtf8Exact(SourcePath))
		Native.cancelAck := true
		Assert(UserHotstringsInvalidate("scope-fixture-retirement"))
	} finally {
		Native.cancelAck := true
		Assert(UserHotstringsInvalidate("fixture-cleanup"))
		if Borrowed is Object
			_ConfigWriteTerminalRelease(Borrowed)
		_ConfigDir := Saved[1], _UserHotstringsOwner := Saved[2], _UserHotstringsLoader := Saved[3]
		_UserHotstringsLoadEpoch := Saved[4]
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboard) ? SavedKeyboard : unset
		GestureActionParameters := IsSet(SavedParameters) ? SavedParameters : unset
		_ScopeOwnerCleanup(Fixture)
	}
}
for _UCHScopeId in ["global", "hotstrings"] {
	for _UCHScopeMode in ["recommended", "clear"]
		Test("programmable hotstrings: real " . _UCHScopeId . " " . _UCHScopeMode . " journal preserves source and rolls back native refusal",
			_UCHScopedConfiguration.Bind(_UCHScopeId, _UCHScopeMode))
}
Test("programmable hotstrings: real scoped restore refuses native cancellation debt without losing its owner",
	_UCHScopedConfiguration.Bind("hotstrings", "recommended", true))

/** Native-literal invalidation revokes admission without claiming sender cleanup. */
_UCHNativeNotepadInvalidation() {
	_HNP_Run(_UCHNativeNotepadInvalidationBody)
}

_UCHNativeNotepadInvalidationBody() {
	global _UserHotstringsOwner, _UserHotstringsLoader, _UserHotstringsJobs, _UserHotstringsLoadEpoch
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending, HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	global _PrefixWatcherSuppressed, _HSE_FireLogQueue, _HNP_Capture
	Saved := {Owner: _UserHotstringsOwner, Loader: _UserHotstringsLoader,
		Jobs: _UserHotstringsJobs, LoadEpoch: _UserHotstringsLoadEpoch,
		Replay: _HSE_TerminalReplayPending}
	try {
		Fixture := _UCHFixture()
		_UserHotstringsOwner := Fixture.owner
		_UserHotstringsLoader := 0
		_UserHotstringsJobs := Map()
		_HSE_TerminalReplayPending := 0
		ExpectedGeneration := Fixture.owner.generation
		HSE_Buffer := "xxab", _PrefixBuffer := "xxab", _LLM_Bridge_Buffer := "xxab"
		OutputHostResolverPrimeForTest("notepad.exe")
		State := Map("Requests", [])
		Spec := _AHK04_NormalSpec()
		Spec.UserCodeGeneration := ExpectedGeneration
		Spec.PublicationCurrent := () => Fixture.owner.generation == ExpectedGeneration
		Owner := HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_Record.Bind(State))
		AssertTrue(Owner is Map && Owner["Pending"], "the actual native sender retains pending publication")
		AssertTrue(Owner.Get("UserCodeOwned", false), "the programmable receipt must reach the native owner")
		AssertEqual(1, _HNP_Capture["Begun"].Length, "the pending native edit holds the keyboard capture")
		AssertTrue(_HSE_NotepadOwnerIsCurrent(Owner), "the original programmable generation admits publication")
		AssertFalse(UserHotstringsInvalidate("native-notepad-fixture"),
			"native completion still owns cleanup after publication revocation")
		AssertTrue(Owner["Pending"] && _HSE_TerminalOwner == Owner,
			"invalidation cannot retire the actual pending native sender")
		AssertEqual(0, _HNP_Capture["Released"].Length, "invalidation cannot release the capture the pending edit holds")
		AssertEqual(0, _HSE_TerminalReplayPending, "invalidation must not fabricate terminal replay debt")
		AssertEqual(1, _PrefixWatcherSuppressed, "native completion retains its sole suppression lease")
		AssertFalse(Owner["OutputOwnershipReleased"], "only actual native completion releases output ownership")
		AssertFalse(_HSE_NotepadOwnerIsCurrent(Owner), "the old publication generation is revoked")
		Request := State["Requests"][1]
		PreviousCritical := Critical("On")
		try {
			Refused := false
			try Request.Opts["atomic_commit"].Call()
			catch as CommitFailure {
				if Type(CommitFailure) != "Error"
						|| CommitFailure.Message != "The Notepad canonical commit lost its publication authority."
					throw CommitFailure
				Refused := true
			}
			AssertTrue(Refused, "the actual commit rejects the revoked publication receipt")
		} finally Critical(PreviousCritical)
		Request.Callback.Call(false, "recorded native refusal")
		AssertTrue(Owner["CompletionClaimed"] && Owner["OutputOwnershipReleased"] && !Owner["Pending"],
			"the real callback settles its retained owner exactly once")
		AssertEqual(0, _PrefixWatcherSuppressed, "actual completion releases suppression")
		AssertEqual(0, Keystats.synth_active, "actual completion releases its synthetic marker")
		AssertEqual("xxab", HSE_Buffer, "refusal preserves the original typed buffer")
		AssertEqual(0, _HSE_FireLogQueue.Length, "revoked output cannot report a fire")
		AssertTrue(UserHotstringsInvalidate("native-notepad-retry"), "settled native completion permits cleanup retry")
		Request.Callback.Call(false, "duplicate recorded refusal")
		AssertEqual(0, _PrefixWatcherSuppressed, "duplicate completion cannot release the same lease twice")
		AssertEqual(1, _HNP_Capture["Released"].Length, "only the native completion releases its capture, once")
		AssertFalse(_HNP_Capture["Released"][1].Committed, "the refused edit releases its capture uncommitted")
	} finally {
		try {
			if (_HSE_TerminalOwner is Map) && _HSE_TerminalOwner.Get("Pending", false)
				_HSE_CompleteNotepadOwner(_HSE_TerminalOwner, false, "fixture cleanup")
		} finally {
			_UserHotstringsOwner := Saved.Owner
			_UserHotstringsLoader := Saved.Loader
			_UserHotstringsJobs := Saved.Jobs
			_UserHotstringsLoadEpoch := Saved.LoadEpoch
			_HSE_TerminalReplayPending := Saved.Replay
		}
	}
}

Test("programmable hotstrings: Notepad invalidation retains native completion ownership (notepad-publication)",
	_UCHNativeNotepadInvalidation)

/** A duplicate native event remains separately owned and reports its collision. */
_UCHNativeEventBoundary() {
	First := 0, Duplicate := 0
	Name := "Local\ErgoptiPlus.NativeBoundaryTest." . UHN_CurrentProcessId() . "." . A_TickCount . "." . Random(0, 0x7fffffff)
	try {
		First := UHN_CreateCancellationEvent(Name, &FirstError)
		AssertTrue(First != 0, "the actual native adapter acquires an event handle")
		AssertTrue(FirstError != 183, "a fresh name does not adopt an existing event")
		AssertEqual(258, PLC_WaitHandle(First, 0), "the manual-reset event starts nonsignaled")
		Duplicate := UHN_CreateCancellationEvent(Name, &DuplicateError)
		AssertTrue(Duplicate != 0, "CreateEvent returns a separately closeable collision handle")
		AssertEqual(183, DuplicateError, "the caller receives the immediate native collision error")
		AssertTrue(UHN_SignalEvent(First), "the actual signal succeeds")
		AssertEqual(0, PLC_WaitHandle(Duplicate, 0), "the collision handle observes the same signaled native event")
	} finally {
		try {
			if Duplicate
				AssertTrue(UHN_CloseEvent(Duplicate), "the owned duplicate is closed once")
		} finally {
			if First
				AssertTrue(UHN_CloseEvent(First), "the owned initial handle is closed once")
		}
	}
}
Test("programmable hotstrings: native adapter preserves event ownership and immediate collision error", _UCHNativeEventBoundary)

/** Read-only probes preserve the active process and reject the null window. */
_UCHNativeWindowBoundary() {
	global DriverPid
	AssertEqual(DriverPid, UHN_CurrentProcessId(), "the nonce source is the actual interpreter process")
	ProcessId := 0
	AssertEqual(0, UHN_WindowProcessId(0, &ProcessId), "a null window acquires no process identity")
	AssertEqual(0, ProcessId)
	Hwnd := UHN_ForegroundHwnd()
	AssertTrue(Hwnd is Integer, "the active-window probe returns a native HWND value")
	if Hwnd {
		AssertTrue(UHN_WindowProcessId(Hwnd, &ProcessId) != 0)
		AssertTrue(ProcessId > 0, "an actual foreground window yields a native process identity")
	}
}
Test("programmable hotstrings: native adapter preserves foreground and process identity", _UCHNativeWindowBoundary)
