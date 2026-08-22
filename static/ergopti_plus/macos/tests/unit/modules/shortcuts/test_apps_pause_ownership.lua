--- tests/unit/modules/shortcuts/test_apps_pause_ownership.lua

--- ==============================================================================
--- MODULE: App Navigation Composite Pause Ownership
--- DESCRIPTION:
--- Drives the real Apps owner and TimerScheduler against observable native timer
--- identities, plus exact ShellRunner handles. PAUSE must fence Finder/open
--- continuations, centering timers and clipboard restore work before cleanup;
--- false/nil/throw cleanup retains the same capability until terminal proof.
--- ==============================================================================

local helpers = require("tests.helpers")


local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = clone(child) end
	return out
end


local function fresh_apps()
	for _, name in ipairs({
		"modules.shortcuts.actions.apps",
		"adapters.timer_scheduler",
		"adapters.shell_runner",
		"adapters.app_launcher",
		"adapters.window_info",
		"adapters.window_manager",
		"adapters.synthetic_input",
		"infra.logger",
		"infra.notifications",
		"infra.i18n",
		"infra.text_utils",
		"tests.stubs.hs",
		"hs",
	}) do package.loaded[name] = nil end

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	local fixture = {
		native_timers = {},
		next_timer_options = {},
		shells = {},
		next_shell_options = {},
		urls = {},
		centered = 0,
		copies = 0,
		clear_calls = 0,
		read_all_calls = 0,
		get_contents_calls = 0,
		notifications = {},
		focused_app_id = "TextEdit",
		clipboard = {
			["public.utf8-plain-text"] = "ORIGINAL",
			["public.html"] = "<b>ORIGINAL</b>",
		},
		original = nil,
		restore_modes = {},
		restore_calls = 0,
	}
	fixture.original = clone(fixture.clipboard)

	function fixture.queue_timer(options)
		fixture.next_timer_options[#fixture.next_timer_options + 1] = options or {}
	end

	local timer_contract = {}
	for key, value in pairs(hs_stub.timer) do timer_contract[key] = value end
	timer_contract.new = function(delay, callback)
		local options = table.remove(fixture.next_timer_options, 1) or {}
		local native = {
			delay = delay,
			callback = callback,
			running_state = false,
			start_calls = 0,
			stop_calls = 0,
			stop_identities = {},
			start_mode = options.start_mode or "success",
			stop_mode = options.stop_mode or "success",
		}
		function native:start()
			self.start_calls = self.start_calls + 1
			if self.start_mode == "false_mutate" then self.running_state = true; return false end
			if self.start_mode == "nil_mutate" then self.running_state = true; return nil end
			if self.start_mode == "throw_mutate" then
				self.running_state = true
				error("native timer start exploded")
			end
			self.running_state = true
			return self
		end
		function native:stop()
			self.stop_calls = self.stop_calls + 1
			self.stop_identities[self.stop_calls] = self
			if self.stop_mode == "false" then return false end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == "throw" then error("native timer stop exploded") end
			self.running_state = false
			return self
		end
		function native:running() return self.running_state end
		function native:fire()
			if self.running_state then self.callback() end
		end
		function native:deliver() self.callback() end
		fixture.native_timers[#fixture.native_timers + 1] = native
		return native
	end
	hs_stub.timer = timer_contract

	local window = {
		isStandard = function() return true end,
		isVisible = function() return true end,
		screen = function()
			return { frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end }
		end,
		frame = function() return { x = 0, y = 0, w = 200, h = 100 } end,
		setFrame = function()
			if type(fixture.center_hook) == "function" then fixture.center_hook() end
			fixture.centered = fixture.centered + 1
			return true
		end,
	}
	local front_app = {
		name = function() return "TextEdit" end,
		allWindows = function() return { window } end,
	}
	hs_stub.application = {
		runningApplications = function() return {} end,
		frontmostApplication = function() return front_app end,
	}
	hs_stub.pasteboard = {
		readAllData = function()
			fixture.read_all_calls = fixture.read_all_calls + 1
			if type(fixture.read_all_hook) == "function" then fixture.read_all_hook() end
			return clone(fixture.clipboard)
		end,
		clearContents = function()
			fixture.clear_calls = fixture.clear_calls + 1
			fixture.clipboard = {}
			return nil
		end,
		getContents = function()
			fixture.get_contents_calls = fixture.get_contents_calls + 1
			if type(fixture.get_contents_hook) == "function" then
				fixture.get_contents_hook(fixture.get_contents_calls)
			end
			return fixture.next_clipboard_text or "selected words"
		end,
		writeAllData = function(snapshot)
			fixture.restore_calls = fixture.restore_calls + 1
			local mode = fixture.restore_modes[fixture.restore_calls] or "success"
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("clipboard restore exploded") end
			fixture.clipboard = clone(snapshot)
			return true
		end,
	}
	hs_stub.urlevent = {
		openURL = function(url)
			fixture.urls[#fixture.urls + 1] = url
			return true
		end,
	}
	hs_stub.http = { encodeForQuery = function(value) return value end }

	function fixture.queue_shell(options)
		fixture.next_shell_options[#fixture.next_shell_options + 1] = options or {}
	end

	local function start_shell(kind, payload, callback)
		local options = table.remove(fixture.next_shell_options, 1) or {}
		local handle = {
			kind = kind,
			payload = payload,
			callback = callback,
			settled = false,
			terminate_calls = 0,
			terminate_identities = {},
			terminate_mode = options.terminate_mode or "pending",
			observers = {},
		}
		function handle.isSettled() return handle.settled end
		function handle.onSettled(observer)
			if handle.settled then observer()
			else handle.observers[#handle.observers + 1] = observer end
			return true
		end
		function handle:settle_without_terminal()
			if self.settled == true then return end
			self.settled = true
			local observers = self.observers
			self.observers = {}
			for _, observer in ipairs(observers) do observer() end
		end
		function handle.terminate()
			handle.terminate_calls = handle.terminate_calls + 1
			handle.terminate_identities[handle.terminate_calls] = handle
			if handle.terminate_mode == "false" then return false, "refused" end
			if handle.terminate_mode == "nil" then return nil, "refused" end
			if handle.terminate_mode == "throw" then error("shell terminate exploded") end
			if handle.terminate_mode == "sync" then
				handle:deliver(false, nil)
				return true, "settled"
			end
			return true, "pending"
		end
		function handle:deliver(...)
			local first = self.settled ~= true
			self.settled = true
			-- A hostile duplicate still calls the supplied wrapper; Apps owns the
			-- business one-shot independently of this fixture.
			self.callback(...)
			if first then
				local observers = self.observers
				self.observers = {}
				for _, observer in ipairs(observers) do observer() end
			end
		end
		fixture.shells[#fixture.shells + 1] = handle
		if options.settled_before_return then handle:settle_without_terminal() end
		if options.sync_terminal then handle:deliver(table.unpack(options.sync_terminal)) end
		if options.started == false then return false, handle end
		return true, handle
	end

	package.loaded["adapters.shell_runner"] = {
		open = function(target, callback) return start_shell("open", target, callback) end,
		applescript = function(script, callback)
			return start_shell("applescript", script, callback)
		end,
	}
	package.loaded["adapters.app_launcher"] = { launch = function() return false end }
	package.loaded["adapters.window_manager"] = { activate = function() return false end }
	package.loaded["adapters.window_info"] = {
		getFocused = function() return { appId = fixture.focused_app_id } end,
	}
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function()
			fixture.copies = fixture.copies + 1
			return true
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.notifications"] = {
		notify = function(...)
			fixture.notifications[#fixture.notifications + 1] = table.pack(...)
			return true
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = {
		applescript_format = function(template, value)
			return (template:gsub("%%s", value))
		end,
	}

	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.shortcuts.actions.apps"] = nil
	fixture.subject = require("modules.shortcuts.actions.apps")
	return fixture
end


helpers.describe("Apps composite owner: positive controls", function()
	helpers.it("completes Finder probe, open and centering once while ACTIVE", function()
		local f = fresh_apps()
		helpers.assert_eq(f.subject.open_downloads(), true)
		helpers.assert_eq(#f.shells, 1)
		helpers.assert_eq(f.shells[1].kind, "applescript")
		f.shells[1]:deliver(false, "none")
		helpers.assert_eq(#f.shells, 2)
		helpers.assert_eq(f.shells[2].kind, "open")
		helpers.assert_eq(#f.native_timers, 1)
		f.shells[2]:deliver(true)
		f.native_timers[1]:fire()
		helpers.assert_eq(f.centered, 1)
		helpers.assert_eq(f.subject.has_pending_apps_action(), false)
	end)
end)


helpers.describe("Apps composite owner: re-entrant clipboard boundaries", function()
	helpers.it("publishes readAllData acquisition and refuses post-PAUSE capture", function()
		local f = fresh_apps()
		local pause_result = nil
		f.read_all_hook = function()
			f.read_all_hook = nil
			pause_result = f.subject.pause_apps_actions()
		end

		helpers.assert_eq(f.subject.copy_or_open_path(), false)
		helpers.assert_eq(pause_result, false,
			"PAUSE must observe the native snapshot acquisition in progress")
		helpers.assert_eq(f.subject.is_apps_actions_paused(), true)
		helpers.assert_eq(f.clear_calls, 0,
			"a snapshot returned after PAUSE must not authorize clipboard mutation")
		helpers.assert_eq(f.copies, 0)
		helpers.assert_eq(f.subject.has_pending_apps_action(), false)
		helpers.assert_eq(f.subject.pause_apps_actions(), true)
	end)

	helpers.it("revalidates Finder getContents before notifying", function()
		local f = fresh_apps()
		f.focused_app_id = "Finder"
		local pause_result, resume_result
		f.get_contents_hook = function()
			f.get_contents_hook = nil
			pause_result = f.subject.pause_apps_actions()
			resume_result = f.subject.resume_apps_actions()
		end

		helpers.assert_eq(f.subject.copy_or_open_path(), true)
		f.native_timers[1]:fire()
		helpers.assert_eq(pause_result, false,
			"PAUSE cannot settle while getContents remains on the native stack")
		helpers.assert_eq(resume_result, false,
			"RESUME cannot reopen admission before the exact callback returns")
		helpers.assert_eq(#f.notifications, 0,
			"a Finder value returned after PAUSE must not reach the user")
		helpers.assert_eq(#f.urls, 0)
		helpers.assert_eq(f.clipboard, f.original)
		helpers.assert_eq(f.subject.resume_apps_actions(), true,
			"retry after callback return must reopen the settled owner")
	end)

	helpers.it("revalidates selection getContents before opening a URL", function()
		local f = fresh_apps()
		local pause_result, resume_result
		f.get_contents_hook = function()
			f.get_contents_hook = nil
			pause_result = f.subject.pause_apps_actions()
			resume_result = f.subject.resume_apps_actions()
		end

		helpers.assert_eq(f.subject.copy_or_open_path(), true)
		f.native_timers[1]:fire()
		helpers.assert_eq(pause_result, false,
			"PAUSE cannot settle while getContents remains on the native stack")
		helpers.assert_eq(resume_result, false,
			"RESUME cannot reopen admission before the exact callback returns")
		helpers.assert_eq(#f.urls, 0,
			"a selection returned after PAUSE must not open or search")
		helpers.assert_eq(f.clipboard, f.original)
		helpers.assert_eq(f.subject.resume_apps_actions(), true,
			"retry after callback return must reopen the settled owner")
	end)
end)


helpers.describe("Apps composite owner: idempotent RESUME", function()
	helpers.it("does not cancel or revoke ACTIVE centering work", function()
		local f = fresh_apps()
		helpers.assert_eq(f.subject.open_settings(), true)
		local timer = f.native_timers[1]

		helpers.assert_eq(f.subject.resume_apps_actions(), true)
		helpers.assert_eq(timer.stop_calls, 0,
			"duplicate RESUME must not settle an ACTIVE timer")
		timer:fire()
		helpers.assert_eq(f.centered, 1,
			"duplicate RESUME must preserve the timer generation")
	end)
end)


helpers.describe("Apps composite owner: ShellRunner settlement", function()
	helpers.it("fences a terminal delivered after onSettled removed the exact owner", function()
		local f = fresh_apps()
		f.queue_shell({ settled_before_return = true })
		helpers.assert_eq(f.subject.open_downloads(), true)
		local old_probe = f.shells[1]
		helpers.assert_eq(f.subject.has_pending_apps_action(), false)

		helpers.assert_eq(f.subject.open_downloads(), true)
		helpers.assert_eq(#f.shells, 2)
		old_probe:deliver(false, "none")
		helpers.assert_eq(#f.shells, 2,
			"a released probe must not launch a successor after a sibling acquired ownership")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the same Finder probe after terminate " .. mode, function()
			local f = fresh_apps()
			helpers.assert_eq(f.subject.open_downloads(), true)
			local probe = f.shells[1]
			probe.terminate_mode = mode
			helpers.assert_eq(f.subject.pause_apps_actions(), false)
			helpers.assert_eq(f.subject.is_apps_actions_paused(), true)
			helpers.assert_eq(f.subject.has_pending_apps_action(), true)
			helpers.assert_eq(probe.terminate_calls, 1)
			helpers.assert_eq(probe.terminate_identities[1] == probe, true)
			helpers.assert_eq(f.subject.open_finder(), false)
			helpers.assert_eq(#f.shells, 1)

			probe.terminate_mode = "pending"
			helpers.assert_eq(f.subject.pause_apps_actions(), false)
			helpers.assert_eq(probe.terminate_calls, 2)
			probe:deliver(false, "none")
			probe:deliver(false, "none")
			helpers.assert_eq(#f.shells, 1,
				"a revoked Finder terminal must not open a folder successor")
			helpers.assert_eq(#f.native_timers, 0)
			helpers.assert_eq(f.subject.pause_apps_actions(), true)
			helpers.assert_eq(f.subject.resume_apps_actions(), true)
			helpers.assert_eq(f.subject.has_pending_apps_action(), false)
		end)
	end
end)


helpers.describe("Apps composite owner: exact timer fence", function()
	helpers.it("keeps centering delivery pending until its native mutation returns", function()
		local f = fresh_apps()
		local nested_pause
		helpers.assert_eq(f.subject.open_settings(), true)
		f.center_hook = function()
			f.center_hook = nil
			nested_pause = f.subject.pause_apps_actions()
		end
		f.native_timers[1]:fire()
		helpers.assert_eq(nested_pause, false,
			"PAUSE inside setFrame may not settle before the callback boundary returns")
		helpers.assert_eq(f.centered, 1)
		helpers.assert_eq(f.subject.is_apps_actions_paused(), true)
		helpers.assert_eq(f.subject.pause_apps_actions(), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and fences the centering timer after stop " .. mode, function()
			local f = fresh_apps()
			helpers.assert_eq(f.subject.open_settings(), true)
			local timer = f.native_timers[1]
			timer.stop_mode = mode
			helpers.assert_eq(f.subject.pause_apps_actions(), false)
			helpers.assert_eq(timer.stop_calls, 1)
			helpers.assert_eq(timer.stop_identities[1] == timer, true)
			helpers.assert_eq(f.subject.open_chatgpt("https://example.invalid"), false)
			helpers.assert_eq(#f.urls, 0)

			timer.stop_mode = "success"
			timer:fire()
			timer:deliver()
			helpers.assert_eq(f.centered, 0,
				"a due cleanup callback must remain inert after PAUSE closed admission")
			helpers.assert_eq(timer.stop_calls, 2)
			helpers.assert_eq(timer.stop_identities[2] == timer, true)
			helpers.assert_eq(f.subject.pause_apps_actions(), true)
			helpers.assert_eq(f.subject.resume_apps_actions(), true)
			helpers.assert_eq(#f.native_timers, 1,
				"RESUME must not replay interrupted navigation")
	end)
	end
end)


helpers.describe("Apps composite owner: clipboard restoration", function()
	helpers.it("restores the exact snapshot before PAUSE and fences the old capture", function()
		local f = fresh_apps()
		f.restore_modes = { "false", "success" }
		helpers.assert_eq(f.subject.copy_or_open_path(), true)
		helpers.assert_eq(f.copies, 1)
		local timer = f.native_timers[1]
		helpers.assert_eq(f.subject.pause_apps_actions(), false)
		helpers.assert_eq(f.subject.has_pending_apps_action(), true)
		helpers.assert_eq(f.subject.pause_apps_actions(), true)
		helpers.assert_eq(f.clipboard, f.original)
		timer:deliver()
		helpers.assert_eq(#f.urls, 0)
		helpers.assert_eq(f.subject.resume_apps_actions(), true)
		helpers.assert_eq(f.subject.has_pending_apps_action(), false)
	end)
end)
