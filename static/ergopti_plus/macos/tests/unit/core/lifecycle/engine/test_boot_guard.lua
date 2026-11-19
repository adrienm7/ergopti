--- tests/unit/core/lifecycle/engine/test_boot_guard.lua

--- ==============================================================================
--- MODULE: Boot Guard Tests
--- DESCRIPTION:
--- init.lua ran its top part unguarded: an error there after hs.reload(), such as
--- a module that will not load from a half-updated tree, reached Hammerspoon's
--- console only and left the driver dead with no launcher alert. These tests pin
--- that the guard reports such a failure through the fatal reporter and exits,
--- raises it again when no launcher heard it, and that init.lua enters the guard
--- before anything else.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["core.lifecycle.engine.boot_guard"] = nil
local BootGuard = require("core.lifecycle.engine.boot_guard")

--- Builds a failing or succeeding entry chunk and records what it received.
--- @param fail boolean Whether the chunk raises.
--- @return table seams { loadfile, received }
local function entry(fail)
	local seams = { received = nil }
	seams.loadfile = function(path)
		helpers.assert_eq(path, "/app/macos/init.lua")
		return function(first)
			seams.received = first
			if fail then error("half-updated tree probe", 0) end
		end
	end
	return seams
end

helpers.describe("boot guard", function()
	helpers.it("runs the entry point once more, marked as guarded", function()
		local seams = entry(false)
		local booted = BootGuard.run("/app/macos/init.lua", { loadfile = seams.loadfile,
			report = function() error("a healthy boot reports nothing") end,
			exit = function() error("a healthy boot never exits") end })
		helpers.assert_eq(booted, true)
		helpers.assert_true(BootGuard.is_guarded(seams.received), "the inner run must know it is guarded")
		helpers.assert_true(not BootGuard.is_guarded(nil), "Hammerspoon's own run is not guarded")
	end)

	helpers.it("reports a top-level boot failure to the launcher and exits 1", function()
		local seams, reported, exited = entry(true), nil, nil
		BootGuard.run("/app/macos/init.lua", { loadfile = seams.loadfile,
			report = function(failure, traceback)
				reported = { failure = failure, traceback = traceback }
				return true
			end,
			exit = function(code) exited = code end })
		helpers.assert_eq(exited, 1, "a failed boot the launcher heard must end the process")
		helpers.assert_eq(reported.failure, "half-updated tree probe")
		helpers.assert_contains(reported.traceback, "half-updated tree probe")
		helpers.assert_contains(reported.traceback, "stack traceback", "the stack is captured before the unwind")
	end)

	helpers.it("raises the failure again when no launcher received it", function()
		local seams = entry(true)
		local ok, err = pcall(BootGuard.run, "/app/macos/init.lua", { loadfile = seams.loadfile,
			report = function() return false end,
			exit = function() error("an unheard failure must not exit silently") end })
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "half-updated tree probe")
	end)

	helpers.it("names the running boot stage and the stack in the fatal report", function()
		local previous = {}
		for _, name in ipairs({ "diagnostics.adapters.boot_fatal", "core.logger.engine.boot_profiler",
			"core.i18n.engine.i18n" }) do previous[name] = package.loaded[name] end
		local call = nil
		package.loaded["diagnostics.adapters.boot_fatal"] = { report = function(stage, detail, message)
			call = { stage = stage, detail = detail, message = message }
			return true
		end }
		package.loaded["core.logger.engine.boot_profiler"] = { current_stage = function() return "Core module requires" end }
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return "text:" .. key end }
		local ok, notified = pcall(BootGuard.report, "probe", "probe\nstack traceback: here")
		for name, value in pairs(previous) do package.loaded[name] = value end
		helpers.assert_eq(ok, true, tostring(notified))
		helpers.assert_eq(notified, true)
		helpers.assert_eq(call.stage, "Core module requires")
		helpers.assert_contains(call.detail, "stack traceback")
		helpers.assert_eq(call.message, "text:dialog.fatal_error.cannot_start")
	end)

	helpers.it("is entered by init.lua before its first module load", function()
		local handle = assert(io.open(helpers.driver_root() .. "init.lua", "rb"))
		local source = assert(handle:read("*a"))
		handle:close()
		local guard = source:find("BootGuard.run(entry)", 1, true)
		local first_require = source:find("require(", 1, true)
		helpers.assert_not_nil(guard, "init.lua must run itself under the boot guard")
		helpers.assert_true(guard < first_require, "the guard must precede every module load")
	end)
end)
