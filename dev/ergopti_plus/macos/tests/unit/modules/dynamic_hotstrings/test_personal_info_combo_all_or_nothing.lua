--- tests/unit/modules/dynamic_hotstrings/test_personal_info_combo_all_or_nothing.lua

--- ==============================================================================
--- MODULE: Regression — an unresolvable letter must decline the WHOLE @-combo
---         (macos-combo-skipped-unresolvable-letters)
--- DESCRIPTION:
--- `resolve_combo` used to SKIP any letter it could not resolve. So typing
--- "@npz★" with a stray "z" expanded as if the user had typed "@np★": the values
--- landed one form field short of where they were aimed, and every box after the
--- gap held the wrong thing. Nothing errored, nothing logged — in a bank form
--- that is a surname in the address line and an address in the phone line.
---
--- ROOT CAUSE ENCODED: a partial expansion is silently wrong, and silence is the
--- expensive part. Nothing happening is merely VISIBLY wrong, which the user
--- corrects in a second by retyping.
---
--- WHY IT IS A CROSS-DRIVER MATTER: Linux (`manager.resolve_combo`) and Windows
--- (`HSE_TryPersonalInfoCombo`) both decline, and both were written that way
--- deliberately. macOS skipping meant the same keystrokes typed different text on
--- different machines — and this divergence changes what is TYPED, not merely
--- what is shown, so the shared preview corpus could never have caught it.
---
--- Behavioural, through `_resolve_combo_for_test`: `resolve_combo` is a local and
--- a source-grep would pin its current spelling rather than the rule it enforces.
--- ==============================================================================

local helpers = require("tests.helpers")

local PersonalInfo = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")

-- Real-shaped, nobody's data.
local INFO = {
	last_name  = "Dupont",
	first_name = "Marie",
	iban       = "FR7630006000011234567890189",
	blank_one  = "",
}
local LETTERS = {
	n = "last_name",
	p = "first_name",
	i = "iban",
	b = "blank_one",
}

--- The values a combo resolves to, joined so an assertion reads like the row.
local function joined(combo)
	local values = PersonalInfo._resolve_combo_for_test(INFO, LETTERS, combo)
	return table.concat(values, "|")
end

helpers.describe("personal_info @-combo: all or nothing", function()

	helpers.it("resolves a combo whose every letter is known", function()
		helpers.assert_eq(joined("np"), "Dupont|Marie",
			"the ordinary case must keep working — a guard that refused everything "
				.. "would satisfy every assertion below and delete the feature")
		helpers.assert_eq(joined("pn"), "Marie|Dupont",
			"and order still decides which value lands in which field")
	end)

	helpers.it("declines the whole combo when one letter resolves to nothing", function()
		helpers.assert_eq(joined("npz"), "",
			"'z' aliases no field. Skipping it expanded '@npz' as '@np', so the values "
				.. "landed one form field short of where they were aimed and every later "
				.. "box held the wrong thing — silently, with the user's own data")
		helpers.assert_eq(joined("zn"), "",
			"and the position of the unresolvable letter makes no difference: leading, "
				.. "trailing or in the middle, the combo is not what the user typed")
		helpers.assert_eq(joined("nzp"), "", "middle")
	end)

	helpers.it("a field the user left blank counts as unresolvable", function()
		helpers.assert_eq(joined("nb"), "",
			"'b' aliases a declared field whose value is empty. Typing the surname and "
				.. "then nothing is the same shifted-fields failure as an unknown letter")
		helpers.assert_eq(joined("n"), "Dupont",
			"while the filled field on its own still resolves — the rule narrows the "
				.. "combo, it does not close the feature")
	end)

	helpers.it("returns field names alongside the values, in step", function()
		local values, fields = PersonalInfo._resolve_combo_for_test(INFO, LETTERS, "ni")
		helpers.assert_eq(#values, 2, "two values")
		helpers.assert_eq(#fields, 2, "and two field names")
		helpers.assert_eq(fields[1], "last_name", "first field name")
		helpers.assert_eq(fields[2], "iban", "second field name")
		-- The pairing is what lets the bubble mask an IBAN while showing the
		-- surname beside it; a resolver that returned the values alone would force
		-- one verdict on the whole row.
		helpers.assert_eq(values[2], INFO.iban,
			"the VALUE is unmasked here: masking is the display layer's job, and a "
				.. "masked value reaching the injector types bullets into a real form")
	end)

	helpers.it("declines gracefully on an empty or non-string combo", function()
		helpers.assert_eq(joined(""), "", "an empty combo resolves to nothing")
		local values = PersonalInfo._resolve_combo_for_test(INFO, LETTERS, nil)
		helpers.assert_eq(#values, 0, "and a nil combo must not throw on the keystroke path")
	end)

end)
