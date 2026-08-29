--- modules/dynamic_hotstrings/init.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings Core
--- DESCRIPTION:
--- Orchestrates dynamic expansions by coupling the Personal Info engine (which
--- acts on "@" tags) and the Rules Engine (which acts on dynamic suffixes like
--- "td" and generates real-time prefixes).
---
--- FEATURES & RATIONALE:
--- 1. Shared Data Pipeline: Extracts personal info automatically and passes it
---    to the rules engine for phone and SSN auto-completion without requiring
---    the main init.lua to manage the logic.
--- ==============================================================================

local M = {}

local PersonalInfo = require("modules.dynamic_hotstrings.personal_info")
local RulesEngine  = require("modules.dynamic_hotstrings.rules_engine")
local Logger       = require("infra.logger")
local Manifest     = require("infra.manifest_reader")
local LOG          = "dynamic_hotstrings"
local _started     = false
local _starting    = false
local _started_keymap = nil





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

-- Per-category dynamic-hotstring defaults come from the shared features manifest
-- (single cross-driver source); each entry there is a feature toggle, so we read
-- its `.enabled` flag. Only dynamichotstrings_enabled has no manifest path (it is
-- a macOS-local master switch), so it stays a literal.
local function feat_enabled(path)
	return Manifest.default_for(path).enabled
end

--- Runs one exact start commit behind an exception boundary.
--- @param label string Diagnostic step name.
--- @param operation function Start operation.
--- @return boolean committed
local function run_start_step(label, operation)
	local ok, result = xpcall(operation, debug.traceback)
	if ok and result == true then return true end
	Logger.error(LOG, "Dynamic-hotstrings start step '%s' failed "
		.. "(callback content withheld; terminal type: %s).", label, type(result))
	return false
end

--- Stops both prospective children after any failed start step.
--- @param reason string Failure context.
--- @return boolean false
local function rollback_start(reason)
	-- Rules first: its callback can resolve personal data. Both stops are protected
	-- so one teardown failure cannot leave the sibling generation live.
	local stops = {
		{ label = "rules_engine", stop = RulesEngine.stop },
		{ label = "personal_info", stop = PersonalInfo.stop },
	}
	for _, entry in ipairs(stops) do
		local label, stop = entry.label, entry.stop
		local ok, result = xpcall(stop, debug.traceback)
		if not ok then
			Logger.error(LOG, "Dynamic-hotstrings rollback could not stop %s "
				.. "(callback content withheld; terminal type: %s).", label, type(result))
		end
	end
	_started = false
	_starting = false
	_started_keymap = nil
	Logger.error(LOG, "Dynamic hotstrings core start rolled back after %s.", tostring(reason))
	return false
end

M.DEFAULT_STATE = {
	personal_info                    = feat_enabled("hotstrings.dynamic.text_expansion_personal_information"),
	dynamichotstrings_enabled        = true,
	dynamichotstrings_datefr         = feat_enabled("hotstrings.dynamic.date_fr"),
	dynamichotstrings_datelongfr     = feat_enabled("hotstrings.dynamic.date_long_fr"),
	dynamichotstrings_date           = feat_enabled("hotstrings.dynamic.date"),
	dynamichotstrings_phoneprefixes  = feat_enabled("hotstrings.dynamic.phone_prefixes"),
	dynamichotstrings_ssnprefixes    = feat_enabled("hotstrings.dynamic.ssn_prefixes"),
	dynamichotstrings_ibanprefixes   = feat_enabled("hotstrings.dynamic.iban_prefixes"),
}





-- ========================================
-- ========================================
-- ======= 2/ Base API & Forwarding =======
-- ========================================
-- ========================================

--- Initializes both dynamic expansion engines and securely shares data between them.
--- @param base_dir string Base configuration directory.
--- @param keymap_module table The active keymap module reference.
--- @param info_toml_path string|nil Absolute path to personal_info.toml.
function M.start(base_dir, keymap_module, info_toml_path)
	if _started then
		if _started_keymap == keymap_module then return true end
		Logger.error(LOG, "Dynamic hotstrings core already owns a different keymap.")
		return false
	end
	if _starting then
		Logger.error(LOG, "Dynamic hotstrings core start refused because another start is in progress.")
		return false
	end
	_starting = true
	Logger.debug(LOG, "Starting the personal info tracker…")

	-- Start the personal info tracker
	if not run_start_step("personal-info start", function()
		return PersonalInfo.start(base_dir, keymap_module, info_toml_path,
			RulesEngine.refresh_personal_data)
	end) then
		return rollback_start("personal-info start")
	end

	Logger.debug(LOG, "Injecting personal data into the rules engine…")

	-- Source the trigger from the real, user-configurable magic key
	-- (keymap_module.get_trigger_char(), backed by CoreState.magic_key) instead
	-- of PersonalInfo.get_trigger_char() — the latter is just personal_info.toml's
	-- own independent default and never reflects a magic-key change made via the
	-- menu (F-HIGH-8 fix). A live RulesEngine.set_trigger_char() call is also
	-- wired into menu_state.lua's sync so later changes keep reaching this engine.
	local trigger_char = (type(keymap_module) == "table" and type(keymap_module.get_trigger_char) == "function")
		and keymap_module.get_trigger_char()
		or PersonalInfo.get_trigger_char()
	if not run_start_step("personal-data injection", function()
		return RulesEngine.inject_data(PersonalInfo.get_info(), trigger_char)
	end) then
		return rollback_start("personal-data injection")
	end

	Logger.debug(LOG, "Starting the dynamic rules engine…")
	
	-- Start the dynamic rules engine
	if not run_start_step("rules-engine start", function()
		return RulesEngine.start(keymap_module)
	end) then
		return rollback_start("rules-engine start")
	end
	
	_started = true
	_starting = false
	_started_keymap = keymap_module
	Logger.info(LOG, "The dynamic hotstrings core initialized successfully.")
	return true
end

--- Stops both dynamic expansion engines.
function M.stop()
	Logger.start(LOG, "Stopping dynamic hotstrings core…")
	_started = false
	_starting = false
	_started_keymap = nil
	RulesEngine.stop()
	PersonalInfo.stop()
	Logger.success(LOG, "Dynamic hotstrings core stopped.")
end

-- Proxy Personal Info UI and state controls for the menu
M.open_editor = PersonalInfo.open_editor
M.enable      = PersonalInfo.enable
M.disable     = PersonalInfo.disable

--- Propagates a magic-key change to BOTH dynamic engines.
---
--- This used to be a bare alias to RulesEngine.set_trigger_char, so the live
--- sync in menu_state.lua reached the date/prefix engine and never the @-tag
--- one: changing the magic key silenced personal_info until the next reload,
--- while its preview provider — which derives its answer from the keymap buffer
--- and carries no trigger of its own — kept offering the expansion. A proxy that
--- names one of a pair is how half a fix ships.
--- @param char string The new trigger character.
function M.set_trigger_char(char)
	if type(char) ~= "string" or char == "" then
		Logger.error(LOG, "set_trigger_char(): expected a non-empty string — both engines unchanged.")
		return false
	end
	-- Verify the entire pair before the first write. A missing sibling API used to
	-- advance RulesEngine alone and leave personal-info on the old key.
	if type(RulesEngine.set_trigger_char) ~= "function"
		or type(PersonalInfo.set_trigger_char) ~= "function"
	then
		Logger.error(LOG, "Trigger-key propagation refused: paired engine API is incomplete.")
		return false
	end

	local previous = PersonalInfo.get_trigger_char()
	if RulesEngine.set_trigger_char(char) ~= true then
		Logger.error(LOG, "Trigger-key propagation refused: rules engine did not commit.")
		return false
	end
	if PersonalInfo.set_trigger_char(char) ~= true then
		-- Defensive rollback: PersonalInfo is normally a deterministic in-memory
		-- write, but a future validation/fence must not create a half-commit.
		local rolled_back = RulesEngine.set_trigger_char(previous) == true
		Logger.error(LOG, "Trigger-key propagation incomplete: personal-info engine refused; "
			.. "rules rollback %s.", rolled_back and "committed" or "FAILED")
		return false
	end
	return true
end

return M
