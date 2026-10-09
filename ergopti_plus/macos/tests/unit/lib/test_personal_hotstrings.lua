--- tests/unit/lib/test_personal_hotstrings.lua

--- ==============================================================================
--- MODULE: infra/personal_hotstrings load contract
--- DESCRIPTION:
--- The personal hotstrings loader was extracted from init.lua Section 5.1 into
--- infra/personal_hotstrings. The Lua suite never loads init.lua, so without this
--- test a missing require, a renamed dep, or a regression in the load order would
--- only surface as a boot failure on the maintainer's Mac. This exercises M.load
--- under stubbed keymap/config_paths/hotstring_editor/fs_dir and asserts (1) the
--- personal group is registered FIRST (lowest group_order = highest priority),
--- (2) extension groups follow in alphabetical-by-stem order, (3) the top-level
--- personal_hotstrings.toml is never re-registered as an extension, and (4) the
--- returned list mirrors exactly what was handed to keymap.load_toml.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Save the real heavy deps so other suite files still get the genuine modules.
local SAVED = {}
local function mock(name, mod)
	SAVED[name] = { value = package.loaded[name] }
	package.loaded[name] = mod
end
local function restore_all()
	for name, prev in pairs(SAVED) do package.loaded[name] = prev.value end
	SAVED = {}
	package.loaded["infra.personal_hotstrings"] = nil
end

--- Supplies explicit physical/source observations for these discovery-only doubles.
--- Real hardlinks and stale bytes are exercised by the separate native-owner suite.
local function mock_source_observations()
	mock("infra.personal_file_adoption", nil)
	mock("adapters.file_system", {
		path_status = function(path)
			local inode = 0
			for index = 1, #path do inode = inode + path:byte(index) * index end
			local attributes = hs.fs.attributes(path)
			return "present", { mode = attributes and attributes.mode or "file", dev = 1, ino = inode }
		end,
		read_with_status = function() return "[probe]\nentry = \"source\"\n", "ok" end,
	})
end

helpers.describe("infra/personal_hotstrings — load contract", function()
	helpers.it("registers personal first, then extensions in stem order, skipping the canonical file", function()
		mock_source_observations()
		-- Record every keymap.load_toml call so we can assert order independently of
		-- the returned list (the two must agree).
		local registered = {}
		mock("modules.keymap", {
			-- The real module exports this constant and infra/personal_hotstrings reads
			-- it, so a stub without it hands nil to load_toml and the group silently
			-- registers under no name. A stub must model the real API it stands in for.
			PERSONAL_GROUP_NAME = "personal",
			load_toml = function(name, path, sections, source)
				registered[#registered + 1] = { name = name, path = path, sections = sections, source = source }
				return true
			end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("infra.config_paths", {
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
			"personal,personal-file:616c7068612e746f6d6c,personal-file:7a656272612e746f6d6c",
			"personal must load first, extensions in alphabetical-by-stem order")

		helpers.assert_nil(registered[1].source, "the canonical personal file retains its existing owner")
		helpers.assert_eq(registered[2].source.id, "personal-file:616c7068612e746f6d6c")
		helpers.assert_eq(registered[3].source.id, "personal-file:7a656272612e746f6d6c")
		helpers.assert_eq(loaded[2].personal_source.id, registered[2].source.id)
		registered[2].source.components[1] = "mutated.toml"
		helpers.assert_eq(loaded[2].personal_source.components[1], "alpha.toml", "discovery and registry own different snapshots")

		-- The returned list must mirror exactly what reached keymap.load_toml.
		helpers.assert_eq(#registered, #loaded, "every returned group must have been registered with keymap")
		for i, g in ipairs(loaded) do
			helpers.assert_eq(registered[i].name, g.name, "registration order must match returned order")
			helpers.assert_eq(registered[i].path, g.path, "registration path must match returned path")
		end
	end)

	helpers.it("terminates on a self-referential directory cycle instead of recursing forever (F-LOW-4)", function()
		mock_source_observations()
		-- Simulate a self-referential symlink: every directory named "loop"
		-- contains one entry, also named "loop", that resolves to a directory
		-- again — the exact shape hs.fs.attributes/fs_dir.entries cannot tell
		-- apart from a real filesystem symlink loop. Before the depth guard,
		-- M.load would recurse until Lua's C-stack limit aborted the process.
		mock("modules.keymap", {
			PERSONAL_GROUP_NAME = "personal",
			load_toml = function(_, _) return true end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("infra.config_paths", {
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

		-- Termination is the subject, so the pcall stays. What it was missing is that
		-- the walk RETURNED something usable: a load that terminated by giving up
		-- silently would satisfy the old assertion and register no hotstrings.
		helpers.assert_true(ok, "load() must terminate and not throw/hang on a directory cycle: " .. tostring(err))
		helpers.assert_true(err == nil or type(err) == "table" or type(err) == "number",
			"and must answer a result, not a half-value: " .. tostring(err))
	end)

	helpers.it("warns and refuses ambiguous stored flat/nested owners without overwriting either source (F-LOW-5)", function()
		mock_source_observations()
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
			load_toml = function(_, _) return true end,
			source_priority = function(_) return nil end,
		})
		mock("ui.hotstring_editor", { init = function() end })
		mock("infra.config_paths", {
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
		local ok, loaded = pcall(PH.load, { bundled_hotstrings_dir = "/fake/bundle/",
			saved_preferences = { hotstrings = { personal_ext_a__b = true } } })

		Logger.warn = orig_warn
		hs.fs.attributes, hs.json = prev_attr, prev_json
		restore_all()

		helpers.assert_true(ok, "load() must not throw on a group-name collision: " .. tostring(loaded))
		helpers.assert_true(loaded == nil or type(loaded) == "table" or type(loaded) == "number",
			"and must still answer a result for the files it did load: " .. tostring(loaded))

		local collision_warned = false
		for _, w in ipairs(warnings) do
			if w:find("collision", 1, true) and w:find("personal_ext_a__b", 1, true) then
				collision_warned = true
			end
		end
		helpers.assert_eq(#loaded, 3, "descriptor transport does not silently discard either legacy collision source")
		local identities = {}
		for _, record in ipairs(loaded) do
			if record.personal_source then
				identities[record.personal_source.id] = record.name
				helpers.assert_eq(record.admitted, false, "an ambiguous stored legacy gate grants neither canonical source")
			end
		end
		helpers.assert_eq(identities["personal-file:615f5f622e746f6d6c"], "personal-file:615f5f622e746f6d6c")
		helpers.assert_eq(identities["personal-file:61:622e746f6d6c"], "personal-file:61:622e746f6d6c")
		helpers.assert_true(collision_warned,
			"a Logger.warn must fire naming the colliding group 'personal_ext_a__b' (got: "
				.. table.concat(warnings, " | ") .. ")")
	end)
end)


helpers.describe("personal-file descriptors: independent cross-driver corpus", function()
	helpers.it("preserves exact relative components without borrowing mutable arrays", function()
		local PersonalFiles = require("hotstrings.personal_files")
		local handle = assert(io.open(helpers.shared("tests/corpus/hotstrings/personal_file_descriptors.json"), "r"))
		local content = assert(handle:read("*a")); assert(handle:close())
		local corpus = assert(require("json").decode(content))
		helpers.assert_eq(#corpus.vectors, 13, "the independent corpus must not become vacuous")
		local identities = {}
		for _, vector in ipairs(corpus.vectors) do
			local descriptor = PersonalFiles.describe(vector.components)
			helpers.assert_eq(descriptor.id, vector.id, vector.name)
			helpers.assert_eq(descriptor.label, vector.label, vector.name)
			helpers.assert_eq(PersonalFiles.components(vector.id), vector.components, vector.name)
			helpers.assert_nil(identities[descriptor.id], "each admitted filename has a distinct identity")
			identities[descriptor.id] = true
			helpers.assert_true(not descriptor.id:find(".", 1, true), "the id remains one TOML path segment")
			local copied = PersonalFiles.copy(descriptor)
			descriptor.components[1] = "mutated.toml"
			helpers.assert_eq(copied.components, vector.components, "each consumer owns its components")
			helpers.assert_true(PersonalFiles.is_descriptor(copied))
			helpers.assert_eq(PersonalFiles.is_descriptor(descriptor), false, "forged components refuse")
			copied.label = "forged"
			helpers.assert_eq(PersonalFiles.is_descriptor(copied), false, "forged display labels refuse")
		end
		for _, components in ipairs(corpus.invalid_components) do
			local accepted = pcall(PersonalFiles.describe, components)
			helpers.assert_eq(accepted, false, "malformed relative components refuse")
		end
		for _, identity in ipairs(corpus.invalid_ids) do
			helpers.assert_nil(PersonalFiles.components(identity), "noncanonical identities refuse: " .. identity)
		end
		for _, components in ipairs({ { "a.toml", extra = true }, { [1] = "a", [3] = "b.toml" },
			{ string.char(0xED, 0xA0, 0x80) .. ".toml" } }) do
			local admitted, refusal = pcall(PersonalFiles.describe, components)
			helpers.assert_eq(admitted, false, "shape and Unicode refuse")
			helpers.assert_true(type(refusal) == "string" and refusal:find("invalid personal-file", 1, true) ~= nil)
		end
		local extra = PersonalFiles.describe({ "a.toml" }); extra.future = true
		helpers.assert_eq(PersonalFiles.is_descriptor(extra), false, "unknown descriptor fields refuse")
	end)
end)
