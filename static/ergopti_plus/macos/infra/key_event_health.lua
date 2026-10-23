--- infra/key_event_health.lua

--- ==============================================================================
--- MODULE: Key Event Health
--- DESCRIPTION:
--- Counts, for the whole session, how the physical key-downs and key-ups that
--- reach the keymap event taps pair up, how late the taps saw them, and how
--- often the Karabiner lease failed. Only counts, durations and a key class
--- (character or other) are kept: never a key code, a character or any text.
---
--- FEATURES & RATIONALE:
--- 1. Pairing: a key-up with no key-down, a fresh key-down of a key that is
---    still down (its key-up was lost) and a key down for STUCK_MS with no event
---    at all are counted. Each one is evidence of a loss upstream of the taps
---    (a Karabiner reload, a tap outage) or in the driver itself.
--- 2. Long holds: a character key down for LONG_HOLD_MS or more, measured with
---    the window server's own stamps, is what opens the macOS press-and-hold
---    accent popup. Each one is logged with its autorepeat count, whether a rule
---    switch happened while it was down, and how late its key-up reached the
---    taps, so a popup the user did not ask for can be traced to its cause.
--- 3. Late callbacks: an event the taps saw LATE_CALLBACK_MS or more later than
---    the freshest recent events (adapters/event_clock.lua) waited behind the
---    main thread; a late key-up is a key-up every application received late.
--- 4. Off the event tap: recording is table writes, never a timer or a file
---    write; the keymap tap watchdog (every second) and a lease failure call
---    flush(), which writes the queued lines, coalesced, with the totals.
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local Timer        = require("adapters.timer_scheduler")
local EventClock   = require("adapters.event_clock")

local LOG = "key_event_health"

-- A tap callback this late after the event's stamp waited behind the main
-- thread; the window server disables a tap that holds an event about a second.
M.LATE_CALLBACK_MS = 250

-- macOS opens the press-and-hold popup, or starts repeating, after about half
-- a second (the default InitialKeyRepeat is 225 ms to 1 s depending on the user).
M.LONG_HOLD_MS = 500

-- A key with no event at all for this long lost its key-up: a held key repeats.
M.STUCK_MS = 3000

-- Only this many keys can be down at once on a keyboard; a bounded table.
M.MAX_HELD = 32

local NS_PER_MS = 1e6

local _held = {}
local _held_count = 0
local _counts = {}
local _lease_failures = {}
local _pending = {}

--- Clears every counter and held key; tests and a full driver stop use it.
function M.reset()
	_held = {}
	_held_count = 0
	_counts = {
		downs = 0, ups = 0, repeats = 0,
		ups_without_down = 0, downs_without_up = 0, stuck = 0,
		long_holds = 0, long_holds_across_transition = 0,
		late_downs = 0, late_ups = 0, max_late_ms = 0, unclocked = 0, stale_passed = 0,
	}
	_lease_failures = {}
	_pending = {}
end

M.reset()

--- Returns a copy of the session counters.
--- @return table counts Counter name → value, lease failures under `lease`.
function M.counts()
	local copy = {}
	for name, value in pairs(_counts) do copy[name] = value end
	local lease = {}
	for kind, value in pairs(_lease_failures) do lease[kind] = value end
	copy.lease = lease
	return copy
end

--- Renders the session totals as one stable clause.
--- @return string summary
function M.summary()
	local lease_total, lease_parts = 0, {}
	local kinds = {}
	for kind in pairs(_lease_failures) do kinds[#kinds + 1] = kind end
	table.sort(kinds)
	for _, kind in ipairs(kinds) do
		lease_total = lease_total + _lease_failures[kind]
		lease_parts[#lease_parts + 1] = string.format("%s=%d", kind, _lease_failures[kind])
	end
	return string.format(
		"session totals: %d key-down(s), %d key-up(s), %d key-up(s) without key-down,"
		.. " %d key-down(s) without key-up, %d key(s) stuck over %.1f s,"
		.. " %d character key(s) held %d ms or more (%d across a rule switch),"
		.. " %d key-down(s) and %d key-up(s) seen %d ms or more late (max %.0f ms),"
		.. " %d late key event(s) passed untouched, %d Karabiner lease failure(s)%s",
		_counts.downs, _counts.ups, _counts.ups_without_down,
		_counts.downs_without_up, _counts.stuck, M.STUCK_MS / 1000,
		_counts.long_holds, M.LONG_HOLD_MS, _counts.long_holds_across_transition,
		_counts.late_downs, _counts.late_ups, M.LATE_CALLBACK_MS, _counts.max_late_ms,
		_counts.stale_passed, lease_total, #lease_parts > 0 and (" (" .. table.concat(lease_parts, ", ") .. ")") or "")
end

--- Writes every line queued since the last flush. Never call it from an event
--- tap: it writes the log.
function M.flush()
	local pending = _pending
	_pending = {}
	if #pending == 0 then return end
	local summary = M.summary()
	for _, entry in ipairs(pending) do
		local log = entry.level == "info" and Logger.info or Logger.warn
		local times = entry.repeats > 1 and string.format(" (%d times)", entry.repeats) or ""
		log(LOG, "%s%s; %s.", entry.text, times, summary)
	end
end

--- Queues one line for the next flush(), coalescing identical texts.
--- @param level string "info" or "warn".
--- @param text string Line without the session totals.
local function queue(level, text)
	for _, entry in ipairs(_pending) do
		if entry.text == text then
			entry.repeats = entry.repeats + 1
			return
		end
	end
	if #_pending >= M.MAX_HELD then return end
	_pending[#_pending + 1] = { level = level, text = text, repeats = 1 }
end

--- Names the class of a key without naming the key.
--- @param character boolean
--- @return string
local function class_name(character)
	return character and "character key" or "non-character key"
end

--- Counts every held key with no event for STUCK_MS once.
--- @param now_ms number Current monotonic time.
local function sweep_stuck(now_ms)
	for _, entry in pairs(_held) do
		if not entry.stuck and now_ms - entry.last_ms >= M.STUCK_MS then
			entry.stuck = true
			_counts.stuck = _counts.stuck + 1
			queue("warn", string.format(
				"A %s stayed down %.1f s with no further event: its key-up was lost before the keymap taps",
				class_name(entry.character), (now_ms - entry.seen_ms) / 1000))
		end
	end
end

--- Records how late one event reached the taps.
--- @param phase string "down" or "up".
--- @param lateness_ms number|nil Callback lateness from adapters/event_clock.lua.
local function note_lateness(phase, lateness_ms)
	if lateness_ms == nil then
		_counts.unclocked = _counts.unclocked + 1
		return
	end
	if lateness_ms < M.LATE_CALLBACK_MS then return end
	if phase == "down" then
		_counts.late_downs = _counts.late_downs + 1
	else
		_counts.late_ups = _counts.late_ups + 1
	end
	if lateness_ms > _counts.max_late_ms then _counts.max_late_ms = lateness_ms end
	queue("warn", string.format(
		"Key events reached the keymap taps %d ms or more late: the main thread held them",
		M.LATE_CALLBACK_MS))
end

--- Records one physical key event seen by a keymap event tap. Safe inside the
--- tap: table writes only, every line is written on a later turn.
--- @param phase string "down" or "up".
--- @param key any Opaque key identity (the key code); never logged.
--- @param autorepeat boolean Whether macOS marked the key-down as a repeat.
--- @param character boolean Whether the key types a character.
--- @param lateness_ms number|nil Callback lateness from adapters/event_clock.lua.
--- @param stamp integer|nil The event's raw stamp from adapters/event_clock.lua.
function M.observe(phase, key, autorepeat, character, lateness_ms, stamp)
	assert(phase == "down" or phase == "up",
		"infra.key_event_health.observe: phase must be 'down' or 'up'")
	if key == nil then return end
	local now_ms = Timer.now_ns() / NS_PER_MS
	note_lateness(phase, lateness_ms)
	local entry = _held[key]
	if phase == "down" then
		if autorepeat == true then
			_counts.repeats = _counts.repeats + 1
			if entry then
				entry.repeats = entry.repeats + 1
				entry.last_ms = now_ms
			end
			sweep_stuck(now_ms)
			return
		end
		_counts.downs = _counts.downs + 1
		if entry then
			_counts.downs_without_up = _counts.downs_without_up + 1
			queue("warn", string.format(
				"A %s was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps",
				class_name(entry.character)))
		elseif _held_count >= M.MAX_HELD then
			sweep_stuck(now_ms)
			return
		else
			_held_count = _held_count + 1
		end
		_held[key] = {
			character = character == true, stamp = stamp, seen_ms = now_ms,
			last_ms = now_ms, repeats = 0, crossed = nil, stuck = false,
		}
		sweep_stuck(now_ms)
		return
	end
	_counts.ups = _counts.ups + 1
	if not entry then
		_counts.ups_without_down = _counts.ups_without_down + 1
		queue("warn", "A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream")
		sweep_stuck(now_ms)
		return
	end
	_held[key] = nil
	_held_count = _held_count - 1
	local hold_ms = EventClock.duration_ms(entry.stamp, stamp) or (now_ms - entry.seen_ms)
	if entry.character and hold_ms >= M.LONG_HOLD_MS then
		_counts.long_holds = _counts.long_holds + 1
		if entry.crossed then
			_counts.long_holds_across_transition = _counts.long_holds_across_transition + 1
		end
		queue("info", string.format(
			"A character key stayed down %.0f ms for macOS (%d autorepeat(s)%s; its key-up reached the taps %s): long enough for the press-and-hold popup",
			hold_ms, entry.repeats,
			entry.crossed and (", across " .. entry.crossed) or "",
			lateness_ms and string.format("%.0f ms late", lateness_ms) or "at an unknown delay"))
	end
	sweep_stuck(now_ms)
end

--- Marks every key held right now as having crossed a rule switch or a tap
--- outage: a long hold or a lost key-up next to it then names its cause.
--- @param cause string Lower-case noun phrase, e.g. "a Karabiner lease fence".
function M.note_transition(cause)
	assert(type(cause) == "string" and cause ~= "",
		"infra.key_event_health.note_transition: cause must be non-empty")
	for _, entry in pairs(_held) do entry.crossed = cause end
end

--- Counts one key event that reached a tap so late that the driver passed it
--- untouched instead of consuming, replaying or answering it.
function M.note_stale_pass()
	_counts.stale_passed = _counts.stale_passed + 1
	queue("warn", "Key events that waited behind the main thread passed untouched: no replay, no expansion")
end

--- Judges one physical key event for a tap that would act on it (run an action,
--- mutate it, answer it): a key that waited behind the main thread may already
--- be in the application, so the tap must let it pass untouched. The event is
--- counted when it is late. Safe inside a tap: table writes only.
--- @param event userdata|table Physical keyDown event.
--- @return boolean pass True when the tap must leave the event alone.
function M.passes_late_event(event)
	local ok, stale = pcall(EventClock.is_stale, event)
	if not ok or stale ~= true then return false end
	M.note_stale_pass()
	return true
end

--- Classifies a lease failure reason without keeping its text.
--- @param reason string Lease failure reason.
--- @return string kind
local function lease_kind(reason)
	local text = tostring(reason)
	if text:find("PONG", 1, true) then return "pong" end
	if text:find("READY", 1, true) then return "ready" end
	if text:find("PAUSED", 1, true) or text:find("RESUMED", 1, true) then return "mode" end
	if text:find("exited", 1, true) or text:find("exit ", 1, true) then return "worker_exit" end
	if text:find("heartbeat", 1, true) then return "heartbeat" end
	return "other"
end

--- Counts one Karabiner lease failure and writes the session totals with it.
--- @param reason string Lease failure reason.
function M.note_lease_failure(reason)
	local kind = lease_kind(reason)
	_lease_failures[kind] = (_lease_failures[kind] or 0) + 1
	M.note_transition("a Karabiner lease fence")
	queue("warn", "A Karabiner lease failed (" .. kind .. ")")
	-- A lease fails from a timer or a task callback, never inside a key tap.
	M.flush()
end

--- Records from a path whose own outcome a diagnostic failure must never change.
--- @param ... any Arguments of M.observe.
--- @return boolean recorded
function M.note(...)
	return (pcall(M.observe, ...))
end

return M
