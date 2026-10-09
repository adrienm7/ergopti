--- ui/onboarding/startup.lua

--- ==============================================================================
--- MODULE: First-use Wizard Startup
--- DESCRIPTION:
--- Opens the wizard after the graphical daemon is ready when config.toml is
--- absent, as the macOS and Windows drivers do. Only the wizard's committed
--- configuration creates the file; opening or closing a window never counts as
--- consent, so a dismissed wizard opens again at the next start.
--- ==============================================================================

local M = {}

-- errno of a missing file, as io.open reports it.
local ENOENT = 2

--- Whether the configuration file is absent, the wizard's only trigger.
--- @param path string Absolute config.toml path.
--- @param open function|nil io.open-compatible opener.
--- @return boolean|nil absent
--- @return string|nil detail Why presence could not be established.
function M.config_absent(path, open)
	local file, err, code = (open or io.open)(path, "rb")
	if file then
		file:close()
		return false
	end
	if code == ENOENT then return true end
	return nil, tostring(err)
end

--- Offers first-use setup once the caller has wired the complete daemon state.
--- @param opts table { graphical, path, show, fail, open? }
--- @return boolean Success, including a configured or headless launch.
function M.run(opts)
	if not opts.graphical then return true end
	local absent, detail = M.config_absent(opts.path, opts.open)
	if absent == nil then
		opts.fail("First-use configuration could not be inspected: " .. detail)
		return false
	end
	if not absent then return true end
	local ok, shown = pcall(opts.show, "onboarding")
	if not ok or shown ~= true then
		opts.fail("First-use wizard could not be opened: " .. tostring(shown))
		return false
	end
	return true
end

return M
