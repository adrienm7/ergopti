--- tests/unit/meta/test_corpus_healthcheck_snapshot.lua

--- ==============================================================================
--- MODULE: Healthcheck Snapshot Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver healthcheck snapshot corpus from
--- _shared/tests/corpus/healthcheck/snapshot_vectors.json and replays each
--- vector through the shared healthcheck.snapshot module, then asserts the
--- output matches the expected golden values.
---
--- This pins the shared snapshot logic (format_uptime, extract_recent_issues,
--- count_issues, validate_snapshot) against golden vectors so any divergence
--- between the Lua and AHK implementations is caught immediately.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading =====================
-- ===============================================
-- ===============================================

local corpus_path = helpers.shared("tests/corpus/healthcheck/snapshot_vectors.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus_root, corpus_err = read_corpus()





-- ===============================================
-- ===============================================
-- ======= 2/ Vector Dispatch ====================
-- ===============================================
-- ===============================================

--- Loads the shared snapshot module (clearing any cached version first)
--- @return table The shared healthcheck.snapshot module
local function load_snapshot()
	package.loaded["healthcheck.snapshot"] = nil
	return require("healthcheck.snapshot")
end

--- Dispatches a single vector to the appropriate function and returns the result
--- @param S table The shared snapshot module
--- @param vec table A corpus vector
--- @return any The function result
local function dispatch(S, vec)
	local cat = vec.category
	local input = vec.input

	if cat == "format_uptime" then
		return S.format_uptime(input.sec)

	elseif cat == "extract_recent_issues" then
		if input.lines == nil then
			return S.extract_recent_issues(nil, input.max_lines)
		end
		return S.extract_recent_issues(input.lines, input.max_lines)

	elseif cat == "count_issues" then
		if input.lines == nil then
			return { S.count_issues(nil) }
		end
		return { S.count_issues(input.lines) }

	elseif cat == "validate_snapshot" then
		local ok, missing = S.validate_snapshot(input.snapshot)
		return { ok = ok, missing = missing }
	end

	return nil, "unknown category: " .. tostring(cat)
end




-- ===============================================
-- ===============================================
-- ======= 3/ Corpus Integrity ===================
-- ===============================================
-- ===============================================

helpers.describe("healthcheck snapshot corpus — integrity", function()
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
			helpers.assert_true(type(v.input) == "table" or v.input == nil,
				"vector '" .. tostring(v.id) .. "' missing input")
			helpers.assert_true(v.expected ~= nil,
				"vector '" .. tostring(v.id) .. "' missing expected")
		end
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 4/ Vector Execution ===================
-- ===============================================
-- ===============================================

helpers.describe("healthcheck snapshot corpus — vector replay", function()
	if not corpus_root then return end

	local S = load_snapshot()

	-- Group vectors by category for organized output
	local by_cat = {}
	for _, vec in ipairs(corpus_root.vectors) do
		by_cat[vec.category] = by_cat[vec.category] or {}
		by_cat[vec.category][#by_cat[vec.category] + 1] = vec
	end

	-- format_uptime vectors
	for _, vec in ipairs(by_cat["format_uptime"] or {}) do
		helpers.it("format_uptime: " .. vec.id .. " — " .. tostring(vec.input.sec) .. "s → " .. vec.expected, function()
			local result = dispatch(S, vec)
			helpers.assert_eq(result, vec.expected,
				vec.id .. ": format_uptime(" .. tostring(vec.input.sec) .. ")")
		end)
	end

	-- extract_recent_issues vectors
	for _, vec in ipairs(by_cat["extract_recent_issues"] or {}) do
		helpers.it("extract_recent_issues: " .. vec.id, function()
			local result = dispatch(S, vec)
			helpers.assert_true(type(result) == "table",
				vec.id .. ": result must be a table")
			helpers.assert_eq(#result, #vec.expected,
				vec.id .. ": issue count mismatch")
			for i, expected_line in ipairs(vec.expected) do
				helpers.assert_eq(result[i], expected_line,
					vec.id .. ": line " .. i .. " mismatch")
			end
		end)
	end

	-- count_issues vectors
	for _, vec in ipairs(by_cat["count_issues"] or {}) do
		helpers.it("count_issues: " .. vec.id, function()
			local result = dispatch(S, vec)
			helpers.assert_true(type(result) == "table" and #result == 2,
				vec.id .. ": count_issues must return (warn, err)")
			helpers.assert_eq(result[1], vec.expected.warn_count,
				vec.id .. ": warn_count mismatch")
			helpers.assert_eq(result[2], vec.expected.err_count,
				vec.id .. ": err_count mismatch")
		end)
	end

	-- validate_snapshot vectors
	for _, vec in ipairs(by_cat["validate_snapshot"] or {}) do
		helpers.it("validate_snapshot: " .. vec.id, function()
			local result = dispatch(S, vec)
			helpers.assert_eq(result.ok, vec.expected.ok,
				vec.id .. ": ok mismatch")
			if vec.expected.ok then
				helpers.assert_eq(#result.missing, 0,
					vec.id .. ": should have no missing fields")
			else
				-- Check that expected missing fields are present in the result
				if vec.expected.missing_contains then
					for _, expected_missing in ipairs(vec.expected.missing_contains) do
						local found = false
						for _, actual_missing in ipairs(result.missing) do
							if actual_missing == expected_missing then
								found = true
								break
							end
						end
						helpers.assert_true(found,
							vec.id .. ": expected missing field '" .. expected_missing .. "' not found in " ..
							table.concat(result.missing, ", "))
					end
				else
					helpers.assert_eq(#result.missing, #vec.expected.missing,
						vec.id .. ": missing count mismatch")
				end
			end
		end)
	end
end)
