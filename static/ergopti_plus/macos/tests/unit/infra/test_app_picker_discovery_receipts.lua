--- tests/unit/infra/test_app_picker_discovery_receipts.lua

--- ==============================================================================
--- MODULE: Application Discovery Completion Receipts
--- DESCRIPTION:
--- Failed scans must not masquerade as successful empty choices or present a UI.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.app_picker_discovery_fixture")

local function prepare(state, mode)
	if mode == "classification" then state.status = "error" end
	if mode == "start" then state.started = false end
end

local function fail_scan(state, mode)
	if mode == "exit" then state.pending[#state.pending].callback(1, "/Applications/Partial.app\n") end
	if mode == "stdout" then state.pending[#state.pending].callback(0, nil) end
end

helpers.describe("app_picker: discovery receipts", function()
	for _, fail in ipairs({ false, true }) do
		helpers.it("restores fixture globals after callback failure=" .. tostring(fail), function()
			local original_hs, original_time, original_getenv = hs, os.time, os.getenv
			local original_picker = package.loaded["infra.app_picker"]
			local ok, failure = pcall(with_picker, function()
				if fail then error("injected fixture callback failure") end
			end)
			helpers.assert_eq(ok, not fail)
			if fail then helpers.assert_true(tostring(failure):find("injected fixture callback failure", 1, true) ~= nil) end
			helpers.assert_eq(hs, original_hs)
			helpers.assert_eq(os.time, original_time)
			helpers.assert_eq(os.getenv, original_getenv)
			helpers.assert_eq(package.loaded["infra.app_picker"], original_picker)
		end)
	end

	for _, reenter in ipairs({ false, true }) do
		helpers.it("retires a failed request's predecessor with cleanup reentry=" .. tostring(reenter), function()
			with_picker(function(picker, state)
				local changes = 0
				local action = picker.build_menu({}, function() changes = changes + 1 end)[1].action
				action()
				state.pending[1].callback(0, "/Applications/A.app\n")
				local previous = state.choosers[1]
				state.now = state.now + 61
				action()
				if reenter then
					state.on_delete = function()
						state.on_delete = nil
						action()
						state.pending[3].callback(0, "/Applications/B.app\n")
					end
				end
				state.pending[2].callback(1, "")
				helpers.assert_eq(previous.deleted, 1)
				previous.callback({ text = "A", appPath = "/Applications/A.app" })
				helpers.assert_eq(changes, 0)
				if not reenter then
					helpers.assert_eq(#state.choosers, 1)
					action()
					state.pending[3].callback(0, "/Applications/B.app\n")
				end
				helpers.assert_eq(#state.choosers, 2)
				helpers.assert_eq(state.choosers[2].deleted, 0)
				state.choosers[2].callback(nil)
			end)
		end)
	end

	for _, mode in ipairs({ "classification", "start", "exit", "stdout" }) do
		helpers.it("reports explicit failure and retry after " .. mode, function()
			with_picker(function(picker, state)
				local receipts = {}
				local function capture(...)
					local rows, success = ...
					receipts[#receipts + 1] = { count = select("#", ...), rows = rows, success = success }
				end
				prepare(state, mode)
				picker.discover_apps(capture)
				fail_scan(state, mode)
				helpers.assert_eq(receipts, { { count = 2, success = false } })
				state.status, state.started = "absent", true
				local previous = #state.pending
				picker.discover_apps(capture)
				helpers.assert_eq(#state.pending, previous + 1)
				state.pending[#state.pending].callback(0, "")
				picker.discover_apps(capture)
				helpers.assert_eq(#state.pending, previous + 1, "successful empty results may be cached")
				helpers.assert_eq(receipts[2], { count = 2, rows = {}, success = true })
				helpers.assert_eq(receipts[3], receipts[2])
			end)
		end)

		helpers.it("does not present a success-shaped empty chooser after " .. mode, function()
			with_picker(function(picker, state)
				local changes = 0
				local action = picker.build_menu({}, function() changes = changes + 1 end)[1].action
				prepare(state, mode)
				action()
				fail_scan(state, mode)
				helpers.assert_eq(#state.choosers, 0)
				helpers.assert_eq(changes, 0)
				state.status, state.started = "absent", true
				action()
				state.pending[#state.pending].callback(0, "")
				helpers.assert_eq(#state.choosers, 1)
				helpers.assert_eq(state.choosers[1].rows, {})
				helpers.assert_eq(state.choosers[1].shown, 1)
				state.choosers[1].callback(nil)
				helpers.assert_eq(state.choosers[1].deleted, 1)
				helpers.assert_eq(changes, 0)
			end)
		end)
	end
end)
