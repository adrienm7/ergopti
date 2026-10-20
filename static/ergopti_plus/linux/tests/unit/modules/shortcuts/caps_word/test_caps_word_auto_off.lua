--- tests/unit/modules/shortcuts/caps_word/test_caps_word_auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off — Unit Tests (Linux)
--- DESCRIPTION:
--- What ends the Linux CapsWord on its own: a checked delimiter typed or
--- pressed, the configured delay without a keystroke, a pointer event of a
--- checked kind. Before [shortcuts.caps_word] the manager's CapsWord never
--- switched off: it stayed on across every word until toggled by hand, and no
--- click, delay or delimiter choice reached it.
---
--- Covered: the settings owner (defaults, outdated values, sparse persistence,
--- the declared pointer kinds), the evdev code -> kind map, the manager's
--- session (delimiter, unchecked delimiter, no-break space, delay, pointer
--- kinds) and the daemon and hook wiring.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =================================================================
-- =================================================================
-- ======= 1/ Fixture ==============================================
-- =================================================================
-- =================================================================

--- Runs a body over an exclusive config file, a manual clock and a manual
--- event loop, with freshly loaded owners; restores every module after.
--- @param source string|nil Configuration bytes.
--- @param body function body(context)
local function with_caps_word(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local context = { now = 1000, deferred = {}, resolution = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["infra.monotonic"] = {
				now_ms = function() return context.now end,
				now_sec = function() return context.now / 1000 end,
				resolution_ms = function() return context.resolution end,
			}
			local EventLoop = require("adapters.event_loop")
			local original_defer = EventLoop.defer
			EventLoop.defer = function(fn, delay_ms)
				context.deferred[#context.deferred + 1] = { fn = fn, due = context.now + delay_ms }
				return true
			end
			--- Runs every queued callback that is due now (callbacks may queue more).
			function context.run_due()
				local pending = context.deferred
				context.deferred = {}
				for _, entry in ipairs(pending) do
					if entry.due <= context.now then entry.fn() else context.deferred[#context.deferred + 1] = entry end
				end
			end
			package.loaded["modules.shortcuts.caps_word_auto_off"] = nil
			package.loaded["modules.shortcuts.manager"] = nil
			context.AutoOff = require("modules.shortcuts.caps_word_auto_off")
			context.manager = require("modules.shortcuts.manager")
			context.manager.init({ enabled = true })
			context.path = path
			local called, failure = pcall(body, context)
			EventLoop.defer = original_defer
			if not called then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

local NBSP = "\194\160"





-- =================================================================
-- =================================================================
-- ======= 2/ The settings owner ===================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: the settings", function()
	helpers.it("caps word auto-off, reads the manifest defaults from an empty configuration", function()
		with_caps_word(nil, function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 0, "never times out by default")
			helpers.assert_eq(table.concat(settings.terminators, ","), "space,tab,enter")
			for _, kind in ipairs(c.AutoOff.pointer_kinds()) do
				helpers.assert_eq(settings.pointer[kind], true, kind .. " ends CapsWord by default")
			end
		end)
	end)

	helpers.it("caps word auto-off, declares exactly the manifest's pointer kinds", function()
		with_caps_word(nil, function(c)
			local Manifest = require("infra.manifest_reader")
			local expected = {}
			for _, entry in ipairs(Manifest.features()) do
				if entry.section == "shortcuts.caps_word.pointer" then expected[#expected + 1] = entry.id end
			end
			helpers.assert_true(#expected > 0, "the manifest declares pointer kinds")
			helpers.assert_eq(table.concat(c.AutoOff.pointer_kinds(), ","), table.concat(expected, ","))
		end)
	end)

	helpers.it("caps word auto-off, reads stored values and drops what this build does not know", function()
		local source = '[shortcuts.caps_word]\nidle_timeout_seconds = 5\nterminators = ["nbsp", "hyphen", "comma", "comma"]\n'
			.. '\n[shortcuts.caps_word.pointer]\nleft_click = false\nwheel = true\n'
		with_caps_word(source, function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 5)
			helpers.assert_eq(table.concat(settings.terminators, ","), "nbsp,comma",
				"an unknown key and a duplicate are dropped")
			helpers.assert_eq(settings.pointer.left_click, false)
			helpers.assert_eq(settings.pointer.wheel, nil, "an undeclared kind is never read")
		end)
	end)

	helpers.it("caps word auto-off, reads a malformed delay or list as its default", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = -2\nterminators = "space"\n', function(c)
			local settings = c.AutoOff.settings()
			helpers.assert_eq(settings.idle_timeout_seconds, 0)
			helpers.assert_eq(table.concat(settings.terminators, ","), "space,tab,enter")
		end)
	end)

	helpers.it("caps word auto-off, persists a change sparsely and in catalogue order", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.AutoOff.set_terminator("nbsp", true))
			helpers.assert_true(c.AutoOff.set_pointer("middle_click", false))
			helpers.assert_true(c.AutoOff.set_idle_timeout_seconds(3))
			local file = assert(io.open(c.path, "rb"))
			local text = file:read("*a")
			file:close()
			helpers.assert_contains(text, 'terminators = ["space", "nbsp", "tab", "enter"]')
			helpers.assert_contains(text, "middle_click = false")
			helpers.assert_contains(text, "idle_timeout_seconds = 3")
			c.AutoOff.reset_for_tests()
			local reread = c.AutoOff.settings()
			helpers.assert_eq(table.concat(reread.terminators, ","), "space,nbsp,tab,enter")
			helpers.assert_eq(c.AutoOff.set_terminator("hyphen", true), false, "an unknown delimiter is refused")
			helpers.assert_eq(c.AutoOff.set_pointer("wheel", true), false, "an undeclared kind is refused")
			helpers.assert_eq(c.AutoOff.set_idle_timeout_seconds(-1), false, "a negative delay is refused")
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 3/ The pointer kinds of native events ===================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: evdev pointer kinds", function()
	helpers.it("caps word auto-off, names the kind of every pointer press", function()
		with_caps_word(nil, function(c)
			local Codes = require("infra.evdev_codes")
			local kind = c.AutoOff.pointer_kind_of_button
			helpers.assert_eq(kind(Codes.BTN_LEFT), "left_click")
			helpers.assert_eq(kind(Codes.BTN_RIGHT), "right_click")
			helpers.assert_eq(kind(Codes.BTN_MIDDLE), "middle_click")
			helpers.assert_eq(kind(0x113), "other_buttons", "BTN_SIDE")
			helpers.assert_eq(kind(0x116), "other_buttons", "BTN_BACK")
			helpers.assert_eq(kind(0x14a), "gesture", "BTN_TOUCH")
			helpers.assert_eq(kind(0x14d), "gesture", "BTN_TOOL_DOUBLETAP")
			helpers.assert_eq(kind(30), nil, "a keyboard key is no pointer kind")
			helpers.assert_eq(c.AutoOff.pointer_kind_of_motion(), "pointer_motion")
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 4/ The CapsWord session =================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: the manager session", function()
	helpers.it("caps word auto-off, a checked delimiter ends CapsWord", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text("a"), false)
			helpers.assert_true(c.manager.is_caps_word_active(), "a letter keeps CapsWord on")
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "a space ends CapsWord by default")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text("\t"), true, "a bare Tab ends it by default")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_control("enter"), true, "a modified Enter ends it too")
		end)
	end)

	helpers.it("caps word auto-off, an unchecked delimiter keeps CapsWord on", function()
		with_caps_word('[shortcuts.caps_word]\nterminators = ["tab"]\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false)
			helpers.assert_eq(c.manager.caps_word_observe_text(NBSP), false, "an unchecked no-break space")
			helpers.assert_eq(c.manager.caps_word_observe_control("enter"), false)
			helpers.assert_true(c.manager.is_caps_word_active())
		end)
	end)

	helpers.it("caps word auto-off, a checked no-break space ends CapsWord and a space does not", function()
		with_caps_word('[shortcuts.caps_word]\nterminators = ["nbsp"]\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false)
			helpers.assert_eq(c.manager.caps_word_observe_text(NBSP), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, the delay ends a silent CapsWord and a keystroke postpones it", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 3\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 3500
			c.manager.caps_word_observe_text("a")
			c.now = 4100
			c.run_due()
			helpers.assert_true(c.manager.is_caps_word_active(), "3 s from the activation, but 0.6 s from the key")
			c.now = 6500
			c.run_due()
			helpers.assert_eq(c.manager.is_caps_word_active(), false, "3 s after the last key, the timer ends it")
		end)
	end)

	helpers.it("caps word auto-off, a key after the delay ends CapsWord before it is read", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 1\n', function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 2500
			helpers.assert_eq(c.manager.caps_word_observe_text("a"), false)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, a whole-second clock never reads two quick keys as a pause", function()
		with_caps_word('[shortcuts.caps_word]\nidle_timeout_seconds = 1\n', function(c)
			c.resolution = 1000
			helpers.assert_true(c.manager.toggle_caps_word())
			c.now = 2000
			c.manager.caps_word_observe_text("a")
			helpers.assert_true(c.manager.is_caps_word_active(), "a second turnover is no pause")
			c.now = 3000
			c.run_due()
			helpers.assert_true(c.manager.is_caps_word_active(), "the timer waits for a provable pause")
			helpers.assert_true(#c.deferred == 1 and c.deferred[1].due > c.now, "and queues itself for later, not for the next tick")
			c.now = 4000
			c.run_due()
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, never times out with the default delay", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(#c.deferred, 0, "no idle check is queued for « never »")
			c.now = 1e9
			c.manager.caps_word_observe_text("a")
			helpers.assert_true(c.manager.is_caps_word_active())
		end)
	end)

	helpers.it("caps word auto-off, a checked pointer kind ends CapsWord and an unchecked one keeps it", function()
		with_caps_word('[shortcuts.caps_word.pointer]\nright_click = false\npointer_motion = false\n', function(c)
			local Codes = require("infra.evdev_codes")
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_button(Codes.BTN_RIGHT)), false)
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_motion()), false)
			helpers.assert_eq(c.manager.caps_word_observe_pointer(nil), false, "an event of no kind")
			helpers.assert_true(c.manager.is_caps_word_active())
			helpers.assert_eq(c.manager.caps_word_observe_pointer(c.AutoOff.pointer_kind_of_button(Codes.BTN_LEFT)), true)
			helpers.assert_eq(c.manager.is_caps_word_active(), false)
		end)
	end)

	helpers.it("caps word auto-off, a new CapsWord reads the settings stored since the last one", function()
		with_caps_word(nil, function(c)
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_true(c.manager.toggle_caps_word())
			local file = assert(io.open(c.path, "wb"))
			file:write('[shortcuts.caps_word]\nterminators = ["comma"]\n')
			file:close()
			helpers.assert_true(c.manager.toggle_caps_word())
			helpers.assert_eq(c.manager.caps_word_observe_text(" "), false, "the hand edit unchecked Space")
			helpers.assert_eq(c.manager.caps_word_observe_text(","), true)
		end)
	end)
end)





-- =================================================================
-- =================================================================
-- ======= 5/ Wiring ===============================================
-- =================================================================
-- =================================================================

helpers.describe("caps word auto-off: daemon and hook wiring", function()
	local function source(rel)
		local f = assert(io.open(helpers.driver_root() .. "/" .. rel, "rb"))
		local text = f:read("*a")
		f:close()
		return text
	end

	helpers.it("caps word auto-off, the daemon reports characters, controls, presses and motion", function()
		local daemon = source("ergopti_hotstrings.lua")
		helpers.assert_contains(daemon, "shortcuts.caps_word_observe_text(ch)")
		helpers.assert_contains(daemon, "shortcuts.caps_word_observe_control(key_name)")
		helpers.assert_contains(daemon, "CapsWordAutoOff.pointer_kind_of_button(code)")
		helpers.assert_contains(daemon, "CapsWordAutoOff.pointer_kind_of_motion()")
		helpers.assert_contains(daemon, "onPointerEvent = on_pointer_event")
		-- The bare Tab returns early; the delimiter check must come before it.
		local observe = daemon:find("shortcuts.caps_word_observe_text(ch)", 1, true)
		local tab = daemon:find('if ch == "\\t" then', 1, true)
		helpers.assert_true(observe ~= nil and tab ~= nil and observe < tab, "the delimiter check precedes the Tab return")
	end)

	helpers.it("caps word auto-off, the hook hands every pointer press and EV_REL report to the callback", function()
		local hook = source("adapters/keyboard_hook.lua")
		helpers.assert_contains(hook, '_call_callback("pointer event callback", _on_pointer_event, "motion", ev.code)')
		helpers.assert_contains(hook, '_call_callback("pointer event callback", _on_pointer_event, "press", ev.code)')
		helpers.assert_contains(hook, "_on_pointer_event = options.onPointerEvent")
	end)

	helpers.it("caps word auto-off, the daemon maps a press and a motion to their declared kinds", function()
		local daemon = source("ergopti_hotstrings.lua")
		local body = assert(daemon:match("local function on_pointer_event%(kind_of_event, code%)(.-)\n\tend\n"),
			"the pointer callback is missing")
		local factory = assert((loadstring or load)(
			"return function(shortcuts, CapsWordAutoOff) return function(kind_of_event, code) " .. body .. " end end"))()
		local seen = {}
		local fake_shortcuts = {
			is_caps_word_active = function() return true end,
			caps_word_observe_pointer = function(kind) seen[#seen + 1] = tostring(kind) end,
		}
		with_caps_word(nil, function(c)
			local Codes = require("infra.evdev_codes")
			local callback = factory(fake_shortcuts, c.AutoOff)
			callback("press", Codes.BTN_MIDDLE)
			callback("motion", 0x00)
			callback("press", 30)
		end)
		helpers.assert_eq(table.concat(seen, ","), "middle_click,pointer_motion,nil",
			"a keyboard code pressed on a pointer is no kind, never a motion")
	end)
end)

return true
