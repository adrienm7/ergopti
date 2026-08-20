--- ui/menu/menu_llm/menu_layout.lua

--- ==============================================================================
--- MODULE: LLM Menu Layout (shared manifest consumer)
--- DESCRIPTION:
--- Reads the IA submenu's rows from the shared menu manifest (``llm_menu``) and
--- exposes the disabled-when-off policy to the macOS menu renderer
--- (ui/menu/menu_llm/init.lua). This is the SINGLE SOURCE OF TRUTH shared with
--- the Windows renderer (windows .../menu_main.ahk), so the two menus can never
--- drift in their greying policy again — a greying mismatch between them
--- (backend/model wrongly greyed while the feature is off) is the exact bug this
--- file prevents.
---
--- MOVED 2026-08-07: the rows used to live in a spec file of their own
--- (_shared/modules/llm/menu_layout.json). One menu therefore had TWO shared
--- descriptions — that file and the manifest's ``llm_menu`` key, which described
--- a two-row menu only the Linux driver drew — and neither mentioned the other.
--- They are one description now, in the manifest, alongside the rest of the menu
--- tree.
---
--- FEATURES & RATIONALE:
--- 1. Single source: the per-row "greys out while the feature is off" flag comes
---    from the manifest, consumed identically by both platforms.
--- 2. Resilient: a built-in fallback (pinned to the manifest by the contract test
---    tests/test_llm_menu_layout_shared.lua) keeps the menu working if the
---    manifest is missing or corrupt — it must never leave the menu unusable.
--- 3. Cached: the manifest is static for the session, read once on first use.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "LLMMenuLayout"

--- Manifest key holding the IA submenu's rows.
local LLM_MENU_KEY = "llm_menu"

--- Platform token this driver may see rows for.
local PLATFORM = "hs"




--- Policy loading + cache.

--- Built-in fallback — mirrors the disabled_when_off policy the manifest declares.
--- Pinned to the manifest by the contract test so the two cannot diverge; exists
--- only so a missing/corrupt manifest still yields a correctly-greyed menu.
--- false = stays usable while OFF (configure before enabling); true = greyed while OFF.
local FALLBACK_GREYS_WHEN_OFF = {
	llm_backend             = false,
	llm_model               = false,
	llm_profile             = true,
	llm_num_predictions     = true,
	llm_trigger             = true,
	llm_generation_settings = true,
	llm_display             = true,
	llm_navigation          = true,
}

--- Built-in fallback — mirrors which row carries the backend-health dot. Same
--- role as FALLBACK_GREYS_WHEN_OFF above, and pinned the same way.
local FALLBACK_HEALTH_DOT = {
	llm_backend             = false,
	llm_model               = true,
	llm_profile             = false,
	llm_num_predictions     = false,
	llm_trigger             = false,
	llm_generation_settings = false,
	llm_display             = false,
	llm_navigation          = false,
}

--- Built-in fallback row ORDER — the order the two tables above cannot express.
local FALLBACK_ROW_ORDER = {
	"llm_backend",
	"llm_model",
	"llm_profile",
	"llm_num_predictions",
	"llm_trigger",
	"llm_generation_settings",
	"llm_display",
	"llm_navigation",
}

-- Map of row id -> disabled_when_off (bool). nil until first load.
local _policy = nil

-- Map of row id -> health_dot (bool). nil until first load.
local _dots = nil

-- Ordered list of the row ids this driver renders. nil until first load.
local _ids = nil

--- Whether a manifest row is visible on this driver. A row with no ``platforms``
--- restriction is visible everywhere.
--- @param row table Manifest row.
--- @return boolean.
local function is_for_this_driver(row)
	if type(row.platforms) ~= "table" then return true end
	for _, p in ipairs(row.platforms) do
		if p == PLATFORM then return true end
	end
	return false
end

--- Loads (once) the disabled-when-off policy from the shared manifest, falling
--- back to the built-in table on any read failure.
---
--- Required lazily: this module is pulled in from the menu tree, and requiring the
--- renderer binding at file scope would load it during the menu's own load.
--- @return table id -> bool.
local function load_policy()
	if _policy then return _policy end

	local policy, dots, ids = nil, nil, nil
	local ok_menu, ManifestMenu = pcall(require, "infra.manifest_menu")
	if ok_menu and ManifestMenu and type(ManifestMenu.get_array) == "function" then
		local rows = ManifestMenu.get_array(LLM_MENU_KEY)
		if type(rows) == "table" then
			policy, dots, ids = {}, {}, {}
			for _, row in ipairs(rows) do
				-- Only the rows this driver renders carry a greying policy: the
				-- separator and Linux's two inline lists have no submenu to grey.
				if type(row) == "table" and type(row.id) == "string"
					and row.type == "dynamic" and is_for_this_driver(row) then
					policy[row.id] = (row.disabled_when_off == true)
					dots[row.id] = (row.health_dot == true)
					ids[#ids + 1] = row.id
				end
			end
		end
	end

	if not policy or next(policy) == nil then
		Logger.warn(LOG, "menu_manifest.json 'llm_menu' unreadable/empty — using built-in fallback greying policy.")
		policy, dots, ids = {}, {}, {}
		for id, v in pairs(FALLBACK_GREYS_WHEN_OFF) do policy[id] = v end
		for id, v in pairs(FALLBACK_HEALTH_DOT) do dots[id] = v end
		-- Deliberately ordered, unlike the two tables above: this list decides
		-- what the caller registers a handler for, and pairs() order is not.
		ids = FALLBACK_ROW_ORDER
	end

	_policy, _dots, _ids = policy, dots, ids
	return _policy
end




--- Public policy queries.

--- Whether the given row greys out while the feature is OFF (its disabled_when_off
--- flag in the shared spec). Unknown ids default to true (grey) — the safe choice.
--- @param id string Row id from the manifest's llm_menu.
--- @return boolean.
function M.greys_when_off(id)
	local p = load_policy()
	local v = p[id]
	if v == nil then return true end
	return v
end

--- The ids this driver's rows are declared with, in manifest order. The renderer
--- places the rows; this is what the caller registers a handler for. Derived from
--- the same read as the greying policy so the two can never disagree about which
--- rows exist.
--- @return table Ordered list of row ids.
function M.row_ids()
	load_policy()
	return _ids
end

--- Whether the given row carries the backend-reachability dot (its ``health_dot``
--- flag in the manifest). Exactly one row does; asking the manifest rather than
--- hardcoding which means moving the dot is a manifest edit on both drivers at
--- once, not a source edit on each.
--- @param id string Row id from the manifest's llm_menu.
--- @return boolean.
function M.has_health_dot(id)
	load_policy()
	return _dots[id] == true
end

--- Resolves a menu row's `disabled` value from the shared policy, mirroring the
--- Windows renderer: a row that greys-when-off is disabled while off OR paused
--- (is_disabled); a row that stays usable is disabled only while paused.
--- @param id string Row id from the manifest's llm_menu.
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
