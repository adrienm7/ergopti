--- tests/unit/adapters/karabiner_coexistence/test_karabiner_coexistence.lua

--- ==============================================================================
--- MODULE: Other Karabiner Detection And Closer
--- DESCRIPTION:
--- Pins adapters/karabiner_coexistence.lua: it detects the official Karabiner's
--- user-side process, asks it to quit only through Karabiner's own helper and in
--- Karabiner's own order, distinguishes a refused quit from a slow exit, and
--- describes a close without performing it.
---
--- ROOT CAUSES ENCODED: (a) detecting by the product name counted the idle root
--- daemon of an installed but unused Karabiner as "running", so owned mode could
--- never start next to it; (b) a closer that killed or signalled a process, or
--- touched launchd, would break rule R3 for every user of the shared runtime;
--- (c) a quit step that failed silently would let the owned runtime fight the
--- official one for the keyboards.
--- ==============================================================================

local helpers = require("tests.helpers")

local HELPER = "/Library/Application Support/org.pqrs/Karabiner-Elements/"
	.. "Karabiner-Elements Non-Privileged Agents v2.app/Contents/MacOS/Karabiner-Elements Non-Privileged Agents v2"

--- Builds the closer over a scripted command runner.
--- @param script function|nil fn(executable, args) -> code, output.
--- @param tweak function|nil Receives the world before the closer is built.
--- @return table port
--- @return table world
local function load_port(script, tweak)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["platform.remap.ke_paths"] = nil
	package.loaded["adapters.karabiner_coexistence"] = nil
	local world = { calls = {}, helper = true, timers = {}, timer_commits = true }
	if tweak then tweak(world) end
	local Closer = require("adapters.karabiner_coexistence")
	world.closer = Closer
	local port = Closer.new({
		exec = function(executable, args, _, callback)
			world.calls[#world.calls + 1] = { executable = executable, args = args }
			callback(script(executable, args, #world.calls))
		end,
		exists = function(path) return path == HELPER and world.helper end,
		timer = {
			after = function(seconds, callback)
				world.timers[#world.timers + 1] = { seconds = seconds, callback = callback }
				return {}, world.timer_commits
			end,
			cancel = function() end,
		},
	})
	--- Fires the oldest armed timer.
	function world.tick() table.remove(world.timers, 1).callback() end
	return port, world
end

--- Captures a callback's single argument.
--- @param register function fn(callback).
--- @return any value
local function answer(register)
	local value = "never called"
	register(function(result) value = result end)
	return value
end

--- Lists the executables and first arguments a run used.
--- @param world table World.
--- @return table rows Each "basename argument" row.
local function used(world)
	local rows = {}
	for _, call in ipairs(world.calls) do
		rows[#rows + 1] = (call.executable:match("[^/]+$")) .. " " .. table.concat(call.args, " ")
	end
	return rows
end





-- =============================
-- =============================
-- ======= 1/ Detection  =======
-- =============================
-- =============================

helpers.describe("other Karabiner: detection", function()
	helpers.it("counts the official user-side processes and distinguishes none from unknown", function()
		local several = load_port(function() return 0, "11\n12\n" end)
		helpers.assert_eq(answer(several.detect), 2)
		local none = load_port(function() return 1, "" end)
		helpers.assert_eq(answer(none.detect), 0)
		local broken = load_port(function() return 2, "" end)
		helpers.assert_eq(answer(broken.detect), nil)
		local timed_out = load_port(function() return nil, "" end)
		helpers.assert_eq(answer(timed_out.detect), nil)
	end)

	helpers.it("looks for the console user server by either of its names, not for the product name", function()
		local port, world = load_port(function() return 1, "" end)
		answer(port.detect)
		helpers.assert_eq(world.calls[1].executable, "/usr/bin/pgrep")
		helpers.assert_eq(world.calls[1].args, { "-f", "karabiner_console_user_server|Karabiner-Console-User-Server" })
		helpers.assert_true(not table.concat(world.calls[1].args, " "):find("Karabiner-Elements", 1, true),
			"the product name also matches an idle root daemon and the app's own paths")
	end)
end)





-- ===========================
-- ===========================
-- ======= 2/ Closing  =======
-- ===========================
-- ===========================

helpers.describe("other Karabiner: the closer", function()
	helpers.it("asks through Karabiner's own helper, in Karabiner's own order, then waits for the exit", function()
		local port, world = load_port(function(executable, args)
			if executable == "/usr/bin/pgrep" then return 1, "" end
			return 0, ""
		end)
		helpers.assert_eq(answer(port.close), true)
		helpers.assert_eq(used(world), {
			"Karabiner-Elements Non-Privileged Agents v2 unregister-multitouch-extension-agent",
			"Karabiner-Elements Non-Privileged Agents v2 unregister-notification-window-agent",
			"Karabiner-Elements Non-Privileged Agents v2 unregister-core-agents",
			"Karabiner-Elements Non-Privileged Agents v2 unregister-menu-agent",
			"pgrep -f karabiner_console_user_server|Karabiner-Console-User-Server",
		})
		helpers.assert_eq(world.calls[1].executable, HELPER)
	end)

	helpers.it("uses nothing but the helper and pgrep: no kill, signal, launchctl or osascript", function()
		local port, world = load_port(function(executable)
			if executable == "/usr/bin/pgrep" then return 1, "" end
			return 0, ""
		end)
		answer(port.close)
		for _, call in ipairs(world.calls) do
			helpers.assert_true(call.executable == HELPER or call.executable == "/usr/bin/pgrep", call.executable)
		end
	end)

	helpers.it("refuses by name when the helper is missing and runs nothing", function()
		local port, world = load_port(function() return 0, "" end, function(w) w.helper = false end)
		helpers.assert_eq(answer(port.close), false)
		helpers.assert_eq(#world.calls, 0)
	end)

	helpers.it("stops at a failed required step and reports it, without the later steps or any wait", function()
		local port, world = load_port(function(_, args)
			if args[1] == "unregister-core-agents" then return 1, "" end
			return 0, ""
		end)
		helpers.assert_eq(answer(port.close), false)
		helpers.assert_eq(#world.calls, 3)
		helpers.assert_eq(#world.timers, 0)
	end)

	helpers.it("treats a timed-out required step as a refusal", function()
		local port = load_port(function(_, args)
			if args[1] == "unregister-core-agents" then return nil, "" end
			return 0, ""
		end)
		helpers.assert_eq(answer(port.close), false)
	end)

	helpers.it("continues past an optional step this Karabiner release does not know", function()
		local port, world = load_port(function(executable, args)
			if executable == "/usr/bin/pgrep" then return 1, "" end
			if args[1] == "unregister-notification-window-agent" or args[1] == "unregister-menu-agent" then
				return 1, "Unknown subcommand"
			end
			return 0, ""
		end)
		helpers.assert_eq(answer(port.close), true)
		helpers.assert_eq(#world.calls, 5)
	end)

	helpers.it("waits, poll by poll, until the user-side process has exited", function()
		local processes = 2
		local port, world = load_port(function(executable)
			if executable == "/usr/bin/pgrep" then
				if processes == 0 then return 1, "" end
				return 0, "42\n"
			end
			return 0, ""
		end)
		local result = "pending"
		port.close(function(ok) result = ok end)
		helpers.assert_eq(result, "pending")
		helpers.assert_eq(#world.timers, 1)
		helpers.assert_eq(world.timers[1].seconds, 0.25)
		processes = 0
		world.tick()
		helpers.assert_eq(result, true)
	end)

	helpers.it("reports the quit as asked, for the owner to re-check, when the process outlives the wait", function()
		local port, world = load_port(function(executable)
			if executable == "/usr/bin/pgrep" then return 0, "42\n" end
			return 0, ""
		end)
		local result = "pending"
		port.close(function(ok) result = ok end)
		local polls = 0
		while result == "pending" and polls < 100 do
			world.tick()
			polls = polls + 1
		end
		helpers.assert_eq(result, true)
		helpers.assert_eq(polls, 39, "the wait is bounded: 40 looks, one of them before any timer")
	end)

	helpers.it("fails when the wait cannot be scheduled", function()
		local port = load_port(function(executable)
			if executable == "/usr/bin/pgrep" then return 0, "42\n" end
			return 0, ""
		end, function(w) w.timer_commits = false end)
		helpers.assert_eq(answer(port.close), false)
	end)
end)





-- ===============================
-- ===============================
-- ======= 3/ Description  =======
-- ===============================
-- ===============================

helpers.describe("other Karabiner: the read-only description", function()
	helpers.it("reports the helper and the active processes without closing anything", function()
		local port, world = load_port(function() return 0, "42\n" end)
		helpers.assert_eq(answer(port.describe), { helper_present = true, active_processes = 1 })
		helpers.assert_eq(used(world), { "pgrep -f karabiner_console_user_server|Karabiner-Console-User-Server" })
	end)

	helpers.it("names an absent helper and an unreadable process list", function()
		local port = load_port(function() return nil, "" end, function(w) w.helper = false end)
		helpers.assert_eq(answer(port.describe), { helper_present = false, active_processes = nil })
	end)
end)
