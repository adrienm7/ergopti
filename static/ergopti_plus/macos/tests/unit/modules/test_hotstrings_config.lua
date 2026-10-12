--- tests/unit/modules/test_hotstrings_config.lua

--- ==============================================================================
--- MODULE: hotstrings_config Priority Unit Tests
--- DESCRIPTION:
--- The delays/colors window edits per-section/file collision priority through
--- modules.hotstrings_config, persisting to the shared `hotstrings_config.toml`
--- override file that BOTH drivers read. These tests pin that priority is an
--- accepted override field, serialises as a BARE INTEGER, round-trips through
--- serialize -> parse, participates in built-in and extension resolution, is
--- reported by get_user_override, and is cleared cleanly.
--- ==============================================================================

local helpers = require("tests.helpers")

-- hotstrings_config logs through lib.logger; load it first under the stub.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

--- Build a unique writable temp path (the module itself creates the file).
--- @param name string A short discriminator so concurrent cases never collide.
--- @return string The absolute path to a (not-yet-created) override file.
local function temp_path(name)
	local base = helpers.temp_dir()
	return base .. "/hcfg_" .. name .. "_" .. tostring(os.time()) .. ".toml"
end

--- Reload the module so its module-level `_state` resets, then init it against a
--- fresh override file with a no-op TOML resolver (no package defaults).
--- @param path string The override file path.
--- @return table The freshly-initialised module.
--- @param toml_resolver function|nil Category to TOML path; none by default.
local function fresh_module(path, toml_resolver)
	package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = path, toml_resolver = toml_resolver or function() return nil end })
	return mod
end

--- Writes one exact UTF-8 fixture.
--- @param path string Destination path.
--- @param content string Complete file content.
local function write_fixture(path, content)
	local fh = assert(io.open(path, "w"))
	assert(fh:write(content))
	assert(fh:close())
end

helpers.describe("hotstrings_config: common section migration ownership", function()
	helpers.it("(common-autocorrection-split) native initialization publishes the complete fan-out before resolving each new section", function()
		local path = temp_path("common_fanout")
		local function read(path)
			local handle = assert(io.open(path, "rb")); local bytes = assert(handle:read("*a")); assert(handle:close())
			return bytes
		end
		local input = read(helpers.shared("tests/corpus/common_autocorrection_migration/input.toml"))
		local expected = read(helpers.shared("tests/corpus/common_autocorrection_migration/expected.toml"))
		write_fixture(path, input)
		local ok, detail = pcall(function()
			local mod = fresh_module(path)
			helpers.assert_eq(read(path), expected)
			for _, section in ipairs({ "names", "abbreviations", "technical_terms" }) do
				local actual = mod.get_user_override("autocorrection", section)
				helpers.assert_eq(actual.delay, section == "names" and 0.2 or 0.875)
				helpers.assert_eq(actual.color, section == "abbreviations" and "#abcdef" or "#123456")
				helpers.assert_eq(actual.show_tooltip, section == "names")
				helpers.assert_eq(actual.priority, 23)
				local resolved = mod.resolve("autocorrection", section)
				helpers.assert_eq(resolved.delay, actual.delay)
				helpers.assert_eq(resolved.priority, 23)
			end
		end)
		os.remove(path)
		if not ok then error(detail) end
	end)
		helpers.it("(common-autocorrection-split) refused native migration blocks saves and retains the entire legacy source", function()
		local path = temp_path("common_refused")
		local input = '[autocorrection.caps]\ndelay = 0.3\n# independent original notes\n'
		write_fixture(path, input)
		local original = require("toml_codec.writer").publish_if_unchanged
		local ok, detail = pcall(function()
			require("toml_codec.writer").publish_if_unchanged = function() return false, "independent refusal" end
			local mod = fresh_module(path)
			helpers.assert_eq(mod.set_override("autocorrection", "names", "delay", 0.4), false)
			local handle = assert(io.open(path, "rb")); local bytes = handle:read("*a"); assert(handle:close())
			helpers.assert_eq(bytes, input)
			helpers.assert_nil(mod.get_user_override("autocorrection", "names"), "unacknowledged candidates never become live")
		end)
		require("toml_codec.writer").publish_if_unchanged = original; os.remove(path)
		if not ok then error(detail) end
	end)
		helpers.it("(common-autocorrection-split) unverified foreign bytes retain their native owner while requested common registration refuses", function()
		local path = temp_path("common_foreign_guard")
		local source = '[__global__]\nword_delimiters = "bad\\q"\n[rolls]\ndelay = 0.5\n'
		write_fixture(path, source)
		local ok, detail = pcall(function()
			local mod = fresh_module(path)
			helpers.assert_eq(mod.common_autocorrection_admitted(), false)
			helpers.with_stub_scope({
				"modules.keymap.registry", "modules.keymap.registry_groups", "modules.keymap.registry_index",
				"modules.keymap.state", "modules.keymap.terminators", "adapters.storage", "infra.toml.reader",
			}, function()
				local State = helpers.load_with_stubs("modules.keymap.state")
				local Registry = helpers.load_with_stubs("modules.keymap.registry")
				local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
				helpers.assert_true(Registry.init(state))
				Registry.set_group_context("foreign_guard")
				Registry.add("foreign", "Preserved foreign", { is_word = true, is_case_sensitive = true, priority = 50 })
				Registry.set_group_context(nil)
				local before, sequence = { state.mappings[1] }, state.seq_counter
				helpers.assert_true(require("adapters.storage").set("hotstrings_section_autocorrection_names", true))
				helpers.assert_eq(Registry.load_toml("autocorrection", helpers.shared("modules/hotstrings/autocorrection.toml")), false)
				helpers.assert_eq(state.mappings, before, "the actual native transaction keeps every previous mapping")
				helpers.assert_eq(state.seq_counter, sequence)
				local Boot = require("infra.common_hotstrings_boot")
				local hotfiles, hotfile_paths = {}, {}
				local refused = Boot.load(Registry, "autocorrection",
					helpers.shared("modules/hotstrings/autocorrection.toml"), nil, hotfiles, hotfile_paths)
				helpers.assert_eq(refused, { committed = false, complete = false, unavailable = { "autocorrection" } })
				helpers.assert_eq(hotfiles, {}, "cold startup never advertises a refused common group")
				helpers.assert_nil(hotfile_paths.autocorrection)
				helpers.assert_eq(state.mappings, before, "cold refusal also leaves prior unrelated native rows intact")
				helpers.assert_true(require("adapters.storage").set("hotstrings_section_french_autocorrection_names", true))
				local french_path = helpers.shared("modules/hotstrings/french/autocorrection.toml")
				local admitted = Boot.load(Registry, "french_autocorrection", french_path, nil, hotfiles, hotfile_paths)
				helpers.assert_eq(admitted, { committed = true, complete = true, unavailable = {} })
				helpers.assert_eq(hotfiles, { "french_autocorrection" }, "unrelated cold groups still load through the actual registry")
				helpers.assert_eq(hotfile_paths, { french_autocorrection = french_path })
				helpers.assert_true(#state.mappings > #before)
				local found = false
				for _, mapping in ipairs(state.mappings) do
					if mapping.group == "french_autocorrection" and mapping.trigger == "aicha" then
						found = mapping.repl == "Aïcha"
					end
				end
				helpers.assert_true(found, "an independent French rule survives unavailable common families")
			end)
		end)
		os.remove(path)
		if not ok then error(detail) end
	end)
end)




helpers.describe("hotstrings_config: priority override round-trip", function()
	helpers.it("set/clear priority persists as a bare integer and round-trips through disk", function()
		local path = temp_path("rt")
		os.remove(path)
		local mod = fresh_module(path)

		helpers.assert_eq(mod.set_override("rolls", nil, "priority", 25), true, "file-level priority accepted")
		helpers.assert_eq(mod.set_override("rolls", "ct", "priority", 80), true, "section priority accepted")

		-- In-memory introspection used by the window's overridden/reset state.
		helpers.assert_eq(mod.get_user_override("rolls", nil).priority, 25)
		helpers.assert_eq(mod.get_user_override("rolls", "ct").priority, 80)

		-- Re-read from disk: serialize -> parse must preserve both levels.
		mod.reload()
		helpers.assert_eq(mod.get_user_override("rolls", nil).priority, 25, "file-level priority survives a reload")
		helpers.assert_eq(mod.get_user_override("rolls", "ct").priority, 80, "section priority survives a reload")

		-- Priority is a BARE integer in the TOML, never a quoted string.
		local fh = io.open(path, "r")
		local txt = fh:read("*a")
		fh:close()
		helpers.assert_eq(txt:find("priority = 25", 1, true) ~= nil, true, "file-level priority is a bare integer")
		helpers.assert_eq(txt:find("priority = 80", 1, true) ~= nil, true, "section priority is a bare integer")
		helpers.assert_eq(txt:find('priority = "', 1, true) ~= nil, false, "priority is never quoted")

		-- Clearing the field drops it; the entry has no other override, so the
		-- whole entry resolves back to nil.
		mod.clear_override("rolls", nil, "priority")
		local fov = mod.get_user_override("rolls", nil)
		helpers.assert_eq(fov and fov.priority or nil, nil, "cleared file-level priority is gone")
		os.remove(path)
	end)

	helpers.it("clearing all fields (nil field) also clears priority", function()
		local path = temp_path("clrall")
		os.remove(path)
		local mod = fresh_module(path)
		mod.set_override("rolls", "ct", "delay", 0.2)
		mod.set_override("rolls", "ct", "priority", 77)
		mod.clear_override("rolls", "ct", nil)
		local ov = mod.get_user_override("rolls", "ct")
		helpers.assert_eq(ov, nil, "an empty-field clear wipes every field including priority")
		os.remove(path)
	end)

	helpers.it("set_override rejects a field other than delay/color/show_tooltip/priority", function()
		local path = temp_path("bad")
		os.remove(path)
		local mod = fresh_module(path)
		helpers.assert_eq(mod.set_override("rolls", nil, "badfield", 1), false, "unknown field is rejected")
		os.remove(path)
	end)

	helpers.it("resolves extension priority through user, section, file, and source tiers", function()
		local override_path = temp_path("ext_priority_override")
		local extension_path = temp_path("ext_priority_source")
		os.remove(override_path)
		write_fixture(extension_path, table.concat({
			"[_meta]",
			"priority = 41",
			"sections_order = []",
			"",
			"[_meta.sections.sec]",
			"priority = 51",
			"",
		}, "\n"))

		local mod = fresh_module(override_path)
		local from_toml = mod.resolve_ext("demo", extension_path, "sec")
		helpers.assert_eq(from_toml.priority, 51,
			"extension section metadata must outrank file metadata and the package source tier")
		helpers.assert_eq(from_toml.has_override, false,
			"shipped extension metadata is not a user override")

		helpers.assert_eq(mod.set_override("ext.demo", "sec", "priority", 81), true)
		local from_user = mod.resolve_ext("DEMO", extension_path, "SEC")
		helpers.assert_eq(from_user.priority, 81,
			"a user extension-section priority must outrank every TOML tier")
		helpers.assert_eq(from_user.has_override, true,
			"a priority-only extension override must be visible to the settings UI")

		helpers.assert_eq(mod.clear_override("ext.demo", "sec", "priority"), true)
		helpers.assert_eq(mod.resolve_ext("demo", extension_path, nil).priority, 41,
			"without a section, extension file metadata must outrank the package source tier")

		os.remove(override_path)
		os.remove(extension_path)
	end)

	helpers.it("(layout-extension-macos) resolves a registered pack group from its own file and ext owner", function()
		local override_path = temp_path("ext_group_override")
		local extension_path = temp_path("ext_group_source")
		os.remove(override_path)
		write_fixture(extension_path, table.concat({
			"[_meta]",
			'color = "#1e88e5"',
			"show_tooltip = false",
			"sections_order = []",
			"",
		}, "\n"))
		local mod = fresh_module(override_path, function(category)
			return category == "ext:demo:phrases" and extension_path or nil
		end)
		local Logger = require("infra.logger")
		helpers.admit_logger_privacy(Logger)
		local saved, errors = Logger.error, 0
		Logger.error = function() errors = errors + 1 end
		local ok, resolved = pcall(mod.resolve, "ext:demo:phrases", "greetings")
		Logger.error = saved
		helpers.assert_true(ok, tostring(resolved))
		helpers.assert_eq(resolved.color, "#1e88e5", "the preview and WPM colour come from the pack's _meta")
		helpers.assert_eq(resolved.show_tooltip, false)
		helpers.assert_eq(errors, 0, "the typing path must not log an error per candidate")
		helpers.assert_eq(mod.set_override("ext.demo", nil, "color", "#000000"), true)
		helpers.assert_eq(mod.resolve("ext:demo:phrases", nil).color, "#000000",
			"the user's ext.<id> override applies to every file of the pack")
		os.remove(override_path)
		os.remove(extension_path)
	end)
end)





-- ===========================================================
-- ===========================================================
-- ======= 2/ Case-Insensitive Override Identifiers ===========
-- ===========================================================
-- ===========================================================

helpers.describe("hotstrings_config: override identifiers match the shared Windows contract", function()
	helpers.it("folds hand-written category, extension, and section headers before resolution", function()
		local override_path = temp_path("mixed_case_read")
		local extension_path = temp_path("mixed_case_extension")
		write_fixture(override_path, table.concat({
			"[Rolls]",
			"delay = 0.6",
			"",
			"[ext.Demo]",
			"delay = 0.9",
			"",
			"[ext.Demo.Mixed]",
			"delay = 0.8",
			"",
		}, "\n"))
		write_fixture(extension_path, table.concat({
			"[_meta]",
			'description = "mixed-case extension fixture"',
			"delay = 0.2",
			"sections_order = []",
			"",
		}, "\n"))

		local mod = fresh_module(override_path)
		helpers.assert_eq(mod.resolve("ROLLS", nil).delay, 0.6,
			"a hand-written built-in category must resolve case-insensitively")
		helpers.assert_eq(mod.resolve_ext("DEMO", extension_path, nil).delay, 0.9,
			"a hand-written extension header must match the folded extension id")
		helpers.assert_eq(mod.resolve_ext("demo", extension_path, "MIXED").delay, 0.8,
			"extension section identifiers must follow the same folded-key contract")
		helpers.assert_eq(mod.get_user_override("ext.demo", nil).delay, 0.9,
			"UI introspection must observe the same canonical extension entry")

		os.remove(override_path)
		os.remove(extension_path)
	end)

	helpers.it("writes mixed-case API identifiers once under canonical lowercase headers", function()
		local override_path = temp_path("mixed_case_write")
		local extension_path = temp_path("mixed_case_write_extension")
		os.remove(override_path)
		write_fixture(extension_path, table.concat({
			"[_meta]",
			'description = "mixed-case writer fixture"',
			"delay = 0.2",
			"sections_order = []",
			"",
		}, "\n"))

		local mod = fresh_module(override_path)
		helpers.assert_eq(mod.set_override("ext.Demo", "Mixed", "delay", 0.8), true)
		helpers.assert_eq(mod.set_override("ext.Demo", nil, "delay", 0.9), true)
		helpers.assert_eq(mod.set_override("Rolls", nil, "delay", 0.6), true)
		helpers.assert_eq(mod.resolve_ext("demo", extension_path, "mixed").delay, 0.8)
		helpers.assert_eq(mod.resolve("ROLLS", nil).delay, 0.6)
		helpers.assert_eq(mod.get_user_override("ext.DEMO", nil).delay, 0.9)

		local fh = assert(io.open(override_path, "r"))
		local content = assert(fh:read("*a"))
		assert(fh:close())
		helpers.assert_contains(content, "[ext.demo]\n",
			"the file-level writer must emit the canonical extension key")
		helpers.assert_contains(content, "[ext.demo.mixed]\n",
			"the section writer must emit the canonical extension and section keys")
		helpers.assert_contains(content, "[rolls]\n",
			"built-in categories must use the same canonical lowercase writer boundary")
		helpers.assert_eq(content:find("Demo", 1, true), nil,
			"raw API casing must never leak back into the shared TOML file")
		helpers.assert_eq(content:find("Rolls", 1, true), nil,
			"raw built-in category casing must never leak into the shared TOML file")

		helpers.assert_eq(mod.clear_override("EXT.DEMO", "MIXED", "delay"), true)
		helpers.assert_eq(mod.resolve_ext("Demo", extension_path, "mixed").delay, 0.9,
			"mixed-case clear calls must remove the canonical section override")
		helpers.assert_nil(mod.get_user_override("ext.demo", "mixed"))

		os.remove(override_path)
		os.remove(extension_path)
	end)
end)





-- ================================================
-- ================================================
-- ======= 3/ Non-Negative Delay Contract =========
-- ================================================
-- ================================================

helpers.describe("hotstrings_config: activation delays are non-negative", function()
	helpers.it("ignores a hand-written negative delay and falls through to the default", function()
		local path = temp_path("negative_read")
		write_fixture(path, table.concat({
			"[rolls]",
			"delay = -0.5",
			"",
		}, "\n"))
		local mod = fresh_module(path)

		local override = mod.get_user_override("rolls", nil)
		helpers.assert_true(override == nil or override.delay == nil,
			"a negative record must be ignored rather than installed as an override")
		local resolved = mod.resolve("rolls", nil)
		helpers.assert_true(type(resolved.delay) == "number" and resolved.delay >= 0,
			"the resolved activation window must remain non-negative")

		os.remove(path)
	end)

	helpers.it("rejects a negative delay setter before publishing or mutating memory", function()
		local path = temp_path("negative_set")
		os.remove(path)
		local mod = fresh_module(path)

		helpers.assert_eq(mod.set_override("rolls", nil, "delay", -0.5), false)
		helpers.assert_nil(mod.get_user_override("rolls", nil),
			"a rejected setter must not leave an in-memory override")
		helpers.assert_nil(io.open(path, "r"),
			"validation must happen before the persistence boundary")
	end)
end)
