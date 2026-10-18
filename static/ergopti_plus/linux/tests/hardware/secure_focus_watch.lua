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
local Watch = require("adapters.atspi_focus_watch").new()
local uv = require("luv")
local root = assert(arg[1], "private native fixture directory required")
package.loaded["infra.metrics_preferences"] = require("tests.support.metrics_preferences_fixture").new({ initial = {
	["metrics.enabled"] = true, ["metrics.secure_filter_enabled"] = true, ["metrics.encrypt"] = false,
} })
local Keylogger = require("modules.keylogger.keylogger")
assert(Keylogger.init({ log_dir = root, sqlite_path = root .. "/metrics.sqlite3" }) ~= false)
local engine = require("modules.hotstrings.engine").new()
local resets, focus_changes = 0, 0
local Guard = require("modules.keylogger.focus_guard").new({
	watch = Watch, detector = Detector, keylogger = Keylogger, now_ms = Clock.now_ms,
	settle_ms = Timings.ms("privacy", "focus_settle_ms"),
	reset_text = function() resets = resets + 1; engine:reset(false) end,
})
Lifecycle.onFocusChange(function() focus_changes = focus_changes + 1; Guard.prime() end)

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
	error("native focus did not establish the expected role within five seconds")
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
	fields.metric_secure = Keylogger.get_privacy_state().secure_field
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
	Guard.prime()
	Lifecycle.start()
	report({ ready = true, lease_ms = Timings.ms("privacy", "atspi_probe_timeout_ms") })
	for command in io.lines() do
		if command == "reset" then
			Keylogger.reset_session()
			engine:reset(false)
			report({ primed = Guard.prime() })
		elseif command == "normal" or command == "password" then
			await_role(command == "normal" and 61 or 40)
			Guard.blocks_text()
			report({ established = true })
		elseif command == "sample" then
			local before = Keylogger._pending_buffer_count_for_test()
			local allowed = 0
			for character in ("DUMMY"):gmatch(".") do
				if not Guard.blocks_text() then
					allowed = allowed + 1
					Keylogger.on_keydown(character, Clock.now_ms(), "OwnedFixture", 30)
					engine:on_char(character)
				end
			end
			Lifecycle.tick(1)
			report({ allowed = allowed, raw_delta = Keylogger._pending_buffer_count_for_test() - before })
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
