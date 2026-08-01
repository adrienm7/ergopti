--- tests/unit/meta/test_corpus_hotstrings_config_resolve.lua

--- ==============================================================================
--- MODULE: Hotstrings Config Resolve Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- _shared/tests/corpus/hotstrings/config_resolve_vectors.json and validates
--- the macOS resolution cascade (modules.hotstrings.hotstrings_config's
--- M.resolve) against it — proving delay/color/show_tooltip precedence
--- (user_section > user_category > toml_section > toml_category) matches the
--- AHK driver bit for bit. Priority and the AHK-only "_global" menu
--- delay tier are intentionally out of this corpus's scope — see the corpus
--- file's own description.
---
--- The AHK half lives in
--- windows/tests/meta/test_corpus_hotstrings_config_resolve.ahk.
--- ==============================================================================

local helpers = require("tests.helpers")

-- hotstrings_config logs through lib.logger; load it first under the stub.
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

local corpus_path = helpers.shared("tests/corpus/hotstrings/config_resolve_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, corpus = pcall(hs.json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(corpus) end
	return corpus, nil
end

local corpus, corpus_err = read_corpus()




-- ========================================
-- ========================================
-- ======= 1/ Fixture helpers =============
-- ========================================
-- ========================================

--- Build a unique writable temp path.
--- @param name string A short discriminator so concurrent cases never collide.
--- @return string
local function temp_path(name)
	local base = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
	return base .. "/hcfg_dl5_" .. name .. "_" .. tostring(os.time()) .. ".toml"
end

--- Writes a `[_meta]` / `[_meta.sections.<name>]` TOML fixture from a vector's
--- toml_category / toml_section tables (either may be nil).
--- @param path string Absolute path to write.
--- @param toml_category table|nil { delay?, color?, show_tooltip? }
--- @param section string|nil
--- @param toml_section table|nil { delay?, color?, show_tooltip? }
local function write_toml_meta(path, toml_category, section, toml_section)
	local lines = { "[_meta]" }
	if toml_category then
		if toml_category.delay ~= nil then table.insert(lines, "delay = " .. tostring(toml_category.delay)) end
		if toml_category.color ~= nil then table.insert(lines, 'color = "' .. toml_category.color .. '"') end
		if toml_category.show_tooltip ~= nil then table.insert(lines, "show_tooltip = " .. tostring(toml_category.show_tooltip)) end
	end
	if section and toml_section then
		table.insert(lines, "")
		table.insert(lines, "[_meta.sections." .. section .. "]")
		if toml_section.delay ~= nil then table.insert(lines, "delay = " .. tostring(toml_section.delay)) end
		if toml_section.color ~= nil then table.insert(lines, 'color = "' .. toml_section.color .. '"') end
		if toml_section.show_tooltip ~= nil then table.insert(lines, "show_tooltip = " .. tostring(toml_section.show_tooltip)) end
	end
	local fh = io.open(path, "w")
	fh:write(table.concat(lines, "\n") .. "\n")
	fh:close()
end

--- Reloads hotstrings_config fresh and initializes it against a fixture built
--- from one corpus vector. Returns the initialized module.
--- @param vector table One entry of the corpus's "vectors" array.
--- @return table mod, string toml_path, string override_path (for cleanup)
local function fresh_module_for_vector(vector)
	local toml_path = temp_path(vector.id .. "_toml")
	local override_path = temp_path(vector.id .. "_ov")
	os.remove(toml_path)
	os.remove(override_path)
	write_toml_meta(toml_path, vector.toml_category, vector.section, vector.toml_section)

	package.loaded["modules.hotstrings.hotstrings_config"] = nil
	local mod = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
	mod.init({ override_path = override_path, toml_resolver = function() return toml_path end })

	local user_category = vector.user_category
	if user_category then
		for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
			if user_category[field] ~= nil then
				mod.set_override(vector.category, nil, field, user_category[field])
			end
		end
	end
	local user_section = vector.user_section
	if user_section and vector.section then
		for _, field in ipairs({ "delay", "color", "show_tooltip" }) do
			if user_section[field] ~= nil then
				mod.set_override(vector.category, vector.section, field, user_section[field])
			end
		end
	end

	return mod, toml_path, override_path
end




-- ============================================
-- ============================================
-- ======= 2/ Corpus integrity ================
-- ============================================
-- ============================================

helpers.describe("hotstrings config resolve corpus (macOS): M.resolve matches every vector", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil, corpus_err or "corpus must parse")
		helpers.assert_true(type(corpus.vectors) == "table" and #corpus.vectors > 0,
			"corpus must contain at least one vector")
	end)




	-- ============================================
	-- ======= 3/ M.resolve parity =================
	-- ============================================

	helpers.it("M.resolve matches every vector's expected cascade result", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			local mod, toml_path, override_path = fresh_module_for_vector(v)
			local result = mod.resolve(v.category, v.section)

			helpers.assert_eq(result.delay, v.expected.delay, "[" .. v.id .. "] delay")
			helpers.assert_eq(result.color, v.expected.color, "[" .. v.id .. "] color")
			helpers.assert_eq(result.show_tooltip, v.expected.show_tooltip, "[" .. v.id .. "] show_tooltip")
			helpers.assert_eq(result.has_override, v.expected.has_override, "[" .. v.id .. "] has_override")

			os.remove(toml_path)
			os.remove(override_path)
		end
	end)
end)
