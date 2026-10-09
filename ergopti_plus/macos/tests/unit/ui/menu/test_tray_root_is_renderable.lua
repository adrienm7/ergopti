--- tests/unit/ui/menu/test_tray_root_is_renderable.lua

--- ==============================================================================
--- MODULE: Every Row Of The Tray Root Is Something hs.menubar Can Draw
--- DESCRIPTION:
--- Builder.generate returns the table handed straight to hs.menubar:setMenu, so
--- every entry in it must carry a `title` (or be the "-" separator). This pins
--- that contract from the OUTSIDE, independently of how the root is assembled
--- inside.
---
--- WHY IT EXISTS:
--- the root is assembled from a dozen component builders, each returning the row
--- that hangs its submenu on the tray. When those rows became provider DATA —
--- `label` / `submenu`, materialised by the shared renderer, the way Linux has
--- built its whole tray root since 2026-08-07 — a single builder left in the old
--- dialect would return a row the renderer drops, and a whole submenu would
--- disappear from the menu bar with one warning in a log.
---
--- The three bugs that motivated this were each found by opening the menu and
--- noticing something missing: the About version row, every hotstring category's
--- section list, every grouped Karabiner action. A test that reads the OUTPUT
--- cannot miss the next one, whichever builder it comes from.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The actions table Builder.generate's top-level tail expects.
--- @return table
local function make_actions()
	return {
		set_log_level     = function() end,
		open_logs         = function() end,
		open_today_log    = function() end,
		open_error_log    = function() end,
		open_console      = function() end,
		show_setup_wizard = function() end,
		open_paths        = function() end,
		reload            = function() end,
		quit              = function() end,
		enable_all        = function() end,
		disable_all       = function() end,
		reset_defaults    = function() end,
	}
end

--- Describes a row that hs.menubar could not draw, or nil when it can.
--- @param row any One entry of the returned menu table.
--- @param path string Where it sits, for the failure message.
--- @return string|nil
local function undrawable(row, path)
	if type(row) ~= "table" then
		return path .. " is a " .. type(row) .. ", not a menu row"
	end
	-- An EMPTY title is legitimate for exactly one row: the canvas badge, which is
	-- an image and no text. A missing one never is.
	if type(row.title) ~= "string" or (row.title == "" and row.image == nil) then
		-- Name the provider field when it is present: that is the whole diagnosis.
		local hint = ""
		if row.label ~= nil then hint = " — it carries `label`, the PROVIDER field, so it never reached the renderer" end
		if row.items ~= nil then hint = hint .. " and `items`, which only a provider row has" end
		return path .. " has no title" .. hint
	end
	if row.menu ~= nil and type(row.menu) ~= "table" then
		return path .. " ('" .. row.title .. "') has a non-table `menu`"
	end
	return nil
end

--- Walks the whole returned tree, reporting the first undrawable row.
--- @param rows table
--- @param path string
--- @return string|nil
local function first_problem(rows, path)
	for index, row in ipairs(rows) do
		local where = path .. "[" .. index .. "]"
		local bad = undrawable(row, where)
		if bad then return bad end
		if type(row.menu) == "table" then
			local deeper = first_problem(row.menu, where .. ".menu")
			if deeper then return deeper end
		end
	end
	return nil
end

helpers.describe("the tray root is a table hs.menubar can draw", function()

	helpers.it("every row it returns carries a title, at every depth", function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("infra.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = { config = { log_level = 2 } }
		local ok_call, menu = pcall(builder.generate, ctx, {}, make_actions())
		helpers.assert_true(ok_call, "M.generate must not raise: " .. tostring(menu))
		helpers.assert_true(type(menu) == "table" and #menu > 0,
			"M.generate must return a non-empty menu, or this test measures nothing")

		local problem = first_problem(menu, "menu")
		helpers.assert_true(problem == nil,
			"a row hs.menubar cannot draw reached the tray root. Provider rows say `label` and `items`; "
			.. "what setMenu consumes says `title` and `menu`, and the shared renderer is what turns one "
			.. "into the other. " .. tostring(problem))
	end)

	helpers.it("no row is left holding both dialects at once", function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("infra.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = { config = { log_level = 2 } }
		local _, menu = pcall(builder.generate, ctx, {}, make_actions())
		helpers.assert_true(type(menu) == "table" and #menu > 0, "M.generate must return a menu")

		local mixed = nil
		local function walk(rows, path)
			for index, row in ipairs(rows) do
				if type(row) == "table" then
					local where = path .. "[" .. index .. "]"
					if row.title ~= nil and (row.label ~= nil or row.items ~= nil or row.action ~= nil) then
						mixed = where .. " ('" .. tostring(row.title) .. "')"
						return
					end
					if type(row.menu) == "table" then walk(row.menu, where .. ".menu") end
					if mixed then return end
				end
			end
		end
		walk(menu, "menu")

		helpers.assert_true(mixed == nil,
			"a row carries BOTH the hs.menubar fields and the provider fields: " .. tostring(mixed)
			.. ". Half-converted rows are how a subtree ends up attached to a field nothing reads")
	end)
end)

-- Complete Language parent: the actual locale owner, canonical child and selected parent.
local function language_parent_fixture(language, scenario)
	return helpers.with_stub_scope({ "ui.menu.builder", "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }, function()
		helpers.load_with_stubs("ui.menu.builder")
		-- The generic helper deliberately installs an i18n stub; this cohort owns the real reader.
		rawset(package.loaded, "ui.menu.builder", nil)
		rawset(package.loaded, "infra.i18n", nil)
		rawset(package.loaded, "infra.manifest_menu", nil)
		local native = require("infra.i18n")
		native.init()
		native.set_locale_injector(require("infra.locale").set_locale)
		native.set_locale_no_reload(language)
		local renderer = require("infra.manifest_menu")
		local builder = require("ui.menu.builder")
		local path = require("infra.paths").shared("tests/corpus/menus/language_parent.json")
		local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
		local corpus = assert(require("adapters.json_codec").decode(bytes))
		assert(native.get("menu.global.language") == corpus.parent[language], "actual locale file was initialized")
		return scenario(native, renderer, corpus, function()
			return builder.generate({ config = { log_level = 2 } }, {}, make_actions())
		end)
	end)
end

local function language_parent_find(rows, caption)
	for _, row in ipairs(rows) do if row.title == caption then return row end end
end

helpers.describe("complete declared Language parent (macOS)", function()
	for _, code in ipairs({ "en", "fr" }) do
		local language = code
		helpers.it("retains the original full hierarchy, callback identities and same finished child in " .. language, function()
			language_parent_fixture(language, function(native, renderer, corpus, build)
				local original_provider, original_group, original_set = native.build_language_menu_items, renderer.group_row, native.set_locale
				local supplied, finished, calls, changes = nil, nil, 0, 0
				local ok, detail = xpcall(function()
					native.build_language_menu_items = function() calls = calls + 1; supplied = original_provider(); return supplied end
					renderer.group_row = function(key, id, child, getters)
						if key == "top_level" and id == "language" then finished = child end
						return original_group(key, id, child, getters)
					end
					native.set_locale = function(...) changes = changes + 1; return original_set(...) end
					local row = assert(language_parent_find(build(), corpus.parent[language]))
					helpers.assert_eq(calls, 1, "the genuine locale data is captured exactly once")
					helpers.assert_true(rawequal(row.menu, finished), "the selected parent retains its actual completed child")
					helpers.assert_eq(#row.menu, #corpus.locales, "all original native locale children remain")
					helpers.assert_eq(changes, 0, "construction does not invoke a language action")
					local active
					for index, expected in ipairs(corpus.locales) do
						local child = row.menu[index]
						helpers.assert_eq(child.title, expected.mac, "handwritten complete native caption/order")
						helpers.assert_eq(child.checked, expected.code == language, "active and inactive states are exact")
						helpers.assert_true(rawequal(child.fn, supplied[index].action), "native callback identity is retained")
						if expected.code == language then active = child end
					end
					assert(active).fn()
					helpers.assert_eq(changes, 1, "the original callback reaches the real native setter")
					helpers.assert_eq(native.get_locale(), language, "the genuine unchanged choice remains current")
				end, debug.traceback)
				native.build_language_menu_items, renderer.group_row, native.set_locale = original_provider, original_group, original_set
				if not ok then error(detail, 0) end
			end)
		end)
	end
	helpers.it("retains the declared parent for a genuine valid empty locale result", function()
		language_parent_fixture("en", function(native, _, corpus, build)
			local original = native.build_language_menu_items
			local ok, detail = xpcall(function()
				native.build_language_menu_items = function() return {} end
				local row = assert(language_parent_find(build(), corpus.parent.en))
				helpers.assert_type(row.menu, "table")
				helpers.assert_eq(#row.menu, 0, "valid empty does not fabricate a choice")
			end, debug.traceback)
			native.build_language_menu_items = original
			if not ok then error(detail, 0) end
		end)
	end)
	for _, variant in ipairs({ "nil", "scalar", "malformed", "child-withdrawn", "parent-withdrawn", "parent-wrong-kind" }) do
		local name = variant
		helpers.it("refuses " .. name .. " without publishing a Language parent", function()
			language_parent_fixture("en", function(native, renderer, corpus, build)
				local root, original = renderer.get_root(), native.build_language_menu_items
				local child, parent = root.language_menu, nil
				for _, row in ipairs(root.top_level) do if row.id == "language" then parent = row; break end end
				local original_kind, original_id = parent.type, parent.id
				local ok, detail = xpcall(function()
					if name == "nil" then native.build_language_menu_items = function() return nil end
					elseif name == "scalar" then native.build_language_menu_items = function() return false end
					elseif name == "malformed" then native.build_language_menu_items = function() return { false } end
					elseif name == "child-withdrawn" then root.language_menu = {}
					elseif name == "parent-withdrawn" then parent.id = "withdrawn-language"
					else parent.type = "label" end
					local rows = build()
					helpers.assert_type(rows, "table", "unrelated genuine root survives selected-parent refusal")
					helpers.assert_nil(language_parent_find(rows, corpus.parent.en), "no nil-to-empty or undeclared parent fallback")
				end, debug.traceback)
				root.language_menu, parent.type, parent.id, native.build_language_menu_items = child, original_kind, original_id, original
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)


helpers.describe("Language completed-child admission (macos)", function()
	for _, mode in ipairs({ "deep", "nil", "scalar" }) do
		local case = mode
		helpers.it("keeps finished deep identity and refuses incomplete native result: " .. case, function()
			language_parent_fixture("en", function(_, renderer, corpus, build)
				local original, finished = renderer.render_rows, nil
				local ok, detail = xpcall(function()
					renderer.render_rows = function(rows, key)
						local native = original(rows, key)
						if key ~= "language_menu" then return native end
						if case == "nil" then return nil end
						if case == "scalar" then return false end
						assert(type(native) == "table" and #native == 21)
						local leaf = { title = "finished-leaf", fn = native[1].fn }
						local subtree = { leaf }
						for _ = 1, 8 do subtree = { { title = "finished-level", menu = subtree } } end
						native[1].menu = subtree
						finished = native
						return native
					end
					local parent = language_parent_find(build(), corpus.parent.en)
					if case == "deep" then
						helpers.assert_true(parent ~= nil, "finished genuine native result remains attachable")
						helpers.assert_true(rawequal(parent.menu, finished), "no secondary native-child depth walk or copy")
						local child = parent.menu[1].menu
						for _ = 1, 8 do child = child[1].menu end
						helpers.assert_eq(child[1].title, "finished-leaf", "all finished deep levels retained")
						helpers.assert_true(rawequal(child[1].fn, finished[1].fn), "finished callback identity retained")
					else
						helpers.assert_nil(parent, "failed native rendering never becomes a valid empty parent")
					end
				end, debug.traceback)
				renderer.render_rows = original
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)


helpers.describe("Language locale provider retains refusal isolation", function()
	for _, mode in ipairs({ "missing", "nonfunction", "throwing" }) do
		local case = mode
		helpers.it("refuses " .. case .. " provider without aborting unrelated native tray rows", function()
			language_parent_fixture("en", function(native, _, corpus, build)
				local original_provider, original_set = native.build_language_menu_items, native.set_locale
				local calls, changes = 0, 0
				local ok, detail = xpcall(function()
					if case == "missing" then native.build_language_menu_items = nil
					elseif case == "nonfunction" then native.build_language_menu_items = false
					else native.build_language_menu_items = function()
						calls = calls + 1
						error("genuine locale provider refusal sentinel")
					end end
					native.set_locale = function(...) changes = changes + 1; return original_set(...) end
					local rows = build()
					helpers.assert_type(rows, "table", "provider refusal does not abort the original tray constructor")
					helpers.assert_nil(language_parent_find(rows, corpus.parent.en), "failed provider is not a valid empty collection")
					helpers.assert_true(language_parent_find(rows, native.get("menu.debug.title")) ~= nil, "actual unrelated Debug parent survives")
					helpers.assert_eq(calls, case == "throwing" and 1 or 0, "the callable native collection is requested once")
					helpers.assert_eq(changes, 0, "no native locale action runs on refusal")
				end, debug.traceback)
				native.build_language_menu_items, native.set_locale = original_provider, original_set
				if not ok then error(detail, 0) end
			end)
		end)
	end
end)
