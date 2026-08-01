--- tests/unit/lib/test_personal_hotstrings.lua

--- ==============================================================================
--- MODULE: infra/personal_hotstrings load contract
--- DESCRIPTION:
--- The personal hotstrings loader was extracted from init.lua Section 5.1 into
--- infra/personal_hotstrings. The Lua suite never loads init.lua, so without this
--- test a missing require, a renamed dep, or a regression in the load order would
--- only surface as a boot failure on the maintainer's Mac. This exercises M.load
--- under stubbed keymap/menu_paths/hotstring_editor/fs_dir and asserts (1) the
--- personal group is registered FIRST (lowest group_order = highest priority),
--- (2) extension groups follow in alphabetical-by-stem order, (3) the top-level
--- personal_hotstrings.toml is never re-registered as an extension, and (4) the
--- returned list mirrors exactly what was handed to keymap.load_toml.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Save the real heavy deps so other suite files still get the genuine modules.
local SAVED = {}
local function mock(name, mod)
	SAVED[name] = package.loaded[name]
	package.loaded[name] = mod
end
local function restore_all()
	for name, prev in pairs(SAVED) do package.loaded[name] = prev end
	package.loaded["infra.personal_hotstrings"] = nil
end

helpers.describe("infra/personal_hotstrings — load contract", function()
	helpers.it("registers personal first, then extensions in stem order, skipping the canonical file", function()
		-- Record every keymap.load_toml call so we can assert order independently of
		-- the returned list (the two must agree).
		local registered = {}
		mock("modules.keymap", {
			-- The real module exports this constant and infra/personal_hotstrings reads
			-- it, so a stub without it hands nil to load_toml and the group silently
			-- registers under no name. A stub must model the real API it stands in for.
			PERSONAL_GROUP_NAME = "personal",
			load_toml = function(name, path) table.insert(registered, { name = name, path = path }) end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("ui.menu.menu_paths", {
			get = function(key)
				if key == "PersonalTomlPath" then return "/fake/hot/personal_hotstrings.toml" end
				if key == "PersonalHotstringsDir" then return "/fake/hot/" end
				return nil
			end,
		})
		-- A flat dir: one canonical file (must be skipped at prefix=="") + two
		-- extension TOMLs returned out of order to prove the loader sorts them.
		mock("infra.fs_dir", {
			entries = function(dir)
				if dir == "/fake/hot" then
					return { "zebra.toml", "alpha.toml", "personal_hotstrings.toml", "_index.toml" }
				end
				return {}
			end,
		})

		-- Stub the OS surface: the scan dir is a directory, every *.toml is a file.
		local prev_attr, prev_json = hs.fs.attributes, hs.json
		hs.fs.attributes = function(path)
			if path == "/fake/hot" then return { mode = "directory" } end
			if path:match("%.toml$") then return { mode = "file" } end
			return nil
		end
		hs.json = { decode = function(_) return nil end }

		package.loaded["infra.personal_hotstrings"] = nil
		local PH = require("infra.personal_hotstrings")
		local ok, loaded = pcall(PH.load, { bundled_hotstrings_dir = "/fake/bundle/" })

		hs.fs.attributes, hs.json = prev_attr, prev_json
		restore_all()

		helpers.assert_true(ok, "load() must not throw: " .. tostring(loaded))
		helpers.assert_true(type(loaded) == "table", "load() must return a list")

		-- Expected order: personal, then alphabetical stems (alpha before zebra).
		local names = {}
		for _, g in ipairs(loaded) do table.insert(names, g.name) end
		helpers.assert_eq(table.concat(names, ","),
			"personal,personal_ext_alpha,personal_ext_zebra",
			"personal must load first, extensions in alphabetical-by-stem order")

		-- The returned list must mirror exactly what reached keymap.load_toml.
		helpers.assert_eq(#registered, #loaded, "every returned group must have been registered with keymap")
		for i, g in ipairs(loaded) do
			helpers.assert_eq(registered[i].name, g.name, "registration order must match returned order")
			helpers.assert_eq(registered[i].path, g.path, "registration path must match returned path")
		end
	end)

	helpers.it("terminates on a self-referential directory cycle instead of recursing forever (F-LOW-4)", function()
		-- Simulate a self-referential symlink: every directory named "loop"
		-- contains one entry, also named "loop", that resolves to a directory
		-- again — the exact shape hs.fs.attributes/fs_dir.entries cannot tell
		-- apart from a real filesystem symlink loop. Before the depth guard,
		-- M.load would recurse until Lua's C-stack limit aborted the process.
		mock("modules.keymap", {
			PERSONAL_GROUP_NAME = "personal",
			load_toml = function(_, _) end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("ui.menu.menu_paths", {
			get = function(key)
				if key == "PersonalTomlPath" then return "/fake/hot/personal_hotstrings.toml" end
				if key == "PersonalHotstringsDir" then return "/fake/hot/" end
				return nil
			end,
		})
		mock("infra.fs_dir", {
			-- Every directory in this fixture contains exactly one further "loop"
			-- entry that resolves back to a directory — a growing-path cycle.
			entries = function(_dir) return { "loop" } end,
		})

		local prev_attr, prev_json = hs.fs.attributes, hs.json
		hs.fs.attributes = function(_path)
			-- Every path in this fixture is a directory — there is no file to
			-- bottom out on, so only the depth guard can stop the recursion.
			return { mode = "directory" }
		end
		hs.json = { decode = function(_) return nil end }

		package.loaded["infra.personal_hotstrings"] = nil
		local PH = require("infra.personal_hotstrings")
		local ok, err = pcall(PH.load, { bundled_hotstrings_dir = "/fake/bundle/" })

		hs.fs.attributes, hs.json = prev_attr, prev_json
		restore_all()

		helpers.assert_true(ok, "load() must terminate and not throw/hang on a directory cycle: " .. tostring(err))
	end)

	helpers.it("warns instead of silently overwriting on a flat/nested group-name collision (F-LOW-5)", function()
		-- A flat "a__b.toml" and a nested "a/b.toml" both derive the group name
		-- "personal_ext_a__b" — "__" is used both as a literal character allowed
		-- in a stem AND as the path-segment join separator. Before the fix, the
		-- second file loaded silently overwrote the first's registration with no
		-- warning. Fixture: /fake/hot/ contains a__b.toml AND a subdirectory a/
		-- containing b.toml; alphabetical sort processes the flat file "a__b.toml"
		-- before the subdirectory "a", so the SECOND (colliding) load is the
		-- nested one — the warn must fire and the loaded list must still record
		-- something sane rather than throwing.
		mock("modules.keymap", {
			PERSONAL_GROUP_NAME = "personal",
			load_toml = function(_, _) end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("ui.menu.menu_paths", {
			get = function(key)
				if key == "PersonalTomlPath" then return "/fake/hot/personal_hotstrings.toml" end
				if key == "PersonalHotstringsDir" then return "/fake/hot/" end
				return nil
			end,
		})
		mock("infra.fs_dir", {
			entries = function(dir)
				if dir == "/fake/hot" then return { "a__b.toml", "a" } end
				if dir == "/fake/hot/a" then return { "b.toml" } end
				return {}
			end,
		})

		local prev_attr, prev_json = hs.fs.attributes, hs.json
		hs.fs.attributes = function(path)
			if path == "/fake/hot" or path == "/fake/hot/a" then return { mode = "directory" } end
			if path:match("%.toml$") then return { mode = "file" } end
			return nil
		end
		hs.json = { decode = function(_) return nil end }

		-- Capture Logger.warn calls without silencing them (same pattern as
		-- tests/meta/test_healthcheck_api_contract.lua).
		package.loaded["infra.personal_hotstrings"] = nil
		local Logger = require("infra.logger")
		local warnings = {}
		local orig_warn = Logger.warn
		Logger.warn = function(log_obj, fmt, ...)
			warnings[#warnings + 1] = string.format(fmt, ...)
			return orig_warn(log_obj, fmt, ...)
		end

		local PH = require("infra.personal_hotstrings")
		local ok, loaded = pcall(PH.load, { bundled_hotstrings_dir = "/fake/bundle/" })

		Logger.warn = orig_warn
		hs.fs.attributes, hs.json = prev_attr, prev_json
		restore_all()

		helpers.assert_true(ok, "load() must not throw on a group-name collision: " .. tostring(loaded))

		local collision_warned = false
		for _, w in ipairs(warnings) do
			if w:find("collision", 1, true) and w:find("personal_ext_a__b", 1, true) then
				collision_warned = true
			end
		end
		helpers.assert_true(collision_warned,
			"a Logger.warn must fire naming the colliding group 'personal_ext_a__b' (got: "
				.. table.concat(warnings, " | ") .. ")")
	end)
end)
