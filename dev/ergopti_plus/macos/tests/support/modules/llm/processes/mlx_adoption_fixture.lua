--- tests/support/modules/llm/processes/mlx_adoption_fixture.lua

--- ==============================================================================
--- MODULE: MLX Diagnostic Reentry Fixture
--- DESCRIPTION:
--- Composes the actual logger and MLX manager with recording native task ports.
--- No process or signal is emitted by the controlled subprocess boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNED = {
	"infra.logger", "logger", "diagnostics.redact", "json", "app_dirs",
	"infra.log_folders", "_generated.logger_sub_files", "adapters.log_transport",
	"infra.launcher_environment", "infra.notifications", "infra.i18n",
	"infra.config_paths", "infra.text_utils", "modules.llm.api_common",
	"adapters.task_lifecycle", "adapters.shell_runner", "adapters.timer_scheduler",
	"adapters.json_codec", "modules.llm.api_mlx",
	"ui.menu.menu_llm.models_manager_mlx_server",
}

--- Runs the actual Logger sink and server lifecycle with recording native ports.
--- @param scenario function Receives the manager and its observations.
local function with_adoption(scenario)
	local saved_open, saved_execute = io.open, os.execute
	local ok, detail = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			local noop = function() end
			local state = { tasks = {}, cleanup = {}, logs = {}, callback_errors = {}, current_a = true,
				a_success = 0, a_cancel = 0, b_success = 0, b_cancel = 0 }
			package.loaded["adapters.log_transport"] = {}
			_G.hs = {}
			local Logger = require("infra.logger")
			helpers.admit_logger_privacy(Logger)
			Logger.set_level("INFO")
			Logger.set_sink(function(line)
				state.logs[#state.logs + 1] = line
				if line:find("Adopting MLX server", 1, true) and not state.observed then
					state.observed = true
					if state.on_adopt then
						local called, err = pcall(state.on_adopt)
						if not called then
							state.callback_errors[#state.callback_errors + 1] = err
							error(err, 0) -- The real logger owns observer-error containment.
						end
					end
				end
			end)
			-- Formatting, privacy and sink delivery remain real; file sinks own no disk.
			io.open = function() return nil, "controlled logger file sink unavailable" end
			os.execute = function(command)
				state.cleanup[#state.cleanup + 1] = command
				return true, "exit", 0
			end
			package.loaded["infra.notifications"] = { notify = noop }
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.config_paths"] = { get = function() return "/fixture/model.txt" end }
			package.loaded["infra.text_utils"] = { shell_quote = function(value) return "'" .. value .. "'" end }
			package.loaded["modules.llm.api_common"] = {
				protected_call = function(fn, _, ...)
					if type(fn) ~= "function" then return false end
					return pcall(fn, ...)
				end,
			}
			package.loaded["modules.llm.api_mlx"] = {
				get_port = function() return 3460 end, reset_endpoints = function() return true end,
				set_model_hf_path = noop, set_active_server_pgid = noop, mark_load_failed = noop,
			}
			package.loaded["adapters.timer_scheduler"] = {
				after = function() return { timer = {} }, true end,
				cancel = function(handle) handle.timer = nil; return true end,
			}
			package.loaded["adapters.json_codec"] = {
				decode = function() return { data = { { id = "org/Model-A" } } } end,
			}
			package.loaded["adapters.shell_runner"] = { spawn = function() error("unexpected process dispatch") end }
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, complete, stream, args)
					local task = { label = label, terminate_calls = 0, args = args, stream = stream }
					function task:start() self.running = true; return self end
					function task:isRunning() return self.running == true end
					function task:terminate() self.terminate_calls = self.terminate_calls + 1; return self end
					function task:complete(code) self.running = false; complete(code, "", "") end
					state.tasks[#state.tasks + 1] = task
					return task
				end,
				start = function(task) return task:start() == task end,
			}
			_G.hs = { execute = function() return '{"data":[{"id":"org/Model-A"}]}' end }
			local deps = { active_tasks = {} }
			local obj = { get_mlx_repo = function(model) return "org/" .. model end }
			require("ui.menu.menu_llm.models_manager_mlx_server").install({
				obj = obj, deps = deps, active_tasks_gc_root = {}, project_venv_python_escaped = "/fixture/python",
			})
			function state.start_a(guarded)
				return obj.start_server("Model-A", function() state.a_success = state.a_success + 1 end,
					function()
						state.a_cancel = state.a_cancel + 1
						state.owner_at_cancel = obj._server_lifecycle_owner
					end, guarded and { is_current = function() return state.current_a end } or nil)
			end
			function state.start_b()
				state.b_accepted = obj.start_server("Model-B", function() state.b_success = state.b_success + 1 end,
					function() state.b_cancel = state.b_cancel + 1 end)
				state.b_task = deps.active_tasks.mlx_server
				state.b_owner = obj._server_lifecycle_owner
			end
			scenario(obj, state, deps)
			Logger.set_sink(nil)
		end)
	end, debug.traceback)
	io.open, os.execute = saved_open, saved_execute
	if not ok then error(detail, 0) end
end

return with_adoption
