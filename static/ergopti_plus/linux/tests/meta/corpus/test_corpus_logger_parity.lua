--- tests/meta/corpus/test_corpus_logger_parity.lua

--- ==============================================================================
--- MODULE: Logger Parity Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/parity_vectors.json against the code
--- this driver ships: the shared level resolver with this driver's manifest
--- declaration, the shared core's formatter and sink accounting, and the
--- retention rules of core/logger/engine/sink.lua. The macOS and Windows suites
--- replay the same file.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local driver_root = helpers.driver_root()
local shared_root = driver_root .. "/../_shared"

local function read_corpus()
	local file = assert(io.open(shared_root .. "/tests/corpus/logger/parity_vectors.json", "r"),
		"logger parity corpus not found")
	local raw = file:read("*a")
	file:close()
	local decoded = json.decode(raw)
	assert(type(decoded) == "table", "logger parity corpus did not decode into a table")
	return decoded
end

local Core = require("core.logger.engine")
local LevelSetting = require("core.logger.engine.level_setting")
local Sink = require("core.logger.engine.sink")
local entry = require("menu.engine.manifest_reader").find_entry_by_path("script.log_level")

--- Emits one INFO line through the core with a capturing sink and returns its body.
--- @param template string
--- @param argument any
--- @return string
local function emit_body(template, argument)
	local lines = {}
	local armed = Core.repeat_collapsing_enabled()
	if armed then Core.disable_repeat_collapsing() end
	local level = Core.get_level()
	Core.set_level(10)
	Core.reset_dedup()
	Core.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, err = pcall(Core.info, "LogParity", template, argument)
	Core.set_sink(nil)
	Core.set_level(level)
	if armed then Core.enable_repeat_collapsing() end
	assert(ok, err)
	assert(#lines == 1, "exactly one line must reach the sink, got " .. #lines)
	return assert(lines[1]:match("%[INFO%] %[LogParity%] (.*)$"), lines[1])
end

dofile(shared_root .. "/tests/corpus/logger/parity_replay.lua")({
	helpers = helpers,
	corpus = read_corpus(),
	driver = "linux",
	core_path = shared_root .. "/core/logger/engine/init.lua",
	default_level = entry.default,
	resolve_level = function(stored, absent)
		local resolved = LevelSetting.resolve(not absent and stored or nil, entry, Core)
		return resolved.level, resolved.threshold, resolved.refused
	end,
	detailed_log = function(stored, absent)
		local LevelSetting = require("core.logger.engine.level_setting")
		local value = not absent and stored or nil
		return LevelSetting.is_detailed(value, entry, Core), LevelSetting.detailed_toggle_target(value, entry, Core)
	end,
	emit_body = emit_body,
	dated_expired = Sink.dated_log_expired,
	topical_stale = Sink.topical_log_stale,
})
