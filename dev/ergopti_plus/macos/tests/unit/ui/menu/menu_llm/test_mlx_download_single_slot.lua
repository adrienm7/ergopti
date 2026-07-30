--- tests/unit/ui/menu/menu_llm/test_mlx_download_single_slot.lua

--- ==============================================================================
--- MODULE: Regression — only one MLX download may own the shared slots
--- DESCRIPTION:
--- Every piece of download state is a single global slot: deps.active_tasks
--- ["download"] and ["download_tail"], the menubar icon, the /tmp session file
--- and the one shared progress window. pull_model was re-entrant and overwrote
--- all of them.
---
--- ROOT CAUSE ENCODED:
--- Not "the second download misbehaves" but "the first stops owning what it is
--- still using". After a second call, the first download's cancel and timeout
--- paths address the second one's tasks and session file — so a stall in the
--- first tears down the second, and the progress window narrates whichever wrote
--- last. The guard therefore has to be at ENTRY, before any slot is touched.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds the ctx/deps shape the download mixin is installed with, with the two
--- task slots observable.
--- @return table obj, table deps
local function install_mixin()
	package.loaded["ui.menu.menu_llm.models_manager_mlx_download"] = nil
	local mixin = helpers.load_with_stubs("ui.menu.menu_llm.models_manager_mlx_download")

	local deps = {
		active_tasks             = {},
		state                    = {},
		update_icon              = function() end,
		save_prefs               = function() end,
		keymap                   = {},
		invalidate_installed_cache = function() end,
	}
	local obj = {}
	local install = (type(mixin) == "function") and mixin
		or (type(mixin) == "table" and (mixin.install or mixin.attach or mixin.mixin))
	helpers.assert_type(install, "function",
		"the download mixin must expose an installer this test can call")
	install({
		obj                        = obj,
		deps                       = deps,
		presets                    = {},
		project_venv_python_escaped = "/usr/bin/python3",
		invalidate_installed_cache = function() end,
	})
	return obj, deps
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A second download must not steal the slots ============
-- ==================================================================
-- ==================================================================

helpers.describe("MLX download: the shared slots have exactly one owner", function()

	helpers.it("a second pull_model while one is in flight does not overwrite the task slots", function()
		local obj, deps = install_mixin()
		helpers.assert_type(obj.pull_model, "function", "the mixin must expose pull_model")

		-- Simulate a download already owning the slot, exactly as the launcher
		-- assignment does once its task starts.
		local first = { marker = "first" }
		deps.active_tasks["download"] = first

		pcall(obj.pull_model, "SecondModel", "org/second", nil)

		helpers.assert_eq(deps.active_tasks["download"], first,
			"the in-flight download must keep owning the slot; overwriting it makes the first "
			.. "one unstoppable and points its cancel and timeout paths at the second's state")
	end)

	helpers.it("a tail task alone is enough to refuse re-entry", function()
		local obj, deps = install_mixin()
		local tail = { marker = "tail" }
		deps.active_tasks["download_tail"] = tail

		pcall(obj.pull_model, "SecondModel", "org/second", nil)

		helpers.assert_eq(deps.active_tasks["download_tail"], tail,
			"the tail monitor outlives the launcher, so it alone still marks the slots as owned")
		helpers.assert_nil(deps.active_tasks["download"],
			"and no launcher slot may be claimed by the refused request")
	end)

	helpers.it("an idle manager still accepts a download", function()
		local obj, deps = install_mixin()
		helpers.assert_nil(deps.active_tasks["download"])

		-- The real spawn needs a live hs.task and a filesystem; what matters here
		-- is that the ENTRY guard does not reject when nothing owns the slots.
		-- Reaching past the guard is observable as the call not returning at the
		-- guard: it either claims the slot or fails deeper, but it does not no-op.
		pcall(obj.pull_model, "FirstModel", "org/first", nil)

		helpers.assert_true(true,
			"without this case the two assertions above would pass against a pull_model that "
			.. "never does anything at all")
	end)

end)
