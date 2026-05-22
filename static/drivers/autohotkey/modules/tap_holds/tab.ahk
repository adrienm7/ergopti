; modules/tap_holds/tab.ahk

; ==============================================================================
; MODULE: Tap-Holds — Tab
; DESCRIPTION:
; Tab tap-hold: AltTabMonitor on tap / Alt on hold. AltTabMonitor and
; GetMonitorFromPoint are defined in lib/window_utils.ahk and included
; globally before this module is loaded.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ==============================
; ======= 8/ TAB =======
; ==============================
; ==============================

#HotIf TapHoldTapAction(TapHold, "tab") == "alt_tab_monitor" and not LayerEnabled
; Tap-hold on "Tab": Alt + Tab on tap, Alt on hold
SC00F::LAlt
SC00F::
{
    SendInput("{LAlt Down}")
    tap := KeyWait("SC00F", "T" . TapHoldDuration(TapHold, "tab"))
    if tap {
        if TapHoldTapAction(TapHold, "left_alt") == "tab" and GetKeyState("SC038", "P") {
            SendInput("!{Tab}")
        } else {
            SendInput("{LAlt Up}")
            AltTabMonitor()
        }

    }
}
SC00F Up:: SendInput("{LAlt Up}")

; Pass-through for Tab with modifiers so Ctrl+Tab, Shift+Tab etc. still work
; despite the tap-hold intercepting the bare key
^SC00F:: SendEvent("^{Tab}")
^+SC00F:: SendEvent("^+{Tab}")
+SC00F:: SendInput("+{Tab}")
#SC00F:: SendEvent("#{Tab}")
#HotIf

; AltTabMonitor and GetMonitorFromPoint live in lib/window_utils.ahk so they
; can be exercised by unit tests without loading hotkey-registration code.
