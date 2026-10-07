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
	-- Reuse the actual Writer's opaque capability/reservation/retirement logic.
	-- Only its syscall port is controlled: no device, kernel ACK or origin exists.
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local driver = assert(source:match("^(.*)/tests/fakes/init.lua$"))
	local fake = assert(loadfile(driver .. "/adapters/uinput_writer.lua"))()
	fake.events, fake.opened, fake.closed, fake.test = {}, false, false, {}
	local pending
	local function uint(bytes, at, count)
		local value = 0
		for index = count - 1, 0, -1 do value = value * 256 + bytes:byte(at + index) end
		return value
	end
	local backend = {
		open = function() if opts.open_fails then return nil, "controlled open refusal" end return 1 end,
		ioctl = function() return true end,
		close = function() fake.closed = true; fake.opened = false; pending = nil; return true end,
		write = function(_, bytes)
			if #bytes ~= 24 then return false end
			local kind, code, value = uint(bytes, 17, 2), uint(bytes, 19, 2), uint(bytes, 21, 4)
			if kind == 1 then pending = { code = code, value = value }; return true end
			if kind ~= 0 or code ~= 0 or not pending then return false end
			local row = pending; pending = nil
			if opts.on_emit and opts.on_emit(row.code, row.value) ~= true then return false end
			fake.events[#fake.events + 1] = row
			return true
		end,
	}
	fake._set_backend(backend)
	local open, close = fake.open, fake.close
	function fake.is_available() return opts.available ~= false end
	function fake.use_ffi_backend() return true end -- Retains the controlled backend; never loads native syscalls.
	function fake.open()
		local opened, reason = open()
		fake.opened = opened == true
		if opened then fake.closed = false end
		return opened, reason
	end
	function fake.close()
		local closed = close()
		if closed then fake.closed = true; fake.opened = false end
		return closed
	end

	--- The codes pressed, in order, ignoring releases.
	--- @return table
	function fake.test.pressed()
		local out = {}
		for _, e in ipairs(fake.events) do
			if e.value == 1 then out[#out + 1] = e.code end
		end
		return out
	end
	return fake
end

--- An in-memory evdev reader that replays a scripted event list.
--- @param opts table|nil { events?, open_fails?, pressed_keys?, active_leds?, drain_status?, drain_reason? }
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

	-- Scripted table rows/held sets are not native Reader-origin receipts.
	-- Refuse that optional protocol explicitly; ordinary callback replay remains.
	function fake.capture_event() return nil end
	function fake.event_current() return false end
	function fake.event_view() return nil end
	function fake.source_current() return false end
	function fake.capture_source_owner() return nil end
	function fake.source_owner_current() return false end
	function fake.retire_source() return false end
	function fake.capture_pressed_keys() return nil end
	function fake.pressed_keys_current() return false end
	function fake.pressed_keys_view() return nil end
	function fake.has_native_origin_debt() return false end

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
	function fake.pressed_keys(slot, max_code)
		if type(opts.pressed_keys) == "function" then return opts.pressed_keys(slot, max_code) end
		return opts.pressed_keys or {}
	end
	function fake.active_leds(slot, max_code)
		if type(opts.active_leds) == "function" then return opts.active_leds(slot, max_code) end
		return opts.active_leds or {}
	end
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
		if opts.drain_status then return count, opts.drain_status, opts.drain_reason end
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
	-- Delegated, never re-implemented. This one is a pure predicate with no shell
	-- contact, and a fake that answered differently from the real validator would
	-- let a test pass on an argv that production refuses -- the exact failure the
	-- double is supposed to rule out (keylogger-worker-timings-must-be-strings).
	fake.validate_spawn_args = require("adapters.shell_runner").validate_spawn_args
	function fake.run(command) fake.commands[#fake.commands + 1] = command ; return true end
	function fake.exec(command)
		fake.commands[#fake.commands + 1] = command
		return answer_for(command)
	end
	function fake.exec_checked(command)
		fake.commands[#fake.commands + 1] = command
		return true, answer_for(command), nil
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
	-- Records the run and answers it with the same canned output, once
	function fake.run_async(executable, args, _, callback)
		local command = executable .. " " .. table.concat(args or {}, " ")
		fake.commands[#fake.commands + 1] = command
		callback({ ok = true, code = 0, stdout = answer_for(command), stderr = "" })
		return { cancel = function() end }
	end
	fake.HAS_ASYNC = true
	function fake._set_runner() end
	function fake._reset_runner() end

	return fake
end

--- A notifier that records what it was asked to show.
---
--- Never reaches a desktop. A test that posted a real notification would put a
--- bubble on the maintainer's screen for every run and prove nothing about the
--- code under test.
--- @param opts table|nil { available = boolean }
--- @return table
function M.notifier(opts)
	opts = opts or {}
	local fake = { sent = {}, available = opts.available ~= false, test = {} }

	function fake.send(message, options)
		options = type(options) == "table" and options or {}
		fake.sent[#fake.sent + 1] = {
			message = message,
			title = options.title,
			level = options.level or "info",
		}
	end

	--- The last message shown, or nil.
	--- @return table|nil
	function fake.test.last()
		return fake.sent[#fake.sent]
	end

	return fake
end

--- Key/value storage held in a table.
--- @param opts table|nil { initial = table, writes_fail = boolean, path = string }
--- @return table
function M.storage(opts)
	opts = opts or {}
	local fake = { values = {} }
	for k, v in pairs(opts.initial or {}) do fake.values[k] = v end

	-- This is an in-memory ownership model, never a native persistence receipt.
	local gates, aliases, generations, receipts, epoch = {}, {}, {}, setmetatable({}, { __mode = "k" }), 0
	local json = require("json")
	local function copy(value)
		if value == nil then return nil end
		local bytes = assert(json.encode(value))
		local cloned = json.decode_lossless(bytes)
		assert(cloned ~= nil and type(cloned) == type(value), "unsupported model value")
		return cloned
	end
	local function equal(a, b)
		return type(a) == type(b) and json.encode(a) == json.encode(b)
	end
	local function cell(key)
		return { present = fake.values[key] ~= nil, value = copy(fake.values[key]) }
	end
	local function cells_equal(a, b)
		return a.present == b.present and (not a.present or equal(a.value, b.value))
	end
	local function current(record)
		for _, key in ipairs(record.keys) do
			if not cells_equal(cell(key), record.expected[key]) or (generations[key] or 0) ~= record.generations[key] then return false end
		end
		return true
	end
	local function authority(owner, receipt)
		local gate, record = gates[owner], receipts[receipt]
		if not gate or gate.busy or not record or not rawequal(record.owner, owner) or not equal(gate.keys, record.keys) then return nil end
		return gate, record
	end
	local function primary_settled(owner)
		if owner.pending == nil then return true end
		if type(owner.pending) ~= "function" then return false end
		local okay, result = pcall(owner.pending)
		return okay and result == false
	end
	function fake.acquire_owned(owner, keys)
		if type(owner) ~= "table" or gates[owner] or type(keys) ~= "table" then return false end
		local count, seen, ordered = 0, {}, {}
		for index in pairs(keys) do if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return false end; count = count + 1 end
		if count == 0 then return false end
		for index = 1, count do
			local key = keys[index]
			if type(key) ~= "string" or key == "" or key:find("\0", 1, true) or seen[key] or aliases[key] then return false end
			seen[key], ordered[index] = true, key
		end
		table.sort(ordered); epoch = epoch + 1
		gates[owner] = { keys = ordered, epoch = epoch, sequence = 0 }
		for _, key in ipairs(ordered) do aliases[key] = owner end
		return true
	end
	function fake.release_owned(owner)
		local gate = gates[owner]
		if not gate or gate.busy or gate.debt ~= nil then return false end
		gate.busy = true; local settled = primary_settled(owner); gate.busy = false
		if not settled then return false end
		for _, key in ipairs(gate.keys) do aliases[key] = nil end
		gates[owner] = nil; return true
	end
	function fake.capture_owned(owner)
		local gate = gates[owner]
		if not gate or gate.busy or gate.debt ~= nil then return nil end
		local okay, snapshot, observed = pcall(function()
			local values, versions = {}, {}
			for _, key in ipairs(gate.keys) do values[key], versions[key] = cell(key), generations[key] or 0 end
			return values, versions
		end)
		if not okay then return nil end
		gate.sequence = gate.sequence + 1; local token = {}
		receipts[token] = { owner = owner, keys = copy(gate.keys), snapshot = snapshot, expected = copy(snapshot),
			generations = observed, epoch = gate.epoch, sequence = gate.sequence }
		return token, copy(snapshot)
	end
	function fake.publish_owned(owner, receipt, updates, backup_path, files)
		local gate, record = authority(owner, receipt)
		if not gate or record.used or record.epoch ~= gate.epoch or record.sequence ~= gate.sequence
			or opts.writes_fail or type(updates) ~= "table" or type(backup_path) ~= "string" or backup_path == ""
			or type(files) ~= "table" or type(files.read_with_status) ~= "function" or type(files.write_if_unchanged) ~= "function" then return false end
		gate.busy = true
		local okay, result = pcall(function()
			local detached = {}
			for key, value in pairs(updates) do
				assert(rawequal(aliases[key], owner) and type(value) == "table" and type(value.present) == "boolean", "invalid owned update")
				assert((value.present and value.value ~= nil) or (not value.present and value.value == nil), "invalid cell")
				detached[key] = copy(value)
			end
			if not current(record) then return false end
			record.used = true
			local bytes = assert(json.encode({ format = "ergopti-owned-storage-model-v1", cells = record.snapshot }))
			if files.write_if_unchanged(backup_path, bytes, { status = "absent" }) ~= true then return false end
			local observed_bytes, status = files.read_with_status(backup_path)
			if status ~= "ok" or observed_bytes ~= bytes or not current(record) then return false end
			for key, value in pairs(detached) do
				if value.present then fake.values[key] = copy(value.value) else fake.values[key] = nil end
				generations[key] = (generations[key] or 0) + 1
				record.generations[key], record.expected[key] = generations[key], cell(key)
			end
			record.updates, record.committed = detached, true; return true
		end)
		gate.busy = false; return okay and result == true
	end
	function fake.restore_owned(owner, receipt)
		local gate, record = authority(owner, receipt)
		if not gate then return false end
		if record.restored or not record.committed then record.restored = true; return true end
		record.pending, gate.debt = true, record
		if opts.writes_fail or not current(record) then return false end
		for key in pairs(record.updates) do
			local before = record.snapshot[key]
			if before.present then fake.values[key] = copy(before.value) else fake.values[key] = nil end
			generations[key] = (generations[key] or 0) + 1
		end
		record.restored, record.pending, gate.debt = true, false, nil; return true
	end
	function fake.pending_owned(owner, receipt)
		local record = receipts[receipt]
		return record ~= nil and rawequal(record.owner, owner) and record.pending == true
	end
	function fake.forget_owned(owner, receipt)
		if type(owner) ~= "table" then return false end
		local record = receipts[receipt]
		if not record then return false end
		if record.forgotten then return rawequal(record.owner_box[1], owner) end
		local gate = gates[owner]
		if not rawequal(record.owner, owner) or record.pending or gate ~= nil or not primary_settled(owner) then return false end
		receipts[receipt] = { forgotten = true, owner_box = setmetatable({ owner }, { __mode = "v" }) }; return true
	end

	-- The store's file, which the configuration backup copies.
	function fake.path() return opts.path or "/fake/ergopti_plus/storage.json" end

	function fake.set(key, value)
		if opts.writes_fail or aliases[key] ~= nil then return false end
		fake.values[key] = value
		generations[key] = (generations[key] or 0) + 1
		return true
	end
	function fake.set_many(values)
		if opts.writes_fail or type(values) ~= "table" then return false end
		for key in pairs(values) do if aliases[key] ~= nil then return false end end
		for key, value in pairs(values) do fake.values[key] = value; generations[key] = (generations[key] or 0) + 1 end
		return true
	end

	function fake.recovery_status()
		return nil
	end
	function fake.get(key, default_value)
		local stored = fake.values[key]
		if stored == nil then return default_value end
		return stored
	end
	function fake.delete(key)
		if opts.writes_fail or aliases[key] ~= nil then return false end
		fake.values[key] = nil
		generations[key] = (generations[key] or 0) + 1
		return true
	end
	function fake.has(key) return fake.values[key] ~= nil end
	function fake.keys()
		local out = {}
		for key in pairs(fake.values) do out[#out + 1] = key end
		table.sort(out)
		return out
	end
	function fake.clear()
		if opts.writes_fail or next(aliases) ~= nil then return false end
		fake.values = {}
		return true
	end

	return fake
end

--- A clipboard that remembers what was written to it.
--- @param opts table|nil { available = boolean, initial = string, selection = string, uri_list = string }
--- @return table
function M.clipboard(opts)
	opts = opts or {}
	local fake = { contents = opts.initial or "", pastes = 0 }

	function fake.is_available() return opts.available ~= false end
	function fake.read() return fake.contents end
	function fake.read_checked()
		if opts.available == false then return false, "", "clipboard unavailable" end
		return true, fake.contents, nil
	end
	function fake.write(text) fake.contents = tostring(text) ; return true end
	-- The PRIMARY selection: what the application published, never written here.
	function fake.read_primary()
		if opts.available == false then return false, "", "clipboard unavailable" end
		return true, opts.primary or "", nil
	end
	function fake.paste_text(text)
		-- The real one saves, sets, pastes and restores. What a caller can assert
		-- is that the previous contents came back, so the fake preserves them.
		local previous = fake.contents
		fake.contents = tostring(text)
		fake.pastes = fake.pastes + 1
		fake.contents = previous
		return true
	end
	-- The copy probe: the selection, the clipboard left as it was.
	function fake.read_selection(emit_combo, sleep_ms)
		if opts.available == false then return false, "", "clipboard unavailable" end
		if type(emit_combo) ~= "function" or type(sleep_ms) ~= "function" then
			return false, "", "invalid_dependencies"
		end
		if emit_combo("ctrl+c") ~= true then return false, "", "copy_chord_failed" end
		if sleep_ms(80) == false then return false, "", "copy_settle_failed" end
		if opts.selection == nil then return false, "", "no_selection" end
		return true, opts.selection, nil
	end
	-- The file manager's copied selection, as the text/uri-list it publishes.
	function fake.read_selection_uri_list(emit_combo, sleep_ms)
		if opts.available == false then return false, "", "clipboard unavailable" end
		if type(emit_combo) ~= "function" or type(sleep_ms) ~= "function" then
			return false, "", "invalid_dependencies"
		end
		if emit_combo("ctrl+c") ~= true then return false, "", "copy_chord_failed" end
		if sleep_ms(80) == false then return false, "", "copy_chord_failed" end
		if opts.uri_list == nil then return false, "", "no_file_selection" end
		return true, opts.uri_list, nil
	end
	function fake.transform_selection(transform, emit_combo, sleep_ms)
		if opts.available == false then return false, "clipboard unavailable" end
		if type(transform) ~= "function" or type(emit_combo) ~= "function"
				or type(sleep_ms) ~= "function" then
			return false, "invalid_dependencies"
		end
		if opts.selection == nil then return false, "no_selection" end
		if emit_combo("ctrl+c") ~= true then return false, "copy_chord_failed" end
		if sleep_ms(80) == false then return false, "copy_settle_failed" end
		local ok, replacement = pcall(transform, opts.selection)
		if not ok or type(replacement) ~= "string" then
			return false, "selection_transform_failed"
		end
		if sleep_ms(30) == false then return false, "paste_chord_failed" end
		if emit_combo("ctrl+v") ~= true then return false, "paste_chord_failed" end
		if sleep_ms(120) == false then return false, "paste_chord_failed" end
		fake.pastes = fake.pastes + 1
		fake.last_pasted = replacement
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
	local fake = { pending = {}, now = 0, next_id = 0, test = {}, HAS_ASYNC = true }

	function fake.activeCount()
		local count = 0
		for _ in pairs(fake.pending) do count = count + 1 end
		return count
	end

	function fake.after(delay_sec, fn)
		fake.next_id = fake.next_id + 1
		local handle = { id = fake.next_id, at = fake.now + (tonumber(delay_sec) or 0),
			fn = fn, repeating = false, armed = true, fired = false }
		fake.pending[handle.id] = handle
		return handle
	end
	function fake.every(interval_sec, fn)
		fake.next_id = fake.next_id + 1
		local handle = { id = fake.next_id, at = fake.now + (tonumber(interval_sec) or 0), fn = fn,
			repeating = true, interval = tonumber(interval_sec) or 0, armed = true, fired = false }
		fake.pending[handle.id] = handle
		return handle
	end
	function fake.cancel(handle)
		if type(handle) == "table" and handle.id then
			fake.pending[handle.id] = nil
			handle.armed = false
			handle.fired = true
		end
		return true
	end
	function fake.cancelAll()
		for _, handle in pairs(fake.pending) do
			handle.armed = false
			handle.fired = true
		end
		fake.pending = {}
		return true
	end

	--- Moves the clock forward and runs whatever was due.
	--- @param seconds number
	--- @return integer How many callbacks fired.
	function fake.test.advance(seconds)
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
				entry.handle.armed = false
				entry.handle.fired = true
			end
			entry.handle.fn()
			fired = fired + 1
		end
		return fired
	end

	return fake
end




-- =============================================
-- =============================================
-- ======= 7/ The Persistence Writer ===========
-- =============================================
-- =============================================

--- An in-memory stand-in for the keylogger's SQLite writer.
---
--- Every export answers plausibly and records what it was handed, so a caller
--- can assert on what would have been persisted without a database — and, more
--- to the point, without a hand-written stub that omits whichever method was
--- added last.
---
--- That omission is not hypothetical. Four separate test files each carried
--- their own literal table of writer methods; adding four functions to the
--- writer broke all four at the CALL, which reads as a bug in the code under
--- test rather than in the double. `test_fakes_match_adapters.lua` covers this
--- one now, so the next method added to the writer fails one parity check
--- instead of scattering nil-call errors across the suite.
---
--- @param opts table|nil { available = boolean } — false to model a machine
---        with no sqlite3, which is the common case in CI.
--- @return table
function M.sqlite_writer(opts)
	opts = opts or {}
	local available = opts.available ~= false
	local system_day_paths = {}
	local fake = {
		typing = {}, hotstrings = {}, shortcuts = {}, app_switches = {},
		app_days = {}, ngrams = {}, scancodes = {},
		chars_class = {}, errors = {}, hourly = {}, hourly_min5 = {},
		app_buckets = {}, bursts = {}, sessions = {}, switches_to = {}, ergo = {},
		titles = {}, layouts = {}, kc_hold = {}, system_days = {},
		categories = {},
		devices = {}, meta = {}, revision = 0, executed = {}, path = nil,
	}

	function fake.is_available() return available end
	function fake.open_db(path) fake.path = path ; return available end
	function fake.close_db() fake.path = nil ; return true end
	function fake.get_db_path() return fake.path end
	function fake.get_revision() return fake.revision end
	function fake.bump_rev() fake.revision = fake.revision + 1 ; return true end
	function fake.register_device(device_id, name, os_name, os_version, signature)
		fake.devices[#fake.devices + 1] = {
			device_id = device_id, name = name, os_name = os_name,
			os_version = os_version, signature = signature,
		}
		return true
	end

	--- Appends every entry of `rows` to `target`, tagged with the device.
	local function collect(target)
		return function(device_id, rows)
			for _, row in ipairs(rows or {}) do
				target[#target + 1] = { device_id = device_id, row = row }
			end
			return true
		end
	end
	fake.insert_typing_events = collect(fake.typing)
	fake.insert_hotstring_events = collect(fake.hotstrings)
	fake.insert_shortcut_events = collect(fake.shortcuts)
	fake.insert_app_switch_events = collect(fake.app_switches)

	function fake.upsert_app_day(device_id, date, app, fields)
		fake.app_days[#fake.app_days + 1] =
			{ device_id = device_id, date = date, app = app, fields = fields }
		return true
	end
	function fake.upsert_ngrams(device_id, date, app, ngrams, table_name)
		fake.ngrams[#fake.ngrams + 1] = {
			device_id = device_id, date = date, app = app, ngrams = ngrams,
			-- Defaulted the way the writer defaults it, so a caller that omits the
			-- name is recorded as having written the table it really would have.
			table_name = table_name or "ngram_chars",
		}
		return true
	end
	function fake.upsert_scancodes(device_id, date, app, scancodes)
		fake.scancodes[#fake.scancodes + 1] =
			{ device_id = device_id, date = date, app = app, scancodes = scancodes }
		return true
	end

	--- Records a single per-app-day aggregate row.
	local function collect_row(target)
		return function(device_id, row)
			target[#target + 1] = { device_id = device_id, row = row }
			return true
		end
	end
	fake.upsert_chars_class = collect_row(fake.chars_class)
	fake.upsert_errors = collect_row(fake.errors)
	fake.upsert_hourly = collect_row(fake.hourly)
	fake.upsert_hourly_min5 = collect_row(fake.hourly_min5)
	fake.upsert_app_bucket = collect_row(fake.app_buckets)
	fake.upsert_burst = collect_row(fake.bursts)
	fake.upsert_session = collect_row(fake.sessions)
	fake.upsert_switch_to = collect_row(fake.switches_to)
	fake.upsert_ergo = collect_row(fake.ergo)
	fake.upsert_title = collect_row(fake.titles)
	fake.upsert_layout = collect_row(fake.layouts)
	fake.upsert_kc_hold = collect_row(fake.kc_hold)
	local record_system_day = collect_row(fake.system_days)
	function fake.upsert_system_day(device_id, row)
		local accepted = record_system_day(device_id, row)
		system_day_paths[#fake.system_days] = fake.path
		return accepted
	end

	function fake.read_system_day(device_id, date)
		if not available or not fake.path or type(device_id) ~= "string" or device_id == ""
			or type(date) ~= "string" or date == "" then return nil, false end
		for index = #fake.system_days, 1, -1 do
			local entry = fake.system_days[index]
			if system_day_paths[index] == fake.path and entry.device_id == device_id and entry.row.date == date then
				local row = { date = date }
				for _, field in ipairs({ "wifi_changes", "space_switches", "battery_sum", "battery_count",
					"audio_muted_ms", "locked_ms", "sleep_ms", "awake_ms", "passive_count", "night_wake_count" }) do
					row[field] = math.floor(tonumber(entry.row[field]) or 0)
				end
				for _, field in ipairs({ "battery_min", "battery_max" }) do
					local value = tonumber(entry.row[field])
					row[field] = value and math.floor(value) or nil
				end
				return row, true
			end
		end
		return nil, true
	end

	function fake.set_app_category(device_id, app_name, category, score)
		fake.categories[#fake.categories + 1] = {
			device_id = device_id, app = app_name, category = category, score = score,
		}
		return true
	end

	function fake.exec_sql(sql) fake.executed[#fake.executed + 1] = sql ; return true end
	function fake.query_rows() return {} end
	function fake.get_meta(key) return fake.meta[key] end
	function fake.set_meta(key, value) fake.meta[key] = value ; return true end

	return fake
end

return M
