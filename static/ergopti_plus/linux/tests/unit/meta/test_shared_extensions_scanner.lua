--- tests/unit/meta/test_shared_extensions_scanner.lua

--- ==============================================================================
--- MODULE: Extension Pack Discovery (shared)
--- DESCRIPTION:
--- Covers _shared/lua/hotstrings/extensions.lua, the scanner both Lua drivers use
--- to find installed extension packs.
---
--- WHY THIS EXISTS:
--- The extensions mechanism was implemented once, in AHK, and the menu manifest
--- recorded that as `platforms = ["ahk"]` with the reason "scans a Windows
--- extensions directory". The directory it scans is part of THIS repository and
--- ships to all three drivers, so the restriction described the reader rather
--- than the feature — an entire capability was Windows-only by accident, for as
--- long as nobody compared the drivers.
---
--- The scanner takes its I/O injected, which is the whole reason it can be tested
--- at all: the three drivers have nothing in common there (hs.fs, a shelled-out
--- find, and nothing), so the only part worth sharing is the part that decides
--- what a directory MEANS. That is what these tests pin.
---
--- The namespacing is the load-bearing detail. Two extensions may each ship a
--- `rolls.toml`, and a category keyed by file stem would let one silently replace
--- the other — or replace the bundled category of that name, which is the case
--- that actually loses the user data they came for.
--- ==============================================================================

local helpers = require("tests.helpers")

local Extensions = helpers.load_module("hotstrings.extensions")


--- Builds an injected filesystem from a plain description.
--- @param tree table Map of directory path to array of child paths.
--- @param files table Map of file path to contents.
--- @return table The io_fns table the scanner expects.
local function fake_fs(tree, files)
	return {
		list_dirs = function(root)
			return tree[root] or {}
		end,
		list_files = function(dir)
			return tree[dir] or {}
		end,
		read_file = function(path)
			return files[path]
		end,
	}
end


local DEMO_MANIFEST = [[
[extension]
id          = "ergopti-demo"
name        = "Ergopti Demo"
version     = "1.0.0"
description = { fr = "Extension de démonstration.", en = "Demo extension." }
]]





-- ==================================================
-- ==================================================
-- ======= 1/ Reading a manifest ====================
-- ==================================================
-- ==================================================

helpers.describe("extensions: the manifest names the extension", function()

	helpers.it("reads the declared name", function()
		helpers.assert_eq("Ergopti Demo", Extensions.parse_name(DEMO_MANIFEST),
			"the name is what the menu shows; a folder id like 'ergopti-demo' is not a label")
	end)

	helpers.it("returns nil rather than a guess when there is no name", function()
		helpers.assert_eq(nil, Extensions.parse_name("[extension]\nid = \"x\"\n"),
			"so the caller can fall back to the directory id deliberately")
		helpers.assert_eq(nil, Extensions.parse_name(nil),
			"an absent manifest is the ordinary case, not an error")
	end)

	helpers.it("reads every localised description", function()
		local d = Extensions.parse_descriptions(DEMO_MANIFEST)
		helpers.assert_eq("Demo extension.", d.en, "English must survive the inline-table parse")
		helpers.assert_eq("Extension de démonstration.", d.fr, "and so must a non-ASCII value")
	end)

	helpers.it("returns an empty map when there is no description", function()
		local d = Extensions.parse_descriptions("[extension]\nname = \"X\"\n")
		helpers.assert_eq("table", type(d), "always a table, so no caller has to nil-check it")
		helpers.assert_eq(nil, next(d), "and empty rather than populated with something invented")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 2/ Scanning a root =======================
-- ==================================================
-- ==================================================

helpers.describe("extensions: scanning finds packs and names them", function()

	helpers.it("finds an extension and its hotstring packs", function()
		local io_fns = fake_fs({
			["/opt/ext"] = { "/opt/ext/ergopti-demo" },
			["/opt/ext/ergopti-demo/hotstrings"] = {
				"/opt/ext/ergopti-demo/hotstrings/demo-symbols.toml",
				"/opt/ext/ergopti-demo/hotstrings/demo-phrases.toml",
			},
		}, {
			["/opt/ext/ergopti-demo/manifest.toml"] = DEMO_MANIFEST,
		})

		local found = Extensions.scan({ "/opt/ext" }, io_fns)
		helpers.assert_eq(1, #found, "one directory under the root is one extension")
		helpers.assert_eq("ergopti-demo", found[1].id, "the id is the folder name")
		helpers.assert_eq("Ergopti Demo", found[1].name, "and the name comes from its manifest")
		helpers.assert_eq(2, #found[1].toml_files, "both packs must be listed")
	end)

	helpers.it("orders packs by name so the menu does not shuffle between launches", function()
		local io_fns = fake_fs({
			["/opt/ext"] = { "/opt/ext/demo" },
			["/opt/ext/demo/hotstrings"] = {
				"/opt/ext/demo/hotstrings/zeta.toml",
				"/opt/ext/demo/hotstrings/alpha.toml",
			},
		}, {})

		local found = Extensions.scan({ "/opt/ext" }, io_fns)
		helpers.assert_eq("alpha", found[1].toml_files[1].stem,
			"a directory listing has no ordering contract, so the scanner must impose one")
		helpers.assert_eq("zeta", found[1].toml_files[2].stem, "and it must be stable")
	end)

	helpers.it("names an extension after its folder when it has no manifest", function()
		local io_fns = fake_fs({
			["/opt/ext"] = { "/opt/ext/nameless" },
			["/opt/ext/nameless/hotstrings"] = { "/opt/ext/nameless/hotstrings/a.toml" },
		}, {})

		local found = Extensions.scan({ "/opt/ext" }, io_fns)
		helpers.assert_eq("nameless", found[1].name,
			"a manifest-less extension still works, so hiding it would hide packs that load fine")
	end)

	helpers.it("lets a later root override an extension of the same id", function()
		local io_fns = fake_fs({
			["/bundled"] = { "/bundled/demo" },
			["/bundled/demo/hotstrings"] = { "/bundled/demo/hotstrings/a.toml" },
			["/user"] = { "/user/demo" },
			["/user/demo/hotstrings"] = { "/user/demo/hotstrings/a.toml", "/user/demo/hotstrings/b.toml" },
		}, {})

		local found = Extensions.scan({ "/bundled", "/user" }, io_fns)
		helpers.assert_eq(1, #found, "the same id in two roots is one extension, not two")
		helpers.assert_eq(2, #found[1].toml_files,
			"and the user's copy wins — the same overlay rule the hotstring packs follow")
	end)

	helpers.it("returns nothing rather than failing when the roots do not exist", function()
		local found = Extensions.scan({ "/nowhere" }, fake_fs({}, {}))
		helpers.assert_eq(0, #found, "no extensions installed is the normal state, not an error")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 3/ Namespacing the category key ==========
-- ==================================================
-- ==================================================

helpers.describe("extensions: a pack's category is namespaced by its extension", function()

	helpers.it("two extensions shipping the same file stem get distinct keys", function()
		local a = Extensions.category_key("acme", "rolls")
		local b = Extensions.category_key("other", "rolls")
		helpers.assert_true(a ~= b,
			"identical keys would make one extension silently replace the other's pack")
	end)

	helpers.it("an extension pack never collides with a bundled category", function()
		-- "rolls" is a real bundled category. An extension shipping rolls.toml must
		-- not be able to take its place: the user would lose a shipped category to a
		-- third-party file with no indication that it happened.
		helpers.assert_true(Extensions.category_key("acme", "rolls") ~= "rolls",
			"the namespaced key must differ from the bare stem")
	end)

	helpers.it("round-trips back to its parts", function()
		local id, stem = Extensions.parse_category_key(Extensions.category_key("acme", "my-pack"))
		helpers.assert_eq("acme", id, "the menu groups by extension id, so it must be recoverable")
		helpers.assert_eq("my-pack", stem, "and the stem identifies the pack within it")
	end)

	helpers.it("reports a bundled category as not belonging to any extension", function()
		helpers.assert_eq(nil, (Extensions.parse_category_key("rolls")),
			"this is the test the menu uses to keep extension packs out of the personal section")
	end)

end)
