--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_semantic_controls.lua
--- Real capture and Hook routing over controlled keymap/Reader/output ports.
local h = require("tests.helpers")
local function key(code, value) return { type = 1, code = code, value = value } end

local function with_hook(options, body)
	options = options or {}
	local journal = {}; for name, value in pairs(package.loaded) do journal[name] = value end
	for _, name in ipairs({ "adapters.xkb_capture", "adapters.keyboard_hook", "adapters.evdev_reader", "adapters.modifier_broker" }) do package.loaded[name] = nil end
	local Capture = require("adapters.xkb_capture")
	local target = options.code or 71
	Capture._set_backend({
		create = function() return {} end, destroy = function() end,
		key_sym = function(_, code)
			if code == 50 then return 0xffe1 end
			if code == 37 then return 0xffe3 end
			if code == target + 8 then return options.sym or 0xff95 end
		end,
		key_utf8 = function(_, code) if code == target + 8 then return options.text end end,
		sym_utf8 = function(_, sym) if sym == (options.sym or 0xff95) then return options.identity end end,
		update_key = function() end, compose_feed = function() end,
		compose_status = function() return "nothing" end, compose_reset = function() end,
	})
	assert(Capture.load("controlled-selected-keymap", "C.UTF-8"))
	local Hook = require("adapters.keyboard_hook")
	local Reader = require("adapters.evdev_reader")
	local ok, failure = xpcall(function()
		local function drive(events, extra)
			extra = extra or {}
			local seen = { raw = {}, controls = {}, chars = {}, order = {}, consume = {} }
			if extra.remapper then assert(Hook.set_remapper(extra.remapper)) end
			seen.drained = Hook._test_drive(events, {
				liveXkb = extra.captureEvent == nil, captureEvent = extra.captureEvent,
				onConsume = function(detail)
					seen.consume[#seen.consume + 1] = detail
					return extra.consume == true
				end,
				onKey = function(name, detail)
					seen.controls[#seen.controls + 1] = { name = name, mods = detail.mods, tap_hold = detail.tap_hold }
					seen.order[#seen.order + 1] = "key:" .. name
				end,
				onChar = function(char) seen.chars[#seen.chars + 1] = char; seen.order[#seen.order + 1] = "char" end,
				onEmitRaw = function(code, value)
					seen.raw[#seen.raw + 1] = { code, value }; seen.order[#seen.order + 1] = "raw:" .. value
					return not extra.refuse
				end,
			}, true)
			return seen
		end
		body(drive)
	end, debug.traceback)
	pcall(Hook.stop); Reader._reset_backend(); Capture._reset_backend()
	for name in pairs(package.loaded) do if journal[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(journal) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

h.describe("keyboard_hook: selected semantic controls", function()
	h.it("publishes selected Home only after raw ACK with the original nil UTF8 identity", function()
		with_hook({}, function(drive)
			local s = drive({ key(71, 1), key(71, 0) })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 0 } }); h.assert_eq(s.chars, {})
			h.assert_eq(s.controls, { { name = "home", mods = {} } })
			h.assert_eq(s.order, { "raw:1", "key:home", "raw:0" })
			h.assert_eq(#s.consume, 1); h.assert_eq(s.consume[1].key, nil); h.assert_eq(s.consume[1].char, nil)
		end)
	end)

	h.it("retains Shift on selected Home without inventing a printable character", function()
		with_hook({}, function(drive)
			local s = drive({ key(42, 1), key(71, 1), key(71, 0), key(42, 0) })
			h.assert_eq(s.controls, { { name = "home", mods = { shift = true } } }); h.assert_eq(s.chars, {})
		end)
	end)

	h.it("follows selected KP_Home at a different raw position", function()
		with_hook({ code = 30 }, function(drive)
			local s = drive({ key(30, 1), key(30, 0) })
			h.assert_eq(s.controls, { { name = "home", mods = {} } }); h.assert_eq(s.chars, {})
		end)
	end)

	h.it("keeps the same physical keypad position printable when XKB selects a digit", function()
		with_hook({ sym = 0xffb7, text = "7", identity = "7" }, function(drive)
			local s = drive({ key(71, 1), key(71, 0) })
			h.assert_eq(s.controls, {}); h.assert_eq(s.chars, { "7" }); h.assert_eq(s.consume[1].key, "7")
		end)
	end)

	h.it("does not classify an unrelated nil-text KP_Begin as document navigation", function()
		with_hook({ sym = 0xff9d }, function(drive)
			local s = drive({ key(71, 1), key(71, 0) })
			h.assert_eq(s.controls, {}); h.assert_eq(s.chars, {}); h.assert_eq(#s.raw, 2)
		end)
	end)

	h.it("preserves DEL text rather than inventing a KP_Delete semantic control", function()
		local del = string.char(127)
		with_hook({ code = 83, sym = 0xff9f, text = del, identity = del }, function(drive)
			local s = drive({ key(83, 1), key(83, 0) })
			h.assert_eq(s.controls, {}); h.assert_eq(s.chars, { del })
		end)
	end)

	h.it("keeps consumed down repeats and release out of raw and semantic delivery", function()
		with_hook({}, function(drive)
			local s = drive({ key(71, 1), key(71, 2), key(71, 0) }, { consume = true })
			h.assert_eq(s.raw, {}); h.assert_eq(s.controls, {}); h.assert_eq(s.chars, {}); h.assert_eq(#s.consume, 1)
		end)
	end)

	h.it("never reports Home when the raw output refuses the event", function()
		with_hook({}, function(drive)
			local s = drive({ key(71, 1), key(71, 0) }, { refuse = true })
			h.assert_true(#s.raw > 0, "the refusal must actually be exercised")
			h.assert_eq(s.controls, {}); h.assert_eq(s.chars, {})
		end)
	end)

	h.it("does not publish a duplicate down with zero native writes", function()
		with_hook({}, function(drive)
			local s = drive({ key(71, 1), key(71, 1), key(71, 0) })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 0 } }); h.assert_eq(#s.controls, 1); h.assert_eq(s.controls[1].name, "home")
		end)
	end)

	h.it("publishes a real repeat but never a release as another control", function()
		with_hook({}, function(drive)
			local s = drive({ key(71, 1), key(71, 2), key(71, 0) })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 2 }, { 71, 0 } }); h.assert_eq(#s.controls, 2)
		end)
	end)

	h.it("ignores fourth-slot metadata accompanying an error and keeps legacy three-return text", function()
		with_hook({}, function(drive)
			local failed = drive({ key(71, 1), key(71, 0) }, { captureEvent = function(_, value)
				if value ~= 0 then return nil, nil, "owned capture refusal", "home" end
			end })
			h.assert_eq(failed.controls, {}); h.assert_eq(failed.chars, {})
			local legacy = drive({ key(71, 1), key(71, 0) }, { captureEvent = function(_, value)
				if value ~= 0 then return "q", "q", nil end
			end })
			h.assert_eq(legacy.controls, {}); h.assert_eq(legacy.chars, { "q" })
		end)
	end)

	h.it("does not reinterpret a dedicated Home fallback when capture has no semantic result", function()
		with_hook({ sym = 0xffbe }, function(drive)
			local s = drive({ key(102, 1), key(102, 0) })
			h.assert_eq(s.controls, { { name = "home", mods = {} } }); h.assert_eq(s.chars, {})
		end)
	end)

	h.it("does not publish the restored down of an output custody handoff", function()
		with_hook({}, function(drive)
			local engine = { tick = function() return {} end, release_all = function() return {} end,
				process = function(_, code, value)
					if code == 30 then
						if value == 1 then return { { code = 71, value = 0, handoff = "suspended" },
							{ code = 71, value = 1, handoff = "restored" } } end
						return {}
					end
				end }
			local s = drive({ key(71, 1), key(30, 1), key(30, 0), key(71, 0) }, { remapper = engine })
			h.assert_eq(s.raw, { { 71, 1 }, { 71, 0 }, { 71, 1 }, { 71, 0 } })
			h.assert_eq(s.controls, { { name = "home", mods = {} } }); h.assert_eq(s.chars, {})
		end)
	end)
end)
