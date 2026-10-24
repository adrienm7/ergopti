; tests/unit/adapters/test_adapter_contract_vectors_system.ahk

; ==============================================================================
; MODULE: System Adapter Contract Vectors
; DESCRIPTION:
; Port contract vectors of the crypto, secure-field, network-info,
; key-state, storage, process, app-launcher, window-manager, mouse,
; clipboard, graphics and keyboard-hook adapters. Like the other vector
; files, each runner executes once at load.
; ==============================================================================

#Requires AutoHotkey v2.0





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


#Include network/test_network_info_native64_cache.ahk
