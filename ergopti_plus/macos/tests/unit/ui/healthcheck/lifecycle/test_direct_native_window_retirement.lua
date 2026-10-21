--- tests/unit/ui/healthcheck/lifecycle/test_direct_native_window_retirement.lua

--- ==============================================================================
--- MODULE: Direct Diagnostics Window Native Retirement
--- DESCRIPTION:
--- A native close notification must preserve exact deferred cleanup ownership
--- after the direct controller retires its logical session. Independent native
--- roots distinguish disappearance from actual userdata consumption.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.ui.direct_native_window_fixture")

helpers.describe("direct diagnostics windows retire their native roots", function()
	helpers.it("healthcheck retires exact ownership before a reentrant close diagnostic", function()
		with_window("healthcheck", function(h)
			helpers.assert_true(h.open())
			local admitted
			h.on_debug = function()
				h.on_debug = nil
				admitted = h.open()
			end
			h.windows[1]:user_close()
			helpers.assert_true(admitted)
			local successor = h.windows[2]
			h.drain()
			helpers.assert_true(h.open())
			h.drain()
			helpers.assert_nil(h.retained[successor.native], "old callback must not erase the successor's business owner")
		end)
	end)

	for _, domain in ipairs({ "healthcheck", "error" }) do
		helpers.it(domain .. " releases a user-closed native window before the next admission", function()
			with_window(domain, function(h)
				helpers.assert_true(h.open())
				local old = h.windows[1]
				old:user_close()
				h.drain()
				helpers.assert_nil(h.retained[old.native], "dropping the business owner cannot remove the native udRef")
				helpers.assert_nil(getmetatable(old))
				helpers.assert_true(h.open())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor.native])
				h.close(); h.drain()
			end)
		end)
		helpers.it(domain .. " keeps a successor outside an older native close continuation", function()
			with_window(domain, function(h)
				helpers.assert_true(h.open())
				local old = h.windows[1]
				old:user_close()
				helpers.assert_true(h.open())
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[old.native])
				helpers.assert_true(h.retained[successor.native])
				helpers.assert_not_nil(getmetatable(successor))
				h.close(); h.drain()
			end)
		end)
		helpers.it(domain .. " preserves explicit close and exact native fade completion", function()
			with_window(domain, function(h)
				helpers.assert_true(h.open())
				local old = h.windows[1]
				h.close(); h.drain()
				helpers.assert_nil(h.retained[old.native])
				helpers.assert_nil(getmetatable(old))
				helpers.assert_nil(next(h.retained), "normal explicit close needs no later public action")
				helpers.assert_nil(next(h.script_refs), "normal explicit close releases the exact bridge after drain alone")
			end)
		end)
		helpers.it(domain .. " retains a refused deferred close until exact cleanup can succeed", function()
			with_window(domain, function(h)
				helpers.assert_true(h.open())
				local old = h.windows[1]
				h.timer_new_refusal, h.delete_refuses = true, "false"
				old:user_close()
				helpers.assert_true(h.retained[old.native])
				helpers.assert_eq(h.open(), false)
				helpers.assert_eq(#h.windows, 1, "native cleanup refusal must block successor allocation")
				h.timer_new_refusal, h.delete_refuses = nil, nil
				helpers.assert_true(h.open())
				helpers.assert_nil(h.retained[old.native])
				h.close(); h.drain()
			end)
		end)
		helpers.it(domain .. " retains a fade accepted before a wrapper raises", function()
			with_window(domain, function(h)
				helpers.assert_true(h.open())
				local old = h.windows[1]
				h.delete_after_consumption = true
				h.close(); h.close()
				helpers.assert_eq(old.native.deletes, 1)
				helpers.assert_eq(#h.deferred, 1, "one exact native fade remains responsible for consumption")
				h.drain()
				helpers.assert_nil(h.retained[old.native])
				helpers.assert_nil(getmetatable(old))
				h.delete_after_consumption = nil
				helpers.assert_true(h.open())
				h.close(); h.drain()
			end)
		end)
		for _, refusal in ipairs({ "false", "throw" }) do
			helpers.it(domain .. " rolls back a refused native closing callback: " .. refusal, function()
				with_window(domain, function(h)
					h.bind_refusal = refusal
					helpers.assert_eq(h.open(), false)
					helpers.assert_eq(h.html_calls or 0, 0)
					helpers.assert_nil(next(h.retained))
				end)
			end)
			helpers.it(domain .. " retains an exact refused explicit delete: " .. refusal, function()
				with_window(domain, function(h)
					helpers.assert_true(h.open())
					local old = h.windows[1]
					h.delete_refuses = refusal
					h.close()
					helpers.assert_true(h.retained[old.native])
					h.delete_refuses = nil
					h.close()
					helpers.assert_eq(old.native.deletes, 1, "uncertain public delete is never replayed")
					helpers.assert_true(h.retained[old.native])
					helpers.assert_not_nil(getmetatable(old))
					h.open()
					helpers.assert_eq(#h.windows, 1, "an uncertain live request must not lose its business owner to a successor")
				end)
			end)
		end
		for _, refusal in ipairs({ "false", "nil", "throw", "unapplied" }) do
			helpers.it(domain .. " refuses the native child policy before page publication: " .. refusal, function()
				with_window(domain, function(h)
					h.child_refusal = refusal
					helpers.assert_eq(h.open(), false)
					helpers.assert_eq(h.html_calls or 0, 0)
					helpers.assert_nil(next(h.retained), "failed construction must settle its exact unexposed native candidate")
				end)
			end)
		end
	end
end)
