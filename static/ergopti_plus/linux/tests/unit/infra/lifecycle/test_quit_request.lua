--- tests/unit/infra/lifecycle/test_quit_request.lua

--- ==============================================================================
--- MODULE: Tray Quit Request (Linux)
--- DESCRIPTION:
--- Replays the shared quit admission contract and proves the Linux daemon gives
--- Quit the macOS behaviour (quit-admission, 2026-10-26): Quit wins over a reload
--- in flight by cancelling it, waits for a running scope write or hotstring
--- publication up to the user-quit deadline, and is refused only when an exit
--- already owns the process. A refusal applies no pause layout and starts no
--- shutdown.
--- ==============================================================================

local helpers = require("tests.helpers")
local QuitRequest = require("infra.quit_request")

require("test.quit_admission_contract")(helpers)

--- Builds a handler over recording ports.
--- @param state table Mutable facts: requested, reload, writer, publication, abandon_fails.
--- @return function on_quit, table calls
local function build(state)
	local calls = { layout = 0, requests = {}, abandons = 0, timers = {}, notices = {}, clock = 0, order = {} }
	local on_quit = QuitRequest.new({
		shutdown = {
			is_requested = function() return state.requested == true end,
			request = function(reason)
				if state.requested then return false end
				state.requested = true
				calls.requests[#calls.requests + 1] = reason
				calls.order[#calls.order + 1] = "shutdown"
				return true
			end,
		},
		reload_in_flight = function() return state.reload == true end,
		abandon_reload = function()
			calls.abandons = calls.abandons + 1
			if state.abandon_throws then error("controlled restart cancellation failure") end
			if state.abandon_fails then return false, "systemctl refused" end
			state.reload = false
			return true
		end,
		writer_active = function() return state.writer == true end,
		publication_pending = function() return state.publication == true end,
		report_update_quit = function(reason)
			assert(type(reason) == "string" and reason ~= "", "the watcher report names its source")
			calls.order[#calls.order + 1] = "update watcher"
			if state.report_throws then error("controlled watcher report failure") end
		end,
		apply_pause_layout = function() calls.layout = calls.layout + 1; if state.layout_throws then error("controlled layout failure") end end,
		schedule = function(_, callback) calls.timers[#calls.timers + 1] = callback; return true end,
		now = function() return calls.clock end,
		timeout = 10, poll = 1,
		notify_refused = function(decision) calls.notices[#calls.notices + 1] = decision.cause end,
	})
	return on_quit, calls
end

helpers.describe("Linux tray Quit follows the shared admission (quit-admission)", function()
	for _, fault in ipairs({ "layout_throws", "abandon_throws", "report_throws" }) do
		helpers.it("linux-quit-port-exception: quit proceeds after " .. fault, function()
			local state = { reload = fault == "abandon_throws" }
			state[fault] = true
			local on_quit, calls = build(state)
			local called, accepted = pcall(on_quit)
			helpers.assert_true(called, "a failed optional action cannot escape the quit owner")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(calls.requests, { "tray quit" })
		end)
	end
	helpers.it("(lcy-003-shortcut-quit) a shortcut Quit takes the same owner as the tray row", function()
		local on_quit, calls = build({ reload = true })
		helpers.assert_eq(on_quit("gesture or shortcut quit"), true)
		helpers.assert_eq(calls.abandons, 1, "a shortcut Quit cancels the reload in flight")
		helpers.assert_eq(calls.requests, { "gesture or shortcut quit" })
		helpers.assert_eq(calls.order, { "update watcher", "shutdown" },
			"a shortcut Quit tells the update watcher before the shutdown")
		helpers.assert_true(not pcall(build({}), ""), "a user Quit names its source")
	end)

	helpers.it("(lcy-003-shortcut-quit) Main routes the shortcut and gesture Quit through that owner", function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		helpers.assert_true(
			source:find("quit = function(reason) return privacy_owners.tray_quit(reason) end", 1, true) ~= nil,
			"the script_quit port must reach the user Quit owner")
		helpers.assert_true(source:find('report_quit("the tray Quit")', 1, true) == nil,
			"the watcher report names the Quit source it was given")
		local degraded = source:match('tray_menu%.setFallbackMenu%((.-)\n\t\t\t\tend%)')
		helpers.assert_true(degraded ~= nil, "the degraded tray Quit is found")
		local owner = degraded:find('pcall(privacy_owners.tray_quit, "degraded tray quit")', 1, true)
		local safety = degraded:find('shutdown.request("degraded tray quit")', 1, true)
		helpers.assert_true(owner ~= nil and safety ~= nil and owner < safety,
			"the degraded tray Quit takes the user Quit owner and ends the daemon only when that owner raises")
	end)

	helpers.it("admits a quit, applies the pause layout, then starts the shutdown", function()
		local on_quit, calls = build({})
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(calls.layout, 1)
		helpers.assert_eq(calls.requests, { "tray quit" })
		helpers.assert_eq(calls.abandons, 0)
	end)

	helpers.it("(update-quit-kept) tells a waiting update watcher before the shutdown, never on a refusal", function()
		-- The watcher's wait is this daemon's startup: without the report it
		-- restored the previous installation and started the previous daemon.
		local on_quit, calls = build({})
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(calls.order, { "update watcher", "shutdown" })
		local refused, refused_calls = build({ requested = true })
		helpers.assert_eq(refused(), false)
		helpers.assert_eq(refused_calls.order, {}, "a refused Quit leaves the watcher alone")
	end)

	helpers.it("refuses a second click once an exit owns the process, without any effect", function()
		local on_quit, calls = build({ requested = true })
		helpers.assert_eq(on_quit(), false)
		helpers.assert_eq(calls.layout, 0)
		helpers.assert_eq(calls.requests, {})
		helpers.assert_eq(#calls.timers, 0, "an exit under way is not waited for")
	end)

	helpers.it("lets Quit win over a systemd reload: it cancels the restart then exits (quit-wins-over-reload)", function()
		local state = { reload = true }
		local on_quit, calls = build(state)
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(calls.abandons, 1, "the pending restart is cancelled")
		helpers.assert_eq(calls.layout, 1)
		helpers.assert_eq(calls.requests, { "tray quit" })
	end)

	helpers.it("lets Quit win over a relay reload whose shutdown already started", function()
		local state = { reload = true, requested = true }
		local on_quit, calls = build(state)
		helpers.assert_eq(on_quit(), true, "the exit under way is the quit")
		helpers.assert_eq(calls.abandons, 1, "the relay is told not to start the launcher")
		helpers.assert_eq(calls.requests, {}, "no second shutdown is requested")
	end)

	helpers.it("still quits when the pending restart cannot be cancelled", function()
		local on_quit, calls = build({ reload = true, abandon_fails = true })
		helpers.assert_eq(on_quit(), true)
		helpers.assert_eq(calls.requests, { "tray quit" })
	end)

	helpers.it("waits for a running write, then quits once, without a notice (quit-waits-for-writer)", function()
		for _, field in ipairs({ "writer", "publication" }) do
			local state = { [field] = true }
			local on_quit, calls = build(state)
			helpers.assert_eq(on_quit(), true, field .. ": the click is accepted as waiting")
			helpers.assert_eq(calls.requests, {}, field .. ": the write is not cut")
			helpers.assert_eq(calls.layout, 0)
			calls.clock = 1
			table.remove(calls.timers, 1)()
			helpers.assert_eq(calls.requests, {}, field .. ": still running")
			state[field] = false
			calls.clock = 2
			table.remove(calls.timers, 1)()
			helpers.assert_eq(calls.requests, { "tray quit" }, field .. ": quits once it settled")
			helpers.assert_eq(calls.notices, {})
		end
	end)

	helpers.it("tells the user when the write outlasts the quit deadline", function()
		local on_quit, calls = build({ writer = true })
		helpers.assert_eq(on_quit(), true)
		calls.clock = 11
		table.remove(calls.timers, 1)()
		helpers.assert_eq(calls.requests, {})
		helpers.assert_eq(calls.notices, { "writer_active" })
	end)

	helpers.it("rejects missing ports instead of reading them as idle", function()
		local ok, err = pcall(QuitRequest.new, {})
		helpers.assert_true(not ok and tostring(err):find("shutdown owner", 1, true) ~= nil, tostring(err))
		ok, err = pcall(QuitRequest.new, { shutdown = { is_requested = function() end,
			request = function() end } })
		helpers.assert_true(not ok and tostring(err):find("reload_in_flight", 1, true) ~= nil, tostring(err))
	end)
end)
