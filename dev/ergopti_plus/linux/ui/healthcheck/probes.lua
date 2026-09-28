--- ui/healthcheck/probes.lua

--- ==============================================================================
--- MODULE: Diagnostics Probes (Linux)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot: every fact that needs a
--- subprocess or the network. The HTTP probes are curl processes owned by
--- libuv (adapters.http_client) and the command probes are child processes
--- owned by libuv (adapters.shell_runner.run_async), so nothing blocks the
--- grabbed-keyboard event loop. Each answers exactly once: a result, a
--- timeout or an error.
---
--- FEATURES & RATIONALE:
--- 1. github_api asks api.github.com for its rate limit, the host every update
---    check talks to; the endpoint does not count against that limit.
--- 2. ai_health asks the local Ollama for its version when the AI is on.
--- 3. system_details runs `kanata --version` and `df -Pk` on the logs folder.
--- 4. cpu_load reads /proc/stat and /proc/self/stat twice, sample_ms apart on
---    a libuv timer, for the machine's load and the daemon's share of it.
--- 5. Without libuv there is no asynchronous child, no HTTP client and no
---    timer: the probes then answer "unsupported" instead of blocking the
---    loop with a synchronous fallback.
--- 6. A run is cancelled as a whole when the page refreshes or closes, and a
---    late answer of a cancelled run publishes nothing.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "healthcheck.probes"

-- The User-Agent GitHub requires on every API request
local USER_AGENT = "ErgoptiPlus-Diagnostics"

-- The HTTP client owners of the two network probes, so they never cancel a
-- request of the updater or the AI engine
local GITHUB_OWNER = "diagnostics.github"
local AI_OWNER = "diagnostics.ai"

-- The Ollama port when the engine names no base URL
local AI_BACKEND = "ollama"





-- =================================
-- =================================
-- ======= 1/ Probe Plumbing =======
-- =================================
-- =================================

--- Milliseconds, for durations.
--- @return number
local function now_ms()
	return require("infra.monotonic").now_ms()
end

--- Starts one probe; publishes its single answer.
--- @param run table The probe run (see M.start).
--- @param id string Probe id.
--- @param body function(done) Starts the probe; calls done(result, sections).
local function start_probe(run, id, body)
	local started = now_ms()
	local settled = false
	Logger.trace(LOG, "Probe '%s' started…", id)
	local function done(result, sections)
		if settled then return end
		settled = true
		result.ms = math.floor(now_ms() - started + 0.5)
		Logger.done(LOG, "Probe '%s' answered: %s (%d ms).", id, result.state, result.ms)
		if run.cancelled then return end
		run.publish(id, result, sections)
	end
	run.cancellers[#run.cancellers + 1] = function() done({ state = "cancelled" }) end
	local ok, err = xpcall(function() body(done) end, debug.traceback)
	if not ok then done({ state = "error", detail = tostring(err):match("^[^\n]*") }) end
end

--- Decodes a JSON body, nil when it is not JSON.
--- @param body string|nil
--- @return table|nil
local function decode(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, data = pcall(require("json").decode, body)
	return (ok and type(data) == "table") and data or nil
end

--- Reads a small file, nil when it cannot be read.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- The answer of a failed HTTP request.
--- @param result table The HTTP client's result.
--- @return table
local function http_failure(result)
	local status = tonumber(result.status) or 0
	if tostring(result.error or ""):find("timeout", 1, true) then return { state = "timeout" } end
	return { state = "error", detail = status > 0 and ("HTTP " .. status) or tostring(result.error) }
end





-- =============================
-- =============================
-- ======= 2/ The Probes =======
-- =============================
-- =============================

--- api.github.com's rate limit: reachable, and how many calls are left.
--- @param config table { url, timeout_ms }
--- @param run table
--- @return function
local function github_api(config, run)
	return function(done)
		local HttpClient = require("adapters.http_client")
		if not HttpClient.HAS_ASYNC then
			done({ state = "unsupported" })
			return
		end
		run.cancellers[#run.cancellers + 1] = function() HttpClient.cancel(GITHUB_OWNER) end
		HttpClient.get(config.url, { ["User-Agent"] = USER_AGENT, ["Accept"] = "application/vnd.github+json" },
			{ timeout_ms = config.timeout_ms, owner = GITHUB_OWNER, https_only = true }, function(result)
				if tonumber(result.status) ~= 200 then
					done(http_failure(result))
					return
				end
				local data = decode(result.body)
				local core = type(data) == "table" and type(data.resources) == "table" and data.resources.core or nil
				local value = "HTTP 200"
				if type(core) == "table" and core.remaining and core.limit then
					value = string.format("HTTP 200, %s/%s", tostring(core.remaining), tostring(core.limit))
				end
				done({ state = "ok" }, { network = { github_api = value } })
			end)
	end
end

--- The local AI backend answers its version endpoint.
--- @param config table { paths, timeout_ms }
--- @param state table Daemon state.
--- @param run table
--- @return function
local function ai_health(config, state, run)
	return function(done)
		local llm = state.llm
		if not llm or type(llm.is_enabled) ~= "function" or llm.is_enabled() ~= true then
			done({ state = "disabled" })
			return
		end
		local HttpClient = require("adapters.http_client")
		if not HttpClient.HAS_ASYNC or type(llm.get_base_url) ~= "function" then
			done({ state = "unsupported" })
			return
		end
		run.cancellers[#run.cancellers + 1] = function() HttpClient.cancel(AI_OWNER) end
		HttpClient.get(llm.get_base_url() .. config.paths[AI_BACKEND], {},
			{ timeout_ms = config.timeout_ms, owner = AI_OWNER }, function(result)
				local status = tonumber(result.status) or 0
				if status < 200 or status >= 300 then
					done(http_failure(result))
					return
				end
				local data = decode(result.body)
				local version = type(data) == "table" and type(data.version) == "string" and data.version or nil
				done({ state = "ok" }, { ai = { ai_health = version and (AI_BACKEND .. " " .. version) or ("HTTP " .. status) } })
			end)
	end
end

--- The kanata version and the logs volume's free space.
--- @param config table { timeout_ms }
--- @param logs_dir string|nil
--- @param run table
--- @return function
local function system_details(config, logs_dir, run)
	return function(done)
		local Shell = require("adapters.shell_runner")
		if not Shell.HAS_ASYNC then
			done({ state = "unsupported" })
			return
		end
		local sections = { versions = {}, system = {} }
		local pending, failures = 0, {}
		local function step(detail)
			if detail then failures[#failures + 1] = detail end
			pending = pending - 1
			if pending > 0 then return end
			if #failures > 0 then
				done({ state = "error", detail = table.concat(failures, "; ") }, sections)
			else
				done({ state = "ok" }, sections)
			end
		end
		local function run_command(executable, args, on_output)
			pending = pending + 1
			local handle, err = Shell.run_async(executable, args, { timeout_ms = config.timeout_ms }, function(result)
				if result.ok then
					on_output(result.stdout)
					step(nil)
				else
					step(executable .. ": " .. tostring(result.error))
				end
			end)
			if not handle then step(executable .. ": " .. tostring(err)) return end
			run.cancellers[#run.cancellers + 1] = function() handle.cancel() end
		end
		run_command("kanata", { "--version" }, function(stdout)
			local version = stdout:match("(%d+%.%d+[%w%.%-]*)")
			sections.versions.kanata = version and ("kanata " .. version) or nil
		end)
		if logs_dir then
			run_command("df", { "-Pk", logs_dir }, function(stdout)
				-- Second line: filesystem, 1024-blocks, used, available, ...
				local available = stdout:match("\n%S+%s+%d+%s+%d+%s+(%d+)")
				sections.system.disk_free = available and tonumber(available) * 1024 or nil
			end)
		end
	end
end

--- The machine's and the daemon's processor times, in clock ticks.
--- @param stat string|nil Content of /proc/stat.
--- @param own string|nil Content of /proc/self/stat.
--- @return table|nil { total, idle, process }, nil when either cannot be read.
function M.cpu_times(stat, own)
	local line = type(stat) == "string" and stat:match("^cpu%s+([^\n]+)") or nil
	-- The command name sits in parentheses and may hold spaces and ")": the
	-- fields after the last ")" start with the state, field 3 of the line
	local rest = type(own) == "string" and own:match("^.*%)%s+(.-)%s*$") or nil
	if not line or not rest then return nil end
	local ticks = {}
	for value in line:gmatch("%d+") do ticks[#ticks + 1] = tonumber(value) end
	local fields = {}
	for value in rest:gmatch("%S+") do fields[#fields + 1] = value end
	-- utime and stime are fields 14 and 15 of the line
	local utime, stime = tonumber(fields[12]), tonumber(fields[13])
	if #ticks < 4 or not utime or not stime then return nil end
	-- user nice system idle iowait irq softirq steal; guest time is inside user
	local total = 0
	for index = 1, math.min(#ticks, 8) do total = total + ticks[index] end
	return { total = total, idle = ticks[4] + (ticks[5] or 0), process = utime + stime }
end

--- The machine's load and the daemon's share of it between two samples, in
--- percent of the whole machine and to a tenth.
--- @param before table From M.cpu_times.
--- @param after table
--- @return table|nil { system, process }, nil when no time elapsed.
function M.cpu_shares(before, after)
	local total = after.total - before.total
	if total <= 0 then return nil end
	local function tenth(ticks) return math.floor(ticks * 1000 / total + 0.5) / 10 end
	return { system = tenth(total - (after.idle - before.idle)), process = tenth(after.process - before.process) }
end

--- The processor's load and the daemon's share of it, from two samples taken
--- sample_ms apart on a libuv timer.
--- @param config table { sample_ms }
--- @param run table
--- @return function
local function cpu_load(config, run)
	return function(done)
		local Timers = require("adapters.timer_scheduler")
		if not Timers.HAS_ASYNC then
			done({ state = "unsupported" })
			return
		end
		local function sample() return M.cpu_times(read_file("/proc/stat"), read_file("/proc/self/stat")) end
		local before = sample()
		if not before then
			done({ state = "error", detail = "/proc/stat or /proc/self/stat could not be read" })
			return
		end
		local handle = Timers.after(config.sample_ms / 1000, function()
			local after = sample()
			local shares = after and M.cpu_shares(before, after) or nil
			if not shares then
				done({ state = "error", detail = "no processor time was measured between the two samples" })
				return
			end
			done({ state = "ok" }, { system = { cpu_usage = shares.system, process_cpu = shares.process } })
		end)
		run.cancellers[#run.cancellers + 1] = function() Timers.cancel(handle) end
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Starts every probe of a snapshot.
--- @param schema table
--- @param paths table The snapshot's paths section.
--- @param state table Daemon state.
--- @param publish function(id, result, sections) Receives each answer once.
--- @return table run { cancel = function() }
function M.start(schema, paths, state, publish)
	local run = { cancelled = false, cancellers = {}, publish = publish }
	local config = schema.probes
	start_probe(run, "github_api", github_api(config.github_api, run))
	start_probe(run, "ai_health", ai_health(config.ai_health, state, run))
	start_probe(run, "system_details", system_details(config.system_details, paths.logs_dir, run))
	start_probe(run, "cpu_load", cpu_load(config.cpu_load, run))
	function run.cancel()
		if run.cancelled then return end
		run.cancelled = true
		for index = #run.cancellers, 1, -1 do
			local ok, err = pcall(run.cancellers[index])
			if not ok then Logger.error(LOG, "A diagnostics probe could not be cancelled: %s.", tostring(err)) end
		end
	end
	return run
end

return M
