--- tests/unit/infra/lifecycle/test_dialog_focus_terminal_owner.lua

--- ==============================================================================
--- MODULE: Nonblocking Dialog Focus Terminal Ownership
--- DESCRIPTION:
--- Drives real DialogUtil and TimerScheduler with local native ports. A closed
--- gesture confirmation must not reopen Hammerspoon after its callback restored
--- another application. Timers and cache owners retire even on causal failures.
--- ==============================================================================

local helpers = require("tests.helpers")
local OWNERS = { "hs", "tests.stubs.hs", "infra.dialog_util", "infra.logger",
	"adapters.timer_scheduler", "adapters.shell_runner", "adapters.running_application",
	"infra.text_utils", "text_utils", "compat.utf8", "window_titles",
	"error_description", "number_policy" }




-- =======================================
-- =======================================
-- ======= 1/ Scoped Native Dialog Ports ==
-- =======================================
-- =======================================

--- Runs one fresh dialog owner and always drains its exact timer capabilities.
--- @param callback function Receives recording ports and real dialog wrappers.
--- @return ... results Original callback results.
local function with_dialog(callback)
	return helpers.with_stub_scope(OWNERS, function()
		local fixture = { timers = {}, alerts = {}, spawns = {}, focus = 0, callback_count = 0 }
		local overrides = {
			processInfo = { bundlePath = "/fixture/Hammerspoon.app" },
			focus = function() fixture.focus = fixture.focus + 1 end,
			timer = {}, dialog = {},
		}
		overrides.timer.new = function(delay, work)
			local timer = { delay = delay, work = work, enabled = false, stop_calls = 0 }
			function timer:start() self.enabled = true; return self end
			function timer:stop()
				self.stop_calls = self.stop_calls + 1
				if self.refuse_stop then error("controlled native focus timer stop refusal", 0) end
				self.enabled = false; return self
			end
			function timer:running() return self.enabled end
			function timer:deliver() self.work() end
			fixture.timers[#fixture.timers + 1] = timer
			return timer
		end
		overrides.dialog.alert = function(...)
			if fixture.constructor_throws then error("controlled native alert constructor failure", 0) end
			fixture.alerts[#fixture.alerts + 1] = { args = table.pack(...), closed = false }
			-- The pinned native Lua wrapper returns zero values, not a success ACK.
		end
		overrides.dialog.blockAlert = function() return "Cancel" end
		overrides.dialog.textPrompt = function() return "Cancel", "typed" end
		function fixture.answer(index, button)
			local alert = assert(fixture.alerts[index])
			alert.closed = true -- The native wrapper deletes its hidden webview first.
			return alert.args[3](button)
		end
		function fixture.open(callback)
			local returned = table.pack(fixture.subject.alert(10, 20, callback or function(button)
				fixture.callback_count = fixture.callback_count + 1
				fixture.last_button = button
			end, "Question", "Details", "Cancel", "Confirm", "warning"))
			helpers.assert_eq(returned.n, 0, "Healthy native alert return arity must remain zero")
		end
		local result = table.pack(xpcall(function()
			local logger = helpers.make_logger_stub()
			logger.run_modal = function(work, ...) return work(...) end
			package.loaded["infra.logger"] = logger
			package.loaded["adapters.running_application"] = {
				current = function() return { activate = function() return true end } end,
			}
			package.loaded["adapters.shell_runner"] = { spawn = function(executable, args)
				local process = { executable = executable, args = args, start_calls = 0 }
				process.start = function() process.start_calls = process.start_calls + 1; return true end
				fixture.spawns[#fixture.spawns + 1] = process
				return process
			end }
			fixture.subject = helpers.load_with_stubs("infra.dialog_util", overrides)
			fixture.scheduler = assert(package.loaded["adapters.timer_scheduler"])
			return callback(fixture)
		end, debug.traceback))
		for _, timer in ipairs(fixture.timers) do timer.refuse_stop = false end
		local settled = fixture.scheduler == nil or fixture.scheduler.cancelAll() == true
		local quiet = true
		for _, timer in ipairs(fixture.timers) do if timer.enabled then quiet = false end end
		if not settled or not quiet then error("Dialog fixture retained a native timer", 0) end
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end)
end




-- =======================================
-- =======================================
-- ======= 2/ Terminal Business Controls ==
-- =======================================
-- =======================================

helpers.describe("dialog focus: terminal alert ownership", function()
	helpers.it("does not reopen Hammerspoon after a quick dialog cancellation", function()
		with_dialog(function(fixture)
			fixture.open(); helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.timers[1].delay, 0.1)
			fixture.answer(1, "Cancel")
			helpers.assert_eq(fixture.callback_count, 1)
			helpers.assert_eq(fixture.last_button, "Cancel")
			fixture.timers[1]:deliver()
			helpers.assert_eq(#fixture.spawns, 0,
				"A dismissed alert must not launch a delayed application focus")
		end)
	end)

	helpers.it("retires the focus nudge before a throwing user callback", function()
		with_dialog(function(fixture)
			fixture.open(function() error("controlled user callback failure", 0) end)
			local ok, detail = pcall(fixture.answer, 1, "Cancel")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("controlled user callback failure", 1, true) ~= nil)
			fixture.timers[1]:deliver()
			helpers.assert_eq(#fixture.spawns, 0,
				"A failed terminal callback must not leave a future focus effect")
		end)
	end)

	helpers.it("retires the focus nudge when native alert construction throws", function()
		with_dialog(function(fixture)
			fixture.constructor_throws = true
			local ok, detail = pcall(fixture.open)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(detail):find("controlled native alert constructor failure", 1, true) ~= nil)
			helpers.assert_eq(#fixture.alerts, 0)
			fixture.timers[1]:deliver()
			helpers.assert_eq(#fixture.spawns, 0,
				"An alert that never opened must not focus the application later")
		end)
	end)

	helpers.it("keeps one deferred focus while its nonblocking alert remains open", function()
		with_dialog(function(fixture)
			fixture.open(); fixture.timers[1]:deliver(); fixture.timers[1]:deliver()
			helpers.assert_eq(fixture.alerts[1].closed, false)
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(fixture.spawns[1].executable, "/usr/bin/open")
			helpers.assert_eq(fixture.spawns[1].args, { "/fixture/Hammerspoon.app" })
			helpers.assert_eq(fixture.spawns[1].start_calls, 1)
			fixture.answer(1, "Confirm")
			helpers.assert_eq(fixture.callback_count, 1)
			helpers.assert_eq(fixture.timers[1].stop_calls, 1)
		end)
	end)

	helpers.it("keeps a successor alert's nudge independent of its completed predecessor", function()
		with_dialog(function(fixture)
			fixture.open(function() fixture.open() end)
			fixture.answer(1, "Confirm")
			helpers.assert_eq(#fixture.alerts, 2)
			helpers.assert_eq(#fixture.timers, 2)
			fixture.timers[1]:deliver(); fixture.timers[2]:deliver()
			helpers.assert_eq(#fixture.spawns, 1,
				"Only the still-open successor owns a deferred focus")
		end)
	end)

	helpers.it("fences terminal focus work while exact native timer cleanup is refused", function()
		with_dialog(function(fixture)
			fixture.open(); local previous = fixture.timers[1]
			previous.refuse_stop = true
			fixture.answer(1, "Cancel"); previous:deliver()
			helpers.assert_eq(fixture.callback_count, 1)
			helpers.assert_eq(#fixture.spawns, 0,
				"Refused timer cleanup must never reopen a dismissed alert")
			previous.refuse_stop = false
			fixture.open()
			helpers.assert_eq(previous.enabled, false)
			fixture.timers[2]:deliver()
			helpers.assert_eq(#fixture.spawns, 1)
		end)
	end)

	helpers.it("keeps both blocking wrappers free of deferred focus work", function()
		with_dialog(function(fixture)
			helpers.assert_eq(fixture.subject.block_alert("Question", "Details"), "Cancel")
			local button, text = fixture.subject.text_prompt("Question", "Details")
			helpers.assert_eq(button, "Cancel"); helpers.assert_eq(text, "typed")
			helpers.assert_eq(#fixture.timers, 0)
			helpers.assert_eq(#fixture.spawns, 0)
			helpers.assert_eq(fixture.focus, 4)
		end)
	end)

	helpers.it("drains native timers and restores the runtime after a body failure", function()
		local incoming_hs, incoming_dialog = rawget(_G, "hs"), package.loaded["infra.dialog_util"]
		local observed
		local ok, detail = pcall(with_dialog, function(fixture)
			fixture.open(); observed = fixture
			error("controlled dialog fixture body failure", 0)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("controlled dialog fixture body failure", 1, true) ~= nil)
		helpers.assert_true(rawequal(rawget(_G, "hs"), incoming_hs))
		helpers.assert_true(rawequal(package.loaded["infra.dialog_util"], incoming_dialog))
		for _, timer in ipairs(observed.timers) do helpers.assert_eq(timer.enabled, false) end
	end)
end)

return true
