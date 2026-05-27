; tests/test_adapter_contract_vectors.ahk

; ==============================================================================
; MODULE: Adapter Contract Behaviour Tests (AutoHotkey)
; DESCRIPTION:
; Executes the contractTestVectors() scenarios defined in each
; _shared/ports/*.spec.js — translated into AHK so they run under the
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
			NotifierSend("Configuration loaded.", Map("kind", "info"))
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
			NotifierSend("API key not set.", Map("kind", "warn"))
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
			NotifierSend("Config missing.", Map("kind", "error"))
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
