--- core/network/engine/proxy_auth_relay.lua

--- ==============================================================================
--- MODULE: Linux Proxy Sign-In Relay Binding
--- DESCRIPTION:
--- Binds the shared relay policy (core/network/engine/proxy_auth_relay_core.lua) to the Linux
--- installation: the contract read once through the native file owner, the
--- relay executable beside the driver's launcher (bin/), the deadlines from the
--- timings registry, and an owned probe child.
---
--- FEATURES & RATIONALE:
--- 1. A relay that is not installed answers "not_installed" without a child;
---    the caller logs it and keeps the proxy as named (proxy-auth-relay.md).
--- 2. The probe child is an owned process: its exit and every handle close are
---    retained before its answer is delivered, and the start's owner cancels it.
--- 3. Logs name the outcome only: never the proxy, the origin or the token.
--- ==============================================================================

local M = {}
local Paths = require("core.fs.engine.paths")
local Reader = require("core.fs.engine.regular_file_reader")
local Json = require("core.text.engine.json")
local Timings = require("infra.timings")
local SharedRelay = require("core.network.engine.proxy_auth_relay_core")

-- The contract is about a kilobyte; a larger file is not the shipped one.
local MAX_CONTRACT_BYTES = 8192
-- The probe prints one short JSON line.
local MAX_PROBE_OUTPUT_BYTES = 4096

local initialized, policy, refusal = false, nil, nil

--- Loads and validates the shared contract exactly once.
--- @return table|nil policy, string|nil reason
function M.load()
	if initialized then return policy, refusal end
	initialized = true
	local path = Paths.shared("core/network/data/proxy_auth_relay.json")
	local file = path and Reader.open_source(path)
	if not file then refusal = "proxy-auth-relay-unavailable"; return nil, refusal end
	local bytes = file:read(MAX_CONTRACT_BYTES + 1)
	local closed = file:close()
	if type(bytes) ~= "string" or #bytes > MAX_CONTRACT_BYTES or not closed then
		refusal = "proxy-auth-relay-unavailable"
		return nil, refusal
	end
	local decoded, data = pcall(Json.decode, bytes)
	if not decoded then refusal = "proxy-auth-relay-contract-invalid"; return nil, refusal end
	policy, refusal = SharedRelay.new(data)
	return policy, refusal
end

--- The relay deadlines, from the timings registry.
--- @return table timings { dial_ms, handshake_ms, idle_ms, probe_ms }
function M.timings()
	return {
		dial_ms = Timings.ms("adapters", "proxy_relay_dial_timeout_ms"),
		handshake_ms = Timings.ms("adapters", "proxy_relay_handshake_timeout_ms"),
		idle_ms = Timings.ms("adapters", "proxy_relay_idle_timeout_ms"),
		probe_ms = Timings.ms("adapters", "proxy_relay_probe_timeout_ms"),
	}
end

--- The installed relay executable, nil when it is not installed.
--- @return string|nil path
function M.executable()
	local root = Paths.driver_root()
	if type(root) ~= "string" or root:sub(1, 1) ~= "/" then return nil end
	local path = root .. "/bin/" .. SharedRelay.EXECUTABLE_NAME
	local ok, luv = pcall(require, "luv")
	if not ok then return nil end
	local stat = luv.fs_stat(path)
	if not stat or stat.type ~= "file" or not luv.fs_access(path, "X") then return nil end
	return path
end

--- Starts one owned probe child.
--- @param upstream string Plain http relay (policy.upstream()).
--- @param authority string CONNECT authority (policy.authority()).
--- @param options table { owner, timeout_ms, authorized }
--- @param callback function fn(answer|nil, reason|nil) after the child retired.
--- @return table|nil operation, string|nil reason
function M.probe(upstream, authority, options, callback)
	local active, reason = M.load()
	if not active then return nil, reason end
	local executable = M.executable()
	if not executable then
		-- Not installed: answered by name without a child, synchronously.
		callback({ status = SharedRelay.NOT_INSTALLED }, nil)
		local done = { settled = true }
		function done.is_settled() return true end
		function done.on_settled(listener) listener(); return true end
		function done.cancel() return true end
		return done
	end
	local args = active.probe_args(upstream, authority, M.timings())
	if not args then return nil, "proxy-auth-relay-arguments-invalid" end
	local constructing, completion = true, nil
	local function deliver(result)
		callback(active.read_probe(type(result) == "table" and result.exit_code or nil,
			type(result) == "table" and result.stdout or nil))
	end
	local operation = require("core.process.adapters.owned_process").start(executable, args, {
		owner = options.owner, timeout_ms = options.timeout_ms, max_output_bytes = MAX_PROBE_OUTPUT_BYTES,
		authorized = options.authorized,
	}, function(result)
		if constructing then completion = result else deliver(result) end
	end)
	constructing = false
	if type(operation) ~= "table" then return nil, "proxy-auth-relay-probe-unavailable" end
	-- A refused start can still own handles until their close callbacks. Keep
	-- that operation and its eventual completion instead of publishing a second
	-- refusal while cleanup is pending.
	if operation.started ~= true and operation:is_settled() then
		return nil, "proxy-auth-relay-probe-unavailable"
	end
	if completion then deliver(completion) end
	return {
		is_settled = function() return operation:is_settled() == true end,
		on_settled = function(listener) return operation:on_settled(listener) end,
		cancel = function() return operation:cancel() end,
	}
end

return M
