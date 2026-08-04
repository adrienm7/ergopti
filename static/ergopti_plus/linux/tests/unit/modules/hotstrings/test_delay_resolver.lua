--- tests/unit/modules/hotstrings/test_delay_resolver.lua

--- ==============================================================================
--- MODULE: Hotstring Delay & Colour Cascade
--- DESCRIPTION:
--- The five-rung precedence that decides how long a hotstring waits, what colour
--- its preview is, and whether it has one.
---
--- WHY THE ORDER IS THE WHOLE TEST:
--- Every rung individually looks like a sensible default. The bug is always the
--- ORDER — a user's per-section setting losing to the category TOML means the
--- user changed something and nothing happened, which reads as the settings
--- window being broken rather than as a precedence mistake. So each case below
--- names two rungs and asserts which one wins.
---
--- WHY `false` HAS ITS OWN CASES:
--- show_tooltip is a boolean, so "unset" cannot be spelled as falsy. A rung
--- written with `or` would make `show_tooltip = false` — which is what
--- rolls.toml ships, and the single most common override — indistinguishable
--- from having said nothing, and the preview would come back on. That mistake
--- had already been made once in a sibling driver.
---
--- The cascade is shared with macOS, so these cases are about the rule rather
--- than about this driver: what differs between the two is where the override
--- file lives, and that is asserted separately below.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = {
	default_delay = 0.75,
	default_color = "#1e88e5",
}

--- Resolves with the shared cascade.
--- @param inputs table Partial inputs, merged over the defaults.
--- @return table
local function resolve(inputs)
	local resolver = helpers.load_module("hotstrings.delay_resolver")
	local merged = {}
	for k, v in pairs(DEFAULTS) do merged[k] = v end
	for k, v in pairs(inputs or {}) do merged[k] = v end
	return resolver.resolve(merged)
end





-- =================================================================
-- =================================================================
-- ======= 1/ Which rung wins ======================================
-- =================================================================
-- =================================================================

helpers.describe("delay cascade: precedence", function()

	helpers.it("falls all the way to the shared default", function()
		helpers.assert_eq(resolve({}).delay, 0.75,
			"a category that declares nothing and a user who changed nothing get the "
				.. "cross-driver canon from defaults.toml")
	end)

	helpers.it("prefers the category TOML to the shared default", function()
		helpers.assert_eq(resolve({ meta_category = { delay = 0.5 } }).delay, 0.5,
			"rolls.toml ships 0.5 because rolls must fire fast")
	end)

	helpers.it("prefers a section's TOML entry to its category's", function()
		helpers.assert_eq(resolve({
			meta_category = { delay = 0.5 },
			meta_section  = { delay = 0.2 },
		}).delay, 0.2, "a section may be faster than the pack it belongs to")
	end)

	helpers.it("prefers the user's category override to any TOML", function()
		helpers.assert_eq(resolve({
			meta_category = { delay = 0.5 },
			meta_section  = { delay = 0.2 },
			user_category = { delay = 1.5 },
		}).delay, 1.5,
			"the user asked for 1.5; a TOML that won here would mean the settings "
				.. "window did nothing")
	end)

	helpers.it("prefers the user's section override to the user's category one", function()
		helpers.assert_eq(resolve({
			user_category = { delay = 1.5 },
			user_section  = { delay = 3.0 },
		}).delay, 3.0, "the most specific thing the user said is what they meant")
	end)

	helpers.it("resolves colour down the same ladder", function()
		helpers.assert_eq(resolve({}).color, "#1e88e5", "the shared default")
		helpers.assert_eq(resolve({ category_color = "#6e6e73" }).color, "#6e6e73",
			"a per-category default sits above the global one, so the personal "
				.. "category keeps its neutral grey")
		helpers.assert_eq(resolve({
			category_color = "#6e6e73",
			meta_category  = { color = "#ff0000" },
		}).color, "#ff0000", "and the category's own TOML outranks it")
		helpers.assert_eq(resolve({
			meta_category = { color = "#ff0000" },
			user_section  = { color = "#00ff00" },
		}).color, "#00ff00", "and the user outranks everything")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ false is a value, not an absence =====================
-- =================================================================
-- =================================================================

helpers.describe("delay cascade: show_tooltip", function()

	helpers.it("defaults to shown", function()
		helpers.assert_eq(resolve({}).show_tooltip, true,
			"a category that says nothing gets a preview")
	end)

	helpers.it("honours an explicit false from the category TOML", function()
		-- THE case. `or` here would skip past false to the default and turn the
		-- preview back on for rolls, which ships show_tooltip = false precisely
		-- because a preview for a two-character roll is noise.
		helpers.assert_eq(resolve({ meta_category = { show_tooltip = false } }).show_tooltip, false,
			"an explicit false must survive four rungs of cascade; a truthiness test "
				.. "makes it indistinguishable from silence")
	end)

	helpers.it("lets the user turn a preview back on over the TOML", function()
		helpers.assert_eq(resolve({
			meta_category = { show_tooltip = false },
			user_category = { show_tooltip = true },
		}).show_tooltip, true, "the user outranks the pack, in both directions")
	end)

	helpers.it("lets the user turn one off that the TOML left on", function()
		helpers.assert_eq(resolve({
			meta_category = { show_tooltip = true },
			user_section  = { show_tooltip = false },
		}).show_tooltip, false, "and per-section, not only per-category")
	end)

	helpers.it("treats a delay of 0 as a value, not as unset", function()
		helpers.assert_eq(resolve({
			meta_category = { delay = 0.5 },
			user_category = { delay = 0 },
		}).delay, 0,
			"zero is 'fire immediately' and is a legitimate setting; `or` would read "
				.. "it as a number but a truthiness chain elsewhere would not")
	end)

end)





-- ===============================================
-- ===============================================
-- ======= 3/ What counts as a user change =======
-- ===============================================
-- ===============================================

helpers.describe("delay cascade: has_override", function()

	helpers.it("is false when only the TOML declares anything", function()
		helpers.assert_eq(resolve({ meta_category = { delay = 0.5, color = "#f00" } }).has_override, false,
			"a category shipping a delay is not the user having set one; conflating "
				.. "them makes 'reset to defaults' look like it did nothing")
	end)

	helpers.it("is true for a category override", function()
		helpers.assert_eq(resolve({ user_category = { delay = 1.0 } }).has_override, true,
			"the menu shows a value rather than '(default)'")
	end)

	helpers.it("is true for a section override", function()
		helpers.assert_eq(resolve({ user_section = { color = "#abc" } }).has_override, true,
			"any field, at either level")
	end)

	helpers.it("is true for an explicit show_tooltip = false", function()
		helpers.assert_eq(resolve({ user_category = { show_tooltip = false } }).has_override, true,
			"turning a preview off is a choice the user made, and a nil check is the "
				.. "only way to see it")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 4/ The driver around it =================================
-- =================================================================
-- =================================================================

helpers.describe("hotstrings_config: resolving through the driver", function()

	helpers.it("reads the shared defaults rather than a local literal", function()
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		-- 750 ms is declared once, in _shared/modules/hotstrings/defaults.toml,
		-- and read by all three drivers. A driver carrying its own copy expands at
		-- a different speed from the one the user configured elsewhere.
		helpers.assert_eq(config.get_global_default_delay_ms(), 750,
			"the canon is 0.75 s; a mismatch here means this driver stopped reading "
				.. "the shared file")
	end)

	helpers.it("applies an in-memory override through the shared cascade", function()
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		config._set_overrides_for_test({
			rolls = { delay = 2.5, sections = { hc = { delay = 0.1 } } },
		})
		helpers.assert_eq(config.resolve("rolls", nil).delay, 2.5, "the category override")
		helpers.assert_eq(config.resolve("rolls", "hc").delay, 0.1, "and the section one")
		helpers.assert_eq(config.resolve("magickey", nil).delay, 750 / 1000,
			"a category with no override falls to the shared default")
		config._set_overrides_for_test(nil)
	end)

	helpers.it("rejects a field it does not own", function()
		local config = helpers.load_module("modules.hotstrings.hotstrings_config")
		helpers.assert_eq(config.set_override("rolls", nil, "priority", 5), false,
			"priority is resolved by the loader from a different cascade entirely; "
				.. "accepting it here would write a key nothing reads")
		config._set_overrides_for_test(nil)
	end)

end)
