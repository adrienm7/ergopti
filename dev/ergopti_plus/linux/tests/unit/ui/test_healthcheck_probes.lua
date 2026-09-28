--- tests/unit/ui/test_healthcheck_probes.lua

--- ==============================================================================
--- MODULE: Diagnostics Probes (Linux)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot, over controlled adapters:
--- 1. github_api reads api.github.com's rate limit through the libuv HTTP
---    client, under its own owner so it never cancels the updater's request;
--- 2. system_details reads the kanata version and the logs volume's free space
---    from asynchronous children;
--- 3. without libuv every probe answers "unsupported" instead of blocking the
---    event loop with a synchronous fallback;
--- 4. a cancelled run publishes nothing and stops its requests and children.
--- ==============================================================================

local helpers = require("tests.helpers")

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

--- An io.open answering the /proc paths of world.proc from memory.
--- @param world table
--- @param real function The real io.open.
--- @return function
local function proc_open(world, real)
	return function(path, mode)
		local content = world.proc and world.proc[path]
		if content == nil then return real(path, mode) end
		return {
			read = function() return content end,
			close = function() return true end,
		}
	end
end

--- Runs body with the real probes over recorded adapters.
--- @param async boolean Whether libuv is available.
--- @param body function(Probes, world)
local function with_probes(async, body)
	local names = { "ui.healthcheck.probes", "adapters.http_client", "adapters.shell_runner",
		"adapters.timer_scheduler" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { requests = {}, children = {}, cancelled_owners = {}, cancelled_children = 0, timers = {},
		cancelled_timers = 0, proc = PROC_BEFORE }
	package.loaded["adapters.timer_scheduler"] = {
		HAS_ASYNC = async,
		after = function(delay, fn)
			local handle = { delay = delay, fn = fn }
			world.timers[#world.timers + 1] = handle
			return handle
		end,
		cancel = function(handle)
			handle.cancelled = true
			world.cancelled_timers = world.cancelled_timers + 1
		end,
	}
	local real_open = io.open
	io.open = proc_open(world, real_open)
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
		run_async = function(executable, args, options, callback)
			world.children[#world.children + 1] = { executable = executable, args = args, options = options,
				callback = callback }
			return { cancel = function() world.cancelled_children = world.cancelled_children + 1 end }
		end,
	}
	package.loaded["ui.healthcheck.probes"] = nil
	local ok, err = pcall(body, require("ui.healthcheck.probes"), world)
	io.open = real_open
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
	local run = Probes.start(schema, { logs_dir = "/home/jdoe/.local/state/ergopti_plus/logs" }, state or {},
		function(id, result, sections) answers[id] = { result = result, sections = sections } end)
	return run, answers
end

helpers.describe("diagnostics probes (linux)", function()
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

	helpers.it("reads the kanata version and the free space from asynchronous children", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			helpers.assert_eq(world.children[1].executable, "kanata")
			helpers.assert_eq(world.children[2].executable, "df")
			world.children[1].callback({ ok = true, stdout = "kanata 1.7.0\n" })
			world.children[2].callback({ ok = true, stdout = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
				.. "/dev/nvme0n1p3 490000000 200000000 250000000 45% /home\n" })
			helpers.assert_eq(answers.system_details.result.state, "ok")
			helpers.assert_eq(answers.system_details.sections.versions.kanata, "kanata 1.7.0")
			helpers.assert_eq(answers.system_details.sections.system.disk_free, 250000000 * 1024)
		end)
	end)

	helpers.it("answers unsupported without libuv rather than blocking the loop", function()
		with_probes(false, function(Probes, world)
			local _, answers = start(Probes, { llm = { is_enabled = function() return true end,
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
			local timer = world.timers[1]
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
			helpers.assert_eq(#world.timers, 0)
		end)
	end)

	helpers.it("a cancelled run publishes nothing and stops its requests and children", function()
		with_probes(true, function(Probes, world)
			local run, answers = start(Probes)
			run.cancel()
			world.requests[1].callback({ status = 200, body = "{}" })
			world.children[1].callback({ ok = true, stdout = "kanata 1.7.0\n" })
			helpers.assert_nil(answers.github_api, "nothing of a cancelled run reaches the page")
			helpers.assert_nil(answers.system_details)
			helpers.assert_eq(world.cancelled_owners, { "diagnostics.github" })
			helpers.assert_eq(world.cancelled_children, 2)
			helpers.assert_eq(world.cancelled_timers, 1, "the processor sample's timer is stopped")
		end)
	end)
end)
