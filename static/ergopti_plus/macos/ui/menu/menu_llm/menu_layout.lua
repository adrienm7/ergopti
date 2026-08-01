--- ui/menu/menu_llm/menu_layout.lua

--- ==============================================================================
--- MODULE: LLM Menu Layout (shared spec consumer)
--- DESCRIPTION:
--- Reads the cross-platform IA-submenu layout spec
--- (_shared/modules/llm/menu_layout.json) and exposes the disabled-when-off policy
--- to the macOS menu renderer (ui/menu/menu_llm/init.lua). This is the SINGLE
--- SOURCE OF TRUTH shared with the Windows renderer (windows .../menu_main.ahk),
--- so the two menus can never drift in their greying policy again — a greying
--- mismatch between them (backend/model wrongly greyed while the feature is off)
--- is the exact bug this file prevents.
---
--- FEATURES & RATIONALE:
--- 1. Single source: the per-row "greys out while the feature is off" flag comes
---    from the shared JSON, consumed identically by both platforms.
--- 2. Resilient: a built-in fallback (pinned to the JSON by the contract test
---    tests/test_llm_menu_layout_shared.lua) keeps the menu working if the spec
---    file is missing or corrupt — it must never leave the menu unusable.
--- 3. Cached: the spec is static for the session, parsed once on first use.
--- ==============================================================================

local M = {}

local hs     = hs
local Paths  = require("infra.paths")
local Logger = require("infra.logger")

local LOG = "LLMMenuLayout"




--- Policy loading + cache.

--- Built-in fallback — mirrors the disabled_when_off policy in menu_layout.json.
--- Pinned to the JSON by the contract test so the two cannot diverge; exists only
--- so a missing/corrupt spec file still yields a correctly-greyed menu.
--- false = stays usable while OFF (configure before enabling); true = greyed while OFF.
local FALLBACK_GREYS_WHEN_OFF = {
	backend         = false,
	model           = false,
	profile         = true,
	num_predictions = true,
	trigger         = true,
	generation      = true,
	display         = true,
	navigation      = true,
}

-- Map of row id -> disabled_when_off (bool). nil until first load.
local _policy = nil

--- Loads (once) the disabled-when-off policy from the shared spec, falling back to
--- the built-in table on any read/parse failure.
--- @return table id -> bool.
local function load_policy()
	if _policy then return _policy end

	local policy = nil
	local path = Paths.shared_llm_path("menu_layout.json")
	if path then
		local ok, fh = pcall(io.open, path, "r")
		if ok and fh then
			local raw = fh:read("*a")
			pcall(function() fh:close() end)
			local dec_ok, data = pcall(hs.json.decode, raw)
			if dec_ok and type(data) == "table" and type(data.rows) == "table" then
				policy = {}
				for _, row in ipairs(data.rows) do
					if type(row) == "table" and type(row.id) == "string" then
						policy[row.id] = (row.disabled_when_off == true)
					end
				end
			end
		end
	end

	if not policy or next(policy) == nil then
		Logger.warn(LOG, "menu_layout.json unreadable/empty — using built-in fallback greying policy.")
		policy = {}
		for id, v in pairs(FALLBACK_GREYS_WHEN_OFF) do policy[id] = v end
	end

	_policy = policy
	return _policy
end




--- Public policy queries.

--- Whether the given row greys out while the feature is OFF (its disabled_when_off
--- flag in the shared spec). Unknown ids default to true (grey) — the safe choice.
--- @param id string Row id from menu_layout.json.
--- @return boolean.
function M.greys_when_off(id)
	local p = load_policy()
	local v = p[id]
	if v == nil then return true end
	return v
end

--- Resolves a menu row's `disabled` value from the shared policy, mirroring the
--- Windows renderer: a row that greys-when-off is disabled while off OR paused
--- (is_disabled); a row that stays usable is disabled only while paused.
--- @param id string Row id from menu_layout.json.
--- @param is_disabled boolean True when the feature is off OR the driver is paused.
--- @param paused boolean True when the driver is paused.
--- @return boolean|nil True to disable, nil to leave enabled (hs menu convention).
function M.row_disabled(id, is_disabled, paused)
	if M.greys_when_off(id) then
		return is_disabled or nil
	end
	return paused or nil
end

return M
