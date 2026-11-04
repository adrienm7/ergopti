; tests/meta/platform/remap/layers/test_nav_layer_hotkey_interval.ahk

; ==============================================================================
; MODULE: Navigation Layer Hotkey Interval
; DESCRIPTION:
; A_MaxHotkeysPerInterval is raised once at load time, never from the
; functions a layer hotkey runs, or the first wheel burst warns before the
; assignment takes effect.
; ==============================================================================

#Requires AutoHotkey v2.0

; Regression: A_MaxHotkeysPerInterval set inside *WheelUp/WheelDown hotkey bodies
TestAuditV4_MaxHotkeysNotInHotkey() {
	Src := _DriverDirConcat("platform/remap")

	; The bug: assignment inside *WheelUp:: and *WheelDown:: hotkey bodies — only
	; takes effect after the first wheel event, too late to suppress the warning.
	; The fix: move assignment to module top-level (runs at #Include time).

	; Confirm the assignment exists (somewhere before the hotkey section).
	; Single-sourced from infra/nav_layer_helpers.ahk's NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL
	; constant (F16) rather than a duplicated literal.
	AssertTrue(
		InStr(Src, "A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL"),
		"nav_layer.ahk must set A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL"
	)

	; The wheel hotkeys are registered from layers.toml now
	; (platform/remap/nav_layer_table.ahk): every function a layer hotkey can
	; run must leave the variable alone.
	for FuncName in ["NavLayer_Callback", "_NavLayer_SendOnce", "_NavLayer_SendCounted", "_NavLayer_SetCount",
			"_NavLayer_MaximizeWindow", "_NavLayer_Swallow"] {
		Body := _DriverFuncBody(FuncName)
		AssertTrue(Body != "", FuncName . " must exist in platform/remap/nav_layer_table.ahk")
		AssertFalse(
			InStr(Body, "A_MaxHotkeysPerInterval"),
			"A_MaxHotkeysPerInterval must not be set by " . FuncName . ", which runs inside a layer hotkey"
		)
	}
}
Test("nav layer: A_MaxHotkeysPerInterval set at load time, not inside hotkey bodies", TestAuditV4_MaxHotkeysNotInHotkey)
