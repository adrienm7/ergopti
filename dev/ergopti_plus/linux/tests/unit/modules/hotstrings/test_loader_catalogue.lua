--- tests/unit/modules/hotstrings/test_loader_catalogue.lua

--- ==============================================================================
--- MODULE: Hotstring Loader — categories and their metadata
--- DESCRIPTION:
--- What a category IS, and what the menu is told about it, from real TOML files.
---
--- ROOT CAUSE ENCODED:
--- The loader derived a mapping's category from its PARENT DIRECTORY. The five
--- shared packs live flat beside each other in _shared/modules/hotstrings/, and
--- install.sh copies them flat into ~/.config/ergopti/hotstrings/ — so every
--- entry in magickey.toml, autocorrection.toml, rolls.toml, sfbsreduction.toml
--- and distancesreduction.toml reported the same group, literally named after
--- the folder. Nothing could match the manifest's category ids, so the menu
--- rendered "no group loaded" stubs and the one real group fell into the
--- personal bucket by exclusion. The category menu the user saw was wrong, not
--- merely unlocalised, and no test exercised it against the real layout.
---
--- The second half is what was thrown away. [_meta] carries a description in 21
--- locales, the section order, the delay and the tooltip colour; the loader
--- dropped all of it, so a menu could only ever show a raw file stem.
---
--- Driven against the SHIPPED files rather than fixtures. A fixture proves the
--- parser reads a shape somebody invented; these five files are the shape that
--- actually ships, and the defect was precisely that nothing read them the way
--- they are laid out on disk.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The absolute path of a shared hotstring pack.
--- @param name string File name.
--- @return string
local function pack(name)
	local Paths = require("infra.paths")
	return Paths.shared("modules/hotstrings/" .. name)
end

--- Loads the catalogue for a set of shared packs.
--- @param names table File names.
--- @return table catalogue
local function catalogue_of(names)
	local loader = helpers.load_module("modules.hotstrings.loader")
	local paths = {}
	for _, name in ipairs(names) do paths[#paths + 1] = pack(name) end
	return loader.load_catalogue(paths)
end





-- =================================================================
-- =================================================================
-- ======= 1/ A category is a file, not a folder ===================
-- =================================================================
-- =================================================================

helpers.describe("loader: the category is the file stem", function()

	helpers.it("keeps the shared packs apart", function()
		local cat = catalogue_of({ "rolls.toml", "sfbsreduction.toml" })
		helpers.assert_true(cat.categories.rolls ~= nil,
			"rolls.toml is the category 'rolls'")
		helpers.assert_true(cat.categories.sfbsreduction ~= nil,
			"and sfbsreduction.toml is its own category")
		helpers.assert_true(cat.categories.hotstrings == nil,
			"the folder they share must not become a category — that collapse is what "
				.. "made every pack report the same group")
	end)

	helpers.it("stamps the category onto every mapping", function()
		local cat = catalogue_of({ "rolls.toml" })
		helpers.assert_true(#cat.mappings > 0, "the pack has entries")
		for _, m in ipairs(cat.mappings) do
			helpers.assert_eq(m.group, "rolls",
				"a mapping's group is the pack it came from; the menu gates entries by it")
		end
	end)

	helpers.it("records which section an entry came from", function()
		local cat = catalogue_of({ "rolls.toml" })
		local with_section = 0
		for _, m in ipairs(cat.mappings) do
			if type(m.section) == "string" and m.section ~= "" then
				with_section = with_section + 1
			end
		end
		helpers.assert_eq(with_section, #cat.mappings,
			"per-section toggles and per-section counts both need it, and it was not "
				.. "on the mapping at all")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ The metadata the menu renders ========================
-- =================================================================
-- =================================================================

helpers.describe("loader: category metadata", function()

	helpers.it("carries the localised description, not just the stem", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_eq(rolls.description.fr, "Roulements",
			"the French name is in the TOML and was being discarded")
		helpers.assert_eq(rolls.description.en, "Rolls", "and the English one")
		local locales = 0
		for _ in pairs(rolls.description) do locales = locales + 1 end
		helpers.assert_true(locales >= 20,
			"the packs are translated into every locale this project ships; got " .. locales)
	end)

	helpers.it("carries the section order the file declares", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_true(#rolls.sections_order >= 5,
			"the order is data: it groups related rolls together, and sorting the "
				.. "sections alphabetically instead would scatter them")
		helpers.assert_eq(rolls.sections_order[1], "hc", "and it starts where the file says")
		for _, name in ipairs(rolls.sections_order) do
			helpers.assert_true(name ~= "-",
				"the separators the menu draws itself must not arrive as section names")
		end
	end)

	helpers.it("carries the delay and the tooltip setting", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_eq(rolls.delay, 0.5,
			"rolls fire fast on purpose; the resolver's category rung reads this")
		helpers.assert_eq(rolls.show_tooltip, false,
			"and they deliberately show no preview — a value of nil would read as "
				.. "'not configured' and turn the preview back on")
	end)

	helpers.it("counts the entries, per section and in total", function()
		local rolls = catalogue_of({ "rolls.toml" }).categories.rolls
		helpers.assert_true(rolls.count > 0, "the category total the menu shows")
		local summed = 0
		for _, section in pairs(rolls.sections) do summed = summed + section.count end
		helpers.assert_eq(summed, rolls.count,
			"the per-section counts must add up to the total, or one of the two is "
				.. "counting something the other is not")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 3/ What is not a category ===============================
-- =================================================================
-- =================================================================

helpers.describe("loader: the scan skips what is not a pack", function()

	helpers.it("rejects the files in that directory that are not categories", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		-- Asserted on the predicate rather than on the scan around it. The scan
		-- shells out to POSIX `find`, which does not exist on the interpreter this
		-- repo is developed on, so a case driving it would only ever run in CI —
		-- and this rule is exactly the kind quietly dropped in a rewrite.
		helpers.assert_eq(loader.is_pack_file("/x/_index.toml"), false,
			"_index.toml is the menu index for the directory; loading it as a "
				.. "category produced a group called '_index' with no entries")
		helpers.assert_eq(loader.is_pack_file("/x/defaults.toml"), false,
			"defaults.toml holds the resolver's fallback delays and colours, not hotstrings")
	end)

	helpers.it("accepts every pack the index declares", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		for _, name in ipairs({
			"distancesreduction", "sfbsreduction", "rolls", "autocorrection", "magickey",
		}) do
			helpers.assert_eq(loader.is_pack_file("/x/" .. name .. ".toml"), true,
				"_index.toml lists '" .. name .. "' in categories_order, so a filter "
					.. "that excluded it would leave a menu entry with nothing behind it")
		end
	end)

	helpers.it("rejects anything that is not a TOML file at all", function()
		local loader = helpers.load_module("modules.hotstrings.loader")
		helpers.assert_eq(loader.is_pack_file("/x/README.md"), false, "not a pack")
		helpers.assert_eq(loader.is_pack_file(""), false, "nor is an empty path")
		helpers.assert_eq(loader.is_pack_file(nil), false, "nor a missing one")
	end)

end)
