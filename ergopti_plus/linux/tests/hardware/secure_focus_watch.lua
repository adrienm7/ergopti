--- tests/hardware/secure_focus_watch.lua

--- ==============================================================================
--- MODULE: Native Secure Focus Watch Regression Worker
--- DESCRIPTION:
--- Exercises the original resident listener, detector, guard, matcher and metric
--- collector against test-owned GTK controls. Only preference consent and input
--- delivery are controlled: DUMMY is an artificial callback sample, not evdev.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
require("compat.utf8").install()
local Json = require("json")
local Clock = require("infra.monotonic")
local Timings = require("infra.timings")
local Window = require("adapters.window_info")
local Lifecycle = require("adapters.process_lifecycle")
local Detector = require("adapters.secure_field_detector")
local jit = require("jit")
local parent_jit = jit.status()
assert(parent_jit, "the native probe must retain its enabled parent JIT")
require("adapters.atspi_focus_watch_worker")
assert(jit.status() == parent_jit, "importing the worker may not disable the parent JIT")
local OwnedProcess = require("adapters.owned_process")
local watch_operation = nil
local Watch = require("adapters.atspi_focus_watch").new({
	start_process = function(executable, arguments, options, callback)
		-- Exercise callback delivery after an aggressively compiled native call.
		-- The original worker must isolate its own JIT policy even with CLI flags.
		local argv = { "-Ohotloop=1,hotexit=1" }
		for _, value in ipairs(arguments) do argv[#argv + 1] = value end
		watch_operation = OwnedProcess.start(executable, argv, options, callback)
		return watch_operation
	end,
})
local uv = require("luv")
local root = assert(arg[1], "private native fixture directory required")
package.loaded["infra.metrics_preferences"] = require("tests.support.metrics_preferences_fixture").new({ initial = {
	["metrics.enabled"] = true, ["metrics.secure_filter_enabled"] = true, ["metrics.encrypt"] = false,
} })
local Keystats = require("modules.keystats.keystats")
assert(Keystats.init({ log_dir = root, sqlite_path = root .. "/metrics.sqlite3" }) ~= false)
local engine = require("modules.hotstrings.engine").new()
local resets, focus_changes = 0, 0
local Guard = require("modules.keystats.focus_guard").new({
	watch = Watch, detector = Detector, keystats = Keystats, now_ms = Clock.now_ms,
	settle_ms = Timings.ms("privacy", "focus_settle_ms"),
	reset_text = function() resets = resets + 1; engine:reset(false) end,
})
Lifecycle.onFocusChange(function() focus_changes = focus_changes + 1; Guard.prime() end)

--- Reports callback panics using a fixed marker, without disclosing native stderr.
--- @param reason string Controlled fixture failure.
local function unavailable(reason)
	local result = watch_operation and watch_operation.result
	local stderr = result and result.stderr
	if type(stderr) == "string" and stderr:find("bad callback", 1, true) then
		error("native focus worker panicked during compiled callback reentry", 0)
	end
	error(reason, 0)
end

--- Waits for a stated native readiness predicate without replaying input samples.
--- @param role number Expected AT-SPI role.
--- @return table receipt
local function await_role(role)
	local deadline = Clock.now_ms() + 5000
	while Clock.now_ms() <= deadline do
		uv.run("nowait")
		local receipt = Watch.barrier()
		if receipt and receipt.role == role then return receipt end
		uv.sleep(1)
	end
	unavailable("native focus did not establish the expected role within five seconds")
end

--- Retires the exact helper and every native handle before leaving the worker.
local function retire()
	Watch.stop()
	local deadline = Clock.now_ms() + 3000
	while not Watch.is_settled() and Clock.now_ms() <= deadline do uv.run("nowait"); uv.sleep(1) end
	assert(Watch.is_settled(), "native focus cleanup remained unsettled")
end

--- Reports only test-owned scalar results and native identity metadata.
--- @param fields table Controlled sample results.
local function report(fields)
	local snapshot = Watch.snapshot()
	fields.role = snapshot and snapshot.role or nil
	fields.bus = snapshot and snapshot.bus or nil
	fields.path = snapshot and snapshot.path or nil
	fields.verdict = Detector.getVerdict()
	fields.metric_secure = Keystats.get_privacy_state().secure_field
	fields.buffer = engine:current_buffer()
	fields.focus_changes = focus_changes
	fields.resets = resets
	fields.window_identity = Window.focused_identity()
	io.write("RECEIPT:" .. Json.encode(fields) .. "\n")
	io.flush()
end

local ok, error_message = xpcall(function()
	assert(Watch.start(), "resident focus process did not start")
	Watch.wait_ready()
	await_role(61)
	local durations = {}
	for _ = 1, 128 do
		local started = Clock.now_ms()
		local snapshot = Watch.barrier()
		durations[#durations + 1] = Clock.now_ms() - started
		if not snapshot or snapshot.role ~= 61 then unavailable("native warmup must retain the ordinary field") end
	end
	table.sort(durations)
	assert(jit.status() == parent_jit, "native child initialization may not disable the parent JIT")
	Guard.prime()
	Lifecycle.start()
	report({ ready = true, parent_jit = parent_jit, warmup_requests = #durations,
		warmup_latency_ms = { median = durations[64], p95 = durations[122], max = durations[#durations] },
		barrier_budget_ms = Timings.ms("privacy", "focus_barrier_timeout_ms"),
		lease_ms = Timings.ms("privacy", "atspi_probe_timeout_ms") })
	for command in io.lines() do
		if command == "reset" then
			Keystats.reset_session()
			engine:reset(false)
			report({ primed = Guard.prime() })
		elseif command == "normal" or command == "password" then
			await_role(command == "normal" and 61 or 40)
			Guard.blocks_text()
			report({ established = true })
		elseif command == "sample" then
			local before = Keystats._pending_buffer_count_for_test()
			local allowed = 0
			for character in ("DUMMY"):gmatch(".") do
				if not Guard.blocks_text() then
					allowed = allowed + 1
					Keystats.on_keydown(character, Clock.now_ms(), "OwnedFixture", 30)
					engine:on_char(character)
				end
			end
			Lifecycle.tick(1)
			report({ allowed = allowed, raw_delta = Keystats._pending_buffer_count_for_test() - before })
		elseif command == "restart" then
			retire()
			assert(Watch.start(), "resident focus restart refused after physical settlement")
			Watch.wait_ready()
			await_role(61)
			report({ restarted = Guard.prime() })
		else error("unknown native focus fixture command") end
	end
end, function(reason) return tostring(reason) end)
Lifecycle.stop()
retire()
if not ok then error(error_message, 0) end
