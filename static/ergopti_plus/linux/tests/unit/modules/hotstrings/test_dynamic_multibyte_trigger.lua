--- tests/unit/modules/hotstrings/test_dynamic_multibyte_trigger.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings with the Canonical Multibyte Trigger
--- DESCRIPTION:
--- Drives the real Linux manager with the shipped `★` trigger. Lua substring
--- indexes are bytes, so removing or comparing one trailing byte cannot represent
--- this one-codepoint, three-byte trigger.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Runs one body with an observable injector and restores the package cache.
--- @param body function Receives manager, captured injections, and shared engine.
local function with_manager(body)
	local saved_manager = package.loaded["modules.dynamic_hotstrings.manager"]
	local saved_engine = package.loaded["dynamic_hotstrings"]
	local saved_injector = package.loaded["modules.hotstrings.injector"]
	package.loaded["modules.dynamic_hotstrings.manager"] = nil
	package.loaded["dynamic_hotstrings"] = nil

	local injections = {}
	package.loaded["modules.hotstrings.injector"] = {
		inject = function(count, text)
			injections[#injections + 1] = { count = count, text = text }
			return { ok = true }
		end,
	}

	local ok, err = xpcall(function()
		local manager = require("modules.dynamic_hotstrings.manager")
		manager.init({ personal_info_path = "/definitely/missing/personal_info.toml" })
		manager.set_enabled(true)
		body(manager, injections, require("dynamic_hotstrings"))
	end, debug.traceback)

	package.loaded["modules.hotstrings.injector"] = saved_injector
	package.loaded["dynamic_hotstrings"] = saved_engine
	package.loaded["modules.dynamic_hotstrings.manager"] = saved_manager
	if not ok then error(err, 0) end
end


helpers.describe("dynamic hotstrings: multibyte trigger", function()
	helpers.it("fires and previews through the shipped star trigger", function()
		with_manager(function(manager, injections)
			helpers.assert_not_nil(manager.preview("td★"),
				"the tooltip must resolve the same canonical trigger as the fire path")
			local fired, event = manager.on_trigger("td★", "★")
			helpers.assert_true(fired == true,
				"the shipped three-byte trigger must fire as one screen character")
			helpers.assert_eq(#injections, 1)
			helpers.assert_eq(injections[1].count, 3,
				"two suffix codepoints plus one trigger codepoint must be deleted")
			helpers.assert_eq(event.backspace_count, 3)
			helpers.assert_eq(event.trigger, "td★")
		end)
	end)

	helpers.it("rejects an explicitly malformed or multi-codepoint trigger", function()
		local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
		helpers.assert_true(manager.init({
			trigger_char = "ab",
			personal_info_path = "/definitely/missing/personal_info.toml",
		}) == false, "invalid configured triggers must fail closed rather than reuse a prior default")
		helpers.assert_true(manager.is_enabled() == false)
	end)
end)
