--- tests/support/modules/llm/stream_payload_cleanup_fixture.lua

--- Drives public stream fetches with real payload files, parser and ShellRunner.
local helpers = require("tests.helpers")
local M = {}

local OWNED = {
	"modules.llm", "modules.llm.api_mlx_fetch", "modules.llm.stream_payload_cleanup",
	"modules.llm.api_mlx_inference", "modules.llm.api_ollama", "modules.llm.api_common",
	"modules.llm.mlx_stream_retirement", "modules.llm.ollama_endpoint", "modules.llm.parser",
	"adapters.shell_runner", "adapters.timer_scheduler", "adapters.http_client", "adapters.file_system",
	"infra.logger", "infra.notifications", "infra.timings", "infra.text_utils",
	"llm.prompt_builder", "llm.rewrite", "modules.keystats",
	"adapters.json_codec", "adapters.storage", "compat.utf8", "infra.toml.reader", "json",
	"llm.parser", "logger", "logger.shim", "text_utils", "toml_codec.basic_string",
	"toml_codec.bom", "toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
	"adapters.managed_ollama_daemon", "adapters.owned_program_runner", "app_dirs", "config_defaults",
	"core.llm.managed_ollama_daemon_receipt", "core.llm.ollama_runtime_choice", "hotstrings.personal_files",
	"infra.manifest_reader", "llm.local_model_policy", "llm.profile_selector", "modules.llm.network_env",
	"modules.llm.ollama_binary", "modules.llm.ollama_server_command", "modules.llm.opaque_network_admission",
	"modules.llm.profiles", "modules.llm.progressive_reveal", "platform.remap.lease_helper",
}


--- Runs one backend with owned native task, timer and file refusal boundaries.
--- @param backend string Ollama or MLX provider.
--- @param callback function Assertions over the public request fixture.
function M.with_stream(backend, callback)
	helpers.with_stub_scope(OWNED, function()
		local h = { tasks = {}, timers = {}, bases = {}, payloads = {}, denied = {}, attempts = {},
			errors = {}, successes = 0, failures = 0, allocations = 0 }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) h.errors[#h.errors + 1] = string.format(message, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["modules.keystats"] = {}
		local defaults_file = assert(io.open(helpers.shared("modules/llm/defaults.json"), "rb"))
		local defaults_raw = assert(defaults_file:read("*a")); assert(defaults_file:close())
		local defaults = assert(require("json").decode(defaults_raw))
		package.loaded["modules.llm"] = { DEFAULT_STATE = defaults }
		local scheduler = { now = function() return 0 end }
		function scheduler.after(delay, callback_fn)
			local timer = { delay = delay, callback = callback_fn, active = true, timer = {} }
			h.timers[#h.timers + 1] = timer
			if h.refuse_watchdog and #h.timers == 2 then return timer, false end
			return timer, true
		end
		function scheduler.cancel(timer) timer.active = false; timer.callback = nil; return true end
		package.loaded["adapters.timer_scheduler"] = scheduler
		local api, ctx
		if backend == "ollama" then
			api = helpers.load_with_stubs("modules.llm.api_ollama")
		else
			local inference = helpers.load_with_stubs("modules.llm.api_mlx_inference")
			local retirement = require("modules.llm.mlx_stream_retirement")
			ctx = { stream = { generation = 0 },
				completions_endpoint = function() return "http://127.0.0.1/v1/completions" end,
				chat_endpoint = function() return "http://127.0.0.1/v1/chat/completions" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() end, model_hf_path = function() end }
			function ctx.cancel_streaming()
				ctx.stream.generation = ctx.stream.generation + 1
				if ctx.stream.timeout then scheduler.cancel(ctx.stream.timeout); ctx.stream.timeout = nil end
				if not ctx.stream.task then return true end
				return retirement.cancel(ctx.stream, ctx.stream.task)
			end
			inference.init(ctx)
			api = require("modules.llm.api_mlx_fetch")
			api.init({ post_and_parse = inference.post_and_parse,
				post_and_parse_streaming = inference.post_and_parse_streaming,
				dedup_enabled = inference.DEDUPLICATION_ENABLED })
		end
		local native_new, native_open, native_remove, native_tmpname = hs.task.new, io.open, os.remove, os.tmpname
		local open_handles = {}
		os.tmpname = function()
			local base = native_tmpname()
			h.bases[#h.bases + 1] = base
			h.allocations = h.allocations + 1
			return base
		end
		os.remove = function(path)
			h.attempts[path] = (h.attempts[path] or 0) + 1
			if h.denied[path] then return nil, "PRIVATE_PATH: Permission denied", 13 end
			return native_remove(path)
		end
		io.open = function(path, mode)
			if not h.refuse_writer or mode ~= "w" then return native_open(path, mode) end
			local file = assert(native_open(path, mode)); open_handles[#open_handles + 1] = file
			local wrapper = {}
			function wrapper:write() return nil, "controlled writer refusal" end
			function wrapper:close()
				assert(file:close())
				local replacement = assert(native_open(path, "w"))
				assert(replacement:write("FOREIGN_REPLACEMENT")); assert(replacement:close())
				h.failed_writer_path = path
				return true
			end
			return wrapper
		end
		hs.task.new = function(_, done, chunk, args)
			local environment = { HOME = "/Users/synthetic" }
			local task = { running = false, done = done, chunk = chunk }
			for index, argument in ipairs(args) do
				if argument == "--data-binary" then
					task.payload = args[index + 1]:sub(2)
					h.payloads[#h.payloads + 1] = task.payload
					if h.deny_at_spawn then h.denied[task.payload] = true end
				end
			end
			if h.refuse_creation then return nil end
			function task:environment() return environment end
			function task:setEnvironment(value) environment = value; return self end
			function task:isRunning() return self.running end
			function task:start() self.running = true; if h.refuse_start then return false end; return self end
			function task:terminate() return self end
			function task:complete(code, remaining)
				self.running = false
				return self.done(code or 0, remaining or "", "")
			end
			h.tasks[#h.tasks + 1] = task
			return task
		end
		local wire = backend == "ollama"
			and '{"message":{"content":" and a useful continuation"},"done":true}\n'
			or 'data: {"choices":[{"delta":{"content":" and a useful continuation"}}]}\n\ndata: [DONE]\n\n'
		function h.request()
			return api.fetch_batch("typed context", "", "fixture-model", 0.2, 8, 1,
				{ batch = false, system_single = "Continue the text." },
				function() h.successes = h.successes + 1 end,
				function() h.failures = h.failures + 1 end,
				function() return 1 end, true, function() end)
		end
		function h.complete(index, code)
			return h.tasks[index]:complete(code or 0, wire)
		end
		function h.cancel()
			if backend == "ollama" then return api.cancel_streaming() end
			return ctx.cancel_streaming()
		end
		function h.fire(timer)
			local fn = assert(timer.callback, "the exact timer must still be active")
			timer.active, timer.callback = false, nil
			return fn()
		end
		function h.read(path)
			local file = native_open(path, "rb"); if not file then return nil end
			local bytes = assert(file:read("a")); assert(file:close()); return bytes
		end
		function h.replace(path)
			local file = assert(native_open(path, "w")); assert(file:write("NEW_OWNED_REPLACEMENT")); assert(file:close())
		end
		local outcome = table.pack(xpcall(function() callback(h) end, debug.traceback))
		-- Native ports remain owned until every controlled task is retired.
		h.denied, h.refuse_start, h.refuse_creation, h.refuse_writer = {}, false, false, false
		h.cancel()
		for _, task in ipairs(h.tasks) do if task.running then task:complete(15) end end
		hs.task.new, io.open, os.remove, os.tmpname = native_new, native_open, native_remove, native_tmpname
		for _, file in ipairs(open_handles) do if io.type(file) == "file" then assert(file:close()) end end
		for _, path in ipairs(h.payloads) do native_remove(path) end
		if h.failed_writer_path then native_remove(h.failed_writer_path) end
		for _, path in ipairs(h.bases) do native_remove(path) end
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

return M
