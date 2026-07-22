--- tests/unit/meta/test_corpus_locale_resolution.lua

--- ==============================================================================
--- MODULE: Locale Resolution Corpus Consumer (Linux)
--- DESCRIPTION:
--- Loads the cross-driver locale resolution corpus from
--- _shared/tests/corpus/locale/resolution_vectors.json and replays each
--- vector through the shared locale.core module (initialised with mock
--- JSON data and path resolver), then asserts the resolved string matches
--- the expected golden value.
---
--- This is the Linux counterpart of the macOS consumer
--- (test_corpus_locale_resolution.lua). Both pin the locale.core cascade
--- (active→en→fr) and ★ substitution against the same golden vectors.
--- Before this test, the Linux driver's locale resolution was only exercised
--- through the structural corpus check in test_corpus_cross_driver.lua §8
--- (SKIP-marked). Now the shared backbone is actually replayed.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_true = helpers.assert_true
local assert_eq   = helpers.assert_eq

local driver_root = helpers.driver_root()
local shared_root = driver_root .. "/../_shared"

-- Bootstrap: inject _shared/lua/ into package.path before requiring locale.core.
local function shared_lua_path()
	return shared_root .. "/lua"
end

local _shared = shared_lua_path()
local entry = _shared .. "/?.lua"
if not package.path:find(entry, 1, true) then
	package.path = entry .. ";" .. package.path
end




-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading =====================
-- ===============================================
-- ===============================================

local corpus_path = shared_root .. "/tests/corpus/locale/resolution_vectors.json"

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	-- Use the vendored JSON decoder if available
	local ok_j, json_mod = pcall(require, "json")
	if ok_j and json_mod and type(json_mod.decode) == "function" then
		return json_mod.decode(raw)
	end
	return nil, "json.decode not available"
end

local corpus_root, corpus_err = read_corpus()




-- ===============================================
-- ===============================================
-- ======= 2/ Mock Setup =========================
-- ===============================================
-- ===============================================

--- Creates a mock json_decode that returns data from the side-channel.
--- @param locales table { [code] = { key = value, ... }, ... }
--- @return function
local function make_json_decode(locales)
	return function(_raw)
		return locales.__last_resolved or {}
	end
end

--- Creates a mock resolve_locale_path that records the requested code.
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
--- Reloads locale.core fresh for each vector so no state leaks.
--- @param vec table Corpus vector.
local function init_locale_with_vector(vec)
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
		json_decode         = make_json_decode(locales),
		resolve_locale_path = make_path_resolver(locales),
		read_file           = function() return "" end,
	})

	Core.set_locale(vec.active_locale)

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

describe("locale resolution corpus — integrity", function()
	it("corpus file is readable and parseable", function()
		assert_true(corpus_root ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		assert_true(type(corpus_root) == "table",
			"corpus root must be a table")
		assert_true(type(corpus_root.vectors) == "table",
			"corpus.vectors must be a table")
		assert_true(#corpus_root.vectors > 0,
			"corpus must have at least one vector")
	end)

	it("every vector has required fields", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			assert_true(type(v.active_locale) == "string",
				"vector '" .. tostring(v.id) .. "' missing active_locale")
			assert_true(type(v.locales) == "table",
				"vector '" .. tostring(v.id) .. "' missing locales table")
			assert_true(type(v.key) == "string",
				"vector '" .. tostring(v.id) .. "' missing key")
			assert_true(v.expected ~= nil or v.expected_lua ~= nil,
				"vector '" .. tostring(v.id) .. "' missing expected or expected_lua")
		end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 4/ Vector Execution ===================
-- ===============================================
-- ===============================================

describe("locale resolution corpus — vector replay", function()
	if not corpus_root then return end

	for _, vec in ipairs(corpus_root.vectors) do
		local expected = vec.expected_lua or vec.expected
		it("locale: " .. vec.id, function()
			local Core = init_locale_with_vector(vec)
			local result = Core.get(vec.key)
			assert_eq(result, expected,
				vec.id .. ": expected '" .. tostring(expected) .. "' got '" .. tostring(result) .. "'")
		end)
	end
end)




-- ===============================================
-- ===============================================
-- ======= 5/ Regression Edges ===================
-- ===============================================
-- ===============================================

describe("locale resolution — additional regression edges", function()
	it("set_locale switches active locale and clears cache", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "FR" }, en = { ["menu.a"] = "EN" } }
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_trigger_provider(function() return nil end)

		Core.set_locale("fr")
		assert_eq(Core.get("menu.a"), "FR", "fr locale")

		Core.set_locale("en")
		assert_eq(Core.get("menu.a"), "EN", "en locale after switch")
	end)

	it("set_locale rejects empty code", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "FR" } }
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_trigger_provider(function() return nil end)
		Core.set_locale("fr")
		Core.set_locale("")
		assert_eq(Core.get("menu.a"), "FR", "locale unchanged after empty set_locale")
	end)

	it("get returns empty string before init", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		assert_eq(Core.get("any.key"), "", "uninitialised get returns empty string")
	end)

	it("is_initialised returns false before init, true after", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		assert_true(not Core.is_initialised(), "not initialised before init")
		Core.init({
			json_decode         = function() return {} end,
			resolve_locale_path = function() return "" end,
			read_file           = function() return "" end,
		})
		assert_true(Core.is_initialised(), "initialised after init")
	end)

	it("duplicate init is a no-op (idempotent)", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["menu.a"] = "first" } }
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		assert_eq(Core.get("menu.a"), "first", "first init active")

		local loc2 = { fr = { ["menu.a"] = "second" } }
		Core.init({
			json_decode         = make_json_decode(loc2),
			resolve_locale_path = make_path_resolver(loc2),
			read_file           = function() return "" end,
		})
		assert_eq(Core.get("menu.a"), "first", "second init ignored")
	end)

	it("trigger provider returning nil leaves ★ unchanged", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["star"] = "★ test" } }
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		assert_eq(Core.get("star"), "★ test", "★ unchanged when trigger is nil")
	end)

	it("trigger provider returning empty string leaves ★ unchanged", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = { fr = { ["star"] = "★ test" } }
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return "" end)
		assert_eq(Core.get("star"), "★ test", "★ unchanged when trigger is empty string")
	end)

	it("key with non-string value in locale table falls through to fallback", function()
		package.loaded["locale.core"] = nil
		local Core = require("locale.core")
		local loc = {
			fr = { ["menu.num"] = 42 },
			en = { ["menu.num"] = "forty-two" },
		}
		Core.init({
			json_decode         = make_json_decode(loc),
			resolve_locale_path = make_path_resolver(loc),
			read_file           = function() return "" end,
		})
		Core.set_locale("fr")
		Core.set_trigger_provider(function() return nil end)
		assert_eq(Core.get("menu.num"), "forty-two", "non-string value treated as missing")
	end)
end)
