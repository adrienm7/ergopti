--- tests/unit/ui/test_log_openers.lua

--- ==============================================================================
--- MODULE: Log openers (Debug menu and gesture actions)
--- DESCRIPTION:
--- One owner opens the logs folder, today's log and today's errors file for
--- both the Debug menu and the gesture/shortcut actions.
---
--- ROOT CAUSES ENCODED (log-openers):
--- 1. The menu and the gesture actions each rebuilt the folder from the config
---    folder and read Logger.UNIFIED_LOG_FILE / ERRORS_LOG_FILE, fixed at boot:
---    after midnight both opened yesterday's file. The opener must ask the
---    logger for the path at the moment of the click.
--- 2. The errors file only exists once something warned that day. Opening a
---    missing path did nothing visible, so the user could not tell "no error"
---    from "broken menu". A missing file now says so.
--- 3. The menu opened files with a synchronous hs.execute on the main thread;
---    the opener hands every target to an injected asynchronous opener.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the openers over a controllable logger, folder creator and notifier.
--- @param state table { day, existing = { [path] = true } }
--- @return table openers
--- @return table observed { created, notified }
local function load_openers(state)
	local observed = { created = {}, notified = {} }
	package.loaded["infra.logger"] = {
		logs_dir = function() return "/fixture/logs/ergopti_plus/" end,
		today_log_path = function()
			return "/fixture/logs/ergopti_plus/unified-" .. state.day .. ".log"
		end,
		today_errors_path = function()
			return "/fixture/logs/ergopti_plus/errors-" .. state.day .. ".log"
		end,
		debug = function() end, info = function() end,
		warn = function() end, error = function() end,
	}
	package.loaded["infra.config_paths"] = {
		ensure_dir = function(path)
			observed.created[#observed.created + 1] = path
			return state.can_create ~= false
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(message, body, kind)
			observed.notified[#observed.notified + 1] = { message = message, body = body, kind = kind }
			return true
		end,
	}
	local openers = helpers.load_with_stubs("ui.log_openers", {
		fs = {
			attributes = function(path)
				if state.existing[path] then return { mode = "file" } end
				return nil
			end,
		},
	})
	return openers, observed
end

--- An opener double recording every target it is handed.
--- @return function open_fn
--- @return table targets
local function recording_opener()
	local targets = {}
	return function(target)
		targets[#targets + 1] = target
		return true
	end, targets
end

helpers.describe("log openers (log-openers)", function()
	helpers.it("opens today's log as the logger names it at the moment of the click", function()
		local state = { day = "2099-01-01", existing = {} }
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers = load_openers(state)
			local open_fn, targets = recording_opener()
			helpers.assert_true(openers.open_today_log(open_fn))
			state.day = "2099-01-02"
			helpers.assert_true(openers.open_today_log(open_fn))
			helpers.assert_eq(targets[1], "/fixture/logs/ergopti_plus/unified-2099-01-01.log")
			helpers.assert_eq(targets[2], "/fixture/logs/ergopti_plus/unified-2099-01-02.log",
				"a path chosen before midnight must not be reused after it")
		end)
	end)

	helpers.it("opens today's errors file when it exists", function()
		local state = { day = "2099-01-03", existing = {} }
		state.existing["/fixture/logs/ergopti_plus/errors-2099-01-03.log"] = true
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers, observed = load_openers(state)
			local open_fn, targets = recording_opener()
			helpers.assert_true(openers.open_today_errors(open_fn))
			helpers.assert_eq(targets[1], "/fixture/logs/ergopti_plus/errors-2099-01-03.log")
			helpers.assert_eq(#observed.notified, 0)
		end)
	end)

	helpers.it("says there was no warning today instead of opening a missing errors file", function()
		local state = { day = "2099-01-04", existing = {} }
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers, observed = load_openers(state)
			local open_fn, targets = recording_opener()
			helpers.assert_true(openers.open_today_errors(open_fn),
				"telling the user is the complete answer to the click")
			helpers.assert_eq(#targets, 0, "a missing file must never be handed to the opener")
			helpers.assert_eq(#observed.notified, 1)
			helpers.assert_eq(observed.notified[1].message, "menu.debug.no_errors_today")
		end)
	end)

	helpers.it("creates the logs folder before opening it", function()
		local state = { day = "2099-01-05", existing = {} }
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers, observed = load_openers(state)
			local open_fn, targets = recording_opener()
			helpers.assert_true(openers.open_logs_folder(open_fn))
			helpers.assert_eq(observed.created[1], "/fixture/logs/ergopti_plus/")
			helpers.assert_eq(targets[1], "/fixture/logs/ergopti_plus/")
		end)
	end)

	helpers.it("reports a folder it could not create instead of opening nothing", function()
		local state = { day = "2099-01-06", existing = {}, can_create = false }
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers = load_openers(state)
			local open_fn, targets = recording_opener()
			helpers.assert_true(openers.open_logs_folder(open_fn) == false)
			helpers.assert_eq(#targets, 0)
		end)
	end)

	helpers.it("rejects a missing opener", function()
		local state = { day = "2099-01-07", existing = {} }
		helpers.with_fresh_modules({ "ui.log_openers", "infra.logger", "infra.config_paths", "infra.notifications" }, function()
			local openers = load_openers(state)
			helpers.assert_throws(function() openers.open_today_log(nil) end)
		end)
	end)
end)
