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

	-- These cases used to send `value`, which the window has never sent. The
	-- bridge read `payload.value` too, so they agreed with each other and with
	-- nothing else: the suite was green on a bridge that could not receive a
	-- single message the real page emits. Every payload below is now copied from
	-- _shared/ui/hotstrings_config_window/script.js.

	helpers.it("applies a category delay, converting the window's milliseconds to seconds", function()
		local log = send({ action = "set_delay", category = "rolls", section = "", ms = 1500 })
		helpers.assert_eq(#log.overrides, 1, "one override written")
		helpers.assert_eq(log.overrides[1].category, "rolls", "for the category the user edited")
		helpers.assert_eq(log.overrides[1].section, nil,
			"an empty section string is the window's spelling of 'the category "
				.. "itself'; passing it through creates an override under a section "
				.. "no category has, which never resolves and never appears")
		helpers.assert_eq(log.overrides[1].field, "delay", "the delay field")
		helpers.assert_eq(log.overrides[1].value, 1.5,
			"the page sends milliseconds (script.js sends `ms: v` from a parseInt) and the "
				.. "cascade stores seconds")
	end)

	helpers.it("applies a section delay to that section", function()
		local log = send({ action = "set_delay", category = "rolls", section = "hc", ms = 200 })
		helpers.assert_eq(log.overrides[1].section, "hc", "named, so the wrong rung cannot be written")
		helpers.assert_eq(log.overrides[1].value, 0.2, "converted the same way at every rung")
	end)

	helpers.it("coerces the delay to a number", function()
		local log = send({ action = "set_delay", category = "rolls", section = "", ms = "2500" })
		helpers.assert_eq(log.overrides[1].value, 2.5,
			"the window sends what a text field holds; a string here would be stored "
				.. "and then compared against numbers for the rest of the session")
	end)

	helpers.it("refuses a payload carrying the old `value` field instead of writing nil", function()
		-- The exact shape of the bug. Reading `payload.value` made tonumber(nil)
		-- nil, and nil is how this bridge spells "clear it" — so typing 500 into a
		-- delay field DELETED that category's delay, and the window showed no error
		-- because the bridge answers with a refreshed payload either way. Refusing
		-- is the only safe answer to a message whose value cannot be read.
		local log = send({ action = "set_delay", category = "rolls", section = "", value = 1.5 })
		helpers.assert_eq(#log.overrides, 0,
			"a set_delay whose delay cannot be read must write nothing at all — writing "
				.. "nil silently clears the setting the user was trying to change")
	end)

	helpers.it("refuses a negative delay", function()
		local log = send({ action = "set_delay", category = "rolls", section = "", ms = -1 })
		helpers.assert_eq(#log.overrides, 0, "a delay before the keystroke is not a setting")
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
		-- `hex`, which is what script.js sends (`send({ …, hex })`).
		helpers.assert_eq(send({ action = "set_color", category = "rolls", section = "", hex = "#ff0000" })
			.overrides[1].value, "#ff0000", "the colour the user picked")
		helpers.assert_eq(send({ action = "clear_color", category = "rolls", section = "" })
			.overrides[1].value, nil, "and clearing returns it to the cascade")
	end)

	helpers.it("refuses a colour payload with no readable hex", function()
		helpers.assert_eq(#send({ action = "set_color", category = "rolls", section = "", value = "#ff0000" }).overrides, 0,
			"reading the wrong field made every colour pick CLEAR the colour instead")
		helpers.assert_eq(#send({ action = "set_color", category = "rolls", section = "", hex = "" }).overrides, 0,
			"an empty select is the page's 'no choice', not a colour to pin")
	end)

	helpers.it("stores show_tooltip as a real boolean", function()
		local log = send({ action = "set_tooltip", category = "rolls", section = "", show_tooltip = false })
		helpers.assert_eq(log.overrides[1].field, "show_tooltip", "the right field")
		helpers.assert_eq(log.overrides[1].value, false, "and a boolean false, not nil")
	end)

	helpers.it("turns the preview ON when the user ticks the box", function()
		-- The sharpest form of the wrong-field bug: `payload.value` was nil, and
		-- `nil and true or false` is false, so ticking "show the preview" wrote
		-- show_tooltip = false and switched it off.
		local log = send({ action = "set_tooltip", category = "rolls", section = "", show_tooltip = true })
		helpers.assert_eq(log.overrides[1].value, true,
			"a ticked box must not be stored as false")
	end)

	helpers.it("does not read the string \"false\" as true", function()
		-- A JSON boolean arrives as a boolean, but a bridge that has ever seen a
		-- string here must not treat it as truthy: that turns the preview ON for a
		-- user who just turned it off.
		local log = send({ action = "set_tooltip", category = "rolls", section = "", show_tooltip = "false" })
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

	helpers.it("clears every override", function()
		local log = send({ action = "reset_all" })
		helpers.assert_true(#log.cleared >= 1,
			"the delays and colours go back to the cascade; a reset that left the "
				.. "overrides behind would look like it did nothing to the values the "
				.. "user can see")
	end)

	helpers.it("leaves the categories the user switched off switched off", function()
		-- This assertion used to be its exact opposite — `assert_eq(log.resets, 1,
		-- "the enable state goes back to shipped")` — so the wrong behaviour was
		-- pinned in place by the test meant to protect it. The button is about
		-- delays and colours. A user clearing a colour experiment must not have
		-- every pack they had disabled switched back on, silently, with thousands
		-- of expansions resuming.
		local log = send({ action = "reset_all" })
		helpers.assert_eq(log.resets, 0,
			"reset_all must not touch enablement — neither reference driver does, and on "
				.. "this driver reset_defaults() is enable_all()")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ Degrading ============================================
-- =================================================================
-- =================================================================

helpers.describe("config window: with no config module", function()

	helpers.it("still answers the window with a usable payload", function()
		-- Called directly, not through pcall: a raise here IS the failure, and
		-- wrapping it would turn the assertion into "pcall reported something",
		-- which is true of every possible implementation. What is asserted is the
		-- REPLY — the window redraws from it, so an override attempted before the
		-- config manager exists must still come back with a shape the page can
		-- render rather than nil.
		local handler = helpers.load_module("ui.hotstrings_config_window.bridge")

		local reply = handler.on_message({ action = "set_delay", category = "rolls", value = 1 }, {})
		helpers.assert_eq(type(reply), "table",
			"the window redraws from the reply; nil blanks the page")
		helpers.assert_eq(type(reply.groups), "table",
			"and it iterates groups, so the key must exist even when there are none")
		helpers.assert_eq(reply.mapping_count, 0,
			"with no config module there are no mappings, and the count must say so "
				.. "rather than be absent")

		local after_tooltip = handler.on_message(
			{ action = "set_tooltip", category = "rolls", value = true }, {})
		helpers.assert_eq(type(after_tooltip), "table", "the same for every override action")

		local after_reset = handler.on_message({ action = "reset_all" }, {})
		helpers.assert_eq(type(after_reset), "table", "and for reset")
	end)

end)
