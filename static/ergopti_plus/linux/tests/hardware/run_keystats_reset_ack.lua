--- tests/hardware/run_keystats_reset_ack.lua
--- ==============================================================================
--- MODULE: Native Metrics Reset COMMIT Acknowledgement
--- DESCRIPTION:
--- A real sampled system day keeps every flush nonempty. Reset must consume its
--- exact SQLite COMMIT plus physical cleanup once, including successor input.
--- ==============================================================================

local root = assert(arg[1])
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;"
	.. root .. "/../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Fixture = require("tests.support.keystats_native_fixture")
local Preferences = require("tests.support.metrics_preferences_fixture")
local uv = require("luv")
assert(jit and jit.os == "Linux", "sampled reset must exercise the real Linux JIT runtime")
assert(debug.getinfo(uv.fs_stat, "S").what == "C", "sampled reset requires the actual native luv provider")
local Clock = require("infra.monotonic")
local Timings = require("infra.timings")
local checks = 0

--- Observes an actual native predicate within the canonical SQLite deadline.
local function await(predicate, pump)
	local deadline = uv.hrtime() + Timings.ms("keystats", "sqlite_operation_timeout_ms") * 1000000
	while not predicate() and uv.hrtime() < deadline do uv.run("nowait"); pump(); uv.sleep(1) end
	assert(predicate(), "native reset did not acknowledge its exact committed source")
end

for _, successor in ipairs({ false, true }) do
	local path = os.tmpname()
	local ok, failure = xpcall(function()
		Preferences.with(function()
			Fixture.with(function(k)
				k.init({ sqlite_path = path })
				require("tests.support.metrics_consent_fixture").enable(k)
				local system = require("modules.keystats.system_metrics")
				assert(system.sample())
				local writer = require("modules.keystats.sqlite_writer")
				local start, operations, released = writer.start_flush, {}, false
				writer.start_flush = function(...)
					local native = assert(start(...))
					operations[#operations + 1] = native
					if #operations ~= 1 then return native end
					local proxy = { result = native.result }
					function proxy:pump() local done = native:pump(); self.result = native.result; return released and done end
					function proxy:is_settled() return released and native:is_settled() end
					function proxy:is_read_safe() return released and native:is_read_safe() end
					function proxy:is_retryable() return native:is_retryable() end
					function proxy:phase() return native:phase() end
					function proxy:cancel() return native:cancel() end
					return proxy
				end
				local passed, detail = xpcall(function()
					local callbacks, success = 0, nil
					k.on_keydown("a", math.floor(Clock.now_ms()), "reset-system-app")
					assert(k.request_session_reset(function(result) callbacks = callbacks + 1; success = result end))
					await(function() return operations[1]:is_settled() end, function() k.pump_flush() end)
					assert(operations[1].result.committed == true)
					assert(callbacks == 0 and k.has_flush_debt(), "withheld physical receipt cannot complete reset")
					if successor then k.on_keydown("b", math.floor(Clock.now_ms()), "reset-system-app") end
					released = true
					await(function() return callbacks > 0 end, function()
						-- New successor input is dispatched by the real periodic path.
						if successor then k.flush() else k.pump_flush() end
					end)
					assert(callbacks == 1 and success == true, "reset must emit one successful terminal callback")
					assert(#operations == (successor and 2 or 1), "committed reset source must not redispatch indefinitely")
					assert(k.get_session_stats().keystrokes == 0, "acknowledged reset must clear live session figures")
					assert(not k.has_flush_debt() and k.get_flush_status().committed)
					for _, operation in ipairs(operations) do assert(operation:is_settled() and operation.result.committed) end
					local rows = assert(writer.query_rows("SELECT text FROM events_typing ORDER BY id;"))
					assert(table.concat(rows) == (successor and "ab" or "a"), "reset must preserve each actual typed row once")
					for _ = 1, 3 do k.pump_flush() end
					assert(callbacks == 1 and #operations == (successor and 2 or 1))
					checks = checks + 8
				end, debug.traceback)
				released, writer.start_flush = true, start
				assert(passed, detail)
			end)
		end)
	end, debug.traceback)
	os.remove(path)
	assert(ok, failure)
end
print("Native metrics reset ACK: " .. checks .. " checks, 0 failures")
