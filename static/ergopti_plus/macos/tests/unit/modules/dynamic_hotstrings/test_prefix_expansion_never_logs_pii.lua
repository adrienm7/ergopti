--- tests/unit/modules/dynamic_hotstrings/test_prefix_expansion_never_logs_pii.lua

--- ==============================================================================
--- MODULE: Regression — personal-info prefix expansions must never log their PII
--- DESCRIPTION:
--- CRITICAL privacy leak. rules_engine registers the phone / SSN / IBAN prefix
--- expansions as ordinary auto-expand registry mappings, so they fire through
--- keymap.expander — NOT through the interceptor. The interceptor path already
--- refuses to log its result ("the result may contain private data whose
--- plaintext must never reach the log"), but the expander path had no such
--- guard: try_auto_expand ended unconditionally with
---   pcall(keylogger.log_hotstring, trigger, repl_text)
---   Logger.debug(LOG, "Auto-expand: '%s' → '%s'.", typed, repl_text)
--- DEBUG is the driver's default level, so the full SSN / IBAN / phone number was
--- written in plaintext into a log retained 14 days — whether or not the keylogger
--- was enabled — and log_hotstring copied it into today.log, which ingest lifts
--- into events_hotstring in data.sql and the export replicates to every device.
---
--- Fix: rules_engine tags both PII option tables with is_private, the registry
--- carries the flag onto the mapping entry, and both expander sinks (auto and
--- terminator) skip the keylogger call and log a content-free line instead.
---
--- This test is BEHAVIOURAL, not a grep: it drives the real registration path
--- with a sentinel SSN, fires the REAL Expander.try_auto_expand, and inspects
--- what the REAL logger and a capturing keylogger stub actually received. The
--- final case pins a NON-private mapping as still logged, so a future "fix" that
--- mutes the expander wholesale fails here instead of silently destroying the
--- hotstring telemetry.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The sentinel stands in for the user's real SSN. It must never appear in ANY
-- log line or reach the keylogger.
local SENTINEL_SSN    = "9SENTINEL9"
local SENTINEL_PREFIX = "9SENT"  -- rules_engine registers ssn_raw:sub(1, 5)

package.loaded["lib.logger"] = nil
local Logger = helpers.load_with_stubs("lib.logger")


--- Installs a keylogger stub that records every log_hotstring invocation.
--- Must run BEFORE the expander is loaded: it captures the module at require time.
--- @return table The recorder table with a `calls` list.
local function install_keylogger_recorder()
	local rec = { calls = {} }
	package.loaded["modules.keylogger"] = {
		log_hotstring = function(trigger, replacement)
			table.insert(rec.calls, { trigger = trigger, replacement = replacement })
		end,
		log_hotstring_suggested = function() end,
		notify_synthetic = function() end,
		set_buffer = function() end,
	}
	return rec
end

--- Builds the minimal LLM bridge the expander needs to complete a replacement.
local function make_llm()
	return {
		update_preview   = function() end,
		get_llm_enabled  = function() return false end,
		start_timer      = function() end,
	}
end

--- Wires a real Registry + Expander over one shared state, drives the REAL
--- rules_engine registration path with the supplied personal data, and returns
--- everything the assertions need.
--- @param personal_data table Personal-info payload passed to inject_data.
--- @return table state, table Registry, table Expander, table keylogger_recorder
local function build_engine(personal_data)
	local rec = install_keylogger_recorder()

	local State    = helpers.load_with_stubs("modules.keymap.state")
	local Registry = helpers.load_with_stubs("modules.keymap.registry")
	local Expander = helpers.load_with_stubs("modules.keymap.expander")
	local RE       = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
	Registry.init(state)
	Expander.init(state, Registry, make_llm())

	-- Forward add/context/sort to the REAL registry so the mapping entries under
	-- test are produced by production code, not by the test.
	local fake_km = {
		add                       = Registry.add,
		set_group_context         = Registry.set_group_context,
		sort_mappings             = Registry.sort_mappings,
		is_section_enabled        = function() return true end,
		is_group_enabled          = function() return true end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		register_interceptor      = function() end,
		register_preview_provider = function() end,
	}

	-- Production boot order: inject_data() runs BEFORE start().
	RE.inject_data(personal_data, "★")
	RE.start(fake_km)

	return state, Registry, Expander, rec
end

--- Finds a registered mapping by its exact trigger.
--- @param state table The shared keymap state holding `mappings`.
--- @param trigger string The trigger to look up.
--- @return table|nil The mapping entry.
local function mapping_for(state, trigger)
	for _, m in ipairs(state.mappings) do
		if m.trigger == trigger then return m end
	end
	return nil
end

--- Runs `fn` with the logger at DEBUG (the driver's production default) and a
--- sink capturing every formatted line.
--- @param fn function The body to execute.
--- @return table The captured log lines.
local function capture_log_lines(fn)
	local lines = {}
	local previous_level = Logger.current_level
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) table.insert(lines, tostring(line)) end)
	local ok, err = pcall(fn)
	Logger.set_sink(nil)
	Logger.set_level(previous_level)
	if not ok then error(err, 0) end
	return lines
end

--- Asserts no captured line contains `needle`.
--- @param lines table Captured log lines.
--- @param needle string The forbidden substring.
--- @param msg string Context for the failure message.
local function assert_no_line_contains(lines, needle, msg)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			helpers.assert_true(false, string.format("%s — leaked in log line: %s", msg, line))
		end
	end
end


helpers.describe("personal-info prefix expansions never log their PII", function()
	helpers.it("rules_engine tags the SSN prefix mapping as private", function()
		local state = build_engine({ social_security_number = SENTINEL_SSN })
		local m = mapping_for(state, SENTINEL_PREFIX)
		helpers.assert_not_nil(m, "the SSN prefix mapping must be registered")
		helpers.assert_eq(m.repl, SENTINEL_SSN, "it must expand to the full SSN")
		helpers.assert_eq(m.is_private, true,
			"a mapping built from personal_info data must carry is_private so the expander can withhold it")
	end)

	helpers.it("firing it calls neither log_hotstring nor leaks the SSN to the log", function()
		local state, _, Expander, rec = build_engine({ social_security_number = SENTINEL_SSN })
		local m = mapping_for(state, SENTINEL_PREFIX)
		helpers.assert_not_nil(m, "the SSN prefix mapping must be registered")

		state.buffer = SENTINEL_PREFIX
		local fired
		local lines = capture_log_lines(function()
			fired = Expander.try_auto_expand(m, 1, false)
		end)

		helpers.assert_eq(fired, true, "the private mapping must still expand normally")

		-- The metrics sink: log_hotstring writes replacement + tag verbatim into
		-- today.log, which the export replicates to every other device.
		helpers.assert_eq(#rec.calls, 0,
			"keylogger.log_hotstring must NOT be called for a private mapping")

		-- The log sink: DEBUG is the production default, so any plaintext here
		-- lands in a log retained 14 days.
		assert_no_line_contains(lines, SENTINEL_SSN,
			"the full SSN must never reach the log")
		-- The trigger is itself a fragment of the secret — the first 5 digits.
		assert_no_line_contains(lines, SENTINEL_PREFIX,
			"the trigger prefix is part of the secret and must not be logged either")
	end)

	helpers.it("still logs an ORDINARY (non-private) mapping — no blanket muting", function()
		local state, Registry, Expander, rec = build_engine({ social_security_number = SENTINEL_SSN })

		-- A plain hotstring, registered exactly like any bundled TOML entry.
		Registry.add("zqxtrig", "ZQXREPLACEMENT", { auto_expand = true, is_case_sensitive = true })
		local m = mapping_for(state, "zqxtrig")
		helpers.assert_not_nil(m, "the ordinary mapping must be registered")
		helpers.assert_true(not m.is_private, "an ordinary mapping must NOT be marked private")

		state.buffer = "zqxtrig"
		local fired
		local lines = capture_log_lines(function()
			fired = Expander.try_auto_expand(m, 1, false)
		end)

		helpers.assert_eq(fired, true, "the ordinary mapping must expand")
		helpers.assert_eq(#rec.calls, 1,
			"a non-private mapping must STILL be reported to the keylogger — muting the expander wholesale is not the fix")
		helpers.assert_eq(rec.calls[1].trigger, "zqxtrig")
		helpers.assert_eq(rec.calls[1].replacement, "ZQXREPLACEMENT")

		local found = false
		for _, line in ipairs(lines) do
			if line:find("ZQXREPLACEMENT", 1, true) then found = true end
		end
		helpers.assert_true(found,
			"a non-private expansion must still be traceable in the DEBUG log")
	end)
end)
