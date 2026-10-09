--- tests/unit/infra/test_config_defaults.lua

local helpers = require("tests.helpers")

helpers.describe("neutral configuration contract", function()
	helpers.it("declares neutral dynamic hotstring leaves without claiming unrelated metadata", function()
		local reader = helpers.load_with_stubs("infra.manifest_reader")
		helpers.assert_eq(reader.default_for("category_enabled.french_autocorrection"), false)
		helpers.assert_eq(reader.default_for("hotstrings.groups.french_autocorrection"), false)
		helpers.assert_eq(reader.default_for("hotstrings.modules.french_autocorrection.accents"), false)
		helpers.assert_eq(reader.sparse_operation("hotstrings.modules.french_autocorrection.accents", false).delete, true)
		helpers.assert_eq(reader.has_default("hotstrings.modules.french_autocorrection.expert.value"), false)
		helpers.assert_eq(reader.has_default("hotstrings.groups..invalid"), false)
	end)

	helpers.it("limits dynamic scope changes to leaves the runtime explicitly owns", function()
		local reader = helpers.load_with_stubs("infra.manifest_reader")
		local owned = { "hotstrings.groups.french_autocorrection",
			"hotstrings.modules.french_autocorrection.accents", "category_enabled.french_autocorrection" }
		local changed = {}
		for _, operation in ipairs(reader.scope_operations("hotstrings", "clear", owned)) do
			changed[operation.section .. "." .. operation.key] = operation
		end
		helpers.assert_eq(changed[owned[1]].delete, true)
		helpers.assert_eq(changed[owned[2]].delete, true)
		helpers.assert_eq(changed[owned[3]].delete, true)
		for _, operation in ipairs(reader.scope_operations("keyboard_layout", "clear", owned)) do
			helpers.assert_true(operation.section ~= "category_enabled" or operation.key ~= "french_autocorrection",
				"a language master belongs only to the declared hotstrings scope")
		end
		helpers.assert_eq(changed["hotstrings.modules.future.unknown"], nil)
	end)
	helpers.it("keeps structured assignments whose neutral sentinel is false", function()
		local defaults = require("config_defaults").new(require("_generated.features_manifest"))
		local binding = { mods = { "ctrl" }, key = "space" }
		local operation = defaults.operation("shortcuts.keys.cmd_star", binding)
		helpers.assert_eq(operation.value, binding)
		binding.key = "return"
		helpers.assert_eq(operation.value.key, "space")
		helpers.assert_eq(defaults.operation("shortcuts.keys.cmd_star", false).delete, true)
	end)

	helpers.it("projects a detached neutral document for applying deleted preferences", function()
		local reader = helpers.load_with_stubs("infra.manifest_reader")
		local document = reader.document_defaults()
		helpers.assert_eq(document.gestures.enabled, false)
		helpers.assert_eq(document.gestures.tap_2, "none")
		helpers.assert_eq(document.shortcuts.keys.cmd_star, false)
		document.gestures.enabled = true
		helpers.assert_eq(reader.document_defaults().gestures.enabled, false)
	end)
	helpers.it("exposes the same contract through the real driver reader", function()
		local reader = helpers.load_with_stubs("infra.manifest_reader")
		helpers.assert_eq(reader.default_for("shortcuts.enabled"), false)
		helpers.assert_eq(reader.recommended_for("shortcuts.enabled"), true)
		helpers.assert_eq(reader.sparse_operation("shortcuts.enabled", false).delete, true)
		helpers.assert_true(#reader.scope_operations("gestures", "recommended") > 20)
	end)

	helpers.it("projects real neutral values while retaining the explicit recommended preset", function()
		local defaults = require("config_defaults").new(require("_generated.features_manifest"))
		helpers.assert_eq(defaults.default_for("shortcuts.enabled"), false)
		helpers.assert_eq(defaults.recommended_for("shortcuts.enabled"), true)
		helpers.assert_eq(defaults.default_for("gestures.swipe_3_down"), "none")
		helpers.assert_eq(defaults.recommended_for("gestures.swipe_3_down"), "tab_next")
		helpers.assert_eq(defaults.default_for("llm.generation.temperature"), 0.1)
	end)

	helpers.it("returns detached values and produces explicit sparse deletion intent", function()
		local defaults = require("config_defaults").new(require("_generated.features_manifest"))
		local original = defaults.default_for("hotstrings.magic_key.replace")
		original.enabled = true
		helpers.assert_eq(defaults.default_for("hotstrings.magic_key.replace.enabled"), false)
		local deleted = defaults.operation("shortcuts.enabled", false)
		helpers.assert_eq(deleted.delete, true)
		helpers.assert_eq(deleted.value, nil)
		local assigned = defaults.operation("shortcuts.enabled", true)
		helpers.assert_eq(assigned.section, "shortcuts")
		helpers.assert_eq(assigned.key, "enabled")
		helpers.assert_eq(assigned.value, true)
		helpers.assert_eq(assigned.delete, nil)
	end)

	helpers.it("restores only selected recommendations and never imports metrics or AI consent", function()
		local defaults = require("config_defaults").new(require("_generated.features_manifest"))
		local all = defaults.scope_operations("global", "recommended")
		local found, count = {}, 0
		for _, row in ipairs(all) do
			found[row.section .. "." .. row.key] = row
			count = count + 1
		end
		helpers.assert_true(count > 100, "exercise the real scope registry")
		helpers.assert_eq(found["llm.enabled"], nil)
		helpers.assert_eq(found["metrics.enabled"], nil)
		helpers.assert_eq(found["hotstrings.preview_ai_enabled"], nil)
		helpers.assert_eq(found["shortcuts.enabled"].value, true)
		helpers.assert_true(found["script.locale"] ~= nil, "global includes preferences outside feature scopes")
		for _, row in ipairs(defaults.scope_operations("gestures", "clear")) do
			helpers.assert_eq(row.section:match("^gestures"), "gestures")
			helpers.assert_eq(row.delete, true)
			helpers.assert_eq(row.value, nil)
		end
	end)
end)

require("test.scope_sparse_contract")(helpers)
