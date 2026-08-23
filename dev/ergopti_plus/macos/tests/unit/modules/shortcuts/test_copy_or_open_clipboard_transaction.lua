--- tests/unit/modules/shortcuts/test_copy_or_open_clipboard_transaction.lua

--- ==============================================================================
--- MODULE: copy_or_open_path clipboard transaction
--- DESCRIPTION:
--- The selection-search branch preserves every pasteboard type, retains the
--- first snapshot after writeAllData(false), and never posts Cmd+C unless its
--- capture callback has been armed.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture(options)
	options = options or {}
	for _, name in ipairs({
		"modules.shortcuts.actions.apps", "adapters.window_info",
		"adapters.synthetic_input", "adapters.timer_scheduler", "infra.logger",
	}) do package.loaded[name] = nil end
	local original = {
		["public.utf8-plain-text"] = "ORIGINAL",
		["public.html"] = "<b>ORIGINAL</b>",
	}
	local current = original
	local timers = {}
	local timer_calls = 0
	local restore_calls = 0
	local copies = 0
	local snapshots = 0
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.window_info"] = {
		getFocused = function() return { appId = "TextEdit" } end,
	}
	package.loaded["adapters.synthetic_input"] = setmetatable({
		emit_key_stroke = function()
			copies = copies + 1
			local outcome = options.copy_outcomes and options.copy_outcomes[copies]
			if outcome == "throw" then error("injected copy dispatch failure") end
			if outcome == "false" then return false end
			return true
		end,
	}, { __index = function() return function() return true end end })
	local pasteboard = {
		readAllData = function() snapshots = snapshots + 1; return original end,
		clearContents = function() current = {} end,
		getContents = function() return "selected words" end,
		writeAllData = function(snapshot)
			restore_calls = restore_calls + 1
			local outcome = options.restore_outcomes and options.restore_outcomes[restore_calls]
			if outcome == "false" then return false end
			current = snapshot
			return true
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_delay, callback)
			timer_calls = timer_calls + 1
			local outcome = options.timer_outcomes and options.timer_outcomes[timer_calls]
			if outcome == "nil" then return { timer = nil, committed = false }, false end
			local handle = {
				timer = {},
				committed = true,
				observers = {},
			}
			function handle.callback()
				if handle.timer == nil then return end
				handle.timer = nil
				handle.committed = false
				local observers = handle.observers
				handle.observers = {}
				for _, observer in ipairs(observers) do observer() end
				callback()
			end
			timers[#timers + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			if handle.timer == nil then return true end
			handle.timer = nil
			handle.committed = false
			local observers = handle.observers
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
		onSettled = function(handle, observer)
			if handle.timer == nil then observer()
			else handle.observers[#handle.observers + 1] = observer end
			return true
		end,
	}
	local actions = helpers.load_with_stubs("modules.shortcuts.actions.apps", {
		pasteboard = pasteboard,
		http = { encodeForQuery = function(value) return value end },
		urlevent = { openURL = function() return true end },
	})
	return {
		actions = actions,
		original = original,
		current = function() return current end,
		timers = timers,
		copies = function() return copies end,
		snapshots = function() return snapshots end,
	}
end


helpers.describe("copy_or_open_path: exact retained clipboard ownership", function()
	helpers.it("retries a refused all-type restore", function()
		local f = load_fixture({ restore_outcomes = { "false", "success" } })
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.copies(), 1)
		f.timers[1].callback()
		helpers.assert_eq(#f.timers, 2,
			"writeAllData(false) must retain ownership and arm a retry")
		f.timers[2].callback()
		helpers.assert_true(f.current() == f.original,
			"retry must restore the original all-type snapshot")
	end)

	helpers.it("timer refusal restores before Cmd+C", function()
		local f = load_fixture({ timer_outcomes = { "nil" } })
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.copies(), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("copy dispatch refusal restores and leaves no live capture", function()
		local f = load_fixture({ copy_outcomes = { "false" } })
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.copies(), 1)
		helpers.assert_true(f.current() == f.original)
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.snapshots(), 2,
			"successful rollback must release ownership for a later clean attempt")
	end)

	helpers.it("overlap cannot replace or invalidate the first snapshot", function()
		local f = load_fixture({ restore_outcomes = { "false", "success" } })
		f.actions.copy_or_open_path()
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.snapshots(), 1)
		helpers.assert_eq(f.copies(), 1,
			"an overlapping action must be refused before posting another Cmd+C")
		f.timers[1].callback()
		f.actions.copy_or_open_path()
		helpers.assert_eq(f.snapshots(), 1,
			"restore-pending ownership must reject rather than invalidate its retry generation")
		helpers.assert_eq(f.copies(), 1)
		f.timers[2].callback()
		helpers.assert_true(f.current() == f.original)
	end)
end)
