--- tests/unit/modules/keylogger/test_native_physical_context_owner.lua

--- Checks diagnostic ownership with explicit native doubles; real AX proof remains macOS-only.
local helpers = require("tests.helpers")

local function scope(callback)
	helpers.with_stub_scope({ "hs", "modules.keylogger.timestamp", "adapters.process_lifecycle",
		"adapters.secure_field_detector" }, function()
		local state = { now = 10, secure = false, stop_refused = false, watch_refused = false, lifecycle_stops = 0 }
		local observers, callbacks, observations, errors = {}, {}, {}, {}
		local app = { name = function() return "ObservedApp" end, pid = function() return 42 end,
			bundleID = function() return "test.observed" end, path = function() return "/Observed.app" end }
		local win = { application = function() return app end, title = function() return "Public" end,
			id = function() return 7 end }
		_G.hs = { application = { frontmostApplication = function() return app end },
			window = { focusedWindow = function() return win end },
			axuielement = { windowElement = function() return {} end },
			timer = { absoluteTime = function() state.now = state.now + 10; return state.now end } }
		package.loaded["modules.keylogger.timestamp"] = { now_epoch = function() return 1000 end, format_epoch = tostring }
		package.loaded["adapters.process_lifecycle"] = {
			onAppActivate = function(fn) callbacks.app = fn end,
			onFocusChange = function(fn) callbacks.focus = fn end,
			start = function() return true end,
			stop = function() state.lifecycle_stops = state.lifecycle_stops + 1; return true end,
		}
		package.loaded["adapters.secure_field_detector"] = {
			inspectFocusedElement = function() return state.secure, "missing focused element" end,
			isSecureApp = function() return false end,
			watchFocusedElementChanges = function(_, fn)
				local observer = { callback = fn, running = true }
				function observer:stop() if state.stop_refused then return false end; self.running = false; return self end
				function observer:isRunning() return self.running end
				function observer:addWatcher() return self end
				observers[#observers + 1] = observer
				return observer, "watch refused", not state.watch_refused
			end,
		}
		local factory = assert(loadfile(helpers.driver_root() .. "../../../tools/diagnostics/hs274-context.lua"))()
		local owner = factory.new(8, observations, function(reason) errors[#errors + 1] = reason end)
		callback(owner, state, callbacks, observers, observations, errors)
	end)
end

local function rejects(callback, fragment)
	local ok, err = pcall(callback)
	helpers.assert_eq(ok, false)
	helpers.assert_true(tostring(err):find(fragment, 1, true) ~= nil, tostring(err))
end

helpers.describe("native physical context ownership (hs274)", function()
	helpers.it("retains native observations and fences callbacks from replaced observers", function()
		scope(function(owner, state, callbacks, observers, observations, errors)
			owner.start()
			helpers.assert_eq(owner.history.resolve(20).app, "ObservedApp")
			state.secure = true
			callbacks.focus()
			helpers.assert_eq(owner.history.resolve(30), { allowed = false })
			helpers.assert_eq(observations[2], { observed_ns = "30", allowed = false })
			observers[1].callback()
			helpers.assert_eq(#observations, 2)
			owner.stop()
			callbacks.app()
			observers[2].callback()
			helpers.assert_eq(#observations, 2)
			helpers.assert_eq(#errors, 0)
			rejects(owner.start, "already started")
		end)
	end)

	helpers.it("refuses startup without an actual focused-element decision", function()
		scope(function(owner, state, _, _, _, errors)
			state.secure = nil
			rejects(owner.start, "failed during startup")
			helpers.assert_eq(#errors, 1)
			owner.stop()
			helpers.assert_eq(state.lifecycle_stops, 1)
		end)
	end)

	helpers.it("keeps refused cleanup retryable while context lookup is already revoked", function()
		scope(function(owner, state, _, observers)
			owner.start()
			state.stop_refused = true
			rejects(owner.stop, "did not stop")
			rejects(function() owner.history.resolve(20) end, "retired")
			helpers.assert_eq(observers[1].running, true)
			state.stop_refused = false
			owner.stop()
			helpers.assert_eq(observers[1].running, false)
			helpers.assert_eq(state.lifecycle_stops, 2)
		end)
	end)

	helpers.it("retains an uncommitted native observer for startup rollback", function()
		scope(function(owner, state, _, observers, _, errors)
			state.watch_refused = true
			rejects(owner.start, "failed during startup")
			helpers.assert_eq(#errors, 1)
			rejects(function() owner.history.resolve(20) end, "retired")
			owner.stop()
			helpers.assert_eq(observers[1].running, false)
		end)
	end)
end)
