--- tests/unit/modules/keylogger/test_notify_synthetic_redacts_private.lua

--- ==============================================================================
--- MODULE: Regression — a private expansion must not persist its content
---         (notify-synthetic-redacts-private)
--- DESCRIPTION:
--- Put an IBAN, an SSN or a phone number in personal_info.toml, enable Metrics,
--- and fire the private expansion that inserts it. The secret then appears
--- verbatim in `today.log`, in `events_typing.rich_text` and in the
--- per-character `r` values of `events_json` — and cross-device export
--- replicates it to every other machine.
---
--- ROOT CAUSE ENCODED: the expander guards TWO of the three sinks behind
--- `is_private` (keylogger.log_hotstring and the DEBUG line) and calls
--- notify_synthetic unconditionally above them. That third sink feeds
--- append_virtual, which writes each replacement codepoint into buffer_events
--- (as meta.r) and into rich_chunks — persisted by flush_buffer through
--- sqlite_writer as events_json and rich_text.
---
--- WHY THE EXISTING TESTS MISSED IT: buffer_text stays clean either way, and
--- the privacy tests assert on `.text`. The dedicated
--- test_prefix_expansion_never_logs_pii stubs `notify_synthetic = function() end`,
--- so the real sink is never exercised at all — a guard that replaces the thing
--- it is guarding cannot observe what that thing does.
---
--- WHY NOT JUST SKIP THE CALL: notify_synthetic also arms the discard markers
--- that claim the physical key echoes. Skipping it for a private expansion
--- leaves those echoes unclaimed, and handle_key then records them as ordinary
--- HUMAN keystrokes in buffer_text — the same secret, in a worse place, and now
--- indistinguishable from typing. The private mode keeps the markers and
--- redacts only what is persisted.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A value that cannot occur by accident, so finding any part of it in the
--- recorded output is unambiguous.
local SECRET = "FR7630006000011234567890189"

--- The keylogger module, loaded through the helpers' stub environment.
---
--- Its CoreState is a module-private local, and every seam that exposes it
--- (KcBridge.init at load, LogManager.init from start()) requires reloading the
--- module — which drags the event tap, watchers and context tracker into the
--- run and outlives this file. An early draft did exactly that and broke an
--- unrelated vscode_bridge test, which reads os.getenv("HOME") at module scope.
---
--- So the redaction decision is exported as a pure function and asserted
--- directly, the same way the URL redactor is, and package.loaded is left alone.
local function keylogger()
	return helpers.load_with_stubs("modules.keylogger", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ Private content is never the recorded value ==================
-- =========================================================================
-- =========================================================================

helpers.describe("keylogger: a private expansion is redacted before it is recorded", function()
	helpers.it("no part of the secret survives as a recorded value", function()
		local kl = keylogger()
		helpers.assert_true(type(kl.recorded_char) == "function",
			"the keylogger must expose the redaction decision — the privacy invariant is about "
				.. "what gets persisted, and that cannot be asserted without running the thing "
				.. "that decides it")

		local recorded = {}
		for _, code in utf8.codes(SECRET) do
			recorded[#recorded + 1] = kl.recorded_char(utf8.char(code), true)
		end
		local joined = table.concat(recorded)

		helpers.assert_true(
			joined:find(SECRET, 1, true) == nil,
			"the private replacement text was recorded verbatim. It travels in the per-character "
				.. "`r` field of buffer_events and in rich_chunks, which sqlite_writer turns into "
				.. "events_json and rich_text — and cross-device export replicates both. Got: " .. joined
		)
		helpers.assert_true(
			joined:find("FR76", 1, true) == nil,
			"no fragment may survive either — a prefix of an IBAN or an SSN is still the secret. Got: " .. joined
		)
	end)

	helpers.it("one placeholder per character, so counts and timings stay correct", function()
		local kl = keylogger()

		local count = 0
		for _, code in utf8.codes("abcde") do
			local out = kl.recorded_char(utf8.char(code), true)
			helpers.assert_true(out ~= nil and out ~= "",
				"the redaction must SUBSTITUTE, never drop: every count, WPM sample and timing "
					.. "derived from these events assumes one entry per character")
			count = count + 1
		end
		helpers.assert_eq(count, 5, "every character must still produce a recorded value")
	end)

	helpers.it("backspace markers are never redacted", function()
		local kl = keylogger()
		helpers.assert_eq(kl.recorded_char("[BS]", true), "[BS]",
			"a backspace marker carries no content, and rewriting it would desynchronise the "
				.. "deletion count the buffer replays when it reconstructs the line")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ A public expansion is untouched ==============================
-- =========================================================================
-- =========================================================================

helpers.describe("keylogger: a public expansion is unaffected", function()
	helpers.it("non-private content is recorded verbatim", function()
		local kl = keylogger()
		for _, code in utf8.codes("bonjour") do
			local ch = utf8.char(code)
			helpers.assert_eq(kl.recorded_char(ch, false), ch,
				"a NON-private expansion must still be recorded in full. Blanket-muting synthetic "
					.. "text would silently destroy the metrics this subsystem exists to produce, "
					.. "which is why the redaction is opt-in per mapping")
		end
	end)

	helpers.it("omitting the flag entirely behaves as public", function()
		local kl = keylogger()
		helpers.assert_eq(kl.recorded_char("a"), "a",
			"callers that have not been migrated pass no flag, so the parameter must be additive — "
				.. "defaulting to redaction would silently blank every expansion in the metrics")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 3/ The expander forwards the flag, it does not skip =============
-- =========================================================================
-- =========================================================================

helpers.describe("expander: private mappings forward the flag", function()
	helpers.it("notify_synthetic is still called, with is_private passed to it", function()
		-- Selected by a symbol unique to the expander rather than by path, so the
		-- invariant survives the file being split or moved.
		local src = helpers.read_driver_source("perform_text_replacement")
		helpers.assert_true(src ~= nil and src ~= "",
			"the expander source must be locatable by its perform_text_replacement symbol")

		-- read_driver_source concatenates EVERY file containing the symbol, so the
		-- first occurrence of the call may belong to a different caller. Scan all
		-- of them and require at least one to pass the flag.
		local found_call, found_flag = false, false
		local pos = 1
		while true do
			local at = src:find("keylogger.notify_synthetic", pos, true)
			if not at then break end
			found_call = true
			if src:sub(at, at + 500):find("is_private", 1, true) then
				found_flag = true
			end
			pos = at + 1
		end

		helpers.assert_true(found_call,
			"the expander must still call notify_synthetic for EVERY expansion, private or not. "
				.. "Skipping it leaves the physical echoes unclaimed, and handle_key then logs them "
				.. "as ordinary human keystrokes — the same secret, recorded worse")
		helpers.assert_true(found_flag,
			"is_private must be passed TO notify_synthetic rather than used to guard the call site")
	end)

	helpers.it("the keylogger applies the flag to what it records", function()
		local src = helpers.read_driver_source("append_virtual")
		helpers.assert_true(src ~= nil and src ~= "",
			"the keylogger source must be locatable by its append_virtual symbol")
		helpers.assert_true(src:find("recorded_char", 1, true) ~= nil,
			"append_virtual must route every character through the redaction decision — it is the "
				.. "single point where buffer_events and rich_chunks are written, so a bypass here "
				.. "puts the secret straight back into events_json and rich_text")
	end)
end)
