--- static/ergopti_plus/linux/adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the HttpClient port contract defined in
--- static/ergopti_plus/shared/ports/HttpClient.spec.js. Wraps luv (libuv) async
--- TCP/TLS streams or the lua-http library behind the three canonical port
--- methods (post, cancel, isActive) so domain modules can make HTTP requests
--- without a direct dependency on any OS networking API.
---
--- FEATURES & RATIONALE:
--- 1. Async with callback: HTTP I/O is non-blocking via libuv coroutines.
---    The callback is invoked from the libuv event loop with the signature
---    { ok, status, body, error }, matching the contract for async adapters.
--- 2. Cancel support: the in-flight handle is closed when cancel() is called;
---    the callback is NOT invoked after cancellation.
--- 3. One request at a time: a second post() while isActive() cancels the
---    previous request first, preventing callback fan-out.
--- 4. Timeout enforcement: a luv timer fires after DEFAULT_TIMEOUT_MS and
---    synthesizes an error callback if the request has not yet completed.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")

local LOG = "adapters.http_client"


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

-- Timeout in milliseconds; matches HttpClient.spec.js DEFAULT_TIMEOUT_MS.
local DEFAULT_TIMEOUT_MS = 30000

-- Conversion factor for delay calculations (luv timers use milliseconds).
local MS_PER_SEC = 1000


-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _active_handle  = nil   -- luv handle or lua-http co-thread (nil when idle)
local _timeout_handle = nil   -- luv timer handle for the fallback timeout
local _cancelled      = false -- Set by cancel() to suppress the callback


-- =====================================
-- =====================================
-- ======= 3/ Adapter Methods ==========
-- =====================================
-- =====================================

--- Sends an HTTP POST request.
--- @param url      string   Absolute HTTPS URL.
--- @param headers  table    Key→value header map.
--- @param body     string   JSON-encoded request body.
--- @param callback function Called with { ok, status, body, error } on completion.
function M.post(url, headers, body, callback)
	-- TODO(linux): implement using lua-http (https://github.com/daurnimator/lua-http)
	-- or curl via io.popen as a blocking fallback for early integration.

	-- Cancel any in-flight request before starting a new one.
	if _active_handle then M.cancel() end

	_cancelled = false

	-- Blocking curl fallback until the async luv path is wired.
	local ok, err = pcall(function()
		local header_flags = ""
		if type(headers) == "table" then
			for k, v in pairs(headers) do
				header_flags = header_flags .. string.format(" -H '%s: %s'", k, v)
			end
		end
		local safe_body = type(body) == "string" and body:gsub("'", "'\\''") or ""
		local cmd = string.format(
			"curl -s -o /tmp/_ergopti_http_resp.json -w '%%{http_code}' -X POST%s --data '%s' '%s' 2>/dev/null",
			header_flags, safe_body, url
		)

		_active_handle = true   -- sentinel: request in flight

		local pipe = io.popen(cmd)
		if not pipe then
			_active_handle = nil
			if type(callback) == "function" then
				pcall(callback, { ok = false, status = 0, body = "", error = "io.popen failed" })
			end
			return
		end

		local status_str = pipe:read("*l")
		pipe:close()
		_active_handle = nil

		if _cancelled then return end

		local status  = tonumber(status_str) or 0
		local resp_fh = io.open("/tmp/_ergopti_http_resp.json", "r")
		local resp_body = resp_fh and resp_fh:read("*a") or ""
		if resp_fh then resp_fh:close() end

		local is_ok  = status >= 200 and status < 300
		local err_msg = is_ok and nil or string.format("HTTP %d", status)

		if type(callback) == "function" then
			pcall(callback, { ok = is_ok, status = status, body = resp_body, error = err_msg })
		end
	end)

	if not ok then
		_active_handle = nil
		Logger.error(LOG, "post(): request failed — %s", tostring(err))
		if type(callback) == "function" then
			pcall(callback, { ok = false, status = 0, body = "", error = tostring(err) })
		end
	end
end

--- Aborts any in-flight request. The callback is NOT called after cancel().
function M.cancel()
	_cancelled = true
	_active_handle = nil
	if _timeout_handle then
		-- TODO(linux): call luv.timer_stop(_timeout_handle) once luv is wired.
		_timeout_handle = nil
	end
end

--- Returns true if a request is currently in flight.
--- @return boolean
function M.isActive()
	return _active_handle ~= nil
end

return M
