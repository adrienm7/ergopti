--- _generated/action_catalogue.lua
--- AUTO-GENERATED from _shared/modules/actions/actions.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:action-catalogue` to refresh.

--- ==============================================================================
--- MODULE: Action Catalogue (macOS)
--- DESCRIPTION:
--- Every action the macOS driver offers: the catalogue the two Lua drivers
--- share (_shared/lua/actions/catalogue_data.lua) filtered to this platform
--- when it loads, plus what only this driver declares. The driver loads this
--- table instead of parsing the shared TOML at runtime.
--- ==============================================================================

return require("actions.catalogue").for_platform("hs", {
	karabiner_aliases = {
		["alt_tab_apps"] = "app_previous",
		["alt_tab_apps_list"] = "app_previous",
		["cmd_tab"] = "app_previous",
		["cycle_windows_in_app"] = "win_app_next",
		["delete_fwd"] = "delete",
		["return"] = "enter",
	},
})
