--- tests/unit/ui/dialogs/lifecycle/test_update_check_native_window.lua

--- ==============================================================================
--- MODULE: Update Check Native Window Custody
--- DESCRIPTION:
--- Exercises the actual host and factory across user close, deferred deletion
--- and rejected construction. A failed native mutation cannot abandon its
--- candidate or let a cleanup-only window become a newly active page.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.ui.owned_window_close_fixture")

--- Adds the pinned binding's userdata-metatable retirement to the shared model.
--- @param scenario function Complete host scenario.
local function run_host(scenario)
	with_window("ui.update_check", function(host, h)
		local construct = hs.webview.new
		h.delete_attempts = 0
		hs.webview.new = function(...)
			local view = construct(...)
			setmetatable(view, { __name = "hs.webview" })
			local native_delete, native_close, native_html = view.delete, view.user_close, view.html
			function view:html(...)
				if h.html_refuses then error("native HTML admission refused") end
				return native_html(self, ...)
			end
			function view:user_close()
				native_close(self)
				if self.disposed then setmetatable(self, nil) end
			end
			function view:delete()
				h.delete_attempts = h.delete_attempts + 1
				if h.on_delete then h.on_delete() end
				if h.delete_refuses == "false" then return false end
				if h.delete_refuses then error("native candidate delete refused") end
				local result = native_delete(self)
				if self.disposed then setmetatable(self, nil) end
				if self.disposed and h.throw_after_gc then error("wrapper raised after native userdata retirement") end
				return result
			end
			return view
		end
		scenario(host, h)
	end)
end

--- Restores the shared update-check interpreters loaded only by this host.
--- @param scenario function Complete native scenario.
local function with_host(scenario)
	return helpers.with_fresh_modules({ "updater.release_parser", "updater.check_result" }, function()
		return run_host(scenario)
	end)
end

helpers.describe("update check native window custody", function()
	helpers.it("releases native user close and keeps still-open reuse working", function()
		with_host(function(_, h)
			helpers.assert_true(h.show())
			helpers.assert_true(h.show())
			helpers.assert_eq(#h.windows, 1)
			h.windows[1]:user_close()
			h.drain()
			helpers.assert_nil(h.retained[h.windows[1]])
			helpers.assert_true(h.show())
			helpers.assert_true(h.retained[h.windows[2]])
			h.windows[2]:user_close()
			h.drain()
		end)
	end)

	helpers.it("keeps explicit native fade completion separate from its successor", function()
		with_host(function(_, h)
			helpers.assert_true(h.show())
			local first = h.windows[1]
			helpers.assert_true(h.close())
			helpers.assert_eq(#h.deferred, 1)
			helpers.assert_true(h.show())
			local successor = h.windows[2]
			h.drain()
			helpers.assert_nil(h.retained[first])
			helpers.assert_true(h.retained[successor])
			helpers.assert_true(h.show())
			helpers.assert_eq(#h.windows, 2)
			helpers.assert_true(h.close())
			h.drain()
		end)
	end)

	helpers.it("retires the exact factory candidate after required HTML admission throws", function()
		with_host(function(_, h)
			h.html_refuses = true
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_nil(next(h.retained), "refused unpublished candidate must be deleted")
			helpers.assert_eq(h.delete_attempts, 1)
		end)
	end)

	for _, mode in ipairs({ "throw", "false" }) do
		helpers.it("retains candidate deletion " .. mode .. " and blocks a successor until retry settles", function()
			with_host(function(_, h)
				h.html_refuses, h.delete_refuses = true, mode
				helpers.assert_eq(h.show(), false)
				local first = h.windows[1]
				helpers.assert_true(h.retained[first])
				h.html_refuses = false
				helpers.assert_eq(h.show(), false, "cleanup-only ownership must not reactivate as a new page")
				helpers.assert_eq(#h.windows, 1)
				h.delete_refuses = false
				helpers.assert_true(h.show())
				helpers.assert_nil(h.retained[first])
				helpers.assert_true(h.retained[h.windows[2]])
				h.windows[2]:user_close()
				h.drain()
			end)
		end)
	end

	helpers.it("does not delete a consumed candidate again when its wrapper subsequently throws", function()
		with_host(function(_, h)
			h.html_refuses, h.throw_after_gc = true, true
			helpers.assert_eq(h.show(), false)
			helpers.assert_nil(next(h.retained))
			helpers.assert_nil(getmetatable(h.windows[1]), "binding GC invalidates the userdata before returning")
			h.html_refuses, h.throw_after_gc = false, false
			helpers.assert_true(h.show())
			helpers.assert_eq(h.delete_attempts, 1, "retired native userdata must never receive another method call")
			h.windows[2]:user_close()
			h.drain()
		end)
	end)

	helpers.it("refuses reentrant open while the exact failed candidate is being deleted", function()
		with_host(function(_, h)
			h.html_refuses = true
			local entered = false
			h.on_delete = function()
				entered = true
				helpers.assert_eq(h.show(), false)
				helpers.assert_eq(#h.windows, 1)
			end
			helpers.assert_eq(h.show(), false)
			helpers.assert_true(entered)
			helpers.assert_nil(next(h.retained))
			h.on_delete, h.html_refuses = nil, false
			helpers.assert_true(h.show())
			h.windows[2]:user_close()
			h.drain()
		end)
	end)

	helpers.it("rejects an uncommitted automatic close policy and retires its candidate", function()
		with_host(function(_, h)
			h.policy_refuses = "throw"
			helpers.assert_eq(h.show(), false)
			helpers.assert_nil(next(h.retained))
		end)
	end)
end)
