; _shared/modules/actions/brightness.ahk

; ==============================================================================
; MODULE: Screen Brightness Readback Policy
; DESCRIPTION:
; Validates complete native backlight receipts against the canonical action data.
; Native acquisition and cancellation remain with the Windows adapter.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Computes the requested percentage from an admitted native reading.
 * @param {Map} Data Canonical action data.
 * @param {String} Action Canonical brightness action id.
 * @param {Integer} Before Current backlight percentage.
 * @returns {Integer} Clamped target percentage.
 */
BrightnessTarget(Data, Action, Before) {
	if !(Before is Integer) || Before < 0 || Before > 100
		throw ValueError("Invalid native screen brightness percentage.")
	return Max(0, Min(100, Before + Data["actions"][Action]["direction"] * Data["step_percent"]))
}

/**
 * Accepts complete native readbacks, never a worker exit code alone.
 * @param {Map} Data Canonical policy.
 * @param {String} Action Requested action id.
 * @param {Any} Receipt Native worker JSON receipt.
 * @returns {Boolean} Every admitted display acknowledged its target.
 */
BrightnessAcknowledged(Data, Action, Receipt) {
	if !(Receipt is Map) || !(Receipt.Get("version", "") is Integer) || Receipt["version"] != Data["version"]
			|| !(Receipt.Get("action", 0) is String)
			|| StrCompare(Receipt["action"], Action, true) != 0
			|| !(Receipt.Get("status", 0) is String)
			|| StrCompare(Receipt["status"], "applied", true) != 0
		return false
	Displays := Receipt.Get("displays", 0)
	if !(Displays is Array) || Displays.Length == 0 || Displays.Length > Data["max_displays"]
		return false
	for Row in Displays {
		if !(Row is Map) || !(Row.Get("before", "") is Integer)
				|| Row["before"] < 0 || Row["before"] > 100
			return false
		Target := BrightnessTarget(Data, Action, Row["before"])
		if !(Row.Get("target", "") is Integer) || !(Row.Get("after", "") is Integer)
				|| Row["target"] != Target || Row["after"] != Target
			return false
	}
	return true
}
