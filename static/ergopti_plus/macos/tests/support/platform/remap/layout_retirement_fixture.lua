--- tests/support/platform/remap/layout_retirement_fixture.lua
--- Actual layout watcher, ShellRunner and Scheduler over explicit native task/timer ports.
local helpers = require("tests.helpers")
local M = {}
local OWNED = {
	"platform.remap.watchers", "adapters.shell_runner", "adapters.timer_scheduler",
	"adapters.input_source_broker", "adapters.task_environment", "infra.launcher_environment",
	"infra.deferred_work", "diagnostics.runtime_log", "infra.logger", "infra.timings", "infra.keycodes",
	"adapters.key_state", "adapters.mouse_control", "adapters.hotkey_registrar",
	"platform.remap.lease_contract", "platform.remap.ke_variables", "infra.capsword_auto_off",
	"infra.capsword_output", "caps_word.auto_off",
}

--- Owns only this process's modeled native handles; no OS process is spawned.
--- @param options table Native termination delivery controls.
--- @param callback function Receives the real adapter composition.
--- @return any result
function M.with_world(options, callback)
	return helpers.with_stub_scope(OWNED, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function(_, key) return key == "layout_poll_ms" and 1 or 0.1 end }
		package.loaded["infra.keycodes"] = { F17_CYCLE_WINDOWS = 64, to_name = function() return "f17" end }
		for _, name in ipairs({ "adapters.key_state", "adapters.mouse_control", "adapters.hotkey_registrar",
			"platform.remap.lease_contract", "platform.remap.ke_variables", "infra.capsword_auto_off",
			"infra.capsword_output", "caps_word.auto_off" }) do package.loaded[name] = {} end
		local w = { now = 0, timers = {}, tasks = {}, changes = {} }
		local function timer(delay, action)
			local native = { delay = delay, callback = action, live = false }
			function native:start() self.live = true; return self end
			function native:stop() self.live = false; return self end
			function native:running() return self.live end
			function native:fire() assert(self.live); w.now = w.now + self.delay; self.callback() end
			w.timers[#w.timers + 1] = native
			return native
		end
		_G.hs = {
			timer = { absoluteTime = function() return math.floor(w.now * 1e9) end,
				secondsSinceEpoch = function() return 1900000000 + w.now end, new = timer,
				doAfter = function(delay, action) return timer(delay, action):start() end },
			keycodes = { currentLayout = function() return "ABC" end,
				inputSourceChanged = function(fn) w.native_callback = fn end },
			task = { new = function(executable, done, args)
				assert(executable == "/usr/bin/defaults")
				assert(table.concat(args, "|") == "read|com.apple.HIToolbox|AppleSelectedInputSources")
				local native = { running = false, env = {}, terminations = 0, callback = done }
				function native:start() self.running = true; return self end
				function native:isRunning() return self.running end
				function native:environment() return self.env end
				function native:setEnvironment(env) self.env = env; return self end
				function native:closeInput() return self end
				function native:finish(code)
					self.running = false
					self.callback(code or 0, '"KeyboardLayout Name" = ABC;', "")
				end
				function native:terminate()
					self.terminations = self.terminations + 1
					if options.complete_on_terminate then self:finish(143) end
					-- Native hs.task accepts SIGTERM and returns self without joining exit.
					return self
				end
				w.tasks[#w.tasks + 1] = native
				return native
			end },
		}
		w.shell = require("adapters.shell_runner")
		w.scheduler = require("adapters.timer_scheduler")
		w.watchers = require("platform.remap.watchers")
		function w.start()
			local accepted = w.watchers.start_input_source_watcher(function(layout) w.changes[#w.changes + 1] = layout end)
			if accepted then
				for index = #w.timers, 1, -1 do
					local native = w.timers[index]
					if native.delay == 1 and native.live then w.poll = native; break end
				end
				assert(w.poll and w.poll.live)
			end
			return accepted
		end
		function w.timeout()
			for _, native in ipairs(w.timers) do
				if native.delay == 5 and native.live then native:fire(); return end
			end
			error("actual scheduler watchdog unavailable")
		end
		function w.counts()
			local live, pins = 0, 0
			for _, native in ipairs(w.tasks) do if native.running then live = live + 1 end end
			for _ in pairs(w.shell._active_tasks) do pins = pins + 1 end
			return { native = live, pins = pins, constructed = #w.tasks }
		end
		local outcome = table.pack(xpcall(function() return callback(w) end, debug.traceback))
		for _, native in ipairs(w.tasks) do if native.running then native:finish(143) end end
		assert(w.watchers.stop_input_source_watcher() == true, "watcher cleanup remains pending")
		assert(w.counts().native == 0 and w.counts().pins == 0 and w.scheduler.activeCount() == 0)
		for _, native in ipairs(w.timers) do assert(not native.live, "native timer remains") end
		if not outcome[1] then error(outcome[2], 0) end
		return table.unpack(outcome, 2, outcome.n)
	end)
end

return M
