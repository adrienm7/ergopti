--- tests/unit/modules/gestures/engine/test_combo_press_order.lua

--- ==============================================================================
--- MODULE: A Chord Is Pressed in the Order a Hand Presses It
--- DESCRIPTION:
--- What `combo_emitter.press` writes to the uinput device, and in what order.
---
--- WHY ORDER IS THE WHOLE THING:
--- A synthesised chord that releases a modifier before the key it modifies leaves
--- the application seeing a BARE keystroke. `ctrl+Right` becomes `Right`: the
--- cursor moves one character instead of one word, the caller sees something
--- happen, and nothing reports an error. That is the classic way a chord
--- half-works, and no parse test can see it — the parse was right in every case.
---
--- WHY THIS COULD NOT BE TESTED BEFORE:
--- It writes to a real device. With the in-memory writer from tests/fakes the
--- events become a list, and a list can be asserted. That is what the adapter
--- boundary is FOR, and it is the first thing to use it.
---
--- WHAT ONLY HARDWARE CAN SAY: whether a compositor acts on the chord. This says
--- what was written; tests/hardware says the kernel accepted it.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

--- Presses a combo against a fake writer and returns everything it wrote.
--- @param combo string
--- @return table events, boolean ok
local function press(combo)
	local writer = Fakes.uinput_writer()
	writer.open()
	package.loaded["adapters.uinput_writer"] = writer

	local Emitter = helpers.load_module("modules.gestures.combo_emitter")
	local ok = Emitter.press(combo)

	package.loaded["adapters.uinput_writer"] = nil
	return writer.events, ok
end

local KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_RIGHT, KEY_TAB = 29, 42, 106, 15




-- =================================================================
-- =================================================================
-- ======= 1/ The order ============================================
-- =================================================================
-- =================================================================

helpers.describe("combo press: the order a hand produces", function()

	helpers.it("holds the modifier across the key it modifies", function()
		local events, ok = press("ctrl+Right")
		helpers.assert_true(ok, "the combo must be emitted")
		helpers.assert_eq(#events, 4, "two presses and two releases")

		helpers.assert_eq(events[1].code, KEY_LEFTCTRL, "ctrl down first")
		helpers.assert_eq(events[1].value, 1)
		helpers.assert_eq(events[2].code, KEY_RIGHT, "then the key")
		helpers.assert_eq(events[2].value, 1)
		helpers.assert_eq(events[3].code, KEY_RIGHT, "the key up before the modifier")
		helpers.assert_eq(events[3].value, 0)
		helpers.assert_eq(events[4].code, KEY_LEFTCTRL, "and the modifier last")
		helpers.assert_eq(events[4].value, 0,
			"releasing ctrl BEFORE Right would leave the application seeing a bare "
				.. "Right: the cursor moves one character instead of one word, and "
				.. "nothing reports an error")
	end)

	helpers.it("releases several modifiers in reverse", function()
		local events = press("ctrl+shift+Tab")
		helpers.assert_eq(#events, 6, "three down, three up")
		helpers.assert_eq(events[1].code, KEY_LEFTCTRL)
		helpers.assert_eq(events[2].code, KEY_LEFTSHIFT)
		helpers.assert_eq(events[3].code, KEY_TAB)
		helpers.assert_eq(events[4].code, KEY_TAB, "the key comes up first")
		helpers.assert_eq(events[5].code, KEY_LEFTSHIFT, "then shift")
		helpers.assert_eq(events[6].code, KEY_LEFTCTRL, "then ctrl — the reverse of the way down")
	end)

	helpers.it("presses a bare key with no modifier events at all", function()
		local events = press("Escape")
		helpers.assert_eq(#events, 2, "one down, one up, and nothing else")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ When it must write nothing ===========================
-- =================================================================
-- =================================================================

helpers.describe("combo press: when it must not write", function()

	helpers.it("writes nothing for a key name it cannot map", function()
		local events, ok = press("ctrl+Insert")
		helpers.assert_true(not ok, "an unmapped name must be refused")
		helpers.assert_eq(#events, 0,
			"and refused BEFORE anything is written: a chord half-emitted leaves the "
				.. "modifier held down, and the user's next keystroke arrives with ctrl "
				.. "on it")
	end)

	helpers.it("writes nothing when the device is not open", function()
		local writer = Fakes.uinput_writer()
		package.loaded["adapters.uinput_writer"] = writer
		local Emitter = helpers.load_module("modules.gestures.combo_emitter")
		local ok = Emitter.press("ctrl+Right")
		package.loaded["adapters.uinput_writer"] = nil

		helpers.assert_true(not ok, "a closed device must refuse")
		helpers.assert_eq(#writer.events, 0,
			"the daemon owns that device's lifetime; opening it here would race the "
				.. "code that closes it")
	end)

	helpers.it("releases partial chord presses after a false return or exception", function()
		for _, throws in ipairs({ false, true }) do
			for fail_at = 1, 4 do
				local events, held = {}, {}
				local previous_writer = package.loaded["adapters.uinput_writer"]
				package.loaded["adapters.uinput_writer"] = {
					is_open = function() return true end,
					emit = function(code, value)
						events[#events + 1] = { code = code, value = value }
						held[code] = value == 1 or nil
						if #events == fail_at then
							if throws then error("synchronization failed after key write") end
							return false
						end
						return true
					end,
				}
				local Emitter = helpers.load_module("modules.gestures.combo_emitter")
				local ok = Emitter.press("ctrl+Right")
				package.loaded["adapters.uinput_writer"] = previous_writer
				helpers.assert_true(not ok)
				helpers.assert_eq(held, {}, "partial chord writes must leave no key held")
				if fail_at == 2 then
					helpers.assert_eq(events[3], { code = KEY_RIGHT, value = 0 })
					helpers.assert_eq(events[4], { code = KEY_LEFTCTRL, value = 0 })
				end
			end
		end
	end)

	helpers.it("releases every held key when an event write fails", function()
		for fail_at = 1, 4 do
			local calls, held = 0, {}
			local writer = {
				is_open = function() return true end,
				emit = function(code, value)
					calls = calls + 1
					if calls == fail_at then return false end
					held[code] = value == 1 or nil
					return true
				end,
			}
			package.loaded["adapters.uinput_writer"] = writer
			local Emitter = helpers.load_module("modules.gestures.combo_emitter")
			local ok = Emitter.press("ctrl+c")
			package.loaded["adapters.uinput_writer"] = nil

			helpers.assert_true(not ok, "event " .. fail_at .. " must reject the chord")
			helpers.assert_eq(held, {},
				"event " .. fail_at .. " must not leave ctrl or C held down")
		end
	end)

end)

-- =================================================================
-- =================================================================
-- ======= 2/ A modifier already down ==============================
-- =================================================================
-- =================================================================

-- A catalogue chord tapped while a modifier is held (CapsLock held as Ctrl,
-- then a left Ctrl tap that pastes) shares one kernel bit per key with that
-- hold. Pressing Ctrl again is dropped by the kernel and releasing it lifted
-- the Ctrl CapsLock still held: every later key under CapsLock lost its Ctrl
-- while the hook still reported it down (held-modifier-tap-2026-09-25).
helpers.describe("combo press: a modifier the hand or a hold already has down", function()

	--- Presses a combo while the hook reports `held` modifier codes down.
	local function press_holding(combo, held)
		local hook = {
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return held end,
		}
		package.loaded["adapters.keyboard_hook"] = hook
		local ok_press, events, ok = pcall(press, combo)
		package.loaded["adapters.keyboard_hook"] = nil
		assert(ok_press, events)
		return events, ok
	end

	local function trail(events)
		local parts = {}
		for _, ev in ipairs(events) do parts[#parts + 1] = ev.code .. ":" .. ev.value end
		return table.concat(parts, " ")
	end

	helpers.it("neither presses nor releases a modifier already down", function()
		local events, ok = press_holding("ctrl+v", { KEY_LEFTCTRL })
		helpers.assert_true(ok)
		helpers.assert_eq(trail(events), "47:1 47:0",
			"releasing Ctrl here would lift the Ctrl a hold still owns")
	end)

	helpers.it("still presses the modifiers the held one does not cover", function()
		local events = press_holding("ctrl+shift+Tab", { KEY_LEFTCTRL })
		helpers.assert_eq(trail(events), "42:1 15:1 15:0 42:0")
	end)

	helpers.it("presses a right-hand-held modifier's left twin normally", function()
		local events = press_holding("ctrl+v", { 97 })
		helpers.assert_eq(trail(events), "29:1 47:1 47:0 29:0",
			"the kernel keeps one bit per key: a held Right Ctrl does not own Left Ctrl")
	end)

end)





-- ===========================================================
-- ===========================================================
-- ======= 4/ Original modifier owners across a chord ========
-- ===========================================================
-- ===========================================================

--- Runs the actual Reader/Hook/Writer/custody with controlled byte ports.
--- Restores every imported module so each case also works alone or in reverse.
--- @param options table|nil Native write refusal or observation hooks.
--- @param body function Receives the source session and actual ComboEmitter.
local function with_owners(options, body)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, detail = pcall(function()
		require("tests.support.modifier_broker_fixture").with_session(options, function(session)
			local combo = helpers.load_module("modules.gestures.combo_emitter")
			body(session, combo)
		end)
	end)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

local function wire_after(session, count)
	local trail = {}
	for index = count + 1, #session.rows do
		local row = session.rows[index]; trail[#trail + 1] = row[1] .. ":" .. row[2]
	end
	return table.concat(trail, " ")
end

helpers.describe("combo press: foreign carrier modifiers retain their original source", function()
	local carriers = {
		{ "Ctrl", { 29 }, "30:1 30:0" },
		{ "Alt", { 56 }, "56:0 29:1 30:1 30:0 29:0 56:1" },
		{ "Ctrl+Shift", { 29, 42 }, "42:0 30:1 30:0 42:1" },
		{ "Super", { 125 }, "125:0 29:1 30:1 30:0 29:0 125:1" },
		{ "Alt+Shift", { 56, 42 }, "42:0 56:0 29:1 30:1 30:0 29:0 56:1 42:1" },
		{ "Super+Shift", { 125, 42 }, "42:0 125:0 29:1 30:1 30:0 29:0 125:1 42:1" },
	}
	for _, case in ipairs(carriers) do
		helpers.it("select-all excludes the " .. case[1] .. " carrier and restores exactly its original owners", function()
			with_owners(nil, function(s, combo)
				for _, code in ipairs(case[2]) do s.queue("a", code, 1, 1) end
				s.pump(); local count = #s.rows
				local before = s.view().down
				local ok, result = combo.press_codes({ 29 }, { 30 }, "select-all carrier")
				helpers.assert_true(ok); helpers.assert_eq(result.kind, "emitted")
				helpers.assert_eq(wire_after(s, count), case[3])
				helpers.assert_eq(s.view().down, before, "only the original exact holders remain down")
				for index = #case[2], 1, -1 do s.queue("a", case[2][index], 0, 2) end
				s.pump(); helpers.assert_eq(s.view().down, {})
			end)
		end)
	end
	for _, pair in ipairs({ { 29, 97 }, { 42, 54 }, { 125, 126 } }) do
		for _, held in ipairs(pair) do
			helpers.it("preserves the requested modifier family while exact side " .. held .. " remains held", function()
				with_owners(nil, function(s, combo)
					s.queue("a", held, 1, 1); s.pump(); local count = #s.rows
					helpers.assert_true(combo.press_codes({ pair[1] }, { 30 }, "requested family"))
					local expected = held == pair[1] and "30:1 30:0"
						or (pair[1] .. ":1 30:1 30:0 " .. pair[1] .. ":0")
					helpers.assert_eq(wire_after(s, count), expected)
					helpers.assert_eq(s.view().down, { held })
					s.queue("a", held, 0, 2); s.pump(); helpers.assert_eq(s.view().down, {})
				end)
			end)
		end
	end
	helpers.it("does not borrow AltGr as the requested ordinary Alt family", function()
		with_owners(nil, function(s, combo)
			s.queue("a", 100, 1, 1); s.pump(); local count = #s.rows
			helpers.assert_true(combo.press_codes({ 56 }, { 30 }, "ordinary Alt"))
			helpers.assert_eq(wire_after(s, count), "100:0 56:1 30:1 30:0 56:0 100:1")
			helpers.assert_eq(s.view().down, { 100 })
			s.queue("a", 100, 0, 2); s.pump(); helpers.assert_eq(s.view().down, {})
		end)
	end)
	for _, phase in ipairs({ "neutralize", "restore" }) do
		for _, throws in ipairs({ false, true }) do
			helpers.it("retires output after " .. phase .. " " .. (throws and "throws" or "refuses") .. " its native ACK", function()
				local armed = false
				with_owners({ fail_sync = function(code, value)
					if armed and code == 56 and value == (phase == "restore" and 1 or 0) then
						if throws then error("controlled modifier synchronization refusal") end
						return true
					end
				end }, function(s, combo)
					s.queue("a", 56, 1, 1); s.pump(); armed = true
					local ok, result = combo.press_codes({ 29 }, { 30 }, "refused modifier ACK")
					helpers.assert_eq(ok, false); helpers.assert_eq(result.kind, "custody_unresolved")
					helpers.assert_eq(s.hook.isRunning(), false)
					helpers.assert_eq(s.writer.is_open(), false, "the original failed output was actually retired")
				end)
			end)
		end
	end
	helpers.it("never restores a carrier whose real source UP arrived during the chord", function()
		local armed, released = false, false
		with_owners({ after_sync = function(s, code, value)
			if armed and not released and code == 30 and value == 1 then
				released = true; s.queue("a", 56, 0, 2); s.pump()
			end
		end }, function(s, combo)
			s.queue("a", 56, 1, 1); s.pump(); armed = true; local count = #s.rows
			helpers.assert_true(combo.press_codes({ 29 }, { 30 }, "retiring source"))
			helpers.assert_true(released)
			helpers.assert_eq(wire_after(s, count), "56:0 29:1 30:1 30:0 29:0")
			helpers.assert_eq(s.view().down, {})
		end)
	end)
	helpers.it("restores the other carrier source after one of two same-code owners releases", function()
		local armed, released = false, false
		with_owners({ after_sync = function(s, code, value)
			if armed and not released and code == 30 and value == 1 then
				released = true; s.queue("a", 56, 0, 2); s.pump()
			end
		end }, function(s, combo)
			s.queue("a", 56, 1, 1); s.queue("b", 56, 1, 1); s.pump(); armed = true; local count = #s.rows
			helpers.assert_true(combo.press_codes({ 29 }, { 30 }, "surviving source"))
			helpers.assert_eq(wire_after(s, count), "56:0 29:1 30:1 30:0 29:0 56:1")
			helpers.assert_eq(s.view().down, { 56 })
			s.queue("b", 56, 0, 3); s.pump(); helpers.assert_eq(s.view().down, {})
		end)
	end)
	helpers.it("refuses a nested producer while restoring the original carrier exactly once", function()
		local armed, nested, inner = false, nil, nil
		with_owners({ after_sync = function(_, code, value)
			if armed and nested == nil and code == 30 and value == 1 then nested = inner.press("Escape") end
		end }, function(s, combo)
			inner = combo; s.queue("a", 56, 1, 1); s.pump(); armed = true; local count = #s.rows
			helpers.assert_true(combo.press_codes({ 29 }, { 30 }, "nested producer"))
			helpers.assert_eq(nested, false)
			helpers.assert_eq(wire_after(s, count), "56:0 29:1 30:1 30:0 29:0 56:1")
			helpers.assert_eq(s.view().down, { 56 })
			s.queue("a", 56, 0, 2); s.pump(); helpers.assert_eq(s.view().down, {})
		end)
	end)
	helpers.it("refuses a foreign modifier on a legacy channel without borrowing another source's cleanup rights", function()
		local saved_writer, saved_hook = package.loaded["adapters.uinput_writer"], package.loaded["adapters.keyboard_hook"]
		local saved_combo = package.loaded["modules.gestures.combo_emitter"]
		local rows = {}
		package.loaded["adapters.uinput_writer"] = { is_open = function() return true end,
			emit = function(code, value) rows[#rows + 1] = { code, value }; return true end }
		package.loaded["adapters.keyboard_hook"] = { held_text_modifier_codes = function() return { 56 } end,
			held_shortcut_modifier_codes = function() return {} end }
		local called, ok, result = pcall(function()
			return helpers.load_module("modules.gestures.combo_emitter").press_codes({ 29 }, { 30 }, "unowned carrier")
		end)
		package.loaded["adapters.uinput_writer"], package.loaded["adapters.keyboard_hook"] = saved_writer, saved_hook
		package.loaded["modules.gestures.combo_emitter"] = saved_combo
		helpers.assert_true(called); helpers.assert_eq(ok, false); helpers.assert_eq(result.kind, "refused")
		helpers.assert_eq(rows, {}, "no modifier UP or replacement is allowed without an exact original owner")
	end)
end)
