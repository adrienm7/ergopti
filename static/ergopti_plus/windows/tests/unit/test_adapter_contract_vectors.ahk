; tests/unit/test_adapter_contract_vectors.ahk

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

	_Result_delete_classifies_native_receipt() {
		Deleted := (*) => Map("deleted", true, "error", 0)
		Missing := (*) => Map("deleted", false, "error", 2)
		MissingParent := (*) => Map("deleted", false, "error", 3)
		AccessDenied := (*) => Map("deleted", false, "error", 5)
		AssertTrue(_FSDeleteWith("C:\fixture", Deleted))
		AssertTrue(_FSDeleteWith("C:\fixture", Missing),
			"an already absent file is an idempotent delete success")
		AssertTrue(_FSDeleteWith("C:\fixture", MissingParent),
			"an absent parent proves the target file is absent")
		AssertFalse(_FSDeleteWith("C:\fixture", AccessDenied),
			"an access failure must not masquerade as absence")
	}
	Test("FileSystem: delete classifies one native receipt (fs-delete-native-receipt)",
		_Result_delete_classifies_native_receipt)
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
			; Injecting a keystroke into whatever window has focus on a CI runner is
			; genuinely unsafe, so the BEHAVIOUR cannot be exercised here. Asserting
			; true was the wrong response: it reported a pass for something that never
			; ran. What CI can still check is that the entry point exists and routes
			; through the adapter — which is what actually breaks in a refactor.
			Assert(IsSet(TextPressKey), "TextPressKey must exist even where it cannot be exercised")
			Body := _DriverFuncBody("TextPressKey")
			Assert(InStr(Body, "Send") > 0 or InStr(Body, "ControlSend") > 0,
				"TextPressKey must reach a real send primitive — a stub that silently does "
				. "nothing would pass every other test in this file")
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
			; Same reasoning as pressKey above: the injection cannot run here, but the
			; surface can still be held to its contract.
			Assert(IsSet(TextSend), "TextSend must exist even where it cannot be exercised")
			Body := _DriverFuncBody("TextSend")
			Assert(InStr(Body, "Send") > 0 or InStr(Body, "ControlSend") > 0,
				"TextSend must reach a real send primitive")
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

	; Lowercase hex, and it must be a REAL SHA-256. This assertion used to accept
	; "64 or 8" chars and gate the canonical-digest check behind `if len = 64` —
	; so it passed while the adapter returned the 8-char DJB2 fallback on every
	; single call, certifying the very defect it was meant to catch. CNG ships
	; with Windows, so the degraded length is now a failure, not an alternative.
	_Result_crypto_hex() {
		Out := CryptoSha256("hello")
		Assert(RegExMatch(Out, "^[0-9a-f]+$") > 0, "CryptoSha256 must be lowercase hex: " . Out)
		Assert(StrLen(Out) = 64,
			"CryptoSha256 must return 64 hex chars — a length of 8 means the DJB2 fallback ran "
			. "and every privacy hash in the product is collision-prone; got " . StrLen(Out))
		Assert(Out = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
			"CryptoSha256('hello') must equal the canonical SHA-256 digest, got: " . Out)
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


; WindowManager contract vectors (WindowManager.spec.js). All mutating calls use
; a nonexistent window handle (no-op -> false), so nothing real is activated or
; killed; the rest are read-only queries.
_RunWindowManagerContractVectors() {
	_Result_wm_activate_false() {
		Out := WMActivate(999999999)
		Assert(Out = false || Out = 0, "WMActivate(missing) must be false")
	}
	Test("WindowManager: activate returns false for a missing window", _Result_wm_activate_false)

	_Result_wm_exists_false() {
		Out := WMExists(999999999)
		Assert(Out = false || Out = 0, "WMExists(missing) must be false")
	}
	Test("WindowManager: exists returns false for a missing window", _Result_wm_exists_false)

	_Result_wm_kill_false() {
		Out := WMKill(999999999)
		Assert(Out = false || Out = 0, "WMKill(missing) must be false")
	}
	Test("WindowManager: kill returns false for a missing window", _Result_wm_kill_false)

	_Result_wm_getlist() {
		Err := "", Out := ""
		try {
			Out := WMGetList()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "WMGetList must not throw: " . Err)
		Assert(IsObject(Out), "WMGetList must return an array")
	}
	Test("WindowManager: getList returns an array", _Result_wm_getlist)

	_Result_wm_gettitle_empty() {
		Assert(WMGetTitle(999999999) = "", "WMGetTitle(missing) must be the empty string")
	}
	Test("WindowManager: getTitle returns empty string for a missing window", _Result_wm_gettitle_empty)

	_Result_wm_getfocused() {
		Err := "", App := ""
		try {
			App := WMGetFocused()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "WMGetFocused must not throw: " . Err)
		Assert(IsObject(App), "WMGetFocused must return an object")
		Assert(Type(App["hwnd"]) = "Integer" || Type(App["hwnd"]) = "Float",
			"WMGetFocused().hwnd must be a number")
	}
	Test("WindowManager: getFocused returns an object with a numeric hwnd", _Result_wm_getfocused)
}
_RunWindowManagerContractVectors()


; MouseControl contract vectors (MouseControl.spec.js). setPos moves the REAL
; cursor via SetCursorPos, so the test saves the position first and restores it
; immediately after.
_RunMouseControlContractVectors() {
	_Result_mc_getpos() {
		Err := "", P := ""
		try {
			P := MCGetPos()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "MCGetPos must not throw: " . Err)
		Assert(IsObject(P), "MCGetPos must return an object")
		Assert((Type(P["x"]) = "Integer" || Type(P["x"]) = "Float")
			&& (Type(P["y"]) = "Integer" || Type(P["y"]) = "Float"),
			"MCGetPos().x/.y must be numbers")
	}
	Test("MouseControl: getPos returns {x, y} numbers and never throws", _Result_mc_getpos)

	_Result_mc_setpos() {
		Saved := MCGetPos()
		Err := ""
		try {
			MCSetPos(0, 0)
		} catch as E {
			Err := E.Message
		}
		MCSetPos(Saved["x"], Saved["y"])
		Assert(Err = "", "MCSetPos must not throw: " . Err)
	}
	Test("MouseControl: setPos does not throw (cursor restored)", _Result_mc_setpos)

	_Result_mc_monitor_count() {
		Err := "", N := ""
		try {
			N := MCGetMonitorCount()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "MCGetMonitorCount must not throw: " . Err)
		Assert((Type(N) = "Integer" || Type(N) = "Float") && N >= 0, "MCGetMonitorCount must be a number >= 0")
	}
	Test("MouseControl: getMonitorCount is a number >= 0", _Result_mc_monitor_count)

	_Result_mc_bounds() {
		B := MCGetMonitorBounds(1)
		Assert(IsObject(B), "MCGetMonitorBounds must return an object")
		Assert((Type(B["left"]) = "Integer" || Type(B["left"]) = "Float"), "bounds.left must be a number")
		Assert((Type(B["bottom"]) = "Integer" || Type(B["bottom"]) = "Float"), "bounds.bottom must be a number")
	}
	Test("MouseControl: getMonitorBounds returns numeric fields", _Result_mc_bounds)

	_Result_mc_bounds_invalid() {
		B := MCGetMonitorBounds(9999)
		Assert(B["left"] = 0 && B["top"] = 0 && B["right"] = 0 && B["bottom"] = 0,
			"getMonitorBounds(invalid) must return zeros")
	}
	Test("MouseControl: getMonitorBounds returns zeros for an invalid index", _Result_mc_bounds_invalid)
}
_RunMouseControlContractVectors()


; Clipboard contract vectors (Clipboard.spec.js). Operates on the REAL clipboard,
; so the whole scenario is wrapped in CB_SaveAll/CB_RestoreAll to preserve the
; user's clipboard (text AND binary) regardless of outcome.
_RunClipboardContractVectors() {
	_Result_clipboard_roundtrip() {
		SavedAll := CB_SaveAll()
		Err := ""
		try {
			; write_returns_true
			Assert(CB_Write("test") = true || CB_Write("test") = 1, "CB_Write must return true")
			; read_after_write
			CB_Write("ergopti_clipboard_test_42")
			Assert(CB_Read() = "ergopti_clipboard_test_42", "CB_Read must return what CB_Write wrote")
			; save_returns_snapshot_or_null
			Saved := CB_Save()
			Assert(Type(Saved) = "String", "CB_Save must return a string")
			; restore_null_clears
			Assert(CB_Restore("") = true || CB_Restore("") = 1, "CB_Restore(null) must return true")
			; read_empty_returns_null
			Assert(CB_Read() = "", "CB_Read after restore(null) must be empty")
		} catch as E {
			Err := E.Message
		}
		CB_RestoreAll(SavedAll)
		Assert(Err = "", "Clipboard round-trip must not throw: " . Err)
	}
	Test("Clipboard: write/read/save/restore round-trip (user clipboard preserved)", _Result_clipboard_roundtrip)
}
_RunClipboardContractVectors()


; GraphicsRenderer contract vectors (GraphicsRenderer.spec.js). The window is
; created HIDDEN (WS_POPUP without WS_VISIBLE), so create/destroy never put
; anything on screen. Two vectors are intentionally exercised only on macOS
; (stubbed hs.canvas): show()-visibility (GR_Show on a real handle would flash
; the real desktop) and draw_bitmap_calls_draw_fn (GR_DrawBitmap renders through
; a GDI DIB/UpdateLayeredWindow chain that does not complete on a hidden window
; in the headless runner, so the callback is not invoked here).
_RunGraphicsRendererContractVectors() {
	_Result_gr_create_nonzero() {
		H := GR_CreateWindow(Map("x", 100, "y", 100, "w", 200, "h", 200))
		GR_DestroyWindow(H)
		Assert(H != 0 && H != "", "GR_CreateWindow must return a non-zero handle")
	}
	Test("GraphicsRenderer: createWindow returns a non-zero handle", _Result_gr_create_nonzero)

	_Result_gr_zero_noops() {
		Err := ""
		try {
			GR_DestroyWindow(0)
			GR_Show(0)
			GR_Hide(0)
			GR_DrawBitmap(0, (*) => 0)
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "zero-handle calls must be no-ops without throwing: " . Err)
	}
	Test("GraphicsRenderer: destroy/show/hide/drawBitmap on a zero handle are no-ops", _Result_gr_zero_noops)
}
_RunGraphicsRendererContractVectors()



; KeyboardHook contract vectors (KeyboardHook.spec.js). The adapter registers with
; the shared HookDispatcher rather than creating its own InputHook, and KHStart
; does NOT start the underlying hook (HookDispatcher.Start owns that lifecycle), so
; these run headless without intercepting real keystrokes. Mirrors the macOS
; KeyboardHook vectors: start/stop toggle isRunning, stop is idempotent, getContext
; returns a Map, refreshContext does not throw, and the two event vectors emit
; the exact portable field shapes.
_RunKeyboardHookContractVectors() {
	_Result_kh_start_running() {
		KHStart(Map("onChar", (*) => 0, "onKey", (*) => 0))
		Running := KHIsRunning()
		KHStop()
		Assert(Running, "KHIsRunning() must be truthy after KHStart(); got " . Running)
	}
	Test("KeyboardHook: isRunning() is true after start()", _Result_kh_start_running)

	_Result_kh_stop_running() {
		KHStart(Map("onChar", (*) => 0, "onKey", (*) => 0))
		KHStop()
		Running := KHIsRunning()
		Assert(!Running, "KHIsRunning() must be falsy after KHStop(); got " . Running)
	}
	Test("KeyboardHook: isRunning() is false after stop()", _Result_kh_stop_running)

	_Result_kh_stop_idempotent() {
		Err := ""
		try {
			KHStop()
			KHStop()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "KHStop() when not running must not throw: " . Err)
	}
	Test("KeyboardHook: stop() when not running is safe (idempotent)", _Result_kh_stop_idempotent)

	_Result_kh_getcontext_map() {
		Ctx := KHGetContext()
		Assert(Ctx is Map, "KHGetContext() must return a Map; got type " . Type(Ctx))
	}
	Test("KeyboardHook: getContext() returns a Map", _Result_kh_getcontext_map)

	_Result_kh_refresh_no_throw() {
		Err := ""
		try {
			KHRefreshContext()
		} catch as E {
			Err := E.Message
		}
		Assert(Err = "", "KHRefreshContext() must not throw: " . Err)
	}
	Test("KeyboardHook: refreshContext() does not throw", _Result_kh_refresh_no_throw)

	_Result_kh_event_vectors() {
		global _KH_CONTEXT
		Chars := []
		Keys := []
		SavedContext := _KH_CONTEXT
		try {
			KHStart(Map(
				"onChar", (Event) => Chars.Push(Event),
				"onKey", (Event) => Keys.Push(Event)))
			_KH_CONTEXT := Map("appId", "contract.exe", "windowTitle", "Contract")
			Before := _KH_EpochMs()
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_CHAR, 0, "a")
			; Printable key-down belongs only to onChar.
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0x41, 0x1E)
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_DOWN, 0, 0x08, 0x0E)
			HookDispatcher.Dispatch(HookDispatcherConst.EVT_KB_UP, 0, 0x08, 0x0E)
			After := _KH_EpochMs()
		} finally {
			KHStop()
			_KH_CONTEXT := SavedContext
		}

		AssertEqual(1, Chars.Length,
			"onChar_fires_for_printable must emit one character event")
		CharEvent := Chars[1]
		AssertEqual(3, CharEvent.Count)
		AssertEqual("a", CharEvent["char"])
		AssertEqual("contract.exe", CharEvent["appId"])
		Assert(CharEvent["timestamp"] >= Before and CharEvent["timestamp"] <= After,
			"onChar timestamp must be Unix epoch milliseconds")

		AssertEqual(2, Keys.Length,
			"printable down must be filtered while Backspace down/up both emit")
		AssertEqual(4, Keys[1].Count)
		AssertEqual("Backspace", Keys[1]["key"])
		AssertEqual("contract.exe", Keys[1]["appId"])
		AssertTrue(Keys[1]["isDown"])
		AssertFalse(Keys[2]["isDown"])
		for KeyEvent in Keys {
			Assert(KeyEvent["timestamp"] >= Before and KeyEvent["timestamp"] <= After,
				"onKey timestamp must be Unix epoch milliseconds")
		}
	}
	Test("KeyboardHook vector onChar_fires_for_printable emits exact epoch event (keyboard-hook-event-contract)",
		_Result_kh_event_vectors)

	_Result_kh_normalized_names() {
		Fixtures := [
			[0x08, "Backspace"], [0x2E, "Delete"], [0x0D, "Enter"],
			[0x09, "Tab"], [0x1B, "Escape"], [0x25, "ArrowLeft"],
			[0x27, "ArrowRight"], [0x26, "ArrowUp"], [0x28, "ArrowDown"],
			[0x24, "Home"], [0x23, "End"], [0x21, "PageUp"],
			[0x22, "PageDown"]
		]
		Loop 12
			Fixtures.Push([0x6F + A_Index, "F" . A_Index])
		for Fixture in Fixtures
			AssertEqual(Fixture[2], _KH_NormalizeKey(Fixture[1]))
		AssertEqual("", _KH_NormalizeKey(0x41),
			"printable keys must not leak onto onKey")
	}
	Test("KeyboardHook vector onKey_fires_for_backspace uses normalized names (keyboard-hook-event-contract)",
		_Result_kh_normalized_names)
}
_RunKeyboardHookContractVectors()
