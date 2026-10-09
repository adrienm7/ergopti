--- tests/unit/modules/shortcuts/test_magic_editor_keyboard_transaction.lua

--- ==============================================================================
--- MODULE: Contextual Keyboard Slot Transaction
--- DESCRIPTION:
--- Verifies that the ordinary keyboard preference owner admits the contextual
--- source owner before exact publication, restores its old intent on refusal,
--- and fences a candidate callback until the canonical assignment commits.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local MODULES = {
	"adapters.file_system", "adapters.hotkey_registrar", "infra.paths", "infra.logger",
	"infra.preferences", "infra.config_paths", "infra.manifest_reader", "toml_codec.writer",
	"modules.gestures.actions", "modules.shortcuts.magic_editor",
	"modules.shortcuts.keyboard_shortcuts",
}

local function with_subject(assignments, scenario)
	return helpers.with_stub_scope(MODULES, function()
		local observed = { specs = {}, actions = {}, claims = {}, writes = 0, binds = 0 }
		local controls = { admission_refuses = false, publication_refuses = false, stop_refuses = false }
		local file = assert(io.open("../_shared/modules/actions/modifier_chords.json", "rb"))
		local catalogue = Json.decode(file:read("*a"))
		file:close()
		catalogue.keys = { { id = "c", label = "C" } }
		package.loaded["adapters.file_system"] = {
			read = function() return Json.encode(catalogue) end,
		}
		package.loaded["infra.paths"] = { shared = function() return "modifier-chords.json" end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.manifest_reader"] = nil
		package.loaded["modules.gestures.actions"] = {
			is_assignable = function(action) return type(action) == "string" end,
			execute_single = function(action) observed.actions[#observed.actions + 1] = action; return true end,
		}
		package.loaded["adapters.hotkey_registrar"] = {
			bind = function() observed.binds = observed.binds + 1; return "ordinary-handle" end,
			unbind = function() return true end,
			setEnabled = function() return true end,
			replace_physical_claims = function(_, rows) observed.claims = rows; return true end,
		}
		package.loaded["modules.shortcuts.magic_editor"] = {
			start = function(spec)
				observed.specs[#observed.specs + 1] = spec
				observed.latest = spec
				return not controls.admission_refuses
			end,
			stop = function() return not controls.stop_refuses end,
			reason = function() return nil end,
		}
		require("tests.support.keyboard_config_fixture").install(assignments, function()
			observed.writes = observed.writes + 1
			observed.callback_during_write = observed.latest.execute(observed.latest.action, "keyboard__magic_editor")
			if controls.publication_refuses then error("owned publication refused") end
		end)
		require("toml_codec.writer").set_sparse_defaults("keyboard-fixture-config", require("infra.manifest_reader"))
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		local subject = require("modules.shortcuts.keyboard_shortcuts")
		local context = {
			trigger = function() return "★" end,
			magic_source = function() return "automatic" end,
			replace_active = function() return false end,
			paused = function() return false end,
			inhibited = function() return false end,
		}
		helpers.assert_eq(subject.configure_magic_editor(context), true)
		helpers.assert_eq(subject.start(), true)
		scenario(subject, observed, controls)
		controls.stop_refuses = false
		helpers.assert_eq(subject.stop(), true)
	end)
end

helpers.describe("contextual keyboard slot: ordinary persistence owner", function()
	helpers.it("owns one editable logical slot and preserves physical explicit none", function()
		with_subject({ hs_ctrl_c = "none" }, function(subject, observed)
			helpers.assert_eq(subject.get_action("magic_editor"), "open_hotstrings_editor")
			helpers.assert_eq(subject.available_slots("contextual")[1].id, "magic_editor")
			helpers.assert_eq(subject.assigned_slots("contextual")[1].action, "open_hotstrings_editor")
			helpers.assert_eq(observed.latest.action, nil, "canonical absence remains the shared conditional default")
			helpers.assert_eq(observed.binds, 0, "the logical slot never binds a displayed glyph")
			helpers.assert_eq(observed.claims, {
				{ chord = "Ctrl+C", action = "none", binding_id = "keyboard__hs_ctrl_c" },
			})
		end)
	end)

	helpers.it("fences explicit logical actions until exact publication", function()
		local assignments = {}
		with_subject(assignments, function(subject, observed)
			helpers.assert_eq(subject.set_action("magic_editor", "script_pause_toggle"), true)
			helpers.assert_eq(observed.callback_during_write, false)
			helpers.assert_eq(#observed.actions, 0)
			helpers.assert_eq(assignments.magic_editor, "script_pause_toggle")
			helpers.assert_eq(observed.latest.execute("script_pause_toggle", "keyboard__magic_editor"), true)
			helpers.assert_eq(observed.actions, { "script_pause_toggle" })
			helpers.assert_eq(subject.set_action("magic_editor", "none"), true)
			helpers.assert_eq(assignments.magic_editor, "none")
			helpers.assert_eq(subject.set_action("magic_editor", "open_hotstrings_editor"), true)
			helpers.assert_eq(assignments.magic_editor, "open_hotstrings_editor")
			helpers.assert_eq(observed.latest.action, "open_hotstrings_editor")
		end)
	end)

	helpers.it("persists a user-selected physical none through real sparse normalization and restart", function()
		local assignments = { hs_ctrl_c = "script_pause_toggle" }
		with_subject(assignments, function(subject, observed)
			helpers.assert_eq(subject.set_action("hs_ctrl_c", "none"), true)
			helpers.assert_eq(assignments.hs_ctrl_c, "none", "explicit None remains durable personal intent")
			local actions, claims = subject.get_configuration_intent()
			helpers.assert_eq(actions.hs_ctrl_c, "none")
			helpers.assert_eq(claims.hs_ctrl_c, true)
			helpers.assert_eq(subject.stop(), true)
			helpers.assert_eq(subject.start(), true)
			helpers.assert_eq(observed.claims, {
				{ chord = "Ctrl+C", action = "none", binding_id = "keyboard__hs_ctrl_c" },
			})
		end)
	end)

	helpers.it("restores the prior conditional intent and bytes after publication refusal", function()
		local assignments = { magic_editor = "none" }
		with_subject(assignments, function(subject, observed, controls)
			controls.publication_refuses = true
			helpers.assert_eq(subject.set_action("magic_editor", "script_pause_toggle"), false)
			helpers.assert_eq(assignments.magic_editor, "none")
			helpers.assert_eq(subject.get_action("magic_editor"), "none")
			helpers.assert_eq(observed.latest.action, "none")
			helpers.assert_eq(observed.callback_during_write, false)
			helpers.assert_eq(#observed.actions, 0)
		end)
	end)

	helpers.it("does not publish before conditional admission or stage across cleanup debt", function()
		with_subject({}, function(subject, observed, controls)
			controls.admission_refuses = true
			helpers.assert_eq(subject.set_action("magic_editor", "none"), false)
			helpers.assert_eq(observed.writes, 0)
			helpers.assert_eq(subject.get_action("magic_editor"), "open_hotstrings_editor")
			controls.stop_refuses = true
			helpers.assert_eq(subject.stop(), false)
			helpers.assert_eq(subject.apply_configuration({ shortcuts = { keyboard = { magic_editor = "none" } } }), false)
		end)
	end)
end)

return true
