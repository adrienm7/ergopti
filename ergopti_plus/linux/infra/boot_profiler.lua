--- infra/boot_profiler.lua

--- ==============================================================================
--- MODULE: Boot Stage Profiler (Linux)
--- DESCRIPTION:
--- Paired START/SUCCESS lines with a duration for every stage of the daemon's
--- boot, the Linux counterpart of windows/infra/boot_profiler.ahk and
--- macos/infra/boot_profiler.lua.
---
--- FEATURES & RATIONALE:
--- 1. A stage that never ends is the diagnosis. The daemon has several os.exit
---    paths during boot (no device, no uinput, hook refused); each leaves an
---    opened stage without its SUCCESS line, which names the stage that died
---    instead of leaving "the log stops here" to interpretation.
--- 2. One clock: the monotonic wall clock (infra/monotonic), never os.clock(),
---    which measures CPU time and reads ~0 for a boot spent waiting on I/O.
--- 3. Explicit ownership: begin() may run once per process; a second call is a
---    programming error and raises.
--- ==============================================================================

local M = {}

local Logger    = require("logger.shim")
local Monotonic = require("infra.monotonic")

local LOG = "BootProfile"

-- Monotonic milliseconds at begin(); nil until the profiler is started.
local _origin_ms = nil

-- Start time of each open stage, keyed by stage name.
local _open = {}

-- Total boot duration frozen by complete(); nil while booting.
local _boot_ms = nil




-- ====================================
-- ====================================
-- ======= 1/ Boot stage API ==========
-- ====================================
-- ====================================

--- Starts the boot clock. Must be called exactly once, before the first stage.
function M.begin()
	if _origin_ms ~= nil then
		error("boot_profiler.begin() called twice — boot has a single owner.")
	end
	_origin_ms = Monotonic.now_ms()
	Logger.info(LOG, "Boot timing started.")
end

--- Returns the milliseconds elapsed since begin().
--- @return number
function M.elapsed_ms()
	if _origin_ms == nil then return 0 end
	return Monotonic.now_ms() - _origin_ms
end

--- Opens a named boot stage.
--- @param name string
function M.stage(name)
	_open[name] = Monotonic.now_ms()
	Logger.start(LOG, "Boot stage '%s'…", name)
end

--- Closes a named boot stage with its duration and an optional detail.
--- @param name string
--- @param detail string|nil Short summary of what the stage produced.
function M.stage_done(name, detail)
	local started = _open[name]
	if started == nil then
		Logger.error(LOG, "Boot stage '%s' closed without being opened.", name)
		return
	end
	_open[name] = nil
	local suffix = (type(detail) == "string" and detail ~= "") and (": " .. detail) or ""
	Logger.success(LOG, "Boot stage '%s' done in %.0f ms%s (total %.0f ms).",
		name, Monotonic.now_ms() - started, suffix, M.elapsed_ms())
end

--- Freezes and logs the total boot duration once the daemon is ready.
--- @return number Total boot milliseconds.
function M.complete()
	if _boot_ms ~= nil then
		error("boot_profiler.complete() called twice — boot completes once.")
	end
	_boot_ms = M.elapsed_ms()
	local still_open = {}
	for name in pairs(_open) do still_open[#still_open + 1] = name end
	table.sort(still_open)
	if #still_open > 0 then
		Logger.warn(LOG, "Boot completed with unclosed stage(s): %s.", table.concat(still_open, ", "))
	end
	Logger.info(LOG, "Boot complete in %.0f ms.", _boot_ms)
	return _boot_ms
end

--- Total boot milliseconds, or nil before complete().
--- @return number|nil
function M.boot_ms()
	return _boot_ms
end

--- Resets every piece of state. Tests only.
function M._reset_for_test()
	_origin_ms, _open, _boot_ms = nil, {}, nil
end

return M
