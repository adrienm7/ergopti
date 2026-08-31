--- tests/unit/modules/shortcuts/test_system_mouse_pause_ownership.lua

--- ==============================================================================
--- MODULE: System Mouse Composite Pause Ownership
--- DESCRIPTION:
--- Drives the real SystemMouse owner and TimerScheduler against mutation-sensitive
--- native timer, eventtap, canvas, and ShellRunner doubles. The suite proves that
--- PAUSE fences business work before cleanup, retains every exact refused handle,
--- and lets RESUME reopen admission without replaying an interrupted user action.
--- ==============================================================================

local helpers = require("tests.helpers")

local ORIGINAL_IO_OPEN = io.open





-- ==================================================
-- ==================================================
-- ======= 1/ Faithful Composite Test Harness =======
-- ==================================================
-- ==================================================

--- Formats one captured log message without depending on the production logger.
--- @param template string Log format string.
--- @param ... any Format arguments.
--- @return string message
local function format_log(template, ...)
	local ok, message = pcall(string.format, tostring(template), ...)
	return ok and message or tostring(template)
end

--- Builds a fresh SystemMouse owner with observable native capability identities.
--- @return table fixture Test fixture.
local function fresh_mouse_owner()
	for _, name in ipairs({
		"modules.shortcuts.actions.system_mouse",
		"adapters.timer_scheduler",
		"adapters.shell_runner",
		"adapters.mouse_control",
		"adapters.synthetic_input",
		"infra.logger",
		"infra.notifications",
		"infra.i18n",
	}) do package.loaded[name] = nil end

	local fixture = {
		native_timers = {},
		next_timer_options = {},
		canvases = {},
		next_canvas_options = {},
		taps = {},
		next_tap_options = {},
		shells = {},
		next_shell_options = {},
		logs = {},
		notifications = {},
		mouse_moves = 0,
		emoji_events = 0,
		lock_calls = 0,
		io_open_calls = 0,
		start_hook = nil,
		boundary_hook = nil,
		nested_pause_result = nil,
	}

	--- Queues one native timer behavior for the next TimerScheduler acquisition.
	--- @param options table Timer behavior.
	function fixture.queue_timer(options)
		fixture.next_timer_options[#fixture.next_timer_options + 1] = options or {}
	end

	--- Queues one canvas behavior for the next spotlight canvas.
	--- @param options table Canvas behavior.
	function fixture.queue_canvas(options)
		fixture.next_canvas_options[#fixture.next_canvas_options + 1] = options or {}
	end

	--- Queues one eventtap behavior for the next spotlight watcher.
	--- @param options table Eventtap behavior.
	function fixture.queue_tap(options)
		fixture.next_tap_options[#fixture.next_tap_options + 1] = options or {}
	end

	--- Queues one exact ShellRunner handle behavior.
	--- @param options table Process behavior.
	function fixture.queue_shell(options)
		fixture.next_shell_options[#fixture.next_shell_options + 1] = options or {}
	end

	local primary_screen = {
		id = function() return 1 end,
		name = function() return "Primary" end,
		frame = function() return { x = 0, y = 0, w = 1200, h = 800 } end,
	}
	local secondary_screen = {
		id = function() return 2 end,
		name = function() return "Secondary" end,
		frame = function() return { x = 1200, y = 0, w = 1000, h = 700 } end,
	}

	local hs_stub = {
		mouse = {
			absolutePosition = function() return { x = 250, y = 300 } end,
			getCurrentScreen = function() return primary_screen end,
		},
		screen = {
			allScreens = function() return { primary_screen, secondary_screen } end,
		},
		canvas = {
			windowLevels = { overlay = 7 },
		},
		eventtap = {
			event = { types = { mouseMoved = 5 } },
		},
		caffeinate = {
			lockScreen = function()
				if type(fixture.boundary_hook) == "function" then
					fixture.boundary_hook("lock")
				end
				fixture.lock_calls = fixture.lock_calls + 1
				return true
			end,
		},
		timer = {},
	}

	hs_stub.timer.new = function(delay, callback)
		local options = table.remove(fixture.next_timer_options, 1) or {}
		local timer = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			start_mode = options.start_mode or "success",
			stop_mode = options.stop_mode or "success",
		}
		function timer:start()
			self.start_calls = self.start_calls + 1
			if self.start_mode == "false_mutate" then
				self.running_state = true
				return false
			end
			if self.start_mode == "nil_mutate" then
				self.running_state = true
				return nil
			end
			if self.start_mode == "throw_mutate" then
				self.running_state = true
				error("native timer start exploded")
			end
			self.running_state = true
			return self
		end
		function timer:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("native timer stop exploded") end
			self.running_state = false
			return self
		end
		function timer:running() return self.running_state end
		function timer:fire()
			if self.running_state then self.callback() end
		end
		function timer:deliver() self.callback() end
		fixture.native_timers[#fixture.native_timers + 1] = timer
		return timer
	end
	hs_stub.timer.secondsSinceEpoch = function() return 1 end
	hs_stub.timer.absoluteTime = function() return 1000000000 end

	hs_stub.canvas.new = function(frame)
		local options = table.remove(fixture.next_canvas_options, 1) or {}
		local canvas = {
			frame = frame,
			showing = false,
			deleted = false,
			delete_calls = 0,
			delete_identities = {},
			delete_mode = options.delete_mode or "success",
			show_mode = options.show_mode or "success",
		}
		function canvas:level()
			return self
		end
		function canvas:show()
			if self.show_mode == "false_mutate" then self.showing = true; return false end
			if self.show_mode == "nil_mutate" then self.showing = true; return nil end
			if self.show_mode == "throw_mutate" then
				self.showing = true
				error("native canvas show exploded")
			end
			self.showing = true
			return self
		end
		function canvas:isShowing() return self.showing end
		function canvas:delete()
			self.delete_calls = self.delete_calls + 1
			self.delete_identities[self.delete_calls] = self
			if self.delete_mode == "false" then return false end
			if self.delete_mode == "nil" then return nil end
			if self.delete_mode == "throw" then error("native canvas delete exploded") end
			self.showing = false
			self.deleted = true
			return nil
		end
		fixture.canvases[#fixture.canvases + 1] = canvas
		return canvas
	end

	hs_stub.eventtap.new = function(types, callback)
		local options = table.remove(fixture.next_tap_options, 1) or {}
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			start_mode = options.start_mode or "success",
			stop_mode = options.stop_mode or "success",
		}
		function tap:start()
			self.start_calls = self.start_calls + 1
			if self.start_mode == "false_mutate" then self.enabled = true; return false end
			if self.start_mode == "nil_mutate" then self.enabled = true; return nil end
			if self.start_mode == "throw_mutate" then
				self.enabled = true
				error("native eventtap start exploded")
			end
			self.enabled = true
			return self
		end
		function tap:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("native eventtap stop exploded") end
			self.enabled = false
			return self
		end
		function tap:isEnabled() return self.enabled end
		function tap:deliver() return self.callback({}) end
		fixture.taps[#fixture.taps + 1] = tap
		return tap
	end

	local shell_runner = {}
	function shell_runner.spawn(executable, args, callback)
		local options = table.remove(fixture.next_shell_options, 1) or {}
		local handle = {
			executable = executable,
			args = args,
			callback = callback,
			settled = false,
			running = false,
			start_calls = 0,
			terminate_calls = 0,
			terminate_identities = {},
			observer_registrations = 0,
			observers = {},
			start_mode = options.start_mode or "success",
			terminate_mode = options.terminate_mode or "pending",
			sync_terminal = options.sync_terminal,
		}
		function handle.isSettled() return handle.settled end
		function handle.onSettled(observer)
			handle.observer_registrations = handle.observer_registrations + 1
			if handle.settled then observer()
			else handle.observers[#handle.observers + 1] = observer end
			return true
		end
		function handle:deliver(...)
			local first = self.settled ~= true
			self.running = false
			self.settled = true
			self.callback(...)
			if first then
				local observers = self.observers
				self.observers = {}
				for _, observer in ipairs(observers) do observer() end
			end
		end
		function handle.start()
			handle.start_calls = handle.start_calls + 1
			local mode = handle.start_mode
			if mode == "false_mutate" or mode == "nil_mutate"
				or mode == "throw_mutate" or mode == "sync_true"
				or mode == "sync_false" then
				handle.running = true
			end
			if type(fixture.start_hook) == "function" then fixture.start_hook(handle) end
			if handle.sync_terminal then
				handle:deliver(table.unpack(handle.sync_terminal, 1,
					handle.sync_terminal.n))
			end
			if mode == "false_mutate" or mode == "sync_false" then return false end
			if mode == "nil_mutate" then return nil end
			if mode == "throw_mutate" then error("ShellRunner start exploded") end
			handle.running = handle.settled ~= true
			return true
		end
		function handle.terminate()
			handle.terminate_calls = handle.terminate_calls + 1
			handle.terminate_identities[handle.terminate_calls] = handle
			if handle.settled then return true, "settled" end
			if handle.terminate_mode == "false" then return false, "refused" end
			if handle.terminate_mode == "nil" then return nil, "refused" end
			if handle.terminate_mode == "throw" then error("ShellRunner terminate exploded") end
			if handle.terminate_mode == "sync" then
				handle:deliver(-15, "", "terminated")
				return true, "settled"
			end
			return true, "pending"
		end
		fixture.shells[#fixture.shells + 1] = handle
		return handle
	end

	local logger = helpers.make_logger_stub()
	for _, level in ipairs({
		"debug", "trace", "done", "info", "start", "success", "warn", "error",
	}) do
		logger[level] = function(_, template, ...)
			fixture.logs[#fixture.logs + 1] = {
				level = level,
				message = format_log(template, ...),
			}
		end
	end

	io.open = function(...)
		fixture.io_open_calls = fixture.io_open_calls + 1
		return ORIGINAL_IO_OPEN(...)
	end

	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = {
		notify = function(message, _, level)
			fixture.notifications[#fixture.notifications + 1] = {
				message = message,
				level = level,
			}
			return true
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["adapters.mouse_control"] = {
		setPos = function()
			if type(fixture.boundary_hook) == "function" then
				fixture.boundary_hook("teleport")
			end
			fixture.mouse_moves = fixture.mouse_moves + 1
			return true
		end,
	}
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function()
			if type(fixture.boundary_hook) == "function" then
				fixture.boundary_hook("emoji")
			end
			fixture.emoji_events = fixture.emoji_events + 1
			return true
		end,
	}
	package.loaded["adapters.shell_runner"] = shell_runner
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.shortcuts.actions.system_mouse"] = nil
	fixture.subject = require("modules.shortcuts.actions.system_mouse")
	return fixture
end

--- Counts captured log records matching a level and substring.
--- @param fixture table Test fixture.
--- @param level string Log level.
--- @param fragment string Plain substring.
--- @return integer count
local function count_logs(fixture, level, fragment)
	local count = 0
	for _, record in ipairs(fixture.logs) do
		if record.level == level and record.message:find(fragment, 1, true) then
			count = count + 1
		end
	end
	return count
end

--- Arms the spotlight eventtap by firing the real scheduler's arm timer.
--- @param fixture table Test fixture.
--- @return table tap Exact native eventtap.
local function arm_spotlight(fixture)
	helpers.assert_eq(fixture.subject.spotlight_mouse(4), true)
	helpers.assert_eq(#fixture.native_timers, 2)
	fixture.native_timers[1]:fire()
	helpers.assert_eq(#fixture.taps, 1)
	return fixture.taps[1]
end





-- ==============================================
-- ==============================================
-- ======= 2/ Mirror Process Ownership =========
-- ==============================================
-- ==============================================

helpers.describe("SystemMouse mirror owner: positive and synchronous controls", function()
	helpers.it("dispatches the Python source inline without a shared temp pathname", function()
		local fixture = fresh_mouse_owner()
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), true)
		helpers.assert_eq(#fixture.shells, 1)
		local handle = fixture.shells[1]
		helpers.assert_eq(handle.executable, "/usr/bin/python3")
		helpers.assert_eq(handle.args[1], "-c")
		helpers.assert_type(handle.args[2], "string")
		helpers.assert_contains(handle.args[2], "CGGetOnlineDisplayList")
		helpers.assert_eq(handle.args[2]:find("/tmp/_hs_", 1, true), nil)
		helpers.assert_eq(fixture.io_open_calls, 0,
			"inline dispatch must not publish a filesystem script before start")
		handle:deliver(0, "single_screen\n", "")
	end)

	helpers.it("publishes one terminal only after start commits", function()
		local fixture = fresh_mouse_owner()
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), true)
		helpers.assert_eq(#fixture.shells, 1)
		local handle = fixture.shells[1]
		helpers.assert_eq(handle.start_calls, 1)
		helpers.assert_eq(handle.observer_registrations, 1)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
		handle:deliver(0, "mirror_enabled\n", "")
		handle:deliver(0, "mirror_disabled\n", "")
		helpers.assert_eq(count_logs(fixture, "success", "Display mirroring enabled"), 1)
		helpers.assert_eq(count_logs(fixture, "success", "Display mirroring disabled"), 0)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)
	end)

	helpers.it("buffers a synchronous terminal and drops one followed by refusal", function()
		local fixture = fresh_mouse_owner()
		fixture.queue_shell({
			start_mode = "sync_true",
			sync_terminal = table.pack(0, "mirror_enabled\n", ""),
		})
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), true)
		helpers.assert_eq(count_logs(fixture, "success", "Display mirroring enabled"), 1)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)

		fixture.queue_shell({
			start_mode = "sync_false",
			sync_terminal = table.pack(0, "mirror_disabled\n", ""),
		})
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
		helpers.assert_eq(count_logs(fixture, "success", "Display mirroring disabled"), 0)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)
	end)

	helpers.it("publishes the exact handle before a re-entrant PAUSE", function()
		local fixture = fresh_mouse_owner()
		fixture.queue_shell({ terminate_mode = "false" })
		fixture.start_hook = function(handle)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
			helpers.assert_eq(handle.terminate_identities[1] == handle, true)
		end
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
		local handle = fixture.shells[1]
		helpers.assert_eq(fixture.subject.is_mouse_actions_paused(), true)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
		handle.terminate_mode = "pending"
		helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
		handle:deliver(0, "mirror_enabled\n", "")
		helpers.assert_eq(count_logs(fixture, "success", "Display mirroring enabled"), 0)
		helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
		helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
		helpers.assert_eq(#fixture.shells, 1,
			"RESUME must not replay the interrupted mirror toggle")
	end)
end)

helpers.describe("SystemMouse mirror owner: termination refusal matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same mirror handle after terminate " .. mode, function()
			local fixture = fresh_mouse_owner()
			fixture.queue_shell({ terminate_mode = mode })
			helpers.assert_eq(fixture.subject.toggle_display_mirror(), true)
			local handle = fixture.shells[1]
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
			helpers.assert_eq(fixture.subject.is_mouse_actions_paused(), true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			helpers.assert_eq(handle.terminate_identities[1] == handle, true)
			helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
			helpers.assert_eq(#fixture.shells, 1)

			handle.terminate_mode = "pending"
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
			helpers.assert_eq(handle.terminate_identities[2] == handle, true)
			handle:deliver(0, "mirror_enabled\n", "")
			handle:deliver(0, "mirror_disabled\n", "")
			helpers.assert_eq(count_logs(fixture, "success", "Display mirroring"), 0)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
			helpers.assert_eq(#fixture.shells, 1)
		end)
	end
end)

helpers.describe("SystemMouse mirror owner: mutate-then-refuse start matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls back the same handle after start " .. mode, function()
			local fixture = fresh_mouse_owner()
			fixture.queue_shell({
				start_mode = mode .. "_mutate",
				terminate_mode = mode,
			})
			helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
			local handle = fixture.shells[1]
			helpers.assert_eq(handle.running, true)
			helpers.assert_eq(handle.terminate_identities[1] == handle, true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
			helpers.assert_eq(#fixture.shells, 1)

			handle.terminate_mode = "pending"
			helpers.assert_eq(fixture.subject.stop_mouse_actions(), false)
			helpers.assert_eq(handle.terminate_identities[2] == handle, true)
			handle:deliver(0, "mirror_enabled\n", "")
			helpers.assert_eq(count_logs(fixture, "success", "Display mirroring enabled"), 0)
			helpers.assert_eq(fixture.subject.stop_mouse_actions(), true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
	end)
	end
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Spotlight Exact Ownership ========
-- ==============================================
-- ==============================================

helpers.describe("SystemMouse spotlight owner: positive controls", function()
	helpers.it("arms one watcher and dismisses every resource exactly once", function()
		local fixture = fresh_mouse_owner()
		local tap = arm_spotlight(fixture)
		helpers.assert_eq(tap.enabled, true)
		helpers.assert_eq(#fixture.canvases, 2)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
		tap:deliver()
		helpers.assert_eq(tap.enabled, false)
		helpers.assert_eq(fixture.native_timers[2].running_state, false)
		helpers.assert_eq(fixture.canvases[1].deleted, true)
		helpers.assert_eq(fixture.canvases[2].deleted, true)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)

		local stop_calls = tap.stop_calls
		local delete_calls = fixture.canvases[1].delete_calls
		tap:deliver()
		helpers.assert_eq(tap.stop_calls, stop_calls)
		helpers.assert_eq(fixture.canvases[1].delete_calls, delete_calls)
	end)

	helpers.it("times out before arming without constructing a late eventtap", function()
		local fixture = fresh_mouse_owner()
		helpers.assert_eq(fixture.subject.spotlight_mouse(4), true)
		fixture.native_timers[2]:fire()
		helpers.assert_eq(#fixture.taps, 0)
		helpers.assert_eq(fixture.subject.has_pending_mouse_action(), false)
		fixture.native_timers[1]:deliver()
		helpers.assert_eq(#fixture.taps, 0,
			"a cancelled arm timer may retry cleanup but never run business work")
	end)

	helpers.it("closes every public admission path before cleanup", function()
		local fixture = fresh_mouse_owner()
		helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
		helpers.assert_eq(fixture.subject.spotlight_mouse(), false)
		helpers.assert_eq(fixture.subject.toggle_display_mirror(), false)
		helpers.assert_eq(fixture.subject.teleport_mouse(), false)
		helpers.assert_eq(fixture.subject.lock_screen(), false)
		helpers.assert_eq(fixture.subject.open_emoji_picker(), false)
		helpers.assert_eq(#fixture.native_timers, 0)
		helpers.assert_eq(#fixture.shells, 0)
		helpers.assert_eq(#fixture.canvases, 0)
		helpers.assert_eq(fixture.mouse_moves, 0)
		helpers.assert_eq(fixture.lock_calls, 0)
		helpers.assert_eq(fixture.emoji_events, 0)
	end)
end)

helpers.describe("SystemMouse spotlight owner: timer cancellation matrix", function()
	for _, timer_index in ipairs({ 1, 2 }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains timer " .. timer_index .. " after stop " .. mode, function()
				local fixture = fresh_mouse_owner()
				helpers.assert_eq(fixture.subject.spotlight_mouse(4), true)
				local timer = fixture.native_timers[timer_index]
				timer.stop_mode = mode
				helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
				helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
				helpers.assert_eq(timer.stop_identities[1] == timer, true)
				local timer_count = #fixture.native_timers
				timer:deliver()
				helpers.assert_eq(#fixture.taps, 0)
				helpers.assert_eq(#fixture.native_timers, timer_count)
				timer.stop_mode = "success"
				helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
				helpers.assert_eq(timer.stop_identities[timer.stop_calls] == timer, true)
				helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
				helpers.assert_eq(#fixture.native_timers, timer_count)
			end)
		end
	end
end)

helpers.describe("SystemMouse spotlight owner: timer start rollback matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains one timer after mutate-then-" .. mode .. " start", function()
			local fixture = fresh_mouse_owner()
			fixture.queue_timer({
				start_mode = mode .. "_mutate",
				stop_mode = mode,
			})
			helpers.assert_eq(fixture.subject.spotlight_mouse(4), false)
			helpers.assert_eq(#fixture.native_timers, 1)
			local timer = fixture.native_timers[1]
			helpers.assert_eq(timer.running_state, true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			for _, identity in ipairs(timer.stop_identities) do
				helpers.assert_eq(identity == timer, true)
			end
			timer.stop_mode = "success"
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
			helpers.assert_eq(timer.stop_identities[timer.stop_calls] == timer, true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
			helpers.assert_eq(#fixture.native_timers, 1)
	end)
	end
end)

helpers.describe("SystemMouse spotlight owner: eventtap cleanup matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same eventtap after stop " .. mode, function()
			local fixture = fresh_mouse_owner()
			local tap = arm_spotlight(fixture)
			tap.stop_mode = mode
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
			helpers.assert_eq(tap.stop_identities[1] == tap, true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			local tap_count = #fixture.taps
			tap:deliver()
			helpers.assert_eq(#fixture.taps, tap_count)
			tap.stop_mode = "success"
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
			helpers.assert_eq(tap.stop_identities[tap.stop_calls] == tap, true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
			helpers.assert_eq(#fixture.taps, tap_count)
		end)
	end
end)

helpers.describe("SystemMouse spotlight owner: eventtap start rollback matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls back the same eventtap after start " .. mode, function()
			local fixture = fresh_mouse_owner()
			fixture.queue_tap({
				start_mode = mode .. "_mutate",
				stop_mode = mode,
			})
			helpers.assert_eq(fixture.subject.spotlight_mouse(4), true)
			fixture.native_timers[1]:fire()
			local tap = fixture.taps[1]
			helpers.assert_eq(tap.enabled, true)
			helpers.assert_eq(tap.stop_identities[1] == tap, true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			tap.stop_mode = "success"
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
			helpers.assert_eq(tap.stop_identities[tap.stop_calls] == tap, true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
			helpers.assert_eq(#fixture.taps, 1)
	end)
	end
end)

helpers.describe("SystemMouse spotlight owner: canvas cleanup matrix", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same canvas after delete " .. mode, function()
			local fixture = fresh_mouse_owner()
			helpers.assert_eq(fixture.subject.spotlight_mouse(4), true)
			local canvas = fixture.canvases[1]
			canvas.delete_mode = mode
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), false)
			helpers.assert_eq(canvas.delete_identities[1] == canvas, true)
			helpers.assert_eq(canvas.showing, true)
			helpers.assert_eq(fixture.subject.has_pending_mouse_action(), true)
			local canvas_count = #fixture.canvases
			canvas.delete_mode = "success"
			helpers.assert_eq(fixture.subject.pause_mouse_actions(), true)
			helpers.assert_eq(canvas.delete_identities[canvas.delete_calls] == canvas, true)
			helpers.assert_eq(canvas.deleted, true)
			helpers.assert_eq(fixture.subject.resume_mouse_actions(), true)
			helpers.assert_eq(#fixture.canvases, canvas_count)
	end)
	end
end)


helpers.describe("SystemMouse owner: parent isolation", function()
	helpers.it("keeps gesture spotlight and teleport live while shortcuts pause", function()
		local fixture = fresh_mouse_owner()
		helpers.assert_eq(
			fixture.subject.spotlight_mouse(4, "gestures"), true)
		local gesture_timer = fixture.native_timers[1]

		helpers.assert_eq(
			fixture.subject.pause_mouse_actions("shortcut_bindings"), true)
		helpers.assert_eq(gesture_timer.stop_calls, 0,
			"shortcut cleanup must not stop the gesture spotlight")
		helpers.assert_eq(
			fixture.subject.has_pending_mouse_action("shortcut_bindings"), false)
		helpers.assert_eq(
			fixture.subject.has_pending_mouse_action("gestures"), true)
		helpers.assert_eq(
			fixture.subject.teleport_mouse("shortcut_bindings"), false)

		helpers.assert_eq(fixture.subject.teleport_mouse("gestures"), true)
		helpers.assert_eq(fixture.mouse_moves, 1,
			"the live gesture parent must still cross the mouse boundary")
		helpers.assert_eq(
			fixture.subject.pause_mouse_actions("gestures"), true)
		helpers.assert_eq(
			fixture.subject.resume_mouse_actions("gestures"), true)
	end)
end)

helpers.describe("SystemMouse synchronous native boundary ownership", function()
	local actions = {
		{
			name = "teleport",
			invoke = function(subject, parent) return subject.teleport_mouse(parent) end,
			count = function(fixture) return fixture.mouse_moves end,
		},
		{
			name = "lock",
			invoke = function(subject, parent) return subject.lock_screen(parent) end,
			count = function(fixture) return fixture.lock_calls end,
		},
		{
			name = "emoji",
			invoke = function(subject, parent) return subject.open_emoji_picker(parent) end,
			count = function(fixture) return fixture.emoji_events end,
		},
	}

	for _, action in ipairs(actions) do
		for _, parent in ipairs({ "gestures", "shortcut_bindings" }) do
			helpers.it(action.name .. " keeps " .. parent
				.. " visible to re-entrant PAUSE until native return", function()
				local fixture = fresh_mouse_owner()
				fixture.boundary_hook = function(label)
					if label ~= action.name then return end
					fixture.boundary_hook = nil
					fixture.nested_pause_result =
						fixture.subject.pause_mouse_actions(parent)
				end

				helpers.assert_eq(action.invoke(fixture.subject, parent), false)
				helpers.assert_eq(fixture.nested_pause_result, false,
					"PAUSE cannot settle while the synchronous mutation is in flight")
				helpers.assert_eq(action.count(fixture), 1,
					"the native boundary must remain observable and mutation-sensitive")
				helpers.assert_eq(
					fixture.subject.is_mouse_actions_paused(parent), true)
				helpers.assert_eq(
					fixture.subject.has_pending_mouse_action(parent), false)
				helpers.assert_eq(
					fixture.subject.pause_mouse_actions(parent), true)
			end)
		end
	end

	helpers.it("a shortcut PAUSE cannot fence a gesture synchronous boundary", function()
		local fixture = fresh_mouse_owner()
		fixture.boundary_hook = function(label)
			if label ~= "lock" then return end
			fixture.boundary_hook = nil
			fixture.nested_pause_result =
				fixture.subject.pause_mouse_actions("shortcut_bindings")
		end
		helpers.assert_eq(fixture.subject.lock_screen("gestures"), true)
		helpers.assert_eq(fixture.nested_pause_result, true)
		helpers.assert_eq(fixture.lock_calls, 1)
		helpers.assert_eq(
			fixture.subject.is_mouse_actions_paused("gestures"), false)
	end)
end)

io.open = ORIGINAL_IO_OPEN
