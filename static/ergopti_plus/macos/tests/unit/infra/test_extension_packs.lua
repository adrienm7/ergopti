--- tests/unit/infra/test_extension_packs.lua

--- ==============================================================================
--- MODULE: Extension Pack Discovery Tests (macOS)
--- DESCRIPTION:
--- The macOS driver discovered no extension pack at all: the menu counted the
--- bundled demo from its own disk walk while no pack ever reached the typing
--- engine, and a layout installed through the manager could not bring its
--- hotstrings. These tests pin the discovery the Linux and Windows drivers
--- already perform: the same roots in the same order, the shared scanner, the
--- existing TOML loader, no activation, and a refusal of any partial catalogue.
--- ==============================================================================

local helpers = require("tests.helpers")
local Packs = require("infra.extension_packs")

--- Runs a callback with stubbed filesystem collaborators, restoring them after.
--- @param attributes function Replacement for hs.fs.attributes.
--- @param file_system table Replacement adapters.file_system module.
--- @param fs_dir table Replacement infra.fs_dir module.
--- @param callback function Body.
--- @return any Callback results, or rethrows its error.
local function with_filesystem(attributes, file_system, fs_dir, callback)
	local saved_attributes = hs.fs.attributes
	local saved_files = package.loaded["adapters.file_system"]
	local saved_dirs = package.loaded["infra.fs_dir"]
	hs.fs.attributes = attributes
	package.loaded["adapters.file_system"] = file_system
	package.loaded["infra.fs_dir"] = fs_dir
	local outcome = table.pack(pcall(callback))
	hs.fs.attributes = saved_attributes
	package.loaded["adapters.file_system"] = saved_files
	package.loaded["infra.fs_dir"] = saved_dirs
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

helpers.describe("Extension packs: discovery roots and scanning", function()
	helpers.it("(layout-extension-macos) orders bundled, committed layout and user roots through their owners", function()
		helpers.with_stub_scope({ "infra.paths", "infra.config_paths", "modules.keymap.layout_registry" }, function()
			package.loaded["infra.paths"] = { shared_root = function() return "/app/_shared" end }
			package.loaded["infra.config_paths"] = { get_config_dir = function() return "/user/" end }
			package.loaded["modules.keymap.layout_registry"] = {
				extension_roots = function() return { "/installed/generation" } end,
			}
			helpers.assert_eq(Packs.roots(), { "/app/_shared/../extensions", "/installed/generation", "/user/extensions" })
		end)
	end)

	helpers.it("(layout-extension-macos) refuses an unresolvable shared root instead of dropping bundled packs", function()
		helpers.with_stub_scope({ "infra.paths" }, function()
			package.loaded["infra.paths"] = { shared_root = function() return nil end }
			local ok, failure = pcall(Packs.roots)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(failure):find("shared extension directory", 1, true) ~= nil, tostring(failure))
		end)
	end)

	helpers.it("(layout-extension-macos) reads a missing root as no extension installed", function()
		local found = with_filesystem(function() return nil end,
			{ classify_no_follow = function() return nil, "absent" end },
			{ try_entries = function() error("an absent root is never listed") end },
			function() return Packs.scan({ "/missing" }) end)
		helpers.assert_eq(#found, 0)
	end)

	helpers.it("(layout-extension-macos) refuses unproven child absence instead of publishing a partial catalogue", function()
		local ok = pcall(with_filesystem, function(path)
			if path == "/packs" then return { mode = "directory" } end
			return nil
		end, { classify_no_follow = function() return nil, "error" end },
		{ try_entries = function() return { "sample" }, true end },
		function() return Packs.scan({ "/packs" }) end)
		helpers.assert_true(not ok, "a failed child stat cannot mean an empty extension catalogue")
	end)

	helpers.it("(layout-extension-macos) refuses an unlistable directory and a root that is a file", function()
		local unlistable = pcall(with_filesystem, function() return { mode = "directory" } end, {},
			{ try_entries = function() return {}, false end },
			function() return Packs.scan({ "/packs" }) end)
		helpers.assert_true(not unlistable, "an enumeration failure cannot read as no extension")
		local file_root = pcall(with_filesystem, function() return { mode = "file" } end, {},
			{ try_entries = function() return {}, true end },
			function() return Packs.scan({ "/packs" }) end)
		helpers.assert_true(not file_root, "a root that is a file is a broken install, not an empty one")
	end)

	helpers.it("(layout-extension-macos) does not treat dot directory entries as extension packs", function()
		local found = with_filesystem(function(path)
			return { mode = path:match("%.toml$") and "file" or "directory" }
		end, { read_with_status = function() return nil, "absent" end },
		{ try_entries = function(path)
			return path == "/packs" and { ".", "..", "sample" } or {}, true
		end }, function() return Packs.scan({ "/packs" }) end)
		helpers.assert_eq(#found, 1)
		helpers.assert_eq(found[1].id, "sample")
	end)

	helpers.it("(layout-extension-macos) refuses an unreadable manifest", function()
		local ok = pcall(with_filesystem, function(path)
			return { mode = path:match("%.toml$") and "file" or "directory" }
		end, { read_with_status = function() return nil, "error" end },
		{ try_entries = function(path) return path == "/packs" and { "sample" } or {}, true end },
		function() return Packs.scan({ "/packs" }) end)
		helpers.assert_true(not ok, "an unreadable manifest cannot rename or unbind a pack silently")
	end)
end)

helpers.describe("Extension packs: one catalogue per boot", function()
	helpers.it("(layout-extension-macos) discovers once and refuses a second discovery", function()
		Packs._reset()
		local ok_before = pcall(Packs.catalogue)
		helpers.assert_true(not ok_before, "no reader may see a catalogue before discovery commits")
		local io_fns = {
			list_dirs = function(root) return root == "/bundled" and { "/bundled/demo" } or {} end,
			list_files = function(dir) return dir == "/bundled/demo/hotstrings" and { dir .. "/phrases.toml" } or {} end,
			read_file = function() return '[extension]\nname = "Demo"\n' end,
		}
		local found = Packs.discover({ "/bundled" }, io_fns)
		helpers.assert_eq(Packs.catalogue(), found)
		helpers.assert_eq(Packs.source("ext:demo:phrases"), "/bundled/demo/hotstrings/phrases.toml")
		helpers.assert_nil(Packs.source("magickey", "repeat_corrections"))
		local again = pcall(Packs.discover, { "/bundled" }, io_fns)
		helpers.assert_true(not again, "a second discovery could publish packs the loader never registered")
		Packs._reset()
	end)

	helpers.it("(layout-extension-macos) a refused discovery leaves no catalogue behind", function()
		Packs._reset()
		local ok = pcall(Packs.discover, { "/ext" }, {
			list_dirs = function() return { "/ext/broken" } end,
			list_files = function() return {} end,
			read_file = function() return "[extension.hotstring_bindings.x]\nenabled = true\n" end,
		})
		helpers.assert_true(not ok)
		helpers.assert_true(not pcall(Packs.catalogue), "a refused scan must not publish a partial catalogue")
		Packs._reset()
	end)
end)

--- Scanner collaborators for one root whose packs declare the given manifests.
--- @param manifests table Map of pack id to manifest text.
--- @param files table Map of pack id to hotstring file stems.
--- @return table io_fns
local function packs_io(manifests, files)
	local ids = {}
	for id in pairs(manifests) do ids[#ids + 1] = id end
	table.sort(ids)
	return {
		list_dirs = function(root)
			local dirs = {}
			for _, id in ipairs(ids) do dirs[#dirs + 1] = root .. "/" .. id end
			return dirs
		end,
		list_files = function(dir)
			local id = dir:match("^/ext/([^/]+)/hotstrings$")
			local out = {}
			for _, stem in ipairs(id and files[id] or {}) do out[#out + 1] = dir .. "/" .. stem .. ".toml" end
			return out
		end,
		read_file = function(path) return manifests[path:match("^/ext/([^/]+)/")] end,
	}
end

local MAGICREPEAT_BINDING = '[extension.hotstring_bindings.magicrepeat]\ncategory = "magickey"\n'
	.. 'feature_section = "hotstrings.magic_key"\nsections = ["repeat_corrections"]\nsource = "common"\n'

helpers.describe("Extension packs: bound geometry routes", function()
	helpers.it("(layout-extension-binding) routes whole and section bindings to their bundled categories", function()
		Packs._reset()
		helpers.assert_true(not pcall(Packs.routes), "no loader may read routes before discovery commits")
		Packs.discover({ "/ext" }, packs_io({
			ergopti = MAGICREPEAT_BINDING .. '[extension.hotstring_bindings.rolls]\ncategory = "rolls"\n'
				.. 'feature_section = "hotstrings.rolls"\nsource = "common"\n',
			demo = '[extension]\nname = "Demo"\n',
		}, { ergopti = { "magicrepeat", "rolls" }, demo = { "phrases" } }))
		helpers.assert_eq(Packs.routes(), {
			magickey = { section_sources = { { path = "/ext/ergopti/hotstrings/magicrepeat.toml",
				sections = { "repeat_corrections" } } } },
			rolls = { path = "/ext/ergopti/hotstrings/rolls.toml" },
		})
		helpers.assert_eq(Packs.source("rolls"), "/ext/ergopti/hotstrings/rolls.toml",
			"a whole binding also names the file the category's metadata comes from")
		helpers.assert_eq(table.pack(Packs.route("rolls", "/bundled/rolls.toml")),
			{ "/ext/ergopti/hotstrings/rolls.toml", n = 2 }, "a whole binding replaces the bundled file")
		helpers.assert_eq(table.pack(Packs.route("magickey", "/bundled/magickey.toml")), {
			"/bundled/magickey.toml",
			{ { path = "/ext/ergopti/hotstrings/magicrepeat.toml", sections = { "repeat_corrections" } } },
			n = 2,
		}, "a section binding loads over the bundled file")
		helpers.assert_eq(table.pack(Packs.route("symbols", "/bundled/symbols.toml")),
			{ "/bundled/symbols.toml", n = 2 }, "an unbound category keeps its bundled file")
		helpers.assert_eq(Packs.unbundled_routes({ magickey = true }), {
			{ category = "rolls", path = "/ext/ergopti/hotstrings/rolls.toml" },
		}, "a whole binding of a category the driver does not carry still loads")
		helpers.assert_eq(Packs.unbundled_routes({ rolls = true }), {
			{ category = "magickey", section_sources = {
				{ path = "/ext/ergopti/hotstrings/magicrepeat.toml", sections = { "repeat_corrections" } },
			} },
		}, "sections bound into an absent category come back without a path, to be reported")
		Packs._reset()
	end)

	helpers.it("(layout-extension-binding) refuses two owners of one bound section at discovery", function()
		Packs._reset()
		local ok, failure = pcall(Packs.discover, { "/ext" }, packs_io({
			first = MAGICREPEAT_BINDING,
			second = MAGICREPEAT_BINDING,
		}, { first = { "magicrepeat" }, second = { "magicrepeat" } }))
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(failure):find("magickey.repeat_corrections", 1, true) ~= nil, tostring(failure))
		helpers.assert_true(not pcall(Packs.catalogue), "a conflicting binding must not publish a catalogue")
		helpers.assert_true(not pcall(Packs.routes), "nor half of its routes")
		Packs._reset()
	end)
end)

helpers.describe("Extension packs: registration", function()
	helpers.it("(layout-extension-macos) preserves user overlay precedence and registers without enable writes", function()
		local found = Packs.scan({ "/bundled", "/installed", "/user" }, {
			list_dirs = function(root) return { root .. "/ergopti" } end,
			list_files = function(root) return { root .. "/rolls.toml" } end,
			read_file = function() return '[extension]\nname = "Ergopti"\n' end,
		})
		helpers.assert_eq(#found, 1)
		local calls = {}
		local loaded = Packs.load(found, {
			load_toml = function(name, path) calls[#calls + 1] = { name, path } return true end,
			enable_group = function() error("installation cannot enable groups") end,
			set_groups_sections_enabled = function() error("installation cannot enable sections") end,
		})
		helpers.assert_eq(#loaded, 1)
		helpers.assert_eq(calls[1][1], "ext:ergopti:rolls")
		helpers.assert_eq(calls[1][2], "/user/ergopti/hotstrings/rolls.toml")
		helpers.assert_eq(loaded[1], { name = "ext:ergopti:rolls", path = "/user/ergopti/hotstrings/rolls.toml",
			extension = "ergopti" })
	end)

	helpers.it("(layout-extension-macos) keeps bound geometry files out of the ext: categories", function()
		local found = Packs.scan({ "/ext" }, {
			list_dirs = function() return { "/ext/geometry" } end,
			list_files = function(dir) return { dir .. "/magicrepeat.toml", dir .. "/extra.toml" } end,
			read_file = function()
				return '[extension.hotstring_bindings.magicrepeat]\ncategory = "magickey"\n'
					.. 'feature_section = "hotstrings.magic_key"\nsections = ["repeat_corrections"]\nsource = "common"\n'
			end,
		})
		local names = {}
		Packs.load(found, { load_toml = function(name) names[#names + 1] = name return true end })
		helpers.assert_eq(names, { "ext:geometry:extra" },
			"a bound file supplies its historical category, never a second ext: group")
	end)

	helpers.it("(layout-extension-macos) rejects an unsuccessful existing-loader registration", function()
		local ok = pcall(Packs.load, { { id = "sample", toml_files = { { stem = "rolls", path = "/private/rolls.toml" } },
			bound_files = {} } }, { load_toml = function() return false end })
		helpers.assert_true(not ok, "an installed pack must not silently disappear from the live catalogue")
	end)
end)
