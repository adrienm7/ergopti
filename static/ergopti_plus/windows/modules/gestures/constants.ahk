; modules/gestures/constants.ahk

; ==============================================================================
; MODULE: Gesture Data Constants
; DESCRIPTION:
; The pure, locale-independent gesture data — the ordered slot identifiers and
; the keyboard shortcut each slot is registered under in Windows Settings —
; exposed as FUNCTIONS rather than top-level globals.
;
; FEATURES & RATIONALE:
; 1. Order independence. #Include executes a file's top-level statements at the
;    include POSITION, and modules/gestures/init.ahk is included ~300 lines
;    after ErgoptiPlus.ahk calls Onboarding_Run(). Any consumer running during
;    the first-run wizard therefore saw GESTURE_SLOTS and GESTURE_SHORTCUT_LABELS
;    declared-but-unassigned. Function definitions have no such position: the
;    whole script is parsed before a single statement executes, so an accessor
;    answers correctly from the very first line of the auto-execute section.
;    That is what makes the wizard's « Enregistrer manuellement » tutorial able
;    to list its ten shortcut rows instead of rendering an empty panel.
; 2. Single owner. init.ahk seeds GESTURE_SLOTS / GESTURE_SHORTCUT_LABELS from
;    these accessors, so the tray menu, the config writer and the wizard all
;    read one copy of the data.
; 3. Locale-free by construction. GESTURE_SLOT_LABELS deliberately stays in
;    init.ahk: it calls t() at load time and must run after I18nPreload. Nothing
;    here may call t(), or the order independence above is lost again.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Gesture data accessors =======
; =========================================
; =========================================

; Ordered gesture slot identifiers. Mirrors Hammerspoon's slot identifiers.
; @return {Array} The canonical slot ids, in menu order.
GestureSlotIds() {
    static Slots := [
        "tap_3",
        "swipe_3_up",
        "swipe_3_down",
        "swipe_3_left",
        "swipe_3_right",
        "tap_4",
        "swipe_4_up",
        "swipe_4_down",
        "swipe_4_left",
        "swipe_4_right",
    ]
    return Slots
}

; The keyboard shortcut each slot must be bound to in Windows Settings >
; Touchpad > Advanced gestures. Shown verbatim in the manual-setup tutorial.
; @return {Map} slot id => human-readable shortcut label.
GestureShortcutLabels() {
    static Labels := Map(
        "tap_3", "Ctrl + Win + Shift + F1",
        "swipe_3_up", "Ctrl + Win + Shift + F2",
        "swipe_3_down", "Ctrl + Win + Shift + F3",
        "swipe_3_left", "Ctrl + Win + Shift + F4",
        "swipe_3_right", "Ctrl + Win + Shift + F5",
        "tap_4", "Ctrl + Win + Shift + F6",
        "swipe_4_up", "Ctrl + Win + Shift + F7",
        "swipe_4_down", "Ctrl + Win + Shift + F8",
        "swipe_4_left", "Ctrl + Win + Shift + F9",
        "swipe_4_right", "Ctrl + Win + Shift + F10",
    )
    return Labels
}
