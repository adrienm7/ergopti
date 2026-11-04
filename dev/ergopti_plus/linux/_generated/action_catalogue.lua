--- _generated/action_catalogue.lua
--- AUTO-GENERATED from _shared/modules/actions/actions.toml.
--- DO NOT EDIT BY HAND — run `npm run codegen:action-catalogue` to refresh.

--- ==============================================================================
--- MODULE: Action Catalogue (Linux)
--- DESCRIPTION:
--- Every action the Linux driver offers: the catalogue the two Lua drivers
--- share (_shared/lua/actions/catalogue_data.lua) filtered to this platform
--- when it loads, plus what only this driver declares. The driver loads this
--- table instead of parsing the shared TOML at runtime.
--- ==============================================================================

return require("actions.catalogue").for_platform("linux", {
	slots = {
		single = { "tap_2", "tap_3", "tap_4", "tap_5", "swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down", "swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down", "swipe_3_left", "swipe_3_right", "swipe_3_up", "swipe_3_down", "swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down", "swipe_4_left", "swipe_4_right", "swipe_4_up", "swipe_4_down", "swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down", "swipe_5_left", "swipe_5_right", "swipe_5_up", "swipe_5_down", "swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down" },
		axis = { "swipe_3_horiz", "swipe_4_horiz", "swipe_5_horiz" },
	},
})
