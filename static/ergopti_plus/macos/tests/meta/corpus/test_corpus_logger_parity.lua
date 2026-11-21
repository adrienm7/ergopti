--- tests/meta/corpus/test_corpus_logger_parity.lua

--- ==============================================================================
--- MODULE: Logger Parity Corpus Consumer (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/parity_vectors.json against the code
--- this driver ships: Logger.apply_level_setting with this driver's manifest
--- declaration (what init.lua calls at boot), the driver's own dispatch for a
--- failed format, the shared core's sink accounting and the boot purge rules of
--- core/logger/engine/logger.lua. The native worker replays the retention
--- sections in LoggerRetentionParityTests.swift; Windows and Linux replay the
--- same file.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")
local Logger = require("core.logger.engine.logger")

helpers.admit_logger_privacy(Logger)

local shared_root = helpers.driver_root() .. "/../_shared"

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
local entry = require("menu.engine.manifest_reader").find_entry_by_path("script.log_level")

--- Runs `body` with a capturing test sink, the level at DEBUG, a clean dedup
--- streak and repeat collapsing disarmed; restores all of them.
--- @param body function
--- @return table lines Lines the sink received.
local function captured(body)
	local lines = {}
	local armed = Core.repeat_collapsing_enabled()
	if armed then Core.disable_repeat_collapsing() end
	local level = Logger.current_level
	Logger.current_level = Logger.LEVELS.DEBUG
	Core.reset_dedup()
	Logger.set_sink(function(line) lines[#lines + 1] = line end)
	local ok, err = pcall(body)
	Logger.set_sink(nil)
	Logger.current_level = level
	if armed then Core.enable_repeat_collapsing() end
	assert(ok, err)
	return lines
end

dofile(shared_root .. "/tests/corpus/logger/parity_replay.lua")({
	helpers = helpers,
	corpus = read_corpus(),
	driver = "macos",
	core_path = shared_root .. "/core/logger/engine/init.lua",
	default_level = entry.default,
	resolve_level = function(stored, absent)
		local resolved, applied
		local lines = captured(function()
			resolved = Logger.apply_level_setting(not absent and stored or nil, entry)
			-- The threshold the boot leaves the logger at, read back from the logger
			applied = Logger.current_level
			Logger.current_level = Logger.LEVELS.DEBUG
		end)
		local warned = false
		for _, line in ipairs(lines) do
			if line:find("[WARNING] [logger] Stored log level", 1, true) then warned = true end
		end
		helpers.assert_eq(warned, resolved.refused, "a refused level must be logged, and only then")
		return resolved.level, applied, resolved.refused
	end,
	emit_body = function(template, argument)
		local lines = captured(function() Logger.info("LogParity", template, argument) end)
		assert(#lines == 1, "exactly one line must reach the sink, got " .. #lines)
		return assert(lines[1]:match("%[INFO%] %[LogParity%] (.*)$"), lines[1])
	end,
	dated_expired = Logger._dated_log_expired,
	topical_stale = Logger._topical_log_stale,
})
