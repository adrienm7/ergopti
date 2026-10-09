--- tests/unit/modules/keylogger/test_system_load_failures.lua

--- ==============================================================================
--- MODULE: System Load Failure Regression
--- DESCRIPTION:
--- Failed or malformed sensor results must remain diagnostics, never persisted
--- measurements. Controlled completions exercise the real watcher boundary.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a sensor completion against an initialized, enabled watcher.
--- @param status integer Native exit status.
--- @param stdout any Native output under test.
--- @return table fixture Persisted events and contextual diagnostics.
local function complete_sample(status, stdout)
	local names = {
		"infra.logger", "infra.timings", "adapters.task_lifecycle",
		"adapters.timer_scheduler", "modules.keylogger.log_manager",
		"modules.keylogger.watchers",
	}
	local saved, saved_hs = {}, _G.hs
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local fixture = { events = {}, errors = {} }
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, success = noop, debug = noop, warn = noop,
		error = function(_, message, ...)
			fixture.errors[#fixture.errors + 1] = string.format(message, ...)
		end,
		pcall = function(_, callback) return pcall(callback) end,
	}
	package.loaded["infra.timings"] = { ms = function() return 1 end }
	package.loaded["adapters.timer_scheduler"] = { cancel = function() return true end }
	package.loaded["adapters.task_lifecycle"] = {
		native = function(_, _, callback) fixture.complete = callback; return {} end,
		start = function() return true end,
	}
	package.loaded["modules.keylogger.log_manager"] = {
		log_system_event = function(kind, data)
			fixture.events[#fixture.events + 1] = { kind = kind, data = data }
		end,
	}
	_G.hs = { timer = { absoluteTime = function() return 1000000000 end } }
	local ok, err = xpcall(function()
		local watcher = require("modules.keylogger.watchers")
		helpers.assert_true(watcher.init({ is_enabled = true, session_last_active = 0 }, function() return false end))
		helpers.assert_true(watcher.init_hardware_watchers())
		watcher.check_idle()
		helpers.assert_eq(type(fixture.complete), "function")
		fixture.complete(status, stdout, "PRIVATE_STDERR_SENTINEL")
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	_G.hs = saved_hs
	if not ok then error(err, 0) end
	return fixture
end

helpers.describe("system-load-failures", function()
	helpers.it("rejects failed exit even when stdout resembles a valid measurement", function()
		local fixture = complete_sample(1, "CPU usage: 10.0% user\nPhysMem: 8G used")
		helpers.assert_eq(#fixture.events, 0, "failed subprocess output is not a measurement")
		helpers.assert_eq(#fixture.errors, 1)
		helpers.assert_true(fixture.errors[1]:find("exit status 1", 1, true) ~= nil)
		helpers.assert_true(fixture.errors[1]:find("PRIVATE_STDERR_SENTINEL", 1, true) == nil)
	end)

	for _, output in ipairs({
		"", "CPU usage: 10.0% user", "PhysMem: 8G used",
		"CPU usage: 101.0% user\nPhysMem: 8G used",
		"CPU usage: 1..0% user\nPhysMem: 8G used",
		"CPU usage: 10.0% user\nPhysMem: garbage8G used",
		"CPU usage: 10.0% user\nPhysMem: 8..1G used",
	}) do
		helpers.it("rejects incomplete or invalid sample " .. string.format("%q", output), function()
			local fixture = complete_sample(0, output)
			helpers.assert_eq(#fixture.events, 0, "invalid sample must not be persisted")
			helpers.assert_eq(#fixture.errors, 1)
		end)
	end

	helpers.it("preserves complete native samples including zero and full CPU usage", function()
		for _, cpu in ipairs({ "0.0", "20.5", "100.0" }) do
			local fixture = complete_sample(0, "CPU usage: " .. cpu .. "% user\nPhysMem: 8192M used (1M wired)")
			helpers.assert_eq(#fixture.events, 1)
			helpers.assert_eq(#fixture.errors, 0)
			helpers.assert_eq(fixture.events[1].kind, "system_load")
			helpers.assert_eq(fixture.events[1].data.cpu_user_percent, tonumber(cpu))
			helpers.assert_eq(fixture.events[1].data.mem_used, "8192M")
		end
	end)
end)
