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
			if keycode == KEY_CAPSLOCK + XKB_OFFSET and direction == 0 then
				state.caps_ups = (state.caps_ups or 0) + 1
				if state.caps_ups == state.fail_caps_up_at then error("controlled capture rollback release refusal") end
			end
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
		if result == false then return false, { kind = "refused" } end
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

	for _, refusal in ipairs({ "refused", "unavailable" }) do
		helpers.it("(linux-caps-word-unlock-debt) retries only the original pre-output " .. refusal, function()
			local hook, capture = load()
			local calls, refuse = 0, true
			local function emit()
				calls = calls + 1
				if calls > 1 and refuse then return false, { kind = refusal } end
				return true
			end
			drive(hook, { 30 }, function()
				helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
			end)
			helpers.assert_eq(hook.release_caps_word_lock(), false)
			helpers.assert_true(capture.caps_locked(), "the refused unlock leaves the original lock in force")
			helpers.assert_true(hook.caps_word_lock_held(), "the original owner must retain its unsettled unlock")
			local successor_calls = 0
			drive(hook, { 48 }, function()
				helpers.assert_true(hook.isRunning(), "a missing live keyboard must not be the refusal")
				local accepted, reason = hook.lock_caps_for_word(function()
					successor_calls = successor_calls + 1; return true
				end, function() end)
				helpers.assert_eq(accepted, false, "a successor cannot adopt the session's lock as a user's lock")
				helpers.assert_eq(reason, "a CapsWord session already holds CapsLock")
			end)
			helpers.assert_eq(successor_calls, 0)
			refuse = false
			helpers.assert_true(hook.release_caps_word_lock(), "the original emitter can settle its retained unlock")
			helpers.assert_eq(calls, 3, "lock, refused unlock, acknowledged original retry")
			helpers.assert_eq(capture.caps_locked(), false)
			helpers.assert_eq(hook.caps_word_lock_held(), false)
			helpers.assert_true(hook.release_caps_word_lock())
			helpers.assert_eq(calls, 3, "an acknowledged unlock is never emitted twice")
		end)
	end

	for _, refusal in ipairs({ "false", "exception", "truthy string", "foreign exception", "native_failed", "custody_unresolved" }) do
		helpers.it("(linux-caps-word-unlock-debt) never retries an unknown unlock after " .. refusal, function()
			local hook, capture = load()
			local calls = 0
			local function emit()
				calls = calls + 1
				if calls == 1 then return true end
				if refusal == "exception" then error("controlled CapsLock unlock refusal") end
				if refusal == "truthy string" then return "true" end
				if refusal == "foreign exception" then
					error(setmetatable({}, { __tostring = function() error("foreign formatter must not run") end }))
				end
				if refusal == "native_failed" or refusal == "custody_unresolved" then return false, { kind = refusal } end
				return false
			end
			drive(hook, { 30 }, function()
				helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
			end)
			helpers.assert_eq(hook.release_caps_word_lock(), false)
			helpers.assert_true(hook.caps_word_lock_held(), "unknown output keeps its original debt")
			-- Capture reset cannot prove what the desktop received from a partial write.
			helpers.assert_true(capture.reset_state())
			helpers.assert_eq(capture.caps_locked(), false)
			helpers.assert_eq(hook.release_caps_word_lock(), false, "an unlocked capture cannot invent a native ACK")
			helpers.assert_eq(hook.release_caps_word_lock(), false)
			helpers.assert_eq(calls, 2, "another toggle could re-lock a desktop the failed native tap already unlocked")
			helpers.assert_true(hook.caps_word_lock_held())
		end)
	end

	for _, refused in ipairs({ false, true }) do
		helpers.it("(linux-caps-word-reseed-debt) capture reset cannot acknowledge an owned lock: " .. tostring(refused), function()
			local hook, capture = load()
			local calls = 0
			local function emit()
				calls = calls + 1
				if calls > 1 then return false, { kind = "refused" } end
				return true
			end
			drive(hook, { 30 }, function()
				helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
			end)
			if refused then helpers.assert_eq(hook.release_caps_word_lock(), false) end
			helpers.assert_true(capture.reset_state())
			helpers.assert_eq(capture.caps_locked(), false)
			helpers.assert_eq(hook.release_caps_word_lock(), false, "the desktop's original lock has no unlock ACK")
			helpers.assert_true(hook.caps_word_lock_held())
			helpers.assert_eq(calls, refused and 2 or 1, "an unrelated fresh capture cannot authorize a native toggle")
		end)
	end

	helpers.it("(linux-caps-word-unlock-debt) refuses a recursive unlock until its original emission settles", function()
		local hook, capture = load()
		local calls, nested = 0, nil
		local function emit()
			calls = calls + 1
			if calls == 2 then nested = hook.release_caps_word_lock() end
			return true
		end
		drive(hook, { 30 }, function()
			helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
		end)
		helpers.assert_true(hook.release_caps_word_lock())
		helpers.assert_eq(nested, false, "the in-flight unlock is not an acknowledged release")
		helpers.assert_eq(calls, 2, "reentry never emits a second unlock")
		helpers.assert_eq(capture.caps_locked(), false)
		helpers.assert_eq(hook.caps_word_lock_held(), false)
	end)

	helpers.it("(linux-caps-word-unlock-debt) reports a stopped session once while retaining its unlock", function()
		local hook, capture = load()
		local calls, refuse, losses = 0, true, {}
		local function emit()
			calls = calls + 1
			if calls > 1 and refuse then return false, { kind = "refused" } end
			return true
		end
		drive(hook, { 30 }, function()
			helpers.assert_true(hook.lock_caps_for_word(emit, function(reason) losses[#losses + 1] = reason end))
		end)
		hook.stop()
		helpers.assert_true(capture.caps_locked())
		helpers.assert_true(hook.caps_word_lock_held(), "stop cannot erase an unacknowledged desktop lock")
		hook.stop()
		helpers.assert_eq(#losses, 1, "the retired session receives only its first loss notification")
		refuse = false
		helpers.assert_true(hook.release_caps_word_lock())
		helpers.assert_eq(capture.caps_locked(), false)
		helpers.assert_eq(hook.caps_word_lock_held(), false)
		helpers.assert_eq(#losses, 1)
	end)

	for _, kind in ipairs({ "unclassified", "native_failed" }) do
		helpers.it("(linux-caps-word-unlock-debt) retains an unknown initial CapsLock emission: " .. kind, function()
			local hook, capture = load()
			local calls = 0
			drive(hook, { 30 }, function()
				local ok = hook.lock_caps_for_word(function()
					calls = calls + 1
					return false, kind == "native_failed" and { kind = kind } or nil
				end, function() end)
				helpers.assert_eq(ok, false)
			end)
			helpers.assert_eq(capture.caps_locked(), false, "capture rollback is not a desktop receipt")
			helpers.assert_true(hook.caps_word_lock_held())
			helpers.assert_eq(hook.release_caps_word_lock(), false)
			helpers.assert_eq(calls, 1, "a failed initial native tap may already have toggled CapsLock")
		end)
	end

	helpers.it("(linux-caps-word-unlock-debt) retires a proved pre-output initial refusal without an unlock", function()
		local hook, capture = load()
		local calls = 0
		drive(hook, { 30 }, function()
			helpers.assert_eq(hook.lock_caps_for_word(function()
				calls = calls + 1; return false, { kind = "refused" }
			end, function() end), false)
			helpers.assert_eq(hook.caps_word_lock_held(), false)
		end)
		helpers.assert_eq(capture.caps_locked(), false)
		helpers.assert_true(hook.release_caps_word_lock())
		helpers.assert_eq(calls, 1, "a proved no-output refusal needs no compensating toggle")
	end)

	helpers.it("(linux-caps-word-boundary-debt) a failed capture rollback cannot authorize another native toggle", function()
		local hook, capture, state = load()
		local calls = 0
		local function emit()
			calls = calls + 1
			if calls > 1 then return false, { kind = "native_failed" } end
			return true
		end
		drive(hook, { 30 }, function()
			helpers.assert_true(hook.lock_caps_for_word(emit, function() end))
		end)
		state.fail_caps_up_at = 3
		helpers.assert_eq(hook.release_caps_word_lock(), false)
		helpers.assert_true(capture.caps_locked(), "rollback key-down succeeded before its release failed")
		helpers.assert_eq(hook.release_caps_word_lock(), false)
		helpers.assert_eq(calls, 2, "rollback failure must not erase the unknown native outcome")
		helpers.assert_true(hook.caps_word_lock_held())
	end)

	for _, kind in ipairs({ "refused", "native_failed" }) do
		helpers.it("(linux-caps-word-boundary-debt) a modal cannot bypass a pending CapsLock unlock: " .. kind, function()
			local hook, capture = load()
			local Reader = require("adapters.evdev_reader")
			local original_ungrab = Reader.ungrab
			local observed = { ungrabs = 0, dialogs = 0, emits = 0 }
			local refusing = true
			local called, failure = pcall(function()
				drive(hook, { 30 }, function()
					local slot = "keyboard:/dev/input/test"
					helpers.assert_true(Reader.grab(slot))
					helpers.assert_true(hook.lock_caps_for_word(function()
						observed.emits = observed.emits + 1
						if observed.emits > 1 and refusing then return false, { kind = kind } end
						return true
					end, function() end))
					Reader.ungrab = function(...)
						observed.ungrabs = observed.ungrabs + 1
						return original_ungrab(...)
					end
					local function dialog()
						observed.dialogs = observed.dialogs + 1
						helpers.assert_eq(Reader.is_grabbed(slot), false)
						return "dialog value"
					end
					observed.first, observed.reason = hook.while_released(dialog)
					observed.first_dialogs, observed.first_ungrabs = observed.dialogs, observed.ungrabs
					observed.first_grabbed = Reader.is_grabbed(slot)
					refusing = false
					observed.second = hook.while_released(dialog)
				end)
			end)
			Reader.ungrab = original_ungrab
			if not called then error(failure, 0) end
			helpers.assert_eq(observed.first, nil)
			helpers.assert_eq(observed.reason, "CapsWord lock retirement refused")
			helpers.assert_eq(observed.first_dialogs, 0, "the blocked modal cannot receive an unobserved CapsLock press")
			helpers.assert_eq(observed.first_ungrabs, 0, "every original keyboard stays grabbed on refusal")
			helpers.assert_true(observed.first_grabbed)
			if kind == "refused" then
				helpers.assert_eq(observed.second, "dialog value")
				helpers.assert_eq(observed.dialogs, 1)
				helpers.assert_eq(observed.ungrabs, 1)
				helpers.assert_eq(observed.emits, 3, "the original typed refusal permits one acknowledged unlock")
				helpers.assert_eq(capture.caps_locked(), false)
				helpers.assert_eq(hook.caps_word_lock_held(), false)
			else
				helpers.assert_eq(observed.second, nil)
				helpers.assert_eq(observed.dialogs, 0)
				helpers.assert_eq(observed.ungrabs, 0)
				helpers.assert_eq(observed.emits, 2, "an unknown native outcome permits no retry")
				helpers.assert_true(hook.caps_word_lock_held())
			end
		end)
	end

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
