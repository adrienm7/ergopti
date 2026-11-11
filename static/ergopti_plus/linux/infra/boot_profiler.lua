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
--- 2. Wall clock for duration, CPU clock for cost. The duration of a stage is the
---    monotonic wall clock (infra/monotonic): os.clock() measures CPU time and
---    reads ~0 for a boot spent waiting on I/O. The CPU time is reported next to
---    it on purpose, because the gap between the two is the diagnosis: a stage
---    whose wall time dwarfs its CPU time waits (disk, network, a child), one
---    whose CPU time matches its wall time computes. The Windows driver reports
---    the same pair per stage.
--- 3. Explicit ownership: begin() may run once per process; a second call is a
---    programming error and raises.
--- 4. The time before begin() is a phase of its own. The runtime's start and
---    every module the entry file requires at load ran before the boot clock,
---    so begin() reads the process's age from /proc (its start time against
---    the system uptime, both in clock ticks of 10 ms) and reports it as the
---    "load" phase; a spawn-to-ready time is then the sum of the two.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")

local Logger    = require("logger.shim")
local Monotonic = require("infra.monotonic")
local PhaseStats = require("infra.phase_stats")

local LOG = "BootProfile"

-- Milliseconds per second: os.clock() reports CPU seconds.
local MILLISECONDS_PER_SECOND = 1000

-- Process CPU milliseconds (user + system) consumed so far.
local function process_cpu_ms()
	return os.clock() * MILLISECONDS_PER_SECOND
end

-- Replaceable in tests, which cannot make a process burn a known amount of CPU.
local _cpu_ms = process_cpu_ms

-- Monotonic milliseconds at begin(); nil until the profiler is started.
local _origin_ms = nil
-- Process CPU milliseconds at begin(), the origin of the boot CPU total.
local _cpu_origin_ms = nil

-- Start time of each open stage, keyed by stage name, and its CPU counterpart.
local _open = {}
local _open_cpu = {}

-- Closed stages, in order, as { name, milliseconds, cpu_milliseconds }: the
-- evidence summary at complete() reads them, so a boot is comparable from one
-- log line.
local _done_stages = {}

-- Total boot duration frozen by complete(); nil while booting.
local _boot_ms = nil

-- The process age at begin() in milliseconds, nil when /proc did not say.
local _load_ms = nil

-- The kernel's USER_HZ: /proc/<pid>/stat counts start time in these ticks, a
-- userspace ABI constant (100) on every architecture Linux supports.
local USER_HZ = 100

--- Reads a whole small file, or nil.
--- @param path string
--- @return string|nil
local function read_small(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- The process's age in milliseconds from /proc, or nil when unreadable.
--- @param read function|nil Reader of a /proc file (tests replace it).
--- @return number|nil
function M.process_age_ms(read)
	read = read or read_small
	local uptime = tonumber(((read("/proc/uptime") or ""):match("^(%d+%.?%d*)")))
	-- Field 22 counted after the command name, which may hold spaces and parentheses.
	local after_name = (read("/proc/self/stat") or ""):match("^.*%)%s(.*)$")
	if not uptime or not after_name then return nil end
	local fields = {}
	for field in after_name:gmatch("%S+") do fields[#fields + 1] = field end
	-- after_name starts at field 3 (state), so field 22 is its 20th word.
	local start_ticks = tonumber(fields[20])
	if not start_ticks then return nil end
	local age_ms = (uptime - start_ticks / USER_HZ) * MILLISECONDS_PER_SECOND
	return age_ms >= 0 and age_ms or nil
end




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
	_cpu_origin_ms = _cpu_ms()
	_load_ms = M.process_age_ms()
	-- The marker line the field log analyser and macOS share, left as it is.
	Logger.info(LOG, "Boot timing started.")
	if _load_ms then
		Logger.info(LOG, "Process age at boot timing: %.0f ms (runtime start and module loading).", _load_ms)
	else
		Logger.warn(LOG, "Process age at boot timing unreadable from /proc; the load phase is not measured.")
	end
end

--- Returns the process CPU milliseconds consumed since begin().
--- @return number
function M.cpu_ms()
	if _cpu_origin_ms == nil then return 0 end
	return _cpu_ms() - _cpu_origin_ms
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
	_open_cpu[name] = _cpu_ms()
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
	local cpu_ms = _cpu_ms() - _open_cpu[name]
	_open[name], _open_cpu[name] = nil, nil
	local wall_ms = Monotonic.now_ms() - started
	_done_stages[#_done_stages + 1] = { name, wall_ms, cpu_ms }
	-- The same phases the macOS profiler records, so the summary line carries the
	-- boot's stage count, wall time and CPU time next to the other families.
	PhaseStats.add_ms("boot.stage", wall_ms)
	PhaseStats.add_ms("boot.stage_cpu", cpu_ms)
	local suffix = (type(detail) == "string" and detail ~= "") and (": " .. detail) or ""
	Logger.success(LOG, "Boot stage '%s' done in %.0f ms (cpu %.0f ms)%s (total %.0f ms).",
		name, Monotonic.now_ms() - started, cpu_ms, suffix, M.elapsed_ms())
end

--- Freezes and logs the total boot duration once the daemon is ready.
--- @return number Total boot milliseconds.
function M.complete()
	if _boot_ms ~= nil then
		error("boot_profiler.complete() called twice — boot completes once.")
	end
	_boot_ms = M.elapsed_ms()
	local still_open = TableUtil.sorted_keys(_open)
	if #still_open > 0 then
		Logger.warn(LOG, "Boot completed with unclosed stage(s): %s.", table.concat(still_open, ", "))
	end
	local boot_cpu_ms = M.cpu_ms()
	Logger.info(LOG, "Boot complete in %.0f ms (cpu %.0f ms).", _boot_ms, boot_cpu_ms)
	require("perf_budget").judge(Logger, LOG, "boot", _boot_ms,
		function() return require("infra.timings").ms("budgets", "boot_total_ms") end)
	-- One never-collapsed summary: every stage's milliseconds and the heap, so
	-- startup cost and its memory are read from a single line.
	local parts = {}
	for _, stage in ipairs(_done_stages) do
		parts[#parts + 1] = string.format("%s=%.0fms(cpu %.0fms)", stage[1], stage[2], stage[3])
	end
	Logger.evidence(LOG, "Boot summary: total=%.0fms (cpu %.0fms) heap=%dKB load=%s stages: %s.", _boot_ms,
		boot_cpu_ms, math.floor(collectgarbage("count")),
		_load_ms and string.format("%.0fms", _load_ms) or "unknown", table.concat(parts, " "))
	return _boot_ms
end

--- Total boot milliseconds, or nil before complete().
--- @return number|nil
function M.boot_ms()
	return _boot_ms
end

--- Replaces the CPU clock (tests only). Pass nil to restore the process clock.
--- @param fn function|nil Zero-argument function returning CPU milliseconds.
function M._use_cpu_clock(fn)
	_cpu_ms = fn or process_cpu_ms
end

--- Resets every piece of state. Tests only.
function M._reset_for_test()
	_origin_ms, _cpu_origin_ms, _open, _open_cpu, _boot_ms, _done_stages = nil, nil, {}, {}, nil, {}
	_load_ms = nil
	_cpu_ms = process_cpu_ms
end

return M
