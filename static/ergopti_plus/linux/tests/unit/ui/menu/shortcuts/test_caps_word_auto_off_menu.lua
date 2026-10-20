--- tests/unit/ui/menu/shortcuts/test_caps_word_auto_off_menu.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Submenu — Unit Tests (Linux)
--- DESCRIPTION:
--- Renders the actual caps_word_auto_off group builder of menu_builder.lua
--- through the shared renderer and the real settings owner: the delay choice,
--- one checkbox per catalogue delimiter (separators kept), one per declared
--- pointer kind, each change published to config.toml.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real group builder out of menu_builder.lua with its upvalues.
--- @param upvalues table Values the builder closes over.
--- @return function builder
local function load_builder(upvalues)
	local f = assert(io.open(helpers.driver_root() .. "/ui/menu/menu_builder.lua", "rb"))
	local source = f:read("*a")
	f:close()
	local start = assert(source:find('\tgroup_builders["caps_word_auto_off"] = function()', 1, true),
		"the CapsWord group builder is missing")
	local stop = assert(source:find("\n\tend\n", start, true))
	local chunk = "return function(Logger, LOG, i18n_safe, show_error, ctx, ManifestMenu, MagicKey, group_builders) "
		.. source:sub(start, stop + 5) .. " return group_builders[\"caps_word_auto_off\"] end"
	local factory = assert((loadstring or load)(chunk, "=caps_word_auto_off_builder"))()
	local groups = {}
	return factory(upvalues.Logger, "test", upvalues.i18n, upvalues.show_error, upvalues.ctx,
		upvalues.ManifestMenu, upvalues.MagicKey, groups)
end

--- Runs a body over an exclusive config file with freshly loaded owners.
--- @param source string|nil Configuration bytes.
--- @param body function body(rows, context)
local function with_menu(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["modules.shortcuts.caps_word_auto_off"] = nil
			local context = { path = path, changes = 0, errors = 0 }
			local i18n = require("infra.i18n")
			local builder = load_builder({
				Logger = require("logger.shim"), i18n = i18n.get,
				show_error = function() context.errors = context.errors + 1 end,
				ctx = { commands = {}, state_getters = {},
					on_menu_changed = function() context.changes = context.changes + 1 end },
				ManifestMenu = require("infra.manifest_menu"),
				MagicKey = { get = function() return "★" end },
			})
			context.i18n = i18n.get
			context.build = builder
			body(context)
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

--- Flattens rendered rows into { title, checked, fn, disabled } leaves.
local function leaves(rows, out)
	out = out or {}
	for _, row in ipairs(rows or {}) do
		if type(row) == "table" then
			local children = type(row.menu) == "table" and row.menu or row.items
			if type(children) == "table" then leaves(children, out)
			elseif row.title then out[#out + 1] = row end
		end
	end
	return out
end

local function find(rows, title)
	for _, row in ipairs(leaves(rows)) do
		if row.title == title then return row end
	end
	return nil
end

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end

helpers.describe("caps word auto-off menu (Linux)", function()
	helpers.it("caps word auto-off menu, draws one checkbox per delimiter and per declared pointer kind", function()
		with_menu(nil, function(c)
			local rows = assert(c.build(), "the group builds")
			local shipped = {}
			for _, key in ipairs(require("infra.manifest_reader").default_for("shortcuts.caps_word.terminators")) do
				shipped[key] = true
			end
			for _, row in ipairs(require("caps_word.auto_off").terminator_rows()) do
				if not row.separator then
					local item = find(rows, c.i18n(row.label_key))
					helpers.assert_not_nil(item, "a row for the delimiter " .. row.key)
					helpers.assert_eq(item.checked, shipped[row.key] == true,
						row.key .. " follows the stored default")
				end
			end
			local AutoOff = require("modules.shortcuts.caps_word_auto_off")
			local kinds = AutoOff.pointer_kind_rows()
			helpers.assert_true(#kinds > 0, "the manifest declares pointer kinds")
			for _, entry in ipairs(kinds) do
				local item = find(rows, c.i18n(entry.label_key))
				helpers.assert_not_nil(item, "a row for the pointer kind " .. entry.kind)
				helpers.assert_eq(item.checked, true, entry.kind .. " ends CapsWord by default")
			end
		end)
	end)

	helpers.it("caps word auto-off menu, a delimiter and a pointer checkbox publish their change", function()
		with_menu(nil, function(c)
			local rows = c.build()
			local minus = assert(find(rows, c.i18n("terminators.label_minus")))
			helpers.assert_eq(minus.checked, false, "the hyphen ships unchecked")
			minus.fn()
			local left = assert(find(rows, c.i18n("menu.caps_word.pointer.left_click")))
			left.fn()
			local text = read(c.path)
			helpers.assert_contains(text, '"minus"')
			helpers.assert_contains(text, "left_click = false")
			helpers.assert_eq(c.errors, 0)
			helpers.assert_true(c.changes >= 2, "the menu is told about each change")
			local rebuilt = c.build()
			helpers.assert_eq(find(rebuilt, c.i18n("terminators.label_minus")).checked, true)
			helpers.assert_eq(find(rebuilt, c.i18n("menu.caps_word.pointer.left_click")).checked, false)
		end)
	end)

	helpers.it("caps word auto-off menu, the delay choice stores the picked preset", function()
		with_menu(nil, function(c)
			local rows = c.build()
			local five = nil
			for _, row in ipairs(leaves(rows)) do
				if type(row.title) == "string" and row.title:find("^5 ") then five = row end
			end
			helpers.assert_not_nil(five, "the 5 s preset is drawn")
			five.fn()
			helpers.assert_contains(read(c.path), "idle_timeout_seconds = 5")
		end)
	end)
end)

return true
