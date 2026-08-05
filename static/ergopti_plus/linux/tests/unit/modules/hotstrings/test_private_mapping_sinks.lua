--- tests/unit/modules/hotstrings/test_private_mapping_sinks.lua

--- ==============================================================================
--- MODULE: Where a Private Expansion May and May Not Appear
--- DESCRIPTION:
--- A mapping marked `is_private` carries PII — a phone number, a social-security
--- number, an IBAN. This walks every sink a fired expansion reaches and pins
--- which of them may see the payload.
---
--- WHY THIS EXISTS BEFORE THE FEATURE THAT NEEDS IT:
--- Nothing on Linux sets `is_private` yet. The expansions that will are the
--- iban/phone/ssn prefix rules the other two drivers already ship, and porting
--- them without this channel would write the user's IBAN, in clear, into the
--- metrics database and the 14-day log — a database that cross-device export
--- then replicates to every other machine. So the channel lands first, with its
--- own test, and the rules land on top of it.
---
--- THE SPLIT, AND WHY IT IS NOT "REDACT EVERYTHING":
---   • the per-character synthetic record is REDACTED, never dropped. Dropping
---     it would be worse than the leak it fixes: that record is what marks these
---     characters synthetic, and without it the physical echoes fall through as
---     ordinary human keystrokes — the same secret, in a worse column. The shape
---     is preserved so counts, WPM and net-gain arithmetic stay correct.
---   • the events_hotstring row is DROPPED outright, because both its columns are
---     secret. The replacement is the IBAN; the trigger is its first six
---     characters. Redacting one and keeping the other still leaks.
--- macOS makes exactly this split (expander.lua skips log_hotstring, forwards
--- the flag to notify_synthetic), and a database merged across a user's two
--- machines has to redact the same way on both.
---
--- WHAT IS NOT ASSERTED HERE:
--- That the clipboard route never carries a secret. It is reached only when the
--- layout cannot type a character, and every character of a phone number, SSN or
--- IBAN is ASCII — so no PII the driver ships can reach it. A pack declaring
--- `is_private` on non-ASCII output could; that is worth knowing and is recorded
--- rather than guarded, since guarding it means refusing to expand at all.
--- ==============================================================================

local helpers = require("tests.helpers")

local IBAN   = "FR76 3000 4000 5000"
local BULLET = "\226\128\162"  -- U+2022, the character macOS substitutes too

--- Fires one expansion and returns everything that reached the database.
---
--- Observed at the WRITER, not at an internal buffer: the writer is the actual
--- sink, and it is what cross-device export replicates. A test that read the
--- module's own upvalue would pass just as happily if a later change started
--- persisting the secret by a different route.
--- @param is_private boolean|nil
--- @return table { hotstrings = rows, typing = rows, app_days = fields }
local function flush_expansion(is_private)
	local calls = { typing = {}, hotstrings = {}, app_days = {} }
	local fake_writer = {
		open_db = function() return true end,
		register_device = function() return true end,
		is_available = function() return true end,
		bump_rev = function() return true end,
		insert_typing_events = function(_, events)
			for _, row in ipairs(events) do calls.typing[#calls.typing + 1] = row end
			return true
		end,
		insert_hotstring_events = function(_, events)
			for _, row in ipairs(events) do calls.hotstrings[#calls.hotstrings + 1] = row end
			return true
		end,
		insert_app_switch_events = function() return true end,
		upsert_app_day = function(_, _, _, fields)
			calls.app_days[#calls.app_days + 1] = fields
			return true
		end,
		upsert_ngrams = function() return true end,
		upsert_scancodes = function() return true end,
	}

	local writer_name = "modules.keylogger.sqlite_writer"
	local logger_name = "modules.keylogger.keylogger"
	local previous_writer, previous_logger = package.loaded[writer_name], package.loaded[logger_name]
	package.loaded[writer_name] = fake_writer
	package.loaded[logger_name] = nil

	local ok, err = pcall(function()
		local kl = require(logger_name)
		kl.init({ sqlite_path = "/tmp/ergopti_private_sinks.sqlite" })
		kl.reset_session()
		kl.on_app_focus("app.test", 1000)
		kl.record_hotstring("app.test", "FR7630", IBAN, 1100, "static", 6, is_private)
		kl.on_app_focus("other", 2000)
		kl.flush()
	end)

	package.loaded[writer_name] = previous_writer
	package.loaded[logger_name] = previous_logger
	helpers.assert_true(ok, "the flush must complete: " .. tostring(err))
	return calls
end




-- =================================================================
-- =================================================================
-- ======= 1/ The events_hotstring row =============================
-- =================================================================
-- =================================================================

helpers.describe("private mapping: the hotstring event row", function()

	helpers.it("writes the row for an ordinary expansion", function()
		local rows = flush_expansion(false).hotstrings
		helpers.assert_eq(#rows, 1, "an ordinary expansion reaches the database")
		helpers.assert_eq(rows[1].replacement, IBAN)
	end)

	helpers.it("writes NO row for a private expansion", function()
		helpers.assert_eq(#flush_expansion(true).hotstrings, 0,
			"both columns of this row are secret — the replacement IS the IBAN and "
				.. "the trigger is its first six characters, so redacting one and "
				.. "keeping the other still leaks")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The per-character synthetic record ===================
-- =================================================================
-- =================================================================

helpers.describe("private mapping: the synthetic character record", function()

	helpers.it("keeps one entry per character, redacted", function()
		local private_rows  = flush_expansion(true).typing
		local ordinary_rows = flush_expansion(false).typing
		helpers.assert_true(#private_rows > 0, "the expansion is persisted at all")

		local private_json  = private_rows[1].events_json or ""
		local ordinary_json = ordinary_rows[1].events_json or ""

		-- One entry per character, so the IBAN never appears as a substring in
		-- either case. What identifies a leak is the characters themselves: "F"
		-- and "R" are the country code, and the digits are the account.
		local function has_char(json, char) return json:find('["' .. char .. '"', 1, true) ~= nil end

		helpers.assert_true(not has_char(private_json, "F") and not has_char(private_json, "7"),
			"not one character of the secret may reach events_json, which "
				.. "cross-device export replicates to every other machine the user owns")
		helpers.assert_contains(private_json, BULLET,
			"redacted, not dropped: these entries are what mark the characters "
				.. "synthetic, and without them the physical echoes are recorded as "
				.. "ordinary human keystrokes — the same secret, in a worse column")
		helpers.assert_true(has_char(ordinary_json, "F") and has_char(ordinary_json, "7"),
			"and an ordinary expansion is untouched by any of this")

		local function count_synthetic(json)
			local n = 0
			for _ in json:gmatch('"st":"hotstring"') do n = n + 1 end
			return n
		end
		helpers.assert_eq(count_synthetic(private_json), count_synthetic(ordinary_json),
			"the SHAPE survives redaction, so counts, WPM and the net-gain "
				.. "arithmetic stay correct")
	end)

	helpers.it("counts the private expansion in the day's aggregates", function()
		local function hs_chars(calls)
			for _, fields in ipairs(calls.app_days) do
				if fields.hs_chars and fields.hs_chars > 0 then return fields.hs_chars end
			end
			return 0
		end
		helpers.assert_eq(hs_chars(flush_expansion(true)), hs_chars(flush_expansion(false)),
			"redaction is about content, not about pretending the expansion never "
				.. "happened — the user's saved-keystrokes total must still count it")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The log ==============================================
-- =================================================================
-- =================================================================

--- Captures everything the injector logs while typing a replacement.
--- @param is_private boolean|nil
--- @return string
local function injector_log(is_private)
	local injector = helpers.load_module("modules.hotstrings.injector")
	local logger   = require("logger.shim")

	local lines = {}
	local originals = {}
	for _, level in ipairs({ "trace", "debug", "info", "warn", "error", "done", "success" }) do
		originals[level] = logger[level]
		logger[level] = function(_tag, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			lines[#lines + 1] = ok and line or tostring(fmt)
		end
	end

	pcall(injector.inject, 6, "FR76 3000 4000 5000", is_private)

	for level, fn in pairs(originals) do logger[level] = fn end
	return table.concat(lines, "\n")
end

helpers.describe("private mapping: the 14-day log", function()

	helpers.it("withholds the replacement from the injector's trace line", function()
		helpers.assert_true(not injector_log(true):find("FR76 3000", 1, true),
			"the driver's default level prints TRACE and the log is kept for 14 "
				.. "days, which makes it the same sink as the database as far as a "
				.. "leak is concerned")
	end)

	helpers.it("still prints the replacement for an ordinary expansion", function()
		helpers.assert_contains(injector_log(false), "FR76 3000",
			"this is a redaction, not a general loss of diagnostics: an ordinary "
				.. "expansion must stay as debuggable as it was")
	end)

	helpers.it("names the type, not the value, when the arguments are wrong", function()
		local injector = helpers.load_module("modules.hotstrings.injector")
		local logger   = require("logger.shim")
		local original = logger.error
		local lines = {}
		logger.error = function(_tag, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			lines[#lines + 1] = ok and line or tostring(fmt)
		end
		-- Arguments the wrong way round: the payload arrives where the count belongs.
		pcall(injector.inject, "FR76 3000 4000 5000", 6)
		logger.error = original

		helpers.assert_true(not table.concat(lines, "\n"):find("FR76", 1, true),
			"this branch fires BECAUSE the arguments are not what was expected, so "
				.. "nothing it holds can be assumed non-secret")
	end)

end)
