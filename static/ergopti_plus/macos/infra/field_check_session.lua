--- infra/field_check_session.lua

--- ==============================================================================
--- MODULE: Field Check, Session Costs and Edge Cases
--- DESCRIPTION:
--- The lines of TODO.md's « Mac hardware session » a program can answer, run by
--- the field run with no person: the cost of the boot that started the app, its
--- idle cost over a quiet window, and the file system's refusal to open a FIFO
--- (section 7, `hs.fs.attributes` on a FIFO).
---
--- FEATURES & RATIONALE:
--- 1. Idle is measured, not assumed: process CPU time and resident memory are
---    read at both ends of a window in which the field run starts nothing, so
---    the share is the driver's own background work (timers, watchers, taps).
--- 2. The FIFO check has a reader attached before anything touches the pipe:
---    should the guard regress, an open still returns instead of freezing the
---    main thread, and the step fails by name rather than hanging the app.
--- 3. Everything a step creates is removed by the step.
--- ==============================================================================

local Report = require("field_check_report")
local Logger = require("infra.logger")

local M = {}

local LOG = "field_check.session"
local PASS, FAIL, INFO = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO

-- The quiet window, and the idle CPU share above which background work is a
-- defect: the hardware session's « no recurring work above a few ms per minute »
-- leaves far less than this; more means a timer or a watcher spins.
M.IDLE_WINDOW_SECONDS = 30
M.IDLE_CPU_PERCENT_MAX = 3
-- Slowest boot stages written to the log.
M.BOOT_STAGES_LOGGED = 3

local PS = "/bin/ps"
local MKFIFO = "/usr/bin/mkfifo"
local MKDIR = "/bin/mkdir"
local RM = "/bin/rm"
local SH = "/bin/sh"
-- One ps, mkdir, mkfifo or rm, and the writer that releases the reader.
local TOOL_SECONDS = 10
-- The reader stays on the pipe at most this long, and is given this long to
-- open it before anything touches the pipe.
local READER_SECONDS = 8
M.FIFO_READER_SETTLE_SECONDS = 1





-- ============================
-- ============================
-- ======= 1/ Boot cost =======
-- ============================
-- ============================

--- The boot that started this app: wall and CPU totals, and the slowest stages.
--- ports.boot_facts() -> { complete_ms, cpu_ms, slowest = { { name, ms } } }.
function M.boot_cost(ports, report, finish)
	local facts = ports.boot_facts()
	if type(facts.complete_ms) ~= "number" then
		report.step("boot_complete_ms", FAIL, "not_complete")
		return finish()
	end
	report.step("boot_complete_ms", INFO, math.floor(facts.complete_ms))
	report.step("boot_cpu_ms", INFO, type(facts.cpu_ms) == "number" and math.floor(facts.cpu_ms) or "unknown")
	for index, stage in ipairs(facts.slowest or {}) do
		Logger.evidence(LOG, "Boot stage %d of the slowest: %s in %.1f ms.", index, tostring(stage.name), stage.ms)
	end
	local slowest = (facts.slowest or {})[1]
	report.step("boot_slowest_stage_ms", INFO, slowest and math.floor(slowest.ms) or 0)
	finish()
end





-- ============================
-- ============================
-- ======= 2/ Idle cost =======
-- ============================
-- ============================

--- Parses `ps -o rss=` (kilobytes).
--- @param text any
--- @return integer|nil kilobytes
function M.parse_rss(text)
	local value = tostring(text or ""):match("^%s*(%d+)%s*$")
	return value and tonumber(value) or nil
end

--- The driver's own CPU share and memory over a quiet window.
--- ports: pid(), cpu_ms() (process CPU), now_ms() (monotonic), exec, after,
--- hold_counts(), lua_heap_kb().
function M.idle_cost(ports, report, finish)
	local pid = tostring(ports.pid())
	local function rss(callback)
		ports.exec(PS, { "-o", "rss=", "-p", pid }, TOOL_SECONDS, function(code, output)
			callback(code == 0 and M.parse_rss(output) or nil)
		end)
	end
	rss(function(rss_start)
		local cpu_start, wall_start = ports.cpu_ms(), ports.now_ms()
		local holds_start, heap_start = ports.hold_counts(), ports.lua_heap_kb()
		ports.after(M.IDLE_WINDOW_SECONDS, function()
			local cpu_used, wall = ports.cpu_ms() - cpu_start, ports.now_ms() - wall_start
			local share = wall > 0 and cpu_used * 100 / wall or 0
			Logger.evidence(LOG, "Idle window: %.0f ms of CPU over %.0f ms (%.2f %%).", cpu_used, wall, share)
			report.step("idle_cpu_percent", share <= M.IDLE_CPU_PERCENT_MAX and PASS or FAIL,
				string.format("%.2f", share))
			local holds_end = ports.hold_counts()
			-- The counters restart at each phase summary: a smaller end is a restart.
			local holds = (holds_end.over_250ms or 0) - (holds_start.over_250ms or 0)
			report.step("idle_holds_over_250ms", INFO, holds >= 0 and holds or (holds_end.over_250ms or 0))
			report.step("idle_heap_growth_kb", INFO, math.floor((tonumber(ports.lua_heap_kb()) or 0)
				- (tonumber(heap_start) or 0)))
			rss(function(rss_end)
				if rss_start == nil or rss_end == nil then
					report.step("idle_rss_mb", FAIL, "unreadable")
				else
					report.step("idle_rss_mb", INFO, math.floor(rss_end / 1024))
					report.step("idle_rss_growth_kb", INFO, rss_end - rss_start)
				end
				finish()
			end)
		end)
	end)
end





-- ==============================
-- ==============================
-- ======= 3/ FIFO safety =======
-- ==============================
-- ==============================

--- A FIFO is classified without being opened, and neither append nor the atomic
--- write opens it. ports.fifo() -> { dir, mode(path), exists(path), append(path,
--- text), write(path, text) } over the driver's file system adapter.
function M.fifo_safety(ports, report, finish)
	local fs = ports.fifo()
	local dir = fs.dir
	local fifo = dir .. "/pipe"
	local function cleanup()
		ports.exec(RM, { "-rf", dir }, TOOL_SECONDS, function(code)
			report.step("fifo_cleanup", code == 0 and PASS or FAIL, code == 0 and nil or "left_behind")
			finish()
		end)
	end
	ports.exec(MKDIR, { "-p", dir }, TOOL_SECONDS, function(made)
		if made ~= 0 then
			report.step("fifo_created", FAIL, "no_folder")
			return finish()
		end
		ports.exec(MKFIFO, { fifo }, TOOL_SECONDS, function(code)
			if code ~= 0 then
				report.step("fifo_created", FAIL, "mkfifo_" .. tostring(code))
				return cleanup()
			end
			report.step("fifo_created", PASS)
			-- The reader drains anything a regressed guard would let through.
			ports.exec(SH, { "-c", 'exec /bin/cat "$1" > /dev/null', "fifo_reader", fifo }, READER_SECONDS, function() end)
			ports.after(M.FIFO_READER_SETTLE_SECONDS, function()
				local status, mode = fs.mode(fifo)
				report.step("fifo_mode", status == "present" and mode == "named pipe" and PASS or FAIL,
					status == "present" and tostring(mode):gsub(" ", "_") or status)
				report.step("fifo_exists", fs.exists(fifo) == true and PASS or FAIL)
				report.step("fifo_append_refused", fs.append(fifo, "field run\n") == false and PASS or FAIL)
				report.step("fifo_write_refused", fs.write(fifo, "field run\n") ~= true and PASS or FAIL)
				local after_status, after_mode = fs.mode(fifo)
				report.step("fifo_kept", after_status == "present" and after_mode == "named pipe" and PASS or FAIL,
					after_status == "present" and nil or after_status)
				-- A writer releases the reader, so nothing waits on the pipe.
				ports.exec(SH, { "-c", ': > "$1"', "fifo_writer", fifo }, TOOL_SECONDS, function() cleanup() end)
			end)
		end)
	end)
end





-- ========================================
-- ========================================
-- ======= 4/ Slow lines of the day =======
-- ========================================
-- ========================================

local AWK = "/usr/bin/awk"
-- Segments named in the log window, by total own time.
M.SLOW_SEGMENTS_LOGGED = 5

-- One pass over the day log, printing a summary only: a task's output is read
-- when it exits, so the lines themselves must never reach the pipe.
M.SLOW_LINES_AWK = [=[
match($0, /Slow [^ :]+: [0-9.]+ ms own/) {
	text = substr($0, RSTART + 5, RLENGTH - 12); split(text, part, ": ")
	n[part[1]]++; t[part[1]] += part[2]; if (part[2] + 0 > m[part[1]] + 0) m[part[1]] = part[2]
}
match($0, /Slow ingest tick [0-9]+ ms/) {
	v = substr($0, RSTART + 17, RLENGTH - 20) + 0; ic++; if (v > im) im = v
}
match($0, /Slow preferences save [0-9]+ ms/) {
	v = substr($0, RSTART + 22, RLENGTH - 25) + 0; pc++; if (v > pm) pm = v
}
/Lease-bound input startup failed/ { lease++ }
/Layout [a-z]+ detected change before its baseline/ { early++ }
/database is locked/ { locked++ }
/Some shortcuts are still unregistered after/ { unregistered++ }
/rebinding every shortcut \(retry/ { rebinds++ }
END {
	for (k in n) printf "segment %s %d %.2f %.2f\n", k, n[k], t[k], m[k]
	printf "ingest %d %d\nprefs %d %d\n", ic, im, pc, pm
	printf "lease_bound %d\nearly_layout %d\n", lease, early
	printf "db_locked %d\nshortcuts_unregistered %d\nshortcut_rebinds %d\n", locked, unregistered, rebinds
}
]=]

-- The counted lines the awk summary ends with.
M.LOG_COUNTERS = { lease_bound = true, early_layout = true, db_locked = true, shortcuts_unregistered = true,
	shortcut_rebinds = true }

--- Reads the awk summary.
--- @param text any
--- @return table|nil summary { segments = { { name, count, own_ms, worst_ms } } by own time, ingest = { count, worst_ms },
---   prefs = { ... }, lease_bound, early_layout, db_locked, shortcuts_unregistered, shortcut_rebinds (counts) }
function M.parse_slow_summary(text)
	local summary = { segments = {} }
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local name, count, own, worst = line:match("^segment (%S+) (%d+) ([%d.]+) ([%d.]+)$")
		if name then
			summary.segments[#summary.segments + 1] = { name = name, count = tonumber(count), own_ms = tonumber(own),
				worst_ms = tonumber(worst) }
		end
		local kind, kind_count, kind_worst = line:match("^(%a+) (%d+) (%d+)$")
		if kind == "ingest" or kind == "prefs" then
			summary[kind] = { count = tonumber(kind_count), worst_ms = tonumber(kind_worst) }
		end
		local counter, counted = line:match("^([%a_]+) (%d+)$")
		if M.LOG_COUNTERS[counter] then summary[counter] = tonumber(counted) end
	end
	if summary.ingest == nil or summary.prefs == nil then return nil end
	for counter in pairs(M.LOG_COUNTERS) do
		if summary[counter] == nil then return nil end
	end
	table.sort(summary.segments, function(a, b) return a.own_ms > b.own_ms end)
	return summary
end

--- Issue #101's first follow-up without a person: which main-thread phase the
--- day's slow lines name most; and item 38's two lines that must not appear.
--- ports.today_log_path(), exec.
function M.slow_lines(ports, report, finish)
	local path = ports.today_log_path()
	if type(path) ~= "string" or path == "" then
		report.step("slow_log", FAIL, "no_log")
		return finish()
	end
	ports.exec(AWK, { M.SLOW_LINES_AWK, path }, TOOL_SECONDS, function(code, output)
		local summary = code == 0 and M.parse_slow_summary(output) or nil
		if summary == nil then
			report.step("slow_log", FAIL, code == nil and "timeout" or "unreadable")
			return finish()
		end
		report.step("slow_log", PASS)
		for index = 1, math.min(M.SLOW_SEGMENTS_LOGGED, #summary.segments) do
			local segment = summary.segments[index]
			Logger.evidence(LOG, "Slow segment %s: %d line(s), %.1f ms own in all, worst %.1f ms.", segment.name,
				segment.count, segment.own_ms, segment.worst_ms)
		end
		local dominant = summary.segments[1]
		report.step("slow_dominant", INFO, dominant and dominant.name or "none")
		report.step("slow_dominant_own_ms", INFO, dominant and math.floor(dominant.own_ms) or 0)
		report.step("slow_ingest_ticks", INFO, summary.ingest.count .. ":" .. summary.ingest.worst_ms)
		report.step("slow_preferences_saves", INFO, summary.prefs.count .. ":" .. summary.prefs.worst_ms)
		-- Item 38: neither line may appear (a lease-bound start that failed, the boot's
		-- layout misread of project-hs-layout-name-forms).
		report.step("log_lease_bound_failures", summary.lease_bound == 0 and PASS or FAIL, summary.lease_bound)
		report.step("log_layout_change_before_baseline", summary.early_layout == 0 and PASS or FAIL,
			summary.early_layout)
		-- The Mac field report of 2026-10-30 21:01 left these to the next day's log:
		-- the keystats ingest's "database is locked" (quick_check opens immutable=1
		-- since 8084562373), and shortcuts left unregistered after a layout flip's
		-- full rebind (a retry line alone is information).
		report.step("log_keystats_database_locked", summary.db_locked == 0 and PASS or FAIL, summary.db_locked)
		report.step("log_shortcuts_still_unregistered", summary.shortcuts_unregistered == 0 and PASS or FAIL,
			summary.shortcuts_unregistered)
		report.step("log_shortcut_rebind_retries", INFO, summary.shortcut_rebinds)
		finish()
	end)
end

return M
