--- platform/focus/compositor_focus.lua

--- ==============================================================================
--- MODULE: Compositor Focus Source (Linux, GNOME, KDE and COSMIC Wayland)
--- DESCRIPTION:
--- Keeps the focused window GNOME Shell, KWin and cosmic-comp push to the
--- daemon, so adapters/window_info answers the four-times-a-second focus poll
--- from memory. The Ergopti GNOME Shell extension and KWin script
--- (linux/platform/desktop_focus/) call the session-bus name below, which
--- adapters/compositor_focus_worker owns in a resident child; under COSMIC,
--- adapters/cosmic_toplevel_worker reads the compositor's toplevel-info
--- protocol instead. Both print one JSON line per change, in the same records.
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
-- Each family's reporter, for the log, and the families without a bus name:
-- cosmic-comp answers its own Wayland protocol, read by its own worker.
M.REPORTERS = { gnome = "GNOME Shell", kde = "KWin", cosmic = "cosmic-comp" }
-- Bounds of one reported window's class and title, for every worker: an
-- oversized one is refused, never truncated into a different identity.
M.MAX_CLASS_BYTES = 256
M.MAX_TITLE_BYTES = 2048
-- Bounds every synchronous bus call the worker makes.
M.CALL_TIMEOUT_MS = 500
-- The GNOME Shell extension's identity, as GNOME Shell's Extensions interface
-- names it; pinned to the shipped metadata.json and the installer by
-- tests/unit/platform/focus/compositor_focus/test_assets.lua.
M.GNOME_EXTENSION_UUID = require("core.text.engine.identifiers").linux_desktop.gnome_extension_uuid
-- What the GNOME worker can say of the extension (an "extension" record).
M.EXTENSION_STATES = { active = true, inactive = true, error = true, out_of_date = true, absent = true,
	unanswered = true, unknown = true }
-- Why no focus report arrives from GNOME Shell, for the log; the tray's
-- localized text is platform/focus/text_automation_status.lua's.
M.EXTENSION_HINTS = {
	absent = "GNOME Shell has not loaded the extension " .. M.GNOME_EXTENSION_UUID
		.. ": log out and back in after an install, otherwise reinstall Ergopti+ outside Flatpak",
	inactive = "the extension is installed but disabled: enable it in the Extensions app or with "
		.. "'gnome-extensions enable " .. M.GNOME_EXTENSION_UUID .. "'",
	out_of_date = "GNOME Shell refuses the extension for this Shell version: update Ergopti+, then log out and back in",
	error = "GNOME Shell failed to load the extension: 'gnome-extensions info " .. M.GNOME_EXTENSION_UUID
		.. "' and the gnome-shell journal name the error",
	silent = "GNOME Shell sent no report although its name was taken: log out and back in so the Shell "
		.. "loads the installed extension",
}

local LOG = "platform.focus.compositor_focus"
local OWNER = "compositor-focus"
-- One worker line is a bounded record; anything longer is not one.
local MAX_LINE_BYTES = 8192




-- =====================================
-- =====================================
-- ======= 1/ Desktop Detection ========
-- =====================================
-- =====================================

--- Names the desktop family whose shell can report focus, from the
--- XDG_CURRENT_DESKTOP value (lowercased, colon-separated).
--- @param desktop string
--- @return string|nil "gnome", "kde", "cosmic" or nil
function M.desktop_family(desktop)
	if type(desktop) ~= "string" then return nil end
	for token in desktop:lower():gmatch("[^:]+") do
		if token == "gnome" then return "gnome" end
		if token == "kde" then return "kde" end
		if token == "cosmic" then return "cosmic" end
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
	if record.kind == "ready" then
		-- COSMIC's worker names the toplevel-info version it bound.
		local protocol = record.protocol
		if protocol ~= nil and (type(protocol) ~= "number" or protocol < 1 or protocol % 1 ~= 0
			or protocol > 1000) then return nil end
		return "ready", { protocol = protocol }
	end
	if record.kind == "clear" then return record.kind end
	-- KWin only: whether the Ergopti script runs, as KWin answered after the
	-- worker asked it to load enabled scripts.
	if record.kind == "script" then
		if type(record.loaded) ~= "boolean" or type(record.answered) ~= "boolean" then return nil end
		return "script", { loaded = record.loaded, answered = record.answered }
	end
	-- GNOME only: the extension's state as GNOME Shell answered, at start
	-- (silent false) and once more after the silence bound (silent true).
	if record.kind == "extension" then
		if not M.EXTENSION_STATES[record.state] or type(record.silent) ~= "boolean" then return nil end
		return "extension", { state = record.state, silent = record.silent }
	end
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

--- Names why GNOME Shell sends no focus report, from what the worker learnt.
--- @param state string|nil The extension's last reported state.
--- @param silent boolean True once the silence bound passed with no report.
--- @param reported boolean True once a report (focus or clear) arrived.
--- @return string|nil "absent", "inactive", "out_of_date", "error", "silent",
---   or nil when reports arrive or may still arrive.
function M.extension_problem(state, silent, reported)
	if reported or state == nil then return nil end
	if state == "absent" or state == "inactive" or state == "out_of_date" or state == "error" then return state end
	-- Active, unanswered or unknown: only the silence bound proves a problem.
	if silent then return "silent" end
	return nil
end

--- Creates the focus source for one desktop family.
--- @param options table { family = "gnome"|"kde"|"cosmic", start_process?, command?, decode? }
--- @return table source
function M.new(options)
	assert(type(options) == "table" and M.REPORTERS[options.family], "compositor focus needs a GNOME, KDE or COSMIC family")
	local Logger = require("core.logger.engine.shim")
	local family = options.family
	local reporter = M.REPORTERS[family]
	local start_process = options.start_process or function(...) return require("core.process.adapters.owned_process").start(...) end
	local decode = options.decode or function(line) return require("core.text.engine.json").decode(line) end
	local command = options.command or function()
		local uv = require("luv")
		local Paths = require("core.fs.engine.paths")
		local executable = assert(uv.exepath(), "native interpreter identity unavailable")
		local shared_lua = assert(Paths.shared_root(), "shared Lua library unavailable")
		if family == "cosmic" then
			local soname = assert(require("_generated.native_runtime").optional.wayland_client, "libwayland-client unnamed")
			return executable, { Paths.driver_root() .. "/platform/focus/cosmic_toplevel_worker.lua",
				soname, tostring(uv.os_getpid()), shared_lua }, Paths.driver_root()
		end
		-- How long the worker waits for the extension's first report before it
		-- asks GNOME Shell again for its state. Read here, not in the worker,
		-- which loads this module without the daemon's logger.
		local silence_ms = require("core.timing.engine.timings").ms("adapters", "desktop_focus_silence_ms")
		return executable, { Paths.driver_root() .. "/platform/focus/compositor_focus_worker.lua",
			M.SERVICES[family], tostring(uv.os_getpid()), shared_lua, tostring(silence_ms) }, Paths.driver_root()
	end

	local source = {}
	local status = "idle" -- idle, starting, ready, failed, stopped
	local operation = nil
	local pending = ""
	local current = nil
	-- KWin only: "loaded", "not_loaded", "unanswered", nil before the worker says.
	local script = nil
	-- GNOME only: the extension's last reported state, whether the silence
	-- bound passed, whether any report arrived, and the problem the log named.
	local extension, silent, reported, diagnosed = nil, false, false, nil

	local function fail(reason)
		if status == "failed" or status == "stopped" then return end
		status, current, pending = "failed", nil, ""
		Logger.warn(LOG, "%s focus reports unavailable (%s) — per-application rules are inactive for this session.",
			reporter, reason)
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
			Logger.info(LOG, "Listening for %s focus reports on %s.", reporter,
				family == "cosmic" and ("zcosmic_toplevel_info_v1 version " .. tostring(window.protocol))
					or M.BUS_NAME)
			return
		end
		if status ~= "ready" then fail("focus report before readiness"); return end
		if kind == "script" then
			script = window.loaded and "loaded" or (window.answered and "not_loaded" or "unanswered")
			if script == "loaded" then
				Logger.info(LOG, "KWin runs the Ergopti focus script.")
			else
				Logger.warn(LOG, "KWin does not run the Ergopti focus script (%s): the focused application stays unknown, "
					.. "so per-application rules and the password-app list cannot apply. Enable 'Ergopti focus' in "
					.. "System Settings > Window Management > KWin Scripts.", script)
			end
			return
		end
		if kind == "extension" then
			if family ~= "gnome" then fail("extension record off GNOME"); return end
			extension, silent = window.state, silent or window.silent
			local problem = M.extension_problem(extension, silent, reported)
			if problem and problem ~= diagnosed then
				diagnosed = problem
				Logger.warn(LOG, "GNOME Shell's Ergopti focus extension sends no focus report (%s, state %s): %s. "
					.. "Per-application rules, the password-app list and the layout switch stay inactive until it does.",
					problem, extension, M.EXTENSION_HINTS[problem])
			elseif not problem then
				Logger.info(LOG, "GNOME Shell reports the Ergopti focus extension %s.", extension)
			end
			return
		end
		reported = true
		if diagnosed then
			-- Pairs the diagnosis line: the problem the tray names is gone.
			Logger.info(LOG, "GNOME Shell's Ergopti focus extension reports focus again (after %s).", diagnosed)
			diagnosed = nil
		end
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
			owner = OWNER, capture_tail = true, max_output_bytes = require("ai.engine.policy.process_limits").defaults().max_output_bytes, cwd = cwd,
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

	--- The source's state, for the field run's setup check.
	--- @return string "idle", "starting", "ready", "failed" or "stopped"
	function source.status() return status end

	--- Whether KWin runs the Ergopti focus script, as the worker found it.
	--- @return string|nil "loaded", "not_loaded", "unanswered"; nil when not
	--- yet known or for another desktop.
	function source.script_state() return script end

	--- Why GNOME Shell sends no focus report, as the worker found it.
	--- @return string|nil "absent", "inactive", "out_of_date", "error" or
	---   "silent"; nil once reports arrive, while they may still arrive, or
	---   for another desktop.
	function source.extension_problem()
		if status ~= "ready" then return nil end
		return M.extension_problem(extension, silent, reported)
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
