--- tests/bench/bench_lua_paths.lua

--- ==============================================================================
--- MODULE: macOS Pure-Lua Path Benchmark
--- DESCRIPTION:
--- Measures the CPU-bound Lua behind the macOS field timings (hotstring load,
--- preferences save, keystats ingest walk, module compilation) off-Mac, under
--- the stubbed Hammerspoon test harness and the shipped fixture data. Native
--- costs (AX, hs.task, canvas, SQLite, Karabiner) are not reproduced here; read
--- the Mac's `Phase summary` lines for those.
---
--- USAGE (from the driver root, POSIX shell; Hammerspoon runs Lua 5.4):
---     lua5.4 tests/bench/bench_lua_paths.lua
---     lua5.4 tests/bench/bench_lua_paths.lua --only=preferences_save --runs=9
---     lua5.4 tests/bench/bench_lua_paths.lua --profile=hotstring_load_warm
---
--- FEATURES & RATIONALE:
--- 1. Realistic fixtures: the four shipped hotstring packs, the generated
---    config_template.toml, and French typing with a pause per sentence.
--- 2. Medians: every workload reports the median, minimum and maximum of N runs
---    in CPU time (os.clock) and, when luv is installed, wall time.
--- 3. Attribution: --profile runs a clock-weighted sampling hook and prints self
---    and inclusive time per function, so C string work is charged to its caller.
--- ==============================================================================

local self_path = debug.getinfo(1, "S").source:gsub("^@", "")
local driver_root = self_path:match("^(.*)/tests/bench/bench_lua_paths%.lua$") or "."
local shared_lua = driver_root .. "/../_shared/lua"
package.path = table.concat({
	driver_root .. "/?.lua", driver_root .. "/?/init.lua",
	shared_lua .. "/?.lua", shared_lua .. "/?/init.lua",
	driver_root .. "/tests/?.lua", driver_root .. "/tests/?/init.lua",
	driver_root .. "/tests/stubs/?.lua", package.path,
}, ";")

local helpers = require("tests.helpers")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

local DEFAULT_RUNS = 7
-- Profiler hook period in VM instructions; small enough to attribute short calls.
local PROFILE_PERIOD = 200
local PROFILE_ROWS = 20
local MS_PER_SECOND = 1000
local NS_PER_MS = 1e6
local HOTSTRINGS_DIR = driver_root .. "/../_shared/modules/hotstrings/"
local CONFIG_TEMPLATE = driver_root .. "/_generated/config_template.toml"
local HOTSTRING_PACKS = {
	{ "magickey", "magickey.toml" },
	{ "autocorrection", "autocorrection.toml" },
	{ "french_magickey", "french/magickey.toml" },
	{ "french_autocorrection", "french/autocorrection.toml" },
}
-- One ingest tick covers this many seconds of typing (keystats.ingest_tick_ms).
local TICK_KEYS = 40
local BACKLOG_ENTRIES, BACKLOG_KEYS = 300, 100
local INLINE_ROWS = 300
local FOLD_CALLS = 100000
local TYPING_TEXT = "Bonjour, je voudrais savoir si la réunion de demain est maintenue. "
	.. "Merci de me confirmer rapidement ! "





-- ============================
-- ============================
-- ======= 2/ Utilities =======
-- ============================
-- ============================

local has_luv, luv = pcall(require, "luv")

--- Reads a whole file.
--- @param path string File path.
--- @return string content
local function read_file(path)
	local handle = assert(io.open(path, "rb"))
	local content = handle:read("a")
	handle:close()
	return content
end

--- Writes a whole file.
--- @param path string File path.
--- @param content string Bytes.
local function write_file(path, content)
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- Returns the middle value of a sorted array.
--- @param values table Sorted numbers.
--- @return number
local function median(values)
	local count = #values
	if count % 2 == 1 then return values[(count + 1) // 2] end
	return (values[count // 2] + values[count // 2 + 1]) / 2
end

--- Runs one workload `runs` times and prints its medians.
--- @param name string Workload name.
--- @param runs number Repetitions.
--- @param prepare function Returns the argument of one run (untimed).
--- @param body function The timed work.
local function measure(name, runs, prepare, body)
	local cpu, wall = {}, {}
	for run = 1, runs do
		local argument = prepare()
		collectgarbage("collect")
		local wall_started = has_luv and luv.hrtime() or nil
		local cpu_started = os.clock()
		body(argument)
		cpu[run] = (os.clock() - cpu_started) * MS_PER_SECOND
		wall[run] = wall_started and (luv.hrtime() - wall_started) / NS_PER_MS or nil
	end
	table.sort(cpu)
	local wall_text = "wall n/a (no luv)"
	if has_luv then
		table.sort(wall)
		wall_text = string.format("wall median %.2f ms max %.2f", median(wall), wall[#wall])
	end
	print(string.format("%-28s runs=%d cpu median %.2f ms (min %.2f max %.2f) %s",
		name, runs, median(cpu), cpu[1], cpu[#cpu], wall_text))
end

--- Runs `body` under a clock-weighted sampling hook and prints the hot functions.
--- @param name string Workload name.
--- @param body function Work to profile.
local function profile(name, body)
	local self_time, inclusive, total = {}, {}, 0
	local last = os.clock()
	debug.sethook(function()
		local now = os.clock()
		local weight = now - last
		last = now
		total = total + weight
		local seen, level = {}, 2
		while true do
			local info = debug.getinfo(level, "Sl")
			if not info then break end
			local key = info.short_src .. ":" .. tostring(info.linedefined)
			if level == 2 then self_time[key] = (self_time[key] or 0) + weight end
			if not seen[key] then
				seen[key] = true
				inclusive[key] = (inclusive[key] or 0) + weight
			end
			level = level + 1
		end
	end, "", PROFILE_PERIOD)
	body()
	debug.sethook()
	for _, view in ipairs({ { "self", self_time }, { "inclusive", inclusive } }) do
		local rows = {}
		for key, weight in pairs(view[2]) do rows[#rows + 1] = { key, weight } end
		table.sort(rows, function(left, right) return left[2] > right[2] end)
		print(string.format("== %s: %s time by function (%.1f ms sampled, hook overhead included)",
			name, view[1], total * MS_PER_SECOND))
		for index = 1, math.min(PROFILE_ROWS, #rows) do
			print(string.format("%6.1f%%  %s", rows[index][2] * 100 / total, rows[index][1]))
		end
	end
end





-- =============================
-- =============================
-- ======= 3/ Workloads ========
-- =============================
-- =============================

package.loaded["infra.logger"] = helpers.make_logger_stub()
local scratch = os.tmpname()
os.remove(scratch)
assert(os.execute("mkdir -p '" .. scratch .. "/toml_cache'"), "cannot create the scratch directory")

--- Builds a fresh registry whose every section is enabled.
--- @return table registry
local function fresh_registry()
	for _, name in ipairs({ "adapters.storage", "modules.keymap.registry", "modules.keymap.registry_groups",
		"modules.keymap.registry_index", "modules.keymap.terminators" }) do
		package.loaded[name] = nil
	end
	local registry = require("modules.keymap.registry")
	registry.is_section_enabled = function() return true end
	local State = require("modules.keymap.state")
	assert(registry.init(State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })))
	return registry
end

--- Loads the four packs the way init.lua does: one deferred sort.
--- @param registry table Fresh registry.
local function load_packs(registry)
	registry.defer_sort()
	for _, pack in ipairs(HOTSTRING_PACKS) do assert(registry.load_toml(pack[1], HOTSTRINGS_DIR .. pack[2])) end
	registry.flush_sort()
end

--- Returns one typing entry of `count` keys opened by a continuity-breaking pause.
--- @param count number Keys.
--- @param pause_ms number Delay of the first key.
--- @return table entry
local function typing_entry(count, pause_ms)
	local events, index = {}, 0
	while #events < count do
		for char in TYPING_TEXT:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			index = index + 1
			events[#events + 1] = { char, index == 1 and pause_ms or 90 + (index * 7) % 60, {} }
			if #events >= count then break end
		end
	end
	return { app = "Mail", timestamp = "2026-10-24 10:00:00.000", events = events }
end

local WORKLOADS = {}
local ORDER = {}

--- Registers one workload.
--- @param name string Workload name.
--- @param setup function Returns prepare, body (called once).
local function workload(name, setup)
	WORKLOADS[name] = setup
	ORDER[#ORDER + 1] = name
end

workload("toml_parse_magickey", function()
	local Reader = require("toml_codec.reader")
	return function() end, function() assert(Reader.parse(HOTSTRINGS_DIR .. "magickey.toml")) end
end)

workload("hotstring_load_warm", function()
	local Cache = helpers.load_with_stubs("adapters.toml_cache")
	Cache.init(scratch .. "/toml_cache")
	require("infra.toml.reader").set_cache_provider(Cache)
	load_packs(fresh_registry())
	return fresh_registry, load_packs
end)

workload("preferences_save", function()
	local Preferences = helpers.load_with_stubs("infra.preferences")
	local path = scratch .. "/config.toml"
	write_file(path, read_file(CONFIG_TEMPLATE))
	local state, status = Preferences.load(path)
	assert(status == "ok", "the template must load")
	local toggles = 0
	return function() end, function()
		toggles = toggles + 1
		state.gestures = toggles % 2 == 0
		assert(Preferences.save(path, state, {}, {}), "save must commit")
	end
end)

workload("inline_parents_300_rows", function()
	local Writer = require("toml_codec.writer")
	local content = read_file(CONFIG_TEMPLATE)
	local rows = {}
	for index = 1, INLINE_ROWS do rows[index] = { section = "bench_" .. index, key = "key", value = true } end
	return function() end, function() assert(Writer.source_inline_scalar_parents(content, rows)) end
end)

workload("trig_lower_100k", function()
	local TextUtils = require("text_utils")
	local words = { "btw", "pr", "jsp", "magickey", "ADN", "cad", "comme", "école", "ça" }
	return function() end, function()
		for index = 1, FOLD_CALLS do TextUtils.trig_lower(words[index % #words + 1]) end
	end
end)

workload("keystats_walk_tick", function()
	package.loaded["modules.keystats.export"] = { get_native_app_category = function() return "Development" end }
	package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return nil end }
	local Aggregator = helpers.load_with_stubs("modules.keystats.aggregator")
	Aggregator.init({ device_id = "bench" })
	local pause = require("modules.keystats.aggregator.core").MAX_KEYSTROKE_DELAY_MS + 1
	local tick = typing_entry(TICK_KEYS, pause)
	local backlog = {}
	for index = 1, BACKLOG_ENTRIES do backlog[index] = typing_entry(BACKLOG_KEYS, pause) end
	WORKLOADS.keystats_walk_backlog = function()
		return function() end, function()
			Aggregator.reset_batch()
			for _, entry in ipairs(backlog) do Aggregator.walk_typing(entry) end
		end
	end
	return function() end, function() Aggregator.reset_batch(); Aggregator.walk_typing(tick) end
end)
ORDER[#ORDER + 1] = "keystats_walk_backlog"

workload("compile_driver_sources", function()
	local sources = {}
	local listing = assert(io.popen("find '" .. driver_root .. "' '" .. shared_lua .. "' -name '*.lua'"
		.. " -not -path '*/tests/*' -not -path '*/test/*' -not -path '*/vendor/*'"))
	for path in listing:lines() do sources[#sources + 1] = { path, read_file(path) } end
	listing:close()
	return function() end, function()
		for _, source in ipairs(sources) do assert(load(source[2], "@" .. source[1])) end
	end
end)





-- =========================
-- =========================
-- ======= 4/ Runner =======
-- =========================
-- =========================

local only, profiled, runs = nil, nil, DEFAULT_RUNS
for _, argument in ipairs(arg or {}) do
	local option, value = argument:match("^%-%-([%w_]+)=(.+)$")
	if option == "only" then only = value
	elseif option == "profile" then profiled = value
	elseif option == "runs" then runs = assert(tonumber(value), "--runs must be a number")
	else error("unknown argument " .. argument .. " (use --only=, --profile=, --runs=)") end
end

for _, name in ipairs(ORDER) do
	if (only == nil and profiled == nil) or only == name or profiled == name then
		if not WORKLOADS[name] then WORKLOADS.keystats_walk_tick() end
		local prepare, body = WORKLOADS[name]()
		if profiled then
			profile(name, function() body(prepare()) end)
		else
			measure(name, runs, prepare, body)
		end
	end
end
os.execute("rm -rf '" .. scratch .. "'")
