--- _generated/action_catalogue.lua
--- AUTO-GENERATED from _shared/shortcuts/data/actions/actions.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:action-catalogue` to refresh.

--- ==============================================================================
--- MODULE: Action Catalogue (macOS)
--- DESCRIPTION:
--- Every action the macOS driver offers: the catalogue the two Lua drivers
--- share (_shared/shortcuts/engine/actions/catalogue_data.lua) filtered to this platform
--- when it loads, plus what only this driver declares. The driver loads this
--- table instead of parsing the shared TOML at runtime.
--- ==============================================================================

return require("shortcuts.engine.actions.catalogue").for_platform("hs", {
	karabiner_aliases = {
		["alt_tab_apps"] = "app_previous",
		["alt_tab_apps_list"] = "app_previous",
		["cmd_tab"] = "app_previous",
		["cycle_windows_in_app"] = "win_app_next",
		["delete_fwd"] = "delete",
		["return"] = "enter",
	},
	tap_hold_spellings = {
		["capsword"] = "caps_word",
		["delete_fwd"] = "delete",
		["opt_backspace"] = "ctrl_backspace",
		["opt_delete_fwd"] = "ctrl_delete",
		["return"] = "enter",
		["screen_capture"] = "ocr_screenshot",
		["space_next"] = "desktop_next",
		["space_next_wrap"] = "desktop_next_wrap",
		["space_prev"] = "desktop_prev",
		["space_prev_wrap"] = "desktop_prev_wrap",
		["sticky_shift"] = "one_shot_shift",
		["toggle_capslock"] = "caps_lock",
		["win_app_prev"] = "win_prev",
	},
})
