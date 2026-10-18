--- tests/unit/adapters/system/test_physical_context_probe.lua

--- Actual adapter over finite native API leaf models, never an AX permission receipt.
local helpers = require("tests.helpers")
local Probe = require("adapters.physical_context_probe")
local function fixture(callback)
	local previous = rawget(_G, "hs")
	local native = { application = { frontmostApplication = function() return nil end },
		window = { focusedWindow = function() return nil end },
		axuielement = { applicationElementForPID = function() return nil end } }
	hs = native
	local result = table.pack(pcall(callback, native))
	hs = previous
	if not result[1] then error(result[2], 0) end
	return table.unpack(result, 2, result.n)
end

helpers.describe("physical context native API custody", function()
	helpers.it("preserves actual leaf nil false and exact AX argument", function()
		fixture(function(native)
			local app, window, element, calls = {}, {}, {}, 0
			native.application.frontmostApplication = function() return app, nil, false end
			native.window.focusedWindow = function() return window end
			native.axuielement.applicationElementForPID = function(pid)
				helpers.assert_eq(pid, 4242); calls = calls + 1; return element
			end
			local results = table.pack(Probe.snapshot().frontmost_application())
			helpers.assert_eq(results.n, 3); helpers.assert_true(rawequal(results[1], app))
			helpers.assert_eq(results[2], nil); helpers.assert_eq(results[3], false)
			helpers.assert_true(rawequal(Probe.snapshot().focused_window(), window))
			helpers.assert_true(rawequal(Probe.snapshot().application_element(4242), element)); helpers.assert_eq(calls, 1)
		end)
	end)
	helpers.it("refuses replacement of the invoked native leaf before return", function()
		fixture(function(native)
			native.window.focusedWindow = function()
				native.window.focusedWindow = function() return {} end
				return {}
			end
			local ok = pcall(function() return Probe.snapshot().focused_window() end); helpers.assert_eq(ok, false)
		end)
	end)
	helpers.it("refuses replacement of the actual native namespace before return", function()
		fixture(function(native)
			native.application.frontmostApplication = function()
				native.application = { frontmostApplication = function() return {} end }
				return {}
			end
			local ok = pcall(function() return Probe.snapshot().frontmost_application() end); helpers.assert_eq(ok, false)
		end)
	end)
	helpers.it("retains one exact API set across distinct reads in a sample", function()
		fixture(function(native)
			local probe = Probe.snapshot()
			probe.frontmost_application()
			native.window.focusedWindow = function() return {} end
			helpers.assert_eq(probe.current(), false)
			local ok = pcall(probe.focused_window); helpers.assert_eq(ok, false)
		end)
	end)
	helpers.it("propagates an actual native refusal without a default result", function()
		fixture(function(native)
			native.axuielement.applicationElementForPID = function() error("native refused") end
			local ok = pcall(function() return Probe.snapshot().application_element(4242) end); helpers.assert_eq(ok, false)
		end)
	end)
end)
