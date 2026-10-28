--- tests/unit/infra/preferences/test_preferences_dynamic_family_rows.lua

--- ==============================================================================
--- MODULE: Dynamic Date Family Row
--- DESCRIPTION:
--- The manifest keeps `hotstrings.dynamic.date` as a feature row
--- (`date = { enabled = false }`), but the macOS state key mapped the boolean
--- onto the row itself, so every save wrote a bare `date = false` the other
--- drivers and the read-only view could not read (field ledger L20). The
--- switch is now the row's `enabled` leaf in both directions.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")

local modules = nil

--- Runs one save of the real preferences owner over an in-memory config.toml.
--- @param source string Initial config.toml bytes.
--- @param mutate function Receives the loaded state before the save.
--- @return string published Bytes the save published.
local function save_once(source, mutate)
	local published
	helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system", "modules.keystats.kc_bridge" }, function()
		package.loaded["modules.keystats.kc_bridge"] = { init = function() return true end }
		-- One load per process: the keymap refuses a second LLM-bridge init.
		if not modules then
			modules = {}
			for key, name in pairs({ keymap = "keymap", dyn_hot_mod = "dynamic_hotstrings",
				shortcuts_mod = "shortcuts", gestures = "gestures", keystats = "keystats" }) do
				modules[key] = helpers.load_with_stubs("modules." .. name)
			end
		end
		package.loaded["adapters.file_system"] = {
			read_with_status = function() return source, "ok" end,
			write = function() error("publication must retain its source precondition") end,
			write_if_unchanged = function(_, content) source = content; return true end,
		}
		local prefs = helpers.load_with_stubs("infra.preferences")
		prefs.load("/dynamic/config.toml")
		local state = prefs.build_initial_state({}, {}, modules)
		mutate(state)
		helpers.assert_eq(prefs.save("/dynamic/config.toml", state, {}, modules), true)
		published = source
	end)
	return published
end

helpers.describe("dynamic date family row (dynamic-date-row-2026-10-27)", function()
	helpers.it("never saves the date switch as a bare scalar", function()
		for _, enabled in ipairs({ true, false }) do
			local published = save_once("[future]\nkeep = 1\n", function(state)
				state.dynamichotstrings_date = enabled
			end)
			local decoded = codec.decode(published)
			local date = decoded.hotstrings and decoded.hotstrings.dynamic and decoded.hotstrings.dynamic.date
			helpers.assert_true(date == nil or type(date) == "table",
				"a save wrote hotstrings.dynamic.date as a " .. type(date))
			local stored = type(date) == "table" and date.enabled
			if stored == nil then stored = false end
			helpers.assert_eq(stored, enabled, "the saved row holds the switch")
		end
	end)

	helpers.it("reads the switch from the row's enabled leaf", function()
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return "[hotstrings.dynamic]\ndate = { enabled = true }\n", "ok" end,
			}
			local state, status = helpers.load_with_stubs("infra.preferences").load("/dynamic/config.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.dynamichotstrings_date, true)
		end)
	end)
end)
