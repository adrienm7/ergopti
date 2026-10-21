--- tests/unit/modules/llm/streaming/test_payload_file_admission.lua

--- ==============================================================================
--- MODULE: Streaming Payload File Admission
--- DESCRIPTION:
--- Drive both real streaming request paths over controlled file refusals and
--- actual temporary files. No transport may observe an unflushed JSON payload.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"modules.llm.api_mlx_inference", "modules.llm.api_ollama", "modules.llm.api_common",
	"modules.llm.mlx_stream_retirement", "modules.llm.ollama_endpoint", "modules.llm.parser",
	"adapters.shell_runner", "adapters.timer_scheduler", "adapters.http_client", "adapters.file_system",
	"infra.logger", "infra.notifications", "infra.timings", "infra.text_utils",
	"llm.prompt_builder", "llm.rewrite", "modules.keylogger",
	"adapters.json_codec", "adapters.storage", "compat.utf8", "infra.toml.reader", "json",
	"llm.parser", "logger", "logger.shim", "text_utils", "toml_codec.basic_string",
	"toml_codec.bom", "toml_codec.key_path", "toml_codec.reader", "toml_codec.record_scanner",
	"adapters.managed_ollama_daemon", "adapters.owned_program_runner", "app_dirs", "config_defaults",
	"core.llm.managed_ollama_daemon_receipt", "core.llm.ollama_runtime_choice", "hotstrings.personal_files",
	"infra.manifest_reader", "llm.local_model_policy", "llm.profile_selector", "modules.llm.network_env",
	"modules.llm.ollama_binary", "modules.llm.ollama_server_command", "modules.llm.opaque_network_admission",
	"modules.llm.profiles", "modules.llm.progressive_reveal", "platform.remap.lease_helper",
}

local function upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if name == target then return value end
		if not name then break end
	end
	error("Missing production dependency: " .. target)
end

local function with_stream(backend, callback)
	helpers.with_stub_scope(OWNED, function()
		-- Transport, scheduling, metrics and diagnostic boundaries are irrelevant
		-- until the real request path admits its payload. Keep those ports local.
		package.loaded["modules.keylogger"] = {}
		package.loaded["adapters.file_system"] = { exists = function(path)
			local file = io.open(path, "rb"); if not file then return false end
			assert(file:close()); return true
		end, read = function(path)
			local file, err = io.open(path, "rb")
			if not file then return nil, err end
			local content = file:read("*a"); assert(file:close()); return content
		end }
		package.loaded["adapters.shell_runner"] = {}
		package.loaded["adapters.timer_scheduler"] = { now = function() return 0 end }
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end, error = function() end, done = function() end,
			callback = function(_, _, fn, ...) return pcall(fn, ...) end,
		}
		local module = helpers.load_with_stubs(backend == "mlx" and "modules.llm.api_mlx_inference" or "modules.llm.api_ollama")
		local stream = backend == "mlx" and module.post_and_parse_streaming or upvalue(module.fetch_batch, "post_and_parse_streaming")
		if backend == "mlx" then
			module.init({ stream = { generation = 0 }, cancel_streaming = function() return true end,
				completions_endpoint = function() return "http://127.0.0.1/v1/completions" end,
				chat_endpoint = function() return "http://127.0.0.1/v1/chat/completions" end,
				read_active_model_arg = function() return "fixture/model" end,
				server_model_id = function() end, model_hf_path = function() end })
		end
		local runner, scheduler = upvalue(stream, "ShellRunner"), upvalue(stream, "TimerScheduler")
		local open, remove, tmpname = io.open, os.remove, os.tmpname
		local spawn, after = runner.spawn, scheduler.after
		local h = { spawns = 0, timers = 0, failures = 0, successes = 0, writes = 0, closes = 0, paths = {}, removed = {} }
		local handles = {}
		os.tmpname = function()
			local base = tmpname()
			h.paths[#h.paths + 1] = base .. "_" .. backend .. "_stream.json"
			return base
		end
		os.remove = function(path)
			h.removed[path] = true
			return remove(path)
		end
		io.open = function(path, mode)
			if not path:match("_" .. backend .. "_stream.json$") or mode ~= "w" then return open(path, mode) end
			if h.phase == "open" then
				if h.refusal == "throw" then error("CONTROLLED_OPEN_FAILURE") end
				if h.refusal == "false" then return false, "CONTROLLED_OPEN_FAILURE" end
				return nil, "CONTROLLED_OPEN_FAILURE"
			end
			local native = assert(open(path, mode)); handles[#handles + 1] = native
			local handle = {}
			function handle:write(content)
				h.writes = h.writes + 1
				if h.phase == "write" then
					if h.refusal == "throw" then error("CONTROLLED_WRITE_FAILURE") end
					if h.refusal == "foreign" then return true end
					if h.refusal == "false" then return false, "CONTROLLED_WRITE_FAILURE" end
				return nil, "CONTROLLED_WRITE_FAILURE"
				end
				assert(native:write(content)); return self
			end
			function handle:close()
				h.closes = h.closes + 1
				local closed, err = native:close()
				if h.replace then
					local replacement = assert(open(path, "w")); assert(replacement:write("FOREIGN_REPLACEMENT")); assert(replacement:close())
				end
				if h.phase == "close" then
					if h.refusal == "throw" then error("CONTROLLED_CLOSE_FAILURE") end
					if h.refusal == "foreign" then return self end
					if h.refusal == "false" then return false, "CONTROLLED_CLOSE_FAILURE" end
				return nil, "CONTROLLED_CLOSE_FAILURE"
				end
				return closed, err
			end
			return handle
		end
		runner.spawn = function(_, args)
			h.spawns = h.spawns + 1
			for index, arg in ipairs(args) do
				if arg == "--data-binary" then
					local file = assert(open(args[index + 1]:sub(2), "rb"))
					h.payload = assert(file:read("*a")); assert(file:close())
				end
			end
			return nil, "Transport deliberately stops after payload admission"
		end
		scheduler.after = function() h.timers = h.timers + 1; return nil, false end
		function h.request()
			return pcall(stream, "fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() h.successes = h.successes + 1 end,
				function() h.failures = h.failures + 1 end, {}, function() end)
		end
		function h.read(path)
			local file = assert(open(path, "rb")); local content = assert(file:read("*a")); assert(file:close()); return content
		end
		local outcome = table.pack(xpcall(function() callback(h) end, debug.traceback))
		io.open, os.remove, os.tmpname, runner.spawn, scheduler.after = open, remove, tmpname, spawn, after
		for _, handle in ipairs(handles) do if io.type(handle) == "file" then handle:close() end end
		for _, path in ipairs(h.paths) do remove(path) end
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("streaming requires an acknowledged complete payload", function()
	for _, backend in ipairs({ "mlx", "ollama" }) do
		helpers.it(backend .. " admits the actual closed JSON bytes to transport", function()
			with_stream(backend, function(h)
				helpers.assert_true(h.request())
				helpers.assert_eq(h.writes, 1); helpers.assert_eq(h.closes, 1)
				helpers.assert_eq(h.spawns, 1)
				local payload = require("adapters.json_codec").decode(h.payload)
				helpers.assert_eq(payload.stream, true)
				helpers.assert_true(h.payload:find("typed context", 1, true) ~= nil)
			end)
		end)
		for _, phase in ipairs({ "open", "write", "close" }) do
			local refusals = phase == "open" and { "nil", "false", "throw" } or { "nil", "false", "throw", "foreign" }
			for _, refusal in ipairs(refusals) do
				helpers.it(backend .. " refuses " .. phase .. " " .. refusal .. " before transport admission", function()
					with_stream(backend, function(h)
						h.phase, h.refusal = phase, refusal
						helpers.assert_true(h.request(), "native I/O failure must reach on_fail rather than escape")
						helpers.assert_eq(h.failures, 1); helpers.assert_eq(h.successes, 0)
						helpers.assert_eq(h.spawns, 0); helpers.assert_eq(h.timers, 0)
						helpers.assert_eq(h.closes, phase == "open" and 0 or 1, "close must still run after refused writes")
						h.phase, h.refusal = nil, nil
						helpers.assert_true(h.request()); helpers.assert_eq(h.spawns, 1, "a failed file must not poison the next request")
					end)
				end)
			end
		end
		helpers.it(backend .. " preserves a replacement at the failed payload path", function()
			with_stream(backend, function(h)
				h.phase, h.refusal, h.replace = "close", "nil", true
				helpers.assert_true(h.request())
				helpers.assert_eq(h.spawns, 0); helpers.assert_eq(h.failures, 1)
				helpers.assert_eq(h.read(h.paths[1]), "FOREIGN_REPLACEMENT")
				helpers.assert_nil(h.removed[h.paths[1]], "a pathname alone cannot authorize deleting a concurrent replacement")
			end)
		end)
	end
end)
