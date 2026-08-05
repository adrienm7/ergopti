--- tests/fakes/init.lua

--- ==============================================================================
--- MODULE: In-Memory Adapters
--- DESCRIPTION:
--- Test doubles for the driver's adapter boundary: an in-memory stand-in for
--- each port that touches the outside world, so a module that depends on one can
--- be tested without a keyboard, a device node, a shell or a display.
---
--- WHY A REGISTRY AND NOT A STUB PER TEST:
--- Stubs written per test drift from the thing they stand for, and the drift is
--- invisible: the test keeps passing while the real adapter's contract moves
--- underneath it. This driver has been bitten by that repeatedly — a bridge test
--- that spoke a protocol the page never used, a gesture suite green against a
--- recogniser nothing fed, a stub whose `hs.keycodes` lacked the one function the
--- module called.
---
--- `tests/unit/meta/test_fakes_match_adapters.lua` is what makes these
--- trustworthy: it asserts every function the REAL adapter exports exists on the
--- fake. A fake that falls behind fails the suite instead of quietly testing a
--- contract nobody has.
---
--- WHAT A FAKE IS AND IS NOT:
--- It records what it was asked to do and answers plausibly. It does not
--- simulate the kernel. A fake uinput writer proves a module emitted the right
--- codes in the right order; only `tests/hardware/` can say the kernel accepted
--- them, and the two are complementary rather than alternatives.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Output devices ===================
-- =============================================
-- =============================================

--- An in-memory uinput writer.
---
--- Records every (code, value) pair so a caller can assert the ORDER, which is
--- where synthetic chords go wrong: releasing a modifier before the key it
--- modifies leaves the application seeing a bare keystroke.
--- @param opts table|nil { available = boolean, open_fails = boolean }
--- @return table
function M.uinput_writer(opts)
	opts = opts or {}
	local fake = { events = {}, opened = false, closed = false }

	function fake.is_available() return opts.available ~= false end
	function fake.open()
		if opts.open_fails then return false end
		fake.opened = true
		return true
	end
	function fake.close() fake.closed = true ; fake.opened = false ; return true end
	function fake.is_open() return fake.opened end
	function fake.emit(code, value)
		fake.events[#fake.events + 1] = { code = code, value = value }
		return true
	end
	function fake.encode_event(ev_type, code, value) return { ev_type, code, value } end
	function fake.encode_setup() return "" end
	function fake.use_ffi_backend() return true end
	function fake._set_backend() end
	function fake._reset_backend() end

	--- The codes pressed, in order, ignoring releases.
	--- @return table
	function fake.pressed()
		local out = {}
		for _, e in ipairs(fake.events) do
			if e.value == 1 then out[#out + 1] = e.code end
		end
		return out
	end

	return fake
end

--- An in-memory evdev reader that replays a scripted event list.
--- @param opts table|nil { events = table, open_fails = boolean }
--- @return table
function M.evdev_reader(opts)
	opts = opts or {}
	local fake = {
		queued = opts.events or {},
		cursor = 0,
		open_slots = {},
		grabbed = {},
		KEYBOARD = "keyboard",
		POINTER = "pointer",
		TOUCHPAD = "touchpad",
	}

	function fake.is_available() return true end
	function fake.open(path, slot)
		if opts.open_fails then return false end
		fake.open_slots[slot or fake.KEYBOARD] = path
		return true
	end
	function fake.close(slot) fake.open_slots[slot or fake.KEYBOARD] = nil ; return true end
	function fake.is_open(slot) return fake.open_slots[slot or fake.KEYBOARD] ~= nil end
	function fake.device_path(slot) return fake.open_slots[slot or fake.KEYBOARD] end
	function fake.grab(slot) fake.grabbed[slot or fake.KEYBOARD] = true ; return true end
	function fake.ungrab(slot) fake.grabbed[slot or fake.KEYBOARD] = nil ; return true end
	function fake.is_grabbed(slot) return fake.grabbed[slot or fake.KEYBOARD] == true end
	function fake.wait_readable() return fake.cursor < #fake.queued end
	function fake.read_event()
		if fake.cursor >= #fake.queued then return nil end
		fake.cursor = fake.cursor + 1
		return fake.queued[fake.cursor]
	end
	function fake.drain(handler, _slot)
		local count = 0
		while true do
			local event = fake.read_event()
			if not event then break end
			count = count + 1
			handler(event)
		end
		return count
	end
	function fake.use_ffi_backend() return true end
	function fake._set_backend() end
	function fake._reset_backend() end

	return fake
end




-- =============================================
-- =============================================
-- ======= 2/ The outside world ================
-- =============================================
-- =============================================

--- A shell runner that records commands and answers from a scripted table.
---
--- Never executes anything. A test that shelled out for real would touch the
--- developer's session and prove nothing about the code under test.
--- @param opts table|nil { answers = { [pattern] = string }, commands = table }
--- @return table
function M.shell_runner(opts)
	opts = opts or {}
	local fake = { commands = {}, answers = opts.answers or {} }

	--- @param command string
	--- @return string
	local function answer_for(command)
		for pattern, value in pairs(fake.answers) do
			if command:find(pattern) then return value end
		end
		return ""
	end

	function fake.quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
	function fake.run(command) fake.commands[#fake.commands + 1] = command ; return true end
	function fake.exec(command)
		fake.commands[#fake.commands + 1] = command
		return answer_for(command)
	end
	function fake.exec_line(command)
		return (fake.exec(command):gsub("%s+$", ""))
	end
	function fake.has_command(name) return fake.answers["command:" .. name] ~= nil end
	function fake.heredoc_token() return "EOF_FAKE" end
	function fake.with_stdin(command) return command end
	function fake.exec_stdin(command) return fake.exec(command) end
	function fake.with_exact_stdin(command) return command end
	function fake.exec_exact_stdin(command) return fake.exec(command) end
	function fake._set_runner() end
	function fake._reset_runner() end

	return fake
end

--- Key/value storage held in a table.
--- @param opts table|nil { initial = table, writes_fail = boolean }
--- @return table
function M.storage(opts)
	opts = opts or {}
	local fake = { values = {} }
	for k, v in pairs(opts.initial or {}) do fake.values[k] = v end

	function fake.set(key, value)
		if opts.writes_fail then return false end
		fake.values[key] = value
		return true
	end
	function fake.get(key, default_value)
		local stored = fake.values[key]
		if stored == nil then return default_value end
		return stored
	end
	function fake.delete(key) fake.values[key] = nil ; return true end
	function fake.has(key) return fake.values[key] ~= nil end
	function fake.keys()
		local out = {}
		for key in pairs(fake.values) do out[#out + 1] = key end
		table.sort(out)
		return out
	end
	function fake.clear() fake.values = {} ; return true end

	return fake
end

--- A clipboard that remembers what was written to it.
--- @param opts table|nil { available = boolean, initial = string }
--- @return table
function M.clipboard(opts)
	opts = opts or {}
	local fake = { contents = opts.initial or "", pastes = 0 }

	function fake.is_available() return opts.available ~= false end
	function fake.read() return fake.contents end
	function fake.write(text) fake.contents = tostring(text) ; return true end
	function fake.paste_text(text)
		-- The real one saves, sets, pastes and restores. What a caller can assert
		-- is that the previous contents came back, so the fake preserves them.
		local previous = fake.contents
		fake.contents = tostring(text)
		fake.pastes = fake.pastes + 1
		fake.contents = previous
		return true
	end

	return fake
end

--- A scheduler whose clock the test advances by hand.
---
--- Timers that fire on a real clock make a suite slow and flaky in the same
--- change. Here nothing fires until `advance` is called, so a test states the
--- passage of time instead of waiting for it.
--- @return table
function M.timer_scheduler()
	local fake = { pending = {}, now = 0, next_id = 0 }

	function fake.after(delay_sec, fn)
		fake.next_id = fake.next_id + 1
		local handle = { id = fake.next_id, at = fake.now + (tonumber(delay_sec) or 0), fn = fn, repeating = false }
		fake.pending[handle.id] = handle
		return handle
	end
	function fake.every(interval_sec, fn)
		fake.next_id = fake.next_id + 1
		local handle = { id = fake.next_id, at = fake.now + (tonumber(interval_sec) or 0), fn = fn,
			repeating = true, interval = tonumber(interval_sec) or 0 }
		fake.pending[handle.id] = handle
		return handle
	end
	function fake.cancel(handle)
		if type(handle) == "table" and handle.id then fake.pending[handle.id] = nil end
		return true
	end
	function fake.cancelAll() fake.pending = {} ; return true end

	--- Moves the clock forward and runs whatever was due.
	--- @param seconds number
	--- @return integer How many callbacks fired.
	function fake.advance(seconds)
		fake.now = fake.now + seconds
		local fired = 0
		-- Collected first: a callback that schedules another timer must not be
		-- run inside the same pass, or a repeating timer loops for ever.
		local due = {}
		for id, handle in pairs(fake.pending) do
			if handle.at <= fake.now then due[#due + 1] = { id = id, handle = handle } end
		end
		table.sort(due, function(a, b) return a.handle.at < b.handle.at end)
		for _, entry in ipairs(due) do
			if entry.handle.repeating then
				entry.handle.at = fake.now + entry.handle.interval
			else
				fake.pending[entry.id] = nil
			end
			entry.handle.fn()
			fired = fired + 1
		end
		return fired
	end

	return fake
end

return M
