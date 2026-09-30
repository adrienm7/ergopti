; _generated/touchpad_registry.ahk
; AUTO-GENERATED from windows/modules/gestures/precision_touchpad_registry.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:touchpad-registry` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Precision Touchpad Registry Data (Windows)
; DESCRIPTION:
; Every registry value Ergopti writes so each gesture slot sends its
; Ctrl + Win + Shift + Fn shortcut, in write order. The in-process writer and
; the first-run wizard's elevated PowerShell script both read this data, and
; modules/gestures/touchpad_registry.ahk backs it up and restores it.
; ==============================================================================

; A function rather than a global initialiser so include ORDER cannot matter:
; the first-run wizard reads it before modules/gestures/init.ahk runs. Each
; call returns fresh maps, so no caller can alter what another one reads.
TouchpadRegistryData() {
	return Map(
		"key", "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad",
		"powershell_key", "HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad",
		"custom_value", 65535,
		"custom_tap_value", 7,
		"family_enables", ["ThreeFingerSlideEnabled", "ThreeFingerTapEnabled", "FourFingerSlideEnabled", "FourFingerTapEnabled"],
		"slot_ids", ["tap_3", "swipe_3_up", "swipe_3_down", "swipe_3_left", "swipe_3_right", "tap_4", "swipe_4_up", "swipe_4_down", "swipe_4_left", "swipe_4_right"],
		"slots", Map(
			"tap_3", Map("family_enable", "ThreeFingerTapEnabled", "function_key", 1, "key_params_name", "CustomThreeFingerTapKeyParams", "key_params", 7340039, "action", "ThreeFingerTapAction", "custom_tap", "CustomThreeFingerTap"),
			"swipe_3_up", Map("family_enable", "ThreeFingerSlideEnabled", "function_key", 2, "key_params_name", "ThreeFingerUpKeyParams", "key_params", 7405575, "action", "ThreeFingerSlideUpAction", "enable", "ThreeFingerUp"),
			"swipe_3_down", Map("family_enable", "ThreeFingerSlideEnabled", "function_key", 3, "key_params_name", "ThreeFingerDownKeyParams", "key_params", 7471111, "action", "ThreeFingerSlideDownAction", "enable", "ThreeFingerDown"),
			"swipe_3_left", Map("family_enable", "ThreeFingerSlideEnabled", "function_key", 4, "key_params_name", "ThreeFingerLeftKeyParams", "key_params", 7536647, "action", "ThreeFingerSlideLeftAction", "enable", "ThreeFingerLeft"),
			"swipe_3_right", Map("family_enable", "ThreeFingerSlideEnabled", "function_key", 5, "key_params_name", "ThreeFingerRightKeyParams", "key_params", 7602183, "action", "ThreeFingerSlideRightAction", "enable", "ThreeFingerRight"),
			"tap_4", Map("family_enable", "FourFingerTapEnabled", "function_key", 6, "key_params_name", "CustomFourFingerTapKeyParams", "key_params", 7667719, "action", "FourFingerTapAction", "custom_tap", "CustomFourFingerTap"),
			"swipe_4_up", Map("family_enable", "FourFingerSlideEnabled", "function_key", 7, "key_params_name", "FourFingerUpKeyParams", "key_params", 7733255, "action", "FourFingerSlideUpAction", "enable", "FourFingerUp"),
			"swipe_4_down", Map("family_enable", "FourFingerSlideEnabled", "function_key", 8, "key_params_name", "FourFingerDownKeyParams", "key_params", 7798791, "action", "FourFingerSlideDownAction", "enable", "FourFingerDown"),
			"swipe_4_left", Map("family_enable", "FourFingerSlideEnabled", "function_key", 9, "key_params_name", "FourFingerLeftKeyParams", "key_params", 7864327, "action", "FourFingerSlideLeftAction", "enable", "FourFingerLeft"),
			"swipe_4_right", Map("family_enable", "FourFingerSlideEnabled", "function_key", 10, "key_params_name", "FourFingerRightKeyParams", "key_params", 7929863, "action", "FourFingerSlideRightAction", "enable", "FourFingerRight")
		),
		"values", [
			Map("name", "ThreeFingerSlideEnabled", "value", 65535),
			Map("name", "ThreeFingerTapEnabled", "value", 65535),
			Map("name", "FourFingerSlideEnabled", "value", 65535),
			Map("name", "FourFingerTapEnabled", "value", 65535),
			Map("name", "CustomThreeFingerTap", "value", 7),
			Map("name", "CustomThreeFingerTapKeyParams", "value", 7340039),
			Map("name", "ThreeFingerTapAction", "value", 65535),
			Map("name", "ThreeFingerUp", "value", 65535),
			Map("name", "ThreeFingerUpKeyParams", "value", 7405575),
			Map("name", "ThreeFingerSlideUpAction", "value", 65535),
			Map("name", "ThreeFingerDown", "value", 65535),
			Map("name", "ThreeFingerDownKeyParams", "value", 7471111),
			Map("name", "ThreeFingerSlideDownAction", "value", 65535),
			Map("name", "ThreeFingerLeft", "value", 65535),
			Map("name", "ThreeFingerLeftKeyParams", "value", 7536647),
			Map("name", "ThreeFingerSlideLeftAction", "value", 65535),
			Map("name", "ThreeFingerRight", "value", 65535),
			Map("name", "ThreeFingerRightKeyParams", "value", 7602183),
			Map("name", "ThreeFingerSlideRightAction", "value", 65535),
			Map("name", "CustomFourFingerTap", "value", 7),
			Map("name", "CustomFourFingerTapKeyParams", "value", 7667719),
			Map("name", "FourFingerTapAction", "value", 65535),
			Map("name", "FourFingerUp", "value", 65535),
			Map("name", "FourFingerUpKeyParams", "value", 7733255),
			Map("name", "FourFingerSlideUpAction", "value", 65535),
			Map("name", "FourFingerDown", "value", 65535),
			Map("name", "FourFingerDownKeyParams", "value", 7798791),
			Map("name", "FourFingerSlideDownAction", "value", 65535),
			Map("name", "FourFingerLeft", "value", 65535),
			Map("name", "FourFingerLeftKeyParams", "value", 7864327),
			Map("name", "FourFingerSlideLeftAction", "value", 65535),
			Map("name", "FourFingerRight", "value", 65535),
			Map("name", "FourFingerRightKeyParams", "value", 7929863),
			Map("name", "FourFingerSlideRightAction", "value", 65535)
		])
}
