--- tests/meta/test_menu_provider_kind_matches_declaration.lua

--- ==============================================================================
--- MODULE: Provider Kind Matches Declaration (macOS)
--- DESCRIPTION:
--- The shared renderer routes a manifest row by its `type`, and the two routes
--- take DIFFERENT things:
---
---   `list`    calls a LIST PROVIDER, which RETURNS provider rows
---             (`label` / `action` / `checked` / `items`) for the renderer to
---             materialise. Providers arrive in R.build's 6th argument.
---   `dynamic` calls a DYNAMIC HANDLER, which APPENDS driver rows
---             (`title` / `fn` / `menu`) into the list it is handed. Handlers
---             arrive in R.build's 3rd argument.
---
--- Register one where the other is expected and the renderer finds no handler
--- for the id, logs a single warning and SKIPS the row. Nothing else fails: the
--- handler-bijection gate greps driver sources for the quoted id and finds it in
--- the table that was passed to the wrong parameter, so it reports the row as
--- answered. The row is simply absent from the menu.
---
--- WHY THIS TEST EXISTS: that is exactly what happened to the keyboard-layout
--- list. `active_layouts` was declared `dynamic`, ui/menu/menu_keyboard_layout.lua
--- passed active_layout_rows() as a list provider, and the layout submenu showed
--- no layouts at all — for as long as both halves have existed. The manifest now
--- says `list`, which is what the function actually returns.
---
--- The second case pins the same label bug through the real declared record
--- producer and actual materializer. Literal OS names remain provider DATA
--- labels, then reach completed native titles with the exact genuine callback;
--- a delegated shared caption owner no longer spells `label = row_label` here.
--- ==============================================================================

local helpers = require("tests.helpers")
local LayoutFixture = require("tests.support.layout_legacy_caption_fixture")

local DRIVER_ROOT = helpers.driver_root()  -- trailing slash

--- Reads and decodes the shared menu manifest.
--- @return table Decoded manifest.
local function read_manifest()
	local fh = io.open(DRIVER_ROOT .. "../_shared/modules/menu/menu_manifest.json", "r")
	helpers.assert_true(fh ~= nil, "menu_manifest.json must be readable")
	local raw = fh:read("*a")
	fh:close()
	local data = hs.json.decode(raw)
	helpers.assert_true(type(data) == "table", "menu_manifest.json must decode to a table")
	return data
end

--- Finds a row by id in one of the manifest's menu arrays.
--- @param manifest table Decoded manifest.
--- @param menu_key string Menu array to search.
--- @param row_id string Row id.
--- @return table|nil
local function find_row(manifest, menu_key, row_id)
	for _, row in ipairs(manifest[menu_key] or {}) do
		if type(row) == "table" and row.id == row_id then return row end
	end
	return nil
end




helpers.describe("menu provider kind matches the manifest declaration (macOS)", function()

	helpers.it("active_layouts is declared `list`, which is what this driver supplies", function()
		local manifest = read_manifest()
		local row = find_row(manifest, "layout_menu", "active_layouts")
		helpers.assert_true(row ~= nil, "layout_menu must declare an active_layouts row")
		helpers.assert_eq(row.type, "list",
			"active_layouts must be declared `list`: menu_keyboard_layout.lua registers " ..
			"active_layout_rows() in R.build's list-provider argument and that function RETURNS " ..
			"provider rows. Declared `dynamic`, the renderer looks for a handler, finds none, and " ..
			"skips the row — the layout submenu then lists no layouts and only the log says why")
	end)

	helpers.it("every row the actual layout provider retains its declared native record caption and command ABI", LayoutFixture.scoped(function()
		local src = helpers.read_driver_source("local function active_layout_rows")
		local body = src and src:match("local function active_layout_rows%(%)(.-)\n\tend")
		helpers.assert_true(type(body) == "string" and #body > 0, "the genuine active_layout_rows source must exist")
		helpers.assert_true(body:find("label%s*=%s*title") == nil, "the nil out-of-scope title assignment remains forbidden")
		local input = helpers.load_with_stubs("modules.keymap.input_sources")
		local records = {
			{id = "fixture.selected", name = "Native sélection %s", selected = true},
			{id = "fixture.available", name = "Native source {1}", selected = false},
		}
		input.list_active_keyboard_layouts = function() return records end
		input.build_kl_name_to_tis_id = function() return {} end
		input.resolve_installed_ergopti_version = function() return nil end
		input.ergopti_in_active_layouts = function() return false end
		local renderer = LayoutFixture.install(require("infra.i18n"))
		package.loaded["ui.menu.menu_keyboard_layout"] = nil
		local Layout = require("ui.menu.menu_keyboard_layout")
		local source_rows, source_refs
		local genuine_build = renderer.build
		renderer.build = function(...)
			local args = table.pack(...)
			local providers = args[1] == "layout_menu" and args[6]
			local genuine_provider = providers and providers.active_layouts
			if genuine_provider then
				providers.active_layouts = function(...)
					local result = table.pack(genuine_provider(...))
					source_rows = result[1]
					source_refs = {}; for index, row in ipairs(source_rows) do
						source_refs[index] = {row = row, label = row.label, action = row.action, checked = row.checked, disabled = row.disabled}
					end
					return table.unpack(result, 1, result.n)
				end
			end
			local result = table.pack(xpcall(function() return genuine_build(table.unpack(args, 1, args.n)) end, debug.traceback))
			if genuine_provider then providers.active_layouts = genuine_provider end
			if not result[1] then error(result[2], 0) end
			return table.unpack(result, 2, result.n)
		end
		local context = {base_dir = helpers.driver_root(), state = {}, updateMenu = function() end}
		local function build_and_assert()
			local item = Layout.build(context)
			helpers.assert_type(item, "table", "the real Layout constructor admits the declared provider")
			helpers.assert_type(source_rows, "table"); helpers.assert_eq(#source_rows, #records, "both actual OS records pass through the genuine list route")
			local native_root = renderer.render_rows({item}, "top_level")
			local native = assert(native_root[1]).menu
			for index, record in ipairs(records) do
				local source = source_rows[index]
				helpers.assert_eq(source.label, record.name, "literal native names are neither translated nor printf/numbered formats")
				helpers.assert_true(rawequal(source, source_refs[index].row)); helpers.assert_nil(source.title); helpers.assert_nil(source.fn)
				local found
				for _, row in ipairs(native) do if row.title == record.name then helpers.assert_nil(found, "each actual record appears once"); found = row end end
				helpers.assert_type(found, "table", "the actual materializer preserves the literal record caption")
				helpers.assert_nil(found.label); helpers.assert_nil(found.action)
				helpers.assert_true(rawequal(found.fn, source_refs[index].action), "the same genuine provider command reaches native fn")
				helpers.assert_eq(found.checked, source_refs[index].checked); helpers.assert_eq(found.disabled, source_refs[index].disabled)
				helpers.assert_eq(source.label, source_refs[index].label); helpers.assert_true(rawequal(source.action, source_refs[index].action))
			end
			helpers.assert_type(source_rows[2].action, "function", "the selectable actual record owns its declared command")
			local compose = assert(renderer.native_composition("macos_download_root"))
			helpers.assert_eq(compose({download = {}, body = native_root}), true,
				"the genuinely materialized Layout subtree satisfies strict completed-native ABI")
		end
		local ok, err = xpcall(function()
			build_and_assert()
			local root = renderer.get_root()
			local declaration = root.layout_native_record_choice
			local admitted, admission_error = xpcall(function()
				root.layout_native_record_choice = nil
				helpers.assert_nil(Layout.build(context), "withdrawn actual record declaration never invents a native row")
			end, debug.traceback)
			root.layout_native_record_choice = declaration
			if not admitted then error(admission_error, 0) end
			build_and_assert()
			local name = records[2].name
			local valid, caption_error = xpcall(function()
				records[2].name = "invalid\0caption"
				helpers.assert_nil(Layout.build(context), "invalid actual native caption refuses instead of creating an unlabelled row")
			end, debug.traceback)
			records[2].name = name
			if not valid then error(caption_error, 0) end
			build_and_assert()
		end, debug.traceback)
		renderer.build = genuine_build
		if not ok then error(err, 0) end
	end))
end)
