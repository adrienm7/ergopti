--- tests/unit/infra/test_ergopti_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Ergopti Extension Hotstrings (macOS)
--- DESCRIPTION:
--- SFB reduction, rolls and the magic key's repeat corrections moved from the
--- shared hotstrings folder into the Ergopti layout extension. These tests read
--- the SHIPPED files: with the Ergopti extension the app ships, discovery routes
--- the three groups to its files under their historical categories and
--- sections, so every saved preference still addresses them and the typed
--- outputs are the shared ones; without it, nothing supplies them.
--- ==============================================================================

local helpers = require("tests.helpers")

local Packs     = require("infra.extension_packs")
local TomlCodec = require("toml_codec.codec")

--- The repository's static folder, from this driver's shared tree.
--- @return string
local function static_dir()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local macos = source:match("^(.*)/tests/unit/infra/[^/]+$")
	if macos == nil or macos == "" then macos = "." end
	return macos .. "/../.."
end

--- Real-filesystem scanner collaborators: sorted children of one kind.
--- @return table io_fns
local function real_io()
	local function list(path, flag)
		local out = {}
		local handle = io.popen('find "' .. path .. '" -mindepth 1 -maxdepth 1 -type ' .. flag .. ' 2>/dev/null')
		for line in handle:lines() do out[#out + 1] = line end
		handle:close()
		table.sort(out)
		return out
	end
	return {
		list_dirs  = function(path) return list(path, "d") end,
		list_files = function(path) return list(path, "f") end,
		read_file  = function(path)
			local fh = io.open(path, "r")
			if not fh then return nil end
			local text = fh:read("*a")
			fh:close()
			return text
		end,
	}
end

--- The shipped roots: bundled extensions, then the Ergopti extension when shipped.
--- @param with_ergopti boolean
--- @return table
local function roots(with_ergopti)
	local static = static_dir()
	local out = { static .. "/ergopti_plus/extensions" }
	if with_ergopti then
		local LayoutRegistry = require("modules.keymap.layout_registry")
		out[#out + 1] = LayoutRegistry.shipped_extension_root({
			settings = { ergopti_family = "ergopti" },
			bundled_dir = static .. "/layouts/registry/",
			exists = function(path)
				local fh = io.open(path, "r")
				if fh then fh:close() end
				return fh ~= nil
			end,
		})
	end
	return out
end

--- The first entry of a trigger in one section of a bound file.
--- @param path string
--- @param section string
--- @param trigger string
--- @return table|nil
local function entry(path, section, trigger)
	local fh = assert(io.open(path, "r"))
	local document = TomlCodec.decode(fh:read("*a"))
	fh:close()
	for _, block in ipairs(document[section] or {}) do
		if block[trigger] then return block[trigger] end
	end
	return nil
end

helpers.describe("Ergopti extension hotstrings: shipped with the app", function()
	helpers.it("(ergopti-hotstrings-ext) routes the three groups to the shipped Ergopti extension", function()
		Packs._reset()
		local found = Packs.discover(roots(true), real_io())
		local ergopti
		for _, pack in ipairs(found) do if pack.id == "ergopti" then ergopti = pack end end
		helpers.assert_true(ergopti ~= nil, "the Ergopti extension the app ships is installed")
		helpers.assert_eq(#ergopti.bound_files, 3)
		helpers.assert_eq(#ergopti.toml_files, 0, "none of its files becomes an ext: category")
		local sfbs = Packs.route("sfbsreduction", nil)
		local rolls = Packs.route("rolls", nil)
		helpers.assert_true(sfbs:find("/layouts/registry/ergopti/hotstrings/sfbsreduction.toml", 1, true) ~= nil, sfbs)
		helpers.assert_true(rolls:find("/layouts/registry/ergopti/hotstrings/rolls.toml", 1, true) ~= nil, rolls)
		local magickey, sources = Packs.route("magickey", "/bundled/magickey.toml")
		helpers.assert_eq(magickey, "/bundled/magickey.toml", "the magic key keeps its bundled file")
		helpers.assert_eq(#sources, 1)
		helpers.assert_eq(sources[1].sections, { "repeat_corrections" })
		local unbundled = Packs.unbundled_routes({ magickey = true })
		helpers.assert_eq(#unbundled, 2, "SFB reduction and rolls load although no bundled file carries them")

		-- One historical expansion per moved group, with the flags it always had.
		for _, case in ipairs({
			{ path = sfbs, section = "comma", trigger = ",t", output = "pt" },
			{ path = rolls, section = "hc", trigger = "hc", output = "wh" },
			{ path = sources[1].path, section = "repeat_corrections", trigger = "ccê", output = "ccu" },
		}) do
			local found_entry = entry(case.path, case.section, case.trigger)
			helpers.assert_true(found_entry ~= nil, case.trigger)
			helpers.assert_eq(found_entry.output, case.output)
			helpers.assert_eq(found_entry.is_word, false)
			helpers.assert_eq(found_entry.auto_expand, true)
		end
		Packs._reset()
	end)

	helpers.it("(ergopti-hotstrings-ext) routes nothing when Ergopti is not installed", function()
		Packs._reset()
		Packs.discover(roots(false), real_io())
		helpers.assert_eq(table.pack(Packs.route("rolls", nil)), { n = 2 })
		helpers.assert_eq(table.pack(Packs.route("magickey", "/bundled/magickey.toml")),
			{ "/bundled/magickey.toml", n = 2 })
		helpers.assert_eq(Packs.unbundled_routes({}), {})
		Packs._reset()
	end)
end)
