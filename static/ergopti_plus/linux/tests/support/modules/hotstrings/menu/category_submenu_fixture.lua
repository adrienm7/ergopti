--- tests/support/modules/hotstrings/menu/category_submenu_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_category_submenu
--- DESCRIPTION:
--- Prelude shared by the test_category_submenu_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A config module standing in for hotstrings_config, recording what it is asked.
--- @param opts table { enabled = boolean, sections_enabled = table }
--- @return table config, table log
local function fake_config(opts)
	opts = opts or {}
	local log = { toggled = {}, sections = {}, bulk = {} }
	local enabled = opts.enabled ~= false
	local section_state = opts.sections_enabled or {}

	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function(id) return id == "rolls" and enabled or false end,
		toggle_group = function(id) log.toggled[#log.toggled + 1] = id end,
		is_section_enabled = function(_, section)
			if not enabled then return false end
			if section_state[section] == nil then return true end
			return section_state[section]
		end,
		toggle_section = function(id, section)
			log.sections[#log.sections + 1] = id .. "." .. section
			return true
		end,
		set_category_scope_enabled = function(ids, on)
			log.bulk[#log.bulk + 1] = table.concat(ids, ",") .. "=" .. tostring(on)
			return true
		end,
		get_category = function(id)
			if id ~= "rolls" then return nil end
			return {
				id = "rolls",
				path = "/home/u/.config/ergopti/hotstrings/rolls.toml",
				description = { en = "Rolls", fr = "Roulements" },
				sections_order = { "hc", "sx" },
				sections = { hc = { count = 12 }, sx = { count = 3 } },
				count = 15,
				-- Rolls come from the Ergopti layout extension, whose submenu lists them.
				extension = { id = "ergopti", name = "Ergopti" },
			}
		end,
		reload = function() end,
	}, log
end

--- Builds the menu and returns the rolls category row.
--- @param config table
--- @param ctx_extra table|nil
--- @return table|nil row
local function rolls_row(config, ctx_extra)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ctx = { config = config, _version = "9.9.9" }
	for k, v in pairs(ctx_extra or {}) do ctx[k] = v end

	local found = nil
	local function search(list)
		for _, item in ipairs(list or {}) do
			if type(item.title) == "string"
				and (item.title:find("Rolls", 1, true) or item.title:find("Roulements", 1, true))
				and type(item.menu) == "table" then
				found = item
				return
			end
			if type(item.menu) == "table" then
				search(item.menu)
				if found then return end
			end
		end
	end
	search(mb.build(ctx))
	return found
end

--- Runs an actual shared renderer over an independently changed command label.
--- @param body function Real native-provider observations and assertions.
local function with_file_command(body, change_label)
	local saved = package.loaded["infra.manifest_menu"]
	local ok, err = xpcall(function()
		local path = require("infra.paths").shared("modules/menu/menu_manifest.json")
		local native_captions = require("infra.i18n")
		local renderer = assert(require("menu.renderer").new({
			platform = "linux", manifest_path = function() return path end,
			json_decode = function(bytes)
				local document = require("json").decode(bytes)
				if change_label then document.hotstring_file_commands[1].i18n = "fixture.category.file.command" end
				return document
			end,
			i18n = { get = function(key)
				-- The counted parent and full-tray header require genuine translated captions;
				-- the file-command assertions retain their independent key labels.
				if key == "menu.hotstrings.title" or key == "menu.builder.active_brand"
					or key == "menu.builder.title_paused" then return native_captions.get(key) end
				return key
			end, section = function(key) return key end },
			logger = require("logger.shim"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		body()
	end, debug.traceback)
	package.loaded["infra.manifest_menu"] = saved
	package.loaded["ui.menu.menu_builder"] = nil
	if not ok then error(err, 0) end
end

return {
	helpers = helpers,
	fake_config = fake_config,
	rolls_row = rolls_row,
	with_file_command = with_file_command,
}
