--- lib/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker  
--- DESCRIPTION:
--- Verifies that all required Python packages for MLX are installed with correct versions.
--- Runs asynchronously on startup to avoid blocking Hammerspoon.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "mlx_deps"





-- ========================================
-- ========================================
-- ======= 1/ Dependency Validation =======
-- ========================================
-- ========================================

--- Runs the bash script verifying python dependencies for MLX asynchronously.
function M.check_and_install_deps()
	Logger.debug(LOG, "Locating MLX dependency script…")
	local script_path = nil
	
	-- Try multiple locations for flexibility
	local hs_config = os.getenv("HOME") .. "/.hammerspoon"
	local candidate = hs_config .. "/../../scripts/ensure-mlx-deps.sh"
	local project_root = os.getenv("HOME") .. "/Documents/perso/ergopti"
	
	if hs.fs.attributes(project_root .. "/scripts/ensure-mlx-deps.sh", "mode") then
		script_path = project_root .. "/scripts/ensure-mlx-deps.sh"
	elseif hs.fs.attributes(candidate, "mode") then
		script_path = candidate
	end
	
	if not script_path then
		Logger.warn(LOG, "Script ensure-mlx-deps.sh introuvable.")
		return
	end
	
	Logger.debug(LOG, "Executing dependency validation script in background…")
	hs.task.new("/bin/bash", function(exitCode, _, _)
		if exitCode == 0 then
			Logger.info(LOG, "Toutes les dépendances sont vérifiées.")
		else
			Logger.warn(LOG, "Dépendances non vérifiées (non critique).")
		end
	end, { script_path }):start()
end

return M
