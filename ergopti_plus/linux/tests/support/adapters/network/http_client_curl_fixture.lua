--- tests/support/adapters/network/http_client_curl_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_http_client_curl
--- DESCRIPTION:
--- Prelude shared by the test_http_client_curl_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates the minimum libuv process/pipe surface used by HttpClient.
--- @param config table|nil
--- @return table fake, table state
local function fake_luv(config)
	local options = config or {}
	local state = { groups = {}, probes = {}, timer_starts = {}, kills = {}, handles = {}, requests = {}, closes = {}, refused_closes = {},
		descriptors = {}, descriptor_closes = {}, identities = {} }
	local fake = {}
	local function refused(receipt)
		if receipt == "throw" then error("SIMULATED close refusal") end
		if receipt == "false" then return false end
		return nil
	end

	local function handle(kind)
		if options.allocation_nil_at == #state.handles + 1 then return nil end
		if options.allocation_failure_at == #state.handles + 1 then error("allocation refused") end
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.new_pipe() return handle("pipe") end
	function fake.update_time() end -- native void-style clock refresh
	function fake.pipe()
		if options.body_pipe_failure then return nil, "pipe refused" end
		local read, write = 100 + #state.descriptors, 101 + #state.descriptors
		state.descriptors[#state.descriptors + 1] = read
		state.descriptors[#state.descriptors + 1] = write
		state.identities[read] = { dev = 1, ino = read, type = "fifo" }
		state.identities[write] = { dev = 1, ino = read, type = "fifo" }
		return { read = read, write = write }
	end
	function fake.pipe_open(pipe, descriptor)
		state.first_body_handle = state.first_body_handle or pipe
		if options.body_attach_failure then return nil, "attachment refused" end
		pipe.descriptor = descriptor
		state.body_pipe = pipe
		return 0
	end
	function fake.fs_close(descriptor)
		state.descriptor_closes[#state.descriptor_closes + 1] = descriptor
		if options.raw_close_receipt and not state.allow_closes then
			if options.close_after_retirement then
				state.identities[descriptor] = options.reuse_descriptor and { dev = 9, ino = 99, type = "file" } or nil
			end
			return refused(options.raw_close_receipt)
		end
		state.identities[descriptor] = nil
		return true
	end
	function fake.fs_fstat(descriptor)
		if options.body_metadata_failure and not state.allow_metadata then return nil, "SIMULATED metadata failure", "EIO" end
		if state.identities[descriptor] then return state.identities[descriptor] end
		return nil, "descriptor absent", "EBADF"
	end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		state.timer_starts[#state.timer_starts + 1] = { timer = timer, timeout = timeout_ms, repeat_ms = repeat_ms, callback = callback }
		if options.timer_failure or (repeat_ms > 0 and state.monitor_refused) then return nil, "timer refused" end
		timer.stopped = false
		timer.timeout_ms = timeout_ms
		timer.repeat_ms = repeat_ms
		timer.callback = callback
		return true
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback) pipe.read_callback = callback; return true end
	function fake.write(pipe, data, callback)
		if pipe == state.body_pipe and options.body_write_failure then return nil, "write refused" end
		pipe.written = (pipe.written or "") .. data
		if pipe == state.body_pipe then state.body = pipe.written else state.config = pipe.written end
		if pipe == state.body_pipe and options.defer_body_write then state.body_written = callback; return true end
		if callback then callback(nil) end
		return true
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value, callback)
		if options.refused_close_callback and not state.allow_closes then
			state.refused_closes[#state.refused_closes + 1] = callback
			if options.refused_close_sync then callback() end
			if options.refused_close_callback == "throw" then error("close refused") end
			if options.refused_close_callback == "false" then return false end
			return nil, "close refused"
		end
		if value == state.first_body_handle and options.body_handle_close_receipt and not state.allow_closes then
			return refused(options.body_handle_close_receipt)
		end
		if options.close_failure and not state.allow_closes then return nil, "close refused" end
		if value.kind == "timer" and state.monitor_close_refused then return nil, "monitor close refused" end
		value.closing = true
		if value.descriptor then
			state.descriptor_closes[#state.descriptor_closes + 1] = value.descriptor
			state.identities[value.descriptor] = nil
			value.descriptor = nil
		end
		if callback then
			state.closes[#state.closes + 1] = { handle = value, callback = callback }
			if not options.defer_close then callback() end
		end
	end
	function state.ack_closes()
		for _, receipt in ipairs(state.closes) do
			if not receipt.acknowledged then
				receipt.acknowledged = true
				receipt.callback()
			end
		end
	end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		if signal == 0 then
			state.probes[#state.probes + 1] = { pid = pid, signal = signal }
			if state.probe_mode == "throw" then error("probe refused") end
			if state.probe_mode == "false" then return false end
			if state.probe_mode == "nil" then return nil end
			if state.probe_mode == "text-only" then return nil, "ESRCH: no such process" end
			if state.probe_mode == "unknown-code" then return nil, "probe refused", "EPERM" end
			if state.groups[-pid] == false then return nil, "ESRCH: no such process", "ESRCH" end
			return true
		end
		if options.kill_missing then return nil, "ESRCH: no such process", "ESRCH" end
		if options.kill_failure and not state.allow_kills then return nil, "EPERM: operation not permitted", "EPERM" end
		return true
	end
	function fake.spawn(command, options, callback)
		if config and config.spawn_failure then return nil, "EACCES", "permission denied" end
		local pid = 4320 + #state.requests + 1
		state.groups[pid] = true
		state.command = command
		state.options = options
		state.exit_callback = callback
		state.process = handle("process")
		state.requests[#state.requests + 1] = {
			options = options,
			exit_callback = callback,
			process = state.process,
			pid = pid,
		}
		return state.process, pid
	end

	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.stderr(chunk) state.options.stdio[3].read_callback(nil, chunk) end
	function state.exit(code, signal)
		if not options.descendants_alive then state.groups[state.requests[#state.requests].pid] = false end
		state.exit_callback(code or 0, signal or 0)
	end
	function state.complete(code)
		state.stdout(nil)
		state.stderr(nil)
		state.exit(code or 0)
	end
	function state.complete_request(index, stdout_text, code)
		local request = assert(state.requests[index], "unknown fake request")
		if stdout_text ~= nil then request.options.stdio[2].read_callback(nil, stdout_text) end
		request.options.stdio[2].read_callback(nil, nil)
		request.options.stdio[3].read_callback(nil, nil)
		if not options.descendants_alive then state.groups[request.pid] = false end
		request.exit_callback(code or 0, 0)
	end
	return fake, state
end

--- Loads a fresh client against one fake libuv instance.
--- @param config table|nil
--- @return table client, table state
local function fresh_client(config)
	local fake, state = fake_luv(config)
	local previous_luv = package.loaded["luv"]
	local previous_client = package.loaded["adapters.curl_http_client"]
	package.loaded["luv"] = fake
	package.loaded["adapters.curl_http_client"] = nil
	local client = require("adapters.curl_http_client")
	package.loaded["luv"] = previous_luv
	package.loaded["adapters.curl_http_client"] = previous_client
	return client, state
end

--- Loads a fresh file digest adapter against one fake libuv instance.
--- @param config table|nil
--- @return table digest, table state
local function fresh_digest(config)
	local fake, state = fake_luv(config)
	local previous_luv = package.loaded["luv"]
	local previous_digest = package.loaded["adapters.file_digest"]
	package.loaded["luv"] = fake
	package.loaded["adapters.file_digest"] = nil
	local digest = require("adapters.file_digest")
	package.loaded["luv"] = previous_luv
	package.loaded["adapters.file_digest"] = previous_digest
	return digest, state
end

-- Append these independent controls to the exact preserved native HTTP suite.
-- Its existing fake_luv/fresh_client helpers are explicit model ports, not
-- production transport overrides. This file is inert and has not run.

local EXECUTABLE_IDENTITY = { device = 42, inode = 123, size = 456,
	mtime_sec = 100, mtime_nsec = 200, ctime_sec = 300, ctime_nsec = 400 }

-- Independent native file observation port with fixed, manually chosen facts.
local function private_client(config)
	local options = config or {}
	local fake, state = fake_luv(options)
	state.stat_calls = {}
	function fake.fs_stat(path)
		state.stat_calls[#state.stat_calls + 1] = path
		if options.stat_case == "missing" then return nil, "SIMULATED missing file" end
		if options.stat_case == "throw" then error("SIMULATED stat refusal") end
		local stat = { dev = 42, ino = options.stat_case == "changed" and 124 or 123, size = 456,
			mtime = { sec = 100, nsec = 200 }, ctime = { sec = 300, nsec = 400 } }
		if options.stat_case == "error-ack" then return stat, "SIMULATED EIO", "EIO" end
		if options.stat_case == "status-ack" then return stat, nil, "EINVAL" end
		return stat
	end
	local previous_luv, previous_client = package.loaded["luv"], package.loaded["adapters.curl_http_client"]
	package.loaded["luv"], package.loaded["adapters.curl_http_client"] = fake, nil
	local client = require("adapters.curl_http_client")
	package.loaded["luv"], package.loaded["adapters.curl_http_client"] = previous_luv, previous_client
	return client, state
end

-- Append to the byte-preserved foreign owner suite behind its eight loader
-- substitutions and exact 28 original additive controls. No original body,
-- expectation, native BodyPipe/Timer source or public assertion is changed.
local ExactPorts = require("tests.support.exact_identity_ports")

local function exact_core_client(config)
	local options = config or {}
	local fake, state = fake_luv(options)
	local native, fd_state = ExactPorts.new(options.identity or {})
	for name, value in pairs(native) do
		if name == "fs_fstat" or name == "fs_close" then
			local original = fake[name]
			fake[name] = function(fd, ...)
				if fd_state.descriptors[fd] then return value(fd, ...) end
				return original(fd, ...)
			end
		else fake[name] = value end
	end
	if options.identity and options.identity.missing_constants then fake.constants = nil end
	if options.identity and options.identity.missing_port then fake[options.identity.missing_port] = nil end
	state.fd_state = fd_state
	local exact_module = require("infra.curl_identity")
	local previous_identity = package.loaded["infra.curl_identity"]
	if options.constructor_throw then
		package.loaded["infra.curl_identity"] = { copy = exact_module.copy, equal = exact_module.equal,
			new = function() error("independent constructor refusal") end }
	end
	local previous_luv, previous_client = package.loaded.luv, package.loaded["adapters.curl_http_client"]
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = fake, nil
	local loaded, client = pcall(require, "adapters.curl_http_client")
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = previous_luv, previous_client
	package.loaded["infra.curl_identity"] = previous_identity
	if not loaded then error(client) end
	return client, state
end

local function exact_options(owner, inode)
	return { owner = owner or "exact-native", method = "GET", buffered = true, timeout_ms = 1000,
		proxy_selection = { mode = "selected", proxy = "http://first.invalid:81", bypass = "environment" },
		curl_executable = "/independent/bin/curl", curl_executable_identity_exact = ExactPorts.identity(inode),
		proxy_metrics_available = true }
end

local function native_write_out(state)
	local field, count = nil, 0
	for index, value in ipairs(state.options.args) do
		if value == "--write-out" then field, count = state.options.args[index + 1], count + 1 end
	end
	helpers.assert_eq(count, 1, "Exactly one native write-out field must be admitted")
	helpers.assert_true(type(field) == "string" and field ~= "", "Native write-out field must be nonempty text")
	return field
end

--- Independent owned-group regressions: expected group absence is authored here,
--- never regenerated from the implementation. These are native-port doubles.

local function retired_leader_with_live_descendant(config)
	config = config or {}
	config.descendants_alive = true
	config.defer_close = true
	local client, state = fresh_client(config)
	local calls = 0
	local operation = client.get_owned("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt", timeout_ms = 1500 }, function() calls = calls + 1 end)
	return client, state, operation, function() return calls end
end

local function complete_owned_leader(state)
	state.complete_request(1, '[]\nERGOPTI_HTTP_STATUS:200\n')
	state.ack_closes()
end

local function nonzero_signals(state)
	local count = 0
	for _, receipt in ipairs(state.kills) do if receipt.signal ~= 0 then count = count + 1 end end
	return count
end

local function assert_successor_blocked(client, state)
	local successor = client.get_owned("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt" }, function() end)
	helpers.assert_eq(successor.started, false)
	helpers.assert_true(successor:is_settled(), "refusal acquires no physical work")
	helpers.assert_eq(client.get("http://127.0.0.1:9000/models", {},
		{ owner = "group-receipt" }, function() end), false)
	helpers.assert_eq(#state.requests, 1, "both APIs must preserve the pending group owner")
end

--- Independent source-capability cases. Expected admission/delivery decisions
--- are authored here, never generated from the adapter. All native ports below
--- are controlled doubles; these cases are not native installation evidence.

local function authorizer_client(config, hook)
	local fake, state = fake_luv(config)
	if hook then hook(fake, state) end
	local previous_luv, previous_client = package.loaded["luv"], package.loaded["adapters.curl_http_client"]
	package.loaded["luv"], package.loaded["adapters.curl_http_client"] = fake, nil
	local client = require("adapters.curl_http_client")
	package.loaded["luv"], package.loaded["adapters.curl_http_client"] = previous_luv, previous_client
	return client, state
end

-- Append after the entire preserved owner suite and exact identity controls.
-- Independent literal native stdout/stderr inputs; original assertions unchanged.
local function redirect_engine_client(config)
	local fake, state = fake_luv(config or {})
	local saved_luv, saved_core = package.loaded.luv, package.loaded["adapters.curl_http_client"]
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = fake, nil
	local loaded, client = pcall(require, "adapters.curl_http_client")
	package.loaded.luv, package.loaded["adapters.curl_http_client"] = saved_luv, saved_core
	if not loaded then error(client) end
	return client, state
end

local function redirect_options()
	return { owner = "native-single-hop", method = "GET", buffered = true, timeout_ms = 1000,
		proxy_selection = { mode = "environment" }, single_hop_redirect = true,
		single_hop_receipt_bytes = 32768, single_hop_url_bytes = 8192, follow_redirects = true }
end

local GOOD_REDIRECT = '\nERGOPTI_GET_REDIRECT_JSON:\nhttps://updates.example/start\nhttps://cdn.example/final\n{"http_code":302,"exitcode":0,"num_redirects":0,"url_effective":"https://updates.example/start","redirect_url":"https://cdn.example/final"}\n\nERGOPTI_PROXY_STATUS:200:?\n'

local invalid_preflight = {
	{ name = "NUL compare path", options = { etag_compare = "/owned/etag\0private-suffix" } },
	{ name = "NUL save path", options = { etag_save = "/owned/etag\0private-suffix" } },
	{ name = "NUL download path", download = "/owned/download\0private-suffix" },
	{ name = "numeric compare path", options = { etag_compare = 42 } },
	{ name = "numeric save path", options = { etag_save = 42 } },
	{ name = "mixed header names", headers = { [1] = "literal", ["X-Native"] = "literal" } },
	{ name = "numeric URL", url = 42 },
	{ name = "empty URL", url = "" },
	{ name = "raising header value", headers = { ["X-Native"] = setmetatable({}, {
		__tostring = function() error("Synthetic private header value") end,
	}) } },
}

local sensitive_headers = { "Api-Key", "Authorization", "Cookie", "Cookie2", "Proxy-Authorization", "X-Api-Key", "X-Goog-Api-Key" }

return {
	helpers = helpers,
	fake_luv = fake_luv,
	fresh_client = fresh_client,
	fresh_digest = fresh_digest,
	EXECUTABLE_IDENTITY = EXECUTABLE_IDENTITY,
	private_client = private_client,
	ExactPorts = ExactPorts,
	exact_core_client = exact_core_client,
	exact_options = exact_options,
	native_write_out = native_write_out,
	retired_leader_with_live_descendant = retired_leader_with_live_descendant,
	complete_owned_leader = complete_owned_leader,
	nonzero_signals = nonzero_signals,
	assert_successor_blocked = assert_successor_blocked,
	authorizer_client = authorizer_client,
	redirect_engine_client = redirect_engine_client,
	redirect_options = redirect_options,
	GOOD_REDIRECT = GOOD_REDIRECT,
	invalid_preflight = invalid_preflight,
	sensitive_headers = sensitive_headers,
}
