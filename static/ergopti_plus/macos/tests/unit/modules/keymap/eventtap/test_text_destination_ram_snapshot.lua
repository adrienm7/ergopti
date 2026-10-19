--- tests/unit/modules/keymap/eventtap/test_text_destination_ram_snapshot.lua

--- ==============================================================================
--- MODULE: Text Destination RAM Snapshot Regression
--- DESCRIPTION:
--- Run real Utils and TimerScheduler with counted native clock/timer/AX ports.
--- The HID-facing snapshot must neither probe nor allocate; existing observers,
--- TTL refresh and the explicit full destination check keep their native work.
--- ==============================================================================

local helpers = require("tests.helpers")
-- Preserve the process-wide logger identity while scoping its shared adapter.
require("logger")

local function with_destination(callback)
	helpers.with_stub_scope({
		"modules.keymap.utils", "keymap.utils", "infra.text_utils", "text_utils", "compat.utf8",
		"infra.logger", "logger.shim", "infra.timings", "adapters.timer_scheduler",
		"adapters.synthetic_input", "adapters.secure_field_detector",
	}, function()
		local f = { now = 100, window = 42, element = {}, secure = false, title = "Editor",
			timers = {}, callbacks = {}, calls = { clock = 0, absolute = 0, timer = 0, start = 0, stop = 0, ax = 0, watcher = 0 } }
		local function watcher(kind, receive)
			f.calls.watcher = f.calls.watcher + 1
			f.callbacks[kind] = receive
			return { start = function(self) return self end, stop = function(self) return self end }
		end
		local app = {
			pid = function() f.calls.ax = f.calls.ax + 1; return 7 end,
			name = function() f.calls.ax = f.calls.ax + 1; return "Editor" end,
			newWatcher = function(_, receive) return watcher("focus", receive) end,
		}
		local window = {
			id = function() f.calls.ax = f.calls.ax + 1; return f.window end,
			title = function() f.calls.ax = f.calls.ax + 1; return f.title end,
			application = function() f.calls.ax = f.calls.ax + 1; return app end,
			newWatcher = function(_, receive) return watcher("title", receive) end,
		}
		_G.hs = {
			timer = {
				secondsSinceEpoch = function() f.calls.clock = f.calls.clock + 1; return f.now end,
				absoluteTime = function() f.calls.absolute = f.calls.absolute + 1; return f.now * 1000000000 end,
				new = function(delay, receive)
					f.calls.timer = f.calls.timer + 1
					local native = { delay = delay, active = false }
					function native:start() f.calls.start = f.calls.start + 1; self.active = true; return self end
					function native:stop() f.calls.stop = f.calls.stop + 1; self.active = false; return self end
					function native:running() return self.active end
					function native:fire() if self.active then receive() end end
					f.timers[#f.timers + 1] = native
					return native
				end,
			},
			application = { watcher = { activated = 1, deactivated = 2,
				new = function(receive) return watcher("app", receive) end } },
			window = { focusedWindow = function() f.calls.ax = f.calls.ax + 1; return window end },
			axuielement = { applicationElementForPID = function()
				f.calls.ax = f.calls.ax + 1
				return { attributeValue = function() f.calls.ax = f.calls.ax + 1; return f.element end }
			end },
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.timings"] = { sec = function() return 0.1 end }
		package.loaded["adapters.synthetic_input"] = {}
		package.loaded["adapters.secure_field_detector"] = {
			isSecureApp = function() return false end,
			inspectFocusedElement = function() f.calls.ax = f.calls.ax + 1; return f.secure end,
			watchFocusedElementChanges = function(_, receive) return watcher("secure", receive), nil, true end,
		}
		f.Utils = require("modules.keymap.utils")
		function f.prime()
			f.Utils.start_ignored_win_tracking({ Secret = true }, {})
			return f.Utils.prewarm_ignored_win_watchers({ Secret = true }, {})
		end
		function f.snapshot()
			local result = {}
			for name, value in pairs(f.calls) do result[name] = value end
			return result
		end
		function f.fire(delay)
			local last = #f.timers
			for index = 1, last do
				local timer = f.timers[index]
				if timer.delay == delay then timer:fire() end
			end
		end
		local ok, err = xpcall(function() callback(f) end, debug.traceback)
		local stopped = f.Utils.stop()
		if not ok then error(err, 0) end
		helpers.assert_eq(stopped, true, "the fixture must settle the real scheduler's native timer owners")
	end)
end

helpers.describe("text destination RAM snapshot", function()
	helpers.it("reads stopped tracking without any native call", function()
		with_destination(function(f)
			local before = f.snapshot()
			helpers.assert_nil(f.Utils.capture_text_destination())
			helpers.assert_eq(f.calls, before)
		end)
	end)

	helpers.it("does not allocate a native timer when the destination is still unknown", function()
		with_destination(function(f)
			f.Utils.start_ignored_win_tracking({}, {})
			local before = f.snapshot()
			helpers.assert_nil(f.Utils.capture_text_destination())
			helpers.assert_eq(f.calls, before)
		end)
	end)

	helpers.it("returns the retained safe receipt without native clocks or probes", function()
		with_destination(function(f)
			helpers.assert_true(f.prime())
			local before = f.snapshot()
			local receipt = f.Utils.capture_text_destination()
			helpers.assert_not_nil(receipt)
			helpers.assert_eq(receipt.pid, 7)
			helpers.assert_eq(receipt.window_id, 42)
			helpers.assert_true(rawequal(receipt.element, f.element))
			helpers.assert_true(rawequal(receipt, f.Utils.capture_text_destination()))
			helpers.assert_eq(f.calls, before)
		end)
	end)

	for _, mode in ipairs({ "secure", "ignored", "unreadable", "no receipt" }) do
		helpers.it("refuses " .. mode .. " state without scheduling or native reads", function()
			with_destination(function(f)
				if mode == "secure" then f.secure = true
				elseif mode == "ignored" then f.title = "Secret"
				elseif mode == "unreadable" then f.secure = nil
				else f.element = nil end
				f.prime()
				local before = f.snapshot()
				helpers.assert_nil(f.Utils.capture_text_destination())
				helpers.assert_eq(f.calls, before)
			end)
		end)
	end

	helpers.it("keeps observer invalidation and explicit full AX verification outside the snapshot", function()
		with_destination(function(f)
			helpers.assert_true(f.prime())
			local first = f.Utils.capture_text_destination()
			f.window, f.element = 43, {}
			f.callbacks.focus()
			local dirty = f.snapshot()
			helpers.assert_nil(f.Utils.capture_text_destination())
			helpers.assert_eq(f.calls, dirty)
			f.fire(0)
			local refreshed = f.snapshot()
			local second = f.Utils.capture_text_destination()
			helpers.assert_true(second.generation > first.generation)
			helpers.assert_eq(second.window_id, 43)
			helpers.assert_eq(f.calls, refreshed)
			helpers.assert_eq(f.Utils.owns_text_destination(first), false)
			helpers.assert_eq(f.Utils.owns_text_destination(second), true)
			helpers.assert_true(f.calls.ax > refreshed.ax, "the full verifier must retain its actual AX probe")
		end)
	end)

	helpers.it("leaves periodic secure-field refresh under the existing timer owner", function()
		with_destination(function(f)
			helpers.assert_true(f.prime())
			helpers.assert_not_nil(f.Utils.capture_text_destination())
			f.secure, f.now = true, 106
			local before_refresh = f.calls.ax
			f.fire(5)
			helpers.assert_true(f.calls.ax > before_refresh, "the actual TTL callback must refresh off the input path")
			local after_refresh = f.snapshot()
			helpers.assert_nil(f.Utils.capture_text_destination())
			helpers.assert_eq(f.calls, after_refresh)
		end)
	end)

	helpers.it("does not republish a retained receipt after tracking stops", function()
		with_destination(function(f)
			helpers.assert_true(f.prime())
			helpers.assert_not_nil(f.Utils.capture_text_destination())
			helpers.assert_true(f.Utils.stop())
			local before = f.snapshot()
			helpers.assert_nil(f.Utils.capture_text_destination())
			helpers.assert_eq(f.calls, before)
		end)
	end)
end)
