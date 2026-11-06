--- tests/unit/ui/healthcheck/test_healthcheck_probes.lua

--- ==============================================================================
--- MODULE: Diagnostics Probes (Linux)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot, over controlled adapters:
--- 1. github_api reads api.github.com's rate limit through the libuv HTTP
---    client, under its own owner so it never cancels the updater's request;
--- 2. system_details reads the logs volume's free space and starts no kanata
---    (removed with the stale probe, owned-runtimes row)
---    from asynchronous children;
--- 3. without libuv every probe answers "unsupported" instead of blocking the
---    event loop with a synchronous fallback;
--- 4. a cancelled run publishes nothing and stops its requests, children and
---    timers, the configuration probe's collection timer included.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The application folder under every XDG base, from the shared registry.
local FOLDER = require("app_dirs").linux.folder_name

-- Two samples of the /proc files the processor probe reads, 1500 ticks apart:
-- 700 of them idle, 75 spent by the daemon, whose command name holds a space
-- and parentheses
local PROC_BEFORE = {
	["/proc/stat"] = "cpu  1000 0 500 8000 500 0 0 0 0 0\ncpu0 500 0 250 4000 250 0 0 0 0 0\n",
	["/proc/self/stat"] = "4242 (lua (ergopti) d) S 1 4242 4242 0 -1 4194304 1000 0 0 0 100 50 0 0 20 0 3 0 12345\n",
}
local PROC_AFTER = {
	["/proc/stat"] = "cpu  1600 0 700 8600 600 0 0 0 0 0\ncpu0 800 0 350 4300 300 0 0 0 0 0\n",
	["/proc/self/stat"] = "4242 (lua (ergopti) d) S 1 4242 4242 0 -1 4194304 1000 0 0 0 150 75 0 0 20 0 3 0 12345\n",
}

--- Runs body with the real probes over recorded adapters.
--- @param async boolean Whether libuv is available.
--- @param body function(Probes, world)
--- @param absent table|nil Programs the probe of has_command answers absent for.
local function with_probes(async, body, absent)
	local names = { "ui.healthcheck.probes", "adapters.http_client", "adapters.shell_runner",
		"adapters.timer_scheduler" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { requests = {}, children = {}, cancelled_owners = {}, cancelled_children = 0, timers = {},
		cancelled_timers = 0, proc = PROC_BEFORE }
	package.loaded["adapters.timer_scheduler"] = {
		HAS_ASYNC = async,
		after = function(delay, fn)
			local handle = { delay = delay, fn = fn, armed = true }
			world.timers[#world.timers + 1] = handle
			return handle
		end,
		cancel = function(handle)
			handle.cancelled = true
			world.cancelled_timers = world.cancelled_timers + 1
		end,
	}
	local reader = require("infra.regular_file_reader")
	local real_read = reader.read_source
	reader.read_source = function(path)
		local content = world.proc and world.proc[path]
		if content ~= nil then return content end
		return real_read(path)
	end
	package.loaded["adapters.http_client"] = {
		HAS_ASYNC = async,
		get = function(url, headers, options, callback)
			world.requests[#world.requests + 1] = { url = url, headers = headers, options = options, callback = callback }
			return true
		end,
		cancel = function(owner) world.cancelled_owners[#world.cancelled_owners + 1] = owner; return true end,
	}
	package.loaded["adapters.shell_runner"] = {
		HAS_ASYNC = async,
		has_command = function(binary)
			world.probed = world.probed or {}
			world.probed[#world.probed + 1] = binary
			return not (absent or {})[binary]
		end,
		run_async = function(executable, args, options, callback)
			if world.refuse and world.refuse[executable] then
				local debt = { cancel = function() world.cancelled_children = world.cancelled_children + 1 end,
					on_settled = function(listener) world.refuse[executable] = listener; return true end }
				return nil, "pipe activation failed", debt
			end
			world.children[#world.children + 1] = { executable = executable, args = args, options = options,
				callback = callback }
			return { cancel = function() world.cancelled_children = world.cancelled_children + 1 end }
		end,
	}
	package.loaded["ui.healthcheck.probes"] = nil
	local ok, err = pcall(body, require("ui.healthcheck.probes"), world)
	reader.read_source = real_read
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Starts the probes of the real schema with a recorder.
--- @param Probes table
--- @param state table|nil Daemon state.
--- @return table run, table answers
local function start(Probes, state)
	local schema = helpers.load_module("ui.healthcheck.bridge").config().schema
	local answers = {}
	local run = Probes.start(schema, { logs_dir = "/home/jdoe/.local/state/" .. FOLDER .. "/logs" }, state or {},
		function(id, result, sections) answers[id] = { result = result, sections = sections } end)
	return run, answers
end

--- The timers of the processor probe, apart from the configuration probe's
--- own collection timer.
--- @param world table
--- @return table
local function cpu_timers(world)
	local sample_s = helpers.load_module("ui.healthcheck.bridge").config().schema.probes.cpu_load.sample_ms / 1000
	local timers = {}
	for _, handle in ipairs(world.timers) do
		if handle.delay == sample_s then timers[#timers + 1] = handle end
	end
	return timers
end

--- The desktop proxy children, in start order: the mode query, then the URL
--- query once the mode answered. By executable, not position: the other probes
--- start their own children before them.
--- @param world table
--- @return table|nil mode, table|nil url
local function gsettings_children(world)
	local found = {}
	for _, child in ipairs(world.children) do
		if child.executable == "gsettings" then found[#found + 1] = child end
	end
	return found[1], found[2]
end

helpers.describe("diagnostics probes (linux)", function()
	helpers.it("(healthcheck-timer-refusal) reports failed starts and retains cancellation owners", function()
		with_probes(true, function(Probes, world)
			package.loaded["adapters.timer_scheduler"].after = function()
				local handle = { armed = false, fired = true, timer = {} }
				world.timers[#world.timers + 1] = handle
				return handle
			end
			local run, answers = start(Probes)
			helpers.assert_eq(answers.configuration.result.state, "error")
			helpers.assert_eq(answers.cpu_load.result.state, "error")
			run.cancel()
			helpers.assert_eq(world.cancelled_timers, 2)
		end)
	end)

	helpers.it("(healthcheck-http-refusal) preserves an inline completion despite a false dispatch receipt", function()
		with_probes(true, function(Probes)
			package.loaded["adapters.http_client"].get = function(_, _, _, done)
				done({ status = 200, body = "{}" }); return false
			end
			local run, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_base_url = function() return "http://127.0.0.1:11434" end } })
			helpers.assert_eq(answers.github_api.result.state, "ok")
			helpers.assert_eq(answers.ai_health.result.state, "ok")
			run.cancel()
		end)
	end)

	helpers.it("(healthcheck-http-refusal) completes probes when HTTP admission refuses without callback", function()
		with_probes(true, function(Probes, world)
			package.loaded["adapters.http_client"].get = function() return false end
			local run, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_base_url = function() return "http://127.0.0.1:11434" end } })
			helpers.assert_eq(answers.github_api.result.state, "error")
			helpers.assert_eq(answers.ai_health.result.state, "error")
			gsettings_children(world).callback({ ok = true, stdout = "'auto'" })
			select(2, gsettings_children(world)).callback({ ok = true, stdout = "'http://pac.example.invalid/a.pac'" })
			helpers.assert_eq(answers.proxy_pac.result.state, "error")
			run.cancel()
			helpers.assert_eq(world.cancelled_owners, { "diagnostics.pac", "diagnostics.ai", "diagnostics.github" },
				"the display result must not discard the native cancellation owners")
		end)
	end)

	helpers.it("(healthcheck-probe-admission) stops launching after an inline answer revokes its page", function()
		with_probes(true, function(Probes, world)
			local schema = helpers.load_module("ui.healthcheck.bridge").config().schema
			local current = true
			local run = Probes.start(schema, { logs_dir = "/tmp" }, {}, function(id)
				if id == "ai_health" then current = false end
			end, { current = function() return current end })
			helpers.assert_eq(#world.requests, 1, "only the earlier GitHub probe was launched")
			helpers.assert_eq(#world.children, 0, "later system probes must not start")
			helpers.assert_eq(world.cancelled_owners, { "diagnostics.github" })
			helpers.assert_true(run.cancelled)
		end)
	end)

	helpers.it("reads GitHub's rate limit under the probe's own owner", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			local request = world.requests[1]
			helpers.assert_eq(request.url, "https://api.github.com/rate_limit")
			helpers.assert_eq(request.options.owner, "diagnostics.github")
			helpers.assert_eq(request.options.https_only, true)
			request.callback({ status = 200, body = '{"resources":{"core":{"limit":60,"remaining":12}}}' })
			helpers.assert_eq(answers.github_api.result.state, "ok")
			helpers.assert_eq(answers.github_api.sections.network.github_api, "HTTP 200, 12/60")
		end)
	end)

	helpers.it("retains refused native probe cleanup before reporting failure (healthcheck-probe-debt)", function()
		with_probes(true, function(Probes, world)
			world.refuse = { df = true, gsettings = true }
			local _, answers = start(Probes)
			helpers.assert_nil(answers.system_details)
			helpers.assert_nil(answers.proxy_pac)
			world.refuse.df()
			helpers.assert_eq(answers.system_details.result.state, "error")
			world.refuse.gsettings()
			helpers.assert_eq(answers.proxy_pac.result.state, "ok")
		end)
	end)

	helpers.it("cancels refused native probe debt without a late answer (healthcheck-probe-debt)", function()
		with_probes(true, function(Probes, world)
			world.refuse = { df = true, gsettings = true }
			local run, answers = start(Probes)
			run.cancel()
			helpers.assert_eq(world.cancelled_children, 2)
			world.refuse.df(); world.refuse.gsettings()
			helpers.assert_nil(answers.system_details)
			helpers.assert_nil(answers.proxy_pac)
		end)
	end)

	helpers.it("reads the free space from one asynchronous df and starts no kanata (owned-runtimes-kanata-probe)", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			for _, child in ipairs(world.children) do
				helpers.assert_true(child.executable ~= "kanata", "the stale kanata probe is gone")
			end
			helpers.assert_eq(world.children[1].executable, "df")
			world.children[1].callback({ ok = true, stdout = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
				.. "/dev/nvme0n1p3 490000000 200000000 250000000 45% /home\n" })
			helpers.assert_eq(answers.system_details.result.state, "ok")
			helpers.assert_nil(answers.system_details.sections.versions, "no kanata version section")
			helpers.assert_eq(answers.system_details.sections.system.disk_free, 250000000 * 1024)
		end)
	end)

	helpers.it("never probes the local Ollama for a selected API backend (ldg-001)", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_backend = function() return "api" end,
				get_base_url = function() return "http://127.0.0.1:11435" end } })
			helpers.assert_eq(answers.ai_health.result.state, "unsupported")
			for _, request in ipairs(world.requests) do
				helpers.assert_true(not request.url:find("11435", 1, true), "no request reaches the local Ollama")
			end
		end)
	end)

	helpers.it("probes the selected local Ollama and names it (ldg-001)", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_backend = function() return "ollama" end,
				get_base_url = function() return "http://127.0.0.1:11435" end } })
			local request
			for _, candidate in ipairs(world.requests) do
				if candidate.url:find("11435", 1, true) then request = candidate end
			end
			helpers.assert_not_nil(request, "the selected Ollama is probed")
			helpers.assert_eq(request.url, "http://127.0.0.1:11435/api/version")
			request.callback({ status = 200, body = '{"version":"0.9.1"}' })
			helpers.assert_eq(answers.ai_health.result.state, "ok")
			helpers.assert_eq(answers.ai_health.sections.ai.ai_health, "ollama 0.9.1")
		end)
	end)

	helpers.it("answers unsupported without libuv rather than blocking the loop", function()
		with_probes(false, function(Probes, world)
			local _, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_backend = function() return "ollama" end,
				get_base_url = function() return "http://localhost:11434" end } })
			helpers.assert_eq(answers.github_api.result.state, "unsupported")
			helpers.assert_eq(answers.ai_health.result.state, "unsupported")
			helpers.assert_eq(answers.system_details.result.state, "unsupported")
			helpers.assert_eq(answers.cpu_load.result.state, "unsupported")
			helpers.assert_eq(#world.requests, 0)
			helpers.assert_eq(#world.children, 0)
			helpers.assert_eq(#world.timers, 0)
			-- A probe the schema declares and nothing starts reads "checking…" forever
			local schema = helpers.load_module("ui.healthcheck.bridge").config().schema
			local declared = 0
			for id, probe in pairs(schema.probes) do
				if require("healthcheck.snapshot").applies(probe, "linux") then
					declared = declared + 1
					helpers.assert_true(answers[id] ~= nil, "the " .. id .. " probe never answered")
				end
			end
			helpers.assert_true(declared >= 4, "the schema declares " .. declared .. " Linux probes")
		end)
	end)

	helpers.it("reads the processor load and the daemon's share from two /proc samples (system-load)", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			local timer = cpu_timers(world)[1]
			helpers.assert_true(timer ~= nil, "the second sample waits for a timer")
			helpers.assert_eq(timer.delay, 1)
			helpers.assert_nil(answers.cpu_load, "no answer before the second sample")
			world.proc = PROC_AFTER
			timer.fn()
			helpers.assert_eq(answers.cpu_load.result.state, "ok")
			helpers.assert_eq(answers.cpu_load.sections.system.cpu_usage, 53.3)
			helpers.assert_eq(answers.cpu_load.sections.system.process_cpu, 5)
		end)
	end)

	helpers.it("computes the shares from the /proc fields, whatever the command name (system-load)", function()
		with_probes(true, function(Probes)
			local before = Probes.cpu_times(PROC_BEFORE["/proc/stat"], PROC_BEFORE["/proc/self/stat"])
			helpers.assert_eq(before, { total = 10000, idle = 8500, process = 150 })
			local after = Probes.cpu_times(PROC_AFTER["/proc/stat"], PROC_AFTER["/proc/self/stat"])
			helpers.assert_eq(Probes.cpu_shares(before, after), { system = 53.3, process = 5 })
			helpers.assert_nil(Probes.cpu_shares(before, before), "no elapsed time measures nothing")
			helpers.assert_nil(Probes.cpu_times(nil, PROC_BEFORE["/proc/self/stat"]), "an unreadable /proc/stat")
			helpers.assert_nil(Probes.cpu_times(PROC_BEFORE["/proc/stat"], "4242 (truncated"), "a cut /proc/self/stat")
		end)
	end)

	helpers.it("reports unreadable /proc files as an error, not a load of zero (system-load)", function()
		with_probes(true, function(Probes, world)
			world.proc = { ["/proc/stat"] = "", ["/proc/self/stat"] = "" }
			local _, answers = start(Probes)
			helpers.assert_eq(answers.cpu_load.result.state, "error")
			helpers.assert_eq(#cpu_timers(world), 0)
		end)
	end)

	helpers.it("a cancelled run publishes nothing and stops its requests and children", function()
		with_probes(true, function(Probes, world)
			local run, answers = start(Probes)
			run.cancel()
			world.requests[1].callback({ status = 200, body = "{}" })
			world.children[1].callback({ ok = true, stdout = "Filesystem\n/dev/x 1 1 1 1% /\n" })
			helpers.assert_nil(answers.github_api, "nothing of a cancelled run reaches the page")
			helpers.assert_nil(answers.system_details)
			helpers.assert_eq(world.cancelled_owners, { "diagnostics.github" })
			helpers.assert_eq(world.cancelled_children, 2, "df and the proxy settings query are stopped")
			helpers.assert_true(cpu_timers(world)[1].cancelled == true, "the processor sample's timer is stopped")
			helpers.assert_eq(world.cancelled_timers, 2, "the processor and configuration timers are stopped")
			helpers.assert_nil(answers.configuration, "the configuration of a cancelled run is not published")
		end)
	end)

	helpers.it("judges the desktop's PAC like the managed download without reporting its URL", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			local mode, url = gsettings_children(world)
			helpers.assert_eq(mode.executable, "gsettings")
			mode.callback({ ok = true, stdout = "'auto'\n" })
			url = select(2, gsettings_children(world))
			url.callback({ ok = true, stdout = "'http://pac.example.invalid/a.pac'\n" })
			local request = world.requests[2]
			helpers.assert_eq(request.url, "http://pac.example.invalid/a.pac")
			helpers.assert_eq(request.options.owner, "diagnostics.pac")
			request.callback({ status = 200, body = "function FindProxyForURL(u, h) { return 'DIRECT'; }" })
			helpers.assert_eq(answers.proxy_pac.result.state, "ok")
			helpers.assert_true(answers.proxy_pac.sections.network.proxy_pac:find("FindProxyForURL", 1, true) ~= nil)
			helpers.assert_nil(tostring(answers.proxy_pac.sections.network.proxy_pac):find("example", 1, true))
		end)
	end)

	helpers.it("asks no gsettings outside GNOME and answers that no PAC is configured", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			for _, child in ipairs(world.children) do
				helpers.assert_true(child.executable ~= "gsettings", "an absent gsettings was spawned")
			end
			local probed = false
			for _, binary in ipairs(world.probed or {}) do probed = probed or binary == "gsettings" end
			helpers.assert_true(probed, "gsettings is probed before the desktop proxy is read")
			helpers.assert_eq(answers.proxy_pac.result.state, "ok")
			helpers.assert_eq(answers.proxy_pac.sections.network.proxy_pac, "No PAC configured")
		end, { gsettings = true })
	end)

	helpers.it("names the failing PAC step and answers when no PAC is configured", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			gsettings_children(world).callback({ ok = true, stdout = "'auto'\n" })
			select(2, gsettings_children(world)).callback({ ok = true, stdout = "'http://pac.example.invalid/a.pac'\n" })
			world.requests[2].callback({ status = 200, body = "// r\233seau\nfunction FindProxyForURL() {}" })
			helpers.assert_eq(answers.proxy_pac.result.state, "error")
			helpers.assert_true(answers.proxy_pac.result.detail:find("not UTF-8", 1, true) ~= nil)
		end)
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			gsettings_children(world).callback({ ok = true, stdout = "'none'\n" })
			helpers.assert_eq(answers.proxy_pac.result.state, "ok")
			helpers.assert_eq(answers.proxy_pac.sections.network.proxy_pac, "No PAC configured")
		end)
	end)
end)

helpers.describe("healthcheck native source admission", function()
	for _, mode in ipairs({ "stat_refused", "stat_throw", "access_nil", "access_throw" }) do
		helpers.it("(healthcheck-device-owner) refuses " .. mode .. " without opening a descriptor", function()
			local previous, accesses = package.loaded["luv"], 0
			package.loaded["luv"] = {
				fs_open = function() error("a diagnostic must not open the device") end,
				fs_stat = function()
					if mode == "stat_throw" then error("stat failed") end
					if mode == "stat_refused" then return nil end
					return { type = "char" }
				end,
				fs_access = function()
					accesses = accesses + 1
					if mode == "access_throw" then error("access failed") end
					return nil
				end,
			}
			local called, result = pcall(require("ui.healthcheck.bridge")._device_access_for_test, "/synthetic")
			package.loaded["luv"] = previous
			helpers.assert_true(called)
			helpers.assert_eq(result, "unknown")
			helpers.assert_eq(accesses, (mode == "stat_refused" or mode == "stat_throw") and 0 or 1)
		end)
	end

	helpers.it("(healthcheck-source-fifo) reads regular sources and rejects special files without blocking", function()
		local shell = require("adapters.shell_runner")
		helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"))
		local quote = require("text_utils").shell_quote
		local runtime = assert(shell.exec_line("command -v luajit"))
		local root = helpers.driver_root()
		local fixture = root .. "/tests/hardware/run_healthcheck_sources.py"
		local result = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime) .. " --driver " .. quote(root))
		helpers.assert_true(result == true or result == 0, "native healthcheck reads must not wait on special files")
	end)
end)
