--- _shared/lua/test/crash_report_contract.lua

--- ==============================================================================
--- MODULE: Crash Report Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/diagnostics/crash_report_vectors.json against the
--- shared crash report module: the field order and defaults, the JSON layout, the
--- file names and the retention cap. The macOS and Linux reporters both write
--- through this module; a Windows reporter must satisfy the same vectors.
--- ==============================================================================

return function(helpers, json, shared_root)
	local CrashReport = require("crash_report")

	local file = assert(io.open(shared_root .. "/tests/corpus/diagnostics/crash_report_vectors.json", "rb"))
	local VECTORS = assert(json.decode(file:read("*a")))
	file:close()

	helpers.describe("Crash report format and retention", function()
		helpers.it("keeps the cap and the field list of the corpus", function()
			helpers.assert_eq(CrashReport.MAX_REPORTS, VECTORS.max_reports)
			local names = {}
			for _, field in ipairs(CrashReport.FIELDS) do names[#names + 1] = field[1] end
			helpers.assert_eq(names, VECTORS.fields)
		end)

		helpers.it("derives the file stem from the UTC timestamp", function()
			for _, vector in ipairs(VECTORS.stems) do
				helpers.assert_eq(CrashReport.stem(vector.timestamp), vector.stem)
			end
			helpers.assert_eq(pcall(CrashReport.stem, "2026-10-25 21:04:11"), false)
		end)

		helpers.it("names a report and parses the name back", function()
			for _, vector in ipairs(VECTORS.names) do
				helpers.assert_eq(CrashReport.file_name(vector.stem, vector.attempt), vector.name)
				local stem, attempt = CrashReport.parse_name(vector.name)
				helpers.assert_eq({ stem, attempt }, { vector.stem, vector.attempt })
			end
		end)

		helpers.it("refuses every name that is not a report", function()
			for _, name in ipairs(VECTORS.not_report_names) do
				helpers.assert_eq(CrashReport.parse_name(name), nil, "not a report: " .. name)
			end
		end)

		helpers.it("deletes the oldest reports beyond the cap, and only reports", function()
			for _, vector in ipairs(VECTORS.retention) do
				helpers.assert_eq(CrashReport.expired(vector.names, vector.limit), vector.expired, vector.case)
			end
		end)

		helpers.it("applies the shared cap by default", function()
			local names = {}
			for index = 1, CrashReport.MAX_REPORTS + 3 do
				names[#names + 1] = string.format("2026-10-25T10-00-%02dZ.json", index)
			end
			local expired = CrashReport.expired(names)
			helpers.assert_eq(#expired, 3)
			helpers.assert_eq(expired[1], "2026-10-25T10-00-01Z.json")
		end)

		helpers.it("serialises a record in the documented order with the documented defaults", function()
			for _, vector in ipairs(VECTORS.documents) do
				local document = CrashReport.encode(CrashReport.build(vector.fields))
				helpers.assert_eq(document, vector.json, vector.case)
				local decoded = assert(json.decode(document))
				helpers.assert_eq(decoded.stack_trace, vector.fields.stack_trace, "the document round-trips")
			end
		end)

		helpers.it("raises on an unknown field and converts a non-string value", function()
			helpers.assert_eq(pcall(CrashReport.build, { not_a_field = "x" }), false)
			helpers.assert_eq(CrashReport.build({ uptime_sec = 12 }).uptime_sec, "12")
		end)
	end)
end
