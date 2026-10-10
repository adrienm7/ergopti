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
	"adapters.shell_runner", "adapters.json_codec", "modules.llm", "ui.healthcheck.appleevents",
}

--- Runs body with the real probes over recorded adapters.
--- @param body function(Probes, world)
local function with_probes(body)
	local saved_shell_runner = package.loaded["adapters.shell_runner"]
	helpers.with_stub_scope(FIXTURE_MODULES, function()
		helpers.load_with_stubs("infra.logger")
		local world = { timers = {}, requests = {}, tasks = {}, cancelled_requests = 0, terminated = 0, llm_on = false,
			samplers = {}, stopped_samplers = 0, errors = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			local ok, text = pcall(string.format, tostring(message), ...)
			world.errors[#world.errors + 1] = ok and text or tostring(message)
		end
		package.loaded["infra.logger"] = logger
		-- The callback form, which samples on its own timer; the blocking form
		-- (no callback) is never what a probe may call. Restored on the same
		-- table, whichever runtime the scope installed. Shaped like hs.host's
		-- sampler: its timer is cleared before the callback runs, and stop()
		-- indexes that timer, so stopping a sampler that already answered raises
		-- exactly as it does on a Mac.
		local host = hs.host
		local saved_cpu_usage = host.cpuUsage
		host.cpuUsage = function(period, callback)
			if type(callback) ~= "function" then error("hs.host.cpuUsage called without a callback blocks") end
			local sampler = { period = period, callbackTimer = {} }
			function sampler:finished() return self.callbackTimer == nil end
			function sampler:stop()
				self.callbackTimer.stopped = true
				self.callbackTimer = nil
				world.stopped_samplers = world.stopped_samplers + 1
				return self
			end
			-- What the sampling timer does when it fires
			function sampler.callback(result)
				sampler.callbackTimer = nil
				callback(result)
			end
			world.samplers[#world.samplers + 1] = sampler
			return sampler
		end
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local handle = { delay = delay, callback = callback }
				world.timers[#world.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.cancelled = true
				if handle.on_settled then handle.on_settled() end
				return true
			end,
			onSettled = function(handle, callback) handle.on_settled = callback; return true end,
		}
		-- The five existing probes use their original controlled adapters. The
		-- sixth collaborator is deliberately NOT_RUN; its real body has a
		-- separate behavioral suite and must not spawn under these old ports.
		package.loaded["ui.healthcheck.appleevents"] = {
			body = function(config)
				return function(done, register_cancel, started_ms)
					world.appleevent_started = started_ms
					world.appleevent_timeout = config.timeout_ms
					local actor = { snapshot = function() return { cleanup = "settled" } end }
					register_cancel(function() world.appleevent_cancelled = true end)
					done({ state = "not_run", detail = "separate_inert_owner_suite", cleanup = "settled" })
					return actor
				end
			end,
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

--- The probes of the real schema, started on a phase A snapshot with a recorder.
--- @param Probes table
--- @param paths table|nil The snapshot's paths section.
--- @param options table|nil { usb = the phase A peripherals, detailed = boolean }
--- @return table run, table answers
local function start(Probes, paths, options)
	options = options or {}
	local schema = require("healthcheck.snapshot").load_config(require("infra.paths").shared).schema
	local answers = {}
	local snapshot = {
		detailed = options.detailed == true,
		extensive = true,
		sections = { paths = paths or {}, peripherals = { items = options.usb or {} } },
	}
	local run = Probes.start(schema, snapshot, function(id, result, sections)
		answers[#answers + 1] = { id = id, result = result, sections = sections }
	end)
	return run, answers
end

-- What system_profiler prints for a Magic Keyboard and a mouse in use, a
-- headset in use, and a trackpad paired but away; with the addresses and
-- serial numbers it also prints
local BLUETOOTH_REPORT = [[{
  "SPBluetoothDataType" : [ {
    "controller_properties" : { "controller_address" : "AA:BB:CC:DD:EE:FF" },
    "device_connected" : [
      { "Magic Keyboard" : { "device_address" : "11:22:33:44:55:66", "device_minorType" : "Keyboard",
          "device_productID" : "0x029C", "device_serialNumber" : "F0T123", "device_vendorID" : "0x004C" } },
      { "MX Master 3" : { "device_address" : "22:33:44:55:66:77", "device_minorType" : "Mouse",
          "device_productID" : "0xB023", "device_vendorID" : "0x046D" } },
      { "AirPods Pro" : { "device_address" : "33:44:55:66:77:88", "device_minorType" : "Headphones",
          "device_productID" : "0x200E", "device_vendorID" : "0x004C" } }
    ],
    "device_not_connected" : [
      { "Magic Trackpad" : { "device_address" : "44:55:66:77:88:99", "device_minorType" : "Trackpad",
          "device_productID" : "0x0265", "device_vendorID" : "0x004C" } }
    ]
  } ]
}]]

-- A USB device phase A listed
local USB_KEYBOARD = { bus = "usb", kind = "keyboard", vendor_id = "05ac", product_id = "024f" }

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

--- Runs the actual registry with one retained actor and exact refused watchdog.
--- @param body function(run, answers, controls) Drives cleanup acknowledgements.
local function with_retained_actor(body)
	with_probes(function(Probes, world)
		local controls = { actor_ack = false, watchdog_ack = false, actor_calls = 0, watchdog_calls = 0 }
		local actor = {
			snapshot = function() return { cleanup = controls.actor_ack and "settled" or "pending" } end,
			cancel = function() controls.actor_calls = controls.actor_calls + 1 end,
		}
		package.loaded["ui.healthcheck.appleevents"] = {
			body = function()
				return function(done, register_cancel)
					controls.complete = done
					register_cancel(actor.cancel)
					return actor
				end
			end,
		}
		local run, answers = start(Probes)
		controls.watchdog = assert(run.watchdogs.appleevent_transport)
		local scheduler = package.loaded["adapters.timer_scheduler"]
		local original_cancel = scheduler.cancel
		scheduler.cancel = function(handle)
			if handle == controls.watchdog then
				controls.watchdog_calls = controls.watchdog_calls + 1
				if not controls.watchdog_ack then return false end
			end
			return original_cancel(handle)
		end
		body(run, answers, controls)
	end)
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

	helpers.it("adds the connected Bluetooth keyboards and mice to the USB devices (bluetooth-peripherals)", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes, nil, { usb = { USB_KEYBOARD } })
			local profiler = task_of(world, "/usr/sbin/system_profiler")
			helpers.assert_true(profiler ~= nil, "hs.usb sees no Bluetooth device: system_profiler reads them, as a task")
			helpers.assert_eq(profiler.args, { "SPBluetoothDataType", "-json" })
			profiler.on_done(0, BLUETOOTH_REPORT)
			local answer = answer_of(answers, "bluetooth")
			helpers.assert_eq(answer.result.state, "ok")
			helpers.assert_eq(answer.sections.peripherals.items, {
				USB_KEYBOARD,
				{ bus = "bluetooth", kind = "keyboard", vendor_id = "004c", product_id = "029c" },
				{ bus = "bluetooth", kind = "mouse", vendor_id = "046d", product_id = "b023" },
			}, "input devices in use only, without their names, addresses or serial numbers")
		end)
	end)

	helpers.it("names the Bluetooth devices only when details are included (bluetooth-peripherals)", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes, nil, { detailed = true })
			task_of(world, "/usr/sbin/system_profiler").on_done(0, BLUETOOTH_REPORT)
			local items = answer_of(answers, "bluetooth").sections.peripherals.items
			helpers.assert_eq(#items, 2)
			helpers.assert_eq(items[1].name, "Magic Keyboard")
			helpers.assert_eq(items[2].name, "MX Master 3")
		end)
	end)

	helpers.it("reports an unreadable Bluetooth report as an error (bluetooth-peripherals)", function()
		with_probes(function(Probes, world)
			local _, answers = start(Probes, nil, { usb = { USB_KEYBOARD } })
			task_of(world, "/usr/sbin/system_profiler").on_done(0, "not json")
			local answer = answer_of(answers, "bluetooth")
			helpers.assert_eq(answer.result.state, "error")
			helpers.assert_nil(answer.sections, "the USB list on the page stays as phase A read it")
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
			for _, message in ipairs(world.errors) do
				helpers.assert_true(not message:find("could not be stopped", 1, true),
					"a sampler that already answered must not be stopped again: " .. message)
			end
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
			helpers.assert_eq(world.terminated, 4, "sysctl, df, ps and system_profiler are stopped")
			helpers.assert_eq(world.stopped_samplers, 1, "the processor sampler is stopped")
		end)
	end)
	helpers.it("passes the original start clock to the separately controlled AppleEvent collaborator", function()
		with_probes(function(Probes, world)
			local timer = hs.timer
			local scheduler = require("adapters.timer_scheduler")
			local saved_clock, saved_after = timer.absoluteTime, scheduler.after
			local now_ns, watchdog_starts = 12345 * 1e6, {}
			timer.absoluteTime = function() return now_ns end
			scheduler.after = function(delay, callback)
				-- Capture the original watchdog clock before registration deliberately advances it.
				watchdog_starts[#watchdog_starts + 1] = now_ns / 1e6
				local handle, committed = saved_after(delay, callback)
				now_ns = now_ns + 17 * 1e6
				return handle, committed
			end
			local ok, err = pcall(function()
				local run, answers = start(Probes)
				local original_start = watchdog_starts[#world.timers]
				helpers.assert_true(type(original_start) == "number", "the collaborator has an original watchdog registration")
				helpers.assert_true(original_start < now_ns / 1e6, "watchdog registration advanced the controlled clock")
				helpers.assert_eq(world.appleevent_started, original_start)
				helpers.assert_true(type(world.appleevent_timeout) == "number" and world.appleevent_timeout > 0)
				helpers.assert_eq(answer_of(answers, "appleevent_transport").result.state, "not_run")
				helpers.assert_eq(run.has_pending_cleanup(), false, "the closed collaborator and watchdog both acknowledge cleanup")
			end)
			scheduler.after = saved_after
			timer.absoluteTime = saved_clock
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("repeated Cancel retries exact retained actor and watchdog without reviving business results", function()
		for _, prior in ipairs({ "error", "cancelled" }) do
			with_retained_actor(function(run, answers, controls)
				if prior == "error" then
					controls.complete({ state = "error", detail = "permission_refused", cleanup = "pending" })
				end
				run.cancel()
				local original = run.results.appleevent_transport
				helpers.assert_eq(original.state, prior)
				helpers.assert_eq(original.cleanup, "pending")
				helpers.assert_eq(run.has_pending_cleanup(), true)
				helpers.assert_true(run.actors.appleevent_transport ~= nil)
				helpers.assert_true(run.watchdogs.appleevent_transport == controls.watchdog)
				local actor_calls, watchdog_calls, published = controls.actor_calls, controls.watchdog_calls, #answers
				controls.actor_ack, controls.watchdog_ack = true, true
				run.cancel()
				helpers.assert_eq(controls.actor_calls, actor_calls + 1)
				helpers.assert_eq(controls.watchdog_calls, watchdog_calls + 1)
				helpers.assert_eq(run.has_pending_cleanup(), false)
				helpers.assert_true(run.results.appleevent_transport == original)
				helpers.assert_eq(original.state, prior)
				helpers.assert_eq(original.detail, prior == "error" and "permission_refused" or nil)
				helpers.assert_eq(original.cleanup, "settled")
				helpers.assert_eq(#answers, published, "cleanup acknowledgement must not republish business completion")
			end)
		end
	end)

	helpers.it("Cancel retries archived cohort capabilities before releasing their cleanup owner", function()
		with_retained_actor(function(run, answers, controls)
			local Cleanup = require("healthcheck.cleanup")
			local session = { probes = run, snapshot = { probes = run.results } }
			Cleanup.archive(session)
			helpers.assert_true(session.probes == nil)
			helpers.assert_true(session.probe_history[1].run == run)
			local original = run.results.appleevent_transport
			helpers.assert_eq(original.state, "cancelled")
			helpers.assert_eq(original.cleanup, "pending")
			local actor_calls, watchdog_calls, published = controls.actor_calls, controls.watchdog_calls, #answers
			controls.actor_ack, controls.watchdog_ack = true, true
			Cleanup.cancel(session)
			helpers.assert_eq(controls.actor_calls, actor_calls + 1)
			helpers.assert_eq(controls.watchdog_calls, watchdog_calls + 1)
			helpers.assert_true(session.probe_history[1].run == nil, "release only after exact capability ACKs")
			helpers.assert_true(session.snapshot.retired_probes[1].probes.appleevent_transport == original)
			helpers.assert_eq(original.state, "cancelled")
			helpers.assert_eq(original.cleanup, "settled")
			helpers.assert_eq(#answers, published)
		end)
	end)

end)
