--- lib/manifest_menu.lua

--- ==============================================================================
--- MODULE: Manifest Menu Renderer
--- DESCRIPTION:
--- Generic manifest-driven menu builder shared by all submenu builders on macOS.
--- Reads a ``*_menu`` array from ``menu_manifest.json`` and constructs an
--- hs.menubar-compatible items table, dispatching each item type to the
--- appropriate render function.
---
--- FEATURES & RATIONALE:
--- 1. Single renderer: every submenu (shortcuts, metrics, layout, hotstrings,
---    gestures) is built by the same loop — structure lives in the manifest,
---    not in per-submenu Lua code.
--- 2. Dynamic escape hatch: items whose ``type`` is ``"dynamic"`` are routed
---    to a caller-supplied table of handler functions so platform-specific UI
---    (file trees, dialogs, runtime state) stays in the caller.
--- 3. Platform filtering: entries with a ``platforms`` array that does not
---    include ``"hs"`` are silently skipped.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local Paths  = require("lib.paths")
local i18n   = require("lib.i18n")
local LOG    = "manifest_menu"

-- Module-level manifest cache — invalidated by M.invalidate_cache().
local _cache = nil





-- ==============================================
-- =============================================
-- ======= 1/ Manifest Root Access Layer =======
-- =============================================
-- ==============================================

--- Loads and caches the shared manifest JSON.
--- Returns the parsed root table, or nil on failure.
--- @return table|nil
local function get_manifest_root()
	if _cache ~= nil then
		return _cache
	end
	local path = Paths.shared("modules/menu/menu_manifest.json") or ""
	local ok_r, fh = pcall(io.open, path, "r")
	if not ok_r or not fh then
		Logger.error(LOG, "Cannot open menu_manifest.json at '%s'.", path)
		return nil
	end
	local content = fh:read("*a")
	fh:close()
	local ok_j, data = pcall(hs.json.decode, content)
	if not ok_j or type(data) ~= "table" then
		Logger.error(LOG, "Failed to parse menu_manifest.json.")
		return nil
	end
	_cache = data
	return _cache
end

--- Invalidates the manifest cache.
--- Call after a locale change or hot-reload so the next build re-reads the file.
function M.invalidate_cache()
	_cache = nil
end

--- Returns the menu definition array at ``key`` in the manifest.
--- Returns an empty table if the key is absent or the manifest failed to load.
--- @param key string Top-level key in menu_manifest.json (e.g. "shortcuts_menu").
--- @return table
local function get_menu_def(key)
	local root = get_manifest_root()
	if type(root) ~= "table" then
		return {}
	end
	local arr = root[key]
	if type(arr) ~= "table" then
		Logger.warn(LOG, "menu key '%s' not found in manifest.", key)
		return {}
	end
	return arr
end




-- ============================================
-- ============================================
-- ======= 2/ Platform Filter Helpers =========
-- ============================================
-- ============================================

--- Returns true when the entry is visible on ``platform``.
--- Driver-neutral: call as is_for_platform(entry, "hs") for macOS,
--- is_for_platform(entry, "linux") for the future Linux driver.
--- An entry with no ``platforms`` restriction is visible on all platforms.
--- @param entry table Manifest item entry.
--- @param platform string Platform token: "ahk", "hs", or "linux".
--- @return boolean
local function is_for_platform(entry, platform)
	if type(entry) ~= "table" then return false end
	if type(entry.platforms) ~= "table" then return true end
	for _, p in ipairs(entry.platforms) do
		if p == platform then return true end
	end
	return false
end

--- Legacy alias: macOS driver entry point.
local function is_for_hs(entry)
	return is_for_platform(entry, "hs")
end




-- ============================================
-- ============================================
-- ======= 3/ Core Renderer ===================
-- ============================================
-- ============================================

--- Calls a manifest-driven handler under pcall isolation so a single broken
--- entry cannot unwind through M.build and take down the entire menu tree —
--- the single outer pcall in the caller's rebuild_menu_cache() would otherwise
--- catch the failure at the granularity of the WHOLE menu, not just this item.
--- Logs ERROR (with the manifest key and item id for triage) and swallows the
--- failure so the loop continues to the next item.
--- @param manifest_key string Menu definition key, for the error message.
--- @param item_id string The failing item's id, for the error message.
--- @param fn function Handler to call.
--- @param ... any Arguments forwarded to fn.
--- @return boolean ok True when fn ran without raising.
--- @return any result The handler's return value when ok is true, nil otherwise.
local function call_isolated(manifest_key, item_id, fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok then
		Logger.error(LOG, "Handler for '%s.%s' raised: %s — item skipped.", manifest_key, item_id, tostring(result))
		return false, nil
	end
	return true, result
end

--- Build an hs.menubar items table from a manifest menu definition array.
---
--- ``manifest_key``      — key in menu_manifest.json (e.g. ``"shortcuts_menu"``)
--- ``category``          — human-readable category name for debug logs
--- ``dynamic_handlers``  — table of id → function(items, ctx) for ``type:"dynamic"`` entries.
---   Each handler receives ``(items_list, ctx)`` and appends its items in place.
--- ``group_builders``    — optional table of group_id → function(ctx) → table|nil for
---   ``type:"group"`` entries. Returns a table ``{title, menu}`` or nil to skip.
--- ``ctx``               — the menu context table passed through to dynamic handlers.
---
--- Returns the populated items list (array of hs.menubar item tables).
--- @param manifest_key string
--- @param category string
--- @param dynamic_handlers table
--- @param group_builders table|nil
--- @param ctx table
--- @return table
function M.build(manifest_key, category, dynamic_handlers, group_builders, ctx)
	group_builders = group_builders or {}
	local menu_def = get_menu_def(manifest_key)
	local result      = {}
	local item_count  = 0     -- real items added so far
	local pending_sep = false -- separator deferred until next real item

	local function flush_sep()
		if pending_sep and item_count > 0 then
			table.insert(result, { title = "-" })
		end
		pending_sep = false
	end

	for _, item in ipairs(menu_def) do
		if not is_for_hs(item) then
			goto continue
		end

		local t = item.type

		if t == "---" then
			-- Defer separator — only flush when a real item follows.
			pending_sep = true
			goto continue

		elseif t == "toggle" then
			-- Category toggles rendered by caller; skip silently.

		elseif t == "feature" then
			-- Feature items rendered by caller or dynamic handlers; skip silently.

		elseif t == "action" then
			local action_id = type(item.id) == "string" and item.id or ""
			if action_id ~= "" and type(dynamic_handlers[action_id]) == "function" then
				flush_sep()
				local ok = call_isolated(manifest_key, action_id, dynamic_handlers[action_id], result, ctx)
				if ok then item_count = item_count + 1 end
			else
				-- A manifest entry with an id but no matching handler renders one item
				-- short, permanently and undetected (F-HIGH-25) — log so a drifted
				-- manifest/handler pairing surfaces instead of vanishing silently.
				Logger.warn(LOG, "No 'action' handler registered for id '%s' in '%s' — item skipped.",
					tostring(action_id), manifest_key)
			end

		elseif t == "section_header" then
			local i18n_key = type(item.i18n) == "string" and item.i18n or ""
			if i18n_key ~= "" then
				flush_sep()
				table.insert(result, { title = i18n.section(i18n_key), disabled = true })
				item_count = item_count + 1
			end

		elseif t == "group" then
			local group_id  = type(item.id)   == "string" and item.id   or ""
			local i18n_key  = type(item.i18n) == "string" and item.i18n or ""
			if group_id == "" or i18n_key == "" then
				Logger.warn(LOG, "group item missing id or i18n in '%s' — skipped.", manifest_key)
				goto continue
			end
			local label = i18n.get(i18n_key)
			local built = nil
			if type(group_builders[group_id]) == "function" then
				local _ok
				_ok, built = call_isolated(manifest_key, group_id, group_builders[group_id], ctx)
			else
				built = M.build_builtin_group(group_id, ctx)
			end
			if type(built) == "table" then
				flush_sep()
				-- built may be a raw items list or a table with {menu=…, disabled=…}
				local sub_menu    = type(built.menu) == "table" and built.menu or built
				local sub_disabled = built.disabled or nil
				table.insert(result, { title = label, menu = sub_menu, disabled = sub_disabled })
				item_count = item_count + 1
			end

		elseif t == "dynamic" then
			local dyn_id = type(item.id) == "string" and item.id or ""
			if dyn_id ~= "" and type(dynamic_handlers[dyn_id]) == "function" then
				flush_sep()
				local ok = call_isolated(manifest_key, dyn_id, dynamic_handlers[dyn_id], result, ctx)
				if ok then item_count = item_count + 1 end
			else
				-- Same class of bug as the "action" branch above (F-HIGH-25): a
				-- misclassified or drifted id-bearing entry with no handler must
				-- never fail silently — it either belongs on this platform (and the
				-- caller's dyn_handlers table is missing a key) or the manifest entry
				-- needs a `platforms` restriction.
				Logger.warn(LOG, "No 'dynamic' handler registered for id '%s' in '%s' — item skipped.",
					tostring(dyn_id), manifest_key)
			end

		else
			Logger.warn(LOG, "Unknown item type '%s' in '%s' — skipped.", tostring(t), manifest_key)
		end

		::continue::
	end

	return result
end




-- ============================================
-- ============================================
-- ======= 4/ Built-in Group Builders =========
-- ============================================
-- ============================================

--- Builds a built-in named group that is always rendered the same way.
--- Returns the items table for the group submenu, or nil when unknown.
--- @param group_id string
--- @param ctx table
--- @return table|nil
function M.build_builtin_group(group_id, ctx)
	-- ctrl_shortcuts and cmd_shortcuts are rendered by menu_shortcuts.lua
	-- which has full access to ctx; no built-in here.
	Logger.warn(LOG, "Unknown built-in group '%s' — skipped.", group_id)
	return nil
end




-- ============================================
-- ============================================
-- ======= 5/ Manifest Data Accessors =========
-- ============================================
-- ============================================

--- Returns the full parsed manifest root, or nil on failure.
--- Useful for callers that need to access arbitrary manifest keys.
--- @return table|nil
function M.get_root()
	return get_manifest_root()
end

--- Returns the array at ``key`` in the manifest, or an empty table.
--- @param key string
--- @return table
function M.get_array(key)
	return get_menu_def(key)
end





-- ========================================================
-- =======================================================
-- ======= 6/ Declarative Disabled Resolver (MG-1) =======
-- =======================================================
-- ========================================================

--- Finds the manifest item with the given ``id`` inside the ``menu_key`` array.
--- @param menu_key string
--- @param item_id string
--- @return table|nil
local function find_item_by_id(menu_key, item_id)
	local menu_def = get_menu_def(menu_key)
	for _, item in ipairs(menu_def) do
		if type(item) == "table" and item.id == item_id then
			return item
		end
	end
	return nil
end

--- Evaluates the declarative ``disabled_when`` predicate of a manifest item
--- against a caller-supplied table of canonical state key -> zero-arg getter function.
---
--- ``disabled_when`` is an array of canonical state keys; the item is enabled
--- only when EVERY key's getter returns a truthy value — it is disabled as
--- soon as any one of them is falsy. Items without a ``disabled_when`` array
--- are never disabled by this mechanism (returns ``false``).
---
--- A missing getter for a declared key means the manifest and the driver's
--- getters table have drifted — logged as ERROR and treated as disabled so the
--- mismatch fails loud instead of silently rendering an always-enabled item.
--- @param menu_key string
--- @param item_id string
--- @param getters table
--- @return boolean
function M.resolve_disabled_when(menu_key, item_id, getters)
	local item = find_item_by_id(menu_key, item_id)
	if item == nil then
		-- A lookup miss means the caller passed an id that does not exist in
		-- menu_key's array — a typo'd or drifted manifest reference. Failing
		-- OPEN here would silently render a security-sensitive item (e.g. a
		-- keylogger-gated toggle) as always-enabled; fail CLOSED instead,
		-- matching the sibling getter-mismatch branch below.
		Logger.error(LOG, "No manifest item '%s.%s' — treating as disabled.", menu_key, item_id)
		return true
	end

	local keys = item.disabled_when
	if type(keys) ~= "table" or #keys == 0 then
		return false
	end

	for _, key in ipairs(keys) do
		if type(getters) ~= "table" or type(getters[key]) ~= "function" then
			Logger.error(LOG, "No getter for disabled_when key '%s' on item '%s.%s' — treating as disabled.", key, menu_key, item_id)
		return true
		end
		if not getters[key]() then
			return true
		end
	end

	return false
end




-- ========================================================
-- ========================================================
-- ======= 7/ Master-Gate Category Resolver (MG-3) ========
-- ========================================================
-- ========================================================

--- Returns the master-category name for a given sub-category id.
--- Reads master_gates.hotstring_sub_categories from the manifest (MG-3).
--- Hotstring sub-categories inherit the "Hotstrings" master; everything
--- else returns itself (first-segment = master).
--- @param category string Sub-category name (e.g. "Autocorrection", "Shortcuts").
--- @return string Master category name.
function M.resolve_master_gate(category)
	if category == nil or category == "" then
		return ""
	end
	local root = get_manifest_root()
	if type(root) ~= "table" then
		return category
	end
	local gates = root.master_gates
	if type(gates) ~= "table" then
		return category
	end
	local hotstring_subs = gates.hotstring_sub_categories
	if type(hotstring_subs) ~= "table" then
		-- Fallback: hardcoded list matching the shared catalog (MG-3).
		hotstring_subs = {"Autocorrection", "DistancesReduction", "SFBsReduction",
			"Rolls", "MagicKey", "DynamicHotstrings", "Personal"}
	end
	for _, sub in ipairs(hotstring_subs) do
		if sub == category then
			return "Hotstrings"
		end
	end
	return category
end

--- Returns the master_categories array from the manifest, or a hardcoded
--- fallback. Used by drivers to iterate known master gates.
--- @return table
function M.get_master_categories()
	local root = get_manifest_root()
	if type(root) ~= "table" then
		return {"Layout", "Shortcuts", "Hotstrings", "TapHolds"}
	end
	local gates = root.master_gates
	if type(gates) ~= "table" or type(gates.master_categories) ~= "table" then
		return {"Layout", "Shortcuts", "Hotstrings", "TapHolds"}
	end
	return gates.master_categories
end

return M
