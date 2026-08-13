--- tests/unit/modules/keymap/test_emit_tokens_timer_retention.lua

--- ==============================================================================
--- MODULE: Deferred Synthetic Token Timer Retention
--- DESCRIPTION:
--- Proves that an ignored emit_tokens() scheduling handle remains strongly owned
--- until its callback runs. Hammerspoon stops a timer userdata when Lua collects
--- it; a test stub that globally retains callbacks cannot expose this failure.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture()
	for _, name in ipairs({
		"modules.keymap.utils", "adapters.timer_scheduler", "adapters.synthetic_input",
		"infra.logger", "infra.timings", "infra.text_utils",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local pending = {}
	hs_stub.timer.new = function(delay, callback)
		local entry = {
			delay = delay,
			callback = callback,
			stopped = false,
			fired = false,
			active = false,
		}
		pending[#pending + 1] = entry
		local handle = {}
		function handle:start() entry.active = true; return self end
		function handle:stop() entry.active = false; entry.stopped = true; return self end
		function handle:running() return entry.active end
		setmetatable(handle, { __gc = function(self) self:stop() end })
		return handle
	end

	local tx = {}
	local retain_count = 0
	local release_count = 0
	package.loaded["adapters.synthetic_input"] = {
		current_transaction = function() return tx end,
		retain = function()
			retain_count = retain_count + 1
			return {}
		end,
		release = function()
			release_count = release_count + 1
			return true
		end,
		with_transaction = function(_, callback) return callback() end,
		emit_key_stroke = function() return true end,
		emit_key_strokes = function() return true end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.timings"] = {
		sec = function(_section, key)
			if key == "clipboard_paste_settle_ms" then return 0.05 end
			return 0.15
		end,
	}

	local pasted = {}
	hs_stub.pasteboard.readAllData = function() return { original = "snapshot" } end
	hs_stub.pasteboard.writeAllData = function() return true end
	hs_stub.pasteboard.setContents = function(value)
		if value ~= "" then pasted[#pasted + 1] = value end
		return true
	end

	local function fire_all()
		for _ = 1, 20 do
			local next_entry = nil
			for _, entry in ipairs(pending) do
				if entry.active and not entry.stopped and not entry.fired
					and (next_entry == nil or entry.delay < next_entry.delay) then
					next_entry = entry
				end
			end
			if next_entry == nil then break end
			next_entry.fired = true
			next_entry.callback()
		end
	end

	return {
		utils = require("modules.keymap.utils"),
		pasted = pasted,
		fire_all = fire_all,
		retain_count = function() return retain_count end,
		release_count = function() return release_count end,
	}
end


helpers.describe("emit_tokens deferred timer lifetime", function()
	helpers.it("survives GC after the caller discards the scheduling handle", function()
		local fixture = load_fixture()
		fixture.utils.emit_tokens({
			{ kind = "text", value = ("A"):rep(60) },
			{ kind = "text", value = ("B"):rep(60) },
		})
		helpers.assert_eq(fixture.retain_count(), 1)
		collectgarbage("collect")
		collectgarbage("collect")
		fixture.fire_all()

		helpers.assert_eq(#fixture.pasted, 2,
			"GC must not cancel the deferred half of one logical replacement")
		helpers.assert_eq(fixture.pasted[2], ("B"):rep(60))
		helpers.assert_eq(fixture.release_count(), 1,
			"the transaction retain must close after deferred output runs")
	end)
end)
