--- _shared/tests/lua/core/log_export_contract.lua

--- Replays the shared log export vectors (file selection, archive name and
--- privacy scrub) against core/logger/engine/log_export.lua, and checks that
--- the shared ZIP writer produces an archive a reader can walk back.
return function(helpers, json, shared_root)
	local Export = require("core.logger.engine.log_export")
	local Zip = require("core.fs.engine.zip_writer")

	local function read_corpus()
		local file = assert(io.open(shared_root .. "/tests/corpus/logger/log_export_vectors.json", "rb"))
		local text = file:read("*a")
		file:close()
		return json.decode(text)
	end

	--- Little-endian integer of `size` bytes at `at` (1-based).
	local function le(bytes, at, size)
		local value = 0
		for index = size, 1, -1 do value = value * 256 + bytes:byte(at + index - 1) end
		return value
	end

	helpers.describe("log export: the shared selection and scrub", function()
		helpers.it("selects exactly the files of every vector (log-export-selection)", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.selection >= 4, "the corpus must hold its selection vectors")
			for _, vector in ipairs(corpus.selection) do
				local selected = Export.select({
					platform = vector.platform, today = vector.today, days = vector.days,
					logs = vector.logs, default = vector.default, crash_reports = vector.crash_reports,
				})
				helpers.assert_eq(#selected, #vector.expected, vector.name .. ": count")
				for index, expected in ipairs(vector.expected) do
					local got = selected[index] or {}
					helpers.assert_eq(got.folder, expected.folder, vector.name .. " #" .. index .. " folder")
					helpers.assert_eq(got.name, expected.name, vector.name .. " #" .. index .. " name")
					helpers.assert_eq(got.archive, expected.archive, vector.name .. " #" .. index .. " archive")
				end
			end
		end)

		helpers.it("never selects a retired topical file or a user file", function()
			local names = { "notes.txt" }
			for _, name in ipairs(require("core.fs.engine.app_dirs").files.retired_topical_logs) do
				names[#names + 1] = name
			end
			local selected = Export.select({ platform = "linux", today = "2026-11-25", logs = names,
				default = names, crash_reports = {} })
			helpers.assert_eq(#selected, 0, "only daily logs, mirrors and pre-logger files are archived")
		end)

		helpers.it("names the archive after the export instant (log-export-archive-name)", function()
			local corpus = read_corpus()
			helpers.assert_eq(Export.archive_name(corpus.archive_name.stamp), corpus.archive_name.expected)
		end)

		helpers.it("withholds the typed text of every scrub vector (log-export-scrub)", function()
			local corpus = read_corpus()
			helpers.assert_true(#corpus.scrub >= 10, "the corpus must hold its scrub vectors")
			for _, vector in ipairs(corpus.scrub) do
				local input = table.concat(vector.input, "\r\n") .. "\r\n"
				local output = Export.scrub_text("\239\187\191" .. input)
				helpers.assert_eq(output, table.concat(vector.expected, "\n") .. "\n", vector.name)
				for _, secret in ipairs(vector.secrets) do
					helpers.assert_true(not output:find(secret, 1, true), vector.name .. " keeps " .. secret)
				end
			end
		end)

		helpers.it("refuses a malformed date or day count", function()
			helpers.assert_throws(function() Export.window_dates("25/11/2026", 3) end)
			helpers.assert_throws(function() Export.window_dates("2026-11-25", 0) end)
			helpers.assert_throws(function() Export.select({ platform = "beos", today = "2026-11-25" }) end)
		end)
	end)

	helpers.describe("log export: the shared ZIP writer", function()
		helpers.it("computes the standard CRC-32", function()
			helpers.assert_eq(Zip.crc32("123456789"), 0xCBF43926)
			helpers.assert_eq(Zip.crc32(""), 0)
		end)

		helpers.it("writes stored entries a reader walks back from the central directory", function()
			local entries = { { name = "ErgoptiPlus_2026-11-25.log", data = "one\n" },
				{ name = "crash_reports/a.json", data = "{}" } }
			local bytes = Zip.build(entries, { year = 2026, month = 11, day = 25, hour = 10, min = 0, sec = 0 })
			local eocd = #bytes - 21
			helpers.assert_eq(bytes:sub(eocd, eocd + 3), "PK\5\6")
			helpers.assert_eq(le(bytes, eocd + 10, 2), 2, "entry count")
			local at = le(bytes, eocd + 16, 4) + 1
			for _, entry in ipairs(entries) do
				helpers.assert_eq(bytes:sub(at, at + 3), "PK\1\2")
				local name_length = le(bytes, at + 28, 2)
				helpers.assert_eq(bytes:sub(at + 46, at + 45 + name_length), entry.name)
				helpers.assert_eq(le(bytes, at + 16, 4), Zip.crc32(entry.data), entry.name .. " crc")
				local local_at = le(bytes, at + 42, 4) + 1
				helpers.assert_eq(bytes:sub(local_at, local_at + 3), "PK\3\4")
				local data_at = local_at + 30 + le(bytes, local_at + 26, 2) + le(bytes, local_at + 28, 2)
				helpers.assert_eq(bytes:sub(data_at, data_at + #entry.data - 1), entry.data)
				at = at + 46 + name_length
			end
		end)

		helpers.it("refuses an empty archive, a repeated name and a name escaping the archive", function()
			local stamp = { year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
			helpers.assert_throws(function() Zip.build({}, stamp) end)
			helpers.assert_throws(function() Zip.build({ { name = "a", data = "" }, { name = "a", data = "" } }, stamp) end)
			helpers.assert_throws(function() Zip.build({ { name = "../a", data = "" } }, stamp) end)
			helpers.assert_throws(function() Zip.build({ { name = "/a", data = "" } }, stamp) end)
		end)
	end)
end
