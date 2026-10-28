--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_modal_error_outcome.lua

--- ==============================================================================
--- MODULE: Modal Exceptions Keep Their Exact Outcome
--- DESCRIPTION:
--- A dialog's pcall status owns failure even when its error is false or nil.
--- Native restoration and its observer cannot turn that failure into success.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Executes the actual modal owner over the hook's controlled kernel boundary.
--- @param intercept boolean Whether the source is intercepted or observed.
--- @param dialog function Original dialog body.
--- @param observer_error boolean Whether the restoration observer raises.
--- @param restoration_refused boolean|nil Whether the native restoration fails.
--- @return table observed Exact caller results and native restoration receipts.
local function run_modal(intercept, dialog, observer_error, restoration_refused)
	local Hook = helpers.load_module("adapters.keyboard_hook")
	local Reader = require("adapters.evdev_reader")
	local grab, ungrab, pressed_keys = Reader.grab, Reader.ungrab, Reader.pressed_keys
	local observed = { stages = {}, grabs = 0, ungrabs = 0, desyncs = 0 }
	Reader.grab = function(...)
		observed.grabs = observed.grabs + 1
		if restoration_refused then return false end
		return grab(...)
	end
	Reader.ungrab = function(...)
		observed.ungrabs = observed.ungrabs + 1
		return ungrab(...)
	end
	if restoration_refused and not intercept then
		Reader.pressed_keys = function() return nil, "controlled query refusal" end
	end
	local called, failure = pcall(function()
		Hook._test_drive({ { type = 1, code = 30, value = 1 } }, {
			onChar = function()
				local function keep(...) observed.results = { n = select("#", ...), ... } end
				keep(pcall(Hook.while_released, dialog, { observer = function(stage, receipt)
					observed.stages[#observed.stages + 1] = stage
					observed.receipt = receipt
					if observer_error and stage == "before" then error("observer failed", 0) end
				end }))
				observed.running = Hook.isRunning()
			end,
			onDesync = function() observed.desyncs = observed.desyncs + 1 end,
			onEmitRaw = function() return true end,
		}, intercept)
	end)
	Reader.grab, Reader.ungrab, Reader.pressed_keys = grab, ungrab, pressed_keys
	if not called then error(failure, 0) end
	return observed
end

helpers.describe("keyboard_hook modal exact failure outcome (linux-modal-error-outcome)", function()
	for _, intercept in ipairs({ false, true }) do
		local mode = intercept and "intercept" or "observe"
		for _, kind in ipairs({ "false", "nil" }) do
			helpers.it("propagates a " .. kind .. " dialog error after " .. mode .. " restoration", function()
				local expected
				if kind == "false" then expected = false end
				local result = run_modal(intercept, function()
					if kind == "false" then error(false, 0) end
					error(nil, 0)
				end)
				helpers.assert_eq(result.results[1], false, "pcall failure cannot become modal success")
				helpers.assert_eq(result.results[2], expected, "the caller receives the original falsey error")
				helpers.assert_eq(result.stages, { "before", "after" })
				helpers.assert_eq(result.receipt.ok, false, "failed dialogs never acknowledge a successful resume")
				helpers.assert_eq(result.desyncs, 1, "restoration still invalidates input before propagating")
				helpers.assert_eq({ result.grabs, result.ungrabs }, intercept and { 1, 1 } or { 0, 0 })
			end)
		end
		for _, kind in ipairs({ "false", "nil" }) do
			helpers.it("keeps a " .. kind .. " error when " .. mode .. " restoration is refused", function()
				local expected
				if kind == "false" then expected = false end
				local result = run_modal(intercept, function()
					if kind == "false" then error(false, 0) end
					error(nil, 0)
				end, false, true)
				helpers.assert_eq(result.results[1], false)
				helpers.assert_eq(result.results[2], expected)
				helpers.assert_eq(result.stages, { "refused" })
				helpers.assert_eq(result.receipt.ok, false)
				helpers.assert_eq(result.desyncs, 0)
				helpers.assert_eq(result.running, false)
			end)
		end
		helpers.it("preserves the original error when the " .. mode .. " observer also fails", function()
			local expected = { original = mode }
			local result = run_modal(intercept, function() error(expected, 0) end, true)
			helpers.assert_eq(result.results[1], false)
			helpers.assert_true(rawequal(result.results[2], expected), "secondary observer failure cannot swallow the original object")
			helpers.assert_eq(result.stages, { "before", "refused" })
			helpers.assert_eq(result.receipt.ok, false)
			helpers.assert_eq(result.running, false, "the failing observer still retires capture")
		end)
		helpers.it("keeps successful false and nil results under " .. mode .. " capture", function()
			local result = run_modal(intercept, function() return false, nil, "last" end)
			helpers.assert_eq(result.results.n, 4)
			helpers.assert_eq(result.results[1], true)
			helpers.assert_eq(result.results[2], false)
			helpers.assert_eq(result.results[3], nil)
			helpers.assert_eq(result.results[4], "last")
			helpers.assert_eq(result.receipt.ok, true, "a returned false is not a thrown false")
			helpers.assert_eq(result.running, true)
		end)
	end
end)
