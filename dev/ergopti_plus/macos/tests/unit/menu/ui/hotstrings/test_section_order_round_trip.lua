--- tests/unit/menu/ui/hotstrings/test_section_order_round_trip.lua

--- ==============================================================================
--- MODULE: Hotstring Section Order Round Trip
--- DESCRIPTION:
--- The Mac check « Hotstring section order » (TODO, To confirm on the Mac)
--- chained by hand what each unit test proves alone: a menu move is written to
--- config.toml by the real Preferences.save, a restart reads it back through
--- Preferences.load and the rebuilt menu shows it, a menu built before a
--- configuration reload refuses its click, and the menu reset removes the order
--- from the file so the next start shows the source order again.
--- ==============================================================================

local helpers = require("tests.helpers")
local TomlCodec = require("core.text.engine.toml_codec")
local Outdated = require("settings.engine.migration.outdated")

-- The configuration owner and its conditional writer use a real private file.
local PATH = os.tmpname()
local SOURCE = "[hotstrings.order_overrides]\nother = [\"kept\"]\n"





-- ===============================
-- ===============================
-- ======= 1/ Menu context =======
-- ===============================
-- ===============================

--- Finds a menu row by its rendered title anywhere under rows.
--- @param rows table|nil
--- @param title string
--- @return table|nil
local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title or row.label == title then return row end
		local child = find(row.menu or row.submenu or row.items, title)
		if child then return child end
	end
	return nil
end

--- Returns the children of a menu row.
--- @param row table
--- @return table
local function children(row)
	return row.menu or row.submenu or row.items
end

--- Builds the hotstrings menu context of one driver session over a state.
--- @param state table The session state Preferences.load produced.
--- @param preferences table The real preferences owner.
--- @return table ctx
local function context(state, preferences)
	local ctx
	ctx = {
		paused = false,
		hotfiles = { "alpha.toml" },
		get_group_name = function(path) return (path:gsub("%.toml$", "")) end,
		state = state,
		applyTriggerChar = function(value) return value end,
		is_paused = function() return false end,
		keymap = {
			is_group_enabled = function() return true end,
			get_sections = function() return { { name = "one" }, { name = "two" } } end,
			is_section_enabled = function() return true end,
			start = function() return true end,
			is_started = function() return true end,
		},
		save_prefs = function() return preferences.save(PATH, ctx.state, {}, {}) end,
		updateMenu = function() end,
		notify_feature = function() end,
	}
	return ctx
end

--- Reads config.toml.
--- @return string
local function read_file()
	local file = assert(io.open(PATH, "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	return source
end

--- Starts one driver session over config.toml: a fresh Preferences owner loads
--- it and the menu module is loaded again, as a restart does.
--- @return table ctx, table menu, table preferences
local function start_session()
	package.loaded["core.fs.adapters.file_system"] = nil
	Outdated.reset_for_tests()
	local preferences = helpers.load_with_stubs("settings.engine.preferences.preferences")
	local values, status = preferences.load(PATH)
	helpers.assert_eq(status, "ok")
	local state = { hotstrings = {}, keymap = true,
		sections_order_overrides = values.sections_order_overrides or {} }
	local menu = helpers.load_with_stubs("hotstrings.ui.menu.hotstrings")
	return context(state, preferences), menu, preferences
end

--- Returns the rendered order rows of category alpha, first entry first.
--- @param menu table
--- @param ctx table
--- @return table entries
local function order_entries(menu, ctx)
	local parent = assert(find(menu.build_groups(ctx, nil, { group_counts = {} }), "menu.hotstrings.section_order"),
		"the section-order submenu is rendered")
	return children(parent)
end

--- Reads the order overrides written to the file.
--- @return table|nil
local function written_orders()
	local decoded = TomlCodec.decode(read_file())
	return type(decoded.hotstrings) == "table" and decoded.hotstrings.order_overrides or nil
end





-- ==================================
-- ==================================
-- ======= 2/ Round trip ============
-- ==================================
-- ==================================

helpers.describe("hotstring-section-order: menu, config.toml and restart round trip", function()
	helpers.it("persists a move, shows it after a restart, refuses a stale menu and resets", function()
		helpers.with_stub_scope({ "settings.engine.preferences.preferences", "core.fs.adapters.file_system", "core.logger.engine.logger", "core.logger.engine.shim" }, function()
		local logger = helpers.make_logger_stub()
		package.loaded["core.logger.engine.logger"], package.loaded["core.logger.engine.shim"] = logger, logger
		local file = assert(io.open(PATH, "wb"))
		assert(file:write(SOURCE)); assert(file:close())
		local ok, err = xpcall(function()
		local ctx, menu = start_session()
		local entries = order_entries(menu, ctx)
		helpers.assert_eq(entries[1].title or entries[1].label, "one", "the source order comes first")
		local up = assert(find(children(entries[2]), "menu.hotstrings.move_up"))
		helpers.assert_eq((up.fn or up.action)(), true, "moving « two » up is committed")
		helpers.assert_eq(written_orders(), { alpha = { "two", "one" }, other = { "kept" } },
			"the move reaches config.toml beside the other category's order")

		-- A restart: a fresh owner reads the file and the rebuilt menu shows the move.
		local restarted, restarted_menu = start_session()
		helpers.assert_eq(restarted.state.sections_order_overrides.alpha, { "two", "one" })
		local after = order_entries(restarted_menu, restarted)
		helpers.assert_eq(after[1].title or after[1].label, "two", "the restarted menu shows the saved order")

		-- A configuration reload replaces the state's orders: the menu built before
		-- it no longer owns them, so its click changes nothing.
		local stale_down = assert(find(children(after[1]), "menu.hotstrings.move_down"))
		local before_reload = read_file()
		restarted.state.sections_order_overrides = start_session().state.sections_order_overrides
		helpers.assert_eq((stale_down.fn or stale_down.action)(), false, "a menu older than the reload is refused")
		helpers.assert_eq(read_file(), before_reload, "the refused click writes nothing")

		-- The reset of a menu built after the reload restores the source order.
		local current = order_entries(restarted_menu, restarted)
		local reset = assert(find(current, "hs_config.btn_reset_default"), "the reset row is rendered")
		helpers.assert_eq((reset.fn or reset.action)(), true, "the reset is committed")
		helpers.assert_eq(written_orders(), { other = { "kept" } },
			"the reset removes the category's order from config.toml and keeps the other one")
		local reset_session, reset_menu = start_session()
		helpers.assert_nil(reset_session.state.sections_order_overrides.alpha)
		local final = order_entries(reset_menu, reset_session)
		helpers.assert_eq(final[1].title or final[1].label, "one", "the next start shows the source order")
		end, debug.traceback)
		os.remove(PATH)
		if not ok then error(err, 0) end
		end)
	end)
end)
