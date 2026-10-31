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
-- Line kinds whose worst line is broken down into its largest stage and its forks.
M.SLOW_KINDS = { "ingest", "prefs", "probe", "diagnostics" }
-- The keyboard-layout row's build phases (ui/menu/menu_keyboard_layout.lua).
M.LAYOUT_MENU_PHASE_PREFIX = "menu_keyboard_layout."

-- One pass over the day log, printing a summary only: a task's output is read
-- when it exits, so the lines themselves must never reach the pipe. The worst
-- line of each kind names its largest "<stage>=<ms>" part: that stage decides
-- the fix of "macOS main-thread holds" (ledger L16, L17, L23), the totals and
-- counters of the line are not stages. A hold line's phases are summed by name.
-- POSIX awk only: macOS ships the BWK awk.
M.SLOW_LINES_AWK = [=[
function dominant(text, skip,   best, best_ms, token, eq, name, ms) {
	best = "none"; best_ms = -1
	while (match(text, /[A-Za-z_][A-Za-z0-9_.]*=[0-9.]+/)) {
		token = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
		eq = index(token, "="); name = substr(token, 1, eq - 1); ms = substr(token, eq + 1) + 0
		if (index(skip, " " name " ") == 0 && ms > best_ms) { best_ms = ms; best = name }
	}
	return best
}
function forks(text,   found) {
	if (!match(text, /metadata_commands=[0-9]+ in [0-9]+ ms/)) return "0 0"
	found = substr(text, RSTART + 18, RLENGTH - 21); sub(/ in /, " ", found)
	return found
}
function keep(kind, ms) {
	count[kind]++; if (ms > worst[kind] + 0) { worst[kind] = ms; line[kind] = $0 }
}
match($0, /Slow [^ :]+: [0-9.]+ ms own/) {
	text = substr($0, RSTART + 5, RLENGTH - 12); split(text, part, ": ")
	n[part[1]]++; t[part[1]] += part[2]; if (part[2] + 0 > m[part[1]] + 0) m[part[1]] = part[2]
}
match($0, /Slow ingest tick [0-9]+ ms/) { keep("ingest", substr($0, RSTART + 17, RLENGTH - 20) + 0) }
match($0, /Slow preferences save [0-9]+ ms/) { keep("prefs", substr($0, RSTART + 22, RLENGTH - 25) + 0) }
match($0, /Slow ignored-window probe [0-9]+ ms/) { keep("probe", substr($0, RSTART + 26, RLENGTH - 29) + 0) }
match($0, /The synchronous diagnostics took [0-9.]+ ms/) {
	keep("diagnostics", int(substr($0, RSTART + 33, RLENGTH - 36) + 0))
}
match($0, /Phases inside the hold: [^;]*\. Lua heap/) {
	text = substr($0, RSTART + 24, RLENGTH - 34)
	while (match(text, /[A-Za-z_][A-Za-z0-9_.]*=[0-9.]+/)) {
		token = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
		eq = index(token, "="); phase[substr(token, 1, eq - 1)] += substr(token, eq + 1)
	}
}
/Lease-bound input startup failed/ { lease++ }
/Layout [a-z]+ detected change before its baseline/ { early++ }
END {
	skip = " prepare operations proposed metadata_commands lua_heap entries statements "
	for (k in n) printf "segment %s %d %.2f %.2f\n", k, n[k], t[k], m[k]
	split("ingest prefs probe diagnostics", kinds, " ")
	for (i = 1; i <= 4; i++) {
		k = kinds[i]; printf "%s %d %d\n", k, count[k], worst[k]
		if (count[k] > 0) printf "stage %s %s\nforks %s %s\n", k, dominant(line[k], skip), k, forks(line[k])
	}
	for (k in phase) printf "phase %s %.2f\n", k, phase[k]
	printf "lease_bound %d\nearly_layout %d\n", lease, early
}
]=]

--- Reads the awk summary.
--- @param text any
--- @return table|nil summary { segments = { { name, count, own_ms, worst_ms } } by own time, phases = { { name, ms } }
---   by time, and per kind of M.SLOW_KINDS { count, worst_ms, stage, forks, fork_ms }, lease_bound = count,
---   early_layout = count }
function M.parse_slow_summary(text)
	local summary = { segments = {}, phases = {} }
	local details = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local name, count, own, worst = line:match("^segment (%S+) (%d+) ([%d.]+) ([%d.]+)$")
		if name then
			summary.segments[#summary.segments + 1] = { name = name, count = tonumber(count), own_ms = tonumber(own),
				worst_ms = tonumber(worst) }
		end
		local phase, phase_ms = line:match("^phase (%S+) ([%d.]+)$")
		if phase then summary.phases[#summary.phases + 1] = { name = phase, ms = tonumber(phase_ms) } end
		local kind, kind_count, kind_worst = line:match("^(%a+) (%d+) (%d+)$")
		if kind then summary[kind] = { count = tonumber(kind_count), worst_ms = tonumber(kind_worst) } end
		local stage_kind, stage = line:match("^stage (%a+) (%S+)$")
		if stage_kind then details[stage_kind] = details[stage_kind] or {}; details[stage_kind].stage = stage end
		local fork_kind, fork_count, fork_ms = line:match("^forks (%a+) (%d+) (%d+)$")
		if fork_kind then
			details[fork_kind] = details[fork_kind] or {}
			details[fork_kind].forks, details[fork_kind].fork_ms = tonumber(fork_count), tonumber(fork_ms)
		end
		local counter, counted = line:match("^([%a_]+) (%d+)$")
		if counter == "lease_bound" or counter == "early_layout" then summary[counter] = tonumber(counted) end
	end
	for _, kind in ipairs(M.SLOW_KINDS) do
		local record = summary[kind]
		if record == nil then return nil end
		local detail = details[kind] or {}
		-- A kind seen in the log always carries its stage and forks line.
		if record.count > 0 and (detail.stage == nil or detail.forks == nil) then return nil end
		record.stage, record.forks, record.fork_ms = detail.stage or "none", detail.forks or 0, detail.fork_ms or 0
	end
	if summary.lease_bound == nil or summary.early_layout == nil then return nil end
	table.sort(summary.segments, function(a, b) return a.own_ms > b.own_ms end)
	table.sort(summary.phases, function(a, b) return a.ms > b.ms end)
	return summary
end

--- Returns the busiest hold phase whose name starts with a prefix, or nil.
--- @param phases table Sorted { { name, ms } } of parse_slow_summary.
--- @param prefix string|nil
--- @return table|nil phase
local function busiest_phase(phases, prefix)
	for _, phase in ipairs(phases) do
		if prefix == nil or phase.name:sub(1, #prefix) == prefix then return phase end
	end
	return nil
end

--- Formats a phase as "<name>:<ms>" in the step grammar, or "none".
--- @param phase table|nil
--- @return string
local function phase_value(phase)
	return phase and (phase.name .. ":" .. math.floor(phase.ms)) or "none"
end

--- Issue #101's first follow-up without a person: which main-thread phase the
--- day's slow lines name most; and item 38's two lines that must not appear.
--- For each part of "macOS main-thread holds" that waits on field data, the
--- step that decides it: the hold phases (keyboard-layout row stages, one-off
--- holds), the worst save's stage and forks (L17), the worst ingest tick's
--- (L16), the worst ignored-window probe's stage (L23) and the slowest
--- diagnostics collector.
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
		report.step("slow_ingest_stage", INFO, summary.ingest.stage)
		report.step("slow_ingest_forks", INFO, summary.ingest.forks .. ":" .. summary.ingest.fork_ms)
		report.step("slow_preferences_saves", INFO, summary.prefs.count .. ":" .. summary.prefs.worst_ms)
		report.step("slow_preferences_save_stage", INFO, summary.prefs.stage)
		report.step("slow_preferences_save_forks", INFO, summary.prefs.forks .. ":" .. summary.prefs.fork_ms)
		report.step("slow_ignored_window_probes", INFO, summary.probe.count .. ":" .. summary.probe.worst_ms)
		report.step("slow_ignored_window_stage", INFO, summary.probe.stage)
		report.step("slow_diagnostics", INFO, summary.diagnostics.count .. ":" .. summary.diagnostics.worst_ms)
		report.step("slow_diagnostics_collector", INFO, summary.diagnostics.stage)
		report.step("slow_hold_phase", INFO, phase_value(busiest_phase(summary.phases)))
		report.step("slow_layout_menu_phase", INFO,
			phase_value(busiest_phase(summary.phases, M.LAYOUT_MENU_PHASE_PREFIX)))
		-- Item 38: neither line may appear (a lease-bound start that failed, the boot's
		-- layout misread of project-hs-layout-name-forms).
		report.step("log_lease_bound_failures", summary.lease_bound == 0 and PASS or FAIL, summary.lease_bound)
		report.step("log_layout_change_before_baseline", summary.early_layout == 0 and PASS or FAIL,
			summary.early_layout)
		finish()
	end)
end

return M
