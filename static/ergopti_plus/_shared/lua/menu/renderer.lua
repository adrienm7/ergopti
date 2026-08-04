--- _shared/lua/menu/renderer.lua

--- ==============================================================================
--- MODULE: Manifest Menu Renderer (shared)
--- DESCRIPTION:
--- Generic manifest-driven menu builder for the Lua drivers. Reads a ``*_menu``
--- array from ``menu_manifest.json`` and constructs a menu items table,
--- dispatching each item type to the appropriate render function.
---
--- WHY THIS IS SHARED AND WHAT MADE IT LOOK OTHERWISE.
--- It lived in ``macos/infra/manifest_menu.lua``, 561 lines, and read as a
--- Hammerspoon module: its docstrings say "hs.menubar item table" throughout.
--- It made exactly ONE Hammerspoon call — ``hs.json.decode`` — and the "hs.menubar
--- item table" is a plain Lua table of ``{title, fn, menu, checked, disabled}``.
--- The naming is what made a platform-neutral tree walker look platform-bound.
---
--- Two things genuinely were bound, and both are now parameters:
---   1. The JSON decoder, injected exactly as ``keycodes/evdev.lua`` injects one,
---      so macOS keeps C-speed ``hs.json.decode`` on its boot path and Linux
---      passes the pure-Lua ``require("json").decode``.
---   2. THE PLATFORM TOKEN. The original hardcoded ``is_for_hs(item)`` in the
---      middle of the build loop, and a first plan to extract this module missed
---      it and declared lines 93-559 "verbatim". Followed literally, Linux would
---      have rendered the macOS projection and silently dropped ``kanata``,
---      ``updates`` and ``apps`` — the exact three rows the top-level parity gate
---      was written to expose. AutoHotkey hardcodes its own token the same way
---      (``_MI_IsForAhk``), which is the concrete reason the two 561-line files
---      were never shareable as written.
---
--- FEATURES & RATIONALE:
--- 1. Single renderer: every submenu is built by the same loop — structure lives
---    in the manifest, not in per-submenu Lua code.
--- 2. Dynamic escape hatch: items whose ``type`` is ``"dynamic"`` are routed to a
---    caller-supplied table of handler functions so platform-specific UI stays in
---    the caller.
--- 3. A FACTORY, not a singleton. Each driver builds one instance at require
---    time. An ``M.init``-style singleton would have to warn-and-ignore a second
---    call per the module-init convention, and the test harness legitimately
---    re-configures with fresh stubs — which is precisely the case that
---    convention makes impossible. ``hotstring_engine`` is the precedent.
--- ==============================================================================

local M = {}

-- Used only to report a malformed `new()` call, which by definition happens
-- before an injected logger exists.
local BootLogger = require("logger.shim")

local LOG = "menu.renderer"

-- How deep a list provider's rows may nest. A provider returning a table that
-- contains itself would recurse until the stack gave out, taking the whole menu
-- with it; three levels is deeper than any menu the drivers draw. Kept equal to
-- windows/infra/manifest_menu.ahk's MR_MAX_LIST_DEPTH so a list that renders on
-- one driver cannot be silently truncated on another.
local MAX_LIST_DEPTH = 3

-- The master categories a driver falls back to when the manifest cannot be read
-- at all. Declared here rather than inline so the two readers below cannot
-- disagree about the list.
local MASTER_CATEGORIES_FALLBACK = { "Layout", "Shortcuts", "Hotstrings", "TapHolds" }

-- The hotstring sub-categories that inherit the "Hotstrings" master gate, used
-- only when the manifest omits the table.
local HOTSTRING_SUBS_FALLBACK = {
	"Autocorrection", "DistancesReduction", "SFBsReduction",
	"Rolls", "MagicKey", "DynamicHotstrings", "Personal",
}




-- ==================================================
-- ==================================================
-- ======= 1/ The Instance ==========================
-- ==================================================
-- ==================================================

--- Creates a renderer bound to one driver's manifest, decoder, i18n and platform.
---
--- @param deps table
---   platform      string   Platform token: "hs", "ahk" or "linux". The build
---                          loop filters every manifest entry on it.
---   manifest_path function Returns the absolute path to menu_manifest.json.
---                          A FUNCTION, not a string: the original resolved the
---                          path on every read, and the four unit files rely on
---                          that — they point the driver Paths module at a
---                          throwaway fixture directory per case.
---   json_decode   function JSON string → Lua value.
---   i18n          table    Must expose get(key) and section(key).
---   logger        table    The DRIVER's logger, not the shared shim. Injected so
---                          the renderer's diagnostics land in the driver's own
---                          log at the driver's own levels — and so a test that
---                          stubs the driver logger can observe them, which is
---                          how every one of this renderer's four unit files is
---                          written.
--- @return table|nil renderer, string|nil error
function M.new(deps)
	if type(deps) ~= "table" then
		BootLogger.error(LOG, "new(): deps must be a table — renderer not created.")
		return nil, "deps must be a table"
	end
	if type(deps.platform) ~= "string" or deps.platform == "" then
		BootLogger.error(LOG, "new(): deps.platform must be a non-empty string — renderer not created.")
		return nil, "deps.platform missing"
	end
	if type(deps.manifest_path) ~= "function" then
		BootLogger.error(LOG, "new(): deps.manifest_path must be a function — renderer not created.")
		return nil, "deps.manifest_path missing"
	end
	if type(deps.json_decode) ~= "function" then
		BootLogger.error(LOG, "new(): deps.json_decode must be a function — renderer not created.")
		return nil, "deps.json_decode missing"
	end
	if type(deps.i18n) ~= "table" or type(deps.i18n.get) ~= "function" or type(deps.i18n.section) ~= "function" then
		BootLogger.error(LOG, "new(): deps.i18n must expose get() and section() — renderer not created.")
		return nil, "deps.i18n missing"
	end
	if type(deps.logger) ~= "table" or type(deps.logger.warn) ~= "function" or type(deps.logger.error) ~= "function" then
		BootLogger.error(LOG, "new(): deps.logger must expose warn() and error() — renderer not created.")
		return nil, "deps.logger missing"
	end

	local platform      = deps.platform
	local manifest_path = deps.manifest_path
	local json_decode   = deps.json_decode
	local i18n          = deps.i18n
	local Logger        = deps.logger

	local R = {}

	-- Parsed manifest for the session — invalidated by R.invalidate_cache().
	local _cache = nil




	-- ==================================================
	-- ===== 1.1) Manifest Root Access Layer ============
	-- ==================================================

	--- Loads and caches the shared manifest JSON.
	--- @return table|nil
	local function get_manifest_root()
		if _cache ~= nil then
			return _cache
		end
		local path = manifest_path() or ""
		local ok_r, fh = pcall(io.open, path, "r")
		if not ok_r or not fh then
			Logger.error(LOG, "Cannot open menu_manifest.json at '%s'.", path)
			return nil
		end
		local content = fh:read("*a")
		fh:close()
		local ok_j, data = pcall(json_decode, content)
		if not ok_j or type(data) ~= "table" then
			Logger.error(LOG, "Failed to parse menu_manifest.json.")
			return nil
		end
		_cache = data
		return _cache
	end

	--- Invalidates the manifest cache.
	--- Call after a locale change or hot-reload so the next build re-reads the file.
	function R.invalidate_cache()
		_cache = nil
	end

	--- Returns the menu definition array at ``key``, or an empty table.
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




	-- ==================================================
	-- ===== 1.2) Platform Filter =======================
	-- ==================================================

	--- Returns true when the entry is visible on this instance's platform.
	--- An entry with no ``platforms`` restriction is visible everywhere.
	--- @param entry table Manifest item entry.
	--- @return boolean
	local function is_for_platform(entry)
		if type(entry) ~= "table" then return false end
		if type(entry.platforms) ~= "table" then return true end
		for _, p in ipairs(entry.platforms) do
			if p == platform then return true end
		end
		return false
	end

	--- The greyed stand-in for a row this platform does not have.
	---
	--- Returns nil unless the row carries a `reason_key`, which is what makes this
	--- a declaration rather than a guess: the manifest author wrote down why the
	--- row is absent here, in a key translated into all 21 locales, and this is the
	--- only thing that ever shows it to anyone.
	---
	--- Declared above the render loop deliberately. A `local` declared textually
	--- after the closure that calls it is captured as a nil GLOBAL, and the call
	--- then fails when a user opens the menu rather than when the file loads —
	--- three bugs of exactly that shape have been fixed in this codebase.
	--- @param entry table Manifest item entry, already known to be off-platform.
	--- @return table|nil A disabled menu row, or nil to keep the row hidden.
	local function render_unavailable(entry)
		local reason_key = entry.reason_key
		if type(reason_key) ~= "string" or reason_key == "" then return nil end

		local reason = i18n.get(reason_key)
		-- A key that does not resolve would put the raw dotted key in the menu,
		-- which reads as a crash. Hiding the row is the better failure: the user
		-- loses an explanation they were never getting before this existed.
		if type(reason) ~= "string" or reason == "" or reason == reason_key then
			Logger.warn(LOG, "reason_key '%s' has no translation — row hidden rather than shown raw.",
				reason_key)
			return nil
		end

		local label = type(entry.i18n) == "string" and i18n.get(entry.i18n) or nil
		if type(label) ~= "string" or label == "" or label == entry.i18n then
			-- Most restricted rows are `dynamic` and carry no label of their own —
			-- their title is built by a handler this platform does not have. The
			-- reason then IS the row, which is the honest rendering: there is nothing
			-- else true to say about it here.
			return { title = reason, disabled = true, fn = function() end }
		end
		return { title = label .. " — " .. reason, disabled = true, fn = function() end }
	end




	-- ==================================================
	-- ===== 1.3) Core Renderer =========================
	-- ==================================================

	--- Calls a manifest-driven handler under pcall isolation so a single broken
	--- entry cannot unwind through R.build and take down the entire menu tree —
	--- the single outer pcall in the caller's rebuild would otherwise catch the
	--- failure at the granularity of the WHOLE menu, not just this item.
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

	--- Turns a list provider's row DATA into menu item tables.
	---
	--- This is the only place a provider's rows become menu rows, which is the
	--- whole reason the two shapes differ: a provider hands over labels, callbacks
	--- and nested rows, and knows nothing about `title`, `fn` or `menu`. A row
	--- missing a label is dropped with a warning rather than rendered blank — an
	--- untitled row is a row the user cannot identify and cannot report.
	--- @param rows table Array of { label, action?, items?, checked?, disabled?, separator? }.
	--- @param list_id string The provider's id, for the warning.
	--- @param depth number|nil Current nesting depth, guarded against a cyclic table.
	--- @return table Array of menu item tables.
	local function render_rows(rows, list_id, depth)
		depth = depth or 1
		local out = {}
		if depth > MAX_LIST_DEPTH then
			Logger.error(LOG, "List '%s' nests deeper than %d level(s) — truncated.", tostring(list_id), MAX_LIST_DEPTH)
			return out
		end

		for _, row in ipairs(rows) do
			if type(row) ~= "table" then
				Logger.warn(LOG, "List '%s' produced a %s where a row was expected — skipped.", tostring(list_id), type(row))
			elseif row.separator then
				out[#out + 1] = { title = "-" }
			elseif type(row.label) ~= "string" or row.label == "" then
				Logger.warn(LOG, "List '%s' produced a row with no label — skipped.", tostring(list_id))
			else
				local entry = { title = row.label, disabled = row.disabled or nil }
				if row.checked ~= nil then entry.checked = row.checked and true or false end
				if type(row.items) == "table" then
					entry.menu = render_rows(row.items, list_id, depth + 1)
				elseif type(row.action) == "function" then
					entry.fn = row.action
				end
				out[#out + 1] = entry
			end
		end
		return out
	end

	--- Builds a built-in named group that is always rendered the same way.
	--- @param group_id string
	--- @param ctx table
	--- @return table|nil
	function R.build_builtin_group(group_id, ctx)  -- luacheck: ignore 212
		-- Nothing is built-in today: ctrl_shortcuts and cmd_shortcuts are rendered
		-- by the caller, which has full access to ctx.
		Logger.warn(LOG, "Unknown built-in group '%s' — skipped.", group_id)
		return nil
	end

	--- Builds a menu items table from a manifest menu definition array.
	---
	--- ``manifest_key``      — key in menu_manifest.json (e.g. ``"shortcuts_menu"``)
	--- ``category``          — human-readable category name for debug logs
	--- ``dynamic_handlers``  — table of id → function(items, ctx) for ``action`` and
	---   ``dynamic`` entries. Each handler appends its items to the list in place.
	--- ``group_builders``    — optional table of group_id → function(ctx) → table|nil
	---   for ``group`` entries. Returns ``{title, menu}``, a raw items list, or nil.
	--- ``list_providers``    — optional table of list_id → function(ctx) → rows for
	---   ``list`` entries. A provider returns DATA, never menu rows: each row is
	---   ``{label, action?, items?, checked?, disabled?, separator?}`` and this
	---   renderer turns it into the menu shape. The asymmetry is the point — a
	---   provider that could return a finished row would be building menu rows
	---   outside the renderer again, which is what the list type exists to stop.
	--- ``ctx``               — menu context passed through to handlers.
	--- @param manifest_key string
	--- @param category string
	--- @param dynamic_handlers table
	--- @param group_builders table|nil
	--- @param ctx table
	--- @param list_providers table|nil
	--- @return table
	function R.build(manifest_key, category, dynamic_handlers, group_builders, ctx, list_providers)  -- luacheck: ignore 212
		dynamic_handlers = dynamic_handlers or {}
		group_builders   = group_builders or {}
		list_providers   = list_providers or {}
		local menu_def    = get_menu_def(manifest_key)
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
			if not is_for_platform(item) then
				-- A row excluded from this platform that carries a translated
				-- explanation is rendered PRESENT and greyed, showing the reason,
				-- rather than dropped. Convention S: the difference between "not
				-- implemented here" and "removed" is exactly what a user of the
				-- other driver needs, and until 2026-08-04 five rows carried that
				-- explanation in 21 languages while every driver silently dropped
				-- them — the reason existed and nobody could ever read it.
				--
				-- Only rows with a reason survive the filter. A restriction with no
				-- explanation stays hidden, because a greyed row saying nothing is
				-- worse than an absent one: it occupies the menu and answers nothing.
				local explained = render_unavailable(item)
				if explained then
					flush_sep()
					table.insert(result, explained)
					item_count = item_count + 1
				end
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
					-- A manifest entry with an id but no matching handler renders one
					-- item short, permanently and undetected — log so a drifted
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
					built = R.build_builtin_group(group_id, ctx)
				end
				if type(built) == "table" then
					flush_sep()
					-- built may be a raw items list or a table with {menu=…, disabled=…}
					local sub_menu     = type(built.menu) == "table" and built.menu or built
					local sub_disabled = built.disabled or nil
					table.insert(result, { title = label, menu = sub_menu, disabled = sub_disabled })
					item_count = item_count + 1
				end

			elseif t == "list" then
				local list_id = type(item.id) == "string" and item.id or ""
				if list_id == "" or type(list_providers[list_id]) ~= "function" then
					-- Same class of bug as the "action" and "dynamic" branches: an entry
					-- whose provider is missing either belongs on this platform (and the
					-- caller's list_providers table has a hole) or needs a `platforms`
					-- restriction. Silence here is a menu section that vanishes.
					Logger.warn(LOG, "No 'list' provider registered for id '%s' in '%s' — item skipped.",
						tostring(list_id), manifest_key)
					goto continue
				end
				local ok_list, rows = call_isolated(manifest_key, list_id, list_providers[list_id], ctx)
				if ok_list and type(rows) == "table" and #rows > 0 then
					flush_sep()
					-- list_id is passed on purpose: every warning and the depth-truncation
					-- ERROR inside render_rows names it, and the top-level call was once
					-- the one caller omitting it — so the single diagnostic that
					-- identifies a truncated list said "List 'nil'".
					for _, row in ipairs(render_rows(rows, list_id, 1)) do
						table.insert(result, row)
						item_count = item_count + 1
					end
				end

			elseif t == "dynamic" then
				local dyn_id = type(item.id) == "string" and item.id or ""
				if dyn_id ~= "" and type(dynamic_handlers[dyn_id]) == "function" then
					flush_sep()
					local ok = call_isolated(manifest_key, dyn_id, dynamic_handlers[dyn_id], result, ctx)
					if ok then item_count = item_count + 1 end
				else
					-- Same class of bug as the "action" branch above: a misclassified or
					-- drifted id-bearing entry with no handler must never fail silently.
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




	-- ==================================================
	-- ===== 1.4) Manifest Data Accessors ===============
	-- ==================================================

	--- Returns the full parsed manifest root, or nil on failure.
	--- @return table|nil
	function R.get_root()
		return get_manifest_root()
	end

	--- Returns the array at ``key`` in the manifest, or an empty table.
	--- @param key string
	--- @return table
	function R.get_array(key)
		return get_menu_def(key)
	end




	-- ==================================================
	-- ===== 1.5) Declarative Predicate Resolvers =======
	-- ==================================================

	--- Finds the manifest item with the given ``id`` inside the ``menu_key`` array.
	--- @param menu_key string
	--- @param item_id string
	--- @return table|nil
	local function find_item_by_id(menu_key, item_id)
		for _, item in ipairs(get_menu_def(menu_key)) do
			if type(item) == "table" and item.id == item_id then
				return item
			end
		end
		return nil
	end

	--- Evaluates the declarative ``disabled_when`` predicate of a manifest item
	--- against a caller-supplied table of canonical state key → zero-arg getter.
	---
	--- The item is enabled only when EVERY key's getter returns truthy — it is
	--- disabled as soon as one is falsy. Items without the array are never
	--- disabled by this mechanism.
	---
	--- FAILS CLOSED. A missing getter means the manifest and the driver's getters
	--- have drifted; rendering an always-enabled item would silently expose a
	--- gated one.
	--- @param menu_key string
	--- @param item_id string
	--- @param getters table
	--- @return boolean
	function R.resolve_disabled_when(menu_key, item_id, getters)
		local item = find_item_by_id(menu_key, item_id)
		if item == nil then
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

	--- Evaluates the declarative ``checked_when`` predicate — the mirror of
	--- ``disabled_when``, checked only when EVERY getter returns truthy.
	---
	--- FAILS OPEN, unlike its sibling, and the asymmetry is deliberate. A checkmark
	--- is an ASSERTION to the user that something is currently on. Inventing one
	--- when the state cannot be read tells them a filter is active that is not —
	--- they stop looking for the setting, and the data they thought was excluded is
	--- being recorded. In both directions the safe answer is the one that does not
	--- overstate what is enabled.
	--- @param menu_key string
	--- @param item_id string
	--- @param getters table
	--- @return boolean
	function R.resolve_checked_when(menu_key, item_id, getters)
		local item = find_item_by_id(menu_key, item_id)
		if item == nil then
			Logger.error(LOG, "No manifest item '%s.%s' — treating as unchecked.", menu_key, item_id)
			return false
		end

		local keys = item.checked_when
		if type(keys) ~= "table" or #keys == 0 then
			return false
		end

		for _, key in ipairs(keys) do
			if type(getters) ~= "table" or type(getters[key]) ~= "function" then
				Logger.error(LOG, "No getter for checked_when key '%s' on item '%s.%s' — treating as unchecked.", key, menu_key, item_id)
				return false
			end
			if not getters[key]() then
				return false
			end
		end

		return true
	end




	-- ==================================================
	-- ===== 1.6) Master-Gate Category Resolver =========
	-- ==================================================

	--- Returns the master-category name for a given sub-category id.
	--- Hotstring sub-categories inherit the "Hotstrings" master; everything else
	--- returns itself.
	--- @param category string Sub-category name (e.g. "Autocorrection").
	--- @return string Master category name.
	function R.resolve_master_gate(category)
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
			hotstring_subs = HOTSTRING_SUBS_FALLBACK
		end
		for _, sub in ipairs(hotstring_subs) do
			if sub == category then
				return "Hotstrings"
			end
		end
		return category
	end

	--- Returns the master_categories array from the manifest, or the fallback.
	--- @return table
	function R.get_master_categories()
		local root = get_manifest_root()
		if type(root) ~= "table" then
			return MASTER_CATEGORIES_FALLBACK
		end
		local gates = root.master_gates
		if type(gates) ~= "table" or type(gates.master_categories) ~= "table" then
			return MASTER_CATEGORIES_FALLBACK
		end
		return gates.master_categories
	end

	return R
end

return M
