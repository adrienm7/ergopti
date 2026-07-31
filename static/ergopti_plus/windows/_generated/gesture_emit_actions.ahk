; _generated/gesture_emit_actions.ahk
; AUTO-GENERATED from _shared/modules/actions/actions.toml.
; DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Gesture Emit Actions (Windows)
; DESCRIPTION:
; Every action whose behaviour the shared catalogue fully describes: a key plus
; modifiers, or a raw send sequence. modules/gestures/actions.ahk turns these
; into registry handlers at static-init, so nothing here runs on the boot path
; and no TOML is parsed to register them.
;
; These were 62 hand-written lambdas in a Map literal, with the same intent
; spelled again in the macOS and Linux registries — three copies of one fact,
; where a wrong one is invisible: a `copy` action sending Ctrl+X is not a crash
; and not a failing test.
; ==============================================================================

; id -> { Key, Mods } for a key press, or { Seq } for a raw send sequence.
; A function, not a global, so include order cannot matter.
GestureEmitActionsData() {
	return Map(
		"app_switcher", { Key: "Tab", Mods: ["Alt"] },
		"arrow_down", { Key: "Down", Mods: [] },
		"arrow_left", { Key: "Left", Mods: [] },
		"arrow_right", { Key: "Right", Mods: [] },
		"arrow_up", { Key: "Up", Mods: [] },
		"backspace", { Key: "BackSpace", Mods: [] },
		"brightness_down", { Key: "Brightness_Down", Mods: [] },
		"brightness_up", { Key: "Brightness_Up", Mods: [] },
		"close_window", { Key: "F4", Mods: ["Alt"] },
		"copy", { Key: "c", Mods: ["Ctrl"] },
		"ctrl_backspace", { Key: "BackSpace", Mods: ["Ctrl"] },
		"ctrl_delete", { Key: "Delete", Mods: ["Ctrl"] },
		"cut", { Key: "x", Mods: ["Ctrl"] },
		"delete", { Key: "Delete", Mods: [] },
		"desktop_close", { Key: "F4", Mods: ["Ctrl", "Win"] },
		"desktop_new", { Key: "d", Mods: ["Ctrl", "Win"] },
		"desktop_next", { Key: "Right", Mods: ["Ctrl", "Win"] },
		"desktop_prev", { Key: "Left", Mods: ["Ctrl", "Win"] },
		"doc_end", { Key: "End", Mods: ["Ctrl"] },
		"doc_start", { Key: "Home", Mods: ["Ctrl"] },
		"enter", { Key: "Enter", Mods: [] },
		"escape", { Key: "Escape", Mods: [] },
		"find", { Key: "f", Mods: ["Ctrl"] },
		"fullscreen", { Key: "F11", Mods: [] },
		"line_down", { Key: "Down", Mods: [] },
		"line_end", { Key: "End", Mods: [] },
		"line_start", { Key: "Home", Mods: [] },
		"line_up", { Key: "Up", Mods: [] },
		"maximize", { Key: "Up", Mods: ["Win"] },
		"minimize_all", { Key: "d", Mods: ["Win"] },
		"mute", { Key: "Volume_Mute", Mods: [] },
		"notification_center", { Key: "n", Mods: ["Win"] },
		"para_next", { Key: "Down", Mods: ["Ctrl"] },
		"para_prev", { Key: "Up", Mods: ["Ctrl"] },
		"paste", { Key: "v", Mods: ["Ctrl"] },
		"redo", { Key: "y", Mods: ["Ctrl"] },
		"screen_record", { Key: "r", Mods: ["Win", "Alt"] },
		"sel_down", { Key: "Down", Mods: ["Shift"] },
		"sel_left", { Key: "Left", Mods: ["Shift"] },
		"sel_right", { Key: "Right", Mods: ["Shift"] },
		"sel_up", { Key: "Up", Mods: ["Shift"] },
		"sel_word_next", { Key: "Right", Mods: ["Ctrl", "Shift"] },
		"sel_word_prev", { Key: "Left", Mods: ["Ctrl", "Shift"] },
		"select_all", { Key: "a", Mods: ["Ctrl"] },
		"snap_left", { Key: "Left", Mods: ["Win"] },
		"snap_right", { Key: "Right", Mods: ["Win"] },
		"space", { Key: "Space", Mods: [] },
		"tab_close", { Key: "w", Mods: ["Ctrl"] },
		"tab_new", { Key: "t", Mods: ["Ctrl"] },
		"task_view", { Key: "Tab", Mods: ["Win"] },
		"track_next", { Key: "Media_Next", Mods: [] },
		"track_play", { Key: "Media_Play_Pause", Mods: [] },
		"track_prev", { Key: "Media_Prev", Mods: [] },
		"undo", { Key: "z", Mods: ["Ctrl"] },
		"vol_down", { Key: "Volume_Down", Mods: [] },
		"vol_up", { Key: "Volume_Up", Mods: [] },
		"word_next", { Key: "Right", Mods: ["Ctrl"] },
		"word_prev", { Key: "Left", Mods: ["Ctrl"] },
		"ocr_screenshot", { Seq: "#+t" },
		"screen_capture", { Seq: "#+s" },
		"select_line", { Seq: "{Home}{Shift Down}{End}{Shift Up}" },
		"surround_parens", { Seq: "{Home}({End}){Home}" }
	)
}
