--- tests/unit/ui/dialogs/test_permission_dialog_controller_cleanup.lua

--- ==============================================================================
--- MODULE: Permission Dialog Controller Cleanup
--- DESCRIPTION:
--- Hammerspoon retains script callbacks in a native Lua reference table until
--- setCallback(nil). Window deletion does not release that controller callback.
--- Drives the real dialog through normal close, native close and failed opening,
--- including cleanup refusal and owner callbacks which open a successor.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a real dialog over native-shaped controller and window boundaries.
--- @param body function Receives the harness.
local function with_dialog(body)
	helpers.with_stub_scope({ "ui.permission_dialog", "ui.ui_builder", "ui.webview_controller_pool" }, function()
		local h = { controllers = {}, windows = {}, references = {}, releases = 0, settings = 0 }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 560, height = 400 } end,
			get_centered_frame = function() return { x = 0, y = 0, w = 560, h = 400 } end,
			force_focus = function() return true end,
			show_webview = function(options)
				if h.factory_refuses then error("independent factory refusal") end
				local window = { options = options, deletes = 0 }
				function window:delete()
					self.deletes = self.deletes + 1
					options.on_close()
				end
				h.windows[#h.windows + 1] = window
				if h.factory_closes then options.on_close() end
				return window
			end,
		}
		h.dialog = helpers.load_with_stubs("ui.permission_dialog", {
			webview = { usercontent = { new = function()
				local controller = {}
				function controller:setCallback(callback)
					if callback == nil and h.on_release then h.on_release() end
					if callback == nil and h.release_refuses then error("independent unref refusal") end
					h.references[self] = callback
					if callback == nil then h.releases = h.releases + 1 end
					if callback ~= nil and h.bind_refuses then error("bound before independent refusal") end
					return self
				end
				h.controllers[#h.controllers + 1] = controller
				return controller
			end } },
		})
		function h.show(on_closed)
			return h.dialog.show({ kind = "login_items", open_settings = function()
				h.settings = h.settings + 1
				return true
			end,
				on_closed = on_closed })
		end
		body(h)
	end)
end

helpers.describe("permission dialog controller cleanup", function()
	helpers.it("releases the native callback when its owner closes the window", function()
		with_dialog(function(h)
			local closes = 0
			helpers.assert_true(h.show(function() closes = closes + 1 end))
			helpers.assert_true(h.dialog.close())
			helpers.assert_nil(h.references[h.controllers[1]])
			helpers.assert_eq(h.releases, 1)
			helpers.assert_eq(closes, 1)
			helpers.assert_true(h.dialog.close())
			helpers.assert_eq(h.releases, 1)
		end)
	end)

	helpers.it("releases the controller after the native close notification", function()
		with_dialog(function(h)
			helpers.assert_true(h.show())
			h.windows[1].options.on_close()
			helpers.assert_nil(h.references[h.controllers[1]])
			helpers.assert_eq(h.dialog.is_open(), false)
			helpers.assert_eq(h.windows[1].deletes, 0)
		end)
	end)

	helpers.it("releases the controller when the window factory refuses", function()
		with_dialog(function(h)
			local closes = 0
			h.factory_refuses = true
			helpers.assert_eq(h.show(function() closes = closes + 1 end), false)
			helpers.assert_nil(h.references[h.controllers[1]])
			helpers.assert_eq(closes, 0, "a window never opened has no close to report")
			h.factory_refuses = false
			helpers.assert_true(h.show())
			helpers.assert_true(h.dialog.close())
		end)
	end)

	helpers.it("retains an append-then-throw binding until its callback is released", function()
		with_dialog(function(h)
			h.bind_refuses = true
			h.release_refuses = true
			local ok, shown = pcall(h.show)
			helpers.assert_true(ok, "native binding refusal must return through the dialog boundary")
			helpers.assert_eq(shown, false)
			helpers.assert_true(h.references[h.controllers[1]] ~= nil)
			h.bind_refuses = false
			helpers.assert_eq(h.show(), false, "failed cleanup blocks another controller")
			helpers.assert_eq(#h.controllers, 1)
			h.release_refuses = false
			helpers.assert_true(h.dialog.close())
			helpers.assert_nil(h.references[h.controllers[1]])
		end)
	end)

	helpers.it("retries controller cleanup without deleting the closed window again", function()
		with_dialog(function(h)
			local closes = 0
			helpers.assert_true(h.show(function() closes = closes + 1 end))
			h.release_refuses = true
			helpers.assert_eq(h.dialog.close(), false)
			helpers.assert_eq(h.dialog.is_open(), false)
			helpers.assert_true(h.references[h.controllers[1]] ~= nil)
			h.references[h.controllers[1]]({ body = { action = "open_settings" } })
			helpers.assert_eq(h.settings, 0, "closed windows cannot still execute queued bridge actions")
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(#h.controllers, 1)
			h.release_refuses = false
			h.on_release = function()
				helpers.assert_eq(h.dialog.close(), false, "native unref cannot be entered twice")
				helpers.assert_eq(h.show(), false, "a successor waits for the native unref acknowledgement")
			end
			helpers.assert_true(h.dialog.close())
			helpers.assert_eq(h.windows[1].deletes, 1)
			helpers.assert_eq(closes, 1)
			helpers.assert_nil(h.references[h.controllers[1]])
		end)
	end)

	helpers.it("releases the old callback before notifying an owner that opens a successor", function()
		with_dialog(function(h)
			local successor
			helpers.assert_true(h.show(function()
				helpers.assert_nil(h.references[h.controllers[1]])
				helpers.assert_true(h.show())
				successor = h.controllers[1]
			end))
			helpers.assert_true(h.dialog.close())
			helpers.assert_true(successor ~= nil)
			helpers.assert_eq(#h.controllers, 1, "the successor reuses the retained native controller")
			helpers.assert_true(h.references[successor] ~= nil)
			helpers.assert_true(h.dialog.is_open())
			helpers.assert_true(h.dialog.close())
			helpers.assert_nil(h.references[successor])
		end)
	end)

	helpers.it("keeps a close during construction closed while controller cleanup retries", function()
		with_dialog(function(h)
			local closes = 0
			h.factory_closes, h.release_refuses = true, true
			helpers.assert_eq(h.show(function() closes = closes + 1 end), false)
			helpers.assert_eq(h.dialog.is_open(), false)
			helpers.assert_eq(h.dialog.close(), false)
			helpers.assert_eq(h.windows[1].deletes, 0)
			h.release_refuses = false
			helpers.assert_true(h.dialog.close())
			helpers.assert_nil(h.references[h.controllers[1]])
			helpers.assert_eq(closes, 1)
		end)
	end)

	helpers.it("keeps a successor opened by the owner during a show-triggered cleanup retry", function()
		with_dialog(function(h)
			helpers.assert_true(h.show(function() helpers.assert_true(h.show()) end))
			h.release_refuses = true
			helpers.assert_eq(h.dialog.close(), false)
			h.release_refuses = false
			helpers.assert_eq(h.dialog.show({ kind = "accessibility", bundle_path = "/Applications/Test.app",
				open_settings = function() return true end }), false, "the owner's successor supersedes this request")
			helpers.assert_eq(#h.windows, 2)
			helpers.assert_eq(h.windows[2].deletes, 0)
			helpers.assert_true(h.dialog.is_open("login_items"))
			helpers.assert_true(h.dialog.close())
		end)
	end)
end)
