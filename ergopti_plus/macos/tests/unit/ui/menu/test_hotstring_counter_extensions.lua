--- tests/unit/ui/menu/test_hotstring_counter_extensions.lua

--- ==============================================================================
--- MODULE: Extension Hotstring Counts Tests
--- DESCRIPTION:
--- Extension packs are counted from the boot's discovery catalogue and the
--- sections the keymap registered for them, like every other category: enabled
--- sections only, under their own extension, never inside the common total.
--- The counter used to walk the bundled extensions folder and re-parse each
--- file, which missed installed layouts and the user's folder entirely.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a callback with a fresh counter that must not touch any file.
--- @param callback function Receives the counter module.
local function with_counter(callback)
	return helpers.with_fresh_modules({ "ui.menu.hotstring_counter", "infra.logger", "adapters.file_system",
		"infra.fs_dir" }, function()
		local function unexpected_io() error("Counting must not access files", 0) end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = { read_with_status = unexpected_io }
		package.loaded["infra.fs_dir"] = { try_entries = unexpected_io }
		callback(require("ui.menu.hotstring_counter"))
	end)
end

--- A menu context whose keymap registered the given groups.
--- @param sections table Map of group name to section descriptors.
--- @param disabled table|nil Set of "group" or "group.section" keys that are off.
--- @param packs table Discovery catalogue.
--- @return table ctx
local function context(sections, disabled, packs)
	disabled = disabled or {}
	local hotfiles = {}
	for name in pairs(sections) do hotfiles[#hotfiles + 1] = name end
	table.sort(hotfiles)
	return {
		hotfiles = hotfiles,
		extension_packs = packs,
		keymap = {
			get_sections = function(name) return sections[name] end,
			is_group_enabled = function(name) return not disabled[name] end,
			is_section_enabled = function(name, section) return not disabled[name .. "." .. section] end,
		},
	}
end

local DEMO = {
	id = "demo", name = "Demo Pack",
	toml_files = { { stem = "phrases", path = "/ext/demo/hotstrings/phrases.toml" },
		{ stem = "symbols", path = "/ext/demo/hotstrings/symbols.toml" } },
	bound_files = {},
}

helpers.describe("hotstring counter: extension packs", function()
	helpers.it("(layout-extension-macos) counts enabled pack sections under their extension, not as common", function()
		with_counter(function(counter)
			local ctx = context({
				autocorrection = { { name = "caps", count = 5 } },
				["ext:demo:phrases"] = { { name = "greetings", count = 3 }, { name = "farewells", count = 4 } },
				["ext:demo:symbols"] = { { name = "arrows", count = 2 } },
			}, { ["ext:demo:phrases.farewells"] = true }, { DEMO })
			local counts = counter.count_all(ctx, {})
			helpers.assert_eq(counts.common, 5, "a pack must never inflate the bundled categories")
			helpers.assert_eq(counts.ext, 5)
			helpers.assert_eq(counts.grand, 10)
			helpers.assert_eq(counts.has_ext, true)
			helpers.assert_eq(counts.group_counts["ext:demo:phrases"], 3, "a disabled section is not counted")
			helpers.assert_eq(counts.group_counts["ext:demo:symbols"], 2)
			helpers.assert_eq(counts.ext_details, { {
				id = "demo", name = "Demo Pack", total = 5, groups = { "ext:demo:phrases", "ext:demo:symbols" },
			} })
		end)
	end)

	helpers.it("(layout-extension-macos) a disabled pack contributes nothing, as a bundled category does", function()
		with_counter(function(counter)
			local ctx = context({
				["ext:demo:phrases"] = { { name = "greetings", count = 3 } },
				["ext:demo:symbols"] = { { name = "arrows", count = 2 } },
			}, { ["ext:demo:phrases"] = true, ["ext:demo:symbols"] = true }, { DEMO })
			local counts = counter.count_all(ctx, {})
			helpers.assert_eq(counts.ext, 0)
			helpers.assert_eq(counts.has_ext, false)
			helpers.assert_eq(#counts.ext_details, 1, "an installed extension stays listed while it is off")
		end)
	end)

	helpers.it("(layout-extension-macos) lists no extension for a pack made only of bound geometry files", function()
		with_counter(function(counter)
			local geometry = { id = "ergopti", name = "Ergopti", toml_files = {},
				bound_files = { { stem = "magicrepeat", path = "/ext/ergopti/hotstrings/magicrepeat.toml" } } }
			local counts = counter.count_all(context({}, nil, { geometry }), {})
			helpers.assert_eq(counts.ext_details, {}, "bound files supply bundled categories, not a pack row")
		end)
	end)

	helpers.it("(layout-extension-macos) refuses a malformed catalogue and counts none without one", function()
		with_counter(function(counter)
			local ok, failure = pcall(counter.count_all, context({}, nil, "not a catalogue"), {})
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(failure):find("extension catalogue", 1, true) ~= nil)
			local counts = counter.count_all(context({
				["ext:demo:phrases"] = { { name = "greetings", count = 3 } },
			}, nil, nil), {})
			helpers.assert_eq(counts.ext, 0, "a partial context lists no extension, as one without hotfiles")
			helpers.assert_eq(counts.common, 0, "and still never counts a pack as a bundled category")
		end)
	end)

	helpers.it("(layout-extension-macos) the boot hands the discovered catalogue to the menu", function()
		local source = assert(helpers.read_driver_unit("ExtensionPacks.discover()"))
		local discover = source:find("ExtensionPacks.discover()", 1, true)
		local resolver = source:find("hotstrings_config.init({", 1, true)
		local load = source:find("ExtensionPacks.load(ExtensionPacks.catalogue(), keymap)", 1, true)
		local dynamic = source:find("dynamic_hotstrings.start(base_dir", 1, true)
		local menu = source:find("karabiner, hotfile_paths, ExtensionPacks.catalogue()", 1, true)
		helpers.assert_true(discover ~= nil and resolver ~= nil and discover < resolver,
			"the catalogue must exist before the override resolver can be asked for a pack")
		helpers.assert_true(load ~= nil and dynamic ~= nil and load < dynamic,
			"packs register at the package tier, before the dynamic and bundled groups")
		helpers.assert_true(menu ~= nil, "the menu must list the packs the boot registered")
	end)
end)
