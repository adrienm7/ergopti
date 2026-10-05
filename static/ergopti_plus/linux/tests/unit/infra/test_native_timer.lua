--- tests/unit/infra/test_native_timer.lua
--- Native relative clock integration and explicitly simulated receipt controls.
local helpers = require("tests.helpers")
local Timer = require("infra.native_timer")

helpers.describe("linux-relative-clock", function()
	helpers.it("linux-relative-clock: refreshes before arming and preserves native start receipts", function()
		for _, receipt in ipairs({ "zero", "nil", "false" }) do
			local calls, handle, callback = {}, {}, function() end
			local backend = {
				update_time = function() calls[#calls + 1] = "refresh" end,
				timer_start = function(actual_handle, delay, interval, actual_callback)
					calls[#calls + 1] = "arm"
					helpers.assert_true(actual_handle == handle and actual_callback == callback)
					helpers.assert_eq(delay, 80)
					helpers.assert_eq(interval, 0)
					if receipt == "zero" then return 0 end
					if receipt == "false" then return false, "simulated refusal", "EINVAL" end
					return nil, "simulated refusal", "EINVAL"
				end,
			}
			local result, message, code = Timer.start(backend, handle, 80, 0, callback)
			helpers.assert_eq(table.concat(calls, ","), "refresh,arm")
			if receipt == "zero" then helpers.assert_eq(result, 0) else
				if receipt == "false" then helpers.assert_eq(result, false) else helpers.assert_nil(result) end
				helpers.assert_eq(message, "simulated refusal")
				helpers.assert_eq(code, "EINVAL")
			end
		end
	end)

	if pcall(require, "luv") and package.config:sub(1, 1) == "/" then
		helpers.it("linux-relative-clock: actual sibling deadlines and loop admission survive blocking work", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_relative_timer_siblings.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native sibling timer fixture must pass")
		end)

		helpers.it("linux-relative-clock: actual timers and child deadlines start after blocking work and inside callbacks", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_relative_timers.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native relative timer fixture must pass")
		end)
	end
end)
