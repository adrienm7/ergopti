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
	Logger.debug(LOG, "Starting the personal info tracker…")

	-- Start the personal info tracker
	PersonalInfo.start(base_dir, keymap_module, info_toml_path)

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
	RulesEngine.inject_data(PersonalInfo.get_info(), trigger_char)

	Logger.debug(LOG, "Starting the dynamic rules engine…")
	
	-- Start the dynamic rules engine
	RulesEngine.start(keymap_module)
	
	Logger.info(LOG, "The dynamic hotstrings core initialized successfully.")
end

--- Stops both dynamic expansion engines.
function M.stop()
	Logger.start(LOG, "Stopping dynamic hotstrings core…")
	PersonalInfo.stop()
	RulesEngine.stop()
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
