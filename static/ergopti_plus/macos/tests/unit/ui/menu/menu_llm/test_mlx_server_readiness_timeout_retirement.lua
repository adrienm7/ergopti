--- tests/unit/ui/menu/menu_llm/test_mlx_server_readiness_timeout_retirement.lua

--- =============================================================================
--- MODULE: MLX Readiness Timeout Retirement Regression
--- DESCRIPTION:
--- Drives the real MLX server lifecycle through all 120 failed readiness probes.
--- Once the logical startup closes, the still-running native process must enter
--- exact retirement before an identical request can be admitted. Otherwise that
--- request joins a waiter queue whose only two drains are permanently fenced.
--- =============================================================================

local helpers = require("tests.helpers")

local MODULE_NAMES = {
	"infra.notifications",
	"infra.logger",
	"infra.i18n",
	"modules.llm.api_common",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.models_manager_mlx_server",
}





-- =======================================
-- =======================================
-- ======= 1/ Timeout Retirement =========
-- =======================================
-- =======================================

helpers.describe("HS-025: MLX readiness timeout retirement", function()
	helpers.it("retires the failed owner before an identical request can join", function()
		local saved_modules = {}
		for _, name in ipairs(MODULE_NAMES) do
			saved_modules[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		local saved_hs = rawget(_G, "hs")
		local saved_os_execute = os.execute
		local ok, err = xpcall(function()
			local noop = function() end
			local timers = {}
			local server_tasks = {}

			package.loaded["infra.notifications"] = { notify = noop }
			package.loaded["infra.logger"] = {
				UNIFIED_LOG_FILE = "/tmp/ergopti-hs025.log",
				debug = noop,
				info = noop,
				warn = noop,
				error = noop,
				callback = function(_, _, callback, ...)
					return xpcall(callback, debug.traceback, ...)
				end,
			}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["modules.llm.api_common"] = {
				protected_call = function(callback, _, ...)
					if type(callback) ~= "function" then return true, nil end
					return xpcall(callback, debug.traceback, ...)
				end,
			}
			package.loaded["modules.llm.api_mlx"] = {
				get_port = function() return 8080 end,
				reset_endpoints = function() return true end,
				set_model_hf_path = noop,
				set_active_server_pgid = noop,
				mark_load_failed = noop,
			}

			package.loaded["adapters.timer_scheduler"] = {
				after = function(delay, callback)
					local handle = {
						delay = delay,
						callback = callback,
						active = true,
					}
					timers[#timers + 1] = handle
					return handle, true
				end,
				cancel = function(handle)
					if type(handle) == "table" then handle.active = false end
					return true
				end,
				onSettled = function(_, callback)
					callback()
					return true
				end,
			}

			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, on_done, stream_or_args, args)
					local task = {
						label = label,
						running = false,
						terminate_calls = 0,
						on_done = on_done,
						on_chunk = args ~= nil and stream_or_args or nil,
					}
					function task:start()
						self.running = true
						if self.label == "MLX readiness probe" then
							self.running = false
							self.on_done(1, "", "")
						end
						return true
					end
					function task:isRunning() return self.running end
					function task:terminate()
						self.terminate_calls = self.terminate_calls + 1
						if self.label == "MLX server launch" and self.terminate_calls == 1 then
							return false
						end
						return self
					end
					function task:complete(code)
						self.running = false
						self.on_done(code or 15, "", "")
					end
					function task:stream(stdout, stderr)
						return self.on_chunk and self.on_chunk(self, stdout or "", stderr or "")
					end
					if label == "MLX server launch" then
						server_tasks[#server_tasks + 1] = task
					end
					return task
				end,
				start = function(task) return task:start() == true end,
			}

			_G.hs = {
				execute = function() return "" end,
				json = { decode = function() return { data = {} } end },
			}
			os.execute = function() return true, "exit", 0 end

			local function pump_one_timer()
				for _, handle in ipairs(timers) do
					if handle.active then
						handle.active = false
						handle.callback()
						return true
					end
				end
				return false
			end

			local obj = {
				get_mlx_repo = function(model) return "fixture/" .. tostring(model) end,
			}
			local deps = { active_tasks = {} }
			require("ui.menu.menu_llm.models_manager_mlx_server").install({
				obj = obj,
				deps = deps,
				project_venv_python_escaped = "/fixture/python",
				active_tasks_gc_root = {},
			})

			local first_cancellations = 0
			helpers.assert_eq(obj.start_server("same-model", noop, function()
				first_cancellations = first_cancellations + 1
			end), true)
			helpers.assert_eq(#server_tasks, 1)
			for tick = 1, 120 do
				helpers.assert_true(pump_one_timer(),
					"readiness retry " .. tostring(tick) .. " must remain observable")
			end
			helpers.assert_eq(first_cancellations, 1,
				"the timed-out primary request must receive one terminal")
			helpers.assert_eq(server_tasks[1].terminate_calls, 1,
				"timeout must immediately retire the exact native owner")

			local second_successes = 0
			local second_cancellations = 0
			helpers.assert_eq(obj.start_server("same-model", function()
				second_successes = second_successes + 1
			end, function()
				second_cancellations = second_cancellations + 1
			end), true)
			helpers.assert_eq(#(obj._server_waiters or {}), 0,
				"an identical retry must not join a startup whose terminal gate is closed")
			helpers.assert_eq(server_tasks[1].terminate_calls, 2,
				"an identical retry must join the existing retirement signal")
			helpers.assert_eq(second_successes, 0)
			helpers.assert_eq(second_cancellations, 0)

			server_tasks[1]:complete(15)
			helpers.assert_eq(#server_tasks, 2,
				"exact predecessor settlement must launch the retained identical retry")
			server_tasks[2]:stream("Application startup complete\n", "")
			helpers.assert_eq(second_successes, 1)
			helpers.assert_eq(second_cancellations, 0)
			helpers.assert_eq(obj._server_ready, true)
		end, debug.traceback)

		os.execute = saved_os_execute
		_G.hs = saved_hs
		for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err, 0) end
	end)
end)
