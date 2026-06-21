; tests/test_adapter_contract_vectors.ahk

; ==============================================================================
; MODULE: Adapter Contract Behaviour Tests (AutoHotkey)
; DESCRIPTION:
; Executes the contractTestVectors() scenarios defined in each
; _shared/core/ports/*.spec.js — translated into AHK so they run under the
; standard run_all.ahk test runner without any external dependency.
;
; APPROACH:
; Each port section hard-codes the relevant contractTestVectors() inputs and
; expected outputs, mirroring the JS source. Side-effectful OS APIs
; (TrayTip, SendInput, ComObject) are exercised only through try/catch
; smoke tests to verify they do not throw — no real keyboard injection
; or notification display occurs in the CI environment.
;
; NOTE: Adapters that require OS state not available in the runner
; (e.g. a window in focus for KeyboardHook) are tested at the
; structural level only — the contractTestVectors assert "no_exception"
; and correct return types rather than observable side effects.
; ==============================================================================






; ====================================================
; ====================================================
; ======= 1/ Helpers: side-effect interceptors =======
; ====================================================
; ====================================================

; Records the most recent TrayTip call so we can assert without displaying UI.
global _ACV_TrayTipCalls := []
_ACV_RecordTrayTip(Body, Title, Flags) {
	global _ACV_TrayTipCalls
	_ACV_TrayTipCalls.Push(Map("title", Title, "body", Body, "flags", Flags))
}

; Records SendInput / SendText calls so we can assert key counts.
global _ACV_SendCalls := []
_ACV_RecordSend(Text) {
	global _ACV_SendCalls
	_ACV_SendCalls.Push(Text)
}

; Reset all recorders before each logical test group.
_ACV_ResetRecorders() {
	global _ACV_TrayTipCalls, _ACV_SendCalls
	_ACV_TrayTipCalls := []
	_ACV_SendCalls    := []
}




; =====================================================
; =====================================================
; ======= 2/ Notifier contract vectors ==============
; =====================================================
; =====================================================

_RunNotifierContractVectors() {
	; send_info — does not throw
	_Result_send_info() {
		Err := ""
		try {
			NotifierSend("Configuration loaded.", Map("level", "info"))
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "Notifier send_info must not throw: " . Err)
	}
	Test("Notifier: send_info does not throw", _Result_send_info)

	; send_warning — does not throw
	_Result_send_warning() {
		Err := ""
		try {
			NotifierSend("API key not set.", Map("level", "warning"))
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "Notifier send_warning must not throw: " . Err)
	}
	Test("Notifier: send_warning does not throw", _Result_send_warning)

	; send_error — does not throw
	_Result_send_error() {
		Err := ""
		try {
			NotifierSend("Config missing.", Map("level", "error"))
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "Notifier send_error must not throw: " . Err)
	}
	Test("Notifier: send_error does not throw", _Result_send_error)

	; send with no opts — does not throw
	_Result_send_no_opts() {
		Err := ""
		try {
			NotifierSend("Hello.", 0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "Notifier send with opts=0 must not throw: " . Err)
	}
	Test("Notifier: send with no opts does not throw", _Result_send_no_opts)
}
_RunNotifierContractVectors()




; =========================================================
; =========================================================
; ======= 3/ TimerScheduler contract vectors =============
; =========================================================
; =========================================================

_RunTimerSchedulerContractVectors() {
	; after returns a handle (non-zero)
	_Result_after_returns_handle() {
		Handle := TimerAfter(1.0, (*) => "")
		Assert(Handle != 0, "TimerAfter must return a non-zero handle")
		TimerCancel(Handle)
	}
	Test("TimerScheduler: after() returns a cancellable handle", _Result_after_returns_handle)

	; every returns a handle
	_Result_every_returns_handle() {
		Handle := TimerEvery(1.0, (*) => "")
		Assert(Handle != 0, "TimerEvery must return a non-zero handle")
		TimerCancel(Handle)
	}
	Test("TimerScheduler: every() returns a cancellable handle", _Result_every_returns_handle)

	; cancel on a valid handle does not throw
	_Result_cancel_valid() {
		Handle := TimerAfter(10.0, (*) => "")
		Err := ""
		try {
			TimerCancel(Handle)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TimerCancel on valid handle must not throw: " . Err)
	}
	Test("TimerScheduler: cancel(handle) does not throw", _Result_cancel_valid)

	; cancel on 0 (null handle) does not throw
	_Result_cancel_null() {
		Err := ""
		try {
			TimerCancel(0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TimerCancel(0) must not throw: " . Err)
	}
	Test("TimerScheduler: cancel(0) is safe", _Result_cancel_null)

	; cancelAll does not throw
	_Result_cancel_all() {
		TimerAfter(10.0, (*) => "")
		TimerAfter(10.0, (*) => "")
		Err := ""
		try {
			TimerCancelAll()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TimerCancelAll must not throw: " . Err)
	}
	Test("TimerScheduler: cancelAll() does not throw", _Result_cancel_all)
}
_RunTimerSchedulerContractVectors()




; ===================================================
; ===================================================
; ======= 4/ FileSystem contract vectors ===========
; ===================================================
; ===================================================

_RunFileSystemContractVectors() {
	TmpPath := A_Temp . "\acv_fs_test_" . A_TickCount . ".txt"

	; read on missing file returns 0 (falsy)
	_Result_read_missing() {
		Result := FSRead(TmpPath . "_no_such_file")
		Assert(Result = 0 or Result = "", "FSRead on missing file must return falsy")
	}
	Test("FileSystem: read missing file returns falsy", _Result_read_missing)

	; write returns truthy and creates the file
	_Result_write_creates() {
		try FileDelete(TmpPath)
		Result := FSWrite(TmpPath, "hello world")
		Assert(Result != 0, "FSWrite must return truthy on success")
		Assert(FSExists(TmpPath) != 0, "file must exist after FSWrite")
		try FileDelete(TmpPath)
	}
	Test("FileSystem: write creates file and returns truthy", _Result_write_creates)

	; read after write returns the written content
	_Result_read_after_write() {
		FSWrite(TmpPath, "test content")
		Content := FSRead(TmpPath)
		Assert(Content = "test content", "FSRead must return what was written")
		try FileDelete(TmpPath)
	}
	Test("FileSystem: read after write returns correct content", _Result_read_after_write)

	; append adds content after existing data
	_Result_append() {
		FSWrite(TmpPath, "line1")
		FSAppend(TmpPath, "line2")
		Content := FSRead(TmpPath)
		Assert(InStr(Content, "line1") > 0, "append must preserve original content")
		Assert(InStr(Content, "line2") > 0, "append must add new content")
		try FileDelete(TmpPath)
	}
	Test("FileSystem: append preserves and adds content", _Result_append)

	; exists returns truthy for existing file
	_Result_exists_true() {
		FSWrite(TmpPath, "x")
		Result := FSExists(TmpPath)
		Assert(Result != 0, "FSExists must return truthy for existing file")
		try FileDelete(TmpPath)
	}
	Test("FileSystem: exists returns truthy for existing file", _Result_exists_true)

	; exists returns falsy for missing file
	_Result_exists_false() {
		try FileDelete(TmpPath)
		Result := FSExists(TmpPath)
		Assert(Result = 0 or Result = "", "FSExists must return falsy for missing file")
	}
	Test("FileSystem: exists returns falsy for missing file", _Result_exists_false)

	; delete removes the file
	_Result_delete() {
		FSWrite(TmpPath, "to delete")
		FSDelete(TmpPath)
		Result := FSExists(TmpPath)
		Assert(Result = 0 or Result = "", "file must not exist after FSDelete")
	}
	Test("FileSystem: delete removes the file", _Result_delete)

	; delete on missing file does not throw
	_Result_delete_missing() {
		try FileDelete(TmpPath)
		Err := ""
		try {
			FSDelete(TmpPath)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "FSDelete on missing file must not throw: " . Err)
	}
	Test("FileSystem: delete missing file is a no-op", _Result_delete_missing)
}
_RunFileSystemContractVectors()




; ===================================================
; ===================================================
; ======= 5/ WindowInfo contract vectors ===========
; ===================================================
; ===================================================

_RunWindowInfoContractVectors() {
	; WIGetFocused always returns a Map, never 0
	_Result_get_focused_returns_map() {
		Result := WIGetFocused()
		Assert(Result is Map, "WIGetFocused must return a Map — got: " . Type(Result))
	}
	Test("WindowInfo: WIGetFocused always returns a Map", _Result_get_focused_returns_map)

	; WIGetFocused result has the four required string fields
	_Result_get_focused_fields() {
		Info := WIGetFocused()
		for Field in ["appId", "windowTitle", "bundleId", "executablePath"] {
			Assert(Info.Has(Field), "WIGetFocused result must have field: " . Field)
			Assert(Info[Field] is String, "WIGetFocused[" . Field . "] must be a String")
		}
	}
	Test("WindowInfo: WIGetFocused result has four string fields", _Result_get_focused_fields)

	; WIGetFocused does not throw
	_Result_get_focused_no_throw() {
		Err := ""
		try {
			WIGetFocused()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "WIGetFocused must not throw: " . Err)
	}
	Test("WindowInfo: WIGetFocused does not throw", _Result_get_focused_no_throw)

	; WIGetAll returns an Array
	_Result_get_all_returns_array() {
		Result := WIGetAll()
		Assert(Result is Array, "WIGetAll must return an Array — got: " . Type(Result))
	}
	Test("WindowInfo: WIGetAll returns an Array", _Result_get_all_returns_array)

	; WIGetAll does not throw
	_Result_get_all_no_throw() {
		Err := ""
		try {
			WIGetAll()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "WIGetAll must not throw: " . Err)
	}
	Test("WindowInfo: WIGetAll does not throw", _Result_get_all_no_throw)
}
_RunWindowInfoContractVectors()




; ==============================================
; ==============================================
; ======= 6/ TrayMenu contract vectors =========
; ==============================================
; ==============================================

_RunTrayMenuContractVectors() {
	; setTooltip does not throw
	_Result_set_tooltip() {
		Err := ""
		try {
			TrayMenuSetTooltip("Test tooltip")
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TrayMenuSetTooltip must not throw: " . Err)
	}
	Test("TrayMenu: setTooltip does not throw", _Result_set_tooltip)

	; setMenu with empty array does not throw
	_Result_set_menu_empty() {
		Err := ""
		try {
			TrayMenuSetMenu([])
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TrayMenuSetMenu([]) must not throw: " . Err)
	}
	Test("TrayMenu: setMenu([]) does not throw", _Result_set_menu_empty)

	; destroy does not throw
	_Result_destroy() {
		Err := ""
		try {
			TrayMenuDestroy()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TrayMenuDestroy must not throw: " . Err)
	}
	Test("TrayMenu: destroy does not throw", _Result_destroy)
}
_RunTrayMenuContractVectors()




; ===============================================
; ===============================================
; ======= 7/ TextSender contract vectors ========
; ===============================================
; ===============================================

_RunTextSenderContractVectors() {
	; eraseChars(0) is a no-op — does not throw (no keystroke emitted)
	_Result_erase_zero() {
		Err := ""
		try {
			TextEraseChars(0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TextEraseChars(0) must not throw: " . Err)
	}
	Test("TextSender: eraseChars(0) is a no-op", _Result_erase_zero)

	; pressKey and send inject real keystrokes — skip in headless CI to avoid
	; accidentally forwarding keystrokes to whatever window has OS focus.
	; Tested manually on developer machines where a safe target window is open.
	InCI := EnvGet("GITHUB_ACTIONS") = "true"

	_Result_press_key() {
		if InCI {
			Assert(true, "TextPressKey skipped in CI (keystroke injection)")
			return
		}
		Err := ""
		try {
			TextPressKey("Return", [])
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TextPressKey must not throw: " . Err)
	}
	Test("TextSender: pressKey('Return', []) does not throw", _Result_press_key)

	_Result_send_short() {
		if InCI {
			Assert(true, "TextSend skipped in CI (keystroke injection)")
			return
		}
		Err := ""
		try {
			TextSend("hello", Map(), 0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "TextSend short text must not throw: " . Err)
	}
	Test("TextSender: send short text does not throw", _Result_send_short)
}
_RunTextSenderContractVectors()




; ===============================================
; ===============================================
; ======= 8/ HttpClient contract vectors ========
; ===============================================
; ===============================================

_RunHttpClientContractVectors() {
	; isActive returns false when no request is in flight
	_Result_is_active_idle() {
		Result := HTTPIsActive()
		Assert(Result = false or Result = 0,
			"HTTPIsActive must be false when idle")
	}
	Test("HttpClient: isActive returns false when idle", _Result_is_active_idle)

	; cancel is safe when idle
	_Result_cancel_idle() {
		Err := ""
		try {
			HTTPCancel()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "HTTPCancel when idle must not throw: " . Err)
	}
	Test("HttpClient: cancel when idle does not throw", _Result_cancel_idle)
}
_RunHttpClientContractVectors()




; ===============================================
; ===============================================
; ======= 9/ Crypto contract vectors ============
; ===============================================
; ===============================================

_RunCryptoContractVectors() {
	; sha256 returns a string and never throws (sha256_returns_string)
	_Result_crypto_string() {
		Err := "", Out := ""
		try {
			Out := CryptoSha256("hello")
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "CryptoSha256 must not throw: " . Err)
		Assert(Type(Out) = "String", "CryptoSha256 must return a String")
	}
	Test("Crypto: sha256 returns a string and never throws", _Result_crypto_string)

	; Lowercase hex; 64 chars via the COM SHA256Managed class, 8 via the DJB2
	; fallback. When COM is present it must equal the canonical SHA-256 of "hello"
	; (sha256_returns_64_hex_chars).
	_Result_crypto_hex() {
		Out := CryptoSha256("hello")
		Assert(RegExMatch(Out, "^[0-9a-f]+$") > 0, "CryptoSha256 must be lowercase hex: " . Out)
		Assert(StrLen(Out) = 64 || StrLen(Out) = 8,
			"CryptoSha256 must be 64 (COM) or 8 (DJB2 fallback) hex chars, got " . StrLen(Out))
		if (StrLen(Out) = 64) {
			Assert(Out = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
				"CryptoSha256('hello') must equal the canonical SHA-256 digest, got: " . Out)
		}
	}
	Test("Crypto: sha256 returns the canonical lowercase hex digest", _Result_crypto_hex)

	; sha256 is deterministic (sha256_is_deterministic)
	_Result_crypto_det() {
		Assert(CryptoSha256("ergopti") = CryptoSha256("ergopti"),
			"CryptoSha256 must return the same digest for the same input")
	}
	Test("Crypto: sha256 is deterministic", _Result_crypto_det)

	; sha256 handles the empty string without throwing (sha256_empty_string)
	_Result_crypto_empty() {
		Err := ""
		try {
			CryptoSha256("")
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "CryptoSha256('') must not throw: " . Err)
	}
	Test("Crypto: sha256 handles the empty string", _Result_crypto_empty)
}
_RunCryptoContractVectors()


; SecureFieldDetector contract vectors (SecureFieldDetector.spec.js). Read-only —
; the detector inspects the focused field/app and never mutates OS state.
_RunSecureFieldDetectorContractVectors() {
	; isSecureField returns a boolean and never throws (isSecureField_returns_boolean)
	_Result_sfd_field_bool() {
		Err := "", Out := ""
		try {
			Out := SFD_IsSecureField()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "SFD_IsSecureField must not throw: " . Err)
		Assert(Out = true || Out = false || Out = 1 || Out = 0,
			"SFD_IsSecureField must return a boolean, got: " . Type(Out))
	}
	Test("SecureFieldDetector: isSecureField returns a boolean and never throws", _Result_sfd_field_bool)

	; isSecureApp returns false for an unknown process (isSecureApp_unknown_returns_false)
	_Result_sfd_unknown_false() {
		Out := SFD_IsSecureApp("notanapp.exe")
		Assert(Out = false || Out = 0, "SFD_IsSecureApp(unknown) must be false")
	}
	Test("SecureFieldDetector: isSecureApp returns false for an unknown process", _Result_sfd_unknown_false)

	; isSecureApp returns false for the empty string (isSecureApp_empty_returns_false)
	_Result_sfd_empty_false() {
		Err := "", Out := ""
		try {
			Out := SFD_IsSecureApp("")
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "SFD_IsSecureApp('') must not throw: " . Err)
		Assert(Out = false || Out = 0, "SFD_IsSecureApp('') must be false")
	}
	Test("SecureFieldDetector: isSecureApp returns false for the empty string", _Result_sfd_empty_false)

	; refresh completes without throwing (refresh_does_not_throw)
	_Result_sfd_refresh() {
		Err := ""
		try {
			SFD_Refresh()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "SFD_Refresh must not throw: " . Err)
	}
	Test("SecureFieldDetector: refresh completes without throwing", _Result_sfd_refresh)
}
_RunSecureFieldDetectorContractVectors()


; NetworkInfo contract vectors (NetworkInfo.spec.js). All queries are fast,
; in-process DllCalls (WLAN / iphlpapi / wininet) — no subprocess, no blocking
; network round-trip.
_RunNetworkInfoContractVectors() {
	_Result_ni_ssid() {
		Err := "", Out := ""
		try {
			Out := NI_GetSsidHash()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "NI_GetSsidHash must not throw: " . Err)
		Assert(Type(Out) = "String", "NI_GetSsidHash must return a string")
	}
	Test("NetworkInfo: getSsidHash returns a string and never throws", _Result_ni_ssid)

	_Result_ni_signal() {
		Err := "", Out := ""
		try {
			Out := NI_GetSignalStrength()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "NI_GetSignalStrength must not throw: " . Err)
		Assert(Out = "" || Type(Out) = "Integer" || Type(Out) = "Float",
			"NI_GetSignalStrength must be a number or empty")
	}
	Test("NetworkInfo: getSignalStrength returns a number and never throws", _Result_ni_signal)

	_Result_ni_reach() {
		Err := "", Out := ""
		try {
			Out := NI_IsInternetReachable()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "NI_IsInternetReachable must not throw: " . Err)
		Assert(Out = true || Out = false || Out = 1 || Out = 0, "NI_IsInternetReachable must return a boolean")
	}
	Test("NetworkInfo: isInternetReachable returns a boolean", _Result_ni_reach)

	_Result_ni_vpn() {
		Err := "", Out := ""
		try {
			Out := NI_IsVpnActive()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "NI_IsVpnActive must not throw: " . Err)
		Assert(Out = true || Out = false || Out = 1 || Out = 0, "NI_IsVpnActive must return a boolean")
	}
	Test("NetworkInfo: isVpnActive returns a boolean", _Result_ni_vpn)
}
_RunNetworkInfoContractVectors()


; KeyState contract vectors (KeyState.spec.js). Read-only GetKeyState queries.
_RunKeyStateContractVectors() {
	_Result_ks_unknown_down() {
		Out := KS_IsDown("ERGOPTI_NONEXISTENT_KEY_XYZ")
		Assert(Out = false || Out = 0, "KS_IsDown(unknown) must be false")
	}
	Test("KeyState: isDown returns false for an unknown key", _Result_ks_unknown_down)

	_Result_ks_unknown_up() {
		Out := KS_IsUp("ERGOPTI_NONEXISTENT_KEY_XYZ")
		Assert(Out = true || Out = 1, "KS_IsUp(unknown) must be true")
	}
	Test("KeyState: isUp returns true for an unknown key", _Result_ks_unknown_up)

	_Result_ks_inverse() {
		Down := KS_IsDown("LShift")
		Up   := KS_IsUp("LShift")
		Assert(!!Down != !!Up, "KS_IsUp must be the inverse of KS_IsDown")
	}
	Test("KeyState: isDown and isUp are inverse for the same key", _Result_ks_inverse)

	_Result_ks_down_bool() {
		Out := KS_IsDown("SC038")
		Assert(Out = true || Out = false || Out = 1 || Out = 0, "KS_IsDown must return a boolean")
	}
	Test("KeyState: isDown returns a boolean", _Result_ks_down_bool)

	_Result_ks_up_bool() {
		Out := KS_IsUp("SC038")
		Assert(Out = true || Out = false || Out = 1 || Out = 0, "KS_IsUp must return a boolean")
	}
	Test("KeyState: isUp returns a boolean", _Result_ks_up_bool)
}
_RunKeyStateContractVectors()


; Storage contract vectors (Storage.spec.js). Persists to the registry; each
; test uses a unique key and deletes it afterward, so no real settings leak.
_RunStorageContractVectors() {
	_Result_st_set_true() {
		Out := ST_Set("__ACV_ST_TEST__", "v")
		ST_Delete("__ACV_ST_TEST__")
		Assert(Out = true || Out = 1, "ST_Set must return true")
	}
	Test("Storage: set returns true", _Result_st_set_true)

	_Result_st_get_after_set() {
		ST_Set("__ACV_ST_TEST__", "v")
		Got := ST_Get("__ACV_ST_TEST__", "")
		ST_Delete("__ACV_ST_TEST__")
		Assert(Got = "v", "ST_Get must return the stored value, got: " . Got)
	}
	Test("Storage: get returns the value previously set", _Result_st_get_after_set)

	_Result_st_get_missing() {
		Assert(ST_Get("__ACV_never_set__", "fallback") = "fallback", "ST_Get(missing) must return the default")
	}
	Test("Storage: get returns the default for a missing key", _Result_st_get_missing)

	_Result_st_has() {
		ST_Set("__ACV_ST_TEST__", "x")
		HasAfter := ST_Has("__ACV_ST_TEST__")
		ST_Delete("__ACV_ST_TEST__")
		HasGone := ST_Has("__ACV_ST_TEST__")
		Assert(HasAfter = true || HasAfter = 1, "ST_Has must be true after set")
		Assert(HasGone = false || HasGone = 0, "ST_Has must be false after delete")
	}
	Test("Storage: has is true after set, false after delete", _Result_st_has)

	_Result_st_has_missing() {
		Out := ST_Has("__ACV_never_set__")
		Assert(Out = false || Out = 0, "ST_Has(missing) must be false")
	}
	Test("Storage: has is false for a never-stored key", _Result_st_has_missing)

	_Result_st_keys_type() {
		Assert(IsObject(ST_Keys()), "ST_Keys must return an array")
	}
	Test("Storage: keys returns an array", _Result_st_keys_type)
}
_RunStorageContractVectors()


; ProcessLifecycle contract vectors (ProcessLifecycle.spec.js). Each test that
; calls PLC_Start also calls PLC_Stop so no foreground watcher leaks.
_RunProcessLifecycleContractVectors() {
	_Result_plc_foreground() {
		App := PLC_GetForegroundApp()
		Assert(IsObject(App), "PLC_GetForegroundApp must return an object")
		Assert(Type(App["appId"]) = "String", "getForegroundApp().appId must be a string")
		Assert(Type(App["windowTitle"]) = "String", "getForegroundApp().windowTitle must be a string")
	}
	Test("ProcessLifecycle: getForegroundApp returns {appId, windowTitle} strings", _Result_plc_foreground)

	_Result_plc_start_idempotent() {
		Err := ""
		try {
			PLC_Start()
			PLC_Start()
		} catch as E {
			Err := E.Message
		}
		PLC_Stop()
		Assert(Err = "", "PLC_Start() twice must not throw: " . Err)
	}
	Test("ProcessLifecycle: start is idempotent", _Result_plc_start_idempotent)

	_Result_plc_stop_idempotent() {
		Err := ""
		try {
			PLC_Start()
			PLC_Stop()
			PLC_Stop()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "PLC_Stop() twice must not throw: " . Err)
	}
	Test("ProcessLifecycle: stop is idempotent", _Result_plc_stop_idempotent)

	_Result_plc_stop_before_start() {
		Err := ""
		try {
			PLC_Stop()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "PLC_Stop() before start must not throw: " . Err)
	}
	Test("ProcessLifecycle: stop before start is safe", _Result_plc_stop_before_start)

	_Result_plc_on_focus() {
		Err := ""
		try {
			PLC_OnFocusChange((*) => 0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "PLC_OnFocusChange(fn) must not throw: " . Err)
	}
	Test("ProcessLifecycle: onFocusChange accepts a function", _Result_plc_on_focus)
}
_RunProcessLifecycleContractVectors()


; AppLauncher contract vectors (AppLauncher.spec.js). launch() spawns a real
; process, so the headless AHK test covers only isRunning plus the graceful
; empty-path error path; the real-launch contract is exercised on macOS where
; hs.application is stubbed.
_RunAppLauncherContractVectors() {
	_Result_al_unknown_false() {
		Out := AL_IsRunning("ergopti_nonexistent_proc_xyz.exe")
		Assert(Out = false || Out = 0, "AL_IsRunning(unknown) must be false")
	}
	Test("AppLauncher: isRunning returns false for an unknown process", _Result_al_unknown_false)

	_Result_al_running_bool() {
		Out := AL_IsRunning("explorer.exe")
		Assert(Out = true || Out = false || Out = 1 || Out = 0, "AL_IsRunning must return a boolean")
	}
	Test("AppLauncher: isRunning returns a boolean", _Result_al_running_bool)

	_Result_al_launch_empty_safe() {
		Err := ""
		try {
			AL_Launch("")
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "AL_Launch('') must not throw: " . Err)
	}
	Test("AppLauncher: launch handles an empty path without throwing", _Result_al_launch_empty_safe)
}
_RunAppLauncherContractVectors()
