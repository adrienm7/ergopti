--- tests/unit/modules/llm/mlx/inference/test_stream_retirement.lua

--- ==============================================================================
--- MODULE: MLX Stream Native Retirement
--- DESCRIPTION:
--- Compose the actual inference engine and ShellRunner around a native task
--- whose accepted SIGTERM completes later. An accepted signal is not proof that
--- the old curl exited or released the model's single streaming connection.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

local OWNED = {
	"app_dirs", "infra.config_paths", "infra.launcher_environment", "infra.log_folders",
	"infra.notifications", "json", "modules.llm.progressive_reveal",
	"modules.llm.api_mlx", "modules.llm.api_mlx_fetch", "modules.llm.api_mlx_discovery",
	"modules.llm.mlx_stream_retirement",
	"modules.llm.api_mlx_inference", "adapters.shell_runner", "modules.keystats",
	"infra.logger", "adapters.timer_scheduler", "adapters.http_client",
	"modules.llm.api_common", "modules.llm.parser", "modules.llm.profiles",
	"llm.prompt_builder", "llm.rewrite", "llm.parser", "llm.profile_selector",
	"adapters.file_system", "adapters.json_codec", "infra.timings",
	"infra.deferred_work", "adapters.task_environment", "diagnostics.runtime_log",
	"diagnostics.operation_reporter", "diagnostics.redact", "logger.shim",
	"infra.manifest_reader", "infra.toml.reader", "adapters.storage",
	"infra.fs_dir", "hotstrings.personal_files", "config_defaults", "lfs",
	"text_utils", "compat.utf8", "toml_codec.basic_string", "toml_codec.bom",
	"toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
}

local function with_stream(scenario)
	-- The real C lfs module publishes a global as well as its require cache.
	local previous_lfs = rawget(_G, "lfs")
	local scope_ok, scope_error = xpcall(function()
		helpers.with_stub_scope(OWNED, function()
			local f = { native = {}, timers = {}, failures = 0 }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["modules.keystats"] = {}
			package.loaded["adapters.http_client"] = { new = function() return {} end }
			package.loaded["adapters.timer_scheduler"] = {
				now = function() return 0 end,
				after = function(delay, callback)
					local handle = { timer = {}, delay = delay, callback = callback }
					f.timers[#f.timers + 1] = handle
					return handle, true
				end,
				cancel = function(handle) handle.timer = nil; return true end,
			}
			local engine = helpers.load_with_stubs("modules.llm.api_mlx_inference", {
				task = { new = function(_, done)
					local native = { running = false, signals = 0 }
					function native:start() self.running = true; return true end
					function native:isRunning() return self.running end
					function native:terminate() self.signals = self.signals + 1; return true end
					function native:complete()
						if not self.running then return end
						self.running = false
						done(15, "", "")
					end
					f.native[#f.native + 1] = native
					return native
				end },
			})
			f.shell = require("adapters.shell_runner")
			f.controller = require("modules.llm.api_mlx")
			for index = 1, 100 do
				local name, value = debug.getupvalue(f.controller.cancel_streaming, index)
				if not name then break end
				if name == "_stream" then f.stream = value; break end
			end
			assert(type(f.stream) == "table", "the controller must own its shared stream")
			engine.init({
				stream = f.stream, cancel_streaming = f.controller.cancel_streaming,
				completions_endpoint = function() return "http://127.0.0.1/v1/completions" end,
				chat_endpoint = function() return "http://127.0.0.1/v1/chat/completions" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() end, model_hf_path = function() end,
			})
			f.request = function()
				engine.post_and_parse_streaming("fixture", "", "typed context", "", 0.2, 8, 1, false,
					function() error("a timed-out stream has no valid result") end,
					function() f.failures = f.failures + 1 end, {}, function() end)
			end
			local ok, detail = xpcall(function() scenario(f) end, debug.traceback)
			for _, native in ipairs(f.native) do native:complete() end
			for _, timer in ipairs(f.timers) do
				if timer.delay > require("infra.timings").sec("llm", "stream_hard_timeout_ms") then timer.callback() end
			end
			if not ok then error(detail, 0) end
		end)
	end, debug.traceback)
	rawset(_G, "lfs", previous_lfs)
	if not scope_ok then error(scope_error, 0) end
end

helpers.describe("MLX stream termination waits for native retirement", function()
	helpers.it("retains its exact curl after the watchdog's SIGTERM is accepted", function()
		with_stream(function(f)
			f.request()
			local task = f.stream.task
			helpers.assert_eq(#f.native, 1)
			f.timers[2].callback()
			helpers.assert_eq(f.native[1].signals, 1)
			helpers.assert_eq(task.isSettled(), false, "actual ShellRunner still owns the native child")
			helpers.assert_eq(f.stream.task, task, "accepted SIGTERM must not untrack a live MLX connection")
		end)
	end)

	helpers.it("reports timeout only after its exact curl actually exits", function()
		with_stream(function(f)
			f.request()
			f.timers[2].callback()
			helpers.assert_eq(f.failures, 0, "pending native retirement is not a terminal failure yet")
			f.native[1]:complete()
			helpers.assert_eq(f.failures, 1)
			helpers.assert_eq(f.stream.task, nil)
		end)
	end)
	helpers.it("blocks a successor until explicit cancellation actually retires its curl", function()
		with_stream(function(f)
			f.request()
			local first = f.stream.task
			helpers.assert_eq(f.controller.cancel_streaming(), false)
			helpers.assert_eq(f.stream.task, first)
			f.request()
			helpers.assert_eq(#f.native, 1, "no sibling curl can overlap the pending predecessor")
			f.native[1]:complete()
			helpers.assert_eq(f.stream.task, nil, "retirement remains owned after generation revocation")
			helpers.assert_eq(f.failures, 1, "only the refused successor reports failure")
			f.request()
			helpers.assert_eq(#f.native, 2, "a fresh stream may start after exact native settlement")
			helpers.assert_eq(f.controller.cancel_streaming(), false)
			f.native[2]:complete()
			helpers.assert_eq(f.stream.task, nil)
		end)
	end)

end)
