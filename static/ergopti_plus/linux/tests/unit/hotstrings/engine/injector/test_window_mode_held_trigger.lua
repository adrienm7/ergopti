--- tests/unit/hotstrings/engine/injector/test_window_mode_held_trigger.lua

--- ==============================================================================
--- MODULE: A Window-Mode Expansion Never Holds Its Trigger Key
--- DESCRIPTION:
--- Field report, Arch Linux, KDE Plasma Wayland, 2026-11-25: typing « , » then
--- « e » (the comma_j hotstring « ,e » → « je ») gave « ,eeeeeeeeeje ». KDE's
--- Wayland session answers no accessibility focus query, so text automation
--- runs in the window mode. The expansion fires on the « e » key-down, which
--- the grabbed hook has already forwarded; the output preflight then asked the
--- window-mode owner for a fresh focus answer with the one-second output
--- budget, while « e » was still down on the virtual keyboard. KDE autorepeats
--- a key held 600 ms, so about ten « e » reached the text before the held-key
--- release, and the two Backspaces erased two of them instead of « ,e ».
---
--- These tests drive the real focus guard in its window mode and the real
--- injector over a fake uinput channel and a clock that a barrier advances by
--- the budget it waits: the held trigger is released long before a desktop
--- would repeat it, every key pressed is released, and an expansion waits on
--- no focus query at all once the worker left one unanswered (each expansion
--- used to wait three times the output budget, three seconds, by eye).
--- ==============================================================================

local helpers = require("tests.helpers")

local KEY_E = 18
local KEY_J = 36
local KEY_BACKSPACE = 14
local KEY_COMMA = 51

-- KDE Plasma's default autorepeat delay: a key held this long repeats.
local DESKTOP_REPEAT_DELAY_MS = 600

--- A window-mode guard over a watch that never answers: each barrier waits
--- its whole budget on the shared clock, as the real worker's does.
--- @param clock table { now = ms }
--- @return table owner The window-mode output owner of the expansion.
--- @return table waits The budgets the barriers were asked for.
local function window_owner(clock)
	local waits = {}
	local listener
	local watch = {
		on_change = function(fn) listener = fn end,
		invalidate = function() if listener then listener(nil) end end,
		pump = function() end,
		barrier = function(budget_ms)
			local waited = budget_ms or require("core.timing.engine.timings").ms("privacy", "focus_barrier_timeout_ms")
			waits[#waits + 1] = waited
			clock.now = clock.now + waited
			return nil
		end,
		authority = function() return "unanswered" end,
		-- The real worker's non-waiting read: nothing ever answers.
		poll = function() return nil, false end,
		answered = function() return false end,
	}
	local epoch = 0
	local guard = require("modules.keystats.focus_guard").new({
		watch = watch, retry_ms = 1000, settle_ms = 250,
		detector = {
			invalidateFocus = function() epoch = epoch + 1; return epoch end,
			currentEpoch = function() return epoch end,
			publishFocus = function(_, current) return current == epoch end,
			isSecureField = function() return true end,
		},
		keystats = {
			set_secure_field = function() end,
			is_context_protected = function() return false end,
		},
		now_ms = function() return clock.now end,
		capture_context_async = function() return { is_settled = function() return false end, cancel = function() return true end } end,
		publish_context = function() return true, false end,
		window_policy = function() return true end,
	})
	local allowed, mode = guard.text_automation()
	helpers.assert_true(allowed and mode == "window", "the KDE Wayland session types in the window mode")
	local owner = guard.capture_text_owner()
	helpers.assert_true(owner ~= nil, "the window mode retains an output owner")
	-- The key that fired is typed now: only the expansion's own waits count.
	for index = #waits, 1, -1 do waits[index] = nil end
	clock.now = 0
	return owner, waits
end

--- Loads the injector over a hook holding the key it forwarded and a
--- recording uinput channel stamped by the clock.
--- @param clock table { now = ms }
--- @param held_code integer|nil The forwarded key still down (KEY_E by default).
local function load(clock, held_code)
	local real_hook = package.loaded["platform.input.keyboard_hook"]
	held_code = held_code or KEY_E
	local held = { held_code }
	package.loaded["platform.input.keyboard_hook"] = {
		held_text_modifier_codes = function() return {} end,
		held_shortcut_modifier_codes = function() return {} end,
		held_forwarded_keys = function() return held end,
	}
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test({
		["j"] = { keycode = KEY_J, level = 1, mods = {} },
		["e"] = { keycode = KEY_E, level = 1, mods = {} },
		[","] = { keycode = KEY_COMMA, level = 1, mods = {} },
	})
	local channel = { emitted = {} }
	channel.is_open = function() return true end
	channel.emit = function(code, value)
		channel.emitted[#channel.emitted + 1] = { code = code, value = value, at = clock.now }
		if code == held_code and value == 0 then held = {} end
		return true
	end
	channel.sync = function() return true end
	package.loaded["hotstrings.engine.injector"] = nil
	local injector = require("hotstrings.engine.injector")
	injector._set_uinput(channel)
	injector._set_nanosleep_for_test(function() end)
	return injector, channel, function()
		package.loaded["platform.input.keyboard_hook"] = real_hook
		package.loaded["hotstrings.engine.injector"] = nil
	end
end

helpers.describe("injector: a window-mode expansion releases its trigger at once (window-held-trigger)", function()
	helpers.it("types ,e as je without holding the e for the desktop to repeat (window-held-trigger)", function()
		local clock = { now = 0 }
		local injector, channel, restore = load(clock)
		local owner, waits = window_owner(clock)
		local ok, result = pcall(injector.inject, 2, "je", false, nil, owner)
		restore()
		helpers.assert_true(ok and type(result) == "table" and result.ok == true,
			"the expansion commits: " .. tostring(ok and result and result.error or result))
		local release, erase = nil, nil
		for index, event in ipairs(channel.emitted) do
			if not release and event.code == KEY_E and event.value == 0 then release = index end
			if not erase and event.code == KEY_BACKSPACE and event.value == 1 then erase = index end
		end
		helpers.assert_true(release ~= nil and erase ~= nil and release < erase,
			"the forwarded e is released before the first erase")
		helpers.assert_true(channel.emitted[release].at < DESKTOP_REPEAT_DELAY_MS,
			string.format("the e was held %d ms by the expansion's focus waits (%s ms); the desktop repeats it at %d ms",
				channel.emitted[release].at, table.concat(waits, "+"), DESKTOP_REPEAT_DELAY_MS))
		-- Every key the expansion pressed it released, in order: « je » and the erase.
		local down, typed = {}, {}
		for _, event in ipairs(channel.emitted) do
			if event.value == 1 then
				helpers.assert_true(not down[event.code], "no key is pressed twice without a release: " .. event.code)
				down[event.code] = true
				typed[#typed + 1] = event.code
			elseif event.value == 0 then
				down[event.code] = nil
			else
				helpers.assert_true(false, "the injector emits no autorepeat event (value " .. tostring(event.value) .. ")")
			end
		end
		helpers.assert_eq(next(down), nil, "every key pressed is released")
		-- The whole expansion, from the key-down to its last key: the guard
		-- polls the unanswering worker instead of waiting for it.
		helpers.assert_eq(clock.now, 0, string.format("the expansion waited %d ms on focus queries (%s ms)",
			clock.now, table.concat(waits, "+")))
		helpers.assert_eq(table.concat(typed, ","), table.concat({ KEY_BACKSPACE, KEY_BACKSPACE, KEY_J, KEY_E }, ","),
			"two erases, then j and e")
	end)

	-- The tester's « it backspaces a huge amount of text by itself »: with
	-- « Backspace undoes the last expansion » on, the physical Backspace is
	-- forwarded first, then the undo's injection waited the same one-second
	-- barrier while that Backspace was still down, and KDE autorepeated it.
	helpers.it("undoes je back to ,e without holding the physical Backspace (window-held-backspace)", function()
		local clock = { now = 0 }
		local injector, channel, restore = load(clock, KEY_BACKSPACE)
		local owner = window_owner(clock)
		-- « je » on screen, the forwarded Backspace removed « e »: one more
		-- erase, then the trigger back.
		local ok, result = pcall(injector.inject, 1, ",e", false, nil, owner)
		restore()
		helpers.assert_true(ok and type(result) == "table" and result.ok == true,
			"the undo commits: " .. tostring(ok and result and result.error or result))
		helpers.assert_eq(channel.emitted[1].code, KEY_BACKSPACE)
		helpers.assert_eq(channel.emitted[1].value, 0, "the held physical Backspace is released first")
		helpers.assert_eq(channel.emitted[1].at, 0, "before any focus wait")
		local downs = 0
		for index, event in ipairs(channel.emitted) do
			if event.code == KEY_BACKSPACE and event.value == 1 then
				downs = downs + 1
				local up = channel.emitted[index + 1]
				helpers.assert_true(up ~= nil and up.code == KEY_BACKSPACE and up.value == 0,
					"every injected Backspace is released by the next event")
			end
			helpers.assert_true(event.value ~= 2, "no autorepeat event is injected")
		end
		helpers.assert_eq(downs, 1, "the erase never exceeds what the undo asked for")
		helpers.assert_eq(clock.now, 0, "the undo waited " .. clock.now .. " ms on focus queries")
	end)
end)
