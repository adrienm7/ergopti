--- tests/unit/ui/action_picker/lifecycle/test_controller_pool_leases.lua

--- ==============================================================================
--- MODULE: Exact Usercontent Controller Leases
--- DESCRIPTION:
--- Exercises the real pool against independent native-shaped callback and UCC
--- registries. No JavaScript delivery or native userdata collection is claimed.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_picker = require("tests.support.ui.usercontent_reference_fixture")

--- Builds the real helper without adding production-only introspection ports.
--- @param callback function Receives a fresh pool and native observations.
local function with_pool(callback)
	return with_picker(function(_, h)
		local pool = require("ui.webview_controller_pool").new(h.native_new, require("infra.logger"))
		function h.activate(view, receive)
			local token, controller = pool.reserve("action_picker")
			helpers.assert_not_nil(token)
			helpers.assert_true(pool.bind(token, receive))
			helpers.assert_true(pool.attach(token, view))
			helpers.assert_true(pool.commit(token))
			return token, controller
		end
		callback(pool, h)
	end)
end

helpers.describe("usercontent pool keeps authority outside the native controller identity", function()
	helpers.it("rejects unknown roles and forged tokens without allocating native controllers", function()
		with_pool(function(pool, h)
			helpers.assert_nil(pool.reserve("user-provided-role"))
			helpers.assert_eq(pool.release({}), false)
			helpers.assert_eq(pool.bind({}, function() end), false)
			helpers.assert_eq(pool.attach({}, {}), false)
			helpers.assert_eq(pool.commit({}), false)
			helpers.assert_eq(#h.controllers, 0)
		end)
	end)

	helpers.it("keeps a terminal A release inert after B reuses the same controller", function()
		with_pool(function(pool, h)
			local first, controller = h.activate({}, function() end)
			helpers.assert_nil(next(first), "token must expose no controller or mutable owner fields")
			helpers.assert_eq(getmetatable(first), false)
			helpers.assert_true(pool.release(first))
			local view, received = {}, 0
			local second, reused = h.activate(view, function() received = received + 1 end)
			helpers.assert_true(rawequal(controller, reused))
			local before = h.nil_calls
			helpers.assert_true(pool.release(first))
			helpers.assert_eq(h.nil_calls, before)
			h.post(reused, view, {})
			helpers.assert_eq(received, 1)
			helpers.assert_true(pool.release(second))
		end)
	end)

	helpers.it("routes simultaneous leases independently and detaches only the final receiver", function()
		with_pool(function(pool, h)
			local a, b, received = {}, {}, {}
			local first, controller = h.activate(a, function() received[#received + 1] = "a" end)
			local second, reused = h.activate(b, function() received[#received + 1] = "b" end)
			helpers.assert_true(rawequal(controller, reused))
			h.post(controller, a, {}); h.post(controller, b, {})
			helpers.assert_eq(table.concat(received), "ab")
			helpers.assert_true(pool.release(first))
			helpers.assert_eq(h.nil_calls, 0)
			h.post(controller, a, {}); h.post(controller, b, {})
			helpers.assert_eq(table.concat(received), "abb")
			helpers.assert_true(pool.release(second))
			helpers.assert_eq(h.nil_calls, 1)
			helpers.assert_nil(next(h.callback_refs))
			helpers.assert_eq(h.count(h.userdata_refs), 1)
		end)
	end)

	for _, refusal in ipairs({ "false", "nil", "true", "foreign" }) do
		helpers.it("retains cleanup debt after applied native detach returns " .. refusal, function()
			with_pool(function(pool, h)
				local lease, controller = h.activate({}, function() error("revoked receiver ran") end)
				h.detach_result = refusal
				helpers.assert_eq(pool.release(lease), false)
				helpers.assert_nil(h.callback_refs[controller], "native mutation applied despite absent acknowledgement")
				helpers.assert_nil(pool.reserve("action_picker"))
				helpers.assert_eq(#h.controllers, 1)
				h.detach_result = nil
				local second = h.activate({}, function() end)
				helpers.assert_eq(#h.controllers, 1)
				helpers.assert_true(pool.release(second))
			end)
		end)
	end

	helpers.it("removes the retired domain receiver while another lease keeps the dispatcher alive", function()
		with_pool(function(pool, h)
			local weak = setmetatable({}, { __mode = "v" })
			local first, controller
			do
				local private = {}
				local receiver = function() return private end
				weak.private, weak.receiver = private, receiver
				first, controller = h.activate({}, receiver)
			end
			local second = h.activate({}, function() end)
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_not_nil(weak.receiver)
			helpers.assert_true(pool.release(first))
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_nil(weak.receiver)
			helpers.assert_nil(weak.private)
			helpers.assert_type(h.callback_refs[controller], "function")
			helpers.assert_true(pool.release(second))
		end)
	end)

	helpers.it("collects terminal opaque tokens and their private receiver session while retaining one UCC", function()
		with_pool(function(pool, h)
			local weak = setmetatable({}, { __mode = "v" })
			do
				local session = {}
				local receiver = function() return session end
				local token = h.activate({}, receiver)
				weak.session, weak.receiver, weak.token = session, receiver, token
				helpers.assert_true(pool.release(token))
			end
			collectgarbage("collect"); collectgarbage("collect")
			helpers.assert_nil(weak.token)
			helpers.assert_nil(weak.receiver)
			helpers.assert_nil(weak.session)
			helpers.assert_nil(next(h.callback_refs))
			helpers.assert_eq(h.count(h.userdata_refs), 1)
		end)
	end)

	helpers.it("never reads an old or forged body's fields before rejecting its native source", function()
		with_pool(function(pool, h)
			local view, received = {}, 0
			local lease, controller = h.activate(view, function(message)
				received = received + 1
				return message.body.action
			end)
			local poison = setmetatable({}, { __index = function() error("foreign body read") end })
			h.post(controller, {}, poison)
			h.post(controller, nil, poison)
			h.post(controller, {}, { webView = view, action = "forged" })
			helpers.assert_eq(received, 0)
			h.post(controller, view, { action = "healthy" })
			helpers.assert_eq(received, 1)
			helpers.assert_true(pool.release(lease))
		end)
	end)

	helpers.it("does not publish business before exact attach and commit", function()
		with_pool(function(pool, h)
			local lease, controller = pool.reserve("action_picker")
			local view, received = {}, 0
			helpers.assert_true(pool.bind(lease, function() received = received + 1 end))
			h.post(controller, view, {})
			helpers.assert_true(pool.attach(lease, view))
			h.post(controller, view, {})
			helpers.assert_eq(received, 0)
			helpers.assert_true(pool.commit(lease))
			h.post(controller, view, {})
			helpers.assert_eq(received, 1)
			local other = pool.reserve("action_picker")
			helpers.assert_eq(pool.attach(other, view), false)
			helpers.assert_true(pool.release(other))
			helpers.assert_true(pool.release(lease))
		end)
	end)

	helpers.it("retains an applied binding exception until exact native cleanup is acknowledged", function()
		with_pool(function(pool, h)
			local lease, controller = pool.reserve("action_picker")
			h.bind_throws, h.detach_throws = true, true
			local bound, detail = pool.bind(lease, function() error("unpublished receiver ran") end)
			helpers.assert_eq(bound, false)
			helpers.assert_true(detail:find("native bind applied before wrapper exception", 1, true) ~= nil)
			helpers.assert_type(h.callback_refs[controller], "function")
			h.post(controller, {}, {})
			helpers.assert_eq(pool.release(lease), false)
			helpers.assert_nil(pool.reserve("action_picker"))
			h.bind_throws, h.detach_throws = false, false
			local second = h.activate({}, function() end)
			helpers.assert_eq(#h.controllers, 1)
			helpers.assert_true(pool.release(second))
		end)
	end)

	helpers.it("blocks reentrant reserve and native cleanup until the nil setter returns", function()
		with_pool(function(pool, h)
			local lease = h.activate({}, function() end)
			local entered = false
			h.on_detach = function()
				entered = true
				helpers.assert_nil(pool.reserve("action_picker"))
				helpers.assert_eq(pool.release(lease), false)
			end
			helpers.assert_true(pool.release(lease))
			helpers.assert_true(entered)
			helpers.assert_eq(h.nil_calls, 1)
			h.on_detach = nil
			local next_lease = h.activate({}, function() end)
			helpers.assert_true(pool.release(next_lease))
		end)
	end)

	helpers.it("keeps the picker loadable when the native usercontent capability is absent", function()
		with_picker(function(_, h)
			package.loaded["ui.action_picker"] = nil
			_G.hs = {}
			local picker = require("ui.action_picker")
			helpers.assert_eq(picker.open({ items = {} }), false)
			helpers.assert_eq(#h.controllers, 0)
			helpers.assert_true(#h.errors > 0)
		end)
	end)
end)
