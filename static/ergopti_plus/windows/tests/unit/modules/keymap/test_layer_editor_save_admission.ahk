; tests/unit/modules/keymap/test_layer_editor_save_admission.ahk

; ==============================================================================
; MODULE: Layer Editor Save Admission Tests
; DESCRIPTION:
; Exercises the real host dispatcher and layer save handler with private native
; files. A real logger observer admits one actual timer and native Suspend;
; only the application/reload boundary is passive. No browser or full lifecycle
; suspension is claimed, and neither the writer nor its filesystem is replaced.
; ==============================================================================

class _LESA_Fixture {
	__New(Mode) {
		global LAYER_EDITOR_APP_ID
		this.Mode := Mode, this.LogCalls := 0, this.TimerCalls := 0
		this.DispatchCalls := 0, this.ApplyCalls := 0, this.Done := false, this.Failure := 0
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
		this.MessageFn := ObjBindMethod(this, "OnMessage")
		this.ApplyFn := ObjBindMethod(this, "Apply")
		this.Host := WebViewHost()
		this.Host.AppId := LAYER_EDITOR_APP_ID
		this.Host.Opts := Map("OnMessage", this.MessageFn)
	}
	OnMessage(Host, Payload) {
		this.DispatchCalls += 1
		_LayerEditor_OnMessage(Host, Payload, this.ApplyFn)
	}
	Apply() {
		this.ApplyCalls += 1
		return 1
	}
	OnTimer() {
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical, "the actual timer must run outside a Critical span")
			if this.Mode == "pause-during"
				Suspend(true)
			AssertEqual(this.Mode == "pause-during", A_IsSuspended)
		} catch as Failure {
			this.Failure := Failure
		} finally this.Done := true
	}
	OnLog(Line, *) {
		if !InStr(Line, "[START] [LayerEditor] Saving the navigation layer")
			return
		this.LogCalls += 1
		if this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical)
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the native timer must be observed inside the real save diagnostic")
		} catch as Failure {
			this.Failure := Failure
		}
	}
	Close() {
		Failure := 0
		try SetTimer(this.TimerFn, 0)
		catch as Err {
			Failure := Err
		}
		try this.Host.Close()
		catch as Err {
			if !IsObject(Failure)
				Failure := Err
		} finally {
			this.Host.Opts := Map()
			this.MessageFn := 0, this.ApplyFn := 0, this.SinkFn := 0, this.TimerFn := 0
		}
		if IsObject(Failure)
			throw Failure
	}
}

_LESA_Bytes(Expected, Actual) {
	AssertTrue(Expected is Buffer && Actual is Buffer)
	AssertEqual(Expected.Size, Actual.Size,
		"a save paused before publication cannot replace the existing navigation layer")
	AssertTrue(Expected.Size == 0 || DllCall("ntdll\RtlCompareMemory",
		"Ptr", Expected.Ptr, "Ptr", Actual.Ptr, "UPtr", Expected.Size,
		"UPtr") == Expected.Size, "the existing layer must retain its exact bytes after admission closes")
}

_LESA_Case(Mode) {
	global _SharedDir, _ConfigDir, _LOGGER_TEST_SINK
	global _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckLastError, _HealthCheckErrCount, _HealthCheckWarnCount
	global _ED_Policy, _ED_Busy, _ED_PendingRecord, _TomlReadFailures, _TomlUnreadableFiles
	static Sequence := 0
	AssertFalse(A_IsSuspended)
	AssertEqual(0, _LOGGER_TEST_SINK, "a foreign logger observer cannot be replaced")
	AssertFalse(IsSet(_ED_Busy) && _ED_Busy)
	AssertFalse(IsSet(_ED_PendingRecord) && IsObject(_ED_PendingRecord))
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	Saved := Map()
	for Name in ["_SharedDir", "_ConfigDir", "_LOGGER_REPEAT_ENABLED", "_LOGGER_PATH_DATE",
		"_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_HealthCheckLastError",
		"_HealthCheckErrCount", "_HealthCheckWarnCount", "_ED_Policy", "_TomlReadFailures", "_TomlUnreadableFiles"]
		Saved[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Root := A_Temp . "\ergopti_layer_save_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	F := _LESA_Fixture(Mode), Primary := 0, CleanupError := 0
	PreviousCritical := A_IsCritical
	try {
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := "", _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		_ED_Policy := 0
		_TomlReadFailures := Map(), _TomlUnreadableFiles := Map()
		_SharedDir := _LEH_SharedDir(), _ConfigDir := Root
		_TestEnsureErgoptiLayout()
		Ctx := KeymapLayers_LoadContext(_SharedDir), Text := _LEH_FixtureText()
		AssertEqual(0, LayerEditor_Validate(Text, Ctx).Length, "the real shared edited-layer fixture is admissible")
		Path := KeymapLayers_UserFilePath(Ctx, Root)
		AssertTrue(FSWriteDurable(Path, "; retained before the click`n" . Text))
		Before := FSReadBytesStrict(Path)
		_LOGGER_TEST_SINK := F.SinkFn
		Critical("Off")
		if Mode == "already-paused"
			Suspend(true)
		F.Host._DispatchMessage(F.Host.Epoch, Map("action", "save", "text", Text))
		if IsObject(F.Failure)
			throw F.Failure
		ExpectedCalls := Mode == "already-paused" ? 0 : 1
		AssertEqual(ExpectedCalls, F.DispatchCalls)
		AssertEqual(ExpectedCalls, F.LogCalls)
		AssertEqual(ExpectedCalls, F.TimerCalls)
		if ExpectedCalls
			AssertTrue(F.Done)
		AssertEqual(Mode != "live", A_IsSuspended, "the observed pause must still be active after the handler returns")
		Actual := FSReadBytesStrict(Path)
		if Mode == "live" {
			AssertEqual(Text, FSReadStrict(Path), "the live request really publishes the complete edited layer")
			AssertEqual(StrPut(Text, "UTF-8") - 1, Actual.Size)
			AssertEqual(1, F.ApplyCalls)
			AssertEqual(1, F.Host.Queue.Length)
			AssertTrue(InStr(F.Host.Queue[1], '"saved":true,"applied":true'))
			Loaded := KeymapLayers_LoadUserFile(Ctx, Root, "windows")
			AssertTrue(Loaded["ok"], "the durable result must load through the real Windows layer loader")
		} else {
			; This physical oracle precedes receipt/UI checks, so BEFORE fails on
			; an actual replacement rather than a future helper or return shape.
			_LESA_Bytes(Before, Actual)
			AssertEqual(0, F.ApplyCalls, "a paused request cannot ask for Reload")
			if Mode == "already-paused"
				AssertEqual(0, F.Host.Queue.Length)
			for Js in F.Host.Queue
				AssertFalse(InStr(Js, '"saved":true') || InStr(Js, '"applied":true'))
		}
		Stages := 0
		loop files Root . "\*.tmp", "F"
			Stages += 1
		loop files Root . "\*.stage", "F"
			Stages += 1
		AssertEqual(0, Stages, "the genuine writer leaves no owned staging artifact")
	} catch as Failure {
		Primary := Failure
	} finally {
		try F.Close()
		catch as Failure {
			CleanupError := Failure
		} finally {
			_LOGGER_TEST_SINK := 0
			Suspend(false)
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Entry in Saved
				%Name% := Entry.Present ? Entry.Value : unset
			try DirDelete(Root, true)
			catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			}
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _LESA_Mode in ["pause-during", "already-paused", "live"]
	Test("Layer editor save: " . _LESA_Mode . " respects native admission (layer-editor-save-admission)",
		_LESA_Case.Bind(_LESA_Mode))
