--- tests/unit/ui/dialogs/lifecycle/test_permission_controller_leases.lua

--- ==============================================================================
--- MODULE: Permission Dialog Controller Leases
--- DESCRIPTION:
--- Drives the real dialog and pool against independent controller userdata and
--- callback reference registries. Window disposal never collects a controller.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.ui.usercontent_reference_fixture")

--- Reuses the native reference contract without replacing the dialog receiver.
--- @param scenario function Receives the real dialog and native observations.
local function with_dialog(scenario)
	helpers.with_stub_scope({ "ui.permission_dialog" }, function()
		with_picker(function(_, h)
			local i18n = require("infra.i18n")
			i18n.format = function(key) return key end
			i18n.get_locale = function() return "en" end
			local builder = require("ui.ui_builder")
			builder.force_focus = function() return true end
			local show = builder.show_webview
			builder.show_webview = function(options)
				local view = show(options)
				if view and h.on_factory then h.on_factory(view) end
				return view
			end
			local dialog = require("ui.permission_dialog")
			h.settings, h.closed = 0, 0
			function h.show(on_closed)
				return dialog.show({ kind = "login_items", open_settings = function()
					h.settings = h.settings + 1
					return true
				end, on_closed = on_closed or function() h.closed = h.closed + 1 end })
			end
			scenario(dialog, h)
		end)
	end)
end

helpers.describe("permission dialog bounded native controllers", function()
	helpers.it("reuses one native controller across owner and user closes", function()
		with_dialog(function(dialog, h)
			for index = 1, 12 do
				helpers.assert_true(h.show())
				if index % 2 == 0 then h.views[index]:delete()
				else helpers.assert_true(dialog.close()) end
				helpers.assert_nil(next(h.callback_refs))
			end
			helpers.assert_eq(h.closed, 12)
			helpers.assert_eq(#h.controllers, 1, "native userdata roots must remain bounded")
			helpers.assert_eq(h.count(h.userdata_refs), 1)
		end)
	end)

	helpers.it("accepts current actions and raises the same open owner", function()
		with_dialog(function(dialog, h)
			helpers.assert_true(h.show())
			helpers.assert_true(h.show())
			helpers.assert_eq(#h.views, 1)
			h.post(h.controllers[1], h.views[1], { action = "open_settings" })
			helpers.assert_eq(h.settings, 1)
			h.post(h.controllers[1], h.views[1], { action = "later" })
			helpers.assert_eq(dialog.is_open(), false)
			helpers.assert_eq(h.closed, 1)
		end)
	end)

	helpers.it("rejects old windows and forged names before reading their body", function()
		with_dialog(function(dialog, h)
			helpers.assert_true(h.show())
			local old, controller = h.views[1], h.controllers[1]
			helpers.assert_true(dialog.close())
			helpers.assert_true(h.show())
			local callback = h.callback_refs[h.controllers[#h.controllers]]
			local function poison(name, view)
				return setmetatable({ name = name, webView = view }, { __index = function(_, key)
					if key == "body" then error("foreign message body was read") end
				end })
			end
			callback(poison(controller.name, old))
			callback(poison("foreign_bridge", h.views[2]))
			callback(poison(controller.name, nil))
			helpers.assert_eq(h.settings, 0)
			h.post(h.controllers[#h.controllers], h.views[2], { action = "open_settings" })
			helpers.assert_eq(h.settings, 1)
			helpers.assert_true(dialog.close())
		end)
	end)

	helpers.it("admits business only after the factory returns and the lease commits", function()
		with_dialog(function(dialog, h)
			h.on_factory = function(view)
				h.post(h.controllers[1], view, { action = "open_settings" })
				helpers.assert_eq(h.settings, 0)
			end
			helpers.assert_true(h.show())
			h.post(h.controllers[1], h.views[1], { action = "open_settings" })
			helpers.assert_eq(h.settings, 1)
			helpers.assert_true(dialog.close())
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "true", "foreign", "throw" }) do
		helpers.it("retains the exact cleanup lease after native detach returns " .. refusal, function()
			with_dialog(function(dialog, h)
				helpers.assert_true(h.show())
				local controller, old = h.controllers[1], h.views[1]
				local callback = h.callback_refs[controller]
				h.detach_result, h.detach_throws = refusal, refusal == "throw"
				helpers.assert_eq(dialog.close(), false)
				helpers.assert_eq(h.closed, 0, "owner notification waits for strict callback retirement")
				callback({ name = controller.name, webView = old, body = { action = "open_settings" } })
				helpers.assert_eq(h.settings, 0)
				helpers.assert_eq(h.show(), false)
				helpers.assert_eq(#h.controllers, 1)
				h.detach_result, h.detach_throws = nil, false
				helpers.assert_true(dialog.close())
				helpers.assert_eq(h.closed, 1)
				helpers.assert_true(h.show())
				helpers.assert_eq(#h.controllers, 1)
				helpers.assert_true(dialog.close())
			end)
		end)
	end

	helpers.it("blocks native detach reentry and protects an owner-created successor", function()
		with_dialog(function(dialog, h)
			helpers.assert_true(h.show(function()
				helpers.assert_nil(next(h.callback_refs))
				h.on_detach = nil
				helpers.assert_true(h.show())
			end))
			h.on_detach = function()
				helpers.assert_eq(dialog.close(), false)
				helpers.assert_eq(h.show(), false)
			end
			helpers.assert_true(dialog.close())
			helpers.assert_true(dialog.is_open())
			helpers.assert_eq(#h.controllers, 1)
			h.post(h.controllers[1], h.views[2], { action = "open_settings" })
			helpers.assert_eq(h.settings, 1)
			helpers.assert_true(dialog.close())
		end)
	end)

	helpers.it("reuses the controller after failed factory construction", function()
		with_dialog(function(dialog, h)
			h.factory_refuses = true
			helpers.assert_eq(h.show(), false)
			helpers.assert_nil(next(h.callback_refs))
			helpers.assert_eq(h.closed, 0)
			h.factory_refuses = false
			helpers.assert_true(h.show())
			helpers.assert_eq(#h.controllers, 1)
			helpers.assert_true(dialog.close())
		end)
	end)

	helpers.it("keeps an applied binding exception revocable and blocks premature replacement", function()
		with_dialog(function(dialog, h)
			h.bind_throws, h.detach_throws = true, true
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(h.show(), false)
			helpers.assert_eq(#h.controllers, 1)
			h.bind_throws, h.detach_throws = false, false
			helpers.assert_true(dialog.close())
			helpers.assert_true(h.show())
			helpers.assert_eq(#h.controllers, 1)
			helpers.assert_true(dialog.close())
		end)
	end)
end)
