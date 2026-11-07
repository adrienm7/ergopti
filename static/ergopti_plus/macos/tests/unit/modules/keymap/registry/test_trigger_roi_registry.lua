--- tests/unit/modules/keymap/registry/test_trigger_roi_registry.lua

--- The real registry publishes candidate exclusions only after a committed sort.
local helpers = require("tests.helpers")

helpers.describe("trigger ROI admitted registry", function()
	helpers.it("tracks strict triggers and retires the index while a deferred mutation is pending", function()
		local registry = helpers.load_with_stubs("modules.keymap.registry")
		helpers.assert_nil(registry.is_known_trigger("other"))
		registry.init({ magic_key = "★", mappings = {}, mappings_lookup = {},
			mappings_by_tail_char = {}, mappings_by_star_tail_char = {}, groups = {},
			seq_counter = 0, current_group = "test", start_is_word_boundary = true })
		helpers.assert_eq(registry.is_known_trigger("other"), false)
		registry.add("UPPER", "expanded", { group = "test", is_case_sensitive_strict = true })
		registry.sort_mappings()
		helpers.assert_true(registry.is_known_trigger("upper"))
		helpers.assert_eq(registry.is_known_trigger("other"), false)
		registry.defer_sort()
		registry.add("NEXT", "expanded", { group = "test", is_case_sensitive_strict = true })
		registry.sort_mappings()
		helpers.assert_nil(registry.is_known_trigger("upper"))
		registry.flush_sort()
		helpers.assert_true(registry.is_known_trigger("next"))
		helpers.assert_true(registry.is_known_trigger("upper"))
	end)
end)
