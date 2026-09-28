--- tests/unit/ui/test_log_openers.lua

--- ==============================================================================
--- MODULE: Log Openers (Linux)
--- DESCRIPTION:
--- The tray and the gesture actions open the logs through ui/log_openers.
---
--- ROOT CAUSE ENCODED (log-openers):
--- The errors file only exists once something warned that day, and xdg-open on
--- a missing path fails without a word, so the menu row looked broken on every
--- quiet day. A missing errors file is now announced instead.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the openers over a sink whose paths the test controls.
--- @param state table { day, existing = { [path] = true } }
--- @param body function Receives the openers module.
local function with_openers(state, body)
	local saved_sink = package.loaded["infra.logger_sink"]
	local saved_openers = package.loaded["ui.log_openers"]
	local real_open = io.open
	package.loaded["infra.logger_sink"] = {
		log_dir = function() return "/fixture/logs/ergopti_plus" end,
		main_log_path = function() return "/fixture/logs/ergopti_plus/unified-" .. state.day .. ".log" end,
		errors_log_path = function() return "/fixture/logs/ergopti_plus/errors-" .. state.day .. ".log" end,
	}
	package.loaded["ui.log_openers"] = nil
	io.open = function(path, mode)
		if state.existing[path] then
			return { close = function() return true end }
		end
		if tostring(path):sub(1, 9) == "/fixture/" then return nil, "absent" end
		return real_open(path, mode)
	end
	local ok, err = pcall(function() body(require("ui.log_openers")) end)
	io.open = real_open
	package.loaded["infra.logger_sink"] = saved_sink
	package.loaded["ui.log_openers"] = saved_openers
	if not ok then error(err, 0) end
end

--- An opener double recording every target.
local function recorder()
	local targets = {}
	return function(target)
		targets[#targets + 1] = target
		return true
	end, targets
end

helpers.describe("log openers (log-openers)", function()
	helpers.it("announces a missing errors file instead of opening it", function()
		with_openers({ day = "2099-01-01", existing = {} }, function(Openers)
			local open_fn, targets = recorder()
			local notified = {}
			helpers.assert_true(Openers.open_today_errors(open_fn, function(key)
				notified[#notified + 1] = key
				return true
			end))
			helpers.assert_eq(#targets, 0, "a missing file must never reach xdg-open")
			helpers.assert_eq(notified, { "menu.debug.no_errors_today" })
		end)
	end)

	helpers.it("opens an existing errors file", function()
		local state = { day = "2099-01-02", existing = {} }
		state.existing["/fixture/logs/ergopti_plus/errors-2099-01-02.log"] = true
		with_openers(state, function(Openers)
			local open_fn, targets = recorder()
			helpers.assert_true(Openers.open_today_errors(open_fn, function() error("must not notify") end))
			helpers.assert_eq(targets, { "/fixture/logs/ergopti_plus/errors-2099-01-02.log" })
		end)
	end)

	helpers.it("names today's log at the moment of the call", function()
		local state = { day = "2099-01-03", existing = {} }
		with_openers(state, function(Openers)
			local open_fn, targets = recorder()
			Openers.open_today_log(open_fn)
			state.day = "2099-01-04"
			Openers.open_today_log(open_fn)
			Openers.open_logs_folder(open_fn)
			helpers.assert_eq(targets, {
				"/fixture/logs/ergopti_plus/unified-2099-01-03.log",
				"/fixture/logs/ergopti_plus/unified-2099-01-04.log",
				"/fixture/logs/ergopti_plus",
			})
		end)
	end)

	helpers.it("refuses a missing opener", function()
		with_openers({ day = "2099-01-05", existing = {} }, function(Openers)
			helpers.assert_throws(function() Openers.open_today_log(nil) end)
		end)
	end)
end)
