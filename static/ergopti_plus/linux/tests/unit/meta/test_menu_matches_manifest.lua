--- tests/unit/meta/test_menu_matches_manifest.lua

--- ==============================================================================
--- MODULE: The Menu the User Sees Is the Menu the Manifest Declares
--- DESCRIPTION:
--- Builds the whole tray with the daemon's own builder and checks, row by row,
--- that every entry the manifest promises this platform actually appears.
---
--- WHY THIS AND NOT ANOTHER STATIC GATE:
--- The cross-driver gates in tools/test read the manifest and the SOURCE. They
--- catch a manifest that promises a row no handler answers, and a driver that
--- builds rows no manifest describes. What neither can see is the third case:
--- a handler that exists, is registered, is reached — and appends nothing,
--- because a guard above it returned early, a context key was misspelled, or the
--- row it builds is conditional on state the daemon never sets. That row is
--- declared, handled, and invisible, and every gate stays green.
---
--- It happened. The gestures submenu declared eleven rows and rendered one; the
--- hotstrings dynamic category was a greyed "(aucun groupe chargé)" while the
--- engine behind it was expanding dates. Both were found by reading, not by a
--- test, because no test ever built the menu and looked at it.
---
--- WHAT IT CHECKS, AND WHAT IT CANNOT:
--- Only rows the RENDERER materialises with a label it owns — `action`, `group`,
--- `section_header`, `list`. A `dynamic` row's rows are the handler's to name,
--- and a `feature` or `toggle` row is built by the caller by contract, so
--- neither has a label this test could look for. Those stay with the
--- bijection ratchet, which asks the narrower question of whether a handler is
--- registered at all.
---
--- WHY IT LIVES IN THE DRIVER SUITE:
--- It needs the driver to actually run. That also means it runs on every
--- distribution's LuaJIT in CI, on a real Linux, rather than against a regex.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Rebound rather than required: `infra.manifest_menu` captures the i18n MODULE
-- TABLE when it is loaded, and tests/unit/meta/test_i18n_persistence.lua wipes
-- `package.loaded["infra.i18n"]` nine times. Whichever of them ran first, the
-- renderer would then be resolving labels against an i18n instance this file
-- cannot see, and every comparison below would be between two different
-- catalogues. Production is unaffected — `set_locale` mutates the module in
-- place and nothing there ever wipes the cache — so this is the harness being
-- made to agree with itself, not a defect being worked around.
local ManifestMenu = helpers.load_module("infra.manifest_menu")
local i18n         = require("infra.i18n")

-- The platform token this driver is declared under in the manifest.
local PLATFORM = "linux"

-- Row types the shared renderer materialises itself, with a label it resolves
-- from the manifest's own i18n key. Every other type is built by a handler or by
-- the caller, and carries no label this test could look for.
local RENDERED_TYPES = { action = true, group = true, section_header = true }

--- Whether the manifest declares a row for this platform.
--- @param row table
--- @return boolean
local function visible(row)
	if type(row.platforms) ~= "table" then return true end
	for _, platform in ipairs(row.platforms) do
		if platform == PLATFORM then return true end
	end
	return false
end

--- Every title in a built menu tree, flattened.
--- @param items table
--- @param out table|nil
--- @return table
local function all_titles(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if type(item.title) == "string" then out[#out + 1] = item.title end
		if type(item.menu) == "table" then all_titles(item.menu, out) end
	end
	return out
end

--- A menu context complete enough for every submenu to build.
---
--- Stubs rather than real modules: this test asks whether the BUILDER renders
--- what the manifest declares, and a real module that happens to be unavailable
--- on the test host would answer a different question — one about the host.
--- @return table
local function full_context()
	local function noop() end
	return {
		_version = "9.9.9",
		config = {
			get_groups         = function() return {} end,
			is_group_enabled   = function() return true end,
			toggle_group       = noop,
			is_section_enabled = function() return true end,
			toggle_section     = noop,
			set_all_sections   = noop,
			get_category       = function() return nil end,
			reload             = noop,
			enable_all         = noop,
			disable_all        = noop,
		},
		shortcuts = {
			is_enabled          = function() return true end,
			toggle              = noop,
			is_caps_word_active = function() return false end,
			toggle_caps_word    = noop,
			transform_uppercase = noop,
			transform_lowercase = noop,
			transform_titlecase = noop,
			select_word         = noop,
			select_line         = noop,
			paste_plain         = noop,
			wrap_selection      = noop,
			get_wrap_pairs      = function() return { ["("] = { left = "(", right = ")" } } end,
		},
		gestures = {
			is_enabled     = function() return true end,
			toggle         = noop,
			get_action     = function() return nil end,
			set_action     = noop,
			get_slots      = function() return {} end,
			get_sg_names   = function() return {} end,
		},
		-- `keylogger`, which is what _build_metrics reads. Named `metrics` in a
		-- first draft, and the metrics submenu then collapsed to "(métriques non
		-- disponibles)" — three manifest rows reported missing for a reason that
		-- was in the stub, not the driver.
		keylogger = {
			is_enabled        = function() return true end,
			toggle            = noop,
			get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end,
			get_wpm           = function() return 0 end,
			get_ngrams        = function() return {} end,
			get_app_stats     = function() return {} end,
			get_privacy_state = function() return {} end,
			flush             = noop,
		},
		kanata = {
			is_running = function() return false end,
			start      = noop,
			stop       = noop,
			restart    = noop,
			generate   = noop,
		},
		dyn_hotstrings = {
			is_enabled      = function() return true end,
			set_enabled     = noop,
			get_rules_count = function() return 0 end,
			active_count    = function() return 0 end,
			rule_families   = function() return {} end,
			set_rule_enabled = noop,
		},
	}
end




-- =================================================================
-- =================================================================
-- ======= 1/ Every declared row is on screen ======================
-- =================================================================
-- =================================================================

helpers.describe("menu certification: the manifest's rows are rendered", function()

	local built = nil
	local titles = nil

	helpers.before_each(function()
		if built then return end
		local mb = helpers.load_module("ui.menu.menu_builder")
		built = mb.build(full_context())
		titles = {}
		for _, title in ipairs(all_titles(built)) do titles[title] = true end
	end)

	helpers.it("builds a tray at all", function()
		helpers.assert_true(#built > 0, "an empty tray means everything below asserts nothing")
		helpers.assert_true(#all_titles(built) > 40,
			"the menu is dozens of rows deep; a handful means most submenus refused "
				.. "to build and the coverage below is measuring their absence")
	end)

	helpers.it("renders every action, group and header the manifest promises Linux", function()
		local root = ManifestMenu and ManifestMenu.get_root() or nil
		helpers.assert_not_nil(root, "the manifest must load, or this test checks nothing")

		local checked, missing = 0, {}
		for menu_key in pairs(root) do
			local rows = ManifestMenu.get_array(menu_key)
			if type(rows) == "table" then
				for _, row in ipairs(rows) do
					local kind = row.type or ""
					if RENDERED_TYPES[kind] and visible(row) and type(row.i18n) == "string" then
						checked = checked + 1
						-- The renderer decorates a section header — `i18n.section`, not
						-- `i18n.get` — so comparing against the bare translation looks for
						-- a string the menu never contains. Resolved the same way the
						-- renderer resolves it, which is the only comparison that means
						-- anything.
						local label = (kind == "section_header")
							and i18n.section(row.i18n)
							or i18n.get(row.i18n)
						if not titles[label] then
							missing[#missing + 1] = menu_key .. "/" .. (row.id or row.i18n)
						end
					end
				end
			end
		end

		helpers.assert_true(checked > 0,
			"no row was examined — the projection is broken, not the menu, and a "
				.. "check that silently examines nothing is the failure this exists "
				.. "to prevent")
		helpers.assert_eq(#missing, 0,
			"the manifest declares these for Linux and the tray does not show them: "
				.. table.concat(missing, ", ")
				.. ". A row that is declared, handled and invisible passes every gate "
				.. "that reads only the manifest and the source.")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ No submenu is a dead end =============================
-- =================================================================
-- =================================================================

helpers.describe("menu certification: no empty submenu", function()

	helpers.it("gives every submenu at least one row", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local empty = {}

		local function walk(items, path)
			for _, item in ipairs(items or {}) do
				if type(item.menu) == "table" then
					local where = path .. "/" .. tostring(item.title)
					if #item.menu == 0 then empty[#empty + 1] = where end
					walk(item.menu, where)
				end
			end
		end
		walk(mb.build(full_context()), "")

		helpers.assert_eq(#empty, 0,
			"a submenu that opens onto nothing is worse than a missing one: the user "
				.. "cannot tell it apart from a feature that failed to load. "
				.. table.concat(empty, ", "))
	end)

end)
