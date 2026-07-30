--- tests/unit/ui/test_tooltip_visibility_and_menu_dirty.lua

--- ==============================================================================
--- MODULE: Regression — two states that claimed something the UI had not done
--- DESCRIPTION:
--- 1. TooltipHotstring set _state.is_visible = true BEFORE rendering. A render
---    that threw left no canvas on screen while tooltip.is_visible() went on
---    reporting true — and the persistent Escape trap consults exactly that to
---    decide whether to swallow Escape, so the user's next Escape vanished into
---    a tooltip that did not exist.
--- 2. Changing the log level from the Debug submenu never marked the menubar
---    cache dirty, so the static NSMenu kept showing the previous level and its
---    checkmark indefinitely — the menu asserting a setting the engine no longer
---    had.
---
--- ROOT CAUSE ENCODED:
--- Both are a claim recorded before, or without, the action that justifies it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("tooltip: a failed render does not leave the tooltip 'visible'", function()

	helpers.it("rolls the visibility claim back when render_stacked throws", function()
		local src = helpers.read_driver_source("Crash during stacked tooltip rendering")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the tooltip source must be readable or this asserts nothing")
		-- Two files carry this phrase and the concatenated blob orders them
		-- arbitrarily, so a single find() lands in whichever came first — which is
		-- how an earlier version of this assertion passed against the unfixed code.
		-- Every occurrence's own block is checked, and at least one must withdraw
		-- the claim.
		local found_rollback = false
		local pos = 1
		while true do
			local at = src:find("Crash during stacked tooltip rendering", pos, true)
			if not at then break end
			local block_end = src:find("\n\tend\n", at, true) or (at + 600)
			if src:sub(at, block_end):find("is_visible = false", 1, true) then
				found_rollback = true
				break
			end
			pos = at + 1
		end
		helpers.assert_true(found_rollback,
			"is_visible is set optimistically before the render; if the render throws the "
			.. "claim must be withdrawn INSIDE that failure branch, or the Escape trap "
			.. "swallows Escape for a tooltip that is not on screen")
	end)

end)

helpers.describe("menu: changing the log level refreshes the cached menubar", function()

	helpers.it("marks the menu dirty", function()
		local src = helpers.read_driver_source("Log level set to")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the menu source must be readable or this asserts nothing")
		-- Anchored on the handler's own log line: "set_log_level" alone matches the
		-- menu manifest and the logger's own set_level far earlier in the blob.
		local at = src:find("Log level set to", 1, true)
		helpers.assert_not_nil(at, "the log-level handler must exist")
		local body = src:sub(at, at + 600)
		helpers.assert_true(body:find("_menu_dirty", 1, true) ~= nil,
			"the menubar tree is cached and rebuilt only when _menu_dirty is set; without it "
			.. "the Debug submenu keeps showing the previous level and its checkmark")
	end)

end)
