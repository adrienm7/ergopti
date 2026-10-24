--- modules/keystats/aggregate_walker.lua

--- ==============================================================================
--- MODULE: Aggregate Walker (Linux)
--- DESCRIPTION:
--- The Linux side of the shared keystats walker
--- (_shared/lua/keystats/walker.lua): it feeds one application's buffered
--- character stream to the walk Windows and macOS run, and reads the derived
--- batch out in the shape the Linux writer takes.
---
--- FEATURES & RATIONALE:
--- 1. One walk on three drivers. This file used to hold a third walker that
---    had drifted from the Windows reference the cross-driver corpus pins (a
---    narrower word-separator set, streaks broken by driver output, synthetic
---    corrections not counted as such, typed minutes outside the five-minute
---    slots, a layout counted per keystroke). The shared walker settles each
---    of those once, and this suite replays the same corpus.
--- 2. What only Linux knows arrives as ports. The finger of a keystroke comes
---    from the character (evdev numbers keys unlike the macOS keycodes the
---    catalogue keys on); the hour slot of each keystroke comes from its
---    monotonic stamp plus the wall-clock offset, so no clock is read here; the
---    session cut uses the stamps, because the buffered delays are capped at
---    the pause threshold and only the stamps can tell a five-minute gap.
--- 3. The context outlives the flush. A word, a sequence, a correction, a
---    burst and a session continue across flushes, and `settle` credits what a
---    context still holds once its own gap has passed, or all of it on a new
---    day or at shutdown.
--- ==============================================================================

local M = {}

local Helpers = require("keystats.aggregator_helpers")
local SharedWalker = require("keystats.walker")
local Timings = require("infra.timings")

-- Which finger types which character, from the shared keycode catalogue — the
-- same file the typing heatmap is generated from. Keyed by CHARACTER rather
-- than by keycode because evdev numbers nothing the way the catalogue's macOS
-- keycodes do; a keycode lookup would need a hand-written Linux table.
local FingerMap = require("keystats.finger_map")

-- Milliseconds in a second, for turning a monotonic stamp into the wall-clock
-- hour a keystroke belongs to.
local MS_PER_SECOND = 1000

-- Minutes per slot in the fine-grained activity histogram ("min5").
local MIN5_STEP_MINUTES = 5

--- Reads a file whole.
--- @param path string
--- @return string|nil
local function read_file(path)
	local handle = io.open(path, "r")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- The layout the keyboard hook resolves keystrokes through, or nil. It is a
--- property of the hook that changes only from the menu, so it is read once
--- per walk rather than per keystroke.
--- @return string|nil
local function active_layout()
	local ok_hook, Hook = pcall(require, "adapters.keyboard_hook")
	if ok_hook and type(Hook.get_layout) == "function" then
		local ok_get, name = pcall(Hook.get_layout)
		if ok_get and type(name) == "string" and name ~= "" then return name end
	end
	return nil
end

--- The finger lookup for the physical base the hook reads through. Not the
--- user's typing layout: the question is which key on the board produced the
--- character, and that is what the hook resolved it against.
--- @return table|nil
local function finger_lookup()
	local ok_paths, Paths = pcall(require, "infra.paths")
	if not ok_paths then return nil end
	local path = Paths.shared("data/keycodes/azerty.json")
	if not path then return nil end
	local ok_json, Json = pcall(require, "json")
	if not ok_json then return nil end
	return FingerMap.load(active_layout() or "qwerty", read_file, Json.decode, path)
end

-- The shared walk, with the Linux finger port. The lookup is resolved per
-- keystroke through FingerMap's own per-layout cache.
local Walk = SharedWalker.new({
	timings = {
		max_keystroke_delay_ms = Timings.ms("keystats", "max_keystroke_delay_ms"),
		think_pause_ms = Timings.ms("keystats", "think_pause_ms"),
		burst_gap_ms = Timings.ms("keystats", "burst_gap_ms"),
		session_gap_ms = Timings.ms("keystats", "session_gap_ms"),
		auto_repeat_max_delay_ms = Timings.ms("keystats", "auto_repeat_max_delay_ms"),
	},
	finger_of = function(char)
		local finger = FingerMap.finger_of(finger_lookup(), char)
		if finger == FingerMap.UNKNOWN then return nil end
		return finger
	end,
})

--- Fills the fields of a shared walk context a fresh or recovered one lacks.
--- @param ctx table
--- @return table ctx
local function ensure_context(ctx)
	ctx.cur_word = ctx.cur_word or ""
	ctx.word_err = ctx.word_err == true
	ctx.hist = ctx.hist or {}
	ctx.recent_typing = ctx.recent_typing or {}
	ctx.bs_run_len = ctx.bs_run_len or 0
	ctx.last_was_bs = ctx.last_was_bs == true
	ctx.same_finger_run = ctx.same_finger_run or 0
	ctx.same_hand_run = ctx.same_hand_run or 0
	return ctx
end




-- =========================================
-- =========================================
-- ======= 1/ Walking ======================
-- =========================================
-- =========================================

--- Replays one application's buffered stream into the derived batch.
---
--- @param events table Array of { char, delay_ms, meta } as the keystats buffers them.
--- @param date_str string "YYYY-MM-DD".
--- @param app string Application identifier.
--- @param batch table|nil An existing batch to add to; a fresh one when absent.
--- @param clock table|nil { times = {monotonic_ms…}, wall_offset_ms = n } to place
---        keystrokes on the wall clock. Absent means the time-of-day tables are
---        skipped rather than filled with a guess.
--- @param ctx table|nil The application's walk context (see M.settle), carried
---        from the previous flush and updated in place. Without it, everything
---        still open is credited when the stream ends.
--- @return table The batch.
function M.walk(events, date_str, app, batch, clock, ctx)
	batch = batch or Helpers.new_batch()
	if type(events) ~= "table" then return batch end
	-- Nothing continues across midnight: what the context still holds belongs
	-- to the day it was typed on.
	if ctx and ctx.date and ctx.date ~= date_str then M.settle(ctx, nil, batch, true) end
	local walk_ctx = ensure_context(ctx or {})

	local times = type(clock) == "table" and type(clock.times) == "table" and clock.times or nil
	local offset = type(clock) == "table" and tonumber(clock.wall_offset_ms) or 0

	--- The hour and five-minute slot of one keystroke, from its stamp.
	local function slot_of(index)
		local monotonic = times and tonumber(times[index])
		if not monotonic then return nil end
		local seconds = math.floor((monotonic + offset) / MS_PER_SECOND)
		local hour = os.date("%H", seconds)
		local minute = tonumber(os.date("%M", seconds)) or 0
		return {
			hour = hour,
			min5 = string.format("%s:%02d", hour, math.floor(minute / MIN5_STEP_MINUTES) * MIN5_STEP_MINUTES),
		}
	end

	-- The real gap since the previous manual keystroke, for the session cut.
	local gaps, last_time = {}, walk_ctx.last_time
	for index, event in ipairs(events) do
		local meta = type(event[3]) == "table" and event[3] or {}
		local stamp = times and tonumber(times[index]) or nil
		if not (meta.s == true or meta.s == 1) and stamp then
			local delay = tonumber(event[2]) or 0
			gaps[index] = last_time and math.max(delay, stamp - last_time) or delay
			last_time = stamp
		end
	end

	Walk.walk_typing(batch, walk_ctx, { app = app, date = date_str, events = events, layout = active_layout() },
		slot_of, function(index, delay) return gaps[index] or delay end)

	if ctx then
		ctx.date, ctx.app, ctx.last_time = date_str, app, last_time
		return batch
	end
	-- The stream ends mid-word far more often than not. Without a context the
	-- tail is recorded rather than discarded: the word, the correction, the
	-- burst and the session still open are credited now.
	Walk.settle(batch, walk_ctx, date_str, app, nil, true)
	return batch
end

--- Credits what a walk context holds once it has provably ended.
---
--- The rules are the shared walk's own, applied to the time elapsed since the
--- last keystroke instead of to the next one. `force` ends everything, for a
--- shutdown or a new day.
--- @param ctx table A context M.walk filled; updated in place.
--- @param now_ms number|nil Monotonic milliseconds now; unknown judges nothing.
--- @param batch table|nil A batch to add to; created only when a row is credited.
--- @param force boolean|nil End everything regardless of time.
--- @return table|nil The batch.
function M.settle(ctx, now_ms, batch, force)
	if type(ctx) ~= "table" or not ctx.date then return batch end
	local date_str, app = ctx.date, ctx.app
	local gap = (type(now_ms) == "number" and type(ctx.last_time) == "number") and now_ms - ctx.last_time or nil
	local target = batch or Helpers.new_batch()
	local credited = Walk.settle(target, ensure_context(ctx), date_str, app, gap, force)
	if force then
		-- Nothing of a finished day or a stopped process continues.
		for key in pairs(ctx) do ctx[key] = nil end
	end
	if batch then return batch end
	return credited and target or nil
end




-- =========================================
-- =========================================
-- ======= 2/ Reading a batch out ==========
-- =========================================
-- =========================================

--- Splits a batch's n-gram tables into per-table, per-app-day maps the writer
--- takes.
---
--- The batch keys rows by "date\1app\1token" because the shared accumulator has
--- to hold several applications at once; the writer takes one application at a
--- time. Undoing that here rather than in the writer keeps the writer's shape
--- the same as its five siblings.
--- @param batch table
--- @return table Array of { table_name, date, app, ngrams }.
function M.batches_for_writer(batch)
	local out = {}
	if type(batch) ~= "table" or type(batch.ngram) ~= "table" then return out end

	for table_name, rows in pairs(batch.ngram) do
		local grouped = {}
		for key, item in pairs(rows) do
			local date_str, app, token = key:match("^([^\1]*)\1([^\1]*)\1(.*)$")
			if date_str and token ~= "" then
				local bucket = grouped[date_str .. "\1" .. app]
				if not bucket then
					bucket = { date = date_str, app = app, ngrams = {} }
					grouped[date_str .. "\1" .. app] = bucket
				end
				-- The delay total travels with the count. Without it every token
				-- reads as free, and "which sequences cost you the most" — the
				-- question the same-finger analysis exists to answer — ranks a
				-- column of zeroes.
				bucket.ngrams[token] = {
					c       = item.c,
					td      = item.td,
					cd      = item.cd,
					e       = item.e,
					sources = item.esrc,
				}
			end
		end
		for _, bucket in pairs(grouped) do
			if next(bucket.ngrams) ~= nil then
				out[#out + 1] = {
					table_name = table_name,
					date       = bucket.date,
					app        = bucket.app,
					ngrams     = bucket.ngrams,
				}
			end
		end
	end
	return out
end

--- Reads the per-app-day aggregate rows out of a batch.
---
--- Returned as one flat array per table rather than as the batch's compound-key
--- maps, because the writer upserts a row at a time and the key it needs is
--- already inside each row.
--- @param batch table
--- @return table One array per aggregate table, keyed by the batch sub-table name.
function M.daily_rows(batch)
	local out = {
		chars_class = {}, errors = {}, hourly = {}, hourly_min5 = {},
		bursts = {}, sessions = {}, app_buckets = {}, ergo = {}, layouts = {},
	}
	if type(batch) ~= "table" then return out end
	-- Every family, the pause buckets included, already holds one row per
	-- schema row: the shared walk keys a bucket by its threshold.
	for name, rows in pairs(out) do
		for _, row in pairs(batch[name] or {}) do
			rows[#rows + 1] = row
		end
	end
	return out
end

return M
