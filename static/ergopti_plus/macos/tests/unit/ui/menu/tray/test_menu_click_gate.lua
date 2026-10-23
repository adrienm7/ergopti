--- tests/unit/ui/menu/tray/test_menu_click_gate.lua

--- ==============================================================================
--- MODULE: Menubar Click Gate Contract
--- DESCRIPTION:
--- Drives ui.menu.click_gate over in-memory ports: a reload that never
--- replaces the driver runs held clicks in place, one that stays pending past
--- the bounded wait reports them lost, a quit drops them with a log line, and
--- the successor rejects a malformed, expired or second hand-off.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local KEY = "menu_reload_replay"

--- Builds a gate over controllable ports and one check row.
--- @return table fixture
local function fixture()
	local logs = { info = {}, warn = {}, error = {} }
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "info", "warn", "error" }) do
		logger[level] = function(_, fmt, ...) logs[level][#logs[level] + 1] = string.format(fmt, ...) end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["ui.menu.click_gate"] = nil
	local ClickGate = require("ui.menu.click_gate")
	local f = { logs = logs, store = {}, timers = {}, clock = 1000, terminal = false,
		reloading = false, stale = false, on = false, runs = 0, lost = 0 }
	function f.tree()
		local shown = f.on
		return f.gate.wrap({ { title = "Features", menu = { { title = "Preview", checked = shown, fn = function()
			f.runs = f.runs + 1
			f.on = not f.on
		end } } } })
	end
	f.gate = ClickGate.new({
		terminal_pending = function() return f.terminal end,
		is_reloading = function() return f.reloading end,
		stale = function() return f.stale end,
		refresh = function() f.items = f.tree(); f.stale = false; return f.items end,
		current_items = function() return f.items end,
		store = {
			get = function(key, default) local value = f.store[key]; if value == nil then return default end; return value end,
			set = function(key, value) f.store[key] = value; return true end,
			delete = function(key) f.store[key] = nil; return true end,
		},
		schedule = function(_, callback) f.timers[#f.timers + 1] = callback; return true end,
		notify_lost = function() f.lost = f.lost + 1; return true end,
		now = function() return f.clock end,
	})
	f.items = f.tree()
	--- Fires the timers armed so far, in order.
	function f.tick(seconds)
		f.clock = f.clock + (seconds or 0)
		local due = f.timers
		f.timers = {}
		for _, callback in ipairs(due) do callback() end
	end
	return f
end

local function click(f) return f.items[1].menu[1].fn({}, {}) end

helpers.describe("menubar click gate", function()
	helpers.it("(menu-click-reload-aborted) runs a held click in place once the reload goes away", function()
		local f = fixture()
		f.terminal = true; click(f)
		helpers.assert_eq(f.runs, 0)
		f.tick(0.25); helpers.assert_eq(f.runs, 0, "still pending: still held")
		f.terminal = false; f.tick(0.25)
		helpers.assert_eq(f.runs, 1, "a reload that never replaced the driver must not lose the click")
		f.tick(1); helpers.assert_eq(f.runs, 1, "a held click runs once")
	end)

	helpers.it("(menu-click-reload-bounded) reports held clicks lost when the reload never settles", function()
		local f = fixture()
		f.terminal = true; click(f)
		for _ = 1, 200 do f.tick(0.25) end
		helpers.assert_eq(f.runs, 0); helpers.assert_eq(f.lost, 1)
		helpers.assert_eq(#f.timers, 0, "the wait is bounded")
	end)

	helpers.it("(menu-click-quit-drop) logs held clicks dropped when the driver quits", function()
		local f = fixture()
		f.terminal = true; click(f)
		helpers.assert_true(f.gate.handoff())
		helpers.assert_eq(f.store[KEY], nil, "a quit hands nothing to a later launch")
		helpers.assert_true(f.logs.warn[1]:find("Features > Preview", 1, true) ~= nil, tostring(f.logs.warn[1]))
	end)

	helpers.it("(menu-click-after-handoff) hands over a click made after the teardown step", function()
		local f = fixture()
		f.terminal = true; f.reloading = true
		click(f); helpers.assert_true(f.gate.handoff())
		click(f)
		local record = json.decode(f.store[KEY])
		helpers.assert_eq(#record.clicks, 2, "the logger drain still accepts clicks; they are handed over too")
	end)

	helpers.it("(menu-click-handoff-once) consumes the hand-off once and refuses a second inherit", function()
		local f = fixture()
		f.store[KEY] = json.encode({ schema = 1, at = f.clock, clicks = { { path = { "Features", "Preview" }, desired = true } } })
		helpers.assert_eq(f.gate.inherit(), 1)
		helpers.assert_eq(f.store[KEY], nil)
		helpers.assert_eq(f.gate.inherit(), 0)
		f.gate.replay_inherited(); f.gate.replay_inherited()
		helpers.assert_eq(f.runs, 1)
	end)

	for _, case in ipairs({
		{ name = "expired", record = function(f) return json.encode({ schema = 1, at = f.clock - 61,
			clicks = { { path = { "Features", "Preview" } } } }) end },
		{ name = "malformed", record = function() return "{not json" end },
		{ name = "wrong schema", record = function(f) return json.encode({ schema = 2, at = f.clock, clicks = {} }) end },
		{ name = "bad path", record = function(f) return json.encode({ schema = 1, at = f.clock,
			clicks = { { path = { 3 } } } }) end },
	}) do
		local current = case
		helpers.it("(menu-click-handoff-rejected) rejects the " .. current.name .. " hand-off", function()
			local f = fixture()
			f.store[KEY] = current.record(f)
			helpers.assert_eq(f.gate.inherit(), 0)
			helpers.assert_eq(f.store[KEY], nil, "a rejected record is not read again")
			f.gate.replay_inherited()
			helpers.assert_eq(f.runs, 0)
			helpers.assert_true(#f.logs.warn >= 1, "the rejection is logged")
		end)
	end

	helpers.it("(menu-click-lost-row) reports a replayed click whose row is gone", function()
		local f = fixture()
		f.store[KEY] = json.encode({ schema = 1, at = f.clock, clicks = { { path = { "Features", "Gone" } } } })
		f.gate.inherit(); f.gate.replay_inherited()
		helpers.assert_eq(f.runs, 0); helpers.assert_eq(f.lost, 1)
	end)

	helpers.it("(menu-click-plain) runs an ordinary click at once", function()
		local f = fixture()
		click(f); helpers.assert_eq(f.runs, 1); helpers.assert_eq(#f.timers, 0)
	end)

	helpers.it("(menu-click-wrap-once) keeps the gate of a reused subtree", function()
		local f = fixture()
		local items = f.items
		local guarded = items[1].menu[1].fn
		f.gate.wrap(items)
		helpers.assert_true(items[1].menu[1].fn == guarded, "a cached subtree is not wrapped twice")
	end)

	helpers.it("(menu-click-reload-joins) a Reload click during a reload joins it instead of replaying a second reload", function()
		local f = fixture()
		local reloads = 0
		local tree = f.gate.wrap({ { title = "Reload", joins_reload = true, fn = function() reloads = reloads + 1 end } })
		f.terminal = true; f.reloading = true
		tree[1].fn()
		helpers.assert_eq(reloads, 0, "the reload in flight is not run again")
		helpers.assert_eq(#f.timers, 0, "nothing is held")
		helpers.assert_true(f.gate.handoff())
		helpers.assert_eq(f.store[KEY], nil, "nothing is handed to the successor")
		f.terminal = false; f.reloading = false
		tree[1].fn()
		helpers.assert_eq(reloads, 1, "with no reload in flight the row reloads")
	end)
end)
