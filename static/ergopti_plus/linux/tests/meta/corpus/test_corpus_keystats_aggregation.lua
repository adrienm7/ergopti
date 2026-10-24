--- tests/meta/corpus/test_corpus_keystats_aggregation.lua

--- ==============================================================================
--- MODULE: Keystats Aggregation Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays the cross-driver aggregation corpus
--- (_shared/tests/corpus/keystats/aggregation_vectors.json) through the Linux
--- production walk entry, modules/keystats/aggregate_walker.walk, with a carried
--- context per application, and checks every expected key with the shared
--- checker the macOS suite runs. The Windows suite replays the same vectors.
---
--- FEATURES & RATIONALE:
--- 1. The production entry, not the shared module directly: the Linux ports
---    (the character finger map, the per-keystroke slot from a monotonic stamp,
---    the stamped session gap) are part of what the corpus must agree with.
--- 2. Each typing entry's timestamp becomes the stamp of all its keystrokes, so
---    the slot ports resolve the hour the vector names in any time zone.
--- 3. Vectors whose events Linux records outside the walk are listed with the
---    reason; the shared checker refuses a skip that names no real vector.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local Corpus = require("test.keystats_aggregation_corpus")
local Walker = helpers.load_module("modules.keystats.aggregate_walker")

local corpus_path = assert(Paths.shared("tests/corpus/keystats/aggregation_vectors.json"))

--- Reads a file whole.
--- @param path string
--- @return string|nil
local function read_file(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

--- Milliseconds of a "YYYY-MM-DD HH:MM:SS.mmm" timestamp on the local clock.
--- @param timestamp string
--- @return number
local function stamp_of(timestamp)
	local y, mo, d, h, mi, s = timestamp:match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
	assert(y, "corpus timestamp is malformed: " .. tostring(timestamp))
	return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) * 1000
end

--- Replays one vector's typing entries through the Linux walk.
--- @param vector table
--- @return table batch, function ctx_of
local function replay(vector)
	local contexts, batch = {}, nil
	local previous_hook = package.loaded["adapters.keyboard_hook"]
	local ok, err = pcall(function()
		for _, entry in ipairs(vector.events) do
			assert(entry.type == "typing", vector.id .. " replays a " .. tostring(entry.type) .. " event")
			-- The layout of an entry is the hook's on Linux.
			package.loaded["adapters.keyboard_hook"] = { get_layout = function() return entry.layout end }
			local events, times = {}, {}
			local stamp = stamp_of(entry.timestamp)
			for index, ev in ipairs(entry.events) do
				events[index] = { ev.char, ev.delay, ev.meta or {} }
				times[index] = stamp
			end
			contexts[entry.app] = contexts[entry.app] or {}
			batch = Walker.walk(events, entry.timestamp:sub(1, 10), entry.app, batch,
				{ times = times, wall_offset_ms = 0 }, contexts[entry.app])
		end
	end)
	package.loaded["adapters.keyboard_hook"] = previous_hook
	if not ok then error(err, 0) end
	return batch, function(app) return contexts[app] end
end

-- Linux records these events outside the typing walk: application and window
-- switches are counted from the switch log in keystats.lua, and hold
-- durations, suggestion counters, focus latency and the machine's day come
-- from the hook and the system sampler.
local OUTSIDE_THE_WALK = "Linux records this event outside the typing walk (keystats.lua and the system sampler)"
local SKIP = {
	app_switch_accumulates_duration = OUTSIDE_THE_WALK,
	window_switch_credits_title_ms = OUTSIDE_THE_WALK,
	system_event_wifi_change = OUTSIDE_THE_WALK,
	system_event_modifier_hold = OUTSIDE_THE_WALK,
	system_event_manifest_increment_hs = OUTSIDE_THE_WALK,
	mixed_batch_typing_and_system = OUTSIDE_THE_WALK,
}

Corpus.register(helpers, {
	corpus = Corpus.load(read_file, Json.decode, corpus_path),
	label = "keystats aggregation corpus — shared readings (Linux)",
	replay = replay,
	skip = SKIP,
})
