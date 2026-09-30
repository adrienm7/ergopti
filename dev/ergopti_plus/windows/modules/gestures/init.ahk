; modules/gestures/init.ahk
; Requires: TextSender, WindowManager, MouseControl

; ==============================================================================
; MODULE: Trackpad Gestures
; DESCRIPTION:
; Mirrors Hammerspoon's gesture system for Windows. Listens for keyboard
; shortcuts assigned to touchpad gestures via Windows Settings (Bluetooth &
; devices > Touchpad > Advanced gesture configuration).
;
; FEATURES & RATIONALE:
; 1. Toggle Selection: Triple-tap activates drag selection, any keystroke cancels.
; 2. Configurable Actions: Each gesture slot maps to an action chosen in the menu.
; 3. Architecture Mirror: Mirrors the Hammerspoon modules/gestures system exactly.
; 4. Auto-Configuration: Can write Windows registry to set up gesture shortcuts.
;
; WINDOWS SETUP:
; In Settings > Bluetooth & devices > Touchpad > Advanced gestures,
; assign the following shortcuts to the corresponding gestures:
;   - 3 finger tap:         Ctrl + Win + Shift + F1
;   - 3 finger swipe up:    Ctrl + Win + Shift + F2
;   - 3 finger swipe down:  Ctrl + Win + Shift + F3
;   - 3 finger swipe left:  Ctrl + Win + Shift + F4
;   - 3 finger swipe right: Ctrl + Win + Shift + F5
;   - 4 finger tap:         Ctrl + Win + Shift + F6
;   - 4 finger swipe up:    Ctrl + Win + Shift + F7
;   - 4 finger swipe down:  Ctrl + Win + Shift + F8
;   - 4 finger swipe left:  Ctrl + Win + Shift + F9
;   - 4 finger swipe right: Ctrl + Win + Shift + F10
; ==============================================================================

; #InputLevel 2 is intentionally NOT set here — ErgoptiPlus.ahk already sets
; it before including this module, so the hotkeys below fire at the correct
; level in production. Omitting it here lets the test runner include this file
; without forcing the keyboard hook installation on a headless CI runner, which
; would block the process indefinitely waiting for a system input device.





; ============================================
; ============================================
; ======= 1/ Constants & Configuration =======
; ============================================
; ============================================

; Pure gesture data (slot ids, shortcut labels) behind order-independent
; accessors. Included here rather than declared inline because consumers such as
; the first-run wizard run long before this file's top-level statements do.
#Include constants.ahk

; The Precision Touchpad registry contract comes from ONE table, generated from
; precision_touchpad_registry.toml (_generated/touchpad_registry.ahk). These
; globals are read-only views of it for the readers below (gesture status
; rows); every write goes through modules/gestures/touchpad_registry.ahk, which
; backs up the prior values first. None of these names is typed here.
_GestureRegistrySlotField(Field) {
		Slots := TouchpadRegistryData()["slots"]
		Result := Map()
		for Slot, Entry in Slots {
				if Entry.Has(Field)
						Result[Slot] := Entry[Field]
		}
		return Result
}

; Registry path for precision touchpad settings
global GESTURE_REG_PATH := TouchpadRegistryData()["key"]

; Registry value names of the new-system *Action for each gesture slot
global GESTURE_REG_ACTIONS := _GestureRegistrySlotField("action")

; Value meaning "Custom keyboard shortcut" in the registry
global GESTURE_REG_CUSTOM_VALUE := TouchpadRegistryData()["custom_value"]

; KeyParams per slot: (VK << 16) | Ctrl+Shift+Win, derived by the generator
global GESTURE_REG_KEY_PARAMS := _GestureRegistrySlotField("key_params")

; Old-system KeyParams registry value names (the ones Windows actually reads
; when sending the synthesised shortcut).
global GESTURE_REG_KEY_PARAMS_NAMES := _GestureRegistrySlotField("key_params_name")

; Old-system direction enables (swipe slots only)
global GESTURE_REG_ENABLE_NAMES := _GestureRegistrySlotField("enable")

; Tap slots use a "Custom*Tap" sentinel that means "user-defined shortcut".
global GESTURE_REG_CUSTOM_TAP_NAMES := _GestureRegistrySlotField("custom_tap")
global GESTURE_REG_CUSTOM_TAP_VALUE := TouchpadRegistryData()["custom_tap_value"]

; The family enable each slot needs, one per three/four-finger tap/slide family
global GESTURE_REG_FAMILY_ENABLES := _GestureRegistrySlotField("family_enable")

; Master enables — must be 65535 for the gesture family to be active
global GESTURE_REG_MASTER_ENABLES := TouchpadRegistryData()["family_enables"]

; Slot names — mirrors Hammerspoon's slot identifiers. The data itself lives in
; constants.ahk behind a function so consumers that run BEFORE this file's
; top-level statements (Onboarding_Run, ~300 lines earlier in ErgoptiPlus.ahk)
; can still read it; this global is the convenience alias every later reader
; already uses.
global GESTURE_SLOTS := GestureSlotIds()

; Human-readable labels for each slot
global GESTURE_SLOT_LABELS := Map()
for _GestureLabelIndex, _GestureLabelSlot in ["tap_3", "swipe_3_up", "swipe_3_down", "swipe_3_left", "swipe_3_right",
							"tap_4", "swipe_4_up", "swipe_4_down", "swipe_4_left", "swipe_4_right"] {
		GESTURE_SLOT_LABELS[_GestureLabelSlot] := t("gesture.slots." . _GestureLabelSlot)
}

; Shortcut labels for setup instructions — same order-independence story as
; GESTURE_SLOTS above.
global GESTURE_SHORTCUT_LABELS := GestureShortcutLabels()


#Include actions.ahk
#Include system_actions.ahk





; ==========================================
; ==========================================
; ======= 2/ Right-Click Hold Toggle =======
; ==========================================
; ==========================================

; Parses an AHK v2 shortcut string (e.g. "^+{Tab}", "!{Left}", "^t") into a
; TextPressKey-compatible (Key, Modifiers) pair and dispatches via the adapter.
; Handles: ^ = Ctrl, + = Shift, ! = Alt, # = Win.
; Bare letters (no braces) are passed as-is; {…} keys strip the braces.
_GestureParseAndPressKey(Keys) {
		Mods := []
		Pos  := 1
		; Consume modifier prefix characters one by one. AHK v2 has no break N;
		; use a flag to exit the outer loop when a non-modifier char is encountered.
		FoundKey := false
		loop {
				if FoundKey
						break
				Ch := SubStr(Keys, Pos, 1)
				switch Ch {
						case "^":
								Mods.Push("Ctrl")
								Pos++
						case "+":
								Mods.Push("Shift")
								Pos++
						case "!":
								Mods.Push("Alt")
								Pos++
						case "#":
								Mods.Push("Win")
								Pos++
						default:
								FoundKey := true
				}
		}
		KeyPart := SubStr(Keys, Pos)
		; Strip braces from {Key} notation
		if SubStr(KeyPart, 1, 1) = "{" and SubStr(KeyPart, -1) = "}"
				KeyPart := SubStr(KeyPart, 2, StrLen(KeyPart) - 2)
		TextPressKey(KeyPart, Mods)
}

; Sends a shortcut while neutralising the Ctrl+Win+Shift modifiers that the
; touchpad gesture itself is still holding down at callback time. Without this,
; e.g. Ctrl+Shift+Tab sent on top of held Ctrl+Win+Shift collapses to plain Tab.
GestureSendShortcut(Keys) {
		if !GestureReleaseOwnedCarrierModifiers()
				return
		_GestureParseAndPressKey(Keys)
}

; Releases only logically stuck members of the Ctrl+Win+Shift carrier. A key
; still physically held belongs to the user and must never receive synthetic Up.
GestureReleaseOwnedCarrierModifiers(StateReader := GetKeyState, Emitter := SendEvent) {
		Payload := "{Blind}"
		ReleaseCount := 0
		for _, ModKey in ["LControl", "RControl", "LShift", "RShift", "LWin", "RWin"] {
				if StateReader(ModKey) && !StateReader(ModKey, "P") {
						Payload .= "{" . ModKey . " Up}"
						ReleaseCount += 1
				}
		}
		if (ReleaseCount == 0)
				return true
		try {
				Emitter(Payload)
				return true
		} catch as Err {
				LoggerError("gestures", "Carrier modifier release failed: {1}.", Err.Message)
				return false
		}
}





; =====================================
; =====================================
; ======= 3/ Action Dispatching =======
; =====================================
; =====================================

; Executes the action assigned to a gesture slot.
GestureDispatch(slot) {
		global GestureAssignments, GESTURE_ACTIONS, Features

		; Guard against being called before auto-execute completes (e.g. hotkey fires
		; during a Reload triggered by enabling metrics)
		if !IsSet(GestureAssignments) or !IsSet(GESTURE_ACTIONS) or !IsSet(Features)
				return

		if !Features["gestures"]["enabled"] {
				return
		}

		if !GestureAssignments.Has(slot) {
				return
		}

		ActionName := GestureAssignments[slot]
		if (ActionName == "none" or !GESTURE_ACTIONS.Has(ActionName)) {
				return
		}

		; Release all modifiers held down by the touchpad shortcut (Ctrl+Win+Shift)
		; before firing the action — otherwise SendEvent/Send calls inherit the
		; still-down state and produce wrong combos on every swipe after the first.
		if !GestureReleaseOwnedCarrierModifiers()
				return
		LoggerDebug("gestures", "Dispatching gesture: {1} -> {2}.", slot, ActionName)

		; Any tap action (other than the click-toggle itself) must deactivate a held click
		; so that a selection started with left_click_toggle is properly released first.
		if (ActionName != "left_click_toggle" && ActionName != "right_click_toggle") {
				LeftReleased := GestureReleaseLeftClick()
				RightReleased := GestureReleaseRightClick()
				if !LeftReleased or !RightReleased {
						LoggerError("gestures", "Gesture {1} was refused because a synthetic mouse button release remains pending.", slot)
						return
				}
		}

		try {
		GestureInvokeAction(ActionName, GestureBindingId("gesture", slot))
				LoggerInfo("gestures", "Gesture {1} dispatched successfully.", slot)
		} catch as e {
				try LoggerError("gestures", "Gesture {1} action '{2}' threw: {3}.", slot, ActionName, e.Message)
		}
}





; ==============================================
; ==============================================
; ======= 4/ Hotkey Bindings (Listeners) =======
; ==============================================
; ==============================================

; These shortcuts must be assigned in Windows Settings > Bluetooth & devices
; > Touchpad > Advanced gesture configuration.
; Use the "Configurer automatiquement" button in the menu to set them via
; the registry, or assign them manually.

; No '$' prefix here — ErgoptiPlus.ahk sets #InputLevel 2 before including
; this module, which installs the low-level keyboard hook at the production
; level. Adding '$' here would also force the hook in the headless test runner
; (which includes this module without #InputLevel 2), causing a hang because
; no physical keyboard device is available on a CI runner.
^#+F1:: GestureDispatch("tap_3")
^#+F2:: GestureDispatch("swipe_3_up")
^#+F3:: GestureDispatch("swipe_3_down")
^#+F4:: GestureDispatch("swipe_3_left")
^#+F5:: GestureDispatch("swipe_3_right")
^#+F6:: GestureDispatch("tap_4")
^#+F7:: GestureDispatch("swipe_4_up")
^#+F8:: GestureDispatch("swipe_4_down")
^#+F9:: GestureDispatch("swipe_4_left")
^#+F10:: GestureDispatch("swipe_4_right")





; ==========================================
; ==========================================
; ======= 5/ Configuration & Setup ========
; ==========================================
; ==========================================

; Read configuration on load
GesturesReadConfig()
if !IsSet(_AHK_DRY_RUN)
	SetTimer((*) => GestureSystemRefresh(true), -1)

; The onboarding wizard cannot call GestureAutoConfigureRegistry() directly —
; when it runs (first launch, before this module's auto-exec body executes) the
; PrecisionTouchPad registry maps above are still unset. So the wizard instead
; records ``[Gestures] AutoConfigureOnNextStart = true`` in config.toml, and
; this block consumes that flag now that every dependency is available. The
; entry is cleared after one attempt regardless of outcome so we never retry on
; every subsequent reload (the tray menu's "Auto-configure" action stays the
; supported way to retry if something failed here).
_GestureAutoConfigureFlagEnabled(Raw) {
	if (Raw is String) && Raw == "_"
		return false
	if !(Raw is Integer) || (Raw != 0 && Raw != 1)
		throw TypeError(
			"gestures.auto_configure_on_next_start must be a TOML boolean")
	return Raw == 1
}

global _IniCache, ConfigurationFile
global GESTURE_AUTO_CONFIGURE_BOOT_DELAY_MS := 2000
RawAutoConfig := IniCacheGet(_IniCache, "gestures", "auto_configure_on_next_start")
if _GestureAutoConfigureFlagEnabled(RawAutoConfig)
		GestureConsumeAutoConfigureFlag(ConfigurationFile)

; Arm the WinEvent hook that tracks manual window activations.
; Skipped in the headless test runner (_AHK_DRY_RUN is defined by run_all.ahk)
; because SetWinEventHook with OUTOFCONTEXT keeps a message-loop reference alive
; and prevents ExitApp from returning promptly in a console-less CI process.
LoggerStart("gestures", "Initialising gestures module…")

_GestureWinOrder   := []
_GestureWinHook    := 0
_GestureCallbackPtr := 0
if !IsSet(_AHK_DRY_RUN) {
		; Store the callback pointer so _GestureUnhook can free it with CallbackFree,
		; preventing the fixed-size thunk leak on every script reload
		_GestureCallbackPtr := CallbackCreate(_GestureOnForeground, "F", 7)
		_GestureWinHook := DllCall("SetWinEventHook",
				"UInt", 0x0003,           ; EVENT_SYSTEM_FOREGROUND
				"UInt", 0x0003,
				"Ptr",  0,
				"Ptr",  _GestureCallbackPtr,
				"UInt", 0,
				"UInt", 0,
				"UInt", 0x0000)           ; WINEVENT_OUTOFCONTEXT
		; SetWinEventHook returns 0 on failure. Unchecked, a failed hook left
		; window-order tracking silently dead while the line below still announced
		; the module ready — so window-cycle gestures did nothing, with no clue why.
		if !_GestureWinHook
				LoggerError("gestures", "SetWinEventHook failed — window-order tracking disabled; window-cycle gestures will not work.")
}

; The readiness claim reports what was actually achieved rather than asserting
; more than it knows. This is also the closing half of the pair opened above:
; before, the module logged SUCCESS with no START at all, so an abort anywhere
; in this file — including the unprotected CallbackCreate/DllCall — produced no
; log line whatsoever, and "gestures failed" was indistinguishable from
; "gestures was never reached".
LoggerSuccess("gestures", "Gestures module initialised — ready (window hook: {1}).",
		_GestureWinHook ? "active" : "unavailable")
