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
--- 3. system_details runs `df -Pk` on the logs folder. kanata left the driver
---    on 2026-09-24, so its version probe is gone with it.
--- 4. cpu_load reads /proc/stat and /proc/self/stat twice, sample_ms apart on
---    a libuv timer, for the machine's load and the daemon's share of it.
--- 5. Without libuv there is no asynchronous child, no HTTP client and no
---    timer: the probes then answer "unsupported" instead of blocking the
---    loop with a synchronous fallback.
--- 6. A run is cancelled as a whole when the page refreshes or closes, and a
---    late answer of a cancelled run publishes nothing.
--- 7. configuration reads and reduces the user's configuration files on a
---    timer after phase A. It reads only local files, so it also runs without
---    the extensive opt-in (local_only), and an answer past its timeout_ms is a
---    timeout without sections.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local LOG = "healthcheck.probes"

-- The User-Agent GitHub requires on every API request
local USER_AGENT = "ErgoptiPlus-Diagnostics"

-- The HTTP client owners of the two network probes, so they never cancel a
-- request of the updater or the AI engine
local GITHUB_OWNER = "diagnostics.github"
local AI_OWNER = "diagnostics.ai"
local PAC_OWNER = "diagnostics.pac"

-- The only backend whose server answers at the engine's local base URL.
local AI_LOCAL_BACKEND = "ollama"





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

--- A refused dispatch may still own a started native process. Defer the
--- logical answer until its exact cleanup receipt has settled.
local function after_refused_cleanup(run, cleanup, answer)
	if not cleanup then answer(); return end
	run.cancellers[#run.cancellers + 1] = function() cleanup.cancel() end
	pcall(cleanup.on_settled, answer)
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
		-- A failed answer carries its detail into the log: the diagnostics window
		-- closes, and a field report holds only the log (issue #104).
		local detail = result.state ~= "ok" and type(result.detail) == "string" and result.detail ~= ""
			and (": " .. result.detail) or ""
		Logger.done(LOG, "Probe '%s' answered: %s (%d ms)%s.", id, result.state, result.ms, detail)
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
	local ok, data = pcall(require("core.text.engine.json").decode, body)
	return (ok and type(data) == "table") and data or nil
end

--- Reads a small file, nil when it cannot be read.
--- @param path string
--- @return string|nil
local function read_file(path)
	return require("infra.regular_file_reader").read_source(path)
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
		local started = HttpClient.get(config.url, { ["User-Agent"] = USER_AGENT, ["Accept"] = "application/vnd.github+json" },
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
		if started ~= true then done({ state = "error", detail = "HTTP request refused" }) end
	end
end

--- The desktop's proxy auto-config (PAC): configured, downloadable and usable by
--- the managed downloader. The URL is read and fetched here but never reported.
--- @param config table { timeout_ms }
--- @param run table
--- @return function
local function proxy_pac(config, run)
	return function(done)
		local Shell = require("adapters.shell_runner")
		local HttpClient = require("adapters.http_client")
		if not Shell.HAS_ASYNC or not HttpClient.HAS_ASYNC then
			done({ state = "unsupported" })
			return
		end
		local PacCheck = require("core.network.engine.pac_check")
		local function none() done({ state = "ok" }, { network = { proxy_pac = "No PAC configured" } }) end
		local function fetch(url)
			run.cancellers[#run.cancellers + 1] = function() HttpClient.cancel(PAC_OWNER) end
			local started = HttpClient.get(url, { ["User-Agent"] = USER_AGENT },
				{ timeout_ms = config.timeout_ms, owner = PAC_OWNER }, function(result)
					local state, text = PacCheck.judge(result.status, result.body, result.error)
					if state == "ok" then
						done({ state = "ok" }, { network = { proxy_pac = text } })
					else
						done({ state = "error", detail = text })
					end
				end)
			if started ~= true then done({ state = "error", detail = "HTTP request refused" }) end
		end
		local function ask(key, on_output)
			-- Only GNOME stores a proxy setting there; elsewhere there is none to read.
			if not Shell.has_command("gsettings") then on_output(nil) return end
			local handle, _, cleanup = Shell.run_async("gsettings", { "get", "org.gnome.system.proxy", key },
				{ timeout_ms = config.timeout_ms }, function(result)
					on_output(result.ok and result.stdout or nil)
				end)
			if not handle then after_refused_cleanup(run, cleanup, function() on_output(nil) end); return end
			run.cancellers[#run.cancellers + 1] = function() handle.cancel() end
		end
		ask("mode", function(mode)
			if not (mode and mode:find("'auto'", 1, true)) then none() return end
			ask("autoconfig-url", function(value)
				local url = value and value:match("'([^']+)'")
				if url and url ~= "" then fetch(url) else none() end
			end)
		end)
	end
end

--- The selected local AI backend answers its version endpoint. A backend with
--- no health path in the schema (the remote API) is unsupported, never probed
--- through the local Ollama URL (audit LDG-001), as on macOS.
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
		local read, backend = pcall(function() return type(llm.get_backend) == "function" and llm.get_backend() end)
		local path = read and type(backend) == "string" and config.paths[backend] or nil
		local HttpClient = require("adapters.http_client")
		if not path or backend ~= AI_LOCAL_BACKEND or not HttpClient.HAS_ASYNC or type(llm.get_base_url) ~= "function" then
			done({ state = "unsupported" })
			return
		end
		run.cancellers[#run.cancellers + 1] = function() HttpClient.cancel(AI_OWNER) end
		local started = HttpClient.get(llm.get_base_url() .. path, {},
			{ timeout_ms = config.timeout_ms, owner = AI_OWNER }, function(result)
				local status = tonumber(result.status) or 0
				if status < 200 or status >= 300 then
					done(http_failure(result))
					return
				end
				local data = decode(result.body)
				local version = type(data) == "table" and type(data.version) == "string" and data.version or nil
				done({ state = "ok" }, { ai = { ai_health = version and (backend .. " " .. version) or ("HTTP " .. status) } })
			end)
		if started ~= true then done({ state = "error", detail = "HTTP request refused" }) end
	end
end

--- The logs volume's free space.
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
		local sections = { system = {} }
		if not logs_dir then
			done({ state = "ok" }, sections)
			return
		end
		local handle, err, cleanup = Shell.run_async("df", { "-Pk", logs_dir }, { timeout_ms = config.timeout_ms }, function(result)
			if not result.ok then
				done({ state = "error", detail = "df: " .. tostring(result.error) }, sections)
				return
			end
			-- Second line: filesystem, 1024-blocks, used, available, ...
			local available = result.stdout:match("\n%S+%s+%d+%s+%d+%s+(%d+)")
			sections.system.disk_free = available and tonumber(available) * 1024 or nil
			done({ state = "ok" }, sections)
		end)
		if not handle then
			after_refused_cleanup(run, cleanup, function()
				done({ state = "error", detail = "df: " .. tostring(err) }, sections)
			end)
			return
		end
		run.cancellers[#run.cancellers + 1] = function() handle.cancel() end
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
		if not handle or not handle.armed then
			done({ state = "error", detail = "Timer could not be started" })
		end
	end
end

--- The user's configuration files and settings, read on a libuv timer after
--- phase A: local files only, so it needs no opt-in. Its answer is the two
--- sections; one that arrives after its timeout is discarded as a timeout.
--- @param schema table
--- @param run table
--- @param overrides table|nil Replacements for tests (see bridge.configuration_context).
--- @return function
local function configuration(schema, run, overrides)
	return function(done)
		local Timers = require("adapters.timer_scheduler")
		if not Timers.HAS_ASYNC then
			done({ state = "unsupported" })
			return
		end
		local handle = Timers.after(require("infra.timings").sec("ui", "healthcheck_probe_defer_ms"), function()
			local context = require("ui.healthcheck.bridge").configuration_context(schema, overrides)
			local ok, result, sections = pcall(require("diagnostics.engine.healthcheck.configuration").probe, context)
			if not ok then
				done({ state = "error", cleanup = "settled", detail = tostring(result):match("^[^\n]*") })
				return
			end
			done(result, sections)
		end)
		run.cancellers[#run.cancellers + 1] = function() Timers.cancel(handle) end
		if not handle or not handle.armed then
			done({ state = "error", detail = "Timer could not be started" })
		end
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
--- @param options table|nil { local_only, overrides, current = function() -> boolean }
--- @return table run { cancel = function() }
function M.start(schema, paths, state, publish, options)
	options = options or {}
	local run = { cancelled = false, cancellers = {}, publish = publish }
	local config = schema.probes
	local function stop()
		if run.cancelled then return end
		run.cancelled = true
		for index = #run.cancellers, 1, -1 do
			local ok, err = pcall(run.cancellers[index])
			if not ok then Logger.error(LOG, "A diagnostics probe could not be cancelled: %s.", tostring(err)) end
		end
	end
	run.cancel = stop
	local function admitted()
		if type(options.current) == "function" then
			local checked, current = pcall(options.current)
			return checked and current == true
		end
		return true
	end
	local function launch(id, body)
		if not admitted() then stop(); return false end
		start_probe(run, id, body)
		if not admitted() then stop(); return false end
		return true
	end
	if not launch("configuration", configuration(schema, run, options.overrides)) then return run end
	if options.local_only == true then
		return run
	end
	if not launch("github_api", github_api(config.github_api, run)) then return run end
	if not launch("ai_health", ai_health(config.ai_health, state, run)) then return run end
	if not launch("system_details", system_details(config.system_details, paths.logs_dir, run)) then return run end
	if not launch("cpu_load", cpu_load(config.cpu_load, run)) then return run end
	launch("proxy_pac", proxy_pac(config.proxy_pac, run))
	return run
end

return M
