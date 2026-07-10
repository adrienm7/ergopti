--- tests/unit/meta/test_corpus_locale_resolution.lua

--- ==============================================================================
--- MODULE: Locale Resolution Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver locale resolution corpus from
--- _shared/tests/corpus/locale/resolution_vectors.json and replays each
--- vector through the shared locale.core module (initialised with mock
--- JSON data and path resolver), then asserts the resolved string matches
--- the expected golden value.
---
--- This pins the Lua locale.core cascade (active→en→fr) and ★ substitution
--- against the same golden vectors as the AHK driver's t() function, so any
--- divergence between the two implementations is caught immediately.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading =====================
-- ===============================================
-- ===============================================

local corpus_path = helpers.shared("tests/corpus/locale/resolution_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result)
	end
	return result, nil
end

local corpus_root, corpus_err = read_corpus()




-- ===============================================
-- ===============================================
-- ======= 2/ Mock Setup =========================
-- ===============================================
-- ===============================================

--- Creates a mock json_decode that returns data from a supplied locales table.
--- @param locales table { [code] = { key = value, ... }, ... }
--- @return function
local function make_json_decode(locales)
	return function(_raw)
		-- The shared module calls json_decode on raw file content; we return
		-- the correct locale data based on which path was resolved (tracked
		-- via a side-channel in resolve_locale_path).
		return locales.__last_resolved or {}
	end
end

--- Creates a mock resolve_locale_path that records the requested code so
--- json_decode can return the right data.
--- @param locales table { [code] = { key = value, ... }, ... }
--- @return function
local function make_path_resolver(locales)
	return function(code)
		if locales[code] then
			locales.__last_resolved = locales[code]
			return "/mock/locales/" .. code .. ".json"
		end
		locales.__last_resolved = nil
		return ""
	end
end

--- Initialises the shared locale.core with mock data for a vector.
--- @param vec table Corpus vector.
local function init_locale_with_vector(vec)
	-- Reload the module fresh for each vector
	package.loaded["locale.core"] = nil
	local Core = require("locale.core")

	-- Deep-copy the locales table so each vector gets a clean __last_resolved
	local locales = {}
	for code, data in pairs(vec.locales) do
		locales[code] = {}
		for k, v in pairs(data) do
			locales[code][k] = v
		end
	end

	Core.init({
		json_decode = make_json_decode(locales),
		resolve_locale_path = make_path_resolver(locales),
		read_file = function() return "" end,
	})

	-- Set the active locale
	Core.set_locale(vec.active_locale)

	-- Set the trigger provider if specified
	if vec.trigger ~= nil then
		Core.set_trigger_provider(function() return vec.trigger end)
	else
		Core.set_trigger_provider(function() return nil end)
	end

	return Core
end




-- ===============================================
-- ===============================================
-- ======= 3/ Corpus Integrity ===================
-- ===============================================
-- ===============================================

helpers.describe("locale resolution corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus_root ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus_root) == "table",
			"corpus root must be a table")
		helpers.assert_true(type(corpus_root.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus_root.vectors > 0,
			"corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, active_locale, locales, key, expected", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(type(v.active_locale) == "string",
				"vector '" .. tostring(v.id) .. "' missing active_locale")
			helpers.assert_true(type(v.locales) == "table",
				"vector '" .. tostring(v.id) .. "' missing locales table")
			helpers.assert_true(type(v.key) == "string",
				"vector '" .. tostring(v.id) .. "' missing key")
			helpers.assert_true(v.expected ~= nil or v.expected_lua ~= nil,
				"vector '" .. tostring(v.id) .. "' missing expected or expected_lua")
		end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 4/ Vector Execution ===================
-- ===============================================
-- ===============================================

helpers.describe("locale resolution corpus — vector replay", function()
	if not corpus_root then return end

	for _, vec in ipairs(corpus_root.vectors) do
		local expected = vec.expected_lua or vec.expected
		helpers.it("locale: " .. vec.id, function()
			local Core = init_locale_with_vector(vec)
			local result = Core.get(vec.key)
			helpers.assert_eq(result, expected,
				vec.id .. ": expected '" .. tostring(expected) .. "' got '" .. tostring(result) .. "'")
		end)
	end
end)




-- ===============================================
-- ===============================================
-- ======= 5/ Additional Regression Tests ========
-- ===============================================
-- ===============================================

helpers.describe("locale resolution — additional regression edges", function()
	helpers.it("set_locale switches active locale and clears cache", function()
		-- Use a fresh init
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "FR" }, en = { ["menu.a"] = "EN" } }
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_trigger_provider(function() return nil end)

		Core.set_locale("fr")
		helpers.assert_eq(Core.get("menu.a"), "FR", "fr locale")

		Core.set_locale("en")
		helpers.assert_eq(Core.get("menu.a"), "EN", "en locale after switch")
	end)

	helpers.it("set_locale rejects empty code", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "FR" } }
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_trigger_provider(function() return nil end)
		Core.set_locale("fr")
		Core.set_locale("")  -- must be a no-op
		helpers.assert_eq(Core.get("menu.a"), "FR", "locale unchanged after empty set_locale")
	end)

	helpers.it("get returns empty string before init", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		helpers.assert_eq(Core.get("any.key"), "", "uninitialised get returns empty string")
	end)

	helpers.it("is_initialised returns false before init, true after", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		helpers.assert_true(not Core.is_initialised(), "not initialised before init")
		local loc = {}
		Core.init({
			json_decode = function() return {} end,
			resolve_locale_path = function() return "" end,
			read_file = function() return "" end,
		})
		helpers.assert_true(Core.is_initialised(), "initialised after init")
	end)

	helpers.it("duplicate init is a no-op (idempotent)", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "first" } }
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		helpers.assert_eq(Core.get("menu.a"), "first", "first init active")

		-- Second init with different data should be ignored
		local loc2 = { fr = { ["menu.a"] = "second" } }
		Core.init({
			json_decode = make_json_decode(loc2),
			resolve_locale_path = make_path_resolver(loc2),
			read_file = function() return "" end,
		})
		helpers.assert_eq(Core.get("menu.a"), "first", "second init ignored")
	end)

	helpers.it("trigger provider that returns non-string (nil) leaves ★ unchanged", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["star"] = "★ test" } }
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		helpers.assert_eq(Core.get("star"), "★ test", "★ unchanged when trigger is nil")
	end)

	helpers.it("trigger provider that returns empty string leaves ★ unchanged", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["star"] = "★ test" } }
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return "" end)
		helpers.assert_eq(Core.get("star"), "★ test", "★ unchanged when trigger is empty string")
	end)

	helpers.it("key with non-string value in locale table is treated as missing", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = {
			fr = { ["menu.num"] = 42 },
			en = { ["menu.num"] = "forty-two" },
		}
		Core.init({
			json_decode = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		-- 42 is not a string, so it falls through to en
		helpers.assert_eq(Core.get("menu.num"), "forty-two", "non-string value treated as missing")
	end)
end)
