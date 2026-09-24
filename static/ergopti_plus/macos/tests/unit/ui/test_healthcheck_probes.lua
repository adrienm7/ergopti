--- tests/unit/ui/test_healthcheck_probes.lua

--- ==============================================================================
--- MODULE: Diagnostics Probes (macOS)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot, over controlled adapters:
--- 1. github_api reads api.github.com's rate limit and fills network.github_api;
---    a failed request is an error with its status;
--- 2. ai_health answers "disabled" when the AI is off, without a request;
--- 3. system_details parses sysctl (model, processor, cores) and df (free
---    space) from tasks, never from hs.execute;
--- 4. each probe answers exactly once: its timeout wins over a late answer, and
---    a cancelled run publishes nothing and stops its requests and tasks.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The modules each case replaces, restored after it
local FIXTURE_MODULES = {
	"infra.logger", "ui.healthcheck.probes", "adapters.timer_scheduler", "adapters.http_client",
	"adapters.shell_runner", "adapters.json_codec", "modules.llm",
}

--- Runs body with the real probes over recorded adapters.
--- @param body function(Probes, world)
local function with_probes(body)
	local saved_shell_runner = package.loaded["adapters.shell_runner"]
	helpers.with_stub_scope(FIXTURE_MODULES, function()
		helpers.load_with_stubs("infra.logger")
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local world = { timers = {}, requests = {}, tasks = {}, cancelled_requests = 0, terminated = 0, llm_on = false,
			samplers = {}, stopped_samplers = 0 }
		-- The callback form, which samples on its own timer; the blocking form
		-- (no callback) is never what a probe may call. Restored on the same
		-- table, whichever runtime the scope installed.
		local host = hs.host
		local saved_cpu_usage = host.cpuUsage
		host.cpuUsage = function(period, callback)
			if type(callback) ~= "function" then error("hs.host.cpuUsage called without a callback blocks") end
			local sampler = { period = period, callback = callback }
			function sampler.stop() world.stopped_samplers = world.stopped_samplers + 1 end
			world.samplers[#world.samplers + 1] = sampler
			return sampler
		end
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local handle = { delay = delay, callback = callback }
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
		}
		package.loaded["adapters.http_client"] = {
			new = function(options)
				local client = {}
				function client.get(url, headers, callback)
					world.requests[#world.requests + 1] = { url = url, headers = headers, callback = callback,
						timeout_ms = options.timeout_ms }
				end
				function client.cancel() world.cancelled_requests = world.cancelled_requests + 1 end
				return client
			end,
		}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local task = { executable = executable, args = args, on_done = on_done }
				world.tasks[#world.tasks + 1] = task
				return {
					start = function() return true end,
					terminate = function() world.terminated = world.terminated + 1; return true end,
				}
			end,
		}
		package.loaded["adapters.json_codec"] = { decode = function(text) return hs.json.decode(text) end }
		package.loaded["modules.llm"] = {
			get_runtime_llm_enabled = function() return world.llm_on end,
			get_backend = function() return "ollama" end,
		}
		package.loaded["ui.healthcheck.probes"] = nil
		local ok, err = pcall(body, require("ui.healthcheck.probes"), world)
		host.cpuUsage = saved_cpu_usage
		if not ok then error(err, 0) end
	end)
	-- The scope already restored it; written out so the suite-wide stub hygiene
	-- scan (tests/meta/test_shell_runner_stub_restore.lua) sees the restore
	package.loaded["adapters.shell_runner"] = saved_shell_runner
end

--- The probes of the real schema, started with a recorder.
--- @param Probes table
--- @param paths table|nil
--- @return table run, table answers
local function start(Probes, paths)
	local schema = require("healthcheck.snapshot").load_config(require("infra.paths").shared).schema
	local answers = {}
	local run = Probes.start(schema, paths or {}, function(id, result, sections)
		answers[#answers + 1] = { id = id, result = result, sections = sections }
	end)
	return run, answers
end

--- The answer of one probe, or nil.
--- @param answers table
--- @param id string
--- @return table|nil
local function answer_of(answers, id)
	for _, answer in ipairs(answers) do if answer.id == id then return answer end end
	return nil
end

--- The task started for one executable, or nil.
--- @param world table
--- @param executable string
--- @return table|nil
local function task_of(world, executable)
	for _, task in ipairs(world.tasks) do if task.executable == executable then return task end end
	return nil
end

helpers.describe("diagnostics probes (macOS)", function()
	helpers.it("reads GitHub's rate limit into the network section", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes)
			local request = world.requests[1]
			helpers.assert_eq(request.url, "https://api.github.com/rate_limit")
			helpers.assert_eq(request.headers["User-Agent"], "ErgoptiPlus-Diagnostics")
			request.callback({ status = 200, body = '{"resources":{"core":{"limit":60,"remaining":57}}}' })
			local answer = answer_of(answers, "github_api")
			helpers.assert_eq(answer.result.state, "ok")
			helpers.assert_eq(answer.sections.network.github_api, "HTTP 200, 57/60")
		end)
	end)

	helpers.it("reports a failed GitHub request as an error with its status", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes)
			world.requests[1].callback({ status = 503, body = "" })
			local answer = answer_of(answers, "github_api")
			helpers.assert_eq(answer.result.state, "error")
			helpers.assert_eq(answer.result.detail, "HTTP 503")
		end)
	end)

	helpers.it("does not ask the AI backend when the AI is off", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes)
			helpers.assert_eq(answer_of(answers, "ai_health").result.state, "disabled")
			helpers.assert_eq(#world.requests, 1, "only GitHub is asked")
		end)
	end)

	helpers.it("parses sysctl and df from tasks", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes, { logs_dir = "/Users/jdoe/Library/Logs/ergopti_plus" })
			helpers.assert_eq(world.tasks[1].executable, "/usr/sbin/sysctl")
			helpers.assert_eq(world.tasks[2].executable, "/bin/df")
			world.tasks[1].on_done(0, "MacBookPro18,3\nApple M1 Pro\n10\n")
			helpers.assert_nil(answer_of(answers, "system_details"), "one step is not the whole probe")
			world.tasks[2].on_done(0, "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
				.. "/dev/disk3s5 482797652 300000000 150000000 67% /System/Volumes/Data\n")
			local answer = answer_of(answers, "system_details")
			helpers.assert_eq(answer.result.state, "ok")
			helpers.assert_eq(answer.sections.hardware.model, "MacBookPro18,3")
			helpers.assert_eq(answer.sections.hardware.cpu, "Apple M1 Pro")
			helpers.assert_eq(answer.sections.hardware.cpu_cores, 10)
			helpers.assert_eq(answer.sections.system.disk_free, 150000000 * 1024)
		end)
	end)

	helpers.it("answers once: a timeout wins over a late answer", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes)
			for _, timer in ipairs(world.timers) do timer.callback() end
			world.requests[1].callback({ status = 200, body = "{}" })
			local count = 0
			for _, answer in ipairs(answers) do if answer.id == "github_api" then count = count + 1 end end
			helpers.assert_eq(count, 1)
			helpers.assert_eq(answer_of(answers, "github_api").result.state, "timeout")
			helpers.assert_true(world.cancelled_requests >= 1, "a timed-out request must be stopped")
			-- A probe the schema declares and nothing starts reads "checking…" forever
			local schema = require("healthcheck.snapshot").load_config(require("infra.paths").shared).schema
			local declared = 0
			for id, probe in pairs(schema.probes) do
				if require("healthcheck.snapshot").applies(probe, "macos") then
					declared = declared + 1
					helpers.assert_true(answer_of(answers, id) ~= nil, "the " .. id .. " probe never answered")
				end
			end
			helpers.assert_true(declared >= 4, "the schema declares " .. declared .. " macOS probes")
		end)
	end)

	helpers.it("reads the processor load and ErgoptiPlus's share and memory (system-load)", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes)
			local sampler = world.samplers[1]
			helpers.assert_true(sampler ~= nil, "the load is sampled by hs.host.cpuUsage's timer")
			helpers.assert_eq(sampler.period, 1)
			local ps = task_of(world, "/bin/ps")
			helpers.assert_true(ps ~= nil, "ErgoptiPlus's share and memory come from ps, as a task")
			helpers.assert_eq(ps.args, { "-o", "%cpu=,rss=", "-p", tostring(hs.processInfo.processID) })
			-- A decimal comma under some locales; one core is 100 %
			ps.on_done(0, " 20,0  51200\n")
			helpers.assert_nil(answer_of(answers, "cpu_load"), "one step is not the whole probe")
			sampler.callback({ { active = 50 }, { active = 30 }, overall = { active = 40.04 }, n = 2 })
			local answer = answer_of(answers, "cpu_load")
			helpers.assert_eq(answer.result.state, "ok")
			helpers.assert_eq(answer.sections.system.cpu_usage, 40)
			helpers.assert_eq(answer.sections.system.process_cpu, 10, "20 % of one core is 10 % of two")
			helpers.assert_eq(answer.sections.system.process_memory, 51200 * 1024)
		end)
	end)

	helpers.it("a cancelled run publishes nothing and stops its requests and tasks", function()
		with_probes(function(Probes, world)
			local run, answers = start(Probes, { logs_dir = "/tmp/logs" })
			local before = #answers
			run.cancel()
			world.requests[1].callback({ status = 200, body = "{}" })
			world.tasks[1].on_done(0, "x\ny\n1\n")
			helpers.assert_eq(#answers, before, "nothing of a cancelled run reaches the page")
			helpers.assert_true(world.cancelled_requests >= 1)
			helpers.assert_eq(world.terminated, 3, "sysctl, df and ps are stopped")
			helpers.assert_eq(world.stopped_samplers, 1, "the processor sampler is stopped")
		end)
	end)
end)
