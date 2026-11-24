; menu/ui/builder/tray_shortcut_hint.ahk

; ==============================================================================
; MODULE: Tray Shortcut Hints
; DESCRIPTION:
; Shows, beside « Suspendre », « Recharger » and « Quitter », the chord that
; runs the same action (maintainer, 2026-11-24). Windows right-aligns the text
; after a tab in a menu item as its accelerator, so the caption becomes
; « Recharger<Tab>AltGr + ⌫ ». The chord is the live one a press
; runs (ScriptShortcutLiveChords, settings/engine/io.ahk), picked by the shared
; rule (ScriptChordHintSlot) and named as « Raccourcis de gestion du script »
; names its slot (SCRIPT_SHORTCUT_LABELS); every chord change reloads, so the
; rebuilt tray reads the new one. macOS shows it in grey, Linux in the label.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\..\_shared\keyboard\engine\layers\script_chord_hint.ahk
; The live chords and whether they are read yet (the entry includes it too; an
; already included file is skipped).
#Include %A_LineFile%\..\..\..\..\settings\engine\io.ahk
#Include %A_LineFile%\..\..\..\..\core\i18n\engine\locale.ahk

; The tray caption of a script-management row followed, after a tab, by the
; chord that runs its action; the caption alone when no chord runs it, or while
; the chords are not read yet (a tray staged before ReadScriptShortcutsConfig):
; the menu never depends on a chord store that has not loaded.
; @param Label {String} The row's caption.
; @param Action {String} Its action id (_shared/shortcuts/data/actions/actions.toml).
; @return {String}
ScriptShortcutTrayLabel(Label, Action) {
	global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS
	if !ScriptShortcutChordsAreRead()
		return Label
	Live := ScriptShortcutLiveChords()
	Slot := ScriptChordHintSlot(SCRIPT_SHORTCUT_SLOTS, Live["assignments"], Live["on"], Action)
	return (Slot == "") ? Label : Label . "`t" . t(SCRIPT_SHORTCUT_LABELS[Slot])
}
