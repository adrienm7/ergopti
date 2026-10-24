--- tests/hardware/run_xkb_semantic_controls.lua
--- Actual detached libxkbcommon + Hook checks within the source gate's Xvfb owner.
--- Reader/output are private ports: these cases claim no physical input or GUI.
local Capture = require("adapters.xkb_capture")
local Hook = require("adapters.keyboard_hook")
local Reader = require("adapters.evdev_reader")
local h = require("tests.helpers")
local US_MAP = 'xkb_keymap { xkb_keycodes { include "evdev+aliases(qwerty)" }; xkb_types { include "complete" }; xkb_compatibility { include "complete" }; xkb_symbols { include "pc+us+inet(evdev)" }; xkb_geometry { include "pc(pc105)" }; };'
local function key(code, value) return { type = 1, code = code, value = value } end

local function with_map(body)
	local ok, failure = xpcall(function()
		assert(Capture.load(US_MAP, "C.UTF-8"))
		body()
	end, debug.traceback)
	-- Attempt every owned retirement even when a preceding cleanup reports error.
	local hook_ok, hook_err = pcall(Hook.stop)
	local reader_ok, reader_err = pcall(Reader._reset_backend)
	local capture_ok, capture_err = pcall(Capture.clear)
	if not ok then error(failure, 0) end
	assert(hook_ok, hook_err); assert(reader_ok, reader_err); assert(capture_ok, capture_err)
	h.assert_eq(Hook.isRunning(), false); h.assert_eq(Reader.is_open("keyboard:/dev/input/test"), false)
	h.assert_eq(Capture.is_ready(), false)
end

local function drive(events, consume)
	local seen = { raw = {}, keys = {}, chars = {}, order = {}, target_consumers = 0 }
	local drained = Hook._test_drive(events, {
		liveXkb = true,
		onConsume = function(detail)
			if detail.code == 71 then
				seen.target_consumers = seen.target_consumers + 1
				seen.identity, seen.text = detail.key, detail.char
				return consume == true
			end
			return false
		end,
		onKey = function(name, detail)
			seen.keys[#seen.keys + 1] = { name = name, mods = detail.mods }
			seen.order[#seen.order + 1] = "key:" .. name
		end,
		onChar = function(char) seen.chars[#seen.chars + 1] = char; seen.order[#seen.order + 1] = "char" end,
		onEmitRaw = function(code, value)
			seen.raw[#seen.raw + 1] = { code, value }; seen.order[#seen.order + 1] = "raw:" .. value
			return true
		end,
	}, true)
	h.assert_eq(drained, #events)
	return seen
end

h.describe("actual native selected keypad Home routing", function()
	h.it("returns native KP_Home in slot four and preserves repeat/release semantics", function()
		with_map(function()
			local text, identity, err, control = Capture.process(71, 1)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, "home")
			local _, _, repeat_err, repeated = Capture.process(71, 2)
			h.assert_eq(repeat_err, nil); h.assert_eq(repeated, "home")
			text, identity, err, control = Capture.process(71, 0)
			h.assert_eq(text, nil); h.assert_eq(identity, nil); h.assert_eq(err, nil); h.assert_eq(control, nil)
		end)
	end)

	h.it("publishes one native Home after acknowledged private forwarding", function()
		with_map(function()
			local s = drive({ key(71, 1), key(71, 0) })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 0 } }); h.assert_eq(s.keys, { { name = "home", mods = {} } })
			h.assert_eq(s.chars, {}); h.assert_eq(s.identity, nil); h.assert_eq(s.text, nil)
			h.assert_eq(s.order, { "raw:1", "key:home", "raw:0" }); h.assert_eq(s.target_consumers, 1)
		end)
	end)

	h.it("preserves selected Home with the actual US keypad Shift states", function()
		for _, num in ipairs({ false, true }) do
			with_map(function()
				local events = {}
				if num then events[#events + 1] = key(69, 1); events[#events + 1] = key(69, 0) end
				for _, event in ipairs({ key(42, 1), key(71, 1), key(71, 0), key(42, 0) }) do events[#events + 1] = event end
				local s = drive(events)
				h.assert_eq(s.keys, { { name = "home", mods = { shift = true } } }); h.assert_eq(s.chars, {})
				h.assert_eq(s.identity, nil); h.assert_eq(s.text, nil)
			end)
		end
	end)

	h.it("leaves native NumLock keypad7 on the original printable UTF8 route", function()
		with_map(function()
			local s = drive({ key(69, 1), key(69, 0), key(71, 1), key(71, 0) })
			h.assert_eq(s.keys, {}); h.assert_eq(s.chars, { "7" }); h.assert_eq(s.identity, "7"); h.assert_eq(s.text, "7")
		end)
	end)

	h.it("keeps a consumed native Home press repeat and release outside document routing", function()
		with_map(function()
			local s = drive({ key(71, 1), key(71, 2), key(71, 0) }, true)
			h.assert_eq(s.raw, {}); h.assert_eq(s.keys, {}); h.assert_eq(s.chars, {}); h.assert_eq(s.target_consumers, 1)
		end)
	end)

	h.it("does not republish native Home for a duplicate down with no native write", function()
		with_map(function()
			local s = drive({ key(71, 1), key(71, 1), key(71, 0) })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 0 } }); h.assert_eq(s.keys, { { name = "home", mods = {} } }); h.assert_eq(s.chars, {})
		end)
	end)
end)
return h.get_results()
