--- tests/unit/ui/ui_builder/lifecycle/test_webview_close_recursion.lua

--- ==============================================================================
--- MODULE: WebView Native Close Recursion
--- DESCRIPTION:
--- Exercises the real factory against the pinned close/GC/re-wrapping cycle.
--- Automatic user-close retirement must not enable the native recursive flag.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

local function with_windows(scenario)
	helpers.with_stub_scope({ "ui.ui_builder", "ui.webview_close_owner", "infra.deferred_work", "infra.logger",
		"adapters.json_codec", "adapters.timer_scheduler", "infra.locale", "json", "locale.core",
		"webview.i18n_seed", "webview.presentation", "window_titles",
		"tests.support.webview_recursive_close_fixture" }, function()
		local h = { windows = {}, retained = {}, deferred = {}, errors = {}, notification_depth = 0, closed = 0 }
		local constructor = require("tests.support.webview_recursive_close_fixture")(h)
		local logger = helpers.make_logger_stub()
		logger.error = function(...) if h.on_error then h.on_error(...) end end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			if h.schedule_refuses == "throw" then error("deferred owner allocation raised") end
			if h.schedule_refuses then return false end
			if h.schedule_inline then callback(); return true end
			h.deferred[#h.deferred + 1] = callback
			if h.schedule_mutating == "throw" then error("deferred owner raised after accepting callback") end
			if h.schedule_mutating == "false" then return false end
			return true
		end }
		h.builder = helpers.load_with_stubs("ui.ui_builder", {
			webview = { new = constructor, windowMasks = { titled = 1, closable = 2 } },
		})
		function h.show(callback)
			return h.builder.show_webview({ title = "Recursion", focus = false, inject_i18n = false,
				html_string = "<html></html>", delete_on_close = true,
				on_webview_created = h.on_created,
				on_close = callback or function() h.closed = h.closed + 1 end })
		end
		function h.drain()
			local turns = 0
			while #h.deferred > 0 do
				turns = turns + 1
				assert(turns < 50, "cleanup must not spin")
				table.remove(h.deferred, 1)()
			end
		end
		scenario(h)
	end)
end

helpers.describe("factory-owned close avoids recursive native GC", function()
	for _, action in ipairs({ "user", "explicit" }) do
		helpers.it("retires " .. action .. " close without re-wrapping GC", function()
			with_windows(function(h)
				local view = h.show()
				helpers.assert_not_nil(view)
				local state = view.native
				if action == "user" then view:user_close() else view:delete() end
				helpers.assert_eq(#h.errors, 0, "native GC must not recurse through new userdata")
				if action == "user" then
					helpers.assert_eq(h.closed, 1, "business close notification remains synchronous")
					helpers.assert_true(h.retained[state], "native retirement waits outside windowWillClose")
				end
				h.drain()
				helpers.assert_eq(#h.errors, 0, "native GC must not recurse through new userdata")
				helpers.assert_nil(getmetatable(view), "exact userdata must actually be consumed")
				helpers.assert_nil(h.retained[state])
				helpers.assert_eq(h.closed, 1)
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("retains the accepted callback after deferred admission mutates then " .. refusal, function()
			with_windows(function(h)
				local reentrant
				local view = h.show(function() h.closed = h.closed + 1; reentrant = h.show() end)
				h.schedule_mutating = refusal
				view:user_close()
				helpers.assert_nil(reentrant)
				helpers.assert_true(h.retained[view.native])
				h.schedule_mutating = nil
				h.drain()
				helpers.assert_nil(getmetatable(view))
				helpers.assert_eq(view.native.deletes, 1)
				helpers.assert_eq(h.closed, 1)
			end)
		end)
	end

	helpers.it("acknowledges the safe policy before handing a candidate to external code", function()
		with_windows(function(h)
			local observed
			h.on_created = function(view)
				observed = { view:deleteOnClose(), view.native.policy_calls }
				view:delete()
				return true
			end
			helpers.assert_nil(h.show(), "a hook-consumed candidate cannot become a published window")
			helpers.assert_eq(observed, { false, 1 })
			helpers.assert_nil(next(h.retained))
			helpers.assert_eq(h.closed, 0)
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	helpers.it("keeps a successor opened by the synchronous close observer", function()
		with_windows(function(h)
			local successor
			local view = h.show(function()
				h.closed = h.closed + 1
				successor = h.show()
			end)
			local state = view.native
			view:user_close()
			helpers.assert_not_nil(successor)
			helpers.assert_true(h.retained[state], "cleanup must remain outside the notification")
			h.drain()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_not_nil(getmetatable(successor))
			helpers.assert_true(h.retained[successor.native])
			helpers.assert_eq(h.closed, 1)
			successor:delete(); h.drain()
		end)
	end)

	helpers.it("tolerates an observer deleting its exact predecessor before reopening", function()
		with_windows(function(h)
			local view, successor
			view = h.show(function()
				h.closed = h.closed + 1
				view:delete()
				successor = h.show()
			end)
			view:user_close()
			h.drain()
			helpers.assert_eq(h.closed, 1)
			helpers.assert_eq(#h.errors, 0)
			helpers.assert_not_nil(getmetatable(successor))
			successor:delete(); h.drain()
		end)
	end)

	helpers.it("retires the exact window even if the business observer raises", function()
		with_windows(function(h)
			local view = h.show(function() h.closed = h.closed + 1; error("business observer raised") end)
			view:user_close(); h.drain()
			helpers.assert_nil(getmetatable(view))
			helpers.assert_eq(h.closed, 1)
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	for _, refusal in ipairs({ "false", "throw", "inline" }) do
		helpers.it("retains cleanup after deferred admission " .. refusal, function()
			with_windows(function(h)
				local reentrant
				local view = h.show(function() h.closed = h.closed + 1; reentrant = h.show() end)
				if refusal == "inline" then h.schedule_inline = true else h.schedule_refuses = refusal end
				view:user_close()
				helpers.assert_nil(reentrant, "unqualified debt cannot be deleted inside the notification")
				helpers.assert_true(h.retained[view.native])
				helpers.assert_eq(h.closed, 1)
				h.schedule_inline, h.schedule_refuses = nil, nil
				local successor = h.show()
				helpers.assert_not_nil(successor, "the next factory admission retries the exact old debt")
				helpers.assert_nil(getmetatable(view))
				successor:delete(); h.drain()
			end)
		end)
	end

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("retains cleanup after native delete " .. refusal, function()
			with_windows(function(h)
				local view = h.show()
				view:user_close()
				h.delete_refuses = refusal
				h.drain()
				helpers.assert_true(h.retained[view.native])
				helpers.assert_nil(h.show())
				helpers.assert_eq(h.closed, 1)
				h.delete_refuses = nil
				local successor = h.show()
				helpers.assert_not_nil(successor)
				helpers.assert_nil(getmetatable(view))
				successor:delete(); h.drain()
			end)
		end)
	end

	helpers.it("accepts exact native consumption even when delete subsequently raises", function()
		with_windows(function(h)
			local view = h.show()
			view:user_close()
			h.delete_after_consumption = true
			h.drain()
			helpers.assert_nil(getmetatable(view))
			h.delete_after_consumption = nil
			local successor = h.show()
			helpers.assert_not_nil(successor)
			successor:delete(); h.drain()
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses required close policy " .. refusal .. " without recursive rollback", function()
			with_windows(function(h)
				h.policy_refuses = refusal
				helpers.assert_nil(h.show())
				h.drain()
				helpers.assert_nil(next(h.retained))
				helpers.assert_eq(h.closed, 0)
				helpers.assert_eq(#h.errors, 0)
			end)
		end)
	end

	helpers.it("keeps the deletion fence during a reentrant cleanup diagnostic", function()
		with_windows(function(h)
			local view = h.show()
			view:user_close()
			h.delete_refuses = "false"
			local observed = 0
			local admitted = {}
			h.on_error = function()
				observed = observed + 1
				admitted[#admitted + 1] = h.show() ~= nil
			end
			h.drain()
			helpers.assert_eq(observed, 1)
			helpers.assert_eq(admitted, { false }, "a diagnostic cannot bypass the active deletion fence")
			helpers.assert_eq(#h.windows, 1)
			helpers.assert_eq(view.native.deletes, 1)
			h.delete_refuses, h.on_error = nil, nil
			h.builder.show_webview({ title = "Successor", focus = false })
			helpers.assert_nil(getmetatable(view))
		end)
	end)

	helpers.it("keeps notification depth through a throwing observer's diagnostic", function()
		with_windows(function(h)
			local view = h.show(function() error("business observer failed") end)
			h.schedule_refuses = "false"
			local observations = 0
			local admitted, deletes = {}, {}
			h.on_error = function()
				observations = observations + 1
				admitted[#admitted + 1] = h.show() ~= nil
				deletes[#deletes + 1] = view.native.deletes
			end
			view:user_close()
			helpers.assert_eq(observations, 2)
			helpers.assert_eq(admitted, { false, false })
			helpers.assert_eq(deletes, { 0, 0 }, "the Cocoa notification remains on the stack during diagnostics")
			h.on_error, h.schedule_refuses = nil, nil
			h.builder.show_webview({ title = "Successor", focus = false })
			helpers.assert_nil(getmetatable(view))
		end)
	end)

	helpers.it("retains a factory rollback whose native delete returns false", function()
		with_windows(function(h)
			h.policy_refuses, h.delete_refuses = "false", "false"
			helpers.assert_nil(h.show())
			local first = h.windows[1]
			helpers.assert_true(h.retained[first.native])
			helpers.assert_nil(h.show())
			helpers.assert_eq(#h.windows, 1, "native false cannot authorize a successor allocation")
			h.policy_refuses, h.delete_refuses = nil, nil
			local successor = h.show()
			helpers.assert_not_nil(successor)
			helpers.assert_nil(getmetatable(first))
			successor:delete(); h.drain()
		end)
	end)

	helpers.it("accepts factory rollback consumption before a subsequent native exception", function()
		with_windows(function(h)
			h.policy_refuses, h.delete_after_consumption = "false", true
			helpers.assert_nil(h.show())
			local first = h.windows[1]
			helpers.assert_nil(getmetatable(first))
			h.policy_refuses, h.delete_after_consumption = nil, nil
			local successor = h.show()
			helpers.assert_not_nil(successor, "consumed rollback must not retain an invalid retry candidate")
			successor:delete(); h.drain()
			helpers.assert_eq(first.native.deletes, 1)
		end)
	end)

	helpers.it("reports a committed cleanup timer delivered inside another close notification", function()
		with_windows(function(h)
			local first = h.show()
			first:user_close()
			helpers.assert_eq(#h.deferred, 1)
			local observed, admitted, deletes = 0, {}, {}
			h.on_error = function(_, message)
				if message:find("cleanup callback delivered inside a native close notification", 1, true) then
					observed = observed + 1
					admitted[#admitted + 1] = h.show() ~= nil
					deletes[#deletes + 1] = first.native.deletes
				end
			end
			local second = h.show(function()
				h.closed = h.closed + 1
				-- A's after() already returned committed before B was opened.
				table.remove(h.deferred, 1)()
			end)
			second:user_close()
			helpers.assert_eq(observed, 1, "lost cleanup authority must remain diagnostically visible")
			helpers.assert_eq(admitted, { false }, "diagnostic reentry stays inside the notification fence")
			helpers.assert_eq(deletes, { 0 })
			helpers.assert_true(h.retained[first.native])
			helpers.assert_eq(#h.deferred, 1, "only B's separate committed continuation remains")
			h.drain()
			helpers.assert_true(h.retained[first.native], "no timer loop may invent another cleanup authority")
			helpers.assert_nil(getmetatable(second))
			local successor = h.show()
			helpers.assert_not_nil(successor)
			helpers.assert_nil(getmetatable(first), "the next factory admission retries A's exact debt")
			helpers.assert_eq(first.native.deletes, 1)
			successor:delete(); h.drain()
		end)
	end)
end)
