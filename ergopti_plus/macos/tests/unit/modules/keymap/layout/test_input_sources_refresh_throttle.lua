--- tests/unit/modules/keymap/layout/test_input_sources_refresh_throttle.lua

--- ==============================================================================
--- MODULE: Active Input-source Refresh Throttle
--- DESCRIPTION:
--- Civil clock corrections must not consume or extend a five-active-second
--- probe-admission budget. Real process, deadline and plist owners run over
--- independent clock ports; no subprocess, native setting or Cocoa is run.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"modules.keymap.input_sources", "modules.keymap.layout_install",
	"infra.logger", "infra.timings", "adapters.python_interpreter",
	"adapters.input_source_selector", "native_path", "adapters.shell_runner",
	"infra.deferred_work", "adapters.task_environment", "infra.launcher_environment",
	"diagnostics.runtime_log", "adapters.timer_scheduler", "error_description",
	"number_policy", "infra.openstep_plist",
}

--- Serializes exactly the native defaults array the real reader accepts.
--- @param names table Native KeyboardLayout Name values.
--- @return string output OpenStep property-list output.
local function native_output(names)
	local records = {}
	for _, name in ipairs(names) do
		records[#records + 1] = '{ InputSourceKind = "Keyboard Layout"; "KeyboardLayout Name" = "' .. name .. '"; }'
	end
	return "(" .. table.concat(records, ",") .. ")"
end

--- Composes the actual cache, process, environment and deadline owners.
--- @param scenario function Receives the public input-source API and native ports.
local function with_sources(scenario)
	return helpers.with_stub_scope(OWNED, function()
		local w = { awake = 0, wall = 1000, tasks = {}, timers = {},
			names = { "French" }, current = "French", errors = {} }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			w.errors[#w.errors + 1] = string.format(message, ...)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.timings"] = { sec = function(section, key)
			helpers.assert_eq(section, "ui")
			helpers.assert_eq(key, "input_source_operation_timeout_ms")
			return 10
		end }
		package.loaded["modules.keymap.layout_install"] = {
			highest_installed = function() return nil end,
			version_gt = function() return false end,
			USER_LAYOUTS_DIR = "/virtual/user-layouts", SYSTEM_LAYOUTS_DIR = "/virtual/system-layouts",
		}
		package.loaded["adapters.python_interpreter"] = { resolve = function() return "/virtual/native-python3" end }
		package.loaded["adapters.input_source_selector"] = {}
		_G.hs = {
			keycodes = {
				currentLayout = function() return w.current end,
				layouts = function()
					local names = {}; for i, name in ipairs(w.names) do names[i] = name end; return names
				end,
			},
			timer = {
				absoluteTime = function() return w.awake * 1e9 end,
				secondsSinceEpoch = function() return w.wall end,
				new = function(delay, callback)
					local timer = { delay = delay, active = false, stops = 0 }
					function timer:start() self.active = true; return self end
					function timer:stop() self.active = false; self.stops = self.stops + 1; return self end
					function timer:running() return self.active end
					function timer:deliver_retained_native_callback() callback() end
					w.timers[#w.timers + 1] = timer
					return timer
				end,
			},
			task = { new = function(executable, callback, arguments)
				local task = { executable = executable, arguments = arguments, active = false,
					env = {}, terminate_calls = 0 }
				function task:environment() return self.env end
				function task:setEnvironment(environment) self.env = environment; return self end
				function task:start() self.active = true; return self end
				function task:isRunning() return self.active end
				function task:terminate() self.terminate_calls = self.terminate_calls + 1; return self end
				function task:complete(code, output)
					self.active = false
					callback(code, output, "")
				end
				w.tasks[#w.tasks + 1] = task
				return task
			end },
		}
		local sources = require("modules.keymap.input_sources")
		local runner = require("adapters.shell_runner")
		local scheduler = require("adapters.timer_scheduler")
		function w.sample(awake, step)
			helpers.assert_true(awake >= w.awake, "the independent awake clock never regresses")
			w.awake, w.wall = awake, 1000 + awake + (step or 0)
		end
		function w.last_read()
			local task = w.tasks[#w.tasks]
			helpers.assert_type(task, "table", "a public list admission acquires a real native task")
			helpers.assert_eq(task.executable, "/usr/bin/defaults")
			helpers.assert_eq(table.concat(task.arguments, " "), "read com.apple.HIToolbox AppleEnabledInputSources")
			return task, w.timers[#w.timers]
		end
		function w.read()
			local done = 0
			helpers.assert_eq(sources.refresh_active_layouts_async(function() done = done + 1 end), true)
			local task, timer = w.tasks[#w.tasks], w.timers[#w.timers]
			helpers.assert_eq(task.executable, "/usr/bin/defaults")
			helpers.assert_eq(table.concat(task.arguments, " "), "read com.apple.HIToolbox AppleEnabledInputSources")
			return task, timer, function() return done end
		end
		function w.edit(mode, names, succeeded)
			local terminal = nil
			local function complete(ok) terminal = ok end
			if mode == "enable" then
				helpers.assert_eq(sources.enable_keylayout_source_async("/virtual/German.keylayout", "German", complete), true)
			else
				helpers.assert_eq(sources.disable_keylayout_source_async("French", "French", complete), true)
			end
			local task = w.tasks[#w.tasks]
			helpers.assert_eq(task.executable, "/virtual/native-python3")
			helpers.assert_eq(task.arguments[1], "-c")
			helpers.assert_eq(task.arguments[3], mode)
			return function()
				if succeeded ~= false then w.names, w.current = names, names[1] end
				task:complete(succeeded == false and 1 or 0, succeeded == false and "READ_ERR:fixture" or "OK\n")
				helpers.assert_eq(terminal, succeeded ~= false, "the real mutation terminal acknowledges the native result")
			end, task, w.timers[#w.timers]
		end
		function w.list()
			local names = {}
			for _, record in ipairs(sources.list_active_keyboard_layouts()) do names[#names + 1] = record.id end
			return table.concat(names, ",")
		end
		local body = table.pack(xpcall(scenario, debug.traceback, sources, w, runner))
		local cleanup = table.pack(xpcall(function()
			for _, task in ipairs(w.tasks) do
				if task.active then
					task:complete(0, task.executable == "/usr/bin/defaults" and native_output(w.names) or "OK\n")
				end
			end
			helpers.assert_eq(next(runner._active_tasks), nil, "every exact native task GC pin is retired")
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
			for _, timer in ipairs(w.timers) do helpers.assert_eq(timer.active, false) end
			for _, task in ipairs(w.tasks) do helpers.assert_eq(task.active, false) end
		end, debug.traceback))
		local failures = {}
		if not body[1] then failures[#failures + 1] = tostring(body[2]) end
		if not cleanup[1] then failures[#failures + 1] = "CLEANUP: " .. tostring(cleanup[2]) end
		for _, message in ipairs(w.errors) do failures[#failures + 1] = "CALLBACK: " .. message end
		if #failures > 0 then error(table.concat(failures, "\n"), 0) end
	end)
end

helpers.describe("active input-source refresh uses a five-awake-second budget", function()
	helpers.it("admits the first public list probe at a valid awake zero sample", function()
		with_sources(function(_, w)
			helpers.assert_eq(w.list(), "French")
			helpers.assert_eq(#w.tasks, 1, "no previous sample must admit even when awake time is zero")
			local task, deadline = w.last_read()
			helpers.assert_eq(task.active, true)
			task:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(deadline.active, false)
			helpers.assert_eq(w.list(), "French,German")
			helpers.assert_eq(#w.tasks, 1)
		end)
	end)

	helpers.it("keeps rapid reads throttled and admits a probe at exactly five active seconds", function()
		with_sources(function(_, w)
			w.list()
			local first = w.last_read()
			first:complete(0, native_output({ "French" }))
			w.sample(4.999)
			helpers.assert_eq(w.list(), "French")
			helpers.assert_eq(#w.tasks, 1)
			w.sample(5)
			helpers.assert_eq(w.list(), "French")
			helpers.assert_eq(#w.tasks, 2, "the strict less-than guard admits at the unchanged five-second boundary")
			local next_read = w.last_read()
			next_read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(w.list(), "French,German")
		end)
	end)

	helpers.it("refreshes enabled-source membership after five active seconds despite a civil rollback", function()
		with_sources(function(sources, w)
			w.list()
			local first = w.last_read()
			first:complete(0, native_output({ "French" }))
			-- An external OS change is the next defaults result, not an owned edit
			-- or an artificial direct cache setter/invalidation.
			w.names = { "French", "German" }
			w.sample(6, -60)
			helpers.assert_eq(w.list(), "French", "the old cache stays available until its new read completes")
			helpers.assert_eq(#w.tasks, 2, "civil rollback must not extend the five-active-second refresh budget")
			local next_read = w.last_read()
			next_read:complete(0, native_output(w.names))
			helpers.assert_eq(w.list(), "French,German", "the subsequent read sees newly enabled membership")
			w.current = "German"
			local records = sources.list_active_keyboard_layouts()
			helpers.assert_eq(records[1].selected, false)
			helpers.assert_eq(records[2].selected, true, "selected flags still follow the live current layout")
		end)
	end)

	helpers.it("does not spend a civil advance as the five-active-second probe budget", function()
		with_sources(function(_, w)
			w.list()
			local first = w.last_read()
			first:complete(0, native_output({ "French" }))
			w.sample(1, 60)
			helpers.assert_eq(w.list(), "French")
			helpers.assert_eq(#w.tasks, 1, "civil advance must not admit a second probe before five active seconds")
			w.sample(5, 60)
			w.list()
			helpers.assert_eq(#w.tasks, 2)
			local next_read = w.last_read()
			next_read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(w.list(), "French,German")
		end)
	end)

	helpers.it("admits a fresh probe immediately after real enabled-list invalidation at awake zero", function()
		with_sources(function(_, w)
			w.list()
			local first = w.last_read()
			first:complete(0, native_output({ "French" }))
			local edited = w.edit("enable", { "French", "German" })
			edited()
			helpers.assert_eq(w.awake, 0)
			helpers.assert_eq(w.list(), "French,German")
			helpers.assert_eq(#w.tasks, 3, "successful invalidation clears the sample without confusing nil and zero")
			local next_read = w.last_read()
			next_read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(w.list(), "French,German")
			helpers.assert_eq(#w.tasks, 3)
		end)
	end)

	helpers.it("preserves live-probe joining and explicit refresh bypass without changing retirement", function()
		with_sources(function(sources, w, runner)
			w.list()
			local first, first_deadline = w.last_read()
			local joined = 0
			helpers.assert_eq(sources.refresh_active_layouts_async(function() joined = joined + 1 end), false)
			w.sample(5)
			w.list()
			helpers.assert_eq(#w.tasks, 1, "an eligible refresh joins the exact still-live read")
			helpers.assert_eq(first.active, true)
			first:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(joined, 1)
			helpers.assert_eq(first_deadline.active, false)
			helpers.assert_eq(runner._active_tasks[first], nil)
			helpers.assert_eq(first.terminate_calls, 0)
			w.sample(5.1)
			helpers.assert_eq(w.list(), "French,German")
			helpers.assert_eq(#w.tasks, 1)
			local direct, _, done = w.read()
			helpers.assert_eq(#w.tasks, 2, "the startup-prime refresh API still bypasses list throttling")
			direct:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(done(), 1)
			w.sample(10)
			w.list()
			helpers.assert_eq(#w.tasks, 3, "joining kept the original refresh-attempt anchor policy")
			local final = w.last_read()
			final:complete(0, native_output({ "French", "German" }))
		end)
	end)
end)
