; static/drivers/autohotkey/tests/test_adapter_compliance_new.ahk

; ==============================================================================
; MODULE: Adapter Compliance Tests (new adapters)
; DESCRIPTION:
; Surface-level compliance tests for the four new port adapters:
; SecureFieldDetector, Clipboard, Storage, and ProcessLifecycle.
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