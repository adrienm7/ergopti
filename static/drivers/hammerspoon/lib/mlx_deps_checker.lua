--- lib/mlx_deps_checker.lua

--- ==============================================================================
--- MODULE: MLX Dependencies Checker
--- DESCRIPTION:
--- Verifies that all required Python packages for MLX are installed with correct
--- versions, and upgrades them if outdated. Runs asynchronously on startup.
---
--- FEATURES & RATIONALE:
--- 1. Robust path resolution: locates the project root from this file's own path
---    via debug.getinfo, so it works regardless of where Hammerspoon is launched
---    from or how the project is checked out.
--- 2. Project venv first: prefers the project's '.venv/bin/python3' so the same
---    Python that runs the MLX server is the one whose deps we maintain.
--- 3. Non-blocking: full check + upgrade runs in a background hs.task so it
---    never freezes Hammerspoon on startup.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "mlx_deps"




-- =====================================
-- =====================================
-- ======= 1/ Path Resolution =========
-- =====================================
-- =====================================

--- Resolves the project root from this file's own path. Returns nil if the
--- expected layout is not found.
--- @return string|nil project_root Absolute path or nil.
local function resolve_project_root()
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	-- Expected suffix: .../static/drivers/hammerspoon/lib/mlx_deps_checker.lua
	local root = source:match("^(.*)/static/drivers/hammerspoon/lib/mlx_deps_checker%.lua$")
	if root and root ~= "" and hs.fs.attributes(root, "mode") then
		return root
	end
	return nil
end




-- ========================================
-- ========================================
-- ======= 2/ Dependency Validation =======
-- ========================================
-- ========================================

--- Runs the bash script verifying python dependencies for MLX asynchronously.
--- The script auto-detects the project venv and upgrades any outdated package.
function M.check_and_install_deps()
	Logger.debug(LOG, "Locating MLX dependency script…")
	local project_root = resolve_project_root()
	if not project_root then
		Logger.warn(LOG, "Project root introuvable depuis mlx_deps_checker.lua — skip.")
		return
	end

	-- The script lives next to the LLM module (modules/llm/) so all MLX-related
	-- code stays co-located.
	local script_path = project_root .. "/static/drivers/hammerspoon/modules/llm/ensure-mlx-deps.sh"
	if not hs.fs.attributes(script_path, "mode") then
		Logger.warn(LOG, "Script ensure-mlx-deps.sh introuvable à %s.", script_path)
		return
	end

	-- Forward the project root so the script knows where to find .venv even
	-- when launched outside the project directory (e.g. from launchd)
	local env_prefix = "PROJECT_ROOT=" .. project_root .. " "
	local bash_cmd = env_prefix .. "/bin/bash " .. script_path

	Logger.debug(LOG, "Executing dependency validation script in background (root=%s)…", project_root)
	local task = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
		-- Surface the script's stdout into the Hammerspoon log on every run, even
		-- on success: the script reports the resolved version of every MLX package
		-- (e.g. 'mlx-lm = 0.27.3'), and that line is the single most valuable piece
		-- of evidence when an mlx-lm release silently changes its HTTP routes.
		local combined = (stdout or "") .. (stderr or "")
		for line in combined:gmatch("([^\n\r]+)") do
			if line:match("%S") then
				Logger.info(LOG, "%s", line)
			end
		end
		if exitCode == 0 then
			Logger.info(LOG, "MLX dependencies check finished successfully.")
		else
			Logger.warn(LOG, "MLX dependencies check failed (exit=%d).",
				tonumber(exitCode) or -1)
		end
	end, { "-c", bash_cmd })

	if task then
		pcall(function() task:start() end)
	else
		Logger.warn(LOG, "Failed to create hs.task for MLX dependencies script.")
	end
end

return M
