--- tests/support/keyboard/tap_hold_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Tap-Hold Preset Fixture
--- DESCRIPTION:
--- Functional engine scenarios select the shipped preset deliberately. Empty
--- configuration tests bypass this helper and exercise the neutral loader.
--- A scenario still spells its tap-hold settings in one text, as the user's
--- tap_hold.toml looked before config schema v22; the fixture splits it into the
--- two homes of the decision of 2026-11-11: the keys stay in tap_hold.toml, the
--- switch and the two timings ([tap_hold] enabled, lone_modifier_tap_max_ms,
--- sticky_timeout_ms) go to the config.toml [tap_holds] the manager reads.
--- ==============================================================================

local M = {}

-- The [tap_hold] leaves config.toml [tap_holds] owns.
local CONFIG_OWNED = { "enabled", "lone_modifier_tap_max_ms", "sticky_timeout_ms" }

--- The [tap_hold] master block of a scenario text, nil when it has none.
local function master_of(text)
	return text:match("%[tap_hold%]([^%[]*)")
end

--- Selects the preset without replacing an explicit master choice in `text`:
--- the tap_hold.toml half of the scenario, its config.toml leaves removed.
--- @param text string|nil
--- @return string
function M.with_preset(text)
	text = text or ""
	local first, last, master = text:find("%[tap_hold%]([^%[]*)")
	if master then
		local kept = master
		for _, key in ipairs(CONFIG_OWNED) do
			kept = kept:gsub("%f[%w_]" .. key .. "%s*=[^\n]*\n?", "")
		end
		text = text:sub(1, first - 1) .. "[tap_hold]" .. kept .. text:sub(last + 1)
		master = kept
	end
	if master and master:match("%f[%w_]inherit_defaults%s*=") then return text end
	if master then return (text:gsub("(%[tap_hold%]%s*\n)", "%1inherit_defaults = true\n", 1)) end
	return "[tap_hold]\ninherit_defaults = true\n" .. text
end

--- The config.toml half of the scenario: [tap_holds] enabled (on unless the
--- text switches it off) and any timing the text sets.
--- @param text string|nil
--- @return string
function M.config(text)
	local master = master_of(text or "") or ""
	local lines = { "[tap_holds]" }
	local enabled = master:match("%f[%w_]enabled%s*=%s*([%w]+)")
	lines[#lines + 1] = "enabled = " .. (enabled or "true")
	for _, key in ipairs({ "lone_modifier_tap_max_ms", "sticky_timeout_ms" }) do
		local value = master:match("%f[%w_]" .. key .. "%s*=%s*([^\n]+)")
		if value then lines[#lines + 1] = key .. " = " .. value end
	end
	return table.concat(lines, "\n") .. "\n"
end

--- The config.toml a scenario's manager and writer read beside its tap_hold.toml.
--- @param tap_path string
--- @return string
function M.config_path(tap_path)
	return tap_path .. ".config.toml"
end

--- Writes both halves of a scenario.
--- @param tap_path string The tap_hold.toml path.
--- @param text string|nil The scenario text.
--- @return string config_path
function M.write(tap_path, text)
	local config_path = M.config_path(tap_path)
	for path, content in pairs({ [tap_path] = M.with_preset(text), [config_path] = M.config(text) }) do
		local fh = assert(io.open(path, "w"))
		assert(fh:write(content))
		assert(fh:close())
	end
	return config_path
end

return M
