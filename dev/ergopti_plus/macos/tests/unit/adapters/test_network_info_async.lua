--- tests/unit/adapters/test_network_info_async.lua

--- ==============================================================================
--- MODULE: NetworkInfo async shell-out regression tests (F-LOW-8)
--- DESCRIPTION:
--- isInternetReachable() and isVpnActive() used to shell out synchronously via
--- hs.execute("ping …") / hs.execute("ifconfig … | grep …") directly on the
--- Hammerspoon main run loop. ping's own timeout (`-t 1`) means a single call
--- could block every other callback for up to a second — a real landmine for
--- whenever this dormant adapter (F-HIGH-10: zero production callers) is first
--- wired into a feature that polls it on a timer.
---
--- Fix: both methods now return a cached boolean immediately (never blocking)
--- and kick off an async refresh through adapters.shell_runner.spawn() (the
--- same hs.task-based async pattern used throughout modules/llm/api_*.lua and
--- platform/remap/watchers.lua's read_layout_async()).
---
--- Two angles, matching the style of tests/unit/adapters/test_shell_runner_on_done_visible.lua:
---   1. Source check: neither method calls hs.execute directly anymore.
---   2. Behaviour: driving the stubbed hs.task completion callback updates the
---      cached result that a subsequent call returns.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_network_info_src()
	-- Selected by a declaration unique to adapters/network_info.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function _refresh_internet_reachable")
	helpers.assert_true(src ~= nil, "adapters/network_info.lua source must be locatable")
	return src
end

--- Extracts the source text of a top-level `function M.<name>(...) ... end`
--- declaration so assertions can be scoped to just that function body.
--- @param src string Full file source.
--- @param name string Function name (e.g. "isInternetReachable").
--- @return string Function body text (empty string if not found).
local function extract_function_body(src, name)
	local start_pos = src:find("function M%." .. name .. "%(")
	if not start_pos then return "" end
	-- The next top-level "function M." or end-of-file closes this function.
	local next_pos = src:find("function M%.", start_pos + 1)
	return src:sub(start_pos, next_pos and (next_pos - 1) or #src)
end





-- =======================================================================
-- =======================================================================
-- ======= 1/ Source invariant: no blocking hs.execute() shell-out =======
-- =======================================================================
-- =======================================================================

helpers.describe("NetworkInfo: async shell-out (F-LOW-8 source)", function()

	helpers.it("isInternetReachable() does not call hs.execute directly", function()
		local body = extract_function_body(read_network_info_src(), "isInternetReachable")
		helpers.assert_true(body ~= "", "isInternetReachable() must be found in the source")
		helpers.assert_true(body:find("hs%.execute") == nil,
			"isInternetReachable() must not shell out synchronously via hs.execute — use the async ShellRunner adapter instead")
	end)

	helpers.it("isVpnActive() does not call hs.execute directly", function()
		local body = extract_function_body(read_network_info_src(), "isVpnActive")
		helpers.assert_true(body ~= "", "isVpnActive() must be found in the source")
		helpers.assert_true(body:find("hs%.execute") == nil,
			"isVpnActive() must not shell out synchronously via hs.execute — use the async ShellRunner adapter instead")
	end)

	helpers.it("network_info.lua requires adapters.shell_runner", function()
		local src = read_network_info_src()
		helpers.assert_true(src:find('require%("adapters%.shell_runner"%)') ~= nil,
			"network_info.lua must dispatch its shell-outs through adapters.shell_runner")
	end)

end)





-- ==================================================================
-- ==================================================================
-- ======= 2/ Behaviour: cached result updates asynchronously =======
-- ==================================================================
-- ==================================================================

helpers.describe("NetworkInfo: async probe updates the cached result (F-LOW-8 behaviour)", function()

	--- Builds an hs stub whose hs.task.new()/start() synchronously fires the
	--- captured completion callback with the given (exit_code, stdout) — this
	--- makes the async round-trip observable in a single synchronous test step.
	--- @param exit_code integer Exit code passed to the completion callback.
	--- @param stdout string Stdout text passed to the completion callback.
	--- @return table hs overrides table for helpers.load_with_stubs.
	local function make_hs_task_stub(exit_code, stdout)
		return {
			task = {
				new = function(_executable, cb, _args)
					return {
						start = function()
							if cb then cb(exit_code, stdout, "") end
							return true
						end,
						isRunning = function() return false end,
						terminate = function() end,
					}
				end,
			},
		}
	end

	-- adapters.shell_runner captures `local hs = hs` at require-time and is a
	-- transitive dependency of adapters.network_info; load_with_stubs only
	-- clears the module named in its first argument, so shell_runner must be
	-- evicted from package.loaded explicitly here or it keeps using whichever
	-- `hs` stub happened to be active the first time some earlier test in the
	-- suite required it — not the fresh task stub built for this test.
	local function reload_network_info(hs_overrides)
		package.loaded["adapters.shell_runner"] = nil
		return helpers.load_with_stubs("adapters.network_info", hs_overrides)
	end

	helpers.it("isInternetReachable() reflects a successful ping after the async callback fires", function()
		local NI = reload_network_info(
			make_hs_task_stub(0, "1 packets transmitted, 1 packets received, 0% packet loss\n"))

		-- First call starts false (nothing probed yet) — cache is seeded false,
		-- but the stub above fires the completion callback SYNCHRONOUSLY inside
		-- spawn().start(), so by the time isInternetReachable() returns, the
		-- probe it just kicked off has already updated the cache.
		local result = NI.isInternetReachable()
		helpers.assert_true(result == true,
			"isInternetReachable() must reflect a successful ping once the async probe completes")
	end)

	helpers.it("isInternetReachable() returns false when the ping probe fails", function()
		local NI = reload_network_info(make_hs_task_stub(1, ""))

		local result = NI.isInternetReachable()
		helpers.assert_true(result == false,
			"isInternetReachable() must return false when the async ping probe fails")
	end)

	helpers.it("isVpnActive() detects a utun interface in ifconfig output", function()
		local NI = reload_network_info(
			make_hs_task_stub(0, "utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380\n"))

		local result = NI.isVpnActive()
		helpers.assert_true(result == true,
			"isVpnActive() must return true once the async ifconfig probe finds a utun interface")
	end)

	helpers.it("isVpnActive() returns false when no utun interface is present", function()
		local NI = reload_network_info(
			make_hs_task_stub(0, "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n"))

		local result = NI.isVpnActive()
		helpers.assert_true(result == false,
			"isVpnActive() must return false when the async ifconfig probe finds no utun interface")
	end)

	-- Regression (probe latch): _refresh_*() sets its in-flight flag BEFORE calling
	-- handle.start(). The adapter only LOGS a launch failure — it never raises — so
	-- pcall(handle.start) always reported success and the flag was never cleared.
	-- Every later call then short-circuited on the in-flight guard, freezing
	-- isInternetReachable() at false for the whole process lifetime even after the
	-- network (and the ability to launch ping) came back.
	helpers.it("a failed ping launch does not latch the probe — the next call retries", function()
		-- First attempt: hs.task.new returns nil, so no subprocess is ever launched.
		local NI = reload_network_info({
			task = { new = function(_exe, _cb, _args) return nil end },
		})

		helpers.assert_true(NI.isInternetReachable() == false,
			"a probe that never launched must report the safe default")
		helpers.assert_true(NI.hasInternetProbeResult() == false,
			"no probe result can exist when the launch failed")

		-- Swap in a working task stub WITHOUT reloading the module, so the module
		-- state (and therefore the in-flight latch) carries over from the failure.
		local reachable_out = "1 packets transmitted, 1 packets received, 0% packet loss\n"
		_G.hs.task = {
			new = function(_exe, cb, _args)
				return {
					start     = function() if cb then cb(0, reachable_out, "") end return true end,
					isRunning = function() return false end,
					terminate = function() end,
				}
			end,
		}

		-- If the latch leaked, this call returns early on the in-flight guard and
		-- the probe is never retried — the assertion below stays false forever.
		local result = NI.isInternetReachable()
		helpers.assert_true(NI.hasInternetProbeResult() == true,
			"the probe must be RETRIED after a failed launch, not blocked by a latched in-flight flag")
		helpers.assert_true(result == true,
			"the retried probe must report the now-reachable network")
	end)

	helpers.it("a failed ifconfig launch does not latch the VPN probe — the next call retries", function()
		local NI = reload_network_info({
			task = { new = function(_exe, _cb, _args) return nil end },
		})

		helpers.assert_true(NI.isVpnActive() == false,
			"a VPN probe that never launched must report the safe default")

		_G.hs.task = {
			new = function(_exe, cb, _args)
				return {
					start     = function() if cb then cb(0, "utun0: flags=8051<UP> mtu 1380\n", "") end return true end,
					isRunning = function() return false end,
					terminate = function() end,
				}
			end,
		}

		helpers.assert_true(NI.isVpnActive() == true,
			"the VPN probe must be RETRIED after a failed launch, not blocked by a latched in-flight flag")
	end)

	helpers.it("never blocks: isInternetReachable() does not throw when hs.task.new fails", function()
		local NI = reload_network_info({
			task = { new = function(_, _, _) error("task creation failed") end },
		})
		local ok, result = pcall(function() return NI.isInternetReachable() end)
		helpers.assert_true(ok, "isInternetReachable() must not throw even if the async adapter fails to spawn: "
			.. tostring(result))
		-- And it must ANSWER. A probe that failed to spawn and returned nil reads as
		-- falsy at the caller, which is the same as "no internet" — so an unlaunchable
		-- probe would look identical to a genuinely offline machine.
		helpers.assert_eq(type(result), "boolean",
			"a failed spawn must still answer a boolean, not nil")
	end)

end)
