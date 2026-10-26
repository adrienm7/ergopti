--- tests/support/modules/llm/streaming_payload_fixture.lua

--- ==============================================================================
--- MODULE: Streaming Payload File Fixture
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
		package.loaded["modules.keystats"] = {}
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
		local h = { spawns = 0, timers = 0, failures = 0, successes = 0, writes = 0, closes = 0,
			paths = {}, bases = {}, writable_paths = {}, removed = {} }
		local handles = {}
		os.tmpname = function()
			local base = tmpname()
			h.bases[#h.bases + 1] = base
			if h.on_allocation then h.on_allocation(base) end
			h.paths[#h.paths + 1] = base .. "_" .. backend .. "_stream.json"
			h.writable_paths[h.paths[#h.paths]] = true
			return base
		end
		os.remove = function(path)
			h.removed[path] = true
			return remove(path)
		end
		local filesystem = package.loaded["adapters.file_system"]
		filesystem.create_secure_temp_file = function()
			if h.allocation_refusal then return h.allocation_result, "CONTROLLED_ALLOCATION_FAILURE" end
			local path = os.tmpname()
			h.paths[#h.paths] = path
			h.writable_paths[path] = true
			return path
		end
		io.open = function(path, mode)
			if not h.writable_paths[path] or mode ~= "w" then return open(path, mode) end
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
					h.payload_path = args[index + 1]:sub(2)
					h.base_removed_at_dispatch = h.removed[h.bases[#h.bases]] == true
					if h.on_payload then h.on_payload(h.payload_path) end
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
		for _, path in ipairs(h.bases) do remove(path) end
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

--- Verifies both the native allocation identity and actual POSIX payload mode.
--- @param backend string Streaming backend whose real admission path runs.
--- @return table observed Actual file kind and permissions at transport admission.
local function assert_private_payload(backend)
	local observed, allocated
	with_stream(backend, function(h)
		local function inspect(path)
			local CommandLines = require("tests.support.command_lines")
			local quote = require("text_utils").shell_quote
			local program = "import json,os,stat,sys; s=os.lstat(sys.argv[1]); "
				.. "print(json.dumps({'permissions':stat.S_IMODE(s.st_mode),'regular':stat.S_ISREG(s.st_mode),"
				.. "'device':str(s.st_dev),'inode':str(s.st_ino)}))"
			local lines = CommandLines.read("python3 -c " .. quote(program) .. " " .. quote(path) .. " 2>&1")
			return assert(require("json").decode(table.concat(lines, "\n")))
		end
		h.on_allocation = function(path) allocated = inspect(path) end
		h.on_payload = function(path) observed = inspect(path) end
		helpers.assert_true(h.request())
		helpers.assert_eq(h.spawns, 1, "the request must admit its actual payload to transport")
		helpers.assert_eq(#h.bases, 1, "one request owns exactly one native temporary file")
		helpers.assert_eq(h.payload_path, h.bases[1], "curl must read the private file already allocated")
		helpers.assert_eq(h.base_removed_at_dispatch, false,
			"removing the private inode before transport loses its permissions and ownership")
		helpers.assert_not_nil(observed, "native metadata must be read while the payload exists")
		helpers.assert_not_nil(allocated, "the original native allocation must also be inspected")
		helpers.assert_eq(observed.device, allocated.device, "the allocation device must remain unchanged")
		helpers.assert_eq(observed.inode, allocated.inode, "the exact allocated inode must reach curl")
		helpers.assert_eq(allocated.permissions, tonumber("600", 8))
		helpers.assert_eq(allocated.regular, true)
		helpers.assert_eq(observed.regular, true)
		helpers.assert_eq(observed.permissions, tonumber("600", 8), "only the owner may read the prompt")
	end)
	return { allocated = allocated, transport = observed }
end

return { with_stream = with_stream, assert_private_payload = assert_private_payload }
