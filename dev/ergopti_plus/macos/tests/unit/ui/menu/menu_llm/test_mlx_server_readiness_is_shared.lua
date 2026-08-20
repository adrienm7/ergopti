--- tests/unit/ui/menu/menu_llm/test_mlx_server_readiness_is_shared.lua

--- ==============================================================================
--- MODULE: Regression — a duplicate start_server must join, not resolve early
--- DESCRIPTION:
--- The boot sequence dispatches an MLX requirements check twice: a primary chain
--- and a 3 s "backup". The guard between them compares a generation counter that is
--- bumped only at TERMINAL outcomes, so it asks "has the other chain FINISHED?"
--- when the question it must answer is "has the other chain STARTED?". On the MLX
--- path a terminal outcome is 60-90 s away, so at t=3 s the counter always still
--- matches and the backup always dispatches a second, concurrent check.
---
--- ROOT CAUSE ENCODED, and deliberately not at the dispatcher. The second dispatch
--- lands on start_server's reuse short-circuit, which resolved on
--- `existing:isRunning()`. That says the PROCESS is alive — not that the model is
--- loaded — so the duplicate caller's on_success fired while the first caller's
--- readiness probe was still running: sixty to ninety seconds early, with the
--- prediction path told the model was ready before its weights were resident.
---
--- The dispatcher is left alone on purpose.
--- tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua asserts
--- `#captured_checks == 2` in three places, under this exact setup; gating the
--- backup would turn all three red and its own test would be their negation. Fixing
--- the SINK is below the seam that test stubs, so a duplicate dispatch becomes
--- harmless instead of forbidden.
---
--- PROVENANCE: source invariant. start_server spawns a detached Python server and
--- drives a 120-retry readiness probe; the branch under test is chosen from live
--- hs.task state, so driving it end to end would mean simulating the whole server
--- lifecycle.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Located by the readiness marker, which is the function this fix moves state into.
local ANCHOR = "mark_server_ready"




-- ==================================================================
-- ==================================================================
-- ======= 1/ Readiness is shared, not per-invocation ===============
-- ==================================================================
-- ==================================================================

--- @return string Comment-stripped source of the MLX server mixin.
local function server_code()
	local src = helpers.read_driver_source(ANCHOR)
	helpers.assert_true(src ~= nil and src ~= "",
		"the MLX server mixin must be locatable by '" .. ANCHOR .. "'; an empty corpus "
		.. "would make every assertion below vacuous")
	return (src:gsub("%-%-[^\n]*", ""))
end


helpers.describe("MLX server: a duplicate start joins the startup in flight", function()

	helpers.it("does not resolve the reuse path on isRunning alone", function()
		local code = server_code()

		local at = code:find("obj._server_target == target_model", 1, true)
		helpers.assert_true(at ~= nil, "the reuse short-circuit must still exist")
		local branch = code:sub(at, at + 900)

		helpers.assert_true(branch:find("obj._server_ready", 1, true) ~= nil,
			"isRunning() means the PROCESS is alive, not that the model is loaded. "
			.. "Resolving on it told a duplicate caller the server was ready 60-90 s "
			.. "before its weights were resident, so readiness has to be its own state")
	end)

	helpers.it("queues a caller that arrives during startup", function()
		local code = server_code()
		local at = code:find("obj._server_target == target_model", 1, true)
		local branch = code:sub(at, at + 900)

		helpers.assert_true(branch:find("_server_waiters", 1, true) ~= nil,
			"a caller arriving before readiness must be able to wait. Dropping its "
			.. "callback instead would recreate the never-released prediction lock that "
			.. "several guards in this file exist to prevent")
	end)

	helpers.it("drains every waiter exactly once when the server becomes ready", function()
		local code = server_code()
		local at = code:find("local function " .. ANCHOR, 1, true)
		helpers.assert_true(at ~= nil, "mark_server_ready must exist")
		local body = code:sub(at, at + 700)

		helpers.assert_true(body:find("obj._server_ready = true", 1, true) ~= nil,
			"readiness must be published where a LATER call can see it")
		helpers.assert_true(body:find("obj._server_waiters = {}", 1, true) ~= nil,
			"and the queue must be cleared before the callbacks run, or a waiter added "
			.. "from inside one of them would be invoked twice")
	end)

	helpers.it("a fresh launch clears the previous readiness", function()
		local code = server_code()

		-- Without this the state would be sticky: a server terminated for a model
		-- switch would leave _server_ready = true, and the next duplicate request
		-- would resolve against a process that no longer exists.
		local at = code:find("local startup_confirmed = false", 1, true)
		helpers.assert_true(at ~= nil, "the launch path must still be findable")
		local body = code:sub(at, at + 400)
		helpers.assert_true(body:find("obj._server_ready = false", 1, true) ~= nil,
			"a fresh launch must reset readiness, or a stale true resolves a duplicate "
			.. "request against a terminated process")
	end)

	helpers.it("an adopted server counts as ready", function()
		local code = server_code()

		-- The cross-session adoption path skips the launch entirely: the weights are
		-- already resident. A duplicate request must resolve there rather than queue
		-- behind a startup that will never run.
		local at = code:find("Adopting MLX server from a previous session", 1, true)
		helpers.assert_true(at ~= nil, "the adoption path must still be findable")
		local body = code:sub(at, at + 700)
		helpers.assert_true(body:find("obj._server_ready = true", 1, true) ~= nil,
			"an adopted server is ready; queueing against it would hang every later "
			.. "caller forever, since no probe is running to drain the queue")
	end)

	helpers.it("(mlx-startup-waiter-failure) (mlx-native-callback-protection) notifies every joined caller when the shared startup fails", function()
		local module_names = {
			"infra.notifications", "infra.logger", "infra.i18n",
			"modules.llm.api_common", "adapters.task_lifecycle",
			"modules.llm.api_mlx", "ui.menu.menu_llm.models_manager_mlx_server",
		}
		local saved_modules = {}
		for _, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] end
		local saved_hs = _G.hs
		local noop = function() end
		local server_done
		local server_stream
		local server_task
		local logged_errors = {}
		local reject_probe_task = false
		local retry_timer_result = "handle"

		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.logger"] = {
			UNIFIED_LOG_FILE = "/tmp/ergopti-test.log",
			debug = noop, info = noop, warn = noop,
			error = function(...) table.insert(logged_errors, { ... }) end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["modules.llm.api_common"] = {
			protected_call = function(callback, _, ...)
				if type(callback) == "function" then return callback(...) end
			end,
		}
		package.loaded["adapters.task_lifecycle"] = {
			create = function(factory) return factory() end,
			native = function(_, path, completion, stream_or_args, args)
				return _G.hs.task.new(path, completion, stream_or_args, args)
			end,
			start = function(task) return task:start() == true end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			get_port = function() return 8080 end,
			reset_endpoints = noop,
			set_model_hf_path = noop,
			set_active_server_pgid = noop,
			mark_load_failed = noop,
		}
		_G.hs = {
			execute = function() return "" end,
			json = { decode = function() return { data = {} } end },
			timer = { doAfter = function(_, callback)
				if retry_timer_result == "false" then return false end
				if retry_timer_result == "sync" then callback(); return { callback = callback } end
				return { callback = callback }
			end },
			task = { new = function(path, completion, stream_or_args, args)
				if path == "/usr/bin/curl" and reject_probe_task then return nil end
				local task = {
					running = false,
					start = function(self) self.running = true; return true end,
					isRunning = function(self) return self.running end,
					terminate = function(self) self.running = false; return true end,
				}
				if path == "/bin/bash" and args ~= nil then
					server_task = task
					server_stream = stream_or_args
					server_done = function(code)
						task.running = false
						completion(code)
					end
				end
				return task
			end },
		}
		package.loaded["ui.menu.menu_llm.models_manager_mlx_server"] = nil

		local ok, err = pcall(function()
			local Server = require("ui.menu.menu_llm.models_manager_mlx_server")
			local obj = {
				get_mlx_repo = function() return "fixture/repo" end,
			}
			local deps = { active_tasks = {} }
			Server.install({
				obj = obj,
				deps = deps,
				project_venv_python_escaped = "/fixture/python",
				active_tasks_gc_root = {},
			})
			local success_one, success_two, cancel_one, cancel_two = 0, 0, 0, 0
			obj.start_server("fixture-model",
				function() success_one = success_one + 1 end,
				function() cancel_one = cancel_one + 1 end)
			helpers.assert_not_nil(server_task)
			helpers.assert_eq(type(server_done), "function")
			helpers.assert_eq(type(server_stream), "function")
			obj.start_server("fixture-model",
				function() success_two = success_two + 1 end,
				function() cancel_two = cancel_two + 1 end)

			-- Native hs.task callbacks swallow escaping Lua errors into the HS console.
			-- Force a dependency to throw inside the real streaming callback: the
			-- callback must contain it, emit a file-log error, terminate the task and
			-- release both the primary caller and its joined waiter exactly once.
			package.loaded["modules.llm.api_mlx"].set_active_server_pgid = function()
				error("fixture stream failure")
			end
			local stream_call_ok, continue_streaming = pcall(server_stream, nil,
				"[MLX] Server started with PID 11 PGID 22\n", "")
			helpers.assert_true(stream_call_ok,
				"an exception in a native hs.task stream callback must not escape")
			helpers.assert_eq(continue_streaming, false)
			helpers.assert_true(#logged_errors > 0,
				"the swallowed Hammerspoon exception must reach the file logger")
			helpers.assert_eq(server_task.running, false)

			server_done(1)
			server_done(1)
			helpers.assert_eq(success_one, 0)
			helpers.assert_eq(success_two, 0)
			helpers.assert_eq(cancel_one, 1)
			helpers.assert_eq(cancel_two, 1,
				"a joined caller owns a failure continuation, not only a success callback")

			-- A readiness task can fail to construct, and the scheduler used for its
			-- retry can independently refuse a handle. That two-boundary failure must
			-- still release the caller and stop the exact server task; merely relying
			-- on the global timer exception wrapper would leave the process unowned.
			reject_probe_task = true
			retry_timer_result = "false"
			local scheduler_success, scheduler_cancel = 0, 0
			obj.start_server("timer-refusal-model",
				function() scheduler_success = scheduler_success + 1 end,
				function() scheduler_cancel = scheduler_cancel + 1 end)
			helpers.assert_eq(scheduler_success, 0)
			helpers.assert_eq(scheduler_cancel, 1,
				"timer refusal must release the primary startup continuation exactly once")
			helpers.assert_not_nil(server_task)
			helpers.assert_eq(server_task.running, false,
				"the server task must not survive after its readiness scheduler is lost")
		end)

		_G.hs = saved_hs
		for _, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err) end
	end)

end)
