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
local LOG          = "dynamic_hotstrings"





-- ================================
-- ================================
-- ======= 1/ Default State =======
-- ================================
-- ================================

M.DEFAULT_STATE = {
	personal_info                    = true,
	dynamichotstrings_enabled        = true,
	dynamichotstrings_datefr         = true,
	dynamichotstrings_date           = true,
	dynamichotstrings_phoneprefixes  = true,
	dynamichotstrings_ssnprefixes    = true,
	dynamichotstrings_ibanprefixes   = true,
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
	
	-- Pass the securely loaded data from PersonalInfo to the Rules Engine
	RulesEngine.inject_data(PersonalInfo.get_info(), PersonalInfo.get_trigger_char())
	
	Logger.debug(LOG, "Starting the dynamic rules engine…")
	
	-- Start the dynamic rules engine
	RulesEngine.start(keymap_module)
	
	Logger.info(LOG, "The dynamic hotstrings core initialized successfully.")
end

-- Proxy Personal Info UI and state controls for the menu
M.open_editor = PersonalInfo.open_editor
M.enable      = PersonalInfo.enable
M.disable     = PersonalInfo.disable

return M
