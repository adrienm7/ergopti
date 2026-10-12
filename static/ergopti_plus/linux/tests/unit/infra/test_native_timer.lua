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

	helpers.it("linux-relative-clock: passive HTTP diagnostics preserve native acknowledgements and callbacks", function()
		local path = helpers.driver_root() .. "/tests/fixtures/native_relative_timer_siblings.lua"
		local file = assert(io.open(path, "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local marker = "-- Passive private observations"
		local first = assert(source:find(marker, 1, true))
		assert(not source:find(marker, first + #marker, true), "fixture observation owner is ambiguous")
		local last = assert(source:find("local function retain(", first, true))
		local body = source:sub(first, last - 1)
		local chunk = body .. [[
local input, image, options = {}, {}, {}
local delivered, trace = 0, { start = 0, cached = 0, events = {}, mode = "control", clock = "luv.hrtime" }
options.stdio, options.image = { input }, image
active_http_trace = trace
local handle, pid, status = uv.spawn("curl", options, function(code, signal)
	assert(code == 7 and signal == 9); delivered = delivered + 1; return false, nil
end)
assert(handle == image and pid == 421 and status == nil)
local receipt, message, code = uv.write(input, "PRIVATE_CONTROL_CONFIG", function(error_code)
	assert(error_code == nil); delivered = delivered + 1; return nil, false
end)
assert(receipt == false and message == "NATIVE_REFUSAL" and code == nil)
assert(native_calls.options == options and native_calls.input == input and native_calls.data == "PRIVATE_CONTROL_CONFIG")
local returned, extra = native_calls.write(nil); assert(returned == nil and extra == false)
assert(delivered == 1)
local phases = {}; for _, row in ipairs(trace.events) do phases[row.phase] = row end
assert(phases["config-write-submit"] and phases["config-write-ack"] and phases["config-write-ack"].ack == "true",
	"actual fixture producer emitted no config-pipe acknowledgement")
]]
		-- The model evaluates the actual observer definitions, without native luv.
		local prefix = [[
local native_calls = {}
local uv = {
	hrtime = function() return 0 end, now = function() return 0 end,
	spawn = function(executable, options, callback)
		assert(executable == "curl"); native_calls.options, native_calls.exit = options, callback
		return options.image, 421, nil
	end,
	write = function(input, data, callback)
		native_calls.input, native_calls.data, native_calls.write = input, data, callback
		return false, "NATIVE_REFUSAL", nil
	end,
}
local native = { start = function() return 0 end }
local require = function(name) assert(name == "infra.native_timer"); return native end
]]
		local compile = loadstring or load
		assert(compile(prefix .. chunk, "@passive-http-diagnostic-control"))()
	end)


	helpers.it("linux-relative-clock: HTTP fixture keeps its completion budget and stale-clock counterexample", function()
		local file = assert(io.open(helpers.driver_root() .. "/tests/fixtures/native_relative_timer_siblings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local marker = '\tcheck("actual loopback HTTP survives its new deadline '
		local first = assert(source:find(marker, 1, true))
		assert(not source:find(marker, first + #marker, true), "HTTP fixture owner must be unique")
		local arm = assert(source:find("\t\tlocal function arm()", first, true))
		local last = assert(source:find("\n\t\tuv.update_time()", arm, true))
		local bound = assert(tonumber(source:match("assert%(requests%(%) == 1 and duration >= 25 and duration < (%d+)%)")))
		local contract = (source:match("local HTTP_DEADLINE_MS = [^\n]+\n") or "")
			.. (source:match("local HTTP_STALE_WORK_MS = [^\n]+\n") or "")
		local compile = loadstring or load
		local invoke = assert(compile("return function(uv, Http, observe_http, remember_processes, require)\n"
			.. contract .. "local start, active_http_trace; local results = {}; local url = 'recording-only'; local in_callback = false\n"
			.. source:sub(arm, last - 1) .. "\narm(); return start\nend", "@HTTP-fixture-admission-contract"))()
		local function exercise(start_timer)
			local wall, cached, expiry, timeout, remembered = 0, 0, nil, nil, 0
			local backend = {
				sleep = function(ms) wall = wall + ms end,
				hrtime = function() return wall * 1000000 end,
				now = function() return cached end,
				update_time = function() cached = wall end,
				timer_start = function(_, delay, repeat_ms, callback)
					assert(repeat_ms == 0 and type(callback) == "function")
					expiry = cached + delay; return 0
				end,
			}
			local http = { get = function(url, headers, options, callback)
				assert(url == "recording-only" and next(headers) == nil)
				assert(options.owner == "clock-fixture" and type(callback) == "function")
				timeout = options.timeout_ms
				return start_timer(backend, {}, timeout, 0, function() end) == 0
			end }
			invoke(backend, http, function() end, function() remembered = remembered + 1 end,
				function(name) assert(name == "infra.monotonic"); return { backend = function() return "luv.hrtime" end } end)
			assert(remembered == 1 and expiry ~= nil)
			return timeout, wall, expiry - wall
		end
		local timeout, blocked, remaining = exercise(Timer.start)
		helpers.assert_eq(timeout, bound, "cold curl receives the unchanged asserted completion budget")
		helpers.assert_true(blocked > timeout, "blocked work must exceed the deadline to retain the original bug")
		helpers.assert_eq(remaining, timeout, "actual native timer owner preserves the full new relative deadline")
		local stale_timeout, stale_blocked, stale_remaining = exercise(function(backend, ...)
			return backend.timer_start(...)
		end)
		helpers.assert_eq(stale_timeout, timeout)
		helpers.assert_eq(stale_blocked, blocked)
		helpers.assert_true(stale_remaining < 0, "withdrawing only clock refresh must expire before any response")
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
