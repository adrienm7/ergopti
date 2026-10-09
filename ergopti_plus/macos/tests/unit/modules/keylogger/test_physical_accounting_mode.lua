--- tests/unit/modules/keylogger/test_physical_accounting_mode.lua

--- ==============================================================================
--- MODULE: Physical accounting mode
--- DESCRIPTION:
--- Exercises the exclusive physical-source policy on its own: legacy by default,
--- stream only for an admitted complete capture, an explicit gap otherwise, and
--- a single owner for every transition. The keylogger-facing consequences are
--- driven through the real event callback in test_hs274_duplicate_count.lua and
--- test_hs274_physical_collision.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULE = "modules.keylogger.physical_accounting_mode"
local OWNER = "physical-capture"
local CAPTURE = "capture-1"

--- Runs a callback against a fresh policy instance.
--- @param callback function Receives the module.
local function with_mode(callback)
	helpers.with_fresh_modules({ MODULE, "infra.logger" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		callback(require(MODULE))
	end)
end

--- Asserts that a call raises an error containing a fragment.
--- @param callback function Call expected to raise.
--- @param fragment string Expected error text.
local function raises(callback, fragment)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false, "the call must raise")
	helpers.assert_true(tostring(err):find(fragment, 1, true) ~= nil, tostring(err))
end

helpers.describe("physical accounting mode (hs274)", function()
	helpers.it("lets the legacy sources credit until a stream is selected", function()
		with_mode(function(mode)
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_LEGACY)
			helpers.assert_eq(mode.legacy_credits(), true)
			helpers.assert_eq(mode.admitted_capture(), nil)
		end)
	end)

	helpers.it("turns a selected stream into a gap until a complete capture is admitted", function()
		with_mode(function(mode)
			helpers.assert_eq(mode.select_stream(OWNER), true)
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_GAP)
			helpers.assert_eq(mode.legacy_credits(), false)
			helpers.assert_eq(mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE), true)
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_STREAM)
			helpers.assert_eq(mode.legacy_credits(), false)
			helpers.assert_eq(mode.admitted_capture(), CAPTURE)
		end)
	end)

	helpers.it("refuses fixture-only coverage and keeps the gap", function()
		with_mode(function(mode)
			mode.select_stream(OWNER)
			local admitted, reason = mode.admit(OWNER, CAPTURE, "fixture_only")
			helpers.assert_eq(admitted, false)
			helpers.assert_eq(reason, "incomplete_coverage")
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_GAP)
			helpers.assert_eq(mode.admitted_capture(), nil)
		end)
	end)

	helpers.it("never falls back to the legacy sources when the capture ends", function()
		with_mode(function(mode)
			mode.select_stream(OWNER)
			mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE)
			helpers.assert_eq(mode.interrupt(OWNER, CAPTURE), true)
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_GAP)
			helpers.assert_eq(mode.legacy_credits(), false)
			helpers.assert_eq(mode.admit(OWNER, "capture-2", mode.COMPLETE_COVERAGE), true)
			helpers.assert_eq(mode.admitted_capture(), "capture-2")
		end)
	end)

	helpers.it("returns to the legacy sources only on the owner's explicit release", function()
		with_mode(function(mode)
			mode.select_stream(OWNER)
			mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE)
			helpers.assert_eq(mode.release(OWNER), true)
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_LEGACY)
			helpers.assert_eq(mode.legacy_credits(), true)
			helpers.assert_eq(mode.admitted_capture(), nil)
			helpers.assert_eq(mode.select_stream("successor"), true)
		end)
	end)

	helpers.it("rejects a second owner, a duplicate selection and foreign transitions", function()
		with_mode(function(mode)
			raises(function() mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE) end, "without a selected stream")
			raises(function() mode.release(OWNER) end, "without a selected stream")
			raises(function() mode.select_stream("") end, "owner must be a non-empty string")
			mode.select_stream(OWNER)
			raises(function() mode.select_stream(OWNER) end, "already selected")
			raises(function() mode.select_stream("intruder") end, "already selected")
			raises(function() mode.admit("intruder", CAPTURE, mode.COMPLETE_COVERAGE) end, "owns the stream")
			raises(function() mode.admit(OWNER, nil, mode.COMPLETE_COVERAGE) end, "capture must be")
			mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE)
			raises(function() mode.admit(OWNER, "capture-2", mode.COMPLETE_COVERAGE) end, "still admitted")
			raises(function() mode.interrupt(OWNER, "capture-2") end, "not the admitted capture")
			raises(function() mode.release("intruder") end, "owns the stream")
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_STREAM)
			helpers.assert_eq(mode.admitted_capture(), CAPTURE)
		end)
	end)
end)

helpers.describe("physical source settlement (wp3)", function()
	local operations = {
		select = function(mode) return mode.select_stream(OWNER) end,
		admit = function(mode) return mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE) end,
		interrupt = function(mode) return mode.interrupt(OWNER, CAPTURE) end,
		release = function(mode) return mode.release(OWNER) end,
	}
	local function prepare(mode, operation)
		if operation ~= "select" then mode.select_stream(OWNER) end
		if operation == "interrupt" or operation == "release" then
			mode.admit(OWNER, CAPTURE, mode.COMPLETE_COVERAGE)
		end
	end
	for _, operation in ipairs({ "select", "admit", "interrupt", "release" }) do
		for _, receipt in ipairs({ "false", "nil", "number", "throw" }) do
			helpers.it("(wp3-settlement) refuses " .. operation .. " after " .. receipt .. " settlement", function()
				with_mode(function(mode)
					local refuse, calls = false, 0
					helpers.assert_eq(mode.bind_settlement({}, function()
						calls = calls + 1
						if not refuse then return true end
						if receipt == "throw" then error("owned settlement refusal") end
						if receipt == "nil" then return nil end
						if receipt == "number" then return 1 end
						return false
					end), true)
					prepare(mode, operation)
					local source, capture, before = mode.credit_source(), mode.admitted_capture(), calls
					refuse = true
					local accepted, reason = operations[operation](mode)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(reason, "settlement_refused")
					helpers.assert_eq(mode.credit_source(), source)
					helpers.assert_eq(mode.admitted_capture(), capture)
					helpers.assert_eq(calls, before + 1)
				end)
			end)
		end
	end
	helpers.it("(wp3-settlement) binds one owner before selection and rejects replacement", function()
		with_mode(function(mode)
			local owner = {}
			helpers.assert_eq(mode.bind_settlement(false, function() return true end), false)
			helpers.assert_eq(mode.bind_settlement(owner, false), false)
			helpers.assert_eq(mode.bind_settlement(owner, function() return true end), true)
			helpers.assert_eq(mode.bind_settlement(owner, function() return true end), false)
			helpers.assert_eq(mode.bind_settlement({}, function() return true end), false)
			helpers.assert_eq(mode.select_stream(OWNER), true)
			helpers.assert_eq(mode.bind_settlement({}, function() return true end), false)
		end)
	end)
	helpers.it("(wp3-settlement) rejects reentry before any competing source publication", function()
		with_mode(function(mode)
			local observations = {}
			helpers.assert_eq(mode.bind_settlement({}, function()
				observations.source = mode.credit_source()
				observations.reentry = pcall(mode.select_stream, "intruder")
				observations.rebind = pcall(mode.bind_settlement, {}, function() return true end)
				return true
			end), true)
			helpers.assert_eq(mode.select_stream(OWNER), true)
			helpers.assert_eq(observations, { source = mode.SOURCE_LEGACY, reentry = false, rebind = false })
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_GAP)
			raises(function() mode.release("intruder") end, "owns the stream")
			helpers.assert_eq(mode.credit_source(), mode.SOURCE_GAP)
		end)
	end)
end)
