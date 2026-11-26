--- core/network/adapters/managed_http_worker.lua

--- ==============================================================================
--- MODULE: Managed HTTP Worker Transport (macOS)
--- DESCRIPTION:
--- An HTTP GET transport with the http_client port's get(url, headers,
--- callback) contract, carried by the launcher's native HTTP worker
--- (ErgoptiPlus --managed-http-worker, ManagedHTTPWorker.swift) instead of
--- hs.http. The worker resolves the system proxy route (PAC, WPAD) and the
--- certificate trust itself, and names a failed transfer with a closed reason
--- it derives from the NSURLSession and CFNetwork error codes.
---
--- FEATURES & RATIONALE:
--- 1. Native evidence for a failed check (UPD-13): hs.http answers a transport
---    failure with status -1 and a localized sentence, which the managed-network
---    contract may not interpret. A failed result here carries the receipt the
---    worker's reason proves (core/network/engine/managed_http_protocol.lua).
--- 2. Binary-safe output: the worker writes length-prefixed binary frames, and
---    hs.task hands stdout over as text, so the frames go to a private file
---    the shell redirects, read back whole once the worker has exited.
--- 3. Bounded by the worker: its watchdog ends the process at the request's
---    budget (exit 75) and when its parent goes away, so no Lua timer races it.
--- 4. One request, one process: redirects are not followed (the worker hands
---    a 3xx back as an answer), the request asks for identity coding (the
---    worker refuses a decoded body it cannot present as raw bytes).
--- ==============================================================================

local Logger = require("core.logger.engine.logger")
local Protocol = require("core.network.engine.managed_http_protocol")

local M = {}

local LOG = "core.network.adapters.managed_http_worker"

-- The launcher role this transport runs
M.FLAG = "--managed-http-worker"

-- The shell only redirects the worker's stdout to the private file; exec keeps
-- Hammerspoon as the worker's parent, which its watchdog follows
M.SCRIPT = 'exec "$1" "$2" "$3" "$4" > "$5"'

-- Far above the GitHub release list (about 6 MB): a larger output is refused
-- whole rather than truncated into a list it never was
M.MAXIMUM_OUTPUT_BYTES = 64 * 1024 * 1024


-- Test seams.
M._resolve = function() return require("platform.remap.lease_helper").resolve() end
M._spawn = function(...) return require("core.process.adapters.shell_runner").spawn(...) end
M._tmpname = os.tmpname
M._read = function(path)
	local handle, open_error = io.open(path, "rb")
	if not handle then return nil, tostring(open_error) end
	local bytes = handle:read(M.MAXIMUM_OUTPUT_BYTES + 1)
	handle:close()
	if bytes == nil then return "" end
	if #bytes > M.MAXIMUM_OUTPUT_BYTES then return nil, "the worker output exceeds its bound" end
	return bytes
end
M._remove = os.remove

--- The caller's headers with the identity coding the worker requires.
--- @param headers table|nil Name → value.
--- @return table|nil headers
--- @return string|nil error
local function request_headers(headers)
	local copy = {}
	for name, value in pairs(headers or {}) do
		if type(name) == "string" and name:lower() == "accept-encoding" then
			return nil, "the worker owns the request's content coding"
		end
		copy[name] = value
	end
	-- The only content coding ManagedHTTPSession accepts: it refuses a body
	-- NSURLSession decoded, which it could not hand over as the raw bytes
	copy["Accept-Encoding"] = "identity"
	return copy
end

--- Removes the worker's output file; a refusal is logged, never hidden.
--- @param path string
local function discard(path)
	local ok, removed, remove_error = pcall(M._remove, path)
	if not ok or not removed then
		Logger.error(LOG, "The worker output file %s could not be removed: %s.", path,
			tostring(ok and remove_error or removed))
	end
end

--- Creates one transport.
--- @param options table { timeout_sec = integer }: the request's budget and
---   idle bound, in whole seconds.
--- @return table client { get(url, headers, callback(result)) -> boolean }
function M.new(options)
	local seconds = type(options) == "table" and options.timeout_sec or nil
	if math.type(seconds) ~= "integer" or seconds <= 0 then
		error("the managed HTTP worker transport needs a whole number of seconds", 2)
	end
	local client = {}

	--- Sends one GET through the worker and answers once, with the http_client
	--- result shape plus failure_receipt on a failed transfer.
	--- @param url string Absolute https URL.
	--- @param headers table|nil Name → value.
	--- @param callback function fn(result).
	--- @return boolean dispatched
	function client.get(url, headers, callback)
		if type(callback) ~= "function" then error("the managed HTTP worker needs a callback", 2) end
		local admitted, header_error = request_headers(headers)
		local request, request_error = nil, header_error
		if admitted then request, request_error = Protocol.encode_request(url, admitted, seconds) end
		if not request then
			Logger.error(LOG, "The managed HTTP request was refused: %s.", tostring(request_error))
			return false
		end
		local launcher, resolve_error = M._resolve()
		if type(launcher) ~= "string" then
			Logger.error(LOG, "The managed HTTP worker is unavailable: %s.", tostring(resolve_error))
			return false
		end
		local named, path = pcall(M._tmpname)
		if not named or type(path) ~= "string" or path == "" then
			Logger.error(LOG, "The managed HTTP worker has no private output file: %s.", tostring(path))
			return false
		end
		local settled = false
		local bound = tostring(seconds)
		local handle = M._spawn("/bin/sh", { "-c", M.SCRIPT, "managed-http-worker", launcher, M.FLAG, bound, bound, path },
			function(exit_code)
				if settled then return end
				settled = true
				local bytes, read_error = M._read(path)
				discard(path)
				local result = bytes and Protocol.result(exit_code, bytes) or {
					ok = false, status = 0, headers = {},
					error = "the worker output could not be read: " .. tostring(read_error),
				}
				if result.status == 0 then
					Logger.warn(LOG, "The managed HTTP request failed: %s.", tostring(result.error))
				end
				local ok, callback_error = xpcall(callback, debug.traceback, result)
				if not ok then Logger.error(LOG, "The managed HTTP callback raised: %s", tostring(callback_error)) end
			end, nil, nil, true)
		if handle.isSettled() or not handle.set_input(request) or not handle.start() then
			settled = true
			pcall(handle.terminate)
			discard(path)
			Logger.error(LOG, "The managed HTTP worker could not start.")
			return false
		end
		Logger.debug(LOG, "Managed HTTP request dispatched through the launcher worker.")
		return true
	end

	return client
end

return M
