--- adapters/compositor_focus.lua

--- ==============================================================================
--- MODULE: Compositor Focus Source (Linux, GNOME and KDE Wayland)
--- DESCRIPTION:
--- Keeps the focused window GNOME Shell and KWin push to the daemon, so
--- adapters/window_info answers the four-times-a-second focus poll from memory.
--- The Ergopti GNOME Shell extension and KWin script (linux/desktop_focus/)
--- call the session-bus name below; adapters/compositor_focus_worker owns it in
--- a resident child and prints one JSON line per admitted call.
---
--- FEATURES & RATIONALE:
--- 1. No fork per poll: one worker per daemon run, its lines read by the event
---    loop as they arrive; snapshot() only reads a table.
--- 2. Fail closed: before the worker is ready, after it exits, after a
---    malformed line or a "clear", the answer is unknown (nil), never the last
---    window. A desktop whose extension or script is not loaded stays unknown.
--- 3. One owner: the bus constants live here; the worker, the extension, the
---    KWin script and their tests read or pin them.
--- ==============================================================================

local M = {}

M.BUS_NAME = "org.ergopti.Focus"
M.OBJECT_PATH = "/org/ergopti/Focus"
M.INTERFACE = "org.ergopti.Focus1"
-- The desktop service whose current owner alone may report focus.
M.SERVICES = { gnome = "org.gnome.Shell", kde = "org.kde.KWin" }
-- Bounds every synchronous bus call the worker makes.
M.CALL_TIMEOUT_MS = 500

local LOG = "adapters.compositor_focus"
local OWNER = "compositor-focus"
-- One worker line is a bounded record; anything longer is not one.
local MAX_LINE_BYTES = 8192
-- Bounded diagnostics retained from the worker's stderr.
local MAX_OUTPUT_BYTES = 65536




-- =====================================
-- =====================================
-- ======= 1/ Desktop Detection ========
-- =====================================
-- =====================================

--- Names the desktop family whose shell can report focus, from the
--- XDG_CURRENT_DESKTOP value (lowercased, colon-separated).
--- @param desktop string
--- @return string|nil "gnome", "kde" or nil
function M.desktop_family(desktop)
	if type(desktop) ~= "string" then return nil end
	for token in desktop:lower():gmatch("[^:]+") do
		if token == "gnome" then return "gnome" end
		if token == "kde" then return "kde" end
	end
	return nil
end

--- True for a desktop service this source admits callers from.
--- @param service any
--- @return boolean
function M.is_desktop_service(service)
	return service == M.SERVICES.gnome or service == M.SERVICES.kde
end




-- =====================================
-- =====================================
-- ======= 2/ Worker Lines =============
-- =====================================
-- =====================================

--- Validates one decoded worker record.
--- @param record any
--- @return string|nil kind, table|nil window
function M.parse_record(record)
	if type(record) ~= "table" then return nil end
	if record.kind == "ready" or record.kind == "clear" then return record.kind end
	if record.kind ~= "focus" then return nil end
	if type(record.class) ~= "string" or type(record.title) ~= "string"
		or type(record.id) ~= "string" or record.id == "" then return nil end
	local pid = record.pid
	if pid ~= nil and (type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 or pid > 2147483647) then return nil end
	return "focus", { class = record.class, title = record.title, pid = pid, id = record.id }
end




-- =====================================
-- =====================================
-- ======= 3/ Source ===================
-- =====================================
-- =====================================

--- Creates the focus source for one desktop family.
--- @param options table { family = "gnome"|"kde", start_process?, command?, decode? }
--- @return table source
function M.new(options)
	assert(type(options) == "table" and M.SERVICES[options.family], "compositor focus needs a GNOME or KDE family")
	local Logger = require("logger.shim")
	local family = options.family
	local service = M.SERVICES[family]
	local start_process = options.start_process or function(...) return require("adapters.owned_process").start(...) end
	local decode = options.decode or function(line) return require("json").decode(line) end
	local command = options.command or function()
		local uv = require("luv")
		local Paths = require("infra.paths")
		local executable = assert(uv.exepath(), "native interpreter identity unavailable")
		local shared_lua = assert(Paths.shared("lua"), "shared Lua library unavailable")
		return executable, { Paths.driver_root() .. "/adapters/compositor_focus_worker.lua",
			service, tostring(uv.os_getpid()), shared_lua }, Paths.driver_root()
	end

	local source = {}
	local status = "idle" -- idle, starting, ready, failed, stopped
	local operation = nil
	local pending = ""
	local current = nil

	local function fail(reason)
		if status == "failed" or status == "stopped" then return end
		status, current, pending = "failed", nil, ""
		Logger.warn(LOG, "%s focus reports unavailable (%s) — per-application rules are inactive for this session.",
			family == "gnome" and "GNOME Shell" or "KWin", reason)
		-- A refused dispatch hands back no running process to cancel.
		if operation and type(operation.is_running) == "function" and operation:is_running() then operation:cancel() end
	end

	local function consume(line)
		local decoded_ok, record = pcall(decode, line)
		local kind, window = M.parse_record(decoded_ok and record or nil)
		if not kind then fail("malformed worker record"); return end
		if kind == "ready" then
			if status ~= "starting" then fail("duplicate worker readiness"); return end
			status = "ready"
			Logger.info(LOG, "Listening for %s focus reports on %s.", family == "gnome" and "GNOME Shell" or "KWin", M.BUS_NAME)
			return
		end
		if status ~= "ready" then fail("focus report before readiness"); return end
		current = window
	end

	local function on_output(chunk, kind)
		if kind ~= "stdout" or status == "failed" or status == "stopped" then return end
		pending = pending .. chunk
		while true do
			local newline = pending:find("\n", 1, true)
			if not newline then break end
			local line = pending:sub(1, newline - 1)
			pending = pending:sub(newline + 1)
			consume(line)
			if status == "failed" then return end
		end
		if #pending > MAX_LINE_BYTES then fail("worker line exceeds its bound") end
	end

	--- Starts the resident worker once.
	--- @return boolean started
	function source.start()
		assert(status == "idle", "compositor focus source already started")
		status = "starting"
		local commanded, executable, arguments, cwd = pcall(command)
		if not commanded then fail("worker command unavailable: " .. tostring(executable)); return false end
		local spawned, child = pcall(start_process, executable, arguments, {
			owner = OWNER, capture_tail = true, max_output_bytes = MAX_OUTPUT_BYTES, cwd = cwd,
			on_output = on_output,
		}, function(result)
			if status == "stopped" then return end
			local tail = type(result) == "table" and type(result.stderr) == "string" and result.stderr or ""
			fail("worker exited" .. (tail ~= "" and ": " .. tail:gsub("%s+$", "") or ""))
		end)
		operation = spawned and child or nil
		if not operation or operation.started ~= true then fail("worker dispatch refused"); return false end
		return status ~= "failed"
	end

	--- The focused window the desktop last reported, or nil when unknown.
	--- @return table|nil { class, title, pid|nil, id }
	function source.snapshot()
		if status ~= "ready" or not current then return nil end
		return { class = current.class, title = current.title, pid = current.pid, id = current.id }
	end

	--- True once start() was called and until stop(): this source then owns the
	--- answer for the session, known or not.
	--- @return boolean
	function source.is_active()
		return status == "starting" or status == "ready" or status == "failed"
	end

	--- The desktop family this source serves.
	--- @return string
	function source.family() return family end

	--- Stops the worker; the answer becomes unknown.
	--- @return boolean settled
	function source.stop()
		status, current, pending = "stopped", nil, ""
		if operation and type(operation.is_settled) == "function" and not operation:is_settled() then
			return operation:cancel() == true
		end
		return true
	end

	return source
end

return M
