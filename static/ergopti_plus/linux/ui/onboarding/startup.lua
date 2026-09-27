--- ui/onboarding/startup.lua

--- ==============================================================================
--- MODULE: First-use Wizard Startup
--- DESCRIPTION:
--- Opens the wizard after the graphical daemon is ready. Only the wizard's
--- successful configuration transaction records completion; opening or closing
--- a window must never silently count as consent.
--- ==============================================================================

local M = {}
local TomlCodec = require("toml_codec")

--- Reads the completion flag and marks the exact configuration key consumed.
--- @param decoded table
--- @param mark function|nil
--- @return boolean
function M.should_show(decoded, mark)
	local section = type(decoded.script) == "table" and decoded.script or {}
	if mark and section.onboarding_done ~= nil then mark("script", "onboarding_done") end
	return section.onboarding_done ~= true
end

--- Offers first-use setup once the caller has wired the complete daemon state.
--- @param opts table { graphical, path, show, fail, open? }
--- @return boolean Success, including a previously completed or headless launch.
function M.run(opts)
	if not opts.graphical then return true end
	local file, err, code = (opts.open or io.open)(opts.path, "rb")
	local decoded = {}
	if file then
		local raw = file:read("*a")
		file:close()
		local ok, result = pcall(TomlCodec.decode, raw)
		if not ok or type(result) ~= "table" then
			opts.fail("First-use configuration could not be decoded: " .. tostring(result))
			return false
		end
		decoded = result
	elseif code ~= 2 then
		opts.fail("First-use configuration could not be read: " .. tostring(err))
		return false
	end
	if not M.should_show(decoded) then return true end
	local ok, shown = pcall(opts.show, "onboarding")
	if not ok or shown ~= true then
		opts.fail("First-use wizard could not be opened: " .. tostring(shown))
		return false
	end
	return true
end

return M
