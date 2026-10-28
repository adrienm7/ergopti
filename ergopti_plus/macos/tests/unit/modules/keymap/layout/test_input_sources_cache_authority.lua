--- tests/unit/modules/keymap/layout/test_input_sources_cache_authority.lua

--- ==============================================================================
--- MODULE: Enabled Input-source Cache Authority
--- DESCRIPTION:
--- A successful edit must not be overwritten by an earlier defaults read.
--- Delivers retained native task callbacks through the real process, deadline
--- and plist owners; no command, input-source mutation or Cocoa callback runs.
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
		local w = { tasks = {}, timers = {}, names = { "French" }, current = "French", errors = {} }
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
				absoluteTime = function() return 1000000000 end,
				secondsSinceEpoch = function() return 1000 end,
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

helpers.describe("enabled-list edits retire older read authority", function()
	helpers.it("publishes an ordinary native read while its enabled-list generation is current", function()
		with_sources(function(_, w)
			local read, _, done = w.read()
			read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(done(), 1)
			helpers.assert_eq(w.list(), "French,German")
		end)
	end)

	helpers.it("does not hide an enabled source when an earlier native read completes late", function()
		with_sources(function(_, w, runner)
			local read, deadline, done = w.read()
			local edited = w.edit("enable", { "French", "German" })
			edited()
			helpers.assert_eq(read.active, true, "editing does not discard a live read capability")
			read:complete(0, native_output({ "French" }))
			helpers.assert_eq(done(), 1)
			helpers.assert_eq(deadline.active, false)
			helpers.assert_eq(runner._active_tasks[read], nil)
			helpers.assert_eq(read.terminate_calls, 0)
			helpers.assert_eq(w.list(), "French,German", "an older read must not hide the committed enabled source")
		end)
	end)

	helpers.it("does not restore a disabled source when an earlier native read completes late", function()
		with_sources(function(_, w)
			w.names = { "French", "German" }
			local read, _, done = w.read()
			local edited = w.edit("disable", { "German" })
			edited()
			read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(done(), 1)
			helpers.assert_eq(w.list(), "German", "an older read must not resurrect the committed disabled source")
		end)
	end)

	helpers.it("accepts the next native refresh normally after the older read retires", function()
		with_sources(function(_, w)
			local read = w.read()
			local edited = w.edit("enable", { "French", "German" })
			edited()
			read:complete(0, native_output({ "French" }))
			w.list()
			local next_read = w.tasks[#w.tasks]
			helpers.assert_eq(next_read.executable, "/usr/bin/defaults")
			helpers.assert_true(next_read ~= read)
			next_read:complete(0, native_output({ "French", "German" }))
			helpers.assert_eq(w.list(), "French,German")
		end)
	end)

	helpers.it("preserves a pending read when an enabled-list edit fails", function()
		with_sources(function(_, w)
			local read = w.read()
			local edited = w.edit("enable", { "French" }, false)
			edited()
			read:complete(0, native_output({ "French" }))
			helpers.assert_eq(w.list(), "French")
		end)
	end)

	helpers.it("settles an older read without cancelling a later in-flight edit", function()
		with_sources(function(_, w)
			local read, read_deadline, done = w.read()
			local enabled = w.edit("enable", { "French", "German" })
			enabled()
			local disabled, editing, edit_deadline = w.edit("disable", { "German" })
			read:complete(0, native_output({ "French" }))
			helpers.assert_eq(done(), 1)
			helpers.assert_eq(read_deadline.active, false)
			helpers.assert_eq(editing.active, true)
			helpers.assert_eq(editing.terminate_calls, 0)
			helpers.assert_eq(edit_deadline.active, true)
			disabled()
			helpers.assert_eq(w.list(), "German")
		end)
	end)
end)
