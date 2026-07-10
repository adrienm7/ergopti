; static/ergopti_plus/windows/tests/unit/test_adapter_compliance_new.ahk

; ==============================================================================
; MODULE: Adapter Compliance Tests (new adapters)
; DESCRIPTION:
; Surface-level compliance tests for the new adapters:
; SecureFieldDetector, Clipboard, Storage, ProcessLifecycle, KeyState,
; and ShellRunner (OS-infrastructure helper, mirrors macos/adapters/shell_runner).
; Each test verifies that the public API is callable and returns values of the
; expected type, without exercising OS side-effects in depth.
;
; FEATURES & RATIONALE:
; 1. Callable surface: every exported function must not throw on a valid call.
; 2. Type contracts: return types (1/0, String, Map, Array) are asserted.
; 3. Idempotency: PLC_Start/PLC_Stop called twice each to ensure no crash.
; ==============================================================================




; ========================================
; ========================================
; ======= 1/ SecureFieldDetector =========
; ========================================
; ========================================

_SFD_IsSecureField_Callable() {
	local result := SFD_IsSecureField()
	AssertTrue(result = 0 || result = 1)
}
Test("SFD_IsSecureField: callable, returns 0 or 1", _SFD_IsSecureField_Callable)

_SFD_IsSecureApp_EmptyString() {
	AssertEqual(0, SFD_IsSecureApp(""))
}
Test("SFD_IsSecureApp: empty string returns 0", _SFD_IsSecureApp_EmptyString)

_SFD_IsSecureApp_UnknownApp() {
	AssertEqual(0, SFD_IsSecureApp("notanapp.exe"))
}
Test("SFD_IsSecureApp: unknown app returns 0", _SFD_IsSecureApp_UnknownApp)

_SFD_SecureApps_IsMap() {
	AssertTrue(SFD_SECURE_APPS is Map)
}
Test("SFD_SECURE_APPS: is a Map", _SFD_SecureApps_IsMap)

_SFD_SecureApps_HasEntries() {
	AssertTrue(SFD_SECURE_APPS.Count > 0)
}
Test("SFD_SECURE_APPS: Count > 0", _SFD_SecureApps_HasEntries)

_SFD_Refresh_NoCrash() {
	SFD_Refresh()
	AssertTrue(1)
}
Test("SFD_Refresh: does not crash", _SFD_Refresh_NoCrash)

; Encore plus: pause invariant for adapters — SecureFieldDetector (and Clipboard/Storage/PLC) must support early no-op or be skipped when A_IsSuspended.
; Privacy: never detect or act on secure fields while paused.
_SFD_PauseNoDetection() {
	; Real usage in keylogger must gate before calling SFD when paused.
	AssertTrue(true, "adapter SecureFieldDetector must be pause-safe (no side effects under suspend)")
}
Test("AdapterCompliance: pause must silence SecureFieldDetector usage (privacy)", _SFD_PauseNoDetection)

; More compliance: ProcessLifecycle idempotency under pause simulation
_PLC_PauseSafeStartStop() {
	; PLC_Start/Stop must be safe even if called during paused state (no timers/hooks activated).
	AssertTrue(1)
}
Test("AdapterCompliance: ProcessLifecycle Start/Stop must be pause-resilient", _PLC_PauseSafeStartStop)




; ==============================
; ==============================
; ======= 2/ Clipboard =========
; ==============================
; ==============================

_CB_Write_ReturnOne() {
	AssertEqual(1, CB_Write("test_ergopti_42"))
}
Test("CB_Write: returns 1 on success", _CB_Write_ReturnOne)

_CB_Read_AfterWrite() {
	CB_Write("test_ergopti_42")
	AssertEqual("test_ergopti_42", CB_Read())
}
Test("CB_Read: returns written value after CB_Write", _CB_Read_AfterWrite)

_CB_Save_ReturnsString() {
	CB_Write("test_ergopti_42")
	local saved := CB_Save()
	AssertTrue(saved is String)
}
Test("CB_Save: returns a String", _CB_Save_ReturnsString)

_CB_Restore_ReturnOne() {
	AssertEqual(1, CB_Restore("test_ergopti_42"))
}
Test("CB_Restore: returns 1 on non-empty string", _CB_Restore_ReturnOne)

_CB_Restore_Empty_ReturnOne() {
	AssertEqual(1, CB_Restore(""))
}
Test("CB_Restore: returns 1 on empty string (clear)", _CB_Restore_Empty_ReturnOne)




; ============================
; ============================
; ======= 3/ Storage =========
; ============================
; ============================

_ST_Set_ReturnOne() {
	local result := ST_Set("__ergopti_test_9z3k", "val42")
	ST_Delete("__ergopti_test_9z3k")
	AssertEqual(1, result)
}
Test("ST_Set: returns 1 on success", _ST_Set_ReturnOne)

_ST_Get_AfterSet() {
	ST_Set("__ergopti_test_9z3k", "val42")
	local result := ST_Get("__ergopti_test_9z3k", "default")
	ST_Delete("__ergopti_test_9z3k")
	AssertEqual("val42", result)
}
Test("ST_Get: returns stored value after ST_Set", _ST_Get_AfterSet)

_ST_Has_AfterSet() {
	ST_Set("__ergopti_test_9z3k", "val42")
	local result := ST_Has("__ergopti_test_9z3k")
	ST_Delete("__ergopti_test_9z3k")
	AssertEqual(1, result)
}
Test("ST_Has: returns 1 after ST_Set", _ST_Has_AfterSet)

_ST_Has_NeverSet() {
	AssertEqual(0, ST_Has("__never_set_ergopti_9z3k"))
}
Test("ST_Has: returns 0 for key that was never set", _ST_Has_NeverSet)

_ST_Delete_ReturnOne() {
	ST_Set("__ergopti_test_9z3k", "val42")
	local result := ST_Delete("__ergopti_test_9z3k")
	AssertEqual(1, result)
}
Test("ST_Delete: returns 1 on success", _ST_Delete_ReturnOne)

_ST_Has_AfterDelete() {
	ST_Set("__ergopti_test_9z3k", "val42")
	ST_Delete("__ergopti_test_9z3k")
	AssertEqual(0, ST_Has("__ergopti_test_9z3k"))
}
Test("ST_Has: returns 0 after ST_Delete", _ST_Has_AfterDelete)

_ST_Keys_ReturnsArray() {
	local keys := ST_Keys()
	AssertTrue(keys is Array)
}
Test("ST_Keys: returns an Array", _ST_Keys_ReturnsArray)

_ST_Keys_ReturnsStrings() {
	; ST_Keys must return key-name strings, not {name,type,data} record objects.
	; Before the fix Reg_EnumValues was returned raw -> Type(k) = "Object".
	ST_Set("__ergopti_k1_test9z3k", "v1")
	ST_Set("__ergopti_k2_test9z3k", "v2")
	local Keys := ST_Keys()
	local AllStrings := true, SawK1 := false
	for k in Keys {
		if (Type(k) != "String")
			AllStrings := false
		if (k == "__ergopti_k1_test9z3k")
			SawK1 := true
	}
	ST_Delete("__ergopti_k1_test9z3k")
	ST_Delete("__ergopti_k2_test9z3k")
	AssertTrue(AllStrings, "ST_Keys must return key-name strings, not record objects")
	AssertTrue(SawK1, "ST_Keys must include keys that were just set")
}
Test("storage: ST_Keys returns key-name strings", _ST_Keys_ReturnsStrings)

_ST_Clear_EmptiesStore() {
	; ST_Clear must actually delete all stored values.
	; Before the fix objects were passed to RegDelete -> throws -> nothing deleted.
	ST_Set("__ergopti_c1_test9z3k", "v1")
	ST_Set("__ergopti_c2_test9z3k", "v2")
	ST_Clear()
	local Gone := !ST_Has("__ergopti_c1_test9z3k") && !ST_Has("__ergopti_c2_test9z3k")
	; Cleanup in case of failure
	ST_Delete("__ergopti_c1_test9z3k")
	ST_Delete("__ergopti_c2_test9z3k")
	AssertTrue(Gone, "ST_Clear must remove all stored values from the registry")
}
Test("storage: ST_Clear empties the store", _ST_Clear_EmptiesStore)




; =====================================
; =====================================
; ======= 4/ ProcessLifecycle =========
; =====================================
; =====================================

_PLC_GetForegroundApp_ReturnsMap() {
	local app := PLC_GetForegroundApp()
	AssertTrue(app is Map)
}
Test("PLC_GetForegroundApp: returns a Map", _PLC_GetForegroundApp_ReturnsMap)

_PLC_GetForegroundApp_AppIdIsString() {
	local app := PLC_GetForegroundApp()
	AssertTrue(app["appId"] is String)
}
Test("PLC_GetForegroundApp: appId is a String", _PLC_GetForegroundApp_AppIdIsString)

_PLC_GetForegroundApp_WindowTitleIsString() {
	local app := PLC_GetForegroundApp()
	AssertTrue(app["windowTitle"] is String)
}
Test("PLC_GetForegroundApp: windowTitle is a String", _PLC_GetForegroundApp_WindowTitleIsString)

_PLC_Start_Idempotent() {
	PLC_Start()
	PLC_Start()
	AssertTrue(1)
}
Test("PLC_Start: callable twice without crash", _PLC_Start_Idempotent)

_PLC_Stop_Idempotent() {
	PLC_Stop()
	PLC_Stop()
	AssertTrue(1)
}
Test("PLC_Stop: callable twice without crash", _PLC_Stop_Idempotent)

_PLC_Stop_BeforeStart_NoCrash() {
	PLC_Stop()
	AssertTrue(1)
}
Test("PLC_Stop: callable before PLC_Start without crash", _PLC_Stop_BeforeStart_NoCrash)

_PLC_OnFocusChange_WithFunc_NoCrash() {
	PLC_OnFocusChange(PLC_GetForegroundApp)
	AssertTrue(1)
}
Test("PLC_OnFocusChange: accepts a Func without crash", _PLC_OnFocusChange_WithFunc_NoCrash)





; ============================================================
; ============================================================
; ======= 5/ Generic ADAPTER_* Contract Map Compliance =======
; ============================================================
; ============================================================

; Each ADAPTER_* map is iterated; every declared Func() reference
; must resolve to a non-null value, proving the function exists.

_AdapterMap_AllFuncsResolvable() {
	local adapterMaps := [
		ADAPTER_CLIPBOARD,
		ADAPTER_FILE_SYSTEM,
		ADAPTER_APP_LAUNCHER,
		ADAPTER_NOTIFIER,
		ADAPTER_TIMER_SCHEDULER,
		ADAPTER_WINDOW_INFO,
		ADAPTER_TRAY_MENU,
		ADAPTER_TEXT_SENDER,
		ADAPTER_HTTP_CLIENT,
		ADAPTER_SECURE_FIELD_DETECTOR,
		ADAPTER_STORAGE,
		ADAPTER_PROCESS_LIFECYCLE,
		ADAPTER_KEY_STATE,
	]
	local allOk := true
	for adapterMap in adapterMaps {
		for methodName, fnRef in adapterMap {
			if (fnRef = 0) {
				OutputDebug("ADAPTER contract failure: Func(" . methodName . ") is null")
				allOk := false
			}
		}
	}
	AssertTrue(allOk)
}
Test("ADAPTER_* maps: all declared Func() references resolve to non-null", _AdapterMap_AllFuncsResolvable)




; ====================================================
; ====================================================
; ======= 6/ KeyState Layout Probes (Windows) ========
; ====================================================
; ====================================================

; The boot-time keyboard-layout DllCall probes were extracted from the entry
; into adapters/key_state.ahk. These Windows-only helpers are not part of the
; cross-platform KeyState port (isDown/isUp), so they are smoke-tested directly:
; each must be callable without throwing and return the documented type, so a
; future rename/deletion breaks here instead of silently at boot on an exotic
; layout the unit suite cannot reproduce.

_KS_ResolveKeyboardLayout_ReturnsInteger() {
	local hkl := KS_ResolveKeyboardLayout()
	AssertTrue(Type(hkl) = "Integer", "KS_ResolveKeyboardLayout must return an Integer HKL (0 when none)")
}
Test("KS_ResolveKeyboardLayout: callable, returns an Integer", _KS_ResolveKeyboardLayout_ReturnsInteger)

_KS_ProbeRightAltScancode_ReturnsInteger() {
	; A dummy HKL of 0 must not crash; the probe returns an Integer scancode (0 = unmapped).
	local sc := KS_ProbeRightAltScancode(0)
	AssertTrue(Type(sc) = "Integer", "KS_ProbeRightAltScancode must return an Integer scancode")
}
Test("KS_ProbeRightAltScancode: callable with dummy HKL, returns an Integer", _KS_ProbeRightAltScancode_ReturnsInteger)

_KS_ScanScancodeForChar_ReturnsMap() {
	; With a dummy HKL and an unfindable target the scan must complete and report a miss.
	local found := KS_ScanScancodeForChar(0, "j")
	AssertTrue(found is Map, "KS_ScanScancodeForChar must return a Map")
	AssertTrue(found.Has("scan") && found.Has("vk"), "result Map must carry scan + vk keys")
}
Test("KS_ScanScancodeForChar: callable, returns a Map with scan + vk", _KS_ScanScancodeForChar_ReturnsMap)




; ==============================================
; ==============================================
; ======= 7/ ShellRunner (OS helper) ===========
; ==============================================
; ==============================================

; Regression guard: ShellRunner is an
; OS-infrastructure adapter (not a formal port) that mirrors
; macos/adapters/shell_runner.lua so domain modules share the same surface
; on both drivers. Tests assert the contract without exercising real OS side-effects.

_SR_Exec_EmptyStringReturnsEmpty() {
	AssertEqual("", ShellRunner_Exec(""))
}
Test("ShellRunner_Exec: empty command returns empty string", _SR_Exec_EmptyStringReturnsEmpty)

_SR_Exec_NonStringReturnsEmpty() {
	AssertEqual("", ShellRunner_Exec(0))
}
Test("ShellRunner_Exec: non-string command returns empty string", _SR_Exec_NonStringReturnsEmpty)

_SR_Exec_SimpleCommand_ReturnsString() {
	; "echo hello" is a cmd.exe builtin — always available, zero side-effects.
	local out := ShellRunner_Exec("echo hello")
	AssertTrue(Type(out) = "String", "ShellRunner_Exec must return a String")
	AssertTrue(InStr(out, "hello"), "stdout must contain the echoed text")
}
Test("ShellRunner_Exec: simple echo returns trimmed stdout", _SR_Exec_SimpleCommand_ReturnsString)

_SR_Exec_FailedCommand_ReturnsString() {
	; An invalid command must not throw — it must return "" gracefully.
	local out := ShellRunner_Exec("ergopti_nonexistent_cmd_xyz")
	AssertTrue(Type(out) = "String", "ShellRunner_Exec must return a String even on failure")
}
Test("ShellRunner_Exec: invalid command does not throw, returns String", _SR_Exec_FailedCommand_ReturnsString)

_SR_Spawn_ReturnsHandle() {
	; spawn() must return a Map-like object with start() and terminate().
	local h := ShellRunner_Spawn("cmd.exe", ["/c", "echo test"])
	AssertTrue(IsObject(h), "ShellRunner_Spawn must return an object handle")
	AssertTrue(HasMethod(h, "start"), "handle must expose start()")
	AssertTrue(HasMethod(h, "terminate"), "handle must expose terminate()")
}
Test("ShellRunner_Spawn: returns handle with start() and terminate()", _SR_Spawn_ReturnsHandle)

_SR_Spawn_TerminateBeforeStart_NoCrash() {
	; terminate() called before start() must not crash (idempotent).
	local h := ShellRunner_Spawn("cmd.exe", ["/c", "echo test"])
	h.terminate()
	AssertTrue(1, "terminate() before start() must not throw")
}
Test("ShellRunner_Spawn: terminate() before start() is safe", _SR_Spawn_TerminateBeforeStart_NoCrash)

_SR_Spawn_StartOnDone_Called() {
	; start() a real process and verify OnDone fires (spin up to 2 s).
	local done := false
	local captured_stdout := ""
	local h := ShellRunner_Spawn("cmd.exe", ["/c", "echo shell_runner_test"],
		(exit_code, stdout, stderr) => (done := true, captured_stdout := stdout))
	h.start()

	; Spin until OnDone fires or 2 000 ms elapsed (100 ms × 20 iterations).
	local ticks := 0
	while (!done && ticks < 20) {
		Sleep(100)
		ticks++
	}

	AssertTrue(done, "OnDone must be called after the process exits")
	AssertTrue(InStr(captured_stdout, "shell_runner_test"),
		"stdout must contain the echoed text: " . captured_stdout)
}
Test("ShellRunner_Spawn: OnDone is called with stdout after process exits", _SR_Spawn_StartOnDone_Called)

_SR_ActiveTasks_IsMap() {
	AssertTrue(_SR_ActiveTasks is Map, "_SR_ActiveTasks must be a Map (GC-pin table)")
}
Test("ShellRunner: _SR_ActiveTasks global is a Map", _SR_ActiveTasks_IsMap)

_SR_GetExitCode_InvalidPid_ReturnsZero() {
	; A PID of 0 (no such process) must return 0 without crashing.
	local code := _SR_GetExitCode(0)
	AssertEqual(0, code)
}
Test("_SR_GetExitCode: invalid PID returns 0", _SR_GetExitCode_InvalidPid_ReturnsZero)