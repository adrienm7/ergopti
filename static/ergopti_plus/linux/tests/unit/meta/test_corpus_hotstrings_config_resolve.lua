--- tests/unit/meta/test_corpus_hotstrings_config_resolve.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Resolve Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/config_resolve_vectors.json against
--- this driver's resolution cascade and requires the same answers the other two
--- give.
---
--- WHY THIS WAS MISSING, AND WHY IT MATTERS MOST HERE:
--- The corpus existed and two drivers consumed it — macOS in
--- tests/unit/meta/test_corpus_hotstrings_config_resolve.lua and Windows in
--- tests/meta/test_corpus_hotstrings_config_resolve.ahk. Linux never did. So the
--- precedence rule (user_section > user_category > toml_section > toml_category)
--- was pinned bit for bit between two drivers and merely asserted on the third,
--- by tests this repository wrote about its own implementation.
---
--- That is the weakest possible position for the one part of this cascade that
--- had no consumer at all until 2026-08-05: hotstrings_config.resolve() was
--- called by nothing in production, so every override the settings window
--- persisted resolved into a value nobody read. Wiring it up and pinning it
--- against the other two drivers are the same job — a resolver that now runs and
--- disagrees with macOS is worse than one that never ran, because the user's
--- delay would take effect and take effect WRONGLY.
---
--- WHAT IS DELIBERATELY OUT OF SCOPE, per the corpus's own description: priority,
--- and the AHK-only "_global" menu delay tier.
--- ==============================================================================

local helpers = require("tests.helpers")

local Json = helpers.load_module("json")

local CORPUS_RELATIVE = "tests/corpus/hotstrings/config_resolve_vectors.json"


--- Reads and decodes the shared corpus.
--- @return table|nil corpus, string|nil error
local function read_corpus()
	local Paths = helpers.load_module("infra.paths")
	local path = Paths.shared and Paths.shared(CORPUS_RELATIVE) or nil
	if not path then return nil, "the shared tree could not be located" end
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open the corpus at " .. path end
	local raw = fh:read("*a")
	fh:close()
	local decoded = Json.decode(raw)
	if type(decoded) ~= "table" then return nil, "the corpus did not parse as JSON" end
	return decoded, nil
end

local corpus, corpus_error = read_corpus()


--- Loads a fresh config module positioned on one vector.
---
--- The metadata is injected rather than discovered. The corpus is about the
--- PRECEDENCE cascade; routing it through load_all() would make it depend on
--- `find`, which is Windows' find.exe on a developer's machine and answers with
--- silence — every vector would then resolve to the global default and report a
--- divergence from macOS that does not exist. The TOML parse is covered by
--- test_loader_catalogue.lua, which is where that belongs.
--- @param vector table
--- @return table module
local function module_for(vector)
	local mod = helpers.load_module("modules.hotstrings.hotstrings_config")
	mod.init({ load_mappings = function() end }, nil)

	-- The shape the loader produces: the category's own values at the top level,
	-- its sections under `sections`, keyed by name.
	local category = {
		id       = vector.category,
		sections = {},
	}
	for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
		if vector.toml_category and vector.toml_category[field] ~= nil then
			category[field] = vector.toml_category[field]
		end
	end
	if vector.section and vector.toml_section then
		local section = {}
		for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
			if vector.toml_section[field] ~= nil then section[field] = vector.toml_section[field] end
		end
		category.sections[vector.section] = section
	end
	mod._set_categories_for_test({ [vector.category] = category })

	-- User overrides on top, in the order the settings window writes them.
	local overrides = {}
	if vector.user_category or vector.user_section then
		local entry = { sections = {} }
		for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
			if vector.user_category and vector.user_category[field] ~= nil then
				entry[field] = vector.user_category[field]
			end
		end
		if vector.section and vector.user_section then
			local section_entry = {}
			for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
				if vector.user_section[field] ~= nil then
					section_entry[field] = vector.user_section[field]
				end
			end
			entry.sections[vector.section] = section_entry
		end
		overrides[vector.category] = entry
	end
	mod._set_overrides_for_test(overrides)

	return mod
end





-- ==================================================
-- ==================================================
-- ======= 1/ The corpus is really read =============
-- ==================================================
-- ==================================================

helpers.describe("hotstrings config resolve corpus (Linux): the corpus loads", function()

	helpers.it("reads and parses the shared vector file", function()
		helpers.assert_true(corpus ~= nil, corpus_error or "the corpus must parse")
		helpers.assert_true(type(corpus) == "table" and type(corpus.vectors) == "table"
			and #corpus.vectors > 0,
			"a corpus with no vectors would make every assertion below vacuously true")
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 2/ Every vector, same answer =============
-- ==================================================
-- ==================================================

helpers.describe("hotstrings config resolve corpus (Linux): resolve matches the other drivers", function()

	helpers.it("every vector resolves to its expected delay, colour and tooltip flag", function()
		if not corpus then return end

		for _, vector in ipairs(corpus.vectors) do
			local mod = module_for(vector)
			local resolved = mod.resolve(vector.category, vector.section)
			local expected = vector.expected or {}
			local where = "vector '" .. tostring(vector.id) .. "'"

			helpers.assert_true(type(resolved) == "table", where .. ": resolve must return a table")

			if expected.delay ~= nil then
				helpers.assert_eq(resolved.delay, expected.delay,
					where .. ": the delay must match what macOS and Windows resolve — "
						.. (vector.description or ""))
			end
			if expected.color ~= nil then
				helpers.assert_eq(resolved.color, expected.color,
					where .. ": the colour must match the other drivers")
			end
			if expected.show_tooltip ~= nil then
				helpers.assert_eq(resolved.show_tooltip, expected.show_tooltip,
					where .. ": the tooltip flag must match the other drivers")
			end

		end
	end)

end)
