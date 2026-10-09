--- ui/healthcheck/probes.lua

--- ==============================================================================
--- MODULE: Healthcheck Probes (macOS)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot: every fact that needs a
--- subprocess or the network. Each probe runs off the main run loop (hs.task
--- through adapters.shell_runner, hs.http through adapters.http_client), is
--- bounded by its timeout in _shared/modules/diagnostics/schema.json, and
--- answers exactly once: its result, a timeout or an error.
---
--- FEATURES & RATIONALE:
--- 1. github_api asks api.github.com for its rate limit, the host every update
---    check talks to; the endpoint does not count against that limit.
--- 2. ai_health asks the local AI backend for its version when the AI is on;
---    a remote backend is not probed (it would need the user's key).
--- 3. system_details runs sysctl (model, processor, cores) and df (free space
---    of the logs volume) as tasks. hs.execute ran sysctl on the main run loop
---    before, which dispatches the event taps: opening the window could stall
---    typing.
--- 4. cpu_load samples the machine with hs.host.cpuUsage's callback form,
---    which waits on its own timer (the form without a callback blocks), and
---    reads ErgoptiPlus's processor share and memory with ps, as a task.
--- 5. bluetooth reads the connected Bluetooth keyboards, mice and trackpads
---    with system_profiler, as a task (1 to 3 s): hs.usb sees none of them,
---    and a Magic Keyboard is the keyboard of most Macs on a desk. Its answer
---    is the whole peripherals list, USB devices first.
--- 6. A run is cancelled as a whole when the window closes or refreshes, and a
---    late answer of a cancelled run publishes nothing.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "healthcheck.probes"

-- The executables the system probe runs, by absolute path
local SYSCTL = "/usr/sbin/sysctl"
local DF = "/bin/df"

-- ps prints this process's processor share (100 = one core) and resident memory (KiB)
local PS = "/bin/ps"

-- system_profiler lists the Bluetooth devices hs.usb cannot see
local SYSTEM_PROFILER = "/usr/sbin/system_profiler"

-- The sysctl keys, in the order they are printed
local SYSCTL_KEYS = { "hw.model", "machdep.cpu.brand_string", "hw.logicalcpu" }

-- The User-Agent GitHub requires on every API request
local USER_AGENT = "ErgoptiPlus-Diagnostics"





-- =================================
-- =================================
-- ======= 1/ Probe Plumbing =======
-- =================================
-- =================================

--- Milliseconds since an arbitrary origin, for durations.
--- @return number
local function now_ms()
	return hs.timer.absoluteTime() / 1e6
end

--- Starts one probe with its timeout; publishes its single answer.
--- @param run table The probe run (see M.start).
--- @param id string Probe id.
--- @param timeout_ms number
--- @param body function(done, register_cancel, started_ms) Starts the probe with the original clock.
local function start_probe(run, id, timeout_ms, body)
	local started = now_ms()
	local settled = false
	local cancellers = {}
	local timer = nil
	local actor = nil
	local function finish(result, sections)
		if settled then return end
		settled = true
		if id == "appleevent_transport" then
			local parent_result = {}
			for key, value in pairs(result) do parent_result[key] = value end
			result = parent_result
		end
		if timer and require("adapters.timer_scheduler").cancel(timer) == true then
			timer = nil
			run.watchdogs[id] = nil
		end
		result.ms = math.floor(now_ms() - started + 0.5)
		for _, cancel in ipairs(cancellers) do
			local ok, err = pcall(cancel)
			if not ok then Logger.error(LOG, "Probe '%s' could not be stopped: %s.", id, tostring(err)) end
		end
		if actor and type(actor.snapshot) == "function" then
			result.cleanup = actor.snapshot().cleanup
		end
		if id == "appleevent_transport" and run.watchdogs[id] then
			result.cleanup = "pending"
			if result.state == "ok" then result.state, result.detail = "error", "watchdog_cleanup_debt" end
		end
		run.results[id] = result
		if run.cancelled then
			Logger.done(LOG, "Probe '%s' cancelled after %d ms.", id, result.ms)
			return
		end
		Logger.done(LOG, "Probe '%s' answered: %s (%d ms).", id, result.state, result.ms)
		run.publish(id, result, sections)
	end
	run.finishers[#run.finishers + 1] = function()
		if not settled then finish({ state = "cancelled" }) return end
		-- A settled business result can still retain exact native cleanup debt.
		-- Retry its capabilities without calling finish or publishing again.
		if actor and type(actor.cancel) == "function" then
			local ok, err = pcall(actor.cancel)
			if not ok then Logger.error(LOG, "Probe '%s' could not be stopped: %s.", id, tostring(err)) end
		end
		local retained = run.watchdogs[id]
		if retained then
			local ok, acknowledged = pcall(require("adapters.timer_scheduler").cancel, retained)
			if ok and acknowledged == true then
				if run.watchdogs[id] == retained then run.watchdogs[id] = nil end
				if timer == retained then timer = nil end
			end
		end
	end
	Logger.trace(LOG, "Probe '%s' started (timeout %d ms)…", id, timeout_ms)
	local handle, committed = require("adapters.timer_scheduler").after(timeout_ms / 1000, function()
		finish({ state = "timeout" })
	end)
	if id == "appleevent_transport" and handle then
		run.watchdogs[id] = handle
		if require("adapters.timer_scheduler").onSettled(handle, function()
			if run.watchdogs[id] == handle then run.watchdogs[id] = nil end
		end) ~= true then
			timer = handle
			finish({ state = "error", detail = "watchdog_observer_refused", cleanup = "pending" })
			return
		end
	end
	if committed ~= true then
		timer = handle
		finish({ state = "error", detail = "the timeout could not be armed" })
		return
	end
	timer = handle
	local ok, err = xpcall(function()
		actor = body(finish, function(cancel) cancellers[#cancellers + 1] = cancel end, started)
		if actor then run.actors[id] = actor end
	end, debug.traceback)
	if not ok then finish({ state = "error", detail = tostring(err):match("^[^\n]*") }) end
end

--- Decodes a JSON body, nil when it is not JSON.
--- @param body string|nil
--- @return table|nil
local function decode(body)
	if type(body) ~= "string" or body == "" then return nil end
	local ok, data = pcall(require("adapters.json_codec").decode, body)
	return (ok and type(data) == "table") and data or nil
end





-- =============================
-- =============================
-- ======= 2/ The Probes =======
-- =============================
-- =============================

--- api.github.com's rate limit: reachable, and how many calls are left.
--- @param config table { url, timeout_ms }
--- @return function Probe body.
local function github_api(config)
	return function(done, on_cancel)
		local client = require("adapters.http_client").new({ timeout_ms = config.timeout_ms })
		on_cancel(function() client.cancel() end)
		client.get(config.url, { ["User-Agent"] = USER_AGENT, ["Accept"] = "application/vnd.github+json" },
			function(result)
				local status = tonumber(result.status) or 0
				if status ~= 200 then
					done({ state = "error", detail = status > 0 and ("HTTP " .. status) or tostring(result.error) })
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
--- @return function Probe body.
local function ai_health(config)
	return function(done, on_cancel)
		local llm = require("modules.llm")
		if llm.get_runtime_llm_enabled() ~= true then
			done({ state = "disabled" })
			return
		end
		local backend = llm.get_backend()
		local path = config.paths[backend]
		if not path then
			done({ state = "unsupported" })
			return
		end
		local base = backend == "mlx" and require("modules.llm.api_mlx").get_base_url()
			or require("modules.llm.api_ollama").get_base_url()
		local client = require("adapters.http_client").new({ timeout_ms = config.timeout_ms })
		on_cancel(function() client.cancel() end)
		client.get(base .. path, {}, function(result)
			local status = tonumber(result.status) or 0
			if status < 200 or status >= 300 then
				done({ state = "error", detail = status > 0 and ("HTTP " .. status) or tostring(result.error) })
				return
			end
			local data = decode(result.body)
			local version = type(data) == "table" and type(data.version) == "string" and data.version or nil
			done({ state = "ok" }, { ai = { ai_health = version and (backend .. " " .. version) or ("HTTP " .. status) } })
		end)
	end
end

--- Runs one command as a task and hands its output to on_output(stdout) or
--- on_failure(detail).
--- @param executable string
--- @param args table
--- @param on_cancel function Registers a canceller.
--- @param on_output function
--- @param on_failure function
local function run_task(executable, args, on_cancel, on_output, on_failure)
	local handle = require("adapters.shell_runner").spawn(executable, args, function(code, stdout)
		if code == 0 then on_output(stdout or "") else on_failure(executable .. " exited with " .. tostring(code)) end
	end)
	on_cancel(function() handle.terminate() end)
	if not handle.start() then on_failure(executable .. " could not start") end
end

--- The model, processor and cores from sysctl, and the logs volume's free
--- space from df.
--- @param logs_dir string|nil
--- @return function Probe body.
local function system_details(logs_dir)
	return function(done, on_cancel)
		local sections = { hardware = {}, system = {} }
		local pending = 0
		local failures = {}
		local function step_done()
			pending = pending - 1
			if pending > 0 then return end
			if #failures > 0 then
				done({ state = "error", detail = table.concat(failures, "; ") }, sections)
			else
				done({ state = "ok" }, sections)
			end
		end
		local function failed(detail)
			failures[#failures + 1] = detail
			step_done()
		end
		pending = logs_dir and 2 or 1
		local args = { "-n" }
		for _, key in ipairs(SYSCTL_KEYS) do args[#args + 1] = key end
		run_task(SYSCTL, args, on_cancel, function(stdout)
			local lines = {}
			for line in (stdout .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
			sections.hardware.model = lines[1] ~= "" and lines[1] or nil
			sections.hardware.cpu = lines[2] ~= "" and lines[2] or nil
			sections.hardware.cpu_cores = tonumber(lines[3])
			step_done()
		end, failed)
		if logs_dir then
			run_task(DF, { "-k", logs_dir }, on_cancel, function(stdout)
				-- Second line: filesystem, 1K-blocks, used, available, ...
				local available = stdout:match("\n%S+%s+%d+%s+%d+%s+(%d+)")
				sections.system.disk_free = available and tonumber(available) * 1024 or nil
				step_done()
			end, failed)
		end
	end
end

--- A share rounded to a tenth.
--- @param value number
--- @return number
local function tenth(value)
	return math.floor(value * 10 + 0.5) / 10
end

--- The processor's load, and ErgoptiPlus's share of it and its memory.
--- @param config table { sample_ms }
--- @return function Probe body.
local function cpu_load(config)
	return function(done, on_cancel)
		local sections = { system = {} }
		local cores, process_share = nil, nil
		local pending, failures = 2, {}
		local function step(detail)
			if detail then failures[#failures + 1] = detail end
			pending = pending - 1
			if pending > 0 then return end
			-- ps counts one core as 100 %; the page shows a share of the whole machine
			if process_share and cores and cores > 0 then
				sections.system.process_cpu = tenth(process_share / cores)
			end
			if #failures > 0 then
				done({ state = "error", detail = table.concat(failures, "; ") }, sections)
			else
				done({ state = "ok" }, sections)
			end
		end
		local sampler = hs.host.cpuUsage(config.sample_ms / 1000, function(result)
			local overall = type(result) == "table" and result.overall or nil
			if type(overall) ~= "table" or type(overall.active) ~= "number" then
				step("hs.host.cpuUsage answered no overall load")
				return
			end
			-- One entry per core, keyed 1..n, beside "overall"
			cores = 0
			for key in pairs(result) do
				if type(key) == "number" then cores = cores + 1 end
			end
			sections.system.cpu_usage = tenth(overall.active)
			step(nil)
		end)
		on_cancel(function()
			if type(sampler) ~= "table" then return end
			-- hs.host.cpuUsage clears its timer before calling back, and its
			-- stop() indexes that timer: stopping a sampler that already
			-- answered raised on every successful run.
			if type(sampler.finished) == "function" and sampler:finished() then return end
			if type(sampler.stop) == "function" then sampler:stop() end
		end)
		run_task(PS, { "-o", "%cpu=,rss=", "-p", tostring(hs.processInfo.processID) }, on_cancel, function(stdout)
			-- A decimal comma under some locales
			local share, rss = stdout:match("([%d%.,]+)%s+(%d+)")
			process_share = share and tonumber((share:gsub(",", "."))) or nil
			sections.system.process_memory = rss and tonumber(rss) * 1024 or nil
			step(nil)
		end, step)
	end
end

--- A "0x004C" id as the four lowercase hex digits of the USB rows.
--- @param value any
--- @return string|nil
local function hex_id(value)
	local digits = type(value) == "string" and value:match("^0[xX](%x+)$") or nil
	return digits and string.format("%04x", tonumber(digits, 16)) or nil
end

--- The connected Bluetooth keyboards, mice and trackpads of system_profiler's
--- report: bus, kind and ids, and their names only when details are
--- included. The report also holds addresses and serial numbers, which are
--- never read.
--- @param json string Output of `system_profiler SPBluetoothDataType -json`.
--- @param detailed boolean
--- @return table|nil items
--- @return string|nil error
function M.bluetooth_devices(json, detailed)
	local data = decode(json)
	local controllers = type(data) == "table" and data.SPBluetoothDataType or nil
	if type(controllers) ~= "table" then return nil, "system_profiler printed no Bluetooth report" end
	local device_kind = require("ui.healthcheck.helpers").device_kind
	local items = {}
	for _, controller in ipairs(controllers) do
		-- Absent when nothing is connected
		local connected = type(controller) == "table" and controller.device_connected or nil
		for _, entry in ipairs(type(connected) == "table" and connected or {}) do
			for name, device in pairs(type(entry) == "table" and entry or {}) do
				local kind = device_kind(type(device) == "table" and device.device_minorType or nil)
				-- Headphones and speakers are no input device
				if kind ~= "other" then
					local item = {
						bus = "bluetooth", kind = kind,
						vendor_id = hex_id(device.device_vendorID), product_id = hex_id(device.device_productID),
					}
					if detailed then item.name = name end
					items[#items + 1] = item
				end
			end
		end
	end
	return items
end

--- The Bluetooth input devices, after the USB ones phase A listed.
--- @param usb_items table The snapshot's peripherals items.
--- @param detailed boolean
--- @return function Probe body.
local function bluetooth(usb_items, detailed)
	return function(done, on_cancel)
		run_task(SYSTEM_PROFILER, { "SPBluetoothDataType", "-json" }, on_cancel, function(stdout)
			local devices, err = M.bluetooth_devices(stdout, detailed)
			if not devices then
				done({ state = "error", detail = err })
				return
			end
			local items = {}
			for _, item in ipairs(usb_items) do items[#items + 1] = item end
			for _, item in ipairs(devices) do items[#items + 1] = item end
			done({ state = "ok" }, { peripherals = { items = items } })
		end, function(detail) done({ state = "error", detail = detail }) end)
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Starts every probe of a snapshot.
--- @param schema table
--- @param snapshot table The phase A snapshot: its paths, its peripherals and
---   whether details are included.
--- @param publish function(id, result, sections) Receives each answer once.
--- @return table run { cancel = function() } Cancels every probe still running.
function M.start(schema, snapshot, publish)
	local run = { cancelled = false, finishers = {}, actors = {}, results = {}, watchdogs = {}, publish = publish }
	local config = schema.probes
	local sections = snapshot.sections
	start_probe(run, "github_api", config.github_api.timeout_ms, github_api(config.github_api))
	start_probe(run, "ai_health", config.ai_health.timeout_ms, ai_health(config.ai_health))
	start_probe(run, "system_details", config.system_details.timeout_ms, system_details(sections.paths.logs_dir))
	start_probe(run, "cpu_load", config.cpu_load.timeout_ms, cpu_load(config.cpu_load))
	start_probe(run, "bluetooth", config.bluetooth.timeout_ms,
		bluetooth(sections.peripherals.items or {}, snapshot.detailed == true))
	start_probe(run, "appleevent_transport", config.appleevent_transport.timeout_ms,
		require("ui.healthcheck.appleevents").body(config.appleevent_transport))
	function run.refresh_cleanup()
		for id, owned in pairs(run.actors) do
			local result = run.results[id]
			if result then
				local status = owned.snapshot()
				result.cleanup = run.watchdogs[id] and "pending" or status.cleanup
				result.runtime_pid = status.runtime_pid
				result.sender_context = status.sender_context
				result.qualification_scope = status.qualification_scope
				result.native_status = status.native_status
			end
		end
	end
	function run.has_pending_cleanup()
		if next(run.watchdogs) then return true end
		for _, owned in pairs(run.actors) do
			if owned.snapshot().cleanup ~= "settled" then return true end
		end
		return false
	end
	function run.cancel()
		run.cancelled = true
		for _, finisher in ipairs(run.finishers) do finisher() end
		run.refresh_cleanup()
	end
	return run
end

return M
