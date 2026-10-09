--- tests/unit/modules/test_gesture_close_ack.lua

local helpers = require("tests.helpers")

local function with_reader(close, body)
	local names = { "adapters.evdev_reader", "modules.gestures.manager", "ffi" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local ok, err = pcall(function()
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend({ open = function() return 7 end, close = close,
			ioctl = function() return true end })
		body(reader)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("evdev close acknowledgement", function()
	helpers.it("accepts completed void backends and acknowledges an idle close", function()
		local calls = 0
		with_reader(function() calls = calls + 1 end, function(reader)
			helpers.assert_eq(reader.close(reader.TOUCHPAD), true)
			helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
			helpers.assert_eq(reader.close(reader.TOUCHPAD), true)
			helpers.assert_eq(reader.close(reader.TOUCHPAD), true)
			helpers.assert_eq(calls, 1)
		end)
	end)

	for _, failure in ipairs({ "return", "throw" }) do
		helpers.it("retains " .. failure .. " debt without closing a recycled descriptor", function()
			local calls = 0
			with_reader(function()
				calls = calls + 1
				if failure == "throw" then error("close outcome unknown") end
				return false, "close errno=5"
			end, function(reader)
				helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
				local closed, reason = reader.close(reader.TOUCHPAD)
				helpers.assert_eq(closed, false)
				helpers.assert_type(reason, "string")
				helpers.assert_eq(reader.is_open(reader.TOUCHPAD), false, "retired handles cannot be read")
				helpers.assert_eq(reader.close(reader.TOUCHPAD), false, "debt survives an idle descriptor")
				helpers.assert_eq(reader.open("/dev/input/reused", reader.TOUCHPAD), false)
				helpers.assert_eq(calls, 1, "never retry close(2), including after an exception")
				helpers.assert_true(reader.open("/dev/input/keyboard", reader.KEYBOARD), "other slots remain independent")
			end)
		end)
	end

	helpers.it("attempts close even when ungrab raises", function()
		local calls = 0
		with_reader(function() calls = calls + 1 return true end, function(reader)
			helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
			helpers.assert_true(reader.grab(reader.TOUCHPAD))
			reader.ungrab = function() error("ioctl failed") end
			helpers.assert_eq(reader.close(reader.TOUCHPAD), true)
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("uses the production FFI close result and errno without retry", function()
		with_reader(function() end, function(reader)
			local calls = 0
			package.loaded.ffi = { cdef = function() end, new = function() return {} end,
				errno = function() return 5 end,
				C = { open = function() return 7 end, close = function() calls = calls + 1 return -1 end } }
			helpers.assert_true(reader.use_ffi_backend())
			helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
			local closed, reason = reader.close(reader.TOUCHPAD)
			helpers.assert_eq(closed, false)
			helpers.assert_contains(reason, "errno=5")
			helpers.assert_eq(reader.close(reader.TOUCHPAD), false)
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("refuses scope publication and restoration after a real reader close failure", function()
		with_reader(function() error("native outcome unknown") end, function(reader)
			local manager = helpers.load_module("modules.gestures.manager")
			manager.init({ enabled = false, persist = false })
			helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
			manager._test_begin_reading({ feed = function() error("must not dispatch") end })
			local before = manager.capture_scope_state()
			local candidate = manager.capture_scope_state()
			candidate.enabled, candidate.reading = false, false
			helpers.assert_eq(manager.apply_scope_state(candidate), false)
			helpers.assert_eq(manager.is_reading(), true, "unacknowledged ownership is retained")
			helpers.assert_eq(manager.capture_scope_state(), nil, "uncertain native state cannot seed another transaction")
			helpers.assert_eq(manager.pump(), 0)
			helpers.assert_eq(manager.start_reading(), false, "already-reading cannot hide close debt")
			helpers.assert_eq(manager.apply_scope_state(before), false, "rollback cannot claim native restoration")
			helpers.assert_eq(manager.stop_reading(), false)
		end)
	end)

	helpers.it("acknowledges a successful manager stop and clears reader state", function()
		with_reader(function() return true end, function(reader)
			local manager = helpers.load_module("modules.gestures.manager")
			manager.init({ enabled = false, persist = false })
			helpers.assert_true(reader.open("/dev/input/test", reader.TOUCHPAD))
			manager._test_begin_reading({})
			helpers.assert_eq(manager.stop_reading(), true)
			helpers.assert_eq(manager.is_reading(), false)
			helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)

	for _, failure in ipairs({ "missing", "void", "throw" }) do
		helpers.it("rejects a " .. failure .. " public close acknowledgement", function()
			with_reader(function() return true end, function(reader)
				local manager = helpers.load_module("modules.gestures.manager")
				manager.init({ enabled = false, persist = false })
				manager._test_begin_reading({})
				if failure == "missing" then reader.close = nil
				elseif failure == "void" then reader.close = function() end
				else reader.close = function() error("public close failed") end end
				helpers.assert_eq(manager.stop_reading(), false)
				helpers.assert_eq(manager.is_reading(), true)
				helpers.assert_eq(manager.start_reading(), false)
			end)
		end)
	end
end)
