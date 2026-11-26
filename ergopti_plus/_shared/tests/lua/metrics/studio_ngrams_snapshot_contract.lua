--- _shared/tests/lua/metrics/studio_ngrams_snapshot_contract.lua

--- ==============================================================================
--- MODULE: Ergopti Studio Saved Read Vectors Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/metrics/studio_ngrams_snapshot_vectors.json
--- through the shared saved-read codec (metrics/engine/view/studio_ngrams.lua).
--- The Windows AutoHotkey reader replays the same file, so the three drivers
--- accept and refuse every saved read alike. macOS and Linux both register it.
--- ==============================================================================

local M = {}

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
--- @param corpus_path string Absolute path of studio_ngrams_snapshot_vectors.json.
function M.register(helpers, corpus_path)
	local Json = require("core.text.engine.json")
	local StudioNgrams = require("metrics.engine.view.studio_ngrams")

	local handle = assert(io.open(corpus_path, "rb"))
	local corpus = Json.decode(handle:read("*a"))
	handle:close()

	helpers.describe("Ergopti Studio saved read vectors (studio-saved-read-vectors)", function()
		helpers.it("(studio-saved-read-vectors) the vectors follow the contract's format and schema", function()
			helpers.assert_eq(StudioNgrams.SNAPSHOT.header, corpus.format .. " ")
			helpers.assert_eq(StudioNgrams.SCHEMA, corpus.schema)
			helpers.assert_true(#corpus.reads >= 10, "the corpus lists its read vectors")
			helpers.assert_true(#corpus.writes >= 4, "the corpus lists its write vectors")
		end)

		helpers.it("(studio-saved-read-vectors) the shared codec accepts and refuses every saved read", function()
			for _, vector in ipairs(corpus.reads) do
				local decoded, saved = pcall(StudioNgrams.decode_snapshot, vector.text)
				if vector.stamp ~= nil then
					helpers.assert_true(decoded, vector.id .. ": " .. tostring(saved))
					helpers.assert_eq(saved.stamp, vector.stamp, vector.id)
					helpers.assert_eq(saved.ngrams, Json.decode(vector.text:match("\n(.*)$")), vector.id .. " (payload)")
				else
					helpers.assert_true(not decoded, vector.id .. " is refused")
				end
			end
		end)

		helpers.it("(studio-saved-read-vectors) the shared codec writes the vectors' text and refuses the others", function()
			for _, vector in ipairs(corpus.writes) do
				local encoded, text = pcall(StudioNgrams.encode_snapshot, vector.stamp, Json.decode(vector.json))
				if vector.text ~= nil then
					helpers.assert_true(encoded, vector.id .. ": " .. tostring(text))
					local header, body = text:match("^([^\n]*)\n(.*)$")
					helpers.assert_eq(header, vector.text:match("^([^\n]*)\n"), vector.id .. " (header)")
					-- A Lua table keeps no key order: the payload is compared decoded.
					helpers.assert_eq(Json.decode(body), Json.decode(vector.text:match("\n(.*)$")), vector.id .. " (payload)")
					helpers.assert_eq(StudioNgrams.decode_snapshot(text).stamp, vector.stamp, vector.id .. " (read back)")
				else
					helpers.assert_true(not encoded, vector.id .. " is refused")
				end
			end
		end)
	end)

	--- A store with an in-memory saved read: files[path] is a file's text.
	--- @return table deps, table files, table results, table logs, table queued
	local function store(dict_of)
		local files, results, logs, queued = {}, {}, {}, {}
		local deps = {
			path = "/data/ergopti/metrics.sqlite",
			exists = function() return true end,
			reads = 0,
			stamp = function() return "7" end,
			snapshot = {
				read = function(path)
					if files[path] == false then return nil, "error" end
					if files[path] == nil then return nil, "absent" end
					return files[path], "ok"
				end,
				write = function(path, text) files[path] = text; return true end,
			},
			log = function(level, message, ...) logs[#logs + 1] = level .. " " .. string.format(message, ...) end,
			defer = function(work) queued[#queued + 1] = work end,
		}
		deps.read = function()
			deps.reads = deps.reads + 1
			return dict_of(deps.reads), true
		end
		return deps, files, results, logs, queued
	end

	local function answer_into(results) return function(result) results[#results + 1] = result end end

	helpers.describe("Ergopti Studio saved read (studio-saved-read-first)", function()
		local saved_path = StudioNgrams.snapshot_path("/data/ergopti/metrics.sqlite")

		helpers.it("(studio-saved-read-first) the saved read sits beside the store, under the contract's name", function()
			helpers.assert_eq(saved_path, "/data/ergopti/" .. StudioNgrams.SNAPSHOT.file)
		end)

		helpers.it("(studio-saved-read-first) a read is saved, then shown at once by the next window, then the fresh one", function()
			StudioNgrams.reset_cache()
			local deps, files, results, logs, queued = store(function(n) return { c = { e = { c = n } } } end)
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(#results, 1, "no saved read yet: the store is read")
			helpers.assert_eq(results[1].ngrams.chars, { e = 1 })
			helpers.assert_true(results[1].saved == false)
			helpers.assert_eq(StudioNgrams.decode_snapshot(files[saved_path]).stamp, "7", "the read is saved with its stamp")
			-- A restart forgets the projection; the store changed since.
			StudioNgrams.reset_cache()
			deps.stamp = function() return "8" end
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(#results, 2, "the saved read answers before the store is read")
			helpers.assert_true(results[2].saved == true)
			helpers.assert_eq(results[2].ngrams.chars, { e = 1 })
			helpers.assert_eq(deps.reads, 1, "the fresh read waits for its turn")
			helpers.assert_eq(#queued, 1)
			queued[1]()
			helpers.assert_eq(#results, 3, "the fresh read follows")
			helpers.assert_eq(results[3].ngrams.chars, { e = 2 })
			helpers.assert_true(results[3].saved == false)
			helpers.assert_eq(StudioNgrams.decode_snapshot(files[saved_path]).stamp, "8", "and is saved in turn")
			helpers.assert_eq(logs, {})
			-- A restart on the unchanged store: the saved read is the answer, alone.
			StudioNgrams.reset_cache()
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(#results, 4)
			helpers.assert_eq(results[4].ngrams.chars, { e = 2 })
			helpers.assert_eq(deps.reads, 2, "a saved read of the unchanged store is not read again")
			helpers.assert_eq(#queued, 1)
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(results[5].ngrams.chars, { e = 2 }, "and is kept as the projection")
			helpers.assert_eq(deps.reads, 2)
			StudioNgrams.reset_cache()
		end)

		helpers.it("(studio-saved-read-first) a corrupt, mismatched or unreadable saved read is logged and never shown", function()
			for _, text in ipairs({ "{\"schema\":" .. StudioNgrams.SCHEMA .. "}", StudioNgrams.SNAPSHOT.header .. "7\n{\"schema\":0,\"source\":\"keystats\"}",
				StudioNgrams.SNAPSHOT.header .. "7\n{\"schema\":", false }) do
				StudioNgrams.reset_cache()
				local deps, files, results, logs, queued = store(function() return { c = { b = { c = 3 } } } end)
				files[saved_path] = text
				StudioNgrams.read(deps, answer_into(results))
				helpers.assert_eq(#results, 1, "only the fresh read is shown")
				helpers.assert_eq(results[1].ngrams.chars, { b = 3 })
				helpers.assert_eq(#queued, 0, "nothing was shown before it, so it is not deferred")
				helpers.assert_eq(#logs, 1, "the broken saved read is logged")
				helpers.assert_contains(logs[1], "error The saved Ergopti Studio read is ignored")
				helpers.assert_eq(StudioNgrams.decode_snapshot(files[saved_path]).ngrams.chars, { b = 3 }, "and replaced")
			end
			StudioNgrams.reset_cache()
		end)

		helpers.it("(studio-saved-read-first) a refused fresh read follows the saved one and saves nothing", function()
			StudioNgrams.reset_cache()
			local deps, files, results, _, queued = store(function() return { c = {} } end)
			deps.read = function() return {}, false end
			files[saved_path] = StudioNgrams.encode_snapshot("6", StudioNgrams.project({ c = { a = { c = 4 } } }))
			local before = files[saved_path]
			StudioNgrams.read(deps, answer_into(results))
			queued[1]()
			helpers.assert_eq(#results, 2)
			helpers.assert_eq(results[1].ngrams.chars, { a = 4 })
			helpers.assert_eq(results[2], { ok = false, code = StudioNgrams.CODES.unreadable })
			helpers.assert_eq(files[saved_path], before, "a partial read is never saved")
			-- Without a stamp nothing is saved either: the read cannot be dated.
			files[saved_path] = nil
			deps.read = function() return { c = { z = { c = 1 } } }, true end
			deps.stamp = function() return nil end
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(results[3].ngrams.chars, { z = 1 })
			helpers.assert_nil(files[saved_path], "a read without a stamp is not saved")
			StudioNgrams.reset_cache()
		end)

		helpers.it("(studio-saved-read-first) an absent store is refused before any saved read", function()
			StudioNgrams.reset_cache()
			local deps, files, results = store(function() return { c = {} } end)
			files[saved_path] = StudioNgrams.encode_snapshot("7", StudioNgrams.project({ c = { a = { c = 4 } } }))
			deps.exists = function() return false end
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(results, { { ok = false, code = StudioNgrams.CODES.absent } })
		end)

		helpers.it("(studio-saved-read-purge) retiring the saved read removes it and the projection kept in memory", function()
			StudioNgrams.reset_cache()
			local deps, files, results = store(function(n) return { c = { p = { c = n } } } end)
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_true(files[saved_path] ~= nil)
			local deleted = {}
			helpers.assert_true(StudioNgrams.retire_snapshot(deps.path, function(path)
				deleted[#deleted + 1] = path
				files[path] = nil
				return true
			end))
			helpers.assert_eq(deleted, { saved_path })
			StudioNgrams.read(deps, answer_into(results))
			helpers.assert_eq(deps.reads, 2, "the same stamp is read again after a retirement")
			helpers.assert_true(StudioNgrams.retire_snapshot(deps.path, function() return false end) == false,
				"a refused removal is reported")
			StudioNgrams.reset_cache()
		end)
	end)
end

return M
