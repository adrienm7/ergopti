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
--- The second case below pins the other half of the same bug: the rows the
--- provider builds must carry a label. Theirs read `label = title`, a name no
--- longer in scope after a rename, so every row would have come out unlabelled
--- even once the renderer reached them.
--- ==============================================================================

local helpers = require("tests.helpers")

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

	helpers.it("every row the layout provider builds carries a label", function()
		local src = helpers.read_driver_source("local function active_layout_rows")
		local body = src:match("local function active_layout_rows%(%)(.-)\n\tend")
		helpers.assert_true(body ~= nil, "active_layout_rows() must exist in menu_keyboard_layout.lua")
		-- `title` is a table KEY throughout this driver and is not a local here.
		-- Assigning it as a VALUE binds the nil global, and the row comes out with
		-- no label at all — which no test could see, because the renderer was
		-- skipping the row before it ever reached one.
		helpers.assert_true(body:find("label%s*=%s*title") == nil,
			"active_layout_rows must not build a row with `label = title` — `title` is not in " ..
			"scope here, so the row would render unlabelled")
		helpers.assert_true(body:find("label%s*=%s*row_label") ~= nil,
			"each layout row must take its label from the display name computed for that record")
	end)
end)
