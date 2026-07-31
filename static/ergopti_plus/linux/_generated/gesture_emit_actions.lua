--- _generated/gesture_emit_actions.lua
--- AUTO-GENERATED from _shared/modules/actions/actions.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:gesture-emit-actions:linux` to refresh.

--- ==============================================================================
--- MODULE: Gesture Emit Actions (Linux)
--- DESCRIPTION:
--- Every action Linux performs as a single xdotool key combo, as
--- action id -> combo. modules/gestures/manager.lua looks the action up here
--- instead of carrying one elseif branch per action.
---
--- The combos are X11 keysym syntax and are Linux's own: `Return`, not AHK's
--- `Enter` or Hammerspoon's `return`. Linux and Windows agree far more often
--- than either agrees with macOS — alt+F4 and ctrl+Right on both, against
--- cmd+w and alt+right — so the divergence is macOS-versus-the-rest.
--- ==============================================================================

return {
	["app_switcher"] = "alt+Tab",
	["app_window_previous"] = "alt+Escape",
	["arrow_down"] = "Down",
	["arrow_left"] = "Left",
	["arrow_right"] = "Right",
	["arrow_up"] = "Up",
	["backspace"] = "BackSpace",
	["close_window"] = "alt+F4",
	["delete"] = "Delete",
	["doc_end"] = "ctrl+End",
	["doc_start"] = "ctrl+Home",
	["enter"] = "Return",
	["escape"] = "Escape",
	["fullscreen"] = "F11",
	["line_down"] = "Down",
	["line_end"] = "End",
	["line_start"] = "Home",
	["line_up"] = "Up",
	["maximize"] = "super+Up",
	["notification_center"] = "super+v",
	["snap_left"] = "super+Left",
	["snap_right"] = "super+Right",
	["tab_next"] = "ctrl+Tab",
	["tab_prev"] = "ctrl+shift+Tab",
	["word_next"] = "ctrl+Right",
	["word_prev"] = "ctrl+Left",
}
