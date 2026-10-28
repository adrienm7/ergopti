--- tests/unit/infra/toml/test_toml_record_scan_memo.lua

--- ==============================================================================
--- MODULE: TOML Record Scan Memo Tests
--- DESCRIPTION:
--- One preferences save scanned the same config.toml text 10 times, about
--- 55 ms of a 93 ms save under Lua 5.4 (measured). scan_records now keeps the
--- newest scans per header grammar and hands every caller a private copy.
--- These cases pin that a repeated text is not scanned again, that the two
--- header grammars never share a result, and that copies are independent.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE = '["x.y"]\nk = 1\n[plain]\nlist = [\n  1,\n]\n'

--- Counts string.find calls while `body` runs; scanning a line always finds.
--- @param body function Work to observe.
--- @return number calls
local function count_find_calls(body)
	local original, calls = string.find, 0
	string.find = function(...) calls = calls + 1; return original(...) end
	local ok, failure = pcall(body)
	string.find = original
	if not ok then error(failure, 0) end
	return calls
end

helpers.describe("TOML record scan memo", function()
	helpers.it("does not scan a text it scanned a moment ago", function()
		local Scanner = require("toml_codec.record_scanner")
		local text = SOURCE .. "# memo probe " .. tostring(os.clock()) .. "\n"
		helpers.assert_true(count_find_calls(function() Scanner.scan_records(text, { quoted_headers = true }) end) > 0,
			"the first scan of a text must scan it")
		helpers.assert_eq(count_find_calls(function() Scanner.scan_records(text, { quoted_headers = true }) end), 0,
			"the repeated text must be served from the memo")
	end)

	helpers.it("keeps the quoted and bare header grammars apart", function()
		local Scanner = require("toml_codec.record_scanner")
		local quoted = Scanner.scan_records(SOURCE, { quoted_headers = true })
		local bare = Scanner.scan_records(SOURCE)
		helpers.assert_eq(quoted.records[1].addressable, true)
		helpers.assert_eq(quoted.records[1].section, '"x.y"')
		helpers.assert_eq(bare.records[1].addressable, false, "a quoted header is not addressable in the bare grammar")
		helpers.assert_eq(Scanner.scan_records(SOURCE, { quoted_headers = true }).records[1].addressable, true)
	end)

	helpers.it("hands every caller an independent scan and repeats a refusal", function()
		local Scanner = require("toml_codec.record_scanner")
		local first = Scanner.scan_records(SOURCE, { quoted_headers = true })
		first.records[2].value = "mutated"
		first.lines[1].text = "mutated"
		local second = Scanner.scan_records(SOURCE, { quoted_headers = true })
		helpers.assert_eq(second.records[2].value, "[ 1, ]")
		helpers.assert_eq(second.lines[1].text, '["x.y"]')
		helpers.assert_true(second.records[1].header == second.headers[1], "shared header tables stay shared in the copy")
		for _ = 1, 2 do
			local scan, detail = Scanner.scan_records("[t]\nlist = [\n1,\n")
			helpers.assert_nil(scan)
			helpers.assert_eq(detail, "unterminated TOML assignment")
		end
	end)
end)
