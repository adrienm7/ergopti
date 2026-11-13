; static/ergopti_plus/windows/tests/unit/metrics/ui/test_wpm_config_types.ahk

; ============================================================================
; MODULE: WPM Widget Config Type Boundary Tests
; DESCRIPTION:
; Exercises the production WPM config reader with native TOML scalar values.
; ============================================================================

_TWCT_Areas := [{ Left: 0, Top: 0, Right: 1920, Bottom: 1080 }]

; The Storage port holds no position: the anchor stays at its default.
_TWCT_NoStoredPosition(Key) => "_"

; A Storage port double holding one saved anchor: one [x, y] value.
_TWCT_StoredPosition(X, Y, Key) => Key == WPMWidgetConst.STORE_PAIR ? [X, Y] : "_"

; One coordinate of the pair the real Storage port holds, or "missing".
_TWCT_StoredCoordinate(Index) {
	Pair := ST_Get(WPMWidgetConst.STORE_PAIR, "missing")
	return (Pair is Array && Pair.Length == 2) ? Pair[Index] : "missing"
}

TestWPMConfigRejectsStringEncodedBooleans() {
	SavedVisible := WPMWidget.visible
	SavedColors := WPMWidget.use_colors
	SavedGraph := WPMWidget.show_graph
	try {
		WPMWidget.visible := false
		WPMWidget.use_colors := false
		WPMWidget.show_graph := false
		Thrown := false
		try WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, "1",
			WPMWidgetConst.CFG_COLORS, "1",
			WPMWidgetConst.CFG_GRAPH, "1")), _TWCT_Areas, _TWCT_NoStoredPosition)
		catch
			Thrown := true
		AssertTrue(Thrown,
			"string-encoded booleans must fail before WPM state publication")
		AssertFalse(WPMWidget.visible)
		AssertFalse(WPMWidget.use_colors)
		AssertFalse(WPMWidget.show_graph)

		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, true,
			WPMWidgetConst.CFG_COLORS, true,
			WPMWidgetConst.CFG_GRAPH, true)), _TWCT_Areas, _TWCT_NoStoredPosition)
		AssertTrue(WPMWidget.visible)
		AssertTrue(WPMWidget.use_colors)
		AssertTrue(WPMWidget.show_graph)
	} finally {
		WPMWidget.visible := SavedVisible
		WPMWidget.use_colors := SavedColors
		WPMWidget.show_graph := SavedGraph
	}
}
Test("WPM config: boolean fields preserve TOML types (AHK-101)",
	TestWPMConfigRejectsStringEncodedBooleans)

; An absent key used to read as false whatever the manifest shipped, and
; SaveFullConfig then wrote that false back (decision of 2026-11-03: the graph
; and colours ship on).
TestWPMConfigAbsentKeysTakeManifestDefaults() {
	SavedVisible := WPMWidget.visible
	SavedColors := WPMWidget.use_colors
	SavedGraph := WPMWidget.show_graph
	try {
		WPMWidget.visible := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_VISIBLE)
		WPMWidget.use_colors := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_COLORS)
		WPMWidget.show_graph := !ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_GRAPH)
		WPMWidget_LoadConfig(Map("metrics", Map()), _TWCT_Areas, _TWCT_NoStoredPosition)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_VISIBLE), WPMWidget.visible)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_COLORS), WPMWidget.use_colors)
		AssertEqual(ManifestDefaultFor(ConfigKey.METRICS_WPM_WIDGET_GRAPH), WPMWidget.show_graph)
		AssertTrue(WPMWidget.use_colors && WPMWidget.show_graph && !WPMWidget.visible,
			"an empty configuration shows colours and graph, the pill itself stays hidden")
	} finally {
		WPMWidget.visible := SavedVisible
		WPMWidget.use_colors := SavedColors
		WPMWidget.show_graph := SavedGraph
	}
}
Test("WPM config: absent widget booleans take the manifest default",
	TestWPMConfigAbsentKeysTakeManifestDefaults)

TestWPMConfigValidatesSavedPositionAgainstEveryMonitor() {
	WorkAreas := [
		{ Left: 0, Top: 0, Right: 1920, Bottom: 1080 },
		{ Left: 0, Top: 1080, Right: 1920, Bottom: 2160 }
	]
	AssertTrue(_WPMWidget_RectCenterIsOnScreen(100, 100, 80, 68,
		WorkAreas), "a position on the primary monitor must remain valid")
	AssertTrue(_WPMWidget_RectCenterIsOnScreen(100, 1400, 80, 68,
		WorkAreas), "a position on a lower secondary monitor must remain valid")
	AssertFalse(_WPMWidget_RectCenterIsOnScreen(5000, 100, 80, 68,
		WorkAreas), "a position on a disconnected monitor must be rejected")
	AssertFalse(_WPMWidget_RectCenterIsOnScreen(-5000, -5000, 80, 68,
		WorkAreas), "a wholly off-screen negative position must be rejected")

	SavedX := WPMWidget.pos_x
	SavedY := WPMWidget.pos_y
	SavedStore := WPMWidgetConst.STORE_PAIR
	try {
		WPMWidgetConst.STORE_PAIR := "test.pos"
		WPMWidget.pos_x := -1
		WPMWidget.pos_y := -1
		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false)), WorkAreas,
			_TWCT_StoredPosition.Bind(5000, 100))
		AssertEqual(-1, WPMWidget.pos_x,
			"the loader must discard a disconnected-monitor X coordinate")
		AssertEqual(-1, WPMWidget.pos_y,
			"the loader must discard the off-screen position as one atomic pair")

		WPMWidget_LoadConfig(Map("metrics", Map(
			WPMWidgetConst.CFG_VISIBLE, false,
			WPMWidgetConst.CFG_COLORS, false,
			WPMWidgetConst.CFG_GRAPH, false)), WorkAreas,
			_TWCT_StoredPosition.Bind(100, 1400))
		AssertEqual(100, WPMWidget.pos_x)
		AssertEqual(1400, WPMWidget.pos_y,
			"the loader must preserve a valid lower-monitor coordinate")
	} finally {
		WPMWidget.pos_x := SavedX
		WPMWidget.pos_y := SavedY
		WPMWidgetConst.STORE_PAIR := SavedStore
	}
}
Test("WPM config: saved surfaces remain reachable after monitor changes (AHK-104)",
	TestWPMConfigValidatesSavedPositionAgainstEveryMonitor)

; A single negative-one coordinate is a real screen position, not the sentinel.
TestWPMAutoPositionRequiresBothCoordinates() {
	AssertTrue(_WPMWidget_IsAutoPosition(-1, -1), "the legacy sentinel selects the default")
	AssertFalse(_WPMWidget_IsAutoPosition(-1, 100), "a left-edge position must survive")
	AssertFalse(_WPMWidget_IsAutoPosition(100, -1), "a top-edge position must survive")
	AssertFalse(_WPMWidget_IsAutoPosition(100, 100), "a saved position must survive")
	SavedX := WPMWidget.pos_x, SavedY := WPMWidget.pos_y
	SavedVisible := WPMWidget.visible, SavedColors := WPMWidget.use_colors, SavedGraph := WPMWidget.show_graph
	SavedStore := WPMWidgetConst.STORE_PAIR
	try {
		WPMWidgetConst.STORE_PAIR := "test.pos"
		for Pair in [[-1, 100], [100, -1]] {
			WPMWidget_LoadConfig(Map("metrics", Map(WPMWidgetConst.CFG_GRAPH, false)),
				_TWCT_Areas, _TWCT_StoredPosition.Bind(Pair[1], Pair[2]))
			AssertEqual(Pair[1], WPMWidget.pos_x, "the saved X reaches the surface anchor")
			AssertEqual(Pair[2], WPMWidget.pos_y, "the saved Y reaches the surface anchor")
			AssertFalse(_WPMWidget_IsAutoPosition(WPMWidget.pos_x, WPMWidget.pos_y))
		}
	} finally {
		WPMWidget.pos_x := SavedX, WPMWidget.pos_y := SavedY
		WPMWidget.visible := SavedVisible, WPMWidget.use_colors := SavedColors, WPMWidget.show_graph := SavedGraph
		WPMWidgetConst.STORE_PAIR := SavedStore
	}
}
Test("WPM config: one negative-one coordinate is a position (wpm-anchor-sentinel)",
	TestWPMAutoPositionRequiresBothCoordinates)

_WPMCO_RefusedConfig(Kind, Successor, SamePosition := false) {
	global ConfigurationFile, STORAGE_REG_BASE, _SharedDir
	SavedAuthority := _WPMWidget_PositionAuthority()
	Saved := {path: ConfigurationFile, store: STORAGE_REG_BASE, x: WPMWidget.pos_x,
		y: WPMWidget.pos_y, graph: WPMWidget.show_graph, colors: WPMWidget.use_colors,
		key: WPMWidgetConst.STORE_PAIR}
	Nonce := A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Subkey := "Software\Ergopti_WpmCompensationAudit_" . Nonce
	RegistryPath := "HKCU\" . Subkey
	Root := A_Temp . "\ergopti_wpm_compensation_" . Nonce
	Path := Root . "\config.toml"
	Handle := 0, OwnedKey := false, CreatedRoot := false, FileHold := 0, ProbeOwned := false
	SuccessorX := SamePosition ? (Kind == "graph-toggle" ? -1 : 30) : 700
	SuccessorY := SamePosition ? (Kind == "graph-toggle" ? -1 : 40) : 800
	State := {notices: 0, bCalls: 0, bAck: false, bX: "unset", bY: "unset"}
	Notify(Message, Options) {
		State.notices += 1
		if Successor {
			State.bCalls += 1
			State.bAck := WPMWidget_SavePosition(SuccessorX, SuccessorY, 0, (*) => 0)
			State.bX := _TWCT_StoredCoordinate(1)
			State.bY := _TWCT_StoredCoordinate(2)
		}
	}
	try {
		_WPMWidget_PositionAuthority({active: 0, published: 0})
		AssertFalse(A_IsSuspended)
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647,
			"Str", Subkey, "UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 3,
			"Ptr", 0, "Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		OwnedKey := Status == 0 && Disposition == 1
		AssertTrue(OwnedKey, "acquire a genuinely new private storage key before any value write")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		CreatedRoot := (Creation is Integer) && Creation == 1
		AssertTrue(CreatedRoot)
		Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[metrics]`nwpm_widget_graph = false`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		ConfigurationFile := Path
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"])
		STORAGE_REG_BASE := RegistryPath
		Canon := ParseTomlFile(_SharedDir . "\metrics\data\wpm_widget\constants.toml")
		WPMWidgetConst.STORE_PAIR := Canon["position"]["storage_pair"]
		AssertTrue(WPMWidgetConst.STORE_PAIR != "")
		WPMWidget.show_graph := false, WPMWidget.use_colors := false
		AssertTrue(WPMWidget_SavePosition(10, 20, 0, (*) => 0))
		AssertEqual(10, _TWCT_StoredCoordinate(1))
		AssertEqual(20, _TWCT_StoredCoordinate(2))
		; A genuine unrelated Windows reader allows ordinary source reads but
		; withholds delete sharing, so the actual default replacement refuses.
		FileHold := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
			"UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(FileHold != 0 && FileHold != -1, "acquire the genuine no-delete-share handle")
		ProbeStage := Root . "\native-sharing-probe.tmp"
		ProbeOwned := FSWriteCreateDurable(ProbeStage, Source)
		AssertTrue(ProbeOwned, "acquire the exact probe artifact before the contention witness")
		AssertFalse(FSAtomicMoveReplace(ProbeStage, Path, &LockError))
		AssertTrue(LockError == 5 || LockError == 32,
			"the blocked rename must return a native access/sharing refusal, verified inversely after closing this exact hold")
		AssertTrue(FSStrictExists(ProbeStage), "a refused native rename must retain this exact owned probe for the inverse control")
		AssertEqual(Source, FSReadUtf8Exact(Path), "the native lock probe never replaced its private config source")
		AssertFalse(MenuCommandConfigBusy(), "no pre-existing config owner can prevent the actual menu action from entering")
		if Kind == "graph-toggle"
			Result := WPMWidget_ToggleGraphConfig(0, Notify)
		else
			Result := WPMWidget_SaveConfig(false, true, 30, 40, 0, Notify)
		ActualX := _TWCT_StoredCoordinate(1)
		ActualY := _TWCT_StoredCoordinate(2)
		_TestPrint("# wpm-compensation kind=" . Kind . " successor=" . Successor
			. " notices=" . State.notices . " b_calls=" . State.bCalls . " b_ack=" . State.bAck
			. " b_stored_x=" . State.bX . " b_stored_y=" . State.bY
			. " a_result=" . Result . " ram_x=" . WPMWidget.pos_x . " ram_y=" . WPMWidget.pos_y
			. " final_stored_x=" . ActualX . " final_stored_y=" . ActualY . " native_replace_error=" . LockError)
		AssertFalse(Result, "the actual native sharing violation refuses A's configuration mutation")
		AssertFalse(_ConfigWriteLeaseCurrent(Path) is Object, "the actual refused writer must release its native transaction owner")
		AssertEqual(1, State.notices, "the real failure-notification boundary must run once")
		AssertEqual(Successor ? 1 : 0, State.bCalls)
		if Successor {
			AssertTrue(State.bAck, "the independent public B position change must genuinely acknowledge native storage")
			AssertEqual(SuccessorX, State.bX)
			AssertEqual(SuccessorY, State.bY)
		}
		ExpectedX := Successor ? SuccessorX : 10, ExpectedY := Successor ? SuccessorY : 20
		AssertEqual(ExpectedX, ActualX, "refused A cannot compensate over an acknowledged successor's durable X position")
		AssertEqual(ExpectedY, ActualY)
		AssertEqual(ExpectedX, WPMWidget.pos_x)
		AssertEqual(ExpectedY, WPMWidget.pos_y)
		AssertFalse(WPMWidget.show_graph, "A's refused graph change stays unpublished")
		AssertEqual(Source, FSReadUtf8Exact(Path), "the native sharing refusal leaves the real source unchanged")
	} finally {
		_WPMWidget_PositionAuthority(SavedAuthority)
		try {
			try {
				if FileHold && FileHold != -1 {
					ClosedHold := DllCall("Kernel32\CloseHandle", "Ptr", FileHold, "Int") != 0
					if ClosedHold
						FileHold := 0
					AssertTrue(ClosedHold, "close this fixture's original exact no-delete-share handle")
				}
				if ProbeOwned {
					; Run even when a business oracle above fails. Error5 alone never
					; proves contention: this same stage/target/operation must now ACK.
					AssertTrue(FSStrictExists(ProbeStage), "retain the exact refused probe until all business oracles finish")
					Released := FSAtomicMoveReplace(ProbeStage, Path, &ReleasedError)
					_TestPrint("# wpm-contention-inverse blocked-error=" . LockError
						. " hold-closed=" . (FileHold == 0) . " released-ack=" . Released . " released-error=" . ReleasedError)
					AssertTrue(Released, "the same actual native rename must succeed after this exact hold closes")
					ProbeOwned := false
					AssertFalse(FSStrictExists(ProbeStage), "the inverse ACK must consume the exact retained probe")
					AssertEqual(Source, FSReadUtf8Exact(Path), "the inverse native control uses the original complete source image")
				}
			} finally {
				ConfigurationFile := Saved.path, STORAGE_REG_BASE := Saved.store
				WPMWidget.pos_x := Saved.x, WPMWidget.pos_y := Saved.y
				WPMWidget.show_graph := Saved.graph, WPMWidget.use_colors := Saved.colors
				WPMWidgetConst.STORE_PAIR := Saved.key
				if CreatedRoot {
					try _TOML_InvalidateParseCache(Path)
					finally DirDelete(Root, true)
				}
			}
		} finally {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
			if OwnedKey
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647,
					"Str", Subkey, "UInt"), "delete only this exclusively created storage key")
		}
	}
}
for _WPMCO_Kind in ["save-config", "graph-toggle"] {
	Test("WPM compensation ownership: " . _WPMCO_Kind . " successor", _WPMCO_RefusedConfig.Bind(_WPMCO_Kind, true))
	Test("WPM compensation ownership: " . _WPMCO_Kind . " ordinary-refusal-control", _WPMCO_RefusedConfig.Bind(_WPMCO_Kind, false))
}

for _WPMCO_ABAKind in ["save-config", "graph-toggle"]
	Test("WPM compensation opaque authority: " . _WPMCO_ABAKind . " same-coordinate successor (wpm-compensation-authority)",
		_WPMCO_RefusedConfig.Bind(_WPMCO_ABAKind, true, true))

; Native private Storage values, with a callout-only Store adapter to enter B at
; the acknowledged write boundary that the native API does not expose itself.
; No native/user-owned key or handle is retired. The pair is one value, so every
; mode makes exactly one store call: a refusal leaves the previous pair whole and
; needs no compensation write (WCF-001).
_WPMA_LocalStore(Mode) {
	global STORAGE_REG_BASE, _SharedDir
	Saved := {storagePath: STORAGE_REG_BASE, x: WPMWidget.pos_x, y: WPMWidget.pos_y,
		key: WPMWidgetConst.STORE_PAIR,
		authority: _WPMWidget_PositionAuthority(), critical: A_IsCritical}
	Subkey := "Software\Ergopti_WpmLocalAuthorityAudit_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Handle := 0, Owned := false
	State := {calls: 0, bCalls: 0, bAck: false, critical: []}
	Successor() {
		State.bCalls += 1
		State.bAck := WPMWidget_SavePosition(700, 800, 0, (*) => 0)
		; The public competing write must refuse before any native store effect.
		; Its result is asserted after the complete A transaction metadata below.
	}
	Store(Key, Value) {
		State.calls += 1
		State.critical.Push(A_IsCritical)
		; later-writes-refused acknowledges its first write and refuses every
		; later one: the split X/Y writer stored X, lost Y and its compensation,
		; and left a mixed pair that no caller asked for.
		Refused := Mode == "first-write-refusal-contender" || Mode == "ordinary-refusal-control"
			|| Mode == "failure-notifier-successor" || (Mode == "later-writes-refused" && State.calls > 1)
		Ack := Refused ? false : ST_Set(Key, Value)
		if Mode == "first-write-refusal-contender" || Mode == "first-write-success-contender"
			Successor()
		return Ack
	}
	Notice(*) {
		if Mode == "failure-notifier-successor"
			Successor()
	}
	try {
		Critical("Off")
		Disposition := 0
		Status := DllCall("Advapi32\RegCreateKeyExW", "Ptr", -2147483647, "Str", Subkey,
			"UInt", 0, "Ptr", 0, "UInt", 0, "UInt", 3, "Ptr", 0,
			"Ptr*", &Handle, "UInt*", &Disposition, "UInt")
		Owned := Status == 0 && Disposition == 1
		AssertTrue(Owned, "the test must affirmatively own the newly created private key")
		STORAGE_REG_BASE := "HKCU\" . Subkey
		Canon := ParseTomlFile(_SharedDir . "\metrics\data\wpm_widget\constants.toml")
		WPMWidgetConst.STORE_PAIR := Canon["position"]["storage_pair"]
		_WPMWidget_PositionAuthority({active: 0, published: 0})
		AssertTrue(WPMWidget_SavePosition(10, 20, 0, (*) => 0))
		if Mode == "inherited-critical-control"
			Critical("On")
		Result := WPMWidget_SavePosition(30, 40, Store, Notice)
		AfterCritical := A_IsCritical
		Critical("Off")
		ActualX := _TWCT_StoredCoordinate(1)
		ActualY := _TWCT_StoredCoordinate(2)
		_TestPrint("# wpm-local-authority mode=" . Mode . " a_ack=" . Result . " calls=" . State.calls
			. " b_calls=" . State.bCalls . " b_ack=" . State.bAck . " stored=" . ActualX . "," . ActualY
			. " ram=" . WPMWidget.pos_x . "," . WPMWidget.pos_y . " restored-critical=" . AfterCritical)
		AssertEqual(1, State.calls, "the pair is published by one store write, with no compensation write")
		for CriticalState in State.critical
			AssertFalse(CriticalState, "native Storage must never execute inside the publication Critical span")
		if Mode == "inherited-critical-control" || Mode == "first-write-success-contender"
				|| Mode == "later-writes-refused" {
			AssertTrue(Result)
			if Mode == "inherited-critical-control"
				AssertTrue(AfterCritical, "the caller's original critical posture is restored")
			ExpectedX := 30, ExpectedY := 40
		} else {
			AssertFalse(Result, "a superseded or refused pair must never receive A's publication ACK")
			ExpectedX := Mode == "failure-notifier-successor" ? 700 : 10, ExpectedY := Mode == "failure-notifier-successor" ? 800 : 20
		}
		ContenderExpected := Mode == "first-write-refusal-contender" || Mode == "first-write-success-contender"
			|| Mode == "failure-notifier-successor"
		AssertEqual(ContenderExpected ? 1 : 0, State.bCalls)
		if Mode == "failure-notifier-successor"
			AssertTrue(State.bAck, "a completed local refusal must release authority before notifying its successor")
		else if ContenderExpected
			AssertFalse(State.bAck, "a pair already being written must refuse a reentrant native contender")
		AssertEqual(ExpectedX, ActualX, "the stored pair is the one a caller asked for, never a mixed pair")
		AssertEqual(ExpectedY, ActualY, "the stored pair is the one a caller asked for, never a mixed pair")
		AssertEqual(ExpectedX, WPMWidget.pos_x)
		AssertEqual(ExpectedY, WPMWidget.pos_y)
	} finally {
		Critical("Off")
		_WPMWidget_PositionAuthority(Saved.authority)
		STORAGE_REG_BASE := Saved.storagePath
		WPMWidget.pos_x := Saved.x, WPMWidget.pos_y := Saved.y
		WPMWidgetConst.STORE_PAIR := Saved.key
		try {
			if Handle
				DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
			if Owned
				AssertEqual(0, DllCall("Advapi32\RegDeleteKeyW", "Ptr", -2147483647,
					"Str", Subkey, "UInt"), "delete only the exclusively acquired private storage key")
		} finally Critical(Saved.critical)
	}
}
for _WPMA_Mode in ["first-write-refusal-contender", "first-write-success-contender", "later-writes-refused",
	"ordinary-refusal-control", "inherited-critical-control", "failure-notifier-successor"]
	Test("WPM position opaque authority: " . _WPMA_Mode . " (wpm-compensation-authority, WCF-001)", _WPMA_LocalStore.Bind(_WPMA_Mode))
