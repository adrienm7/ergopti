--- _shared/tests/lua/diagnostics/report_contract.lua

--- ==============================================================================
--- MODULE: Readable Diagnostics Report Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/healthcheck/report_vectors.json against the
--- shared share document on both Lua drivers: the readable English report is
--- byte for byte the one model.js and report.ahk write, and a config.toml with
--- many changed settings is cut on the bug link in those settings, after every
--- error, check and permission, with the note that sends the user to the Full
--- report field. The settings used to come before the errors, so a large
--- configuration cut the errors off the link (field report 2026-11-24).
--- ==============================================================================

return function(helpers, json, shared_root)
	local Share = require("diagnostics.engine.healthcheck.share")
	local IssueLink = require("diagnostics.engine.reports.issue_link")

	local function read(rel)
		local file = assert(io.open(shared_root .. "/" .. rel, "rb"))
		local data = assert(json.decode(file:read("*a")))
		file:close()
		return data
	end

	local function query_value(url, key)
		local raw = url:match("[?&]" .. key .. "=([^&]*)")
		if raw == nil then return nil end
		return (raw:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
	end

	local schema = read("diagnostics/data/schema.json")
	schema.export_strings = read("core/i18n/data/locales/en.json")
	local templates = read("diagnostics/data/issue_templates.json")
	local repository = read("updater/data/defaults.json").github
	local corpus = read("tests/corpus/healthcheck/report_vectors.json")

	helpers.describe("readable diagnostics report (report-readable)", function()
		for _, vector in ipairs(corpus.vectors) do
			helpers.it("renders " .. vector.id .. " byte for byte (report-readable)", function()
				local document = Share.document(vector.snapshot, schema)
				helpers.assert_eq(document.fields.diagnostics, vector.diagnostics)
				helpers.assert_eq(document.text:sub(1, #vector.diagnostics + 9), vector.diagnostics .. "\n```json\n",
					"the complete report starts with the same text, then its JSON block")
				helpers.assert_true(not document.text:find("PRIVATE_USER_ZEBRA", 1, true), "a path leaked")
				helpers.assert_true(not document.fields.diagnostics:find("| --- |", 1, true), "no Markdown table")
			end)
		end

		helpers.it("cuts a large configuration in its changed settings, after every error and check (report-budget)", function()
			local base
			for _, vector in ipairs(corpus.vectors) do
				if vector.id == corpus.large.vector then base = vector end
			end
			local snapshot = json.decode(json.encode(base.snapshot))
			local items = snapshot.sections.configuration.items
			for index = 1, corpus.large.rows do
				items[#items + 1] = { setting = corpus.large.setting_prefix .. index, type = "text", value = "9" }
			end
			local document = Share.document(snapshot, schema)
			local url = IssueLink.build_url(templates, repository, "bug", document.fields, document.notes)
			-- A signed-out click's login redirect carries the URL encoded again
			local redirect = #templates.login_redirect_prefix + #IssueLink.percent_encode(url)
			helpers.assert_true(#url <= templates.max_url_bytes, "the bug link fits its budget")
			helpers.assert_true(redirect <= templates.max_redirect_bytes, "its login redirect fits its budget")
			helpers.assert_true(#url > templates.max_url_bytes - 64 or redirect > templates.max_redirect_bytes - 64,
				"the bug link fills one of its budgets")
			helpers.assert_eq(query_value(url, "driver"), "macOS", "the Driver dropdown option")
			local prefilled = query_value(url, "diagnostics")
			local title = "## " .. schema.export_strings["healthcheck.export.changed_settings"]
			local before = base.diagnostics:sub(1, base.diagnostics:find(title, 1, true) + #title - 1)
			helpers.assert_eq(prefilled:sub(1, #before), before, "every group before the changed settings is whole")
			helpers.assert_true(prefilled:find("\ngestures.enabled = false\n", 1, true) ~= nil, "the first changed settings fit")
			local ending = templates.truncation_marker .. "\n\n" .. schema.export_strings[schema.share_policy.truncated_note_key]
			helpers.assert_eq(prefilled:sub(-#ending), ending, "the note sends the user to the Full report field")
		end)
	end)
end
