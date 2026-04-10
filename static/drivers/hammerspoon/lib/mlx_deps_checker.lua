--- utilities/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker  
--- DESCRIPTION:
--- Verifies that all required Python packages for MLX are installed with correct versions.
--- Runs asynchronously on startup to avoid blocking Hammerspoon.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "mlx_deps"

function M.check_and_install_deps()
	-- Dynamically find the script path from the current Hammerspoon config location
	local script_path = nil
	
	-- Try multiple locations for flexibility:
	-- 1. Symlink in ~/.hammerspoon (standard Hammerspoon location)
	local hs_config = os.getenv("HOME") .. "/.hammerspoon"
	local candidate = hs_config .. "/../../scripts/ensure-mlx-deps.sh"
	
	-- 2. Direct path from project repo
	local project_root = os.getenv("HOME") .. "/Documents/perso/ergopti"
	if hs.fs.attributes(project_root .. "/scripts/ensure-mlx-deps.sh", "mode") then
		script_path = project_root .. "/scripts/ensure-mlx-deps.sh"
	elseif hs.fs.attributes(candidate, "mode") then
		script_path = candidate
	end
	
	if not script_path then
		Logger.warn(LOG, "Script ensure-mlx-deps.sh introuvable")
		return
	end
	
	-- Run asynchronously in background; failures are non-critical
	hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
		if exitCode == 0 then
			Logger.info(LOG, "✅ All dependencies verified")
		else
			Logger.warn(LOG, "Dépendances non vérifiées (non critique)")
		end
	end, { script_path }):start()
end

return M
