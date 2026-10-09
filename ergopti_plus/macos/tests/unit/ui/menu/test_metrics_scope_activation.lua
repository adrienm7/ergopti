--- tests/unit/ui/menu/test_metrics_scope_activation.lua

local helpers = require("tests.helpers")

local function fixture(synchronous, accepted)
	local saved = package.loaded["infra.deferred_work"]
	local callback, starts = nil, 0
	package.loaded["infra.deferred_work"] = { after = function(_, fn, label)
		if label == "menu_state.keylogger_start" then
			callback = fn
			if synchronous then fn() end
			return accepted
		end
		return true
	end }
	local MenuState = helpers.load_with_stubs("ui.menu.menu_state")
	local core = { start = function() starts = starts + 1; return true end, stop = function() return true end }
	local function sync(enabled)
		return MenuState.sync_state_to_modules({ keylogger_enabled = enabled, hotstrings = {} }, {}, false,
			{ core_mods = { keylogger = core }, hotstring_editor = {}, save_prefs = function() return true end })
	end
	sync(true)
	package.loaded["infra.deferred_work"] = saved
	return MenuState, function() callback() end, function() return starts end, sync
end

helpers.describe("Metrics scope deferred activation admission", function()
	helpers.it("keeps activation pending until the actual keylogger start returns", function()
		local owner, dispatch, starts = fixture(false, true)
		helpers.assert_eq(owner.metrics_start_pending(), true)
		helpers.assert_eq(starts(), 0)
		dispatch()
		helpers.assert_eq(owner.metrics_start_pending(), false)
		helpers.assert_eq(starts(), 1)
	end)
	helpers.it("a refused scheduler cannot activate through a captured or synchronous callback", function()
		for _, synchronous in ipairs({ false, true }) do
			local owner, dispatch, starts = fixture(synchronous, false)
			helpers.assert_eq(owner.metrics_start_pending(), false)
			dispatch()
			helpers.assert_eq(starts(), 0)
		end
	end)
	helpers.it("an explicit OFF supersedes the older queued boot start", function()
		local owner, dispatch, starts, sync = fixture(false, true)
		sync(false)
		dispatch()
		helpers.assert_eq(starts(), 0)
		helpers.assert_eq(owner.metrics_start_pending(), false)
	end)
end)
