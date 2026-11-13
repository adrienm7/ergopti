--- tests/support/ai/engine/mlx_import_probe.lua

--- ==============================================================================
--- MODULE: MLX import probe for checker doubles
--- DESCRIPTION:
--- The menu runs mlx_deps_checker.import_probe(), the statement
--- ensure-mlx-deps.sh declares. A test double of the checker answers with the
--- same statement, read from the script, so no test keeps its own copy.
--- ==============================================================================

local helpers = require("tests.helpers")

local M = {}

--- Returns the MLX_IMPORT_PROBE statement of the shipped ensure-mlx-deps.sh.
--- @return string probe
function M.read()
	local handle = assert(io.open(helpers.driver_root() .. "ai/engine/local_servers/ensure-mlx-deps.sh", "rb"))
	local source = handle:read("*a")
	handle:close()
	return assert(source:match('\nMLX_IMPORT_PROBE="([^"]+)"'), "ensure-mlx-deps.sh declares no MLX_IMPORT_PROBE")
end

return M
