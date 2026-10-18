--- tests/unit/modules/keylogger/privacy/test_resident_text_identity.lua

--- ==============================================================================
--- MODULE: Resident Native Text Destination Tests
--- DESCRIPTION:
--- Keeps AI target reads on one fresh resident barrier and fences the exact joined
--- field, context generation and detector epoch across reentrant callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fixture(body, asynchronous)
	local name = "adapters.secure_field_detector"
	local previous = package.loaded[name]
	package.loaded[name] = nil
	local called, detail = pcall(function()
		local detector = require(name)
		local state = { bus = ":1.10", path = "/field/one", role = 61,
			barriers = 0, captures = 0, protected = false, now = 1000 }
		local listener, guard
		local function snapshot()
			if state.unknown then return nil end
			return { bus = state.bus, path = state.path, role = state.role }
		end
		local watch = {
			on_change = function(fn) listener = fn end,
			invalidate = function() listener(nil) end,
			pump = function() if state.pump then state.pump(guard, state) end end,
			barrier = function()
				state.barriers = state.barriers + 1
				if state.barrier then state.barrier(guard, state) end
				return snapshot()
			end,
		}
		local logger = {
			set_secure_field = function(value) state.secure = value end,
			is_context_protected = function()
				if state.policy then return state.policy(guard, state) end
				return state.protected
			end,
		}
		local options = {
			watch = watch, detector = detector, keylogger = logger,
			now_ms = function() return state.now end,
			capture_context = function()
				state.captures = state.captures + 1
				return { app_id = "code", title = "Owned editor", native_identity = "controlled-window" }
			end,
			publish_context = function() return true, state.protected end,
		}
		if asynchronous then
			local capture = options.capture_context
			options.capture_context = nil
			options.retry_ms = 250
			options.capture_context_async = function(_, _, callback)
				state.complete = function() callback(capture()) end
				return { cancel = function() return true end, is_settled = function() return state.settled ~= false end }
			end
		end
		guard = require("modules.keylogger.focus_guard").new(options)
		function state.signal() listener(snapshot()) end
		state.detector = detector
		if asynchronous then
			guard.prime(); state.complete()
			helpers.assert_true(guard.refresh(true))
		else helpers.assert_true(guard.prime()) end
		state.barriers = 0
		body(guard, state)
	end)
	package.loaded[name] = previous
	if not called then error(detail, 0) end
end

helpers.describe("Resident native AI text destination", function()
	helpers.it("(resident-text-target) uses one fresh barrier without capturing another context", function()
		fixture(function(guard, state)
			helpers.assert_eq(guard.focused_text_identity(), "atspi::1.10:/field/one")
			helpers.assert_eq(state.barriers, 1)
			helpers.assert_eq(state.captures, 1)
		end)
	end)
	helpers.it("(resident-text-target) admits the physically settled asynchronous context join", function()
		fixture(function(guard, state)
			helpers.assert_eq(guard.focused_text_identity(), "atspi::1.10:/field/one")
			helpers.assert_eq(state.barriers, 1)
			helpers.assert_eq(state.captures, 1)
		end, true)
	end)
	helpers.it("(resident-text-target) refuses staged metadata until its process physically settles", function()
		fixture(function(guard, state)
			guard.invalidate(); guard.refresh(true)
			state.settled = false; state.complete()
			helpers.assert_eq(guard.refresh(true), false)
			helpers.assert_eq(guard.focused_text_identity(), nil)
			state.settled = true
			helpers.assert_true(guard.refresh(true))
			helpers.assert_eq(guard.focused_text_identity(), "atspi::1.10:/field/one")
		end, true)
	end)
	for _, refusal in ipairs({ "unknown", "password", "other field", "other bus", "protected policy", "new epoch" }) do
		helpers.it("(resident-text-target) withholds " .. refusal, function()
			fixture(function(guard, state)
				if refusal == "unknown" then state.unknown = true
				elseif refusal == "password" then state.role = 40
				elseif refusal == "other field" then state.path = "/field/two"
				elseif refusal == "other bus" then state.bus = ":1.11"
				elseif refusal == "protected policy" then state.protected = true
				else state.detector.invalidateFocus() end
				helpers.assert_eq(guard.focused_text_identity(), nil)
			end)
		end)
	end
	helpers.it("(resident-text-target) never treats a path and role concatenation collision as the same field", function()
		fixture(function(guard, state)
			state.path, state.role = "/field/a6", 1
			helpers.assert_true(guard.prime())
			state.path, state.role = "/field/a", 61
			helpers.assert_eq(guard.focused_text_identity(), nil)
		end)
	end)
	for _, boundary in ipairs({ "pump", "barrier", "policy" }) do
		helpers.it("(resident-text-target) refuses reentrant invalidation during " .. boundary, function()
			fixture(function(guard, state)
				state[boundary] = function(owner)
					state[boundary] = nil
					owner.invalidate()
					return false
				end
				helpers.assert_eq(guard.focused_text_identity(), nil)
			end)
		end)
	end
	helpers.it("(resident-text-target) fences an A to B to A native transition", function()
		fixture(function(guard, state)
			state.barrier = function()
				state.barrier = nil
				state.path = "/field/two"; state.signal()
				state.path = "/field/one"; state.signal()
			end
			helpers.assert_eq(guard.focused_text_identity(), nil)
		end)
	end)
	helpers.it("(resident-text-target) refuses a failed native barrier", function()
		fixture(function(guard, state)
			state.barrier = function() error("controlled resident barrier failure") end
			helpers.assert_eq(guard.focused_text_identity(), nil)
		end)
	end)
	for _, refusal in ipairs({ "nil", "throw" }) do
		helpers.it("(resident-text-target) refuses an inconclusive live policy: " .. refusal, function()
			fixture(function(guard, state)
				state.policy = function()
					if refusal == "throw" then error("controlled policy failure") end
				end
				helpers.assert_eq(guard.focused_text_identity(), nil)
			end)
		end)
	end
	helpers.it("(resident-text-target) refuses a nested identity reader without another barrier", function()
		fixture(function(guard, state)
			state.barrier = function()
				helpers.assert_eq(guard.focused_text_identity(), nil)
			end
			helpers.assert_eq(guard.focused_text_identity(), "atspi::1.10:/field/one")
			helpers.assert_eq(state.barriers, 1)
		end)
	end)
	helpers.it("(resident-text-target) cannot borrow a reentrant replacement join for the same field", function()
		fixture(function(guard, state)
			state.policy = function()
				state.policy = nil
				helpers.assert_true(guard.prime())
				return false
			end
			helpers.assert_eq(guard.focused_text_identity(), nil)
			helpers.assert_eq(guard.focused_text_identity(), "atspi::1.10:/field/one")
		end)
	end)
	helpers.it("(resident-text-target) refuses a stopped owner", function()
		fixture(function(guard)
			guard.stop()
			helpers.assert_eq(guard.focused_text_identity(), nil)
		end)
	end)
	helpers.it("(resident-text-target) rechecks the epoch after the final detector callback", function()
		fixture(function(guard, state)
			state.detector.isSecureField = function()
				guard.invalidate()
				return false
			end
			helpers.assert_eq(guard.focused_text_identity(), nil)
		end)
	end)
	helpers.it("(resident-text-target) never substitutes a legacy role verdict for a joined native context", function()
		local guard = require("modules.keylogger.focus_guard").new({
			keylogger = { set_secure_field = function() end }, now_ms = function() return 0 end,
			detector = { isSecureField = function() return false end },
		})
		helpers.assert_eq(guard.focused_text_identity(), nil)
	end)
end)
