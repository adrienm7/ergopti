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

-- The caption value is literal data; percent escapes belong to the translation.
local function caption_format(format, value)
	if type(format) ~= "string" then return nil, false end
	local parts, found, index = {}, false, 1
	while index <= #format do
		local character = format:sub(index, index)
		local following = format:sub(index + 1, index + 1)
		if character == "%" and following == "%" then
			parts[#parts + 1], index = "%", index + 2
		elseif character == "%" and following == "s" then
			parts[#parts + 1], found, index = value, true, index + 2
		else
			parts[#parts + 1], index = character, index + 1
		end
	end
	return table.concat(parts), found
end

-- Used only to report a malformed `new()` call, which by definition happens
-- before an injected logger exists.
local BootLogger = require("logger.shim")

local LOG = "menu.renderer"

-- How deep a list provider's rows may nest. A provider returning a table that
-- contains itself would recurse until the stack gave out, taking the whole menu
-- with it, so this is a runaway-recursion guard — NOT a statement about how deep
-- a menu may legitimately be. Kept equal to windows/infra/manifest_menu.ahk's
-- MR_MAX_LIST_DEPTH so a list that renders on one driver cannot be silently
-- truncated on another.
--
-- Raised 3 → 8 on 2026-08-07. Three was documented as "deeper than any menu the
-- drivers draw" and that was already false: the personal-extensions tree follows
-- a folder the USER writes, so its depth is theirs to choose, and a single level
-- of subfolder already reaches four — the personal row, the tree, a folder, its
-- files. A cap sized for a hand-declared menu cannot bound a filesystem. Eight
-- allows six levels of user nesting while staying far from any stack risk, and
-- the scanner feeding it stops at sixteen regardless.
local MAX_LIST_DEPTH = 8

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

	--- The short form of a translated reason: the text before its first colon,
	--- ASCII or full-width, which every platform reason opens with (« Not on
	--- macOS yet: … »), or the whole text when it has none.
	--- @param text string Translated reason.
	--- @return string head
	local function reason_head(text)
		local cut = nil
		for _, mark in ipairs({ ":", "\239\188\154" }) do
			local at = text:find(mark, 1, true)
			if at and (cut == nil or at < cut) then cut = at end
		end
		local head = cut and text:sub(1, cut - 1) or text
		return (head:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	--- The disabled stand-in of a row this platform has not yet ported: its
	--- label and the short form of its translated reason. The manifest generator
	--- refuses a `grey` row without both keys, so a missing one here is a stale
	--- manifest, reported and not drawn.
	--- @param manifest_key string Menu definition key, for the report.
	--- @param item table Manifest entry declaring `unavailable = "grey"`.
	--- @return table|nil row
	local function greyed_stand_in(manifest_key, item)
		if type(item.i18n) ~= "string" or type(item.reason_key) ~= "string" then
			Logger.error(LOG, "Greyed row '%s' in '%s' lacks its label or reason — not drawn.",
				tostring(item.id or item.i18n), manifest_key)
			return nil
		end
		return { title = i18n.get(item.i18n) .. " — " .. reason_head(i18n.get(item.reason_key)), disabled = true }
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

	--- Reports a row written in the DRIVER dialect, field by field.
	---
	--- `title`, `fn` and `menu` are what hs.menubar consumes; a provider hands over
	--- `label`, `action` and `items`. The two shapes are deliberately different, and
	--- the cost of writing the wrong one used to be paid in silence: a `title` is
	--- not a label, so the row was dropped with a generic warning, and a `menu` was
	--- simply never read, so the row appeared with its whole subtree missing and
	--- nothing at all was logged.
	---
	--- Both happened, three times, in the days this menu moved onto the renderer —
	--- the About submenu lost its version row and its channel picker, every macOS
	--- hotstring category lost its sections, and the extension tree lost every file
	--- row AND threw while sorting rows that no longer had the field it sorted on.
	--- Each was invisible until someone opened the menu and looked. So drift now
	--- names the field it found and the row it found it on.
	--- @param row table The offending row.
	--- @param list_id string The provider's id.
	local function report_driver_dialect(row, list_id)
		local named = tostring(row.label or row.title or "?")
		if row.title ~= nil and row.label == nil then
			Logger.error(LOG, "List '%s' row '%s' uses `title` — a provider row says `label`, so this row is dropped.",
				tostring(list_id), named)
		end
		if row.menu ~= nil and row.items == nil and row.submenu == nil then
			Logger.error(LOG, "List '%s' row '%s' hangs its subtree on `menu` — a provider row says `items` (or "
				.. "`submenu` for a tree already built), so the row renders with nothing under it.",
				tostring(list_id), named)
		end
		if row.fn ~= nil and row.action == nil then
			Logger.error(LOG, "List '%s' row '%s' carries `fn` — a provider row says `action`, so the row does "
				.. "nothing when clicked.", tostring(list_id), named)
		end
		-- A row that opens a submenu is never clicked: AppKit sends no action for
		-- it and neither appindicator nor Win32 binds one. The subtree wins below,
		-- so this action is dropped — which is how Gestures, Shortcuts, Metrics
		-- and the Hotstrings master became impossible to switch on from the macOS
		-- menu bar while their switch sat on the parent row.
		if row.action ~= nil and (row.items ~= nil or row.submenu ~= nil) then
			Logger.error(LOG, "List '%s' row '%s' carries both an `action` and a subtree — a row that opens a "
				.. "submenu is never clicked, so the action can never run.", tostring(list_id), named)
		end
	end

	--- Returns true when a menu item table is a separator.
	--- @param entry any
	--- @return boolean
	local function is_separator(entry)
		return type(entry) == "table" and entry.title == "-"
	end

	--- Drops every separator that would not sit between two real rows, in place.
	---
	--- The deferred `---` in R.build only sees the manifest's own separators. A
	--- list provider or a dynamic handler brings separators of its own, and one
	--- landing next to a manifest `---`, or at either end of a menu, drew two lines
	--- in a row. Submenus are normalised too, since a provider nests rows freely.
	--- @param items table Array of menu item tables; `{ title = "-" }` is a separator.
	--- @return table The same array.
	local function normalize_separators(items)
		local kept = {}
		for _, entry in ipairs(items) do
			if is_separator(entry) then
				if #kept > 0 and not is_separator(kept[#kept]) then kept[#kept + 1] = entry end
			else
				if type(entry) == "table" and type(entry.menu) == "table" then
					normalize_separators(entry.menu)
				end
				kept[#kept + 1] = entry
			end
		end
		while is_separator(kept[#kept]) do kept[#kept] = nil end
		for i = 1, math.max(#items, #kept) do items[i] = kept[i] end
		return items
	end

	--- Turns a list provider's row DATA into menu item tables.
	---
	--- This is the only place a provider's rows become menu rows, which is the
	--- whole reason the two shapes differ: a provider hands over labels, callbacks
	--- and nested rows, and knows nothing about `title`, `fn` or `menu`. A row
	--- missing a label is dropped with a warning rather than rendered blank — an
	--- untitled row is a row the user cannot identify and cannot report.
	--- @param rows table Array of { label, action?, items?, checked?, disabled?,
	---   disabled_reason_key?, separator? }.
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
				report_driver_dialect(row, list_id)
				Logger.warn(LOG, "List '%s' produced a row with no label — skipped.", tostring(list_id))
			else
				report_driver_dialect(row, list_id)
				local entry = { title = row.label, disabled = row.disabled or nil }
				-- A greyed row that names why (`disabled_reason_key`) reads like every
				-- greyed row with a reason, « label — head of the reason », and has
				-- nothing to run.
				local greyed = row.disabled == true and type(row.disabled_reason_key) == "string"
				if greyed then entry.title = row.label .. " — " .. reason_head(i18n.get(row.disabled_reason_key)) end
				if row.checked ~= nil then entry.checked = row.checked and true or false end
				-- An optional per-row image, the Lua twin of the AutoHotkey renderer's
				-- `icon`. Without it a provider had to choose between reaching the
				-- renderer and keeping its icons: the bundled-apps list went through an
				-- adapter that carried label, tick and greying and silently left the
				-- app icons behind, so every row in that menu rendered blank-faced.
				if row.image ~= nil then entry.image = row.image end
				if type(row.items) == "table" then
					entry.menu = render_rows(row.items, list_id, depth + 1)
				elseif type(row.submenu) == "table" then
					-- A subtree this driver has ALREADY built, handed over whole.
					--
					-- TRANSITIONAL, and narrow on purpose — the AutoHotkey renderer
					-- carries the same field for the same reason. The row itself is
					-- materialised here, which is the point; only the tree hanging off
					-- it is still the driver's, and that tree is usually built by a
					-- different subsystem (the app picker, the shortcut chooser).
					--
					-- It is deliberately NOT `items`: a caller must say which of the two
					-- it is handing over, so a finished menu passed where row data was
					-- expected fails visibly instead of rendering an empty submenu.
					entry.menu = row.submenu
				elseif type(row.action) == "function" and not greyed then
					entry.fn = row.action
				end
				out[#out + 1] = entry
			end
		end
		return out
	end

	--- Materialises row DATA that reaches the renderer outside a `list` entry.
	---
	--- The second entry point, and the narrower one: a submenu whose PARENT row is
	--- still the driver's — because its label carries runtime state the manifest
	--- cannot express, a health dot or a model name — can still hand its contents
	--- over as data. Without this the whole subtree would stay hand-built merely
	--- because one row above it is.
	---
	--- @param rows table Array of { label, action?, items?, checked?, disabled?, separator? }.
	--- @param list_id string An id for the warnings, so a bad row names its source.
	--- @return table Array of menu item tables; empty when rows is not a table.
	function R.render_rows(rows, list_id)  -- luacheck: ignore 212
		if type(rows) ~= "table" then
			Logger.warn(LOG, "List '%s' got no row array to render — nothing built.", tostring(list_id))
			return {}
		end
		return normalize_separators(render_rows(rows, list_id, 1))
	end

	--- Admits a completed native child tree as detached provider rows.
	--- This pure boundary never invokes callbacks or observes a native owner.
	--- @param children table Dense native rows using title, fn and menu.
	--- @return table|nil rows Nil refuses the complete tree before publication.
	function R.native_child_rows(children)
		local active = {}
		local function convert(rows, depth)
			if type(rows) ~= "table" or getmetatable(rows) ~= nil or active[rows]
				or depth > MAX_LIST_DEPTH then return nil end
			local count, maximum = 0, 0
			for index in next, rows do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return nil end
				count, maximum = count + 1, math.max(maximum, index)
			end
			if count ~= maximum then return nil end
			active[rows] = true
			local result = {}
			for index = 1, count do
				local child = rawget(rows, index)
				if type(child) ~= "table" or getmetatable(child) ~= nil then return nil end
				for field in next, child do
					if field ~= "title" and field ~= "fn" and field ~= "menu" and field ~= "checked"
						and field ~= "disabled" and field ~= "image" then return nil end
				end
				local title, action, subtree = rawget(child, "title"), rawget(child, "fn"), rawget(child, "menu")
				local checked, disabled, image = rawget(child, "checked"), rawget(child, "disabled"), rawget(child, "image")
				if type(title) ~= "string" or title == "" or (action ~= nil and type(action) ~= "function")
					or (subtree ~= nil and type(subtree) ~= "table") or (action ~= nil and subtree ~= nil)
					or (checked ~= nil and type(checked) ~= "boolean")
					or (disabled ~= nil and type(disabled) ~= "boolean")
					or (image ~= nil and type(image) ~= "userdata" and type(image) ~= "string") then return nil end
				local row
				if title == "-" then
					if action ~= nil or subtree ~= nil or checked ~= nil or disabled ~= nil or image ~= nil then return nil end
					row = { separator = true }
				else
					row = { label = title, action = action, checked = checked, disabled = disabled, image = image }
					if subtree ~= nil then
						row.items = convert(subtree, depth + 1)
						if row.items == nil then return nil end
					end
				end
				result[index] = row
			end
			active[rows] = nil
			return result
		end
		local rows = convert(children, 1)
		return rows
	end

	--- Builds a built-in named group that is always rendered the same way.
	--- @param group_id string
	--- @param ctx table
	--- @return table|nil
	function R.build_builtin_group(group_id, ctx)  -- luacheck: ignore 212
		-- Nothing is built-in today: every group is rendered by the caller, which
		-- has full access to ctx.
		Logger.warn(LOG, "Unknown built-in group '%s' — skipped.", group_id)
		return nil
	end

	--- Builds provider data from the same choice declaration used by ordinary rows.
	--- @param item table Published choice metadata.
	--- @param manifest_key string Owning menu declaration.
	--- @param commands table Existing native mutation owners.
	--- @param getters table Existing native state readers.
	--- @return table|nil row
	local function choice_row_data(item, manifest_key, commands, getters)
		local row_id   = type(item.id) == "string" and item.id or ""
		local i18n_key = type(item.i18n) == "string" and item.i18n or ""
		local path     = type(item.path) == "string" and item.path or ""
		local cmd_id   = type(item.command) == "string" and item.command or row_id
		local fn       = commands[cmd_id]
		local choices  = type(item.choices) == "table" and item.choices or {}

		if row_id == "" or i18n_key == "" or path == "" or #choices == 0 then
			Logger.error(LOG, "'choice' item in '%s' needs id, i18n, path and choices — skipped.", manifest_key)
			return nil
		end
		if type(fn) ~= "function" then
			Logger.error(LOG, "No command '%s' registered for the '%s.%s' choice — skipped.",
				tostring(cmd_id), manifest_key, row_id)
			return nil
		end

		local current = nil
		if type(getters[path]) == "function" then
			current = getters[path]()
		else
			-- Fails open like checked_when: no value is ticked rather than a
			-- guessed one, and the drift is loud.
			Logger.error(LOG, "No getter for the '%s' value of choice '%s.%s' — nothing is ticked.",
				path, manifest_key, row_id)
		end

		local sub = {}
		local current_label = nil
		for _, choice in ipairs(choices) do
			local value = choice.value
			local label = (choice.label_prefix or "") .. (choice.label or i18n.get(choice.i18n))
			if current == value then
				current_label = choice.current_i18n and i18n.get(choice.current_i18n) or label
			end
			sub[#sub + 1] = {
				label   = label,
				checked = current == value,
				action  = function() return fn(value) end,
			}
		end
		local title = i18n.get(i18n_key) .. (item.current_choice_suffix or "")
		-- Caption interpolation is declared alongside the shared choice, so
		-- native consumers provide no competing mode-label policy.
		if item.show_current_choice == true then
			title = title:gsub(item.current_choice_placeholder or "{1}", function() return current_label or tostring(current or "") end)
		end
		return {
			label = title, items = sub,
			disabled = R.resolve_disabled_when(manifest_key, row_id, getters) or nil,
		}
	end

	--- Supplies one declared choice as provider data, without a private row policy.
	--- @param manifest_key string Owning menu declaration.
	--- @param row_id string Declared choice identity.
	--- @param commands table Existing native mutation owners.
	--- @param getters table Existing native state readers.
	--- @return table|nil row
	function R.choice_row(manifest_key, row_id, commands, getters)
		for _, item in ipairs(get_menu_def(manifest_key)) do
			if item.type == "choice" and item.id == row_id and is_for_platform(item) then
				return choice_row_data(item, manifest_key, commands or {}, getters or {})
			end
		end
		Logger.error(LOG, "Missing declared choice '%s.%s' — provider row refused.", manifest_key, row_id)
		return nil
	end

	--- Builds the shared native shape for a declared command or checkbox.
	--- @param item table Canonical declaration.
	--- @param manifest_key string Owning menu declaration.
	--- @param commands table Native command owners.
	--- @param getters table Native state readers.
	--- @return table|nil row
	local function command_item(item, manifest_key, commands, getters)
		local t = item.type
		local row_id   = type(item.id) == "string" and item.id or ""
		local i18n_key = type(item.i18n) == "string" and item.i18n or ""
		-- `command` defaults to the id, because the two are the same name in
		-- every case so far and repeating it is a second thing to get wrong.
		local cmd_id = type(item.command) == "string" and item.command or row_id
		local fn     = commands[cmd_id]

		if row_id == "" or i18n_key == "" then
			Logger.warn(LOG, "'%s' item missing id or i18n in '%s' — skipped.", t, manifest_key)
			return nil
		end
		if type(fn) ~= "function" then
			-- Same class as the "action" branch: a declared row whose command
			-- the driver never registered renders one item short, permanently
			-- and undetected.
			Logger.warn(LOG, "No command '%s' registered for '%s.%s' — item skipped.",
				tostring(cmd_id), manifest_key, row_id)
			return nil
		end

		local disabled = R.resolve_disabled_when(manifest_key, row_id, getters)
		-- Greyed by `disabled_when` with the reason it declares, the row is
		-- drawn as the same stand-in as a row this platform has not yet
		-- ported, « label — head of the reason », with nothing to run: the
		-- two differ only in how the condition is evaluated.
		if disabled and type(item.disabled_reason_key) == "string" then
			return greyed_stand_in(manifest_key,
				{ id = row_id, i18n = i18n_key, reason_key = item.disabled_reason_key })
		end
		local built = {
			title    = i18n.get(i18n_key),
			fn       = fn,
			disabled = disabled or nil,
		}
		-- Only "check" carries a tick. A "command" is a plain action row, and
		-- giving it `checked = false` would draw an empty checkbox next to a
		-- row that toggles nothing.
		if t == "check" then
			built.checked = R.resolve_checked_when(manifest_key, row_id, getters)
		end
		return built

	end

	--- Supplies a declared command as provider data through the same row policy.
	--- A retained provider callback rechecks its declaration before delivery.
	--- @param manifest_key string Owning menu declaration.
	--- @param row_id string Declared command identity.
	--- @param commands table Native command owners.
	--- @param getters table Native state readers.
	--- @return table|nil row
	function R.command_row(manifest_key, row_id, commands, getters)
		commands, getters = commands or {}, getters or {}
		for _, item in ipairs(get_menu_def(manifest_key)) do
			if item.type == "command" and item.id == row_id and is_for_platform(item) then
				local built = command_item(item, manifest_key, commands, getters)
				if not built then return nil end
				local action = built.fn
				return {
					label = built.title, disabled = built.disabled,
					action = type(action) == "function" and function(...)
						if R.resolve_disabled_when(manifest_key, row_id, getters) then return false end
						return action(...)
					end or nil,
				}
			end
		end
		Logger.error(LOG, "Missing declared command '%s.%s' — provider row refused.", manifest_key, row_id)
		return nil
	end

	--- Supplies an ordered declared child template as provider data.
	--- Includes reuse the original command declaration and retained readiness gate.
	--- Native owners provide only callbacks, current caption values and child data.
	--- @param manifest_key string Owning shared child declaration.
	--- @param commands table Native command owners.
	--- @param getters table Native state and caption readers.
	--- @param children table Native group data and zero-argument list providers indexed by identity.
	--- @return table|nil rows
	local function template_rows(manifest_key, commands, getters, children, status_definition)
		commands, getters, children = commands or {}, getters or {}, children or {}
		local visiting = {}
		local function native_children(key, id, provider)
			local ok, supplied = false, nil
			if type(provider) == "function" then ok, supplied = pcall(provider) end
			local valid, count, maximum = ok and type(supplied) == "table", 0, 0
			if valid then
				for index, child in next, supplied do
					count = count + 1
					if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then
						valid = false
					else
						maximum = math.max(maximum, index)
					end
					if type(child) ~= "table" or rawget(child, "title") ~= nil
						or rawget(child, "fn") ~= nil or rawget(child, "menu") ~= nil
						or (rawget(child, "separator") ~= nil and type(rawget(child, "separator")) ~= "boolean")
						or (rawget(child, "separator") ~= true and (type(rawget(child, "label")) ~= "string"
							or rawget(child, "label") == "")) then valid = false end
				end
			end
			if not valid or count ~= maximum then
				Logger.error(LOG, "Invalid native child provider '%s.%s' — template rows refused.", key, tostring(id))
				return nil
			end
			local canonical = {}
			for index = 1, count do canonical[index] = rawget(supplied, index) end
			return canonical
		end
		-- Omission is only for declared inert presentation; preflight before any getter or action.
		local function inert_presentation(key, row_id, checking)
			local declaration = get_menu_def(key)
			if getmetatable(declaration) ~= nil then return false end
			local count, maximum = 0, 0
			for index in next, declaration do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return false end
				count, maximum = count + 1, math.max(maximum, index)
			end
			if checking[key] or count == 0 or count ~= maximum then return false end
			if row_id ~= nil then
				local matches = 0
				for _, item in ipairs(declaration) do
					if type(item) == "table" and rawget(item, "id") == row_id then matches = matches + 1 end
				end
				if matches ~= 1 then return false end
			end
			checking[key] = true
			for _, item in ipairs(declaration) do
				if type(item) ~= "table" or getmetatable(item) ~= nil then return false end
				local fields
				if item.type == "include" then
					fields = { type = true, section = true, row_id = true }
					if type(item.section) ~= "string" or item.section == ""
						or (item.row_id ~= nil and (type(item.row_id) ~= "string" or item.row_id == ""))
						or not inert_presentation(item.section, item.row_id, checking) then return false end
				elseif item.type == "---" then
					fields = { type = true, platforms = true, unavailable = true }
					if item.unavailable ~= nil and item.unavailable ~= "hide" then return false end
				elseif item.type == "label" or item.type == "section_header" then
					fields = { type = true, id = true, i18n = true, platforms = true, unavailable = true }
					if type(item.i18n) ~= "string" or item.i18n == ""
						or (item.id ~= nil and (type(item.id) ~= "string" or item.id == ""))
						or (item.type == "label" and item.id == nil) then return false end
					if item.type == "section_header" then
						fields.reason_key = true
						if item.unavailable ~= nil and item.unavailable ~= "hide" and item.unavailable ~= "grey" then return false end
						if item.unavailable == "grey" and item.reason_key == nil then return false end
						if item.reason_key ~= nil and (type(item.reason_key) ~= "string" or item.reason_key == ""
							or item.unavailable == "hide") then return false end
					elseif item.unavailable ~= nil and item.unavailable ~= "hide" then return false end
				else return false end
				for field in next, item do if not fields[field] then return false end end
				if item.platforms ~= nil then
					if type(item.platforms) ~= "table" or getmetatable(item.platforms) ~= nil then return false end
					local seen, count, maximum = {}, 0, 0
					for index, value in next, item.platforms do
						if type(index) ~= "number" or index % 1 ~= 0 or index < 1
							or (value ~= "ahk" and value ~= "hs" and value ~= "linux") or seen[value] then return false end
						seen[value], count, maximum = true, count + 1, math.max(maximum, index)
					end
					if count == 0 or count ~= maximum then return false end
				end
			end
			checking[key] = nil
			return true
		end
		local function collect(key, row_id)
			local declaration = status_definition or get_menu_def(key)
			if row_id ~= nil then
				local selected, matches = nil, 0
				for _, item in ipairs(declaration) do
					if item.id == row_id then selected, matches = item, matches + 1 end
				end
				if type(row_id) ~= "string" or row_id == "" or matches ~= 1 then
					Logger.error(LOG, "Missing or ambiguous child-template row '%s.%s' — rows refused.", key, tostring(row_id))
					return nil
				end
				declaration = { selected }
			end
			if visiting[key] or #declaration == 0 then
				Logger.error(LOG, "Missing or cyclic child template '%s' — provider rows refused.", key)
				return nil
			end
			visiting[key] = true
			local rows = {}
			for _, item in ipairs(declaration) do
				if item.on_refusal ~= nil and item.type ~= "include" then
					Logger.error(LOG, "Invalid presentation omission policy in '%s' — rows refused.", key)
					return nil
				end
				if is_for_platform(item) or (item.type == "section_header" and item.unavailable == "grey") then
					local row
					if item.type == "include" then
						local fields = { type = true, section = true, row_id = true, present_when = true, on_refusal = true }
						local target = type(item.section) == "string" and get_menu_def(item.section) or {}
						local omit = item.on_refusal == "omit_presentation"
						local valid = type(item.section) == "string" and item.section ~= ""
							and (item.on_refusal == nil or omit) and (omit or #target > 0)
						for field in pairs(item) do if not fields[field] then valid = false end end
						if item.row_id ~= nil then
							local matches = 0
							if type(item.row_id) ~= "string" or item.row_id == "" then
								valid = false
							elseif omit then
								for _, child in next, target do
									if type(child) == "table" and rawget(child, "id") == item.row_id then matches = matches + 1 end
								end
							else
								for _, child in ipairs(target) do if child.id == item.row_id then matches = matches + 1 end end
							end
							valid = valid and type(item.row_id) == "string" and item.row_id ~= "" and matches == 1
						end
						if not valid then
							Logger.error(LOG, "Invalid child-template include in '%s' — rows refused.", key)
							return nil
						end
						local present = true
						if item.present_when ~= nil then
							local getter = type(item.present_when) == "string" and item.present_when ~= "" and getters[item.present_when]
							local ok, value = false, nil
							if type(getter) == "function" then ok, value = pcall(getter) end
							if not ok or type(value) ~= "boolean" then
								Logger.error(LOG, "Invalid child-template presence getter in '%s' — rows refused.", key)
								return nil
							end
							present = value
						end
						local presentation_valid = not omit or inert_presentation(item.section, item.row_id, {})
						if not presentation_valid then
							Logger.error(LOG, "Invalid inert presentation include '%s' in '%s' — presentation omitted.", item.section, key)
						elseif present then
							local included = type(item.section) == "string" and collect(item.section, item.row_id) or nil
							if not included then return nil end
							for _, child in ipairs(included) do rows[#rows + 1] = child end
						end
					elseif item.type == "list" then
						local fields = { type = true, id = true, platforms = true, unavailable = true }
						for field in pairs(item) do
							if not fields[field] then
								Logger.error(LOG, "Invalid child-template list in '%s' — rows refused.", key)
								return nil
							end
						end
						local provider = type(item.id) == "string" and item.id ~= "" and children[item.id]
						local supplied = native_children(key, item.id, provider)
						if not supplied then return nil end
						for _, child in ipairs(supplied) do rows[#rows + 1] = child end
					elseif item.type == "---" then
						row = { separator = true }
					elseif status_definition and item.type == "label" then
						row = { label = i18n.get(item.i18n), disabled = true }
					elseif item.type == "label" then
						local fields = { type = true, id = true, i18n = true, platforms = true, unavailable = true, caption_getter = true }
						local valid = type(item.id) == "string" and item.id ~= ""
							and type(item.i18n) == "string" and item.i18n ~= ""
							and (item.unavailable == nil or item.unavailable == "hide")
						valid = valid and (item.caption_getter == nil or (type(item.caption_getter) == "string"
							and item.caption_getter ~= "" and type(item.id) == "string" and item.id ~= ""))
						for field in pairs(item) do if not fields[field] then valid = false end end
						if not valid then
							Logger.error(LOG, "Invalid inert label in template '%s' — provider rows refused.", key)
							return nil
						end
						row = { label = i18n.get(item.i18n), disabled = true }
					elseif item.type == "section_header" then
						local fields = { type = true, id = true, i18n = true, platforms = true,
							unavailable = true, reason_key = true, caption_getter = true }
						local valid = (item.id == nil or (type(item.id) == "string" and item.id ~= ""))
							and type(item.i18n) == "string" and item.i18n ~= ""
							and (item.unavailable == nil or item.unavailable == "hide" or item.unavailable == "grey")
							and (item.unavailable ~= "grey" or item.reason_key ~= nil)
							and (item.reason_key == nil or (type(item.reason_key) == "string"
								and item.reason_key ~= "" and item.unavailable ~= "hide"))
						valid = valid and (item.caption_getter == nil or (type(item.caption_getter) == "string"
							and item.caption_getter ~= "" and type(item.id) == "string" and item.id ~= ""))
						for field in pairs(item) do if not fields[field] then valid = false end end
						if not valid then
							Logger.error(LOG, "Invalid section header in template '%s' — provider rows refused.", key)
							return nil
						end
						if is_for_platform(item) then
							row = { label = i18n.section(item.i18n), disabled = true }
						else
							local stand_in = greyed_stand_in(key, item)
							if not stand_in then return nil end
							row = { label = stand_in.title, disabled = true }
						end
					elseif item.type == "command" then
						row = R.command_row(key, item.id, commands, getters)
						if not row then return nil end
					elseif item.type == "check" then
						row = R.check_row(key, item.id, commands, getters)
						if not row then return nil end
					elseif item.type == "group" and (type(children[item.id]) == "table" or type(children[item.id]) == "function") then
						local items = children[item.id]
						if type(items) == "function" then items = native_children(key, item.id, items) end
						if not items then return nil end
						row = { label = i18n.get(item.i18n), items = items }
						if item.disabled_when ~= nil and R.resolve_disabled_when(key, item.id, getters) then
							row.disabled = true
							row.disabled_reason_key = item.disabled_reason_key
						end
					else
						Logger.error(LOG, "Missing child data or unsupported row in template '%s' — provider rows refused.", key)
						return nil
					end
					if row and item.caption_getter ~= nil then
						local raw_title = i18n.get(item.i18n)
						if item.type == "label" or item.type == "section_header" then
							local _, source_slot = caption_format(raw_title, "")
							if not source_slot then
								Logger.error(LOG, "Invalid inert caption format in template '%s' — provider rows refused.", key)
								return nil
							end
						end
						local getter = getters[item.caption_getter]
						local value = type(getter) == "function" and getter() or nil
						local title = item.type == "section_header" and row.label or raw_title
						if type(value) ~= "string" then
							Logger.error(LOG, "Invalid caption getter in template '%s' — provider rows refused.", key)
							return nil
						end
						local caption, formatted = caption_format(title, value)
						if (item.type == "label" or item.type == "section_header") and not formatted then
							Logger.error(LOG, "Invalid inert caption format in template '%s' — provider rows refused.", key)
							return nil
						end
						row.label = caption
					end
					if row then rows[#rows + 1] = row end
				end
			end
			visiting[key] = nil
			return rows
		end
		return collect(manifest_key)
	end

	function R.template_rows(manifest_key, commands, getters, children)
		return template_rows(manifest_key, commands, getters, children)
	end

	--- Supplies inert status declared on an existing live provider row.
	--- No callbacks, getters or children can be declared in status data.
	--- @param manifest_key string Owning menu declaration.
	--- @param row_id string Existing provider identity.
	--- @param status string Named native status to project.
	--- @return table|nil rows
	function R.status_rows(manifest_key, row_id, status)
		local owner
		for _, item in ipairs(get_menu_def(manifest_key)) do
			if item.id == row_id then owner = item; break end
		end
		local statuses = owner and owner.status_rows
		local declaration = type(statuses) == "table" and statuses[status]
		if type(declaration) ~= "table" or #declaration == 0 then
			Logger.error(LOG, "Missing provider status '%s.%s.%s' — rows refused.", manifest_key, row_id, status)
			return nil
		end
		for _, item in ipairs(declaration) do
			if type(item) ~= "table" then return nil end
			local label = item.type == "label" and type(item.i18n) == "string" and item.i18n ~= ""
			if item.type ~= "---" and not label then return nil end
			for field in pairs(item) do
				if field ~= "type" and not (label and field == "i18n") then return nil end
			end
		end
		return template_rows(manifest_key, {}, {}, {}, declaration)
	end

	--- Supplies a declared checkbox as provider data through the shared policy.
	--- A retained callback rechecks its declared readiness before delivery.
	--- @param manifest_key string Owning menu declaration.
	--- @param row_id string Declared checkbox identity.
	--- @param commands table Native mutation owners.
	--- @param getters table Native state readers.
	--- @return table|nil row
	function R.check_row(manifest_key, row_id, commands, getters)
		commands, getters = commands or {}, getters or {}
		for _, item in ipairs(get_menu_def(manifest_key)) do
			if item.type == "check" and item.id == row_id and is_for_platform(item) then
				local built = command_item(item, manifest_key, commands, getters)
				if not built then return nil end
				local action = built.fn
				return {
					label = built.title, checked = built.checked, disabled = built.disabled,
					action = type(action) == "function" and function(...)
						if R.resolve_disabled_when(manifest_key, row_id, getters) then return false end
						return action(...)
					end or nil,
				}
			end
		end
		Logger.error(LOG, "Missing declared checkbox '%s.%s' — provider row refused.", manifest_key, row_id)
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

		-- Read once for the whole build: `commands` answers a row's declared
		-- behaviour and `state_getters` answers its checked_when / disabled_when
		-- keys. Both were resolved inside the check/command branch until the
		-- `toggle` branch needed them too.
		local commands = (type(ctx) == "table" and type(ctx.commands) == "table") and ctx.commands or {}
		local getters  = (type(ctx) == "table" and type(ctx.state_getters) == "table") and ctx.state_getters or {}

		for _, item in ipairs(menu_def) do
			if not is_for_platform(item) then
				-- A row this platform does not have is hidden: not applicable here
				-- (`unavailable = "hide"`), or not yet classified. A row declared
				-- `unavailable = "grey"` is not yet ported here, and the maintainer
				-- wants it seen: a disabled stand-in with the short form of its
				-- reason, the full one staying in the health check.
				if item.unavailable == "grey" then
					local stand_in = greyed_stand_in(manifest_key, item)
					if stand_in then
						flush_sep()
						table.insert(result, stand_in)
						item_count = item_count + 1
					end
				end
				goto continue
			end

			local t = item.type

			if t == "---" then
				-- Defer separator — only flush when a real item follows.
				pending_sep = true
				goto continue

			elseif t == "toggle" then
				-- The category's master switch: a CHECK row, first in its submenu.
				--
				-- It rendered as a plain row whose label alternated between two keys
				-- — « ✅ … enabled (click to disable) » and « ❌ … disabled (click to
				-- enable) » — so the one row that governs a whole submenu was the only
				-- on/off row of the tray that was not a checkbox, and its state was
				-- readable only from its words. One key names it now, and the tick
				-- carries the state exactly as a `check` row's does.
				local toggle_id  = type(item.id) == "string" and item.id or "category_toggle"
				local cmd_id     = type(item.command) == "string" and item.command or toggle_id
				local fn         = commands[cmd_id]
				local i18n_key   = type(item.i18n) == "string" and item.i18n or ""

				if i18n_key == "" then
					Logger.warn(LOG, "'toggle' item in '%s' declares no i18n — skipped.", manifest_key)
				elseif type(fn) ~= "function" then
					-- An ERROR, not a note: the submenu is shown without its switch, so
					-- the category cannot be turned on from the tray. This was a DEBUG
					-- line on the premise that a tray parent can toggle instead; none can.
					Logger.error(LOG, "No command '%s' for the '%s' category switch — its submenu has no way to "
						.. "turn it on or off.", tostring(cmd_id), manifest_key)
				else
					flush_sep()
					table.insert(result, {
						title    = i18n.get(i18n_key),
						fn       = fn,
						checked  = R.resolve_checked_when(manifest_key, toggle_id, getters),
						disabled = R.resolve_disabled_when(manifest_key, toggle_id, getters) or nil,
					})
					item_count = item_count + 1
				end

			elseif t == "feature" then
				-- A driver that draws a feature switch HERE registers its path in
				-- ctx.feature_rows (path -> function returning one row of data): the
				-- manifest then decides that the row exists and where it hangs.
				-- Without a registration the row is the caller's, as before — macOS
				-- builds its own shortcut feature rows.
				local path = type(item.path) == "string" and item.path or ""
				local providers = type(ctx) == "table" and type(ctx.feature_rows) == "table"
					and ctx.feature_rows or {}
				local provider = providers[path]
				if type(provider) == "function" then
					local ok, row = pcall(provider)
					if not ok or type(row) ~= "table" then
						Logger.error(LOG, "Feature row '%s' in '%s' failed: %s — row skipped.",
							path, manifest_key, tostring(row))
					else
						local rendered = render_rows({ row }, path, 1)
						if rendered[1] then
							flush_sep()
							table.insert(result, rendered[1])
							item_count = item_count + 1
						end
					end
				end

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
					-- A driver may enrich a header's TEXT — macOS puts the group's
					-- hotstring count in it — without owning the ROW. Given the hook,
					-- the manifest still decides that the header exists, where it sits
					-- and which key names it; without one, a driver that wanted a count
					-- had to build the header itself, and then the whole block around
					-- it, which is how that menu stayed hand-assembled.
					local label = nil
					if type(ctx) == "table" and type(ctx.section_label) == "function" then
						local ok, enriched = pcall(ctx.section_label, i18n_key)
						if ok and type(enriched) == "string" and enriched ~= "" then
							label = enriched
						end
					end
					table.insert(result, { title = label or i18n.section(i18n_key), disabled = true })
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
					-- Three accepted shapes, and the third is why a group builder no
					-- longer has to assemble driver rows: `items` is provider DATA,
					-- materialised here exactly as a `list` row's is. `menu` is a
					-- finished tree in the driver's own dialect, and a bare array is
					-- the same thing without the wrapper — both predate the renderer
					-- and stay accepted so a group can move when its author is ready
					-- rather than all at once.
					local sub_menu
					if type(built.items) == "table" then
						sub_menu = render_rows(built.items, group_id, 1)
					else
						sub_menu = type(built.menu) == "table" and built.menu or built
					end
					local sub_disabled = built.disabled or nil
					-- A group declaring checked_when ticks its title, as a category's
					-- parent row shows its switch (the key-combinations group).
					local sub_checked = nil
					if type(item.checked_when) == "table" then
						sub_checked = R.resolve_checked_when(manifest_key, group_id, getters)
					end
					table.insert(result, { title = label, menu = sub_menu, disabled = sub_disabled, checked = sub_checked })
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

			elseif t == "check" or t == "command" then
				-- The declarative row: everything about it is in the manifest, and
				-- the driver supplies only a NAMED behaviour.
				--
				-- WHY THIS TYPE EXISTS. Every other type that carries behaviour —
				-- "action", "dynamic" — hands the manifest key to a driver function
				-- that builds the row itself. That is why 639 rows lived outside this
				-- file: the manifest described the SLOT and three drivers each wrote
				-- the row. And they wrote it differently — Linux appended " ✓" to the
				-- title while its own tray adapter has supported a native GTK check
				-- item all along, so the same setting looked like a tick on one OS
				-- and a checkbox on the others.
				--
				-- Here the row is built ONCE, from `i18n`, `checked_when` and
				-- `disabled_when`, and the driver registers `ctx.commands[id]` — one
				-- function per BEHAVIOUR rather than one builder per row. A row that
				-- reads the same on three drivers is the point; a shared renderer that
				-- cannot build a checkbox was never going to deliver it.
				local built = command_item(item, manifest_key, commands, getters)
				if built then
					flush_sep()
					table.insert(result, built)
					item_count = item_count + 1
				end

			elseif t == "choice" then
				local row = choice_row_data(item, manifest_key, commands, getters)
				if not row then goto continue end
				local rendered = render_rows({ row }, item.id, 1)
				if #rendered > 0 then
					flush_sep()
					table.insert(result, rendered[1])
					item_count = item_count + 1
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

		return normalize_separators(result)
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


	--- Returns independently owned Dynamic family child records in manifest order.
	--- Callers select their native section alias and supply only live state.
	--- @return table[] families
	function R.get_dynamic_hotstring_families()
		local root = get_manifest_root()
		local node = root and root.dynamic_hotstring_families
		local rows = type(node) == "table" and node.rows
		if type(rows) ~= "table" or #rows == 0 then
			error("Dynamic hotstring families require their shared menu declaration", 2)
		end
		local out, seen = {}, {}
		for _, row in ipairs(rows) do
			if type(row) ~= "table" then error("Dynamic hotstring family must be a record", 2) end
			local copy = require("toml_codec.leaf_rows").clone_value(row)
			if row.separator == true then
				if row.id ~= nil then error("Dynamic separator cannot also be a family", 2) end
			else
				for _, key in ipairs({ "id", "section", "i18n", "legacy_key" }) do
					if type(row[key]) ~= "string" or row[key] == "" then
						error("Dynamic hotstring family requires " .. key, 2)
					end
				end
				if seen[row.id] then error("Duplicate Dynamic hotstring family: " .. row.id, 2) end
				seen[row.id] = true
				if row.linux_section ~= nil and (type(row.linux_section) ~= "string" or row.linux_section == "") then
					error("Dynamic hotstring Linux section must be a nonempty string", 2)
				end
			end
			out[#out + 1] = copy
		end
		return out
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
