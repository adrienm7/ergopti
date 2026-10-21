--- tests/unit/ui/editors/lifecycle/test_physical_shortcuts_fade_owner.lua

--- ==============================================================================
--- MODULE: Physical Shortcuts Native Fade Owner
--- DESCRIPTION:
--- Composes the real host and factory with the pinned public WebView close model.
--- Public delete always forwards a delay to the native method, so even zero-delay
--- visible deletion retains a fade completion that still needs the native udRef.
--- No Cocoa crash or native GUI execution is claimed by these portable cases.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

local with_host = require("tests.support.physical_shortcuts_fade_fixture")

helpers.describe("physical shortcut public fade retains its exact native owner", function()
	helpers.it("keeps the healthy user-close path at one native deletion", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			view:user_close()
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_nil(getmetatable(view))
			helpers.assert_nil(next(h.retained))
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_true(host.close())
		end)
	end)

	helpers.it("does not consume udRef from inside the explicit fade's closing notification", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			helpers.assert_true(h.retained[view.native])
			helpers.assert_eq(view.native.deletes, 1)
			h.drain()
			helpers.assert_eq(view.native.deletes, 1, "the fade remains the only native destruction owner")
			helpers.assert_eq(#h.errors, 0, "outer fade must retain its udRef through the callback")
			helpers.assert_nil(getmetatable(view))
			helpers.assert_nil(next(h.script_refs), "completed fade must release its bridge without another public operation")
			helpers.assert_true(host.close(), "consumed userdata is acknowledged without another delete")
			helpers.assert_nil(next(h.script_refs))
		end)
	end)

	helpers.it("blocks another delete and successor while an accepted fade remains live", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
			h.script_refs[h.bridges[1]]({ body = { action = "ready" } })
			helpers.assert_eq(h.received, 0)
			h.drain()
			helpers.assert_true(h.open())
			helpers.assert_eq(#h.windows, 2)
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_eq(host.close(), false)
			h.drain(); helpers.assert_true(host.close())
		end)
	end)

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("does not replay an ambiguous public deletion that returns " .. refusal, function()
			with_host(function(host, h)
				helpers.assert_true(h.open())
				local view = h.windows[1]
				h.delete_refuses = refusal
				helpers.assert_eq(host.close(), false)
				h.delete_refuses = nil
				helpers.assert_eq(host.close(), false)
				helpers.assert_eq(h.open(), false)
				helpers.assert_eq(view.native.deletes, 1, "refused outcome does not prove that no fade was scheduled")
				helpers.assert_eq(#h.windows, 1)
				helpers.assert_true(h.retained[view.native])
				helpers.assert_true(getmetatable(view) ~= nil)
			end)
		end)
	end

	helpers.it("keeps the fade when a wrapper raises after accepting its native callback", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			h.delete_after_consumption = true
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.deferred, 1)
			h.drain()
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_true(host.close())
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_nil(next(h.retained))
			helpers.assert_nil(next(h.script_refs))
		end)
	end)

	helpers.it("acknowledges consumed userdata after a user-close wrapper raises", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			h.delete_after_consumption = true
			view:user_close()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_true(host.close())
			helpers.assert_true(h.logs[1]:find("native delete raised after consumption", 1, true) ~= nil)
		end)
	end)

	helpers.it("keeps close and reopen fenced throughout a reentrant diagnostic", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local admitted, entered = {}, false
			h.delete_refuses = "false" -- A real refusal triggers the diagnostic; accepted fades are silent.
			h.on_error = function()
				if entered then return end
				entered = true
				admitted[#admitted + 1] = { close = host.close(), open = h.open() }
				error("deliberately broken diagnostic")
			end
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(admitted, { { close = false, open = false } })
			helpers.assert_eq(h.retired, 1, "diagnostic reentry cannot invoke business retirement again")
			helpers.assert_eq(h.windows[1].native.deletes, 1)
			helpers.assert_eq(#h.windows, 1)
			h.on_error = nil
			setmetatable(h.windows[1], nil) -- Independent native retirement acknowledges the ambiguous request.
			h.drain(); helpers.assert_true(host.close())
		end)
	end)

	helpers.it("does not let an old closing notification retire a healthy successor", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local old = h.windows[1].native.callback
			helpers.assert_eq(host.close(), false)
			h.drain(); helpers.assert_true(h.open())
			local successor = h.windows[2]
			old("closing")
			helpers.assert_true(h.retained[successor.native])
			helpers.assert_eq(successor.native.deletes, 0)
			h.script_refs[h.bridges[2]]({ body = { action = "ready" } })
			helpers.assert_eq(h.received, 1)
			helpers.assert_eq(host.close(), false)
			h.drain(); helpers.assert_true(host.close())
		end)
	end)

	helpers.it("retains an independent bridge refusal after the fade has consumed its window", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			h.detach_refuses = true; h.drain()
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			h.detach_refuses = false
			helpers.assert_true(host.close())
			helpers.assert_nil(next(h.script_refs))
		end)
	end)

	helpers.it("retries a known method-lookup failure before any native deletion attempt", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			local native = getmetatable(view).__index
			local refuse = true
			setmetatable(view, { __index = function(_, key)
				if key == "delete" and refuse then error("native method lookup refused before invocation") end
				return native[key]
			end })
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(view.native.deletes, 0)
			refuse = false
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(view.native.deletes, 1)
			h.drain(); helpers.assert_true(host.close())
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	helpers.it("keeps business retirement refusal distinct from a native fade owner", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local admitted, entered = {}, false
			h.retire_refuses = true
			h.on_error = function()
				if entered then return end
				entered = true
				admitted[#admitted + 1] = h.open()
			end
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(admitted, { false })
			helpers.assert_eq(h.retired, 1, "refused retirement stays fenced during its diagnostic")
			helpers.assert_eq(h.windows[1].native.deletes, 0)
			h.retire_refuses, h.on_error = false, nil
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(h.windows[1].native.deletes, 1)
			h.drain(); helpers.assert_true(host.close())
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	helpers.it("keeps the bridge until the deferred native timer actually acknowledges stop", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			table.remove(h.deferred, 1)()
			h.timer_stop_refuses = true
			helpers.assert_true(h.tick())
			helpers.assert_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(h.open(), false, "an unacknowledged timer still owns the original session")
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
			h.timer_stop_refuses = false
			h.drain()
			helpers.assert_nil(next(h.script_refs), "stop acknowledgement finishes without another public close")
			helpers.assert_true(h.open())
			helpers.assert_eq(host.close(), false)
			h.drain()
		end)
	end)

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("retains explicit bridge debt when continuation allocation refuses: " .. mode, function()
			with_host(function(host, h)
				helpers.assert_true(h.open())
				local view = h.windows[1]
				h.timer_construct_refuses = mode
				helpers.assert_eq(host.close(), false)
				h.drain()
				helpers.assert_nil(getmetatable(view))
				helpers.assert_not_nil(h.script_refs[h.bridges[1]], "refused scheduling is not a delivered continuation")
				helpers.assert_eq(h.timer_attempts, 1, "the real scheduling port must actually be attempted")
				local reported = false
				for _, line in ipairs(h.logs) do
					if line:find("deferred retirement refused", 1, true) then reported = true end
				end
				helpers.assert_true(reported, "scheduling refusal must remain visible")
				h.timer_construct_refuses = nil
				helpers.assert_true(h.open(), "a later admission first acknowledges and detaches the original debt")
				helpers.assert_nil(h.script_refs[h.bridges[1]])
				helpers.assert_eq(view.native.deletes, 1)
				helpers.assert_eq(host.close(), false)
				h.drain()
			end)
		end)
	end

	helpers.it("retains an activated but refused continuation timer until exact cleanup", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			h.timer_start_refuses, h.timer_stop_refuses = true, true
			helpers.assert_eq(host.close(), false)
			table.remove(h.deferred, 1)()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_eq(h.open(), false)
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(#h.windows, 1)
			h.timer_start_refuses, h.timer_stop_refuses = false, false
			h.drain()
			helpers.assert_not_nil(h.script_refs[h.bridges[1]], "failed activation cannot manufacture a delivered callback")
			helpers.assert_true(h.open())
			helpers.assert_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(host.close(), false)
			h.drain()
		end)
	end)

	helpers.it("does not finalize an injected synchronous delivery inside the native notification", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			h.timer_start_inline = true
			local admitted = {}
			h.on_error = function() admitted[#admitted + 1] = h.open() end
			helpers.assert_eq(host.close(), false)
			h.drain()
			helpers.assert_true(#admitted > 0)
			for _, accepted in ipairs(admitted) do helpers.assert_eq(accepted, false) end
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			h.timer_start_inline, h.on_error = false, nil
			helpers.assert_true(h.open())
			helpers.assert_eq(host.close(), false)
			h.drain()
		end)
	end)

	helpers.it("keeps a stale delivered timer from retiring its successor", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			helpers.assert_eq(host.close(), false)
			table.remove(h.deferred, 1)()
			helpers.assert_not_nil(h.timers[1], "native close must acquire a deferred retirement capability")
			local stale = h.timers[1].receive
			local stale_business = h.retirement_callbacks[1]
			helpers.assert_not_nil(stale_business)
			h.drain()
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_true(h.open())
			local successor = h.windows[2]
			local retired = h.retired
			stale(); stale_business()
			helpers.assert_eq(h.retired, retired, "a stale continuation cannot re-enter its old business owner")
			helpers.assert_true(h.retained[successor.native])
			helpers.assert_not_nil(h.script_refs[h.bridges[2]])
			helpers.assert_eq(successor.native.deletes, 0)
			helpers.assert_eq(host.close(), false)
			h.drain()
		end)
	end)

	helpers.it("does not mistake an earlier close notification for the pending fade's consumption", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			helpers.assert_eq(host.close(), false)
			view:user_close()
			helpers.assert_true(h.tick())
			helpers.assert_not_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]])
			helpers.assert_eq(view.native.deletes, 1)
			h.drain()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_nil(next(h.script_refs))
			helpers.assert_eq(view.native.deletes, 1)
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	helpers.it("keeps uncertainty explicit when a broken scheduler diagnostic hides its native handle", function()
		with_host(function(host, h)
			helpers.assert_true(h.open())
			local view = h.windows[1]
			h.timer_start_refuses, h.timer_stop_refuses = true, true
			h.on_error = function() error("deliberately broken scheduler diagnostic") end
			helpers.assert_eq(host.close(), false)
			table.remove(h.deferred, 1)()
			h.timer_start_refuses, h.timer_stop_refuses, h.on_error = false, false, nil
			h.drain()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_not_nil(h.script_refs[h.bridges[1]], "unexposed timer ownership cannot be silently certified")
			helpers.assert_eq(host.close(), false)
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
		end)
	end)
end)
