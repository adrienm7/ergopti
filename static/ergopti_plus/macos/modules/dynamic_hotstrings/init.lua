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
local Logger       = require("lib.logger")
local Manifest     = require("lib.manifest_reader")
local LOG          = "dynamic_hotstrings"





-- ================================
--- ================================
-- ======= 1/ Default State =======
--- ================================
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
--- ========================================
-- ======= 2/ Base API & Forwarding =======
--- ========================================
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
	
	-- Pass the securely loaded data from PersonalInfo to the Rules Engine
	RulesEngine.inject_data(PersonalInfo.get_info(), PersonalInfo.get_trigger_char())
	
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

return M
