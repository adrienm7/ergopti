--- tests/unit/meta/test_config_window_overrides.lua

--- ==============================================================================
--- MODULE: Config Window — the actions that edit delays, colours and previews
--- DESCRIPTION:
--- Every message the shared settings window can send about an override, and what
--- this driver does with it.
---
--- ROOT CAUSE ENCODED:
--- The window is shared across drivers and speaks eleven actions. This bridge
--- answered four. So every delay field, colour swatch and preview switch the
--- window draws was inert here: the user clicked, the window updated its own
--- state, and nothing reached the daemon. Not a missing feature — a feature that
--- appears to be there.
---
--- WHY THE EMPTY SECTION HAS ITS OWN CASE:
--- The window spells "the category itself" as `section: ''`. Passed through
--- unchanged, that creates an override under a section no category has, which
--- never resolves and never appears — the setting vanishes silently and the
--- category keeps its old value.
---
--- WHY show_tooltip HAS ITS OWN CASE:
--- A JSON boolean arrives as a boolean, but a string "false" is TRUTHY in Lua.
--- Passing it through would turn the preview on for a user who had just turned
--- it off, which is the exact opposite of what they asked for.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module recording every override it is asked to apply.
--- @return table config, table log
local function recording_config()
	local log = { overrides = {}, resets = 0, cleared = {} }
	return {
		get_groups        = function() return { "rolls" } end,
		is_group_enabled  = function() return true end,
		mapping_count     = function() return 0 end,
		parse_error_count = function() return 0 end,
		get_config_dir    = function() return "/tmp" end,
		get_categories    = function() return { rolls = {} } end,
		set_override = function(category, section, field, value)
			log.overrides[#log.overrides + 1] = {
				category = category, section = section, field = field, value = value,
			}
		end,
		clear_override = function(category, section)
			log.cleared[#log.cleared + 1] = tostring(category) .. "/" .. tostring(section)
		end,
		reset_defaults = function() log.resets = log.resets + 1 end,
	}, log
end

--- Sends one message to the bridge.
--- @param payload table
--- @return table log
local function send(payload)
	local handler = helpers.load_module("ui.hotstrings_config_window.bridge")
	local config, log = recording_config()
	handler.on_message(payload, { config = config })
	return log
end





-- =================================================================
-- =================================================================
-- ======= 1/ Delays ===============================================
-- =================================================================
-- =================================================================

helpers.describe("config window: delay actions", function()

	helpers.it("applies a category delay", function()
		local log = send({ action = "set_delay", category = "rolls", section = "", value = 1.5 })
		helpers.assert_eq(#log.overrides, 1, "one override written")
		helpers.assert_eq(log.overrides[1].category, "rolls", "for the category the user edited")
		helpers.assert_eq(log.overrides[1].section, nil,
			"an empty section string is the window's spelling of 'the category "
				.. "itself'; passing it through creates an override under a section "
				.. "no category has, which never resolves and never appears")
		helpers.assert_eq(log.overrides[1].field, "delay", "the delay field")
		helpers.assert_eq(log.overrides[1].value, 1.5, "with the value the user typed")
	end)

	helpers.it("applies a section delay to that section", function()
		local log = send({ action = "set_delay", category = "rolls", section = "hc", value = 0.2 })
		helpers.assert_eq(log.overrides[1].section, "hc", "named, so the wrong rung cannot be written")
	end)

	helpers.it("coerces the delay to a number", function()
		local log = send({ action = "set_delay", category = "rolls", section = "", value = "2.5" })
		helpers.assert_eq(log.overrides[1].value, 2.5,
			"the window sends what a text field holds; a string here would be stored "
				.. "and then compared against numbers for the rest of the session")
	end)

	helpers.it("clears a delay by writing nil, not zero", function()
		local log = send({ action = "clear_delay", category = "rolls", section = "" })
		helpers.assert_eq(#log.overrides, 1, "clearing is still a write")
		helpers.assert_eq(log.overrides[1].value, nil,
			"zero means 'fire immediately' and is a legitimate setting; clearing must "
				.. "return the category to the cascade, not pin it at zero")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ Colours and previews =================================
-- =================================================================
-- =================================================================

helpers.describe("config window: colour and preview actions", function()

	helpers.it("applies and clears a colour", function()
		helpers.assert_eq(send({ action = "set_color", category = "rolls", section = "", value = "#ff0000" })
			.overrides[1].value, "#ff0000", "the colour the user picked")
		helpers.assert_eq(send({ action = "clear_color", category = "rolls", section = "" })
			.overrides[1].value, nil, "and clearing returns it to the cascade")
	end)

	helpers.it("stores show_tooltip as a real boolean", function()
		local log = send({ action = "set_tooltip", category = "rolls", section = "", value = false })
		helpers.assert_eq(log.overrides[1].field, "show_tooltip", "the right field")
		helpers.assert_eq(log.overrides[1].value, false, "and a boolean false, not nil")
	end)

	helpers.it("does not read the string \"false\" as true", function()
		-- A JSON boolean arrives as a boolean, but a bridge that has ever seen a
		-- string here must not treat it as truthy: that turns the preview ON for a
		-- user who just turned it off.
		local log = send({ action = "set_tooltip", category = "rolls", section = "", value = "false" })
		helpers.assert_eq(log.overrides[1].value, false,
			"every string is truthy in Lua, including \"false\"")
	end)

	helpers.it("clears the preview override without deciding for the user", function()
		local log = send({ action = "clear_tooltip", category = "rolls", section = "" })
		helpers.assert_eq(log.overrides[1].value, nil,
			"clearing must return the category to whatever its TOML says, not force "
				.. "the preview on")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ Reset ================================================
-- =================================================================
-- =================================================================

helpers.describe("config window: reset", function()

	helpers.it("re-enables everything and clears every override", function()
		local log = send({ action = "reset_all" })
		helpers.assert_eq(log.resets, 1, "the enable state goes back to shipped")
		helpers.assert_true(#log.cleared >= 1,
			"and so do the delays and colours; a reset that left the overrides behind "
				.. "would look like it did nothing to the values the user can see")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ Degrading ============================================
-- =================================================================
-- =================================================================

helpers.describe("config window: with no config module", function()

	helpers.it("answers without raising", function()
		local handler = helpers.load_module("ui.hotstrings_config_window.bridge")
		local ok, err = pcall(function()
			handler.on_message({ action = "set_delay", category = "rolls", value = 1 }, {})
			handler.on_message({ action = "set_tooltip", category = "rolls", value = true }, {})
			handler.on_message({ action = "reset_all" }, {})
		end)
		helpers.assert_eq(ok, true,
			"the window can be opened before the config manager is ready, and a "
				.. "raise here takes the WebView down rather than the message: "
				.. tostring(err))
	end)

end)
