--- tests/support/layout_rows_fake_mac.lua

--- ==============================================================================
--- MODULE: Layout Rows Fake Mac
--- DESCRIPTION:
--- The collaborators of modules/keymap/layout_rows_build.lua over an in-memory
--- Mac: files, the enabled list, the selected layout, and a keyboard probe that
--- types the selected build's base cells from its own file. Shared by the build's
--- tests and the field run's layout rows check.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Rows = require("layouts.keylayout_rows")

local M = {}

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

local KEYCODES = Json.decode(read(helpers.shared("modules/layouts/mac_keycodes.json")))

--- A Mac the build drives: files, the enabled list, the selection and a probe that
--- translates the selected build's base level from its file.
function M.new(options)
	options = options or {}
	local mac = { files = {}, enabled = {}, selected = "Ergo-L", calls = {} }
	local function log(entry) mac.calls[#mac.calls + 1] = entry end
	local codes = assert(Rows.key_codes(KEYCODES, "ansi"))
	local deps = {
		read = function(path) return mac.files[path] end,
		write = function(path, text) mac.files[path] = text; return true end,
		write_build = function(path, text)
			if mac.files[path] ~= nil then return false, "exists" end
			mac.files[path] = text
			return true
		end,
		delete_build = function(path)
			if options.undeletable then return false, "busy" end
			mac.files[path] = nil
			return true
		end,
		exists = function(path) return mac.files[path] ~= nil end,
		prepare_parent = function() return true end,
		decode_json = Json.decode,
		encode_json = Json.encode,
		layouts_dir = "/L/",
		file_prefix = "ErgoptiRows-",
		record_path = "/C/rows_builds.json",
		keycodes_table = KEYCODES,
		enable_source = function(path, name, done)
			log("enable " .. name)
			mac.enabled[name] = path
			done(true, "OK")
		end,
		disable_source = function(name, _, done)
			log("disable " .. name)
			mac.enabled[name] = nil
			done(true, "OK")
		end,
		confirm_enabled = function(name, _, done) done(true, { listed = true, enabled = mac.enabled[name] ~= nil }) end,
		select_source = function(name, _, done)
			log("select " .. name)
			mac.selected = name
			done(true, "0")
		end,
		confirm_source = function(name, _, done)
			done(true, { listed = true, selected = mac.selected == name, id = "org.unknown.keylayout." .. name })
		end,
		probe = function(request, done)
			local name = request.source_id:match("keylayout%.(.*)$")
			local text = mac.enabled[name] and mac.files[mac.enabled[name]]
			local cells = text and Rows.cells(text, codes)
			if not cells then return done(nil, "unavailable") end
			local levels = {}
			local list = {}
			for _, cell in ipairs(cells.digits) do list[#list + 1] = cell.plain end
			for _, cell in ipairs(cells.edges) do list[#list + 1] = cell.plain end
			for index, cell in ipairs(list) do
				local text_typed = cell and cell.Kind == "text" and cell.Text or ""
				if options.stale_cells and index == 1 then text_typed = "1" end
				levels[index] = { code = request.codes[index], text = text_typed, dead = cell ~= nil and cell.Kind == "dead",
					direct = text_typed ~= "" }
			end
			done({ version = 1, source_id = request.source_id, keyboard_type = 40, levels = levels })
		end,
	}
	return mac, deps
end

return M
