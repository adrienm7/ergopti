--- tests/unit/modules/shortcuts/test_clipboard_and_timer_lifecycles.lua

--- ==============================================================================
--- MODULE: Regression — two lifecycles that outlived what owned them
--- DESCRIPTION:
--- 1. wrap_selection had no in-flight guard, unlike _transform_in_flight twenty
---    lines above it in the same file. A second wrap fired while the first still
---    held the clipboard snapshotted the text the FIRST had just written, then
---    "restored" it 250 ms later — replacing the user's real clipboard with a
---    wrapped fragment of their own selection, permanently.
--- 2. The keep-awake cursor-return timer was never cancelled, so switching the
---    feature off still teleported the pointer back up to its full delay later:
---    a cursor moving by itself once nothing is supposed to be moving it.
---
--- ROOT CAUSE ENCODED:
--- The wrap assertions drive the real transaction through a faithful timer and
--- all-type pasteboard double, so moving the latch release ahead of restoration
--- makes the second call snapshot owned data and fails behaviorally. The cursor
--- owner remains a source guard because it requires live mouse hardware.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Clones an all-type clipboard snapshot.
--- @param value any Source value.
--- @return any copy
local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = clone(child) end
	return out
end


--- Loads the real wrap transaction with mutation-sensitive native doubles.
--- @param restore_outcomes table|nil Ordered writeAllData outcomes.
--- @return table fixture
local function load_wrap_fixture(restore_outcomes)
	local saved = {
		hs_global = _G.hs,
		hs_module = package.loaded["hs"],
		logger = package.loaded["infra.logger"],
		synthetic = package.loaded["adapters.synthetic_input"],
		timer_scheduler = package.loaded["adapters.timer_scheduler"],
		text = package.loaded["modules.shortcuts.actions.text"],
	}
	local original = {
		["public.utf8-plain-text"] = "ORIGINAL",
		["public.html"] = "<b>ORIGINAL</b>",
	}
	local clipboard = clone(original)
	local timers = {}
	local snapshots = 0
	local restore_calls = 0

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function(_mods, key)
			helpers.assert_eq(key, "v", "wrap_selection may emit only Cmd+V")
			return true
		end,
		emit_key_strokes = function() return true end,
		defer_after_callback = function() return true end,
	}

	local pasteboard = {
		readAllData = function()
			snapshots = snapshots + 1
			return clone(clipboard)
		end,
		setContents = function(value)
			clipboard = { ["public.utf8-plain-text"] = value }
			return true
		end,
		writeAllData = function(snapshot)
			restore_calls = restore_calls + 1
			local outcome = (restore_outcomes or {})[restore_calls] or "success"
			if outcome == "false" then return false end
			clipboard = clone(snapshot)
			return true
		end,
		clearContents = function()
			clipboard = {}
			return nil
		end,
		getContents = function() return clipboard["public.utf8-plain-text"] end,
	}
	local timer = {
		new = function(_delay, callback)
			local handle = { running_state = false, callback = callback }
			function handle:start()
				self.running_state = true
				return self
			end
			function handle:stop()
				self.running_state = false
				return self
			end
			function handle:running() return self.running_state end
			timers[#timers + 1] = handle
			return handle
		end,
	}

	package.loaded["adapters.timer_scheduler"] = nil
	local text = helpers.load_with_stubs("modules.shortcuts.actions.text", {
		pasteboard = pasteboard,
		timer = timer,
	})
	return {
		text = text,
		original = original,
		timers = timers,
		clipboard = function() return clone(clipboard) end,
		snapshots = function() return snapshots end,
		wrap = function() return text.wrap_selection("selected", "(", ")") end,
		fire = function(handle) handle.callback() end,
		restore = function()
			package.loaded["modules.shortcuts.actions.text"] = saved.text
			package.loaded["infra.logger"] = saved.logger
			package.loaded["adapters.synthetic_input"] = saved.synthetic
			package.loaded["adapters.timer_scheduler"] = saved.timer_scheduler
			package.loaded["hs"] = saved.hs_module
			_G.hs = saved.hs_global
		end,
	}
end


--- Runs one wrap fixture without leaking its captured Hammerspoon singleton.
--- @param outcomes table|nil Restore outcomes.
--- @param callback function Test body.
local function with_wrap_fixture(outcomes, callback)
	local fixture = load_wrap_fixture(outcomes)
	local ok, err = xpcall(function() callback(fixture) end, debug.traceback)
	fixture.restore()
	if not ok then error(err, 0) end
end


helpers.describe("shortcuts: the clipboard wrap serialises like its sibling", function()

	helpers.it("wrap_selection refuses re-entry while a wrap is outstanding", function()
		with_wrap_fixture(nil, function(f)
			helpers.assert_eq(f.wrap(), true)
			helpers.assert_eq(f.snapshots(), 1)
			helpers.assert_eq(f.wrap(), false)
			helpers.assert_eq(f.snapshots(), 1,
				"re-entry must not snapshot the wrapped payload owned by the first action")
			f.fire(f.timers[1])
			helpers.assert_eq(f.clipboard(), f.original)
			helpers.assert_eq(f.wrap(), true)
			helpers.assert_eq(f.snapshots(), 2,
				"exact restoration must reopen admission for a fresh snapshot")
			f.fire(f.timers[2])
		end)
	end)

	helpers.it("and releases the guard only after the restore", function()
		with_wrap_fixture({ "false", "success" }, function(f)
			helpers.assert_eq(f.wrap(), true)
			f.fire(f.timers[1])
			helpers.assert_eq(f.wrap(), false,
				"a refused exact restore must retain the wrap latch")
			helpers.assert_eq(f.snapshots(), 1)
			helpers.assert_true(not helpers.deep_equal(f.clipboard(), f.original),
				"the mutation control must still expose owned clipboard data")
			helpers.assert_eq(#f.timers, 2,
				"restore refusal must retain an autonomous retry")
			f.fire(f.timers[2])
			helpers.assert_eq(f.clipboard(), f.original)
			helpers.assert_eq(f.wrap(), true)
			helpers.assert_eq(f.snapshots(), 2,
				"the latch may reopen only after exact restoration succeeds")
			f.fire(f.timers[3])
		end)
	end)

end)

helpers.describe("shortcuts: keep-awake cancels its pending cursor return", function()

	helpers.it("toggle_awake stops the return timer, not only the tick timer", function()
		local src = helpers.read_driver_source("toggle_awake")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the system actions source must be readable or this asserts nothing")
		local at = src:find("function M.toggle_awake", 1, true)
		helpers.assert_not_nil(at, "toggle_awake must exist")
		local body = src:sub(at, at + 1400)
		helpers.assert_true(body:find("_awake_return_timer", 1, true) ~= nil,
			"stopping only the tick timer leaves a scheduled cursor teleport firing after the "
			.. "user switched the feature off")
	end)

end)
