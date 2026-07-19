; modules/tap_holds/nav_layer.ahk
; Requires: TextSender

; ==============================================================================
; MODULE: Tap-Holds — Navigation Layer
; DESCRIPTION:
; Full navigation layer activated when the configured hold key is held past
; its tap threshold. Remaps both hands to arrows, word/line/document
; navigation, window management, volume control, and line-operation shortcuts.
; Number-row keys 1-0 set the repeat multiplier for the current action.
; ==============================================================================

#Requires AutoHotkey v2.0

; Raise the per-interval hotkey limit once at load time so rapid wheel events
; never trigger the "too many hotkeys" warning before the first WheelUp/Down
; fires. Single-sourced from lib/nav_layer_helpers.ahk (loaded earlier, see
; ErgoptiPlus.ahk's #Include order) so ActivateLayer/DisableLayer restore
; this exact same ceiling instead of drifting to a different hardcoded number.
A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL





; ====================================
; ====================================
; ======= 10/ NAVIGATION LAYER =======
; ====================================
; ====================================

; ActivateLayer, DisableLayer, ResetNumberOfRepetitions, SetNumberOfRepetitions,
; and ActionLayer are defined in lib/nav_layer_helpers.ahk and loaded globally.

; Fix to get the CapsWord shortcut working when pressing "LAlt" activates the layer
#HotIf (LayerEnabled
    and TapHoldHoldLayer(TapHold, "left_alt") == "nav"
    and (
        Features["shortcuts"]["lalt_caps_lock"]["backspace"]
        or Features["shortcuts"]["lalt_caps_lock"]["caps_lock"]
        or Features["shortcuts"]["lalt_caps_lock"]["caps_word"]
        or Features["shortcuts"]["lalt_caps_lock"]["ctrl_backspace"]
        or Features["shortcuts"]["lalt_caps_lock"]["ctrl_delete"]
        or Features["shortcuts"]["lalt_caps_lock"]["delete"]
        or Features["shortcuts"]["lalt_caps_lock"]["one_shot_shift"]
    )
)
; Overrides the "BackSpace" shortcut on the layer
SC03A:: {
    DisableLayer() LAltCapsLockShortcut()
}
#HotIf

; Fix when LAlt triggers the layer
#HotIf (
    _LAltIsBackspaceLayer()
    and LayerEnabled
)
SC038:: TapHoldSyntheticKeyUp("LAlt") ; Necessary to do this, otherwise multicursor trigger in VSCode when scrolling in the layer and then leaving it
#HotIf

; Fix when Space triggers the layer
#HotIf (
    TapHoldHoldLayer(TapHold, "space") == "nav"
    and LayerEnabled
)
SC039:: return ; Necessary to do this, otherwise Space keeps being sent while it is held to get the layer
#HotIf

#HotIf LayerEnabled
; The base layer will become this one when the navigation layer variable is set to True

*WheelUp:: {
    ActionLayer("{Volume_Up " . AppState_GetNumberOfRepetitions() . "}") ; Turn on the volume by scrolling up
}
*WheelDown:: {
    ActionLayer("{Volume_Down " . AppState_GetNumberOfRepetitions() . "}") ; Turn down the volume by scrolling down
}

SC01D & ~SC138:: ; RAlt
RAlt:: ; RAlt on QWERTY
{
    ; Physical Kana AltGr is SC138 and has its own handler below. Do not let
    ; a virtual RAlt alias emit a second Escape for one physical tap.
    if (_ALTGR_KANA_FIXUP && GetKeyState("SC138", "P"))
        return
    ActionLayer("{Escape " . AppState_GetNumberOfRepetitions() . "}")
}

#HotIf LayerEnabled and _ALTGR_KANA_FIXUP
SC138:: {
    ActionLayer("{Escape " . AppState_GetNumberOfRepetitions() . "}")
}
#HotIf

#HotIf LayerEnabled

; === Number row ===
SC002:: SetNumberOfRepetitions(1) ; On key 1
SC003:: SetNumberOfRepetitions(2) ; On key 2
SC004:: SetNumberOfRepetitions(3) ; On key 3
SC005:: SetNumberOfRepetitions(4) ; On key 4
SC006:: SetNumberOfRepetitions(5) ; On key 5
SC007:: SetNumberOfRepetitions(6) ; On key 6
SC008:: SetNumberOfRepetitions(7) ; On key 7
SC009:: SetNumberOfRepetitions(8) ; On key 8
SC00A:: SetNumberOfRepetitions(9) ; On key 9





SC00B:: SetNumberOfRepetitions(10) ; On key 0

; ======= Left hand =======

; === Top row ===
SC010:: ActionLayer("^+{Home}") ; Select to the beginning of the document
SC011:: ActionLayer("^{Home}") ; Go to the beginning of the document
SC012:: ActionLayer("^{End}") ; Go to the end of the document
SC013:: ActionLayer("^+{End}") ; Select to the end of the document
SC014:: ActionLayer("{F2}")

; === Middle row ===
; ``Format("{X {1}}", N)`` collapsed into direct concatenation -- the call
; ran on every navigation keystroke and ``Format`` parses its template each
; time. Concatenation produces the same string with zero parsing overhead.
SC03A:: ActionLayer("{BackSpace " . AppState_GetNumberOfRepetitions() . "}") ; "CapsLock" becomes BackSpace
SC01E:: ActionLayer("^+{Up " . AppState_GetNumberOfRepetitions() . "}")
SC01F:: ActionLayer("{Up " . AppState_GetNumberOfRepetitions() . "}") ; Up arrow
SC020:: ActionLayer("{Down " . AppState_GetNumberOfRepetitions() . "}") ; Down arrow
SC021:: ActionLayer("^+{Down " . AppState_GetNumberOfRepetitions() . "}")
SC022:: ActionLayer("{F12}")

; === Bottom row ===
SC056:: ActionLayer("!+{Up " . AppState_GetNumberOfRepetitions() . "}")  ; Duplicate the line up
SC02C:: ActionLayer("!{Up " . AppState_GetNumberOfRepetitions() . "}") ; Move the line up
SC02D:: ActionLayer("!{Down " . AppState_GetNumberOfRepetitions() . "}") ; Move the line down
SC02E:: ActionLayer("!+{Down " . AppState_GetNumberOfRepetitions() . "}") ; Duplicate the line down
SC02F:: ActionLayer("{End}{Enter " . AppState_GetNumberOfRepetitions() . "}") ; Start a new line below the cursor





; SC030:: ; On K

; ======= Right hand =======

; === Top row ===
SC015:: ActionLayer("+{Home}") ; Select everything to the beginning of the line
SC016:: ActionLayer("^+{Left " . AppState_GetNumberOfRepetitions() . "}") ; Select the previous word
SC017:: ActionLayer("+{Left " . AppState_GetNumberOfRepetitions() . "}") ; Select the previous character
SC018:: ActionLayer("+{Right " . AppState_GetNumberOfRepetitions() . "}") ; Select the next character
SC019:: ActionLayer("^+{Right " . AppState_GetNumberOfRepetitions() . "}") ; Select the next word
SC01A:: ActionLayer("+{End}") ; Select everything to the end of the line

; === Middle row ===
SC023:: ActionLayer("#+{Left}") ; Move the window to the left screen
SC024:: ActionLayer("^{Left " . AppState_GetNumberOfRepetitions() . "}") ; Move to the previous word
SC025:: ActionLayer("{Left " . AppState_GetNumberOfRepetitions() . "}") ; Left arrow
SC026:: ActionLayer("{Right " . AppState_GetNumberOfRepetitions() . "}") ; Right arrow
SC027:: ActionLayer("^{Right " . AppState_GetNumberOfRepetitions() . "}") ; Move to the next word
SC028:: ActionLayer("#+{Right}") ; Move the window to the right screen

; === Bottom row ===
SC031:: WinMaximize("A") ; Make the window fullscreen
SC032:: ActionLayer("{Home}") ; Go to the beginning of the line
SC033:: ActionLayer("#{Left}") ; Move the window to the left of the current screen
SC034:: ActionLayer("#{Right}") ; Move the window to the right of the current screen
SC035:: ActionLayer("{End}") ; Go to the end of the line
#HotIf
