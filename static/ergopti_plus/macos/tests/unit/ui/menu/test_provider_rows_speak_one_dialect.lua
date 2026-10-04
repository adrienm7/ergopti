--- tests/unit/ui/menu/test_provider_rows_speak_one_dialect.lua

--- ==============================================================================
--- MODULE: Regression — a provider row left in the driver dialect disappears
--- DESCRIPTION:
--- A list provider returns row DATA — `label`, `action`, `items` — and the shared
--- renderer turns it into the hs.menubar shape. A row left in the DRIVER dialect
--- (`title`, `fn`, `menu`) has no label as far as the renderer is concerned, so
--- it is dropped with a single warning and the user simply never sees it.
---
--- THE BUG (menu_about, found 2026-08-07): the About submenu's updater block
--- became an `about_updates` list provider, and its version header was not
--- converted from `title` to `label`. It vanished while all suites stayed green.
---
--- WHY A SOURCE SCAN: the failure is invisible at runtime by construction. There
--- is nothing to assert about a row that was silently dropped, so the guard reads
--- the provider bodies and refuses the wrong dialect there.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("provider rows speak the provider dialect (a driver-dialect row is dropped)", function()
	-- Each entry: a declaration unique to the module, and the name of the array
	-- its list provider returns. Selected by declaration rather than by path so
	-- moving or splitting a module cannot turn this invariant into a path error.
	local GUARDED = {
		{ anchor = 'require("adapters.update_launcher")', array = "menu_items" },
		{ anchor = "local function discover_bundled_apps", array = "provider_rows" },
	}

	helpers.it("no row pushed into a provider array uses `title` or `fn`", function()
		for _, guard in ipairs(GUARDED) do
			local src = helpers.read_driver_source(guard.anchor)
			helpers.assert_true(src ~= nil,
				"the module declaring '" .. guard.anchor .. "' must be locatable")

			local offending
			for line in src:gmatch("[^\n]+") do
				local stripped = line:match("^%s*(.-)%s*$") or line
				local pushes = stripped:find("table%.insert%(" .. guard.array .. ",")
					or stripped:find(guard.array .. "%[#" .. guard.array .. "%s*%+%s*1%]%s*=")
				if not stripped:match("^%-%-") and pushes then
					if stripped:find("%f[%w]title%s*=") or stripped:find("%f[%w]fn%s*=") then
						offending = stripped
						break
					end
				end
			end
			helpers.assert_true(offending == nil,
				"a row pushed into '" .. guard.array .. "' uses the driver dialect. The renderer reads "
				.. "provider data: `title` is not a label and the row is dropped with one warning. "
				.. "Offending: " .. tostring(offending))
		end
	end)

	-- Modules whose rows are ALL provider rows. The guard above reads the pushes
	-- into one named array, which is the right shape when a module builds a driver
	-- tree AND a provider array; these two build nothing else, so the stronger
	-- invariant applies and catches a row wherever it is written — including one
	-- assigned after the fact, which is exactly how the hotstring sections were
	-- lost (`item.menu = sec_menu`, four lines below the row it belonged to).
	local PROVIDER_ONLY_MODULES = {
		{ anchor = "function M.build_groups",           what = "the hotstring category builder" },
		{ anchor = "local function render_ext_tree",    what = "the personal-extensions tree" },
		-- Added 2026-08-07 with the bug they were carrying: build_action_picker and
		-- build_section_header returned `title`/`fn` while every caller fed the
		-- result into an `items` array, so the Karabiner tap and hold pickers showed
		-- their two ungrouped « Spécial » entries and dropped every grouped action,
		-- and the mod-combo list lost every category header. as_provider_row READS
		-- `row.title`, which is the one legitimate mention — the scan below skips it
		-- because a read has no `=` after the field.
		{ anchor = "function M.build_action_picker",    what = "the shared picker builders" },
		{ anchor = "local function build_one_combo_item", what = "the Karabiner picker trees" },
	}

	helpers.it("a module that emits only provider rows never names `title`, `fn` or `menu`", function()
		for _, guard in ipairs(PROVIDER_ONLY_MODULES) do
			local src, err = helpers.read_driver_unit(guard.anchor)
			helpers.assert_true(src ~= nil,
				"could not locate " .. guard.what .. ": " .. tostring(err))

			local offending, offending_line = nil, 0
			local line_no = 0
			for line in src:gmatch("[^\n]*") do
				line_no = line_no + 1
				local stripped = line:match("^%s*(.-)%s*$") or line
				if not stripped:match("^%-%-") then
					-- `%f[%w_]` so `sec_menu =`, `folder_menu =` and `update_menu =`
					-- are not read as the field `menu`; `[^=]` so `row.title == "-"`
					-- — a READ, which the provider adapter legitimately performs — is
					-- not mistaken for writing the field.
					if stripped:find("%f[%w_]title%s*=[^=]")
						or stripped:find("%f[%w_]fn%s*=[^=]")
						or stripped:find("%f[%w_]menu%s*=[^=]") then
						offending, offending_line = stripped, line_no
						break
					end
				end
			end
			helpers.assert_true(offending == nil,
				guard.what .. " emits provider rows only, so `title`, `fn` and `menu` — the hs.menubar "
				.. "field names — must not appear in it. The renderer reads `label`, `action` and `items`: "
				.. "a `title` is dropped, a `menu` is never read and the row loses its whole subtree. "
				.. "Line " .. offending_line .. ": " .. tostring(offending))
		end
	end)

	helpers.it("every hotstring category carries its rendered sections and commands intact", function()
		local Hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx = {
			hotfiles = { "alpha.toml" }, get_group_name = function() return "alpha" end,
			state = { hotstrings = {}, sections_order_overrides = {} },
			applyTriggerChar = function(value) return value end,
			keymap = {
				is_group_enabled = function() return true end,
				is_section_enabled = function() return true end,
				get_sections = function() return {
					{ name = "one", description = "One", count = 1 },
					{ name = "two", description = "Two", count = 3 },
				} end,
			},
		}
		local rows = Hotstrings.build_groups(ctx, nil, {})
		local rendered = require("infra.manifest_menu").render_rows(rows, "category-dialect-proof")
		helpers.assert_eq(#rendered, 1)
		helpers.assert_true(rendered[1].menu == rows[1].submenu,
			"an already-rendered child passes through without translating or rebuilding commands")
		helpers.assert_eq(#rendered[1].menu, 5, "two commands, a separator and both native sections")
		helpers.assert_eq(rendered[1].menu[4].title, "One (1)")
		helpers.assert_eq(rendered[1].menu[5].title, "Two (3)")
		helpers.assert_eq(type(rendered[1].menu[1].fn), "function")
		helpers.assert_eq(type(rendered[1].menu[2].fn), "function")
	end)

	helpers.it("the extension tree emits rows in the dialect it also reads", function()
		local src = helpers.read_driver_unit("local function render_ext_tree")
		helpers.assert_true(src ~= nil, "the personal-extensions tree must be locatable")

		helpers.assert_true(src:find("label = folder_label, items = folder_menu", 1, true) ~= nil,
			"a folder row is `label` + `items`; as `title` + `menu` the folder renders empty")
		helpers.assert_true(src:find("label = file.label, submenu = file.submenu", 1, true) ~= nil,
			"a file row must read the fields the nodes actually carry — reading `file.title`/`file.menu` "
			.. "off a node built with `label`/`submenu` yields a row with no label at all, which the "
			.. "renderer drops")
		helpers.assert_true(src:find("a.label < b.label", 1, true) ~= nil,
			"and the sort must compare that same field: `a.title < b.title` on those nodes compares two "
			.. "nils, which throws inside the provider and takes the whole hotstrings menu with it as "
			.. "soon as one folder holds two extension files")
	end)

	helpers.it("nested personal files retain their sorted native command subtrees", function()
		helpers.with_stub_scope({ "infra.personal_file_scope", "ui.menu.menu_hotstrings_custom" }, function()
			-- This projection fixture owns a synthetic acknowledged group. Actual
			-- provenance, native route and refusal behavior have their own owner test.
			local bindings = 0
			package.loaded["infra.personal_file_scope"] = { bind = function()
				bindings = bindings + 1
				return function() return true end
			end }
			local Custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
			local asked = {}
			local ctx = {
				paused = false,
				state = { hotstrings = {}, trigger_char = "★" },
				hotfiles = { "personal.toml", "personal_ext_tools__zeta.toml", "personal_ext_tools__alpha.toml" },
				get_group_name = function(path) return path:gsub("%.toml$", "") end,
				applyTriggerChar = function(value) return value end,
				hotstring_editor = { open = function() end },
				keymap = {
					is_group_enabled = function() return false end,
					is_section_enabled = function() return true end,
					get_sections = function(group)
						if group:sub(1, 13) == "personal_ext_" then
							return { { name = "part", description = "Part", count = 1 } }
						end
					end,
					set_category_scope_enabled = function(names, enabled, publish)
						asked[#asked + 1] = { names = names, enabled = enabled }
						return publish()
					end,
				},
				save_prefs = function() return true end,
				updateMenu = function() end,
			}
			local rows = Custom.build_custom(ctx, { group_counts = {} }).submenu
			local folder
			for _, row in ipairs(rows) do if row.title == "tools (2)" then folder = row end end
			helpers.assert_true(folder ~= nil, "a folder with two personal files must survive rendering")
			helpers.assert_eq(#folder.menu, 2)
			helpers.assert_eq(folder.menu[1].title, "alpha (1)")
			helpers.assert_eq(folder.menu[2].title, "zeta (1)")
			for _, file in ipairs(folder.menu) do
				helpers.assert_eq(file.menu[1].title, "menu.hotstrings.scope_enable_all")
				helpers.assert_eq(file.menu[2].title, "menu.hotstrings.scope_disable_all")
				helpers.assert_eq(file.menu[3].title, "-")
				helpers.assert_eq(file.menu[4].title, "Part (1)")
			end
			helpers.assert_eq(folder.menu[2].menu[1].fn(), true)
			helpers.assert_eq(asked, { { names = { "personal_ext_tools__zeta" }, enabled = true } })
			helpers.assert_eq(bindings, 2, "one native admission binding per rendered file")
		end)
	end)

	helpers.it("the About submenu keeps its version header and native update action", function()
		local src = helpers.read_driver_source('require("adapters.update_launcher")')
		helpers.assert_true(src ~= nil, "ui/menu/menu_about.lua source must be locatable")

		helpers.assert_true(src:find("label = ver_display", 1, true) ~= nil,
			"the version header must be a provider row (`label = ver_display`) — as `title` it is "
			.. "dropped by the renderer and the submenu shows no version at all")
		helpers.assert_true(src:find('label = i18n.get("menu.about.check_for_updates")', 1, true) ~= nil,
			"the Sparkle command must remain a visible provider row")
		helpers.assert_true(src:find('require("ui.update_check").open(', 1, true) ~= nil,
			"the visible check row must open the update-check window")
		helpers.assert_true(src:find("UpdateLauncher.request_check(latest.channel)", 1, true) ~= nil,
			"a row naming a found release must retain its native Sparkle action")
	end)
end)
