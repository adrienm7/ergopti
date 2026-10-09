--- tests/unit/platform/remap/guardian_recovery/test_open_login_items.lua

--- ==============================================================================
--- MODULE: Opening Login Items For The Remap Guardian
--- DESCRIPTION:
--- The shell runner refuses a launch it cannot start by logging an error and
--- answering false synchronously. open_login_items then reported that refusal
--- as `open-exited-non-zero` and logged a second error of its own, and every
--- error line raises a developer notification. A refusal now keeps its own
--- reason and its single error line.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local count_logs = fixture.count_logs
local with_remap = fixture.with_remap

--- Runs one body with a shell runner double, restored afterwards.
--- @param open function Double for shell_runner.open(target, on_done).
--- @param body function Receives nothing.
local function with_runner(open, body)
	local saved = package.loaded["adapters.shell_runner"]
	package.loaded["adapters.shell_runner"] = { open = open }
	local ok, err = pcall(body)
	package.loaded["adapters.shell_runner"] = saved
	if not ok then error(err, 0) end
end

helpers.describe("Karabiner Login Items opener", function()
	helpers.it("keeps a refused launch's reason and adds no error line (login-items-open-failed)", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			with_runner(function(_, on_done)
				on_done(false)
				return false
			end, function()
				local results = {}
				helpers.assert_true(remap.open_login_items(function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end) == false)
				helpers.assert_eq(#results, 1)
				helpers.assert_true(results[1].ok == false)
				helpers.assert_eq(results[1].reason, "open-request-rejected")
				helpers.assert_eq(count_logs(calls, "error", "login items"), 0,
					"the runner already logged its refusal")
			end)
		end)
	end)

	helpers.it("names an open that exited non-zero", function()
		with_remap({ initial_phase = "idle" }, function(remap)
			local finish = nil
			with_runner(function(_, on_done)
				finish = on_done
				return true
			end, function()
				local results = {}
				helpers.assert_true(remap.open_login_items(function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end) == true)
				finish(false)
				helpers.assert_eq(#results, 1)
				helpers.assert_eq(results[1].reason, "open-exited-non-zero")
			end)
		end)
	end)

	helpers.it("logs a raising runner once and reports it", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			with_runner(function() error("synthetic-open-failure") end, function()
				local results = {}
				helpers.assert_true(remap.open_login_items(function(ok, reason)
					results[#results + 1] = { ok = ok, reason = reason }
				end) == false)
				helpers.assert_eq(#results, 1)
				helpers.assert_eq(results[1].reason, "open-request-raised")
				helpers.assert_eq(count_logs(calls, "error", "login items"), 1)
			end)
		end)
	end)
end)
