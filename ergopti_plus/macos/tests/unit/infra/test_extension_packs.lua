--- tests/unit/infra/test_extension_packs.lua

--- ==============================================================================
--- MODULE: Extension Pack Discovery Tests (macOS)
--- DESCRIPTION:
--- The macOS driver discovered no extension pack at all: the menu counted the
--- bundled demo from its own disk walk while no pack ever reached the typing
--- engine, and a layout installed through the manager could not bring its
--- hotstrings. These tests pin the discovery the Linux and Windows drivers
--- already perform: the same roots in the same order, the shared scanner, the
--- existing TOML loader and no activation. The scanner refuses a partial
--- listing; the boot catalogue leaves out, and logs, only the broken pack.
--- ==============================================================================

local helpers = require("tests.helpers")
local Logger = require("infra.logger")
helpers.admit_logger_privacy(Logger)
local Packs = require("infra.extension_packs")

--- Runs a callback while capturing the extension packs' error log lines.
--- @param callback function Body.
--- @return table Captured error messages, formatted.
--- @return any Callback result.
local function capturing_errors(callback)
	local saved = Logger.error
	local errors = {}
	Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
	local ok, result = pcall(callback)
	Logger.error = saved
	if not ok then error(result, 0) end
	return errors, result
end

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
				shipped_extension_root = function() return { pack = "/app/layouts/registry/ergopti" } end,
			}
			helpers.assert_eq(Packs.roots(), { "/app/_shared/../extensions", "/installed/generation",
				{ pack = "/app/layouts/registry/ergopti" }, "/user/extensions" })
		end)
	end)

	helpers.it("(layout-extension-macos) boots without installed layouts' packs when their record is unreadable", function()
		helpers.with_stub_scope({ "infra.paths", "infra.config_paths", "modules.keymap.layout_registry" }, function()
			package.loaded["infra.paths"] = { shared_root = function() return "/app/_shared" end }
			package.loaded["infra.config_paths"] = { get_config_dir = function() return "/user/" end }
			package.loaded["modules.keymap.layout_registry"] = {
				extension_roots = function() error("the installed-layouts record has schema version 99", 0) end,
				-- No Ergopti extension shipped here: only the installed record is at stake.
				shipped_extension_root = function() return nil end,
			}
			local errors, roots = capturing_errors(Packs.roots)
			helpers.assert_eq(roots, { "/app/_shared/../extensions", "/user/extensions" },
				"a corrupt installed record costs its layouts' packs, never the bundled or user ones")
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("schema version 99", 1, true) ~= nil, errors[1])
		end)
	end)

	helpers.it("(layout-extension-macos) skips a pack folder linked to a missing target, keeping its siblings", function()
		local errors, found = capturing_errors(function()
			return with_filesystem(function(path)
				if path == "/packs/moved" then return nil end
				return { mode = path:match("%.toml$") and "file" or "directory" }
			end, {
				classify_no_follow = function(path)
					if path == "/packs/moved" then return { mode = "link" }, "ok" end
					return nil, "absent"
				end,
				read_with_status = function() return nil, "absent" end,
			}, { try_entries = function(path)
				return path == "/packs" and { "moved", "sample" } or {}, true
			end }, function() return Packs.scan({ "/packs" }) end)
		end)
		helpers.assert_eq(#found, 1)
		helpers.assert_eq(found[1].id, "sample")
		helpers.assert_eq(#errors, 1, "the dangling link is reported, not silently dropped")
	end)

	helpers.it("(ergopti-hotstrings-ext) counts the shipped Ergopti as installed, and nothing when none shipped", function()
		local LayoutRegistry = require("modules.keymap.layout_registry")
		local settings = { ergopti_family = "ergopti" }
		local files = { ["/app/registry/ergopti/manifest.toml"] = true }
		local deps = { settings = settings, bundled_dir = "/app/registry/",
			exists = function(path) return files[path] == true end }
		helpers.assert_eq(LayoutRegistry.shipped_extension_root(deps), { pack = "/app/registry/ergopti" })
		files = {}
		helpers.assert_nil(LayoutRegistry.shipped_extension_root(deps), "a registry without the extension ships none")
		deps.bundled_dir = nil
		helpers.assert_nil(LayoutRegistry.shipped_extension_root(deps))
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

	helpers.it("(layout-extension-macos) leaves a broken pack out of the boot catalogue and reports it", function()
		Packs._reset()
		local manifests = {
			["/ext/broken/manifest.toml"] = "[extension.hotstring_bindings.x]\nenabled = true\n",
			["/ext/garbled/manifest.toml"] = "[extension\nname = ",
			["/ext/healthy/manifest.toml"] = '[extension]\nname = "Healthy"\n',
		}
		local errors, found = capturing_errors(function()
			return Packs.discover({ "/ext", "/unlistable" }, {
				list_dirs = function(root)
					if root == "/unlistable" then error("Extension directory enumeration did not commit", 0) end
					return { "/ext/broken", "/ext/garbled", "/ext/healthy" }
				end,
				list_files = function(dir) return { dir .. "/words.toml" } end,
				read_file = function(path) return manifests[path] end,
			})
		end)
		helpers.assert_eq(#found, 1, "one broken pack must not cost the boot every other pack")
		helpers.assert_eq(found[1].id, "healthy")
		helpers.assert_eq(Packs.catalogue(), found)
		helpers.assert_eq(#errors, 3, "each left-out pack and root is reported")
		helpers.assert_true(errors[1]:find("'broken'", 1, true) ~= nil, errors[1])
		helpers.assert_true(errors[3]:find("/unlistable", 1, true) ~= nil, errors[3])
		Packs._reset()
	end)

	helpers.it("(layout-extension-macos) registers only packs whose groups the preference projection can address", function()
		Packs._reset()
		local errors, found = capturing_errors(function()
			return Packs.discover({ "/ext" }, {
				list_dirs = function() return { "/ext/com.acme.abbrevs", "/ext/acme" } end,
				list_files = function(dir)
					return { dir .. "/words.toml", dir .. "/words.old.toml" }
				end,
				read_file = function() return nil end,
			})
		end)
		helpers.assert_eq(#found, 1)
		helpers.assert_eq(found[1].id, "acme")
		helpers.assert_eq(#errors, 2, "the dotted pack and the backup file are each reported")
		-- The projection run before keymap.start asks the manifest for each
		-- registered group's default; one unknown path aborts the boot there.
		local Manifest = require("infra.manifest_reader")
		for _, pack in ipairs(found) do
			for _, file in ipairs(pack.toml_files) do
				local key = "hotstrings.groups." .. require("hotstrings.extensions").category_key(pack.id, file.stem)
				helpers.assert_eq(Manifest.default_for(key), false, key)
			end
		end
		Packs._reset()
	end)

	helpers.it("(layout-extension-macos) commits an empty catalogue when no root can be resolved", function()
		Packs._reset()
		helpers.with_stub_scope({ "infra.paths" }, function()
			package.loaded["infra.paths"] = { shared_root = function() return nil end }
			local errors, found = capturing_errors(function() return Packs.discover() end)
			helpers.assert_eq(found, {})
			helpers.assert_eq(#errors, 1)
			helpers.assert_eq(Packs.routes(), {}, "the loader still reads a committed, empty route table")
		end)
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

	helpers.it("(layout-extension-binding) leaves out the second owner of one bound section", function()
		Packs._reset()
		local errors, found = capturing_errors(function()
			return Packs.discover({ "/ext" }, packs_io({
				first = MAGICREPEAT_BINDING,
				second = MAGICREPEAT_BINDING,
			}, { first = { "magicrepeat" }, second = { "magicrepeat" } }))
		end)
		helpers.assert_eq(#found, 1)
		helpers.assert_eq(found[1].id, "first")
		helpers.assert_eq(#errors, 1)
		helpers.assert_true(errors[1]:find("magickey.repeat_corrections", 1, true) ~= nil, errors[1])
		helpers.assert_eq(Packs.source("magickey", "repeat_corrections"), "/ext/first/hotstrings/magicrepeat.toml",
			"readers resolve the one accepted owner instead of raising on every call")
		Packs._reset()
	end)

	helpers.it("(layout-extension-binding) refuses a whole binding over a section another pack already owns", function()
		Packs._reset()
		local errors, found = capturing_errors(function()
			return Packs.discover({ "/ext" }, packs_io({
				a_sections = MAGICREPEAT_BINDING,
				b_whole = '[extension.hotstring_bindings.magic]\ncategory = "magickey"\n'
					.. 'feature_section = "hotstrings.magic_key"\nsource = "common"\n',
			}, { a_sections = { "magicrepeat" }, b_whole = { "magic" } }))
		end)
		helpers.assert_eq(#found, 1, "a whole binding scanned after a section binding still conflicts")
		helpers.assert_eq(found[1].id, "a_sections")
		helpers.assert_eq(#errors, 1)
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

	helpers.it("(layout-extension-macos) reports and drops a pack file the loader refuses, keeping the boot", function()
		local packs = { { id = "sample", bound_files = {}, toml_files = {
			{ stem = "broken", path = "/private/broken.toml" },
			{ stem = "raising", path = "/private/raising.toml" },
			{ stem = "rolls", path = "/private/rolls.toml" },
		} } }
		local errors, loaded = capturing_errors(function()
			return Packs.load(packs, { load_toml = function(_, path)
				if path == "/private/raising.toml" then error("reader crashed", 0) end
				return path ~= "/private/broken.toml"
			end })
		end)
		helpers.assert_eq(loaded, { { name = "ext:sample:rolls", path = "/private/rolls.toml", extension = "sample" } })
		helpers.assert_eq(packs[1].toml_files, { { stem = "rolls", path = "/private/rolls.toml" } },
			"the menu's catalogue offers only the groups the keymap registered")
		helpers.assert_eq(#errors, 2, "an installed pack must not disappear without a logged error")
	end)
end)
