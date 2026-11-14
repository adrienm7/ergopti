--- tests/unit/ui/editors/lifecycle/test_layout_manager_controller_pool.lua

--- ==============================================================================
--- MODULE: Layout Manager Bounded Controller Retention
--- DESCRIPTION:
--- Exercises the actual host, manager bridge and pool against independently pinned
--- native references. Portable authority/refusal cases do not qualify WebKit.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.layout_manager_pool_fixture")

helpers.describe("layout manager bounds native controller ownership", function()
	for _, kind in ipairs({ "explicit", "user" }) do
		helpers.it("retains one pinned UCC across six " .. kind .. " closes", function()
			Fixture(function(host, h)
				for _ = 1, 6 do
					assert(host.open())
					if kind == "explicit" then h.close() else h.user_close() end
					assert(next(h.callback_refs) == nil)
				end
				assert(h.count(h.userdata_refs) == 1, "native udRef remains independently pinned")
				assert(#h.controllers == 1)
			end)
		end)
	end
	helpers.it("preserves ready, explicit refresh and singleton focus", function()
		Fixture(function(host, h)
			assert(host.open()); assert(host.open())
			assert(#h.views == 1 and #h.controllers == 1 and h.focuses == 1)
			local view, controller = h.current()
			h.post(controller, view, { action = "ready" })
			h.post(controller, view, { action = "ready" })
			h.post(controller, view, { action = "refresh" })
			assert(h.refreshes == 2 and #view.evaluations == 3)
			h.close(); assert(next(h.callback_refs) == nil)
		end)
	end)
	helpers.it("retires pending focus on close and reports presentation refusal", function()
		Fixture(function(host, h)
			assert(host.open()); assert(host.open())
			local current = h.focus_owner
			assert(current())
			h.focus_result = false
			assert(not host.open())
			h.close(); assert(not current())
			h.focus_result = nil
			assert(host.open()); assert(not current())
		end)
	end)
	helpers.it("rejects foreign native identities before reading their bodies", function()
		Fixture(function(host, h)
			assert(host.open())
			local view, controller = h.current()
			local callback = assert(h.callback_refs[controller])
			local poison = setmetatable({}, { __index = function() error("foreign body was read") end })
			callback({ name = "foreign", webView = view, body = poison })
			callback({ name = controller.name, webView = {}, body = poison })
			callback({ name = controller.name, body = poison })
			assert(h.refreshes == 0 and #h.errors == 0)
			h.post(controller, view, { action = "refresh" }); assert(h.refreshes == 1)
		end)
	end)
	helpers.it("rejects stale A delivery and close while the same controller serves B", function()
		Fixture(function(host, h)
			assert(host.open())
			local a, controller = h.current()
			local callback, old_close = h.callback_refs[controller], a.options.on_close
			h.close(); assert(host.open())
			local b, reused = h.current(); assert(reused == controller)
			callback({ name = controller.name, webView = a, body = { action = "close" } })
			h.post(controller, a, { action = "refresh", webView = b })
			old_close(); assert(not b.deleted and h.refreshes == 0)
			h.post(controller, b, { action = "refresh" }); assert(h.refreshes == 1)
		end)
	end)
	for _, refusal in ipairs({ "false", "nil", "true", "foreign", "throw" }) do
		helpers.it("retains exact cleanup debt after native detach " .. refusal, function()
			Fixture(function(host, h)
				assert(host.open())
				local a, controller = h.current()
				local callback = h.callback_refs[controller]
				if refusal == "throw" then h.detach_throws = true else h.detach_result = refusal end
				h.close(); assert(not host.open())
				assert(#h.views == 1 and a.delete_calls == 1)
				callback({ name = controller.name, webView = a, body = { action = "refresh" } })
				assert(h.refreshes == 0)
				h.detach_throws, h.detach_result = nil, nil
				assert(host.open()); assert(#h.controllers == 1)
				local b = h.current(); h.post(controller, b, { action = "refresh" })
				assert(h.refreshes == 1 and a.delete_calls == 1)
			end)
		end)
	end
	helpers.it("blocks reentrant admission and delivery during exact native detach", function()
		Fixture(function(host, h)
			assert(host.open())
			local a, controller = h.current()
			local callback = h.callback_refs[controller]
			h.on_detach = function()
				assert(not host.open())
				callback({ name = controller.name, webView = a, body = { action = "refresh" } })
			end
			h.close(); h.on_detach = nil
			assert(h.refreshes == 0 and host.open() and #h.controllers == 1)
		end)
	end)
	helpers.it("withholds business until exact factory attach and commit", function()
		Fixture(function(host, h)
			h.on_created = function(view)
				assert(not host.open())
				h.post(h.controllers[1], view, { action = "refresh" })
			end
			assert(host.open()); assert(h.refreshes == 0)
			local view, controller = h.current()
			h.post(controller, view, { action = "refresh" }); assert(h.refreshes == 1)
		end)
	end)
	helpers.it("retires a rejected factory candidate without losing or replacing its UCC", function()
		Fixture(function(host, h)
			h.reject_created = true
			assert(not host.open()); assert(h.views[1].deleted)
			assert(next(h.callback_refs) == nil)
			h.reject_created = nil
			assert(host.open()); assert(#h.controllers == 1)
		end)
	end)
	for _, refusal in ipairs({ "false", "throw" }) do
		helpers.it("preserves exact native delete debt on " .. refusal, function()
			Fixture(function(host, h)
				assert(host.open()); h.delete_refuses = refusal
				h.close(); assert(not host.open())
				assert(#h.views == 1 and #h.controllers == 1)
				h.delete_refuses = nil
				assert(host.open()); assert(#h.controllers == 1)
			end)
		end)
	end
	-- The native pool probe (tools/diagnostics/macos_layout_manager_pool_observer.lua)
	-- reads the open window's owners as upvalues of the public open function: a
	-- wrapper around the window factory hides them and turns the probe red.
	helpers.it("exposes the window owners the native pool probe reads (layout-manager-pool-upvalues)", function()
		Fixture(function(host)
			for _, wanted in ipairs({ "_webview", "_usercontent", "_controller", "_controller_lease", "ControllerPool" }) do
				local found, index = 0, 1
				while true do
					local name = debug.getupvalue(host.open, index)
					if name == nil then break end
					if name == wanted then found = found + 1 end
					index = index + 1
				end
				assert(found == 1, "open carries " .. wanted .. " " .. found .. " time(s)")
			end
		end)
	end)
	helpers.it("opens the layout editor in its own window from the manager (layout-editor-own-window)", function()
		Fixture(function(host, h)
			local registry = package.loaded["modules.keymap.layout_registry"]
			registry.source_open = function(on_done) on_done({ text = "x", filename = "mine.toml" }) end
			registry.source_save = function(_, on_done) on_done(true) end
			assert(host.open())
			local manager_view, manager_controller = h.current()
			h.post(manager_controller, manager_view, { action = "ready" })
			h.post(manager_controller, manager_view, { action = "open_editor" })
			assert(#h.views == 2, "the editor has a window of its own")
			local editor_view, editor_controller = h.views[2], h.controllers[#h.controllers]
			assert(editor_view.options.assets_dir:match("ui/layout_editor_window/$"), editor_view.options.assets_dir)
			assert(editor_controller.name == "layout_editor_window_bridge", tostring(editor_controller.name))
			assert(host.editor_window() == editor_view and host.window() == manager_view)
			h.post(editor_controller, editor_view, { action = "ready" })
			local last = editor_view.evaluations[#editor_view.evaluations]
			assert(last:match("window%.sourceData") and last:match("mine%.toml"), last)
			for _, script in ipairs(manager_view.evaluations) do
				assert(not script:match("sourceData"), "the manager page receives no source")
			end
			assert(host.open_editor() and #h.views == 2, "a second request focuses the open editor")
			assert(host.close_editor() and host.editor_window() == nil and host.window() == manager_view)
			h.close()
		end)
	end)
end)
