--- static/ergopti_plus/linux/tests/unit/meta/test_corpus_updater_release_parser.lua

--- ==============================================================================
--- MODULE: Updater Release Parser Corpus Consumer (Linux)
--- DESCRIPTION:
--- Loads the cross-driver GitHub release JSON parser corpus from
--- _shared/tests/corpus/updater/release_parser_vectors.json and replays each
--- vector through the shared updater.release_parser module, then asserts the
--- output matches the expected golden values.
---
--- The Linux updater (modules/updater/manager.lua) calls this exact parser in
--- production — parse_asset_url() resolves the download URL for the release
--- asset — so this corpus pins the parser against the same golden vectors as
--- the macOS and AHK drivers. The asset_realistic_release_wanted_not_first
--- vector specifically guards the parse_asset_url assets-array scoping fix:
--- without it, iterating the whole release object matched the release title
--- instead of the wanted asset and returned the wrong URL.
--- ==============================================================================

local helpers = require("tests.helpers")

local corpus_path = helpers.driver_root()
	.. "/../_shared/tests/corpus/updater/release_parser_vectors.json"




-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading =====================
-- ===============================================
-- ===============================================

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	-- Use the shared pure-Lua JSON decoder (no hs.* on Linux). It returns nil
	-- on parse failure rather than raising.
	local decoded = require("json").decode(raw)
	if not decoded then return nil, "JSON parse error for " .. corpus_path end
	return decoded, nil
end

local corpus_root, corpus_err = read_corpus()




-- ===============================================
-- ===============================================
-- ======= 2/ Vector Dispatch ====================
-- ===============================================
-- ===============================================

local function load_parser()
	package.loaded["updater.release_parser"] = nil
	return require("updater.release_parser")
end

--- Coerces a decoded corpus value to a string, or nil when it is not one.
--- The shared JSON decoder represents a JSON `null` (used by the null-body and
--- null-json vectors) as absent/sentinel rather than a Lua string, and the
--- parser contract is string-or-nil, so normalising here keeps those "no value"
--- vectors faithful without masking any real parser behaviour.
local function as_str(v)
	return type(v) == "string" and v or nil
end

local function dispatch(P, vec)
	local cat = vec.category
	local input = vec.input
	local body = as_str(input.body)

	if cat == "parse_tag" then
		return P.parse_tag(body)

	elseif cat == "parse_notes" then
		return P.parse_notes(body)

	elseif cat == "parse_asset_url" then
		return P.parse_asset_url(body, as_str(input.asset_name))

	elseif cat == "parse_prerelease_flag" then
		return P.parse_prerelease_flag(body)

	elseif cat == "parse_html_url" then
		return P.parse_html_url(body)

	elseif cat == "parse_published_at" then
		return P.parse_published_at(body)

	elseif cat == "split_releases_array" then
		local chunks = P.split_releases_array(as_str(input.json))
		return #chunks
	end

	return nil, "unknown category: " .. tostring(cat)
end




-- ===============================================
-- ===============================================
-- ======= 3/ Corpus Integrity ===================
-- ===============================================
-- ===============================================

helpers.describe("updater release parser corpus — integrity", function()
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

	helpers.it("every vector has required fields: id, category, input, expected", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(type(v.category) == "string",
				"vector '" .. tostring(v.id) .. "' missing category")
			helpers.assert_true(v.expected ~= nil or v.expected_count ~= nil,
				"vector '" .. tostring(v.id) .. "' missing expected or expected_count")
		end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 4/ Vector Execution ===================
-- ===============================================
-- ===============================================

helpers.describe("updater release parser corpus — vector replay", function()
	if not corpus_root then return end

	local P = load_parser()

	local by_cat = {}
	for _, vec in ipairs(corpus_root.vectors) do
		by_cat[vec.category] = by_cat[vec.category] or {}
		by_cat[vec.category][#by_cat[vec.category] + 1] = vec
	end

	-- parse_tag vectors
	for _, vec in ipairs(by_cat["parse_tag"] or {}) do
		helpers.it("parse_tag: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_tag mismatch")
		end)
	end

	-- parse_notes vectors
	for _, vec in ipairs(by_cat["parse_notes"] or {}) do
		helpers.it("parse_notes: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_notes mismatch")
		end)
	end

	-- parse_asset_url vectors
	for _, vec in ipairs(by_cat["parse_asset_url"] or {}) do
		helpers.it("parse_asset_url: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_asset_url mismatch")
		end)
	end

	-- parse_prerelease_flag vectors
	for _, vec in ipairs(by_cat["parse_prerelease_flag"] or {}) do
		helpers.it("parse_prerelease_flag: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_prerelease_flag mismatch")
		end)
	end

	-- parse_html_url vectors
	for _, vec in ipairs(by_cat["parse_html_url"] or {}) do
		helpers.it("parse_html_url: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_html_url mismatch")
		end)
	end

	-- parse_published_at vectors
	for _, vec in ipairs(by_cat["parse_published_at"] or {}) do
		helpers.it("parse_published_at: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected,
				vec.id .. ": parse_published_at mismatch")
		end)
	end

	-- split_releases_array vectors
	for _, vec in ipairs(by_cat["split_releases_array"] or {}) do
		helpers.it("split_releases_array: " .. vec.id, function()
			helpers.assert_eq(dispatch(P, vec), vec.expected_count,
				vec.id .. ": split count mismatch")
		end)
	end
end)
