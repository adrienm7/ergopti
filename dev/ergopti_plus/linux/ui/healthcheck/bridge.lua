--- ui/healthcheck/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Healthcheck Dashboard
--- DESCRIPTION:
--- Builds the diagnostic snapshot the shared healthcheck page renders, in the
--- canonical shape `_shared/lua/healthcheck/snapshot.lua` declares.
--- Bridge name: "healthcheck"
---
--- WHY THE WINDOW USED TO OPEN EMPTY:
--- This bridge answered with `{ modules = {…}, version, platform, locale }` — a
--- shape of its own invention. The page's `renderHealthcheck` reads
--- `version, sys, uptime_sec, warn_count, err_count, ports_validated,
--- failed_adapters, last_error, recent_issues, pause_state, keylogger, llm,
--- layout, hotstrings, logs, config`, found none of them, and rendered an empty
--- report. Nothing errored on either side: the bridge answered, the page ran,
--- and the window showed nothing — which reads as "the daemon has no diagnostics
--- to give" rather than as two halves speaking different languages.
---
--- The shared module has declared this contract and validated it since it was
--- written, and macOS is the only driver that ever bound it.
---
--- FEATURES & RATIONALE:
--- 1. Every collector is isolated. A diagnostic report exists to be readable
---    when things are broken, so one collector raising must cost its own section
---    and not the whole window.
--- 2. The snapshot is validated before it is sent, and a missing field is logged
---    by name. A report with a silently absent section is worse than a loud one:
---    the reader cannot tell "not measured" from "measured as nothing".
--- 3. Values that this driver genuinely cannot answer are reported as "n/a"
---    rather than as a plausible default. macOS does the same, for the same
---    reason: a fabricated zero is indistinguishable from a real one.
--- ==============================================================================

local M = {}
M.bridge_name = "healthcheck"

local Logger = require("logger.shim")
local LOG = "bridge.healthcheck"

-- Single source of the driver version (never a re-typed literal).
local Version = require("infra.version")
-- The canonical snapshot shape, its uptime formatting and its issue extraction.
local Snapshot = require("healthcheck.snapshot")
local LoggerSink = require("infra.logger_sink")

-- What this driver cannot currently measure. Spelled once so a reader can see
-- at a glance which gaps are deliberate, and so "not measured" never reaches the
-- page as a number that looks measured.
local NOT_AVAILABLE = "n/a"

-- How many WARNING/ERROR lines the report carries. The shared extractor's own
-- default, named here because the page scrolls them and an unbounded list on a
-- bad day is a window that takes seconds to render.
local MAX_RECENT_ISSUES = 100

-- When the daemon started, in seconds. Captured at load rather than read from
-- the process table: /proc/self/stat gives jiffies since boot, which needs the
-- clock tick and the boot time to become an age, and both can be wrong in a
-- container.
local _started_at = os.time()

-- The most recent error worth surfacing, if anything set one.
local _last_error = nil


-- =========================================
-- =========================================
-- ======= 1/ Collectors ===================
-- =========================================
-- =========================================

--- Runs a collector, isolating a failure to its own section.
---
--- A report exists to be readable when things are broken, so one collector
--- raising must not take the window with it. The failure is logged by name and
--- the section comes back nil, which the validator below then reports.
--- @param name string Section name, for the log line.
--- @param fn function Collector.
--- @return table|nil
local function collect(name, fn)
	local ok, value = pcall(fn)
	if not ok then
		Logger.error(LOG, "Healthcheck collector '%s' raised: %s — section omitted.", name, tostring(value))
		return nil
	end
	return value
end

--- The logger's ring buffer, or an empty list when it is unavailable.
--- @return table
local function ring_lines()
	local ok, real = pcall(require, "logger")
	if not ok or type(real) ~= "table" or type(real.ring_buffer_snapshot) ~= "function" then
		return {}
	end
	local ok_snapshot, lines = pcall(real.ring_buffer_snapshot)
	return (ok_snapshot and type(lines) == "table") and lines or {}
end

--- Whether the daemon is paused, and what answered.
--- @param state table Daemon state.
--- @return table
local function collect_pause_state(state)
	if state.engine and type(state.engine.is_paused) == "function" then
		return { is_paused = not not state.engine.is_paused(), source = "engine" }
	end
	-- Reported as unknown rather than as false. "Not paused" and "nobody could
	-- say" are different answers, and only one of them should reassure a reader.
	return { is_paused = false, source = "engine (no is_paused)" }
end

--- Live keylogger figures.
--- @param state table Daemon state.
--- @return table
local function collect_keylogger(state)
	local summary = {
		enabled = NOT_AVAILABLE,
		wpm = NOT_AVAILABLE,
		events_session = NOT_AVAILABLE,
		privacy_hits = NOT_AVAILABLE,
		today_log = "",
		errors_log = "",
		notes = "High-severity lines are also written to ErgoptiPlus_errors_*.log.",
	}
	local keylogger = state.keylogger
	if not keylogger then return summary end

	if type(keylogger.is_enabled) == "function" then
		summary.enabled = tostring(keylogger.is_enabled())
	end
	if type(keylogger.get_wpm) == "function" then
		summary.wpm = keylogger.get_wpm()
	end
	if type(keylogger.get_session_stats) == "function" then
		local stats = keylogger.get_session_stats() or {}
		summary.events_session = stats.keystrokes or NOT_AVAILABLE
	end
	if type(keylogger.is_suppressed) == "function" then
		summary.privacy_hits = keylogger.is_suppressed() and "suppressed now" or "not suppressing"
	end
	local dir = LoggerSink.log_dir()
	if dir and dir ~= "" then
		local today = os.date("%Y-%m-%d")
		summary.today_log = dir .. "/ErgoptiPlus_" .. today .. ".log"
		summary.errors_log = dir .. "/ErgoptiPlus_errors_" .. today .. ".log"
	end
	return summary
end

--- LLM backend state.
--- @param state table Daemon state.
--- @return table
local function collect_llm(state)
	local llm_state = {
		enabled = NOT_AVAILABLE,
		-- Ollama is the only backend this driver has. Saying so is more useful
		-- than "unknown", and less misleading than naming one it cannot reach.
		backend = "ollama",
		active_profile = NOT_AVAILABLE,
		model = NOT_AVAILABLE,
		n_predictions = NOT_AVAILABLE,
		streaming = "true",
	}
	local llm = state.llm
	if not llm then
		llm_state.enabled = "false"
		return llm_state
	end
	if type(llm.is_enabled) == "function" then
		llm_state.enabled = tostring(llm.is_enabled())
	end
	if type(llm.get_current_model) == "function" then
		llm_state.model = llm.get_current_model() or NOT_AVAILABLE
	end
	return llm_state
end

--- Keyboard layout state.
--- @param state table Daemon state.
--- @return table
local function collect_layout(state)
	local layout_state = {
		ergopti_base = state.layout or NOT_AVAILABLE,
		altgr = NOT_AVAILABLE,
		shift = NOT_AVAILABLE,
		caps = NOT_AVAILABLE,
		prefix_latch = "clean",
	}
	-- `held_modifiers`, not `held_text_modifiers`. The latter answers a different
	-- question and answers it as an ARRAY of names, so indexing it by name gives
	-- nil for every modifier — which renders as "off" for all of them and reads
	-- as a report rather than as a failed read.
	local ok, hook = pcall(require, "adapters.keyboard_hook")
	if ok and type(hook.held_modifiers) == "function" then
		local ok_held, held = pcall(hook.held_modifiers)
		if ok_held and type(held) == "table" then
			layout_state.shift = held.shift and "active" or "off"
			layout_state.altgr = held.altgr and "active" or "off"
			layout_state.ctrl = held.ctrl and "active" or "off"
			layout_state.meta = held.meta and "active" or "off"
		end
	end
	-- Whether a typable keymap resolved at all. This is the single most useful
	-- line in the report for the driver's most common failure: with no keymap
	-- every expansion silently reroutes through the clipboard.
	local ok_layout, keyboard_layout = pcall(require, "adapters.keyboard_layout")
	if ok_layout and type(keyboard_layout.is_ready) == "function" then
		layout_state.keymap = keyboard_layout.is_ready() and "resolved" or "UNRESOLVED"
	end
	return layout_state
end

--- Hotstring engine figures.
--- @param state table Daemon state.
--- @return table
local function collect_hotstrings(state)
	local hotstrings = {
		terminators = 0,
		magic_key = "",
		personal_count = 0,
		dynamic_count = 0,
		default_delay = NOT_AVAILABLE,
	}
	local config = state.config
	if config and type(config.mapping_count) == "function" then
		hotstrings.personal_count = config.mapping_count() or 0
	end
	local ok_magic, MagicKey = pcall(require, "modules.hotstrings.magic_key")
	if ok_magic and type(MagicKey.get) == "function" then
		hotstrings.magic_key = MagicKey.get() or ""
	end
	local ok_dyn, dynamic = pcall(require, "modules.dynamic_hotstrings.manager")
	if ok_dyn and type(dynamic.active_count) == "function" then
		hotstrings.dynamic_count = dynamic.active_count() or 0
	end
	return hotstrings
end

--- Where the logs are and how much is buffered.
--- @param lines table The ring-buffer snapshot.
--- @return table
local function collect_logs(lines)
	local dir = LoggerSink.log_dir()
	local today = os.date("%Y-%m-%d")
	return {
		unified_today = (dir ~= "" and dir .. "/ErgoptiPlus_" .. today .. ".log") or "",
		errors_today = (dir ~= "" and dir .. "/ErgoptiPlus_errors_" .. today .. ".log") or "",
		errors_sink_active = LoggerSink.is_file_sink_active(),
		ring_lines = #lines,
		note = "The dedicated errors sink keeps the main daily log readable.",
	}
end

--- Which configuration files this install reads.
--- @param state table Daemon state.
--- @return table
local function collect_config(state)
	local summary = {
		overrides = 0,
		enabled_hotstrings = tostring(state.config ~= nil),
		enabled_gestures = NOT_AVAILABLE,
		enabled_llm = tostring(state.llm ~= nil),
		config_files = {},
	}
	local ok, ConfigPaths = pcall(require, "infra.config_paths")
	if ok and type(ConfigPaths.config) == "function" then
		summary.config_files = {
			ConfigPaths.config("hotstrings"),
			ConfigPaths.config("tap_hold.toml"),
		}
	end
	return summary
end

--- Host information.
--- @return table
local function collect_sys()
	local sys = { os = "linux", arch = NOT_AVAILABLE, display_server = NOT_AVAILABLE }
	local ok, DisplayServer = pcall(require, "infra.display_server")
	if ok and type(DisplayServer.kind) == "function" then
		sys.display_server = DisplayServer.kind() or NOT_AVAILABLE
	end
	local pipe = io.popen("uname -m 2>/dev/null")
	if pipe then
		local arch = pipe:read("*l")
		pipe:close()
		if arch and arch ~= "" then sys.arch = arch end
	end
	return sys
end


-- =========================================
-- =========================================
-- ======= 2/ The Snapshot =================
-- =========================================
-- =========================================

--- Resolves the active UI locale so the healthcheck window renders in the
--- user's language instead of a hardcoded "fr". Falls back to "fr" only when
--- i18n truly fails to load or expose get_locale — a fail-safe default, not a
--- silent override of the user's persisted choice.
--- @return string
local function resolve_locale()
	local ok, i18n = pcall(require, "infra.i18n")
	if ok and type(i18n) == "table" and type(i18n.get_locale) == "function" then
		local ok_locale, locale = pcall(i18n.get_locale)
		if ok_locale and type(locale) == "string" and locale ~= "" then return locale end
	end
	return "fr"
end

--- Builds the full diagnostic snapshot.
--- @param state table Daemon state.
--- @return table
local function build_snapshot(state)
	state = type(state) == "table" and state or {}
	local lines = ring_lines()
	local warn_count, err_count = Snapshot.count_issues(lines)

	-- Which of the daemon's parts are wired. Reported as adapter lists because
	-- that is what the page renders, and because "the LLM section is missing"
	-- is a more useful sentence than a section quietly rendering zeroes.
	local loaded, failed = {}, {}
	-- Iterated over a list of NAMES, not over a table built from the state. A
	-- constructor drops its nil values, so `pairs{ engine = state.engine, … }`
	-- is empty exactly when every part is missing — the report would have been
	-- silent about a completely unwired daemon, which is the one case this
	-- window exists for.
	for _, name in ipairs({ "engine", "keylogger", "config", "llm" }) do
		if state[name] then
			loaded[#loaded + 1] = name
		else
			failed[#failed + 1] = name .. " (not wired)"
		end
	end

	local snapshot = {
		version          = Version.VERSION,
		platform         = "linux",
		-- Carried alongside the canonical fields rather than in place of them.
		-- The shared contract does not name it and the page does not require it,
		-- but the window is one of the few surfaces a user reads in their own
		-- language, and hardcoding "fr" here was a bug once already.
		locale           = resolve_locale(),
		loaded_adapters  = loaded,
		-- This driver has no port-contract validation pass, so claiming a
		-- validated list would be inventing one. The loaded list is the honest
		-- answer to a question the page asks of every platform.
		ports_validated  = loaded,
		failed_adapters  = failed,
		-- `false` rather than nil when nothing has failed. The shared validator
		-- reads a nil field as MISSING, so a healthy daemon would have reported
		-- itself as an incomplete snapshot — and the page's `if (s.last_error)`
		-- treats false and nil identically, so nothing is printed either way.
		-- "No error" is a value; the absence of the field is a different claim.
		last_error       = _last_error or false,
		uptime_sec       = os.time() - _started_at,
		warn_count       = warn_count,
		err_count        = err_count,
		recent_issues    = Snapshot.extract_recent_issues(lines, MAX_RECENT_ISSUES),
		sys              = collect("sys", collect_sys),
		pause_state      = collect("pause_state", function() return collect_pause_state(state) end),
		keylogger        = collect("keylogger", function() return collect_keylogger(state) end),
		llm              = collect("llm", function() return collect_llm(state) end),
		layout           = collect("layout", function() return collect_layout(state) end),
		hotstrings       = collect("hotstrings", function() return collect_hotstrings(state) end),
		logs             = collect("logs", function() return collect_logs(lines) end),
		config           = collect("config", function() return collect_config(state) end),
	}

	-- Validated against the shared contract before it is sent. A section that is
	-- silently absent is worse than a loud gap: the reader cannot tell "not
	-- measured" from "measured as nothing", and this window exists to answer
	-- exactly that kind of question.
	local ok, missing = Snapshot.validate_snapshot(snapshot)
	if not ok then
		Logger.error(LOG, "Healthcheck snapshot is missing %d field(s): %s.",
			#missing, table.concat(missing, ", "))
	end
	return snapshot
end

--- Records an error for the next snapshot to surface.
--- @param message string
function M.record_error(message)
	if type(message) ~= "string" or message == "" then return end
	_last_error = message
	Logger.debug(LOG, "Last error recorded for the healthcheck report.")
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	local action = type(payload) == "table" and payload.action or payload
	if action == "ready" then
		Logger.info(LOG, "Healthcheck UI ready.")
		return build_snapshot(state)
	end
	if action == "refresh" then
		return build_snapshot(state)
	end
	Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(action))
	return nil
end

return M
