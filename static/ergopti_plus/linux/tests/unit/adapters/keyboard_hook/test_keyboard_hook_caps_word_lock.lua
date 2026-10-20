--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_caps_word_lock.lua

--- ==============================================================================
--- MODULE: The CapsLock A CapsWord Session Holds
--- DESCRIPTION:
--- The Linux CapsWord used to rewrite only the character it handed the
--- hotstring engine: the key had already gone to the application unchanged,
--- so nothing ever arrived in capitals. A session now locks CapsLock on the
--- desktop and in the daemon's capture state, as Windows and macOS light it.
--- These cases drive the real hook over a stateful XKB backend whose CapsLock
--- key locks, and prove what the hook owns: the order of the lock against the
--- forwarded keys, the capitals the capture reads after it, a keymap that
--- refuses to lock, a lock the user already had, the user's own CapsLock, and
--- the unlock on stop, emergency stop, dialog and reseed.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEY_CAPSLOCK = 58
local XKB_OFFSET = 8
local LETTERS = { [30] = "a", [48] = "b", [46] = "c" }
local KEY_1 = 2

--- Loads the hook over a capture backend whose CapsLock key toggles Lock
--- when `locks` is true and is a key of no effect otherwise.
--- @param opts table|nil { locks = boolean (default true), locked = boolean }
--- @return table hook, table capture, table backend_state
local function load(opts)
	opts = opts or {}
	local state = { locks = opts.locks ~= false, initial = opts.locked == true }
	local Capture = helpers.load_module("adapters.xkb_capture")
	Capture._set_backend({
		create = function() return { caps = state.initial } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function(session, keycode)
			local letter = LETTERS[keycode - XKB_OFFSET]
			if letter then return session.caps and letter:upper() or letter end
			if keycode - XKB_OFFSET == KEY_1 then return "1" end
			return nil
		end,
		sym_utf8 = function() return nil end,
		update_key = function(session, keycode, direction)
			if keycode == KEY_CAPSLOCK + XKB_OFFSET and direction == 1 and state.locks then
				session.caps = not session.caps
			end
		end,
		caps_locked = function(session) return session.caps end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		compose_utf8 = function() return nil end,
		compose_reset = function() end,
	})
	assert(Capture.load("keymap", "C"))
	package.loaded["adapters.keyboard_hook"] = nil
	local hook = require("adapters.keyboard_hook")
	return hook, Capture, state
end

--- One key press and release.
--- @param code integer
--- @return table, table
local function tap(code)
	return { type = 1, code = code, value = 1 }, { type = 1, code = code, value = 0 }
end

--- Builds an event list from key codes, each pressed and released.
--- @param codes table
--- @return table events
local function stream(codes)
	local events = {}
	for _, code in ipairs(codes) do
		local down, up = tap(code)
		events[#events + 1] = down
		events[#events + 1] = up
	end
	return events
end

--- Drives `codes` through the hook; `on_char(char, wire)` runs at each typed
--- character with the wire log the desktop received so far.
--- @param hook table
--- @param codes table
--- @param on_char function|nil
--- @return table chars, table wire
local function drive(hook, codes, on_char)
	local chars, wire = {}, {}
	hook._test_drive(stream(codes), {
		liveXkb = true,
		onEmitRaw = function(code, value) wire[#wire + 1] = code .. ":" .. value; return true end,
		onChar = function(char)
			chars[#chars + 1] = char
			if on_char then on_char(char, wire) end
		end,
	}, true)
	return chars, wire
end

--- An emitter that writes the CapsLock tap into the same wire log.
--- @param wire_ref table { wire = table|nil } filled once the drive starts.
--- @param result boolean|nil What the emitter answers (true by default).
--- @return function emit, table calls
local function emitter(wire_ref, result)
	local calls = { count = 0 }
	return function()
		calls.count = calls.count + 1
		if wire_ref.wire then wire_ref.wire[#wire_ref.wire + 1] = "capslock" end
		if result == nil then return true end
		return result
	end, calls
end

helpers.describe("keyboard_hook: the CapsLock a CapsWord session holds", function()
	helpers.it("(linux-caps-word-lock) locks CapsLock before the next key and reads capitals until released", function()
		local hook, capture = load()
		local ref, lost = {}, {}
		local emit, calls = emitter(ref)
		local chars, wire = drive(hook, { 30, 48, KEY_1, 46 }, function(char, log)
			ref.wire = log
			if char == "a" then
				helpers.assert_true(hook.lock_caps_for_word(emit, function(reason) lost[#lost + 1] = reason end))
				helpers.assert_true(capture.caps_locked(), "the capture state is locked with the desktop")
			elseif char == "1" then
				helpers.assert_true(hook.release_caps_word_lock())
			end
		end)
		helpers.assert_eq(table.concat(chars), "aB1c", "the letter after the lock is a capital, the digit stays a digit")
		helpers.assert_eq(calls.count, 2, "one CapsLock tap locks, one unlocks")
		helpers.assert_eq(table.concat(wire, ","),
			"30:1,capslock,30:0,48:1,48:0,2:1,capslock,2:0,46:1,46:0",
			"the desktop receives the lock right after the key that asked for it, before the next one")
		helpers.assert_eq(capture.caps_locked(), false)
		helpers.assert_eq(#lost, 0, "a release the session asked for is not a loss")
		helpers.assert_eq(hook.caps_word_lock_held(), false)
	end)

	helpers.it("(linux-caps-word-lock) refuses a keymap whose CapsLock key does not lock, sending the desktop nothing", function()
		local hook, capture = load({ locks = false })
		local ref = {}
		local emit, calls = emitter(ref)
		local refused
		drive(hook, { 30 }, function()
			local ok, reason = hook.lock_caps_for_word(emit, function() end)
			refused = { ok = ok, reason = reason }
		end)
		helpers.assert_eq(refused.ok, false)
		helpers.assert_contains(tostring(refused.reason), "does not toggle Caps Lock")
		helpers.assert_eq(calls.count, 0, "the desktop never receives a key that would do something else")
		helpers.assert_eq(capture.caps_locked(), false)
		helpers.assert_eq(hook.caps_word_lock_held(), false)
	end)

	helpers.it("(linux-caps-word-lock) puts the capture state back when the CapsLock tap cannot be emitted", function()
		local hook, capture = load()
		local ref = {}
		local emit, calls = emitter(ref, false)
		local refused
		local chars = drive(hook, { 30, 48 }, function(char)
			if char == "a" then refused = { hook.lock_caps_for_word(emit, function() end) } end
		end)
		helpers.assert_eq(refused[1], false)
		helpers.assert_contains(tostring(refused[2]), "could not be emitted")
		helpers.assert_eq(calls.count, 1)
		helpers.assert_eq(capture.caps_locked(), false, "the capture must not believe in a lock the desktop never got")
		helpers.assert_eq(table.concat(chars), "ab")
	end)

	helpers.it("(linux-caps-word-lock) rides a CapsLock the user locked and leaves it locked", function()
		local hook, capture = load({ locked = true })
		local ref = {}
		local emit, calls = emitter(ref)
		local chars = drive(hook, { 30, 48 }, function(char)
			if char == "A" then helpers.assert_true(hook.lock_caps_for_word(emit, function() end)) end
			if char == "B" then helpers.assert_true(hook.release_caps_word_lock()) end
		end)
		helpers.assert_eq(table.concat(chars), "AB")
		helpers.assert_eq(calls.count, 0, "the user's lock is never toggled")
		helpers.assert_true(capture.caps_locked(), "the user's CapsLock outlives the session")
	end)

	helpers.it("(linux-caps-word-lock) ends the hold on the user's CapsLock and never toggles it back", function()
		local hook, capture = load()
		local ref, lost = {}, {}
		local emit, calls = emitter(ref)
		drive(hook, { 30, KEY_CAPSLOCK, 48 }, function(char, log)
			ref.wire = log
			if char == "a" then
				helpers.assert_true(hook.lock_caps_for_word(emit, function(reason) lost[#lost + 1] = reason end))
			end
		end)
		helpers.assert_eq(table.concat(lost, ","), "CapsLock pressed")
		helpers.assert_eq(hook.caps_word_lock_held(), false)
		helpers.assert_true(hook.release_caps_word_lock(), "a hold the hook ended releases nothing")
		helpers.assert_eq(calls.count, 1, "only the session's own lock was emitted")
		helpers.assert_eq(capture.caps_locked(), false, "the user's press unlocked it")
	end)

	for _, ending in ipairs({
		{ name = "stop", reason = "keyboard hook stopped", run = function(hook) hook.stop() end },
		{ name = "emergency stop", reason = "emergency keyboard stop",
			run = function(hook) hook.emergency_stop("controlled output failure") end },
	}) do
		helpers.it("(linux-caps-word-lock) unlocks the session's CapsLock on " .. ending.name, function()
			local hook, capture = load()
			local ref, lost = {}, {}
			local emit, calls = emitter(ref)
			drive(hook, { 30 }, function()
				helpers.assert_true(hook.lock_caps_for_word(emit, function(reason) lost[#lost + 1] = reason end))
			end)
			helpers.assert_true(capture.caps_locked())
			ending.run(hook)
			helpers.assert_eq(calls.count, 2, "the unlock goes out before the hook lets go")
			helpers.assert_eq(capture.caps_locked(), false)
			helpers.assert_eq(table.concat(lost, ","), ending.reason)
			helpers.assert_eq(hook.caps_word_lock_held(), false)
		end)
	end

	helpers.it("(linux-caps-word-lock) keeps the session's lock through a reseed from a stale LED", function()
		local hook, capture = load()
		local ref = {}
		local emit = emitter(ref)
		local after
		drive(hook, { 30, 48 }, function(char)
			if char == "a" then
				helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
				-- A SYN_DROPPED resynchronisation rebuilds the state from the LEDs,
				-- which the grab kept dark.
				helpers.assert_true(capture.reset_state())
				helpers.assert_eq(capture.caps_locked(), false)
				helpers.assert_true(hook._seed_caps_lock_for_test("/dev/input/test"))
				after = capture.caps_locked()
			end
		end)
		helpers.assert_eq(after, true, "the reseed must restore the lock the desktop still has")
		helpers.assert_true(hook.release_caps_word_lock())
		helpers.assert_eq(capture.caps_locked(), false)
	end)

	helpers.it("(linux-caps-word-lock) ends the session before a dialog takes the keyboard", function()
		local source = assert(io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "rb"))
		local text = source:read("*a")
		source:close()
		local body = assert(text:match("function M%.while_released%(fn, opts%)(.-)\nend\n"), "while_released is missing")
		local ending = body:find('_locks.end_word(true, "keyboard handed to a dialog")', 1, true)
		local ungrab = body:find("EvdevReader.ungrab", 1, true)
		helpers.assert_true(ending ~= nil and ungrab ~= nil and ending < ungrab,
			"the unlock must go out while the daemon still owns the keyboard")
	end)

	helpers.it("(linux-caps-word-lock) refuses a second hold and a hook that captures nothing", function()
		local hook = load()
		local ok, reason = hook.lock_caps_for_word(function() return true end, function() end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(reason, "the keyboard is not captured")
		local second
		drive(hook, { 30 }, function()
			helpers.assert_true(hook.lock_caps_for_word(function() return true end, function() end))
			second = { hook.lock_caps_for_word(function() return true end, function() end) }
		end)
		helpers.assert_eq(second[1], false)
		helpers.assert_eq(second[2], "a CapsWord session already holds CapsLock")
		helpers.assert_true(hook.release_caps_word_lock())
	end)
end)

return true
