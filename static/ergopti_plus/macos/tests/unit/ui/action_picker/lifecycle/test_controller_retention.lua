--- tests/unit/ui/action_picker/lifecycle/test_controller_retention.lua

--- ==============================================================================
--- MODULE: Action Picker Bounded Controller Retention
--- DESCRIPTION:
--- Native-shaped UCC registry ownership stays independent of window/callback
--- cleanup. These cases do not execute JavaScript or native WebKit bindings.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.ui.usercontent_reference_fixture")

helpers.describe("action picker bounds retained native controllers", function()
	for _, close_kind in ipairs({ "explicit", "user" }) do
		helpers.it("retains only one UCC across six " .. close_kind .. " close cycles", function()
			with_picker(function(picker, h)
				for _ = 1, 6 do
					helpers.assert_true(h.open())
					if close_kind == "explicit" then helpers.assert_true(picker.close())
					else h.views[#h.views].options.on_close() end
					helpers.assert_nil(next(h.callback_refs), "callback LuaRef must be removed independently")
				end
				helpers.assert_eq(h.count(h.userdata_refs), 1, "UCC userdata remains pinned after callback nil")
				helpers.assert_eq(#h.controllers, 1)
			end)
		end)
	end

	helpers.it("keeps healthy ready and confirmation while removing its callback", function()
		with_picker(function(_, h)
			local confirmations = 0
			helpers.assert_true(h.open(function(id)
				helpers.assert_eq(id, "next")
				confirmations = confirmations + 1
				return true
			end))
			local view, controller = h.views[1], h.controllers[1]
			h.post(controller, view, { action = "ready" })
			helpers.assert_true(view.evaluations[#view.evaluations]:find("init(", 1, true) ~= nil)
			h.post(controller, view, { action = "confirm", id = "next" })
			helpers.assert_eq(confirmations, 1)
			helpers.assert_true(view.deleted)
			helpers.assert_nil(next(h.callback_refs))
			helpers.assert_eq(h.count(h.userdata_refs), 1)
		end)
	end)

	helpers.it("rejects an old native page after the controller is rebound to B", function()
		with_picker(function(picker, h)
			helpers.assert_true(h.open())
			local first, controller = h.views[1], h.controllers[1]
			helpers.assert_true(picker.close())
			local confirmations = 0
			helpers.assert_true(h.open(function() confirmations = confirmations + 1; return true end))
			local second = h.views[2]
			local poison = setmetatable({}, { __index = function() error("old body read before native source rejection") end })
			h.post(controller, first, poison)
			h.post(controller, first, { action = "cancel" })
			helpers.assert_eq(confirmations, 0)
			helpers.assert_eq(second.deleted, false)
			h.post(second.options.usercontent, second, { action = "confirm", id = "next" })
			helpers.assert_eq(confirmations, 1)
			helpers.assert_nil(next(h.callback_refs))
		end)
	end)

	helpers.it("retains nil-applied-then-throw debt and reuses only after acknowledgement", function()
		with_picker(function(picker, h)
			helpers.assert_true(h.open())
			h.detach_throws = true
			helpers.assert_eq(picker.close(), false)
			helpers.assert_nil(next(h.callback_refs))
			helpers.assert_eq(h.open(), false)
			helpers.assert_eq(#h.controllers, 1)
			h.detach_throws = false
			helpers.assert_true(h.open())
			helpers.assert_eq(#h.controllers, 1, "uncertain detach must not allocate a replacement UCC")
			helpers.assert_true(picker.close())
		end)
	end)

	helpers.it("releases the real picker's private confirmation owner after native-shaped disposal", function()
		with_picker(function(picker, h)
			local weak = setmetatable({}, { __mode = "v" })
			do
				local private = {}
				local receiver = function() return private end
				weak.private, weak.receiver = private, receiver
				helpers.assert_true(h.open(receiver))
			end
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_not_nil(weak.receiver)
			helpers.assert_true(picker.close())
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_nil(weak.receiver)
			helpers.assert_nil(weak.private)
			helpers.assert_eq(h.count(h.userdata_refs), 1)
		end)
	end)
end)
