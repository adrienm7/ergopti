--- tests/unit/modules/diagnostics/test_hid_diagnostic_mailbox.lua

--- ==============================================================================
--- MODULE: HID Diagnostic Mailbox Regression Tests
--- DESCRIPTION:
--- Proves that eventtap-side diagnostics perform bounded in-memory publication
--- only, while one lifecycle-owned repeating pump delivers them off-HID. Timer
--- arm/cancel failures and logger failures remain retryable without exposing the
--- exception payload or allocating one timer per failed keystroke callback.
--- ==============================================================================

local helpers = require("tests.helpers")


local MODULES = {
	"adapters.timer_scheduler",
	"infra.logger",
	"modules.diagnostics.hid_diagnostic_mailbox",
}


--- Loads a fresh mailbox against deterministic scheduler and logger doubles.
--- @return table fixture
local function load_fixture()
	local previous = {}
	for _, name in ipairs(MODULES) do previous[name] = package.loaded[name] end

	local effects = {
		arm_calls = 0,
		cancel_calls = 0,
		cancelled_handles = {},
		handles = {},
		logs = {},
		pump = nil,
		pumps = {},
	}
	local controls = {
		arm_mode = "ok",
		cancel_mode = "ok",
		fail_diagnostic_logs = 0,
	}
	local Scheduler = {}
	function Scheduler.every(_interval, callback)
		effects.arm_calls = effects.arm_calls + 1
		local handle = { id = "diagnostic-pump-" .. tostring(effects.arm_calls) }
		effects.handles[#effects.handles + 1] = handle
		if controls.arm_mode == "throw" then error("SCHEDULER_ARM_SECRET", 0) end
		if controls.arm_mode == "nil" then return nil, nil end
		effects.pump = callback
		effects.pumps[#effects.pumps + 1] = callback
		-- The adapter returns this exact surface after native start activates then
		-- raises and its first internal rollback stop refuses
		if controls.arm_mode == "false" or controls.arm_mode == "activate_then_throw" then
			return handle, false
		end
		return handle, true
	end
	function Scheduler.cancel(candidate)
		effects.cancel_calls = effects.cancel_calls + 1
		effects.cancelled_handles[#effects.cancelled_handles + 1] = candidate
		if controls.cancel_mode == "throw" then error("SCHEDULER_CANCEL_SECRET", 0) end
		if controls.cancel_mode == "false" then return false end
		if controls.cancel_mode == "nil" then return nil end
		return true
	end
	Scheduler.after = function()
		error("a HID diagnostic must never allocate a one-shot timer", 0)
	end

	local Logger = helpers.make_logger_stub()
	local function record(level, log, format_string, ...)
		if controls.fail_diagnostic_logs > 0
			and (log == "keymap.llm_bridge"
				or log == "dynamic_hotstrings.rules"
				or log == "diagnostics.hid_mailbox")
		then
			controls.fail_diagnostic_logs = controls.fail_diagnostic_logs - 1
			error("LOGGER_SINK_SECRET", 0)
		end
		effects.logs[#effects.logs + 1] = {
			level = level,
			log = log,
			message = string.format(format_string, ...),
		}
	end
	Logger.error = function(log, format_string, ...)
		record("error", log, format_string, ...)
	end
	Logger.warn = function(log, format_string, ...)
		record("warn", log, format_string, ...)
	end

	package.loaded["adapters.timer_scheduler"] = Scheduler
	package.loaded["infra.logger"] = Logger
	package.loaded["modules.diagnostics.hid_diagnostic_mailbox"] = nil
	local Mailbox = require("modules.diagnostics.hid_diagnostic_mailbox")

	return {
		Mailbox = Mailbox,
		controls = controls,
		effects = effects,
		restore = function()
			pcall(Mailbox.stop)
			for _, name in ipairs(MODULES) do package.loaded[name] = previous[name] end
		end,
	}
end


--- Runs a fixture body and restores process-global module slots afterward.
--- @param body function Scenario receiving the fixture.
local function with_fixture(body)
	local fixture = load_fixture()
	local ok, err = xpcall(function() body(fixture) end, debug.traceback)
	fixture.restore()
	if not ok then error(err, 0) end
end





-- ===========================================
-- ===========================================
-- ======= 1/ Off-HID Delivery & Retry =======
-- ===========================================
-- ===========================================

helpers.describe("HID diagnostic mailbox: delivery", function()
	helpers.it("(hid-diagnostic-mailbox-off-tap) uses one pump and never schedules per report", function()
		with_fixture(function(fixture)
			local Mailbox = fixture.Mailbox
			helpers.assert_true(Mailbox.start())
			helpers.assert_eq(fixture.effects.arm_calls, 1)

			local poison = setmetatable({}, {
				__tostring = function() error("PRIVATE_EXCEPTION_CONTENT", 0) end,
			})
			helpers.assert_true(Mailbox.report_preview_provider_failure(7, poison))
			helpers.assert_true(Mailbox.report_resolver_failure({
				section = "private-section-name",
				suffix = "private-suffix",
			}, poison))
			helpers.assert_eq(fixture.effects.arm_calls, 1,
				"reports must reuse the lifecycle pump instead of creating timers")
			helpers.assert_eq(#fixture.effects.logs, 0,
				"publishing from HID must perform no logger I/O")

			fixture.effects.pump()
			helpers.assert_eq(#fixture.effects.logs, 2)
			helpers.assert_true(fixture.effects.logs[1].message:find("Preview provider #7 raised", 1, true) ~= nil)
			helpers.assert_true(fixture.effects.logs[2].message:find("Dynamic resolver raised", 1, true) ~= nil)
			for _, entry in ipairs(fixture.effects.logs) do
				helpers.assert_true(entry.message:find("PRIVATE_EXCEPTION_CONTENT", 1, true) == nil)
				helpers.assert_true(entry.message:find("private-section-name", 1, true) == nil)
				helpers.assert_true(entry.message:find("private-suffix", 1, true) == nil)
			end
			helpers.assert_eq(Mailbox.status().pending, 0)
			helpers.assert_true(Mailbox.stop())
			helpers.assert_eq(fixture.effects.cancel_calls, 1)
			helpers.assert_eq(fixture.effects.cancelled_handles[1], fixture.effects.handles[1],
				"stop must cancel the exact pump handle")
		end)
	end)

	helpers.it("(hid-diagnostic-mailbox-delivery-retry) retains the exact record when logging raises", function()
		with_fixture(function(fixture)
			local Mailbox = fixture.Mailbox
			helpers.assert_true(Mailbox.start())
			fixture.controls.fail_diagnostic_logs = 1
			helpers.assert_true(Mailbox.report_preview_provider_failure(3, "SECRET_FAILURE"))

			local first_ok, first_err = pcall(fixture.effects.pump)
			helpers.assert_true(first_ok, "pump failures must not escape the timer callback")
			helpers.assert_nil(first_err)
			helpers.assert_eq(Mailbox.status().pending, 1,
				"a failed sink must leave the record owned for retry")
			helpers.assert_eq(#fixture.effects.logs, 0)

			fixture.effects.pump()
			helpers.assert_eq(Mailbox.status().pending, 0)
			helpers.assert_eq(#fixture.effects.logs, 2,
				"retry must deliver the record and its recovery diagnostic")
			helpers.assert_true(fixture.effects.logs[1].message:find("Preview provider #3 raised", 1, true) ~= nil)
			helpers.assert_true(fixture.effects.logs[2].message:find("recovered after 1 failed", 1, true) ~= nil)
			for _, entry in ipairs(fixture.effects.logs) do
				helpers.assert_true(entry.message:find("SECRET_FAILURE", 1, true) == nil)
				helpers.assert_true(entry.message:find("LOGGER_SINK_SECRET", 1, true) == nil)
			end
		end)
	end)

	helpers.it("(hid-diagnostic-mailbox-bounded) coalesces overflow into a visible count", function()
		with_fixture(function(fixture)
			local Mailbox = fixture.Mailbox
			helpers.assert_true(Mailbox.start())
			local capacity = Mailbox.DEFAULT_STATE.capacity
			for index = 1, capacity + 3 do
				Mailbox.report_preview_provider_failure(index, "WITHHELD_" .. tostring(index))
			end
			local before = Mailbox.status()
			helpers.assert_eq(before.pending, capacity)
			helpers.assert_eq(before.overflow_preview, 3)

			fixture.effects.pump()
			local after = Mailbox.status()
			helpers.assert_eq(after.pending, 0)
			helpers.assert_eq(after.overflow_preview, 0)
			helpers.assert_eq(#fixture.effects.logs, capacity + 1)
			local summary = fixture.effects.logs[#fixture.effects.logs].message
			helpers.assert_true(summary:find("3 preview-provider", 1, true) ~= nil,
				"bounded loss must be reported rather than silent")
			helpers.assert_true(summary:find("WITHHELD_", 1, true) == nil)
		end)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 2/ Pump Lifecycle Ownership =======
-- ===========================================
-- ===========================================

helpers.describe("HID diagnostic mailbox: lifecycle", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains pending diagnostics after scheduler " .. mode .. " and drains on retry", function()
			with_fixture(function(fixture)
				local Mailbox = fixture.Mailbox
				Mailbox.report_resolver_failure({ section = "secret", suffix = "secret" }, "SECRET")
				fixture.controls.arm_mode = mode
				helpers.assert_eq(Mailbox.start(), false)
				helpers.assert_eq(Mailbox.status().pending, 1)
				helpers.assert_eq(Mailbox.is_running(), false)

				fixture.controls.arm_mode = "ok"
				helpers.assert_true(Mailbox.start())
				fixture.effects.pump()
				helpers.assert_eq(Mailbox.status().pending, 0)
				helpers.assert_true(Mailbox.is_running())
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact pump ownership after cancel " .. mode .. " and retries", function()
			with_fixture(function(fixture)
				local Mailbox = fixture.Mailbox
				helpers.assert_true(Mailbox.start())
				fixture.controls.cancel_mode = mode
				helpers.assert_eq(Mailbox.stop(), false)
				helpers.assert_true(Mailbox.is_running(),
					"a failed cancel must retain ownership for retry")
				helpers.assert_eq(fixture.effects.cancelled_handles[1], fixture.effects.handles[1],
					"a refused stop must retain the exact pump capability")

				fixture.controls.cancel_mode = "ok"
				helpers.assert_true(Mailbox.stop())
				helpers.assert_eq(Mailbox.is_running(), false)
				helpers.assert_eq(fixture.effects.cancel_calls, 2)
				helpers.assert_eq(fixture.effects.cancelled_handles[2], fixture.effects.handles[1],
					"the retry must target the originally retained capability")
			end)
		end)
	end

	helpers.it("supports stop/start without duplicate pumps or stale callbacks", function()
		with_fixture(function(fixture)
			local Mailbox = fixture.Mailbox
			helpers.assert_true(Mailbox.start())
			local stale_pump = fixture.effects.pump
			helpers.assert_true(Mailbox.stop())
			helpers.assert_true(Mailbox.start())
			local current_pump = fixture.effects.pump
			helpers.assert_eq(fixture.effects.arm_calls, 2)

			Mailbox.report_preview_provider_failure(9, "SECRET")
			stale_pump()
			helpers.assert_eq(Mailbox.status().pending, 1,
				"a callback from the cancelled generation must be inert")
			current_pump()
			helpers.assert_eq(Mailbox.status().pending, 0)
		end)
	end)

	helpers.it("(hid-mailbox-partial-arm-debt) retains a partially armed pump until exact cleanup", function()
		with_fixture(function(fixture)
			local Mailbox = fixture.Mailbox
			Mailbox.report_preview_provider_failure(11, "SECRET")
			fixture.controls.arm_mode = "activate_then_throw"
			fixture.controls.cancel_mode = "false"

			helpers.assert_eq(Mailbox.start(), false)
			helpers.assert_eq(fixture.effects.arm_calls, 1)
			helpers.assert_eq(fixture.effects.cancel_calls, 1,
				"failed acquisition must immediately retry exact candidate cleanup")
			local stale_pump = fixture.effects.pumps[1]
			stale_pump()
			helpers.assert_eq(Mailbox.status().pending, 1,
				"a callback from an uncommitted partially armed timer must be inert")

			helpers.assert_eq(Mailbox.start(), false,
				"a successor must be refused while exact cleanup remains pending")
			helpers.assert_eq(fixture.effects.arm_calls, 1,
				"cleanup debt must prevent allocating a second native pump")
			helpers.assert_eq(fixture.effects.cancel_calls, 2)
			helpers.assert_eq(fixture.effects.cancelled_handles[1],
				fixture.effects.cancelled_handles[2],
				"cleanup retries must target the same native capability")
			helpers.assert_eq(fixture.effects.cancelled_handles[1], fixture.effects.handles[1])

			fixture.controls.cancel_mode = "ok"
			fixture.controls.arm_mode = "ok"
			helpers.assert_true(Mailbox.start())
			helpers.assert_eq(fixture.effects.arm_calls, 2)
			local current_pump = fixture.effects.pumps[2]
			stale_pump()
			helpers.assert_eq(Mailbox.status().pending, 1,
				"the retired timer generation must remain inert after replacement")
			current_pump()
			helpers.assert_eq(Mailbox.status().pending, 0)
		end)
	end)
end)

return true
