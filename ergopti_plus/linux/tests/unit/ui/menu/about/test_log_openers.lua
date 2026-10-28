--- tests/unit/ui/menu/about/test_log_openers.lua

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
	local saved_reader = package.loaded["infra.regular_file_reader"]
	local reader = require("infra.regular_file_reader")
	package.loaded["infra.logger_sink"] = {
		log_dir = function() return "/fixture/logs/ergopti_plus" end,
		main_log_path = function() return "/fixture/logs/ergopti_plus/unified-" .. state.day .. ".log" end,
		errors_log_path = function() return state.path or "/fixture/logs/ergopti_plus/errors-" .. state.day .. ".log" end,
	}
	package.loaded["ui.log_openers"] = nil
	if not state.native then
		package.loaded["infra.regular_file_reader"] = { ENOENT = reader.ENOENT, open = function(path)
			if state.existing[path] then
				return { close = function()
					if state.close_refuses then return nil, state.close_failure end
					return true
				end }
			end
			return nil, "absent", reader.ENOENT
		end }
	end
	local ok, err = pcall(function() body(require("ui.log_openers")) end)
	package.loaded["infra.regular_file_reader"] = saved_reader
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

helpers.describe("log-openers-native-refusal", function()
	helpers.it("(log-openers-native-refusal) never calls a denied log an error-free day", function()
		local native = require("luv")
		local path = os.tmpname()
		assert(native.fs_chmod(path, 0))
		local notified, opened, handled = 0, 0, nil
		local ok, failure = pcall(function()
			with_openers({ native = true, path = path }, function(Openers)
				handled = Openers.open_today_errors(function() opened = opened + 1; return true end,
					function() notified = notified + 1; return true end)
			end)
		end)
		assert(native.fs_chmod(path, 384))
		os.remove(path)
		if not ok then error(failure, 0) end
		helpers.assert_eq(handled, false, "EACCES must refuse the action instead of claiming no errors exist")
		helpers.assert_eq(opened, 0)
		helpers.assert_eq(notified, 0, "the no-errors notification needs proven ENOENT")
	end)

	local native_ok, native = pcall(require, "luv")
	local ffi_ok, ffi = pcall(require, "ffi")
	if not native_ok or not ffi_ok then return end
	helpers.it("(log-openers-native-refusal) rejects a FIFO log without waiting for a writer", function()
		ffi.cdef("int mkfifo(const char *pathname, unsigned int mode);")
		local path = os.tmpname()
		os.remove(path)
		helpers.assert_eq(ffi.C.mkfifo(path, 384), 0)
		local code = string.format([[
			package.path = %q
			package.loaded["infra.logger_sink"] = { errors_log_path = function() return %q end }
			local opened, notified = 0, 0
			local handled = require("ui.log_openers").open_today_errors(
				function() opened = opened + 1; return true end,
				function() notified = notified + 1; return true end)
			assert(handled == false and opened == 0 and notified == 0)
		]], package.path, path)
		local expired, exited, exit_code, exit_signal = false, false, nil, nil
		local timer = assert(native.new_timer())
		local child
		child = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
			exited, exit_code, exit_signal = true, status, signal
			native.timer_stop(timer)
			native.close(timer)
			native.close(child)
		end))
		assert(require("infra.native_timer").start(native, timer, 2000, 0, function() expired = true; child:kill("sigkill") end))
		while not exited do native.run("once") end
		native.run("nowait")
		os.remove(path)
		helpers.assert_eq(expired, false, "a tray action must never block on a FIFO log")
		helpers.assert_eq(exit_code, 0, "a special file must be refused without a no-errors notice")
		helpers.assert_eq(exit_signal, 0, "a killed or crashed opener must never count as success")
	end)
end)

helpers.describe("log-openers-read-receipts", function()
	helpers.it("(log-openers-read-receipts) refuses an unsuccessful close without claiming an empty log", function()
		local path = "/fixture/errors.log"
		local failure = setmetatable({}, { __tostring = function() error("foreign formatter must not run") end })
		with_openers({ path = path, existing = { [path] = true }, close_refuses = true, close_failure = failure }, function(Openers)
			local opened, notified = 0, 0
			local handled = Openers.open_today_errors(function() opened = opened + 1; return true end,
				function() notified = notified + 1; return true end)
			helpers.assert_eq(handled, false)
			helpers.assert_eq(opened, 0)
			helpers.assert_eq(notified, 0)
		end)
	end)

	helpers.it("(log-openers-read-receipts) native ENOENT is the only error-free-day notice", function()
		local path = os.tmpname()
		os.remove(path)
		local reader = require("infra.regular_file_reader")
		local stream, _, code = reader.open(path)
		helpers.assert_eq(stream, nil)
		helpers.assert_eq(code, reader.ENOENT, "the canonical absence code must match the real native receipt")
		with_openers({ path = path, native = true }, function(Openers)
			local opened, notices = 0, {}
			local handled = Openers.open_today_errors(function() opened = opened + 1; return true end,
				function(key) notices[#notices + 1] = key; return true end)
			helpers.assert_eq(handled, true)
			helpers.assert_eq(opened, 0)
			helpers.assert_eq(notices, { "menu.debug.no_errors_today" })
		end)
	end)
end)
