--- tests/unit/modules/gestures/test_screenshot_save_transaction.lua

--- ==============================================================================
--- MODULE: Shared Screenshot Save Transaction Regression
--- DESCRIPTION:
--- Exercises the exact mkdir -> screencapture owner shared by gesture and
--- configurable-shortcut entry points. Construction, start, and exit refusal
--- must be visible, capture cannot overtake mkdir, and rapid saves cannot target
--- the same pathname.
--- ==============================================================================

local helpers = require("tests.helpers")

local SUBJECT_MODULES = {
	"adapters.file_system",
	"adapters.shell_runner",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.shortcuts.actions.screenshot_save",
}

--- Loads the shared transaction against configurable async-task boundaries.
--- @param options table Failure-injection options.
--- @param scenario function Test body receiving subject and fixture.
local function with_subject(options, scenario)
	local saved = {}
	for _, name in ipairs(SUBJECT_MODULES) do saved[name] = package.loaded[name] end
	local saved_hs = _G.hs

	local fixture = {
		tasks = {},
		notifications = {},
		errors = {},
		role_counts = {directory = 0, capture = 0},
		notify_hook = nil,
	}
	local modes = options or {}

	package.loaded["adapters.file_system"] = {
		expand_path = function(path)
			if modes.home_throw then error("injected home resolution failure") end
			if path == "~" then return modes.home or "/tmp/hs015-home" end
			return path
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key)
			if key == "shortcuts.saved" then return "Saved %s" end
			if key == "shortcuts.screenshot_failed" then return "Screenshot failed" end
			return key
		end,
	}
	package.loaded["infra.logger"] = {
		debug = function() end,
		info = function() end,
		warn = function() end,
		error = function(_, message, ...)
			fixture.errors[#fixture.errors + 1] = string.format(tostring(message), ...)
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(message, body, kind)
			if type(fixture.notify_hook) == "function" then fixture.notify_hook() end
			fixture.notifications[#fixture.notifications + 1] = {
				message = message,
				body = body,
				kind = kind,
			}
			return true
		end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(executable, args, on_done)
			local role = executable == "/bin/mkdir" and "directory" or "capture"
			fixture.role_counts[role] = fixture.role_counts[role] + 1
			local ordinal = fixture.role_counts[role]
			local construct_mode = modes[role .. "_construct"]
			if type(construct_mode) == "table" then construct_mode = construct_mode[ordinal] end
			if construct_mode == "throw" then error("injected " .. role .. " construction failure") end
			if construct_mode == "nil" then return nil end

			local record = {
				role = role,
				executable = executable,
				args = args,
				started = false,
			}
			fixture.tasks[#fixture.tasks + 1] = record
			local handle = {
				settled = false,
				observers = {},
			}
			function handle.start()
					local start_mode = modes[role .. "_start"]
					if type(start_mode) == "table" then start_mode = start_mode[ordinal] end
					if start_mode == "throw" then error("injected " .. role .. " start failure") end
					if start_mode == "false" then return false end
					if start_mode == "nil" then return nil end
					record.started = true
					return true
			end
			function handle.isSettled() return handle.settled end
			function handle.onSettled(observer)
				if handle.settled then observer()
				else handle.observers[#handle.observers + 1] = observer end
				return true
			end
			function handle.terminate()
				if handle.settled then return true, "settled" end
				handle.settled = true
				local observers = handle.observers
				handle.observers = {}
				for _, observer in ipairs(observers) do observer() end
				return true, "settled"
			end
			function record.on_done(...)
				local first = handle.settled ~= true
				handle.settled = true
				on_done(...)
				if first then
					local observers = handle.observers
					handle.observers = {}
					for _, observer in ipairs(observers) do observer() end
				end
			end
			return handle
		end,
	}
	package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	_G.hs = {
		processInfo = {processID = modes.process_id or 7001},
		timer = {absoluteTime = function() return modes.absolute_time or 123456789 end},
	}

	local ok, err = xpcall(function()
		local subject = require("modules.shortcuts.actions.screenshot_save")
		scenario(subject, fixture)
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(SUBJECT_MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Returns the task records for one lifecycle role.
--- @param fixture table Fixture state.
--- @param role string `directory` or `capture`.
--- @return table records
local function tasks_for(fixture, role)
	local records = {}
	for _, task in ipairs(fixture.tasks) do
		if task.role == role then records[#records + 1] = task end
	end
	return records
end

--- Asserts one visible failure and no success notice.
--- @param fixture table Fixture state.
local function assert_one_failure(fixture)
	helpers.assert_eq(#fixture.notifications, 1, "a refused screenshot must notify exactly once")
	helpers.assert_eq(fixture.notifications[1].kind, "error")
	helpers.assert_eq(#fixture.errors, 1, "a refused screenshot must reach the file logger exactly once")
end





-- ==========================================
-- ==========================================
-- ======= 1/ Exact Async Transaction =======
-- ==========================================
-- ==========================================

helpers.describe("shared screenshot save transaction (HS-015)", function()
	helpers.it("commits mkdir before capture and reports exact success (HS-015)", function()
		with_subject({}, function(subject, fixture)
			helpers.assert_eq(subject.save({"-w"}, "win"), true)
			local directories = tasks_for(fixture, "directory")
			helpers.assert_eq(#directories, 1)
			helpers.assert_eq(directories[1].started, true)
			helpers.assert_eq(directories[1].args[1], "-p")
			helpers.assert_eq(directories[1].args[2], "/tmp/hs015-home/Pictures/screenshots")
			helpers.assert_eq(#tasks_for(fixture, "capture"), 0,
				"capture must not start until mkdir reports exit 0")

			directories[1].on_done(0, "", "")
			local captures = tasks_for(fixture, "capture")
			helpers.assert_eq(#captures, 1)
			helpers.assert_eq(captures[1].started, true)
			helpers.assert_eq(captures[1].args[1], "-w")
			helpers.assert_true(captures[1].args[2]:find("/Pictures/screenshots/win_", 1, true) ~= nil)
			helpers.assert_eq(#fixture.notifications, 0,
				"task construction is not capture success")

			captures[1].on_done(0, "", "")
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1].kind, "success")
			helpers.assert_eq(#fixture.errors, 0)
		end)
	end)

	for _, boundary in ipairs({
		{"directory_construct", "nil"},
		{"directory_construct", "throw"},
		{"directory_start", "nil"},
		{"directory_start", "false"},
		{"directory_start", "throw"},
	}) do
		local field, mode = boundary[1], boundary[2]
		helpers.it("rejects mkdir " .. field .. "=" .. mode .. " without capture (HS-015)", function()
			with_subject({[field] = mode}, function(subject, fixture)
				helpers.assert_eq(subject.save({}, "full"), false)
				helpers.assert_eq(#tasks_for(fixture, "capture"), 0)
				assert_one_failure(fixture)
			end)
		end)
	end

	helpers.it("stops the chain when mkdir exits nonzero (HS-015)", function()
		with_subject({}, function(subject, fixture)
			helpers.assert_eq(subject.save({}, "full"), true)
			tasks_for(fixture, "directory")[1].on_done(73, "", "mkdir refused")
			helpers.assert_eq(#tasks_for(fixture, "capture"), 0)
			assert_one_failure(fixture)
		end)
	end)

	for _, boundary in ipairs({
		{"capture_construct", "nil"},
		{"capture_construct", "throw"},
		{"capture_start", "nil"},
		{"capture_start", "false"},
		{"capture_start", "throw"},
	}) do
		local field, mode = boundary[1], boundary[2]
		helpers.it("reports capture " .. field .. "=" .. mode .. " (HS-015)", function()
			with_subject({[field] = mode}, function(subject, fixture)
				helpers.assert_eq(subject.save({"-i"}, "reg"), true)
				tasks_for(fixture, "directory")[1].on_done(0, "", "")
				assert_one_failure(fixture)
			end)
		end)
	end

	helpers.it("reports a nonzero screencapture exit without false success (HS-015)", function()
		with_subject({}, function(subject, fixture)
			helpers.assert_eq(subject.save({}, "full"), true)
			tasks_for(fixture, "directory")[1].on_done(0, "", "")
			tasks_for(fixture, "capture")[1].on_done(1, "", "capture refused")
			assert_one_failure(fixture)
		end)
	end)

	helpers.it("keeps success notification visible to re-entrant parent PAUSE", function()
		with_subject({}, function(subject, fixture)
			local nested_pause = nil
			helpers.assert_eq(subject.save({}, "full", "gestures"), true)
			tasks_for(fixture, "directory")[1].on_done(0, "", "")
			fixture.notify_hook = function()
				fixture.notify_hook = nil
				nested_pause = subject.pause_screenshot_actions("gestures")
			end
			tasks_for(fixture, "capture")[1].on_done(0, "", "")
			helpers.assert_eq(nested_pause, false,
				"PAUSE cannot settle before the terminal business callback returns")
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1].kind, "success")
			helpers.assert_eq(
				subject.has_screenshot_pause_claim("gestures"), true)
			helpers.assert_eq(
				subject.has_pending_screenshot_action("gestures"), false)
			helpers.assert_eq(
				subject.pause_screenshot_actions("shortcut_bindings"), true)
			helpers.assert_eq(subject.pause_screenshot_actions("gestures"), true)
		end)
	end)

	helpers.it("allocates distinct paths to same-tick saves (HS-015)", function()
		with_subject({absolute_time = 987654321}, function(subject, fixture)
			helpers.assert_eq(subject.save({}, "full"), true)
			helpers.assert_eq(subject.save({}, "full"), true)
			local directories = tasks_for(fixture, "directory")
			helpers.assert_eq(#directories, 2)
			directories[1].on_done(0, "", "")
			directories[2].on_done(0, "", "")
			local captures = tasks_for(fixture, "capture")
			helpers.assert_eq(#captures, 2)
			local first_target = captures[1].args[#captures[1].args]
			local second_target = captures[2].args[#captures[2].args]
			helpers.assert_true(first_target ~= second_target,
				"two saves in one wall-clock second and monotonic tick must not overwrite each other")
		end)
	end)
end)





-- ==========================================
-- ==========================================
-- ======= 2/ Gesture Entry-Point ===========
-- ==========================================
-- ==========================================

helpers.describe("gesture screenshot entry point (HS-015)", function()
	helpers.it("owns the registered action when the shared save transaction refuses (HS-015)", function()
		local saved_actions = package.loaded["modules.gestures.actions"]
		local saved_screenshot = package.loaded["modules.shortcuts.actions.screenshot_save"]
		local saved_hs = _G.hs
		local calls = {}
		package.loaded["modules.shortcuts.actions.screenshot_save"] = {
			save = function(flags, prefix)
				calls[#calls + 1] = {flags = flags, prefix = prefix}
				return false
			end,
		}
		package.loaded["modules.gestures.actions"] = nil

		local ok, err = xpcall(function()
			local actions = helpers.load_with_stubs("modules.gestures.actions")
			helpers.assert_eq(actions.execute_single("screenshot_fullscreen_save"), true,
				"the registered gesture remains owned after its shared transaction refuses")
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(#calls[1].flags, 0)
			helpers.assert_eq(calls[1].prefix, "full")
		end, debug.traceback)

		package.loaded["modules.gestures.actions"] = saved_actions
		package.loaded["modules.shortcuts.actions.screenshot_save"] = saved_screenshot
		_G.hs = saved_hs
		if not ok then error(err, 0) end
	end)
end)
