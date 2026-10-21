--- tests/unit/ui/ui_builder/lifecycle/test_webview_child_policy.lua

--- ==============================================================================
--- MODULE: Native Child WebView Ownership
--- DESCRIPTION:
--- Drives the real factory over the packaged WebKit delegate's child policy:
--- native children copy the parent's callback and enable recursive automatic GC.
--- Factory-owned windows must not create an unowned child or retire its parent.
--- ==============================================================================

local helpers = require("tests.helpers")
require("logger")

--- Composes pinned native child creation with the real factory lifecycle.
--- @param scenario function Scenario over independent native observations.
local function with_windows(scenario)
	helpers.with_stub_scope({ "ui.ui_builder", "ui.webview_close_owner", "infra.deferred_work", "infra.logger",
		"adapters.json_codec", "adapters.timer_scheduler", "infra.locale", "json", "locale.core",
		"webview.i18n_seed", "webview.presentation", "window_titles", "tests.support.webview_recursive_close_fixture",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, errors = {}, notification_depth = 0, closed = 0 }
		local native_new = require("tests.support.webview_recursive_close_fixture")(h)
		local function constructor()
			local parent = native_new()
			parent.native.allow_new_windows = true -- libwebview.m:287, independent of factory defaults.
			function parent:allowNewWindows(value)
				if value == nil then
					if h.getter_refuses == "throw" then error("native child-policy getter raised") end
					if h.getter_refuses == "nil" then return nil end
					if h.getter_refuses == "true" then return true end
					return self.native.allow_new_windows
				end
				self.native.child_policy_calls = (self.native.child_policy_calls or 0) + 1
				if h.setter_refuses == "throw" then error("native child-policy setter raised") end
				if h.setter_refuses == "false" then return false end
				if h.setter_refuses == "nil" then return nil end
				if h.setter_refuses == "foreign" then return {} end
				self.native.allow_new_windows = value
				if h.setter_mutates_then_throws then error("native child-policy setter raised after mutation") end
				return self
			end
			function parent:html()
				h.html_policy = self.native.allow_new_windows
				h.html_calls = (h.html_calls or 0) + 1
				return self
			end
			function parent:request_child()
				if not self.native.allow_new_windows then return nil end
				local child = constructor()
				child.native.delete_on_close = true -- createWebViewWithConfiguration:589.
				child.native.callback = self.native.callback -- The same Lua callback is copied:594–597.
				child.native.visible = true
				return child
			end
			return parent
		end
		h.native_new = constructor
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.deferred_work"] = { after = function(_, callback)
			h.deferred[#h.deferred + 1] = callback
			return true
		end }
		h.builder = helpers.load_with_stubs("ui.ui_builder", {
			webview = { new = constructor, windowMasks = { titled = 1, closable = 2 } },
		})
		function h.show(policy)
			return h.builder.show_webview({ title = "Parent", focus = false, inject_i18n = false,
				html_string = "<html></html>", delete_on_close = true, allow_new_windows = policy,
				on_webview_created = h.on_created,
				on_close = function() h.closed = h.closed + 1 end })
		end
		function h.drain()
			for _ = 1, 40 do
				if #h.deferred == 0 then return end
				local count = #h.deferred
				for _ = 1, count do table.remove(h.deferred, 1)() end
			end
			error("native child cleanup must not spin")
		end
		scenario(h)
	end)
end

helpers.describe("factory child windows preserve their parent's lifecycle", function()
	helpers.it("models native child callback copying and recursive GC independently", function()
		with_windows(function(h)
			local parent = h.native_new()
			local source
			parent:windowCallback(function(_, view) source = view end)
			local child = parent:request_child()
			helpers.assert_not_nil(child)
			helpers.assert_eq(child.native.callback, parent.native.callback)
			child:user_close()
			helpers.assert_eq(source, child, "the copied callback receives the child's native window")
			helpers.assert_eq(h.errors, { "C stack overflow" })
			helpers.assert_not_nil(getmetatable(parent))
			parent:delete()
		end)
	end)

	helpers.it("does not retire a factory parent when a native child close is requested", function()
		with_windows(function(h)
			local parent = h.show()
			helpers.assert_not_nil(parent)
			local child = parent:request_child()
			if child then child:user_close(); h.drain() end
			helpers.assert_eq(h.closed, 0, "a child's copied callback cannot close the parent owner")
			helpers.assert_not_nil(getmetatable(parent))
			helpers.assert_true(h.retained[parent.native])
			helpers.assert_nil(child, "native child creation requires its own explicit lifecycle owner")
			parent:delete(); h.drain()
		end)
	end)

	helpers.it("does not re-enable recursive GC through a default native child", function()
		with_windows(function(h)
			local parent = h.show()
			local child = parent:request_child()
			if child then child:user_close(); h.drain() end
			helpers.assert_eq(#h.errors, 0, "the child must not inherit the packaged unsafe GC flag")
			helpers.assert_nil(child)
			parent:delete(); h.drain()
		end)
	end)

	helpers.it("preserves an explicitly closed child policy and ordinary parent deletion", function()
		with_windows(function(h)
			local parent = h.show(false)
			helpers.assert_not_nil(parent)
			helpers.assert_eq(parent:allowNewWindows(), false)
			helpers.assert_nil(parent:request_child())
			helpers.assert_eq(h.closed, 0)
			parent:delete(); h.drain()
			helpers.assert_nil(getmetatable(parent))
			helpers.assert_eq(h.closed, 1)
			helpers.assert_eq(#h.errors, 0)
		end)
	end)

	for _, candidate in ipairs({ { label = "true", value = true }, { label = "a string", value = "false" },
		{ label = "zero", value = 0 }, { label = "a positive number", value = 1 },
		{ label = "a table", value = {} }, { label = "a function", value = function() end },
	}) do
		helpers.it("refuses unowned native child admission with " .. candidate.label, function()
			with_windows(function(h)
				helpers.assert_nil(h.show(candidate.value))
				helpers.assert_eq(#h.windows, 0, "unsupported policy refuses before native allocation")
				helpers.assert_eq(h.closed, 0)
			end)
		end)
	end

	helpers.it("commits the closed policy before exposing the owner or loading HTML", function()
		with_windows(function(h)
			local observed
			h.on_created = function(view)
				observed = { policy = view:allowNewWindows(), calls = view.native.child_policy_calls,
					child = view:request_child() }
				return true
			end
			local parent = h.show()
			helpers.assert_not_nil(parent)
			helpers.assert_eq(observed, { policy = false, calls = 1 })
			helpers.assert_eq(h.html_calls, 1)
			helpers.assert_eq(h.html_policy, false)
			parent:delete(); h.drain()
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "foreign", "throw" }) do
		helpers.it("rolls back an unacknowledged child-policy setter " .. refusal, function()
			with_windows(function(h)
				local hooks = 0
				h.on_created = function() hooks = hooks + 1; return true end
				h.setter_refuses = refusal
				helpers.assert_nil(h.show())
				helpers.assert_eq(hooks, 0)
				helpers.assert_eq(h.html_calls, nil)
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(getmetatable(h.windows[1]))
				helpers.assert_eq(h.closed, 0)
			end)
		end)
	end

	for _, refusal in ipairs({ "nil", "true", "throw" }) do
		helpers.it("rolls back an unreadable child-policy getter " .. refusal, function()
			with_windows(function(h)
				h.getter_refuses = refusal
				helpers.assert_nil(h.show())
				helpers.assert_nil(next(h.retained))
				helpers.assert_nil(getmetatable(h.windows[1]))
				helpers.assert_eq(h.html_calls, nil)
			end)
		end)
	end

	helpers.it("settles a child-policy setter that mutates before raising", function()
		with_windows(function(h)
			h.setter_mutates_then_throws = true
			helpers.assert_nil(h.show())
			helpers.assert_nil(next(h.retained))
			helpers.assert_eq(h.windows[1].native.allow_new_windows, false)
			helpers.assert_eq(h.closed, 0)
		end)
	end)

	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("retains the exact rollback when native delete " .. refusal .. " refuses", function()
			with_windows(function(h)
				h.setter_refuses, h.delete_refuses = "false", refusal
				helpers.assert_nil(h.show())
				local old = h.windows[1]
				helpers.assert_true(h.retained[old.native])
				helpers.assert_nil(h.show())
				helpers.assert_eq(#h.windows, 1)
				h.setter_refuses, h.delete_refuses = nil, nil
				local successor = h.show()
				helpers.assert_not_nil(successor)
				helpers.assert_nil(getmetatable(old))
				helpers.assert_nil(successor:request_child())
				helpers.assert_eq(h.closed, 0)
				successor:delete(); h.drain()
			end)
		end)
	end
end)
