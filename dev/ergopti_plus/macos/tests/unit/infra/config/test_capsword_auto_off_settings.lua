--- tests/unit/infra/config/test_capsword_auto_off_settings.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Settings Tests
--- DESCRIPTION:
--- The macOS owner of [shortcuts.caps_word] takes its pointer kinds and its
--- defaults from the manifest, applies a menu state only when the shared policy
--- compiles it (keeping the previous settings otherwise), and its three state
--- keys are the ones infra/preferences.lua reads and writes, the pointer kinds
--- as one table so no key list names them.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh settings owner with a capturing logger.
local function fresh_owner()
	package.loaded["infra.capsword_auto_off"] = nil
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_module, format_string, ...)
		errors[#errors + 1] = string.format(format_string, ...)
	end
	package.loaded["infra.logger"] = logger
	return require("infra.capsword_auto_off"), errors
end

--- A detached copy of the owner's defaults.
local function default_state(Owner)
	local state = {}
	for key, value in pairs(Owner.DEFAULT_STATE) do state[key] = value end
	local pointer = {}
	for kind, enabled in pairs(Owner.DEFAULT_STATE[Owner.POINTER_KEY]) do pointer[kind] = enabled end
	state[Owner.POINTER_KEY] = pointer
	return state
end

helpers.describe("CapsWord auto-off settings owner", function()
	helpers.it("takes the pointer kinds and defaults from the manifest", function()
		helpers.with_stub_scope({ "infra.capsword_auto_off", "infra.logger" }, function()
			local Owner = fresh_owner()
			local Manifest = require("infra.manifest_reader")
			local declared = {}
			for _, entry in ipairs(Manifest.declared_section_entries("shortcuts.caps_word.pointer")) do
				declared[#declared + 1] = entry.id
			end
			helpers.assert_eq(Owner.pointer_kinds(), declared, "every declared kind exists on macOS")
			helpers.assert_eq(Owner.DEFAULT_STATE[Owner.IDLE_KEY],
				Manifest.default_for("shortcuts.caps_word.idle_timeout_seconds"))
			helpers.assert_eq(Owner.DEFAULT_STATE[Owner.TERMINATORS_KEY],
				Manifest.default_for("shortcuts.caps_word.terminators"))
			for _, kind in ipairs(declared) do
				helpers.assert_eq(Owner.DEFAULT_STATE[Owner.POINTER_KEY][kind],
					Manifest.default_for("shortcuts.caps_word.pointer." .. kind), kind)
			end
		end)
	end)

	helpers.it("applies a valid state and keeps the previous one on refusal", function()
		helpers.with_stub_scope({ "infra.capsword_auto_off", "infra.logger" }, function()
			local Owner, errors = fresh_owner()
			local Policy = require("caps_word.auto_off")
			local state = default_state(Owner)
			state[Owner.IDLE_KEY] = 5
			state[Owner.TERMINATORS_KEY] = { "nbsp" }
			helpers.assert_true(Owner.apply_state(state))
			helpers.assert_eq(Policy.idle_delay_ms(Owner.policy()), 5000)
			helpers.assert_true(Policy.ends_on_text(Owner.policy(), "\xC2\xA0"))
			helpers.assert_eq(Owner.current_values()[Owner.TERMINATORS_KEY], { "nbsp" })
			state[Owner.TERMINATORS_KEY] = { "hyphen" }
			helpers.assert_eq(Owner.apply_state(state), false, "an unknown delimiter is refused")
			helpers.assert_eq(#errors, 1, "the refusal is reported")
			helpers.assert_true(Policy.ends_on_text(Owner.policy(), "\xC2\xA0"), "the previous settings stay")
			state[Owner.TERMINATORS_KEY] = { "space" }
			state[Owner.POINTER_KEY].left_click = nil
			helpers.assert_eq(Owner.apply_state(state), false, "a missing pointer kind is refused")
		end)
	end)

	helpers.it("persists through Preferences at the manifest paths", function()
		helpers.with_stub_scope({ "infra.capsword_auto_off", "infra.logger" }, function()
			local Owner = fresh_owner()
			local Preferences = require("infra.preferences")
			helpers.assert_eq(Preferences.flat_key_for("shortcuts.caps_word.idle_timeout_seconds"), Owner.IDLE_KEY)
			helpers.assert_eq(Preferences.flat_key_for("shortcuts.caps_word.terminators"), Owner.TERMINATORS_KEY)
			helpers.assert_eq(Preferences.flat_key_for("shortcuts.caps_word.pointer"), Owner.POINTER_KEY)
			local state = default_state(Owner)
			Preferences.merge_saved_data(state, { [Owner.POINTER_KEY] = { gesture = false } })
			helpers.assert_eq(state[Owner.POINTER_KEY].gesture, false, "a stored kind overlays its default")
			helpers.assert_eq(state[Owner.POINTER_KEY].left_click, true, "an absent kind keeps its default")
		end)
	end)
end)
