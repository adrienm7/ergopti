--- _shared/lua/test/app_category_store_corpus.lua

--- Replays the app category store corpus
--- (`_shared/tests/corpus/metrics/app_category_store_vectors.json`) through the
--- shared codec with a driver's own JSON library, so macOS and Linux prove the
--- same document, refusal and edit behaviour. Registered by both suites.
local M = {}

local Store = require("keystats.app_category_store")

--- Reads a file whole.
--- @param path string
--- @return string
local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Copies a name -> record map so a vector is never edited in place.
--- @param apps table
--- @return table
local function copy_apps(apps)
	local out = {}
	for name, entry in pairs(apps) do out[name] = { type = entry.type, score = entry.score } end
	return out
end

--- Registers the vectors as test cases.
--- @param helpers table The suite's helpers.
--- @param spec table { path, decode, encode, label }.
function M.register(helpers, spec)
	local corpus = spec.decode(read(spec.path))

	helpers.describe(spec.label .. ": documents", function()
		for _, case in ipairs(corpus.decode) do
			helpers.it("app-category-store: decode " .. case.id, function()
				local model, reason = Store.decode(case.document, spec.decode)
				if case.refused then
					helpers.assert_eq(model, nil, case.id .. " must be refused")
					helpers.assert_true(type(reason) == "string" and reason ~= "", case.id .. " must say why")
					return
				end
				helpers.assert_true(model ~= nil, case.id .. " must be accepted: " .. tostring(reason))
				helpers.assert_eq(model.legacy, case.legacy, case.id .. " legacy flag")
				helpers.assert_eq(model.apps, case.apps, case.id .. " apps")
				-- What a driver writes back reads back as the same model, in the versioned layout.
				local reread = assert(Store.decode(Store.encode(model, spec.encode), spec.decode))
				helpers.assert_eq(reread.apps, case.apps, case.id .. " round trip")
				helpers.assert_eq(reread.legacy, false, case.id .. " is rewritten versioned")
			end)
		end
	end)

	helpers.describe(spec.label .. ": edits", function()
		for _, case in ipairs(corpus.edits) do
			helpers.it("app-category-store: edit " .. case.id, function()
				local model = { apps = copy_apps(case.start), legacy = false }
				for index, op in ipairs(case.ops) do
					local where = case.id .. " op " .. index
					if op.op == "set" then
						helpers.assert_eq((Store.set(model, op.app, op.category, op.score)), op.ok, where)
					elseif op.op == "rename" then
						local renamed = Store.rename_category(model, op.from, op.to)
						if op.refused then helpers.assert_eq(renamed, nil, where) else
							helpers.assert_eq(renamed, op.renamed, where)
						end
					elseif op.op == "import" then
						local added = Store.import_missing(model, op.entries)
						if op.refused then helpers.assert_eq(added, nil, where) else
							helpers.assert_eq(added, op.added, where)
						end
					else
						error(where .. ": unknown op " .. tostring(op.op))
					end
				end
				helpers.assert_eq(model.apps, case.apps, case.id .. " final apps")
			end)
		end
	end)
end

return M
