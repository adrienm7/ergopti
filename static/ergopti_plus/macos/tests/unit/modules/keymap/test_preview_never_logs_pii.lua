--- tests/unit/modules/keymap/test_preview_never_logs_pii.lua

--- ==============================================================================
--- MODULE: Regression — the hotstring PREVIEW must never log its PII
--- DESCRIPTION:
--- CRITICAL privacy leak, and the forgotten sibling of acc7946fc.
---
--- That commit established the contract in modules/keymap/expander.lua: for a
--- mapping tagged is_private, BOTH the replacement and the trigger are secrets, so
--- the keylogger call and the DEBUG line are skipped and a content-free line is
--- logged instead — "DEBUG is the driver's default level", so an unguarded line
--- lands in a log retained 14 days. It applied that contract to the two EXPANSION
--- sinks (try_auto_expand and the terminator path) and stopped there.
---
--- The PREVIEW sink in modules/keymap/llm_bridge.lua ran on every keystroke and
--- logged unconditionally:
---   Logger.debug(LOG, "Hotstring '%s' → '%s' [%s].", tostring(m.input), m.plain_repl, m.type)
--- Worse than the expansion path, because a preview fires while the user is still
--- typing — before any expansion is committed — so merely typing "@phone" wrote
--- the resolved phone number into the log even if the expansion never happened.
---
--- Two distinct producers reach that line:
---   1. preview providers — dynamic_hotstrings/personal_info registers one that
---      resolves @-combos straight out of personal_info.toml (phone, IBAN, SSN,
---      card), and rules_engine registers a second over the same PII rules.
---   2. static registry mappings tagged is_private by rules_engine.
--- Neither carried is_private into the preview's match records, so the sink had no
--- way to apply the contract even in principle.
---
--- WHY THIS TEST IS BEHAVIOURAL:
--- The pre-existing guard for this area (test_update_preview_early_out.lua) is
--- entirely source-grep based, and a grep for the fixed line would pass against a
--- build that still leaks through a producer it does not know about. This test
--- installs a REAL logger sink, drives the REAL M.update_preview, and asserts on
--- what the logger actually received. The final case pins a NON-private mapping as
--- still logged, so a future "fix" that mutes the preview sink wholesale fails here
--- rather than silently destroying the diagnostic.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stands in for the user's real personal data. It must never appear in any log line.
local SENTINEL_PII = "9SENTINEL9"

-- A deliberately ordinary replacement that MUST still be logged.
local PUBLIC_REPL = "public-replacement"

package.loaded["infra.logger"] = nil
local Logger = helpers.load_with_stubs("infra.logger")





-- =================================
-- =================================
-- ======= 1/ Bridge Harness =======
-- =================================
-- =================================

--- Builds a minimal CoreState and initialises the real llm_bridge over it.
--- @param provider function|nil Preview provider to register, or nil for none.
--- @return table bridge, table state
local function load_bridge(provider)
	package.loaded["modules.keymap.llm_bridge"] = nil
	local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

	local state = {
		buffer                    = "",
		mappings                  = {},
		groups                    = {},
		preview_providers         = provider and { provider } or {},
		is_repeat_feature_enabled = function() return false end,
		DELAYS                    = {},
		SECTION_DELAYS            = {},
	}

	Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
	Bridge.set_preview_star_enabled(true)
	Bridge.set_preview_autocorrect_enabled(true)
	return Bridge, state
end

--- Drives update_preview with the logger sink installed and returns every line.
--- @param bridge table The initialised bridge.
--- @param buf string Buffer contents to preview.
--- @return table lines Captured log lines.
local function capture_preview(bridge, buf)
	local lines = {}
	Logger.set_level("DEBUG")
	Logger.set_sink(function(line) lines[#lines + 1] = tostring(line) end)
	pcall(bridge.update_preview, buf)
	Logger.set_sink(nil)
	return lines
end

--- Asserts no captured line contains the needle.
--- @param lines table Captured lines.
--- @param needle string Text that must be absent.
--- @param message string Assertion message.
local function assert_absent(lines, needle, message)
	-- The floor matters more than the scan. An absence assertion over an EMPTY
	-- log list is vacuous: if the capture stopped recording, every "must not
	-- leak" case in this file goes green while nothing is being inspected — which
	-- is the exact failure mode a PII test cannot afford.
	helpers.assert_true(#lines > 0,
		"no log lines were captured, so this absence assertion inspected nothing: " .. message)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			helpers.assert_true(false, message .. " — leaked line: " .. line)
			return
		end
	end
end





-- ==============================================
-- ==============================================
-- ======= 2/ Provider Output Is Withheld =======
-- ==============================================
-- ==============================================

helpers.describe("hotstring preview never logs personal-info content", function()
	helpers.it("a preview provider's resolved PII never reaches the log", function()
		local bridge = load_bridge(function(buf)
			-- Mirrors personal_info's provider: an @-combo resolves to the secret.
			if type(buf) == "string" and buf:match("@phone$") then return SENTINEL_PII end
			return nil
		end)

		local lines = capture_preview(bridge, "@phone")

		assert_absent(lines, SENTINEL_PII,
			"the resolved personal-info value must never be written to the log — DEBUG is the "
			.. "driver's default level and the file is retained 14 days (sibling of acc7946fc)")
	end)

	helpers.it("still records that a private preview matched, so the path stays diagnosable", function()
		local bridge = load_bridge(function(buf)
			if type(buf) == "string" and buf:match("@phone$") then return SENTINEL_PII end
			return nil
		end)

		local lines = capture_preview(bridge, "@phone")

		local mentioned = false
		for _, line in ipairs(lines) do
			if line:find("withheld", 1, true) then mentioned = true break end
		end
		helpers.assert_true(mentioned,
			"withholding must log a content-free marker rather than nothing at all, so the "
			.. "preview path remains traceable without exposing the secret")
	end)

	helpers.it("a NON-private static mapping is still logged in full", function()
		-- Guards the opposite failure: a "fix" that mutes the preview sink wholesale
		-- would satisfy every assertion above while destroying the diagnostic. Drive
		-- a REAL public star mapping through the REAL registry and require its
		-- replacement to still appear.
		local State = helpers.load_with_stubs("modules.keymap.state")

		package.loaded["modules.keymap.registry"] = nil
		package.loaded["modules.keymap.terminators"] = nil
		package.loaded["modules.keymap.expander"] = nil
		package.loaded["modules.keymap.llm_bridge"] = nil
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")

		-- Take the registry instance the BRIDGE resolved, not a separately loaded
		-- one: the bridge captured its Registry upvalue at require time, and a
		-- second instance would be initialised over a state the bridge never reads.
		local Registry = package.loaded["modules.keymap.registry"]
		helpers.assert_true(Registry ~= nil, "the bridge must have loaded the registry")
		local Expander = package.loaded["modules.keymap.expander"]
		helpers.assert_true(Expander ~= nil, "the bridge must have loaded the expander")

		local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
		state.preview_providers         = {}
		state.is_repeat_feature_enabled = function() return false end
		Registry.init(state)
		Registry.add("pub★", PUBLIC_REPL, { auto_expand = true })
		Registry.sort_mappings()

		Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
		Expander.init(state, Registry, Bridge)
		Bridge.set_preview_star_enabled(true)
		Bridge.set_preview_autocorrect_enabled(true)

		-- The star preview fires on the star_base ("pub"), before the magic key is
		-- typed — that is the whole point of previewing what ★ would produce.
		local lines = capture_preview(Bridge, "pub")

		local found = false
		for _, line in ipairs(lines) do
			if line:find(PUBLIC_REPL, 1, true) then found = true break end
		end
		helpers.assert_true(found,
			"a mapping WITHOUT is_private must still be logged in full — withholding must be "
			.. "scoped to private mappings, not applied to the whole preview sink")
	end)
end)
