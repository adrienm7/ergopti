--- tests/unit/ui/healthcheck/test_desktop_report_shutdown.lua

--- ==============================================================================
--- MODULE: Desktop Report Shutdown Integration (Linux)
--- DESCRIPTION:
--- Exercises the real Main coordinator and Report action frame. A page may
--- revoke its confirmation helper, while an accepted GUI has its own lifetime.
--- ==============================================================================

local h = require("tests.helpers")
local Scenario = require("tests.support.ui.healthcheck.desktop_scenario")

h.describe("desktop-report actual Main confirmation owner", function()
	h.it("desktop-report cold shutdown never imports a desktop launcher", function()
		local shutdown, observed = Scenario.shutdown({})
		shutdown.request("cold desktop control")
		h.assert_eq(false, shutdown.is_pending())
		h.assert_eq(1, observed.stops)
		h.assert_eq(1, observed.flushes)
	end)
	for _, value in ipairs({ "nil", "false", "zero" }) do
		h.it("desktop-report actual Main retains " .. value .. " helper acknowledgements", function()
			local calls, acknowledged = 0, false
			local owner = { shutdown = function()
				calls = calls + 1
				if acknowledged then return true end
				if value == "zero" then return 0 elseif value == "false" then return false end
			end }
			local shutdown, observed = Scenario.shutdown({ loaded = { ["adapters.desktop_opener"] = owner } })
			shutdown.request("pending desktop control")
			h.assert_eq(true, shutdown.is_pending())
			h.assert_eq(0, observed.stops)
			shutdown.request("repeated desktop control")
			h.assert_eq(1, observed.flushes)
			acknowledged = true
			shutdown.poll()
			h.assert_true(calls >= 2)
			h.assert_eq(false, shutdown.is_pending())
			h.assert_eq(1, observed.stops)
		end)
	end
	for _, replacement in ipairs({ "module", "method", "unloaded" }) do
		h.it("desktop-report actual Main pins its initial module and method across " .. replacement, function()
			local acknowledged, foreign_calls = false, 0
			local owner = { shutdown = function() return acknowledged end }
			local loaded = { ["adapters.desktop_opener"] = owner }
			local shutdown, observed = Scenario.shutdown({ loaded = loaded })
			shutdown.request("pin desktop owner")
			local foreign = function() foreign_calls = foreign_calls + 1; return true end
			if replacement == "module" then loaded["adapters.desktop_opener"] = { shutdown = foreign }
			elseif replacement == "method" then owner.shutdown = foreign
			else loaded["adapters.desktop_opener"] = nil end
			shutdown.poll()
			h.assert_eq(true, shutdown.is_pending())
			h.assert_eq(0, foreign_calls)
			h.assert_eq(0, observed.stops)
			acknowledged = true
			shutdown.poll()
			h.assert_eq(false, shutdown.is_pending())
			h.assert_eq(1, observed.stops)
		end)
	end
end)

h.describe("desktop-report default opener authority", function()
	h.it("desktop-report default ports retain the exact action predicate and cancellation", function()
		local name, adapter = "ui.healthcheck.report", "adapters.desktop_opener"
		local previous_report, previous_adapter = package.loaded[name], package.loaded[adapter]
		package.loaded[name] = nil
		local calls, cancels, completions, live, authority = {}, 0, 0, true, nil
		package.loaded[adapter] = { open = function(target, done, current)
			calls[#calls + 1] = { target = target, done = done }
			authority = current
			return { cancel = function() cancels = cancels + 1 end }
		end }
		local ok, err = pcall(function()
			local Report = require(name)
			local request = Report.perform({ action = "open_path", id = "log_today" },
				{ log_today = "/private/report literal.txt" }, {}, {}, { exists = function() return true end }, nil,
				{ current = function() return live end, complete = function() completions = completions + 1 end })
			h.assert_eq(1, #calls)
			h.assert_eq("/private/report literal.txt", calls[1].target)
			h.assert_eq("function", type(authority))
			h.assert_eq(true, authority())
			live = false
			h.assert_eq(false, authority())
			request.cancel()
			calls[1].done({ ok = true, code = 0 })
			h.assert_eq(0, completions)
			h.assert_eq(1, cancels)
		end)
		package.loaded[name], package.loaded[adapter] = previous_report, previous_adapter
		if not ok then error(err, 0) end
	end)
end)
