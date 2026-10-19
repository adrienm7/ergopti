--- tests/unit/ui/editors/lifecycle/test_physical_shortcuts_consumption_observer.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Consumption Observer
--- DESCRIPTION:
--- Exercises native-shaped close notifications while the first notification
--- still sees a visible window and the later fade consumes it without another
--- notification. These cases qualify Lua ownership, not actual Cocoa delivery.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_host = require("tests.support.physical_shortcuts_fade_fixture")

local function with_closed_window(scenario)
	with_host(function(host, h)
		h.first_close_visible, h.close_notifies_once = true, true
		scenario(host, h)
	end)
end

local function assert_retired(view, h)
	helpers.assert_nil(getmetatable(view))
	helpers.assert_eq(view.native.deletes, 1)
	helpers.assert_eq(#h.errors, 0)
	helpers.assert_nil(next(h.script_refs))
	helpers.assert_nil(next(h.retained))
	for _, entry in ipairs(h.timers) do helpers.assert_eq(entry.running, false) end
end

helpers.describe("physical shortcut consumption does not depend on notification count", function()
	helpers.it("retains the healthy renotified native fade control", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("releases the bridge after one visible user notification and no second notification", function()
		with_closed_window(function(_, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			helpers.assert_not_nil(getmetatable(view))
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("observes the public request even when no closing callback is delivered", function()
		with_closed_window(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view.native.notified = true -- The native fade closes a window whose notification already ran.
			helpers.assert_eq(host.close(), false)
			helpers.assert_true(h.tick())
			helpers.assert_not_nil(getmetatable(view))
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("keeps observing when public timers run before native fade consumption", function()
		with_closed_window(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			for _ = 1, 3 do helpers.assert_true(h.tick()) end
			helpers.assert_not_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(h.timers[1].delay, 0)
			helpers.assert_true(h.timers[2].delay > 0, "reobservation must not spin at zero delay")
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("waits for exact observer stop after the native window is consumed", function()
		with_closed_window(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			h.timer_stop_refuses = true
			helpers.assert_true(h.tick())
			table.remove(h.deferred, 1)()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(h.open(), false)
			h.timer_stop_refuses = false
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("does not rearm a delivered early observer before its exact stop acknowledgement", function()
		with_closed_window(function(_, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			h.timer_stop_refuses = true
			helpers.assert_true(h.tick())
			helpers.assert_true(h.tick())
			helpers.assert_eq(h.timer_attempts, 1)
			helpers.assert_not_nil(getmetatable(view))
			h.timer_stop_refuses = false
			helpers.assert_true(h.tick())
			helpers.assert_eq(h.timer_attempts, 2)
			h.drain()
			assert_retired(view, h)
		end)
	end)

	helpers.it("fences reentrant admission during a reobservation refusal diagnostic", function()
		with_closed_window(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			local admitted = {}
			h.timer_construct_refuses = true
			h.on_error = function() admitted[#admitted + 1] = h.open() end
			helpers.assert_true(h.tick())
			helpers.assert_true(#admitted > 0)
			for _, result in ipairs(admitted) do helpers.assert_eq(result, false) end
			helpers.assert_eq(#h.windows, 1)
			h.timer_construct_refuses, h.on_error = nil, nil
			h.drain()
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_true(host.close())
			assert_retired(view, h)
		end)
	end)

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("preserves bridge debt when reobservation allocation refuses " .. mode, function()
			with_closed_window(function(host, h)
				helpers.assert_true(h.open())
				local view = h.windows[1]
				view:user_close()
				h.timer_construct_refuses = mode
				helpers.assert_true(h.tick())
				h.drain()
				helpers.assert_nil(getmetatable(view))
				helpers.assert_not_nil(h.script_refs[h.bridges[1]])
				helpers.assert_eq(h.timer_attempts, 2)
				helpers.assert_true(#h.logs > 0)
				h.timer_construct_refuses = nil
				helpers.assert_true(host.close())
				assert_retired(view, h)
			end)
		end)
	end

	helpers.it("keeps stale observer and closing callbacks from retiring the next owner", function()
		with_closed_window(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			local native_close = view.native.callback
			view:user_close()
			local observer = h.retirement_callbacks[1]
			h.drain()
			assert_retired(view, h)
			helpers.assert_true(h.open())
			local successor = h.windows[2]
			local retired = h.retired
			native_close("closing"); observer()
			helpers.assert_eq(h.retired, retired)
			helpers.assert_not_nil(h.script_refs[h.bridges[2]])
			helpers.assert_eq(successor.native.deletes, 0)
			helpers.assert_eq(host.close(), false)
			h.drain()
			assert_retired(successor, h)
		end)
	end)
end)
