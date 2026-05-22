; modules/tap_holds/lshift_lctrl.ahk

; ==============================================================================
; MODULE: Tap-Holds — LShift and LCtrl
; DESCRIPTION:
; LShift tap-hold (copy on tap / shift on hold) and LCtrl tap-hold (paste on
; tap / ctrl on hold).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 3/ LSHIFT AND LCTRL =======
; ==========================================
; ==========================================

#HotIf TapHoldTapAction(TapHold, "left_shift") == "copy" and not LayerEnabled
; Tap-hold on "LShift" : Ctrl + C on tap, Shift on hold
~$SC02A::
{
    TimeBefore := A_TickCount
    KeyWait("SC02A")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_shift") * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= TapMinDurationMs()
        and A_PriorKey == "LShift"
    ) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
        SendInput("{LCtrl Down}c{LCtrl Up}")
    }
}
#HotIf

#HotIf TapHoldTapAction(TapHold, "left_ctrl") == "paste" and not LayerEnabled
; This bug seems resolved now:
; << ~ must not be used here, otherwise [AltGr] [AltGr] ... [AltGr], which is supposed to give Tab multiple times, will suddenly block and keep LCtrl activated >>

; Tap-hold on "LControl" : Ctrl + V on tap, Ctrl on hold
~$SC01D::
{
    UpdateLastSentCharacter("LControl")
    TimeBefore := A_TickCount
    KeyWait("SC01D")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= TapHoldDuration(TapHold, "left_ctrl") * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= TapMinDurationMs()
        and A_PriorKey == "LControl"
        and not GetKeyState("SC03A", "P") ; "CapsLock"
        and not GetKeyState("SC038", "P") ; "LAlt"
    ) {
        SendInput("{LCtrl Down}v{LCtrl Up}")
    }
}
#HotIf
