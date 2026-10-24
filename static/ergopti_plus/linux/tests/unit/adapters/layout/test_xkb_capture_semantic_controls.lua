--- tests/unit/adapters/layout/test_xkb_capture_semantic_controls.lua
--- Selected XKB controls extend process() after its existing error result.
local h = require("tests.helpers")

local function with_capture(options, body)
	options = options or {}
	local previous = package.loaded["adapters.xkb_capture"]
	package.loaded["adapters.xkb_capture"] = nil
	local capture = require("adapters.xkb_capture")
	local state = { calls = {}, resets = 0, updates = 0 }
	local function note(name, value) state.calls[#state.calls + 1] = { name, value } end
	capture._set_backend({
		create = function() return {} end,
		destroy = function() state.destroyed = true end,
		key_sym = function(_, code)
			note("sym", code)
			if options.resolve_error then error("owned resolve failure") end
			return options.sym or 0xff95
		end,
		key_utf8 = function(_, code) note("text", code); return options.text end,
		sym_utf8 = function(_, sym) note("identity", sym); return options.identity end,
		update_key = function(_, code, direction)
			note("update", code); state.updates = state.updates + 1
			if options.update_error == direction then error("owned update failure") end
		end,
		compose_feed = function(_, sym) note("feed", sym) end,
		compose_status = function() return options.status or "nothing" end,
		compose_utf8 = function() return options.composed end,
		compose_reset = function() state.resets = state.resets + 1 end,
	})
	local ok, failure = xpcall(function()
		assert(capture.load("owned-semantic-keymap", "C.UTF-8"))
		body(capture, state)
	end, debug.traceback)
	capture._reset_backend()
	package.loaded["adapters.xkb_capture"] = previous
	h.assert_true(state.destroyed, "the controlled capture session must be retired")
	if not ok then error(failure, 0) end
end

h.describe("xkb_capture: selected semantic control return", function()
	h.it("publishes KP_Home after the unchanged text identity and error slots", function()
		with_capture({}, function(c, s)
			local text, identity, err, control = c.process(71, 1)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, "home")
			h.assert_eq(s.calls, { { "sym", 79 }, { "identity", 0xff95 }, { "text", 79 }, { "feed", 0xff95 }, { "update", 79 } })
		end)
	end)

	h.it("resolves repeats without committing another transition and filters release", function()
		with_capture({}, function(c, s)
			local _, _, _, first = c.process(71, 1)
			local _, _, repeat_err, repeated = c.process(71, 2)
			h.assert_eq({ first, repeated }, { "home", "home" }); h.assert_eq(repeat_err, nil); h.assert_eq(s.updates, 1)
			local count = #s.calls
			local text, identity, err, control = c.process(71, 0)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, nil)
			h.assert_eq(#s.calls, count + 1); h.assert_eq(s.updates, 2)
		end)
	end)

	h.it("uses the selected keysym even at another physical position", function()
		with_capture({}, function(c, s)
			local _, _, err, control = c.process(30, 1)
			h.assert_eq(err, nil); h.assert_eq(control, "home"); h.assert_eq(s.calls[1], { "sym", 38 })
		end)
	end)

	for _, specimen in ipairs({ { "keypad digit", 0xffb7, "7", "7" }, { "ordinary letter", 0x71, "q", "q" },
		{ "unclassified keypad Begin", 0xff9d }, { "function", 0xffbe }, { "unknown symbol", 0 } }) do
		h.it("does not infer Home from the physical keypad code or nil text: " .. specimen[1], function()
			with_capture({ sym = specimen[2], text = specimen[3], identity = specimen[4] }, function(c)
				local text, identity, err, control = c.process(71, 1)
				h.assert_eq(text, specimen[3]); h.assert_eq(identity, specimen[4]); h.assert_eq(err, nil); h.assert_eq(control, nil)
			end)
		end)
	end

	h.it("leaves KP_Delete DEL bytes on their original text and identity routes", function()
		local del = string.char(127)
		with_capture({ sym = 0xff9f, text = del, identity = del }, function(c)
			local text, identity, err, control = c.process(83, 1)
			h.assert_eq(text:byte(), 127); h.assert_eq(identity:byte(), 127); h.assert_eq(err, nil); h.assert_eq(control, nil)
		end)
	end)

	h.it("keeps pending Compose intact while reporting the selected known control", function()
		with_capture({ status = "composing" }, function(c, s)
			local text, identity, err, control = c.process(71, 1)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, "home")
			h.assert_eq(s.resets, 0); h.assert_eq(s.updates, 1)
		end)
	end)

	for _, composed in ipairs({ "é", "" }) do
		h.it("preserves composed text and suppresses semantic projection: " .. (composed == "" and "empty" or "UTF8"), function()
			with_capture({ status = "composed", composed = composed }, function(c, s)
				local text, identity, err, control = c.process(71, 1)
				h.assert_eq(text, composed); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, nil)
				h.assert_eq(s.resets, 1); h.assert_eq(s.updates, 1)
			end)
		end)
	end

	h.it("preserves cancelled Compose's current key and its existing reset", function()
		with_capture({ status = "cancelled" }, function(c, s)
			local _, _, err, control = c.process(71, 1)
			h.assert_eq(err, nil); h.assert_eq(control, "home"); h.assert_eq(s.resets, 1)
		end)
	end)

	h.it("keeps genuine text even if a controlled backend associates it with KP_Home", function()
		with_capture({ text = "kept", identity = "original" }, function(c)
			local text, identity, err, control = c.process(71, 1)
			h.assert_eq(text, "kept"); h.assert_eq(identity, "original"); h.assert_eq(err, nil); h.assert_eq(control, nil)
		end)
	end)

	for _, specimen in ipairs({ { "resolver", { resolve_error = true }, 1 }, { "down update", { update_error = 1 }, 1 },
		{ "up update", { update_error = 0 }, 0 }, { "Compose status", { status = "invalid" }, 1 } }) do
		h.it("retains error in slot three with no semantic control after " .. specimen[1] .. " failure", function()
			with_capture(specimen[2], function(c)
				local text, identity, err, control = c.process(71, specimen[3])
				h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_true(type(err) == "string"); h.assert_eq(control, nil)
			end)
		end)
	end

	h.it("keeps validation and unavailable-session errors in their original slot", function()
		with_capture({}, function(c)
			for _, event in ipairs({ { -1, 1 }, { 71, 3 } }) do
				local text, identity, err, control = c.process(event[1], event[2])
				h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_true(type(err) == "string"); h.assert_eq(control, nil)
			end
			c.clear()
			local text, identity, err, control = c.process(71, 1)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_true(type(err) == "string"); h.assert_eq(control, nil)
		end)
	end)
end)
