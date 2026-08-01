--- tests/unit/modules/keymap/test_registry_percent_magic_key.lua

--- ==============================================================================
--- MODULE: Regression — a "%" magic key must not break hotstring registration
--- DESCRIPTION:
--- Registry.add substitutes the configured magic key into every "★" trigger:
---   trigger = trigger:gsub("★", _state.magic_key)
--- _state.magic_key lands on the REPLACEMENT side of gsub, where Lua treats "%"
--- specially: "%1".."%9" are capture references, "%%" is a literal percent, and a
--- "%" followed by anything else RAISES "invalid use of '%' in replacement
--- string". Verified directly in the interpreter:
---   ("a★"):gsub("★", "%")  ->  error: invalid use of '%' in replacement string
---
--- The key is user-configurable: the menubar's magic-key prompt accepts any text
--- and keeps its first codepoint with no character-class validation, so "%" is
--- reachable in one dialog. Choosing it made every add() throw during
--- registration, and since the change triggers a reload, the driver came back with
--- no hotstrings at all.
---
--- This is the forgotten sibling of ad7c7fd55 ("escape percent signs in gsub
--- replacements"), which introduced the escape helper and applied it to
--- app_picker and updater — the two sites handling third-party app names and
--- release tags — while the user-configurable magic key, the most obviously
--- user-controlled value of the three, kept its raw interpolation.
---
--- The helper now lives once in _shared/lua/text_utils (escape_gsub_replacement)
--- and the two former local copies delegate to it, so a fourth call site cannot
--- reintroduce the bug by copying a stale private helper.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Every replacement-side metacharacter a user could pick as their magic key.
-- "%" is the one that raises; "%1" cannot be typed as a single codepoint but the
-- escape must survive it regardless.
local HOSTILE_KEYS = { "%", "$", "&" }





-- ===========================================
-- ===========================================
-- ======= 1/ Registration Survives It =======
-- ===========================================
-- ===========================================

helpers.describe("registry survives a regex-metacharacter magic key", function()
	helpers.it("registers a ★ trigger without raising when the magic key is '%'", function()
		local State    = helpers.load_with_stubs("modules.keymap.state")
		local Registry = helpers.load_with_stubs("modules.keymap.registry")

		local state = State.new({ trigger_char = "%", expansion_delay = 0.4 }, {})
		state.magic_key = "%"
		Registry.init(state)

		local ok, err = pcall(Registry.add, "sig★", "Best regards", {})

		helpers.assert_true(ok,
			"Registry.add must not raise when the magic key is '%' — the key is interpolated "
			.. "into the REPLACEMENT side of gsub, where an unescaped '%' throws and aborts "
			.. "hotstring registration for the whole session: " .. tostring(err))
	end)

	helpers.it("produces the literal key in the stored trigger, not an escape artefact", function()
		local State    = helpers.load_with_stubs("modules.keymap.state")
		local Registry = helpers.load_with_stubs("modules.keymap.registry")

		local state = State.new({ trigger_char = "%", expansion_delay = 0.4 }, {})
		state.magic_key = "%"
		Registry.init(state)
		Registry.add("sig★", "Best regards", {})

		local found = nil
		for _, m in ipairs(state.mappings) do
			if m.trigger == "sig%" then found = m break end
		end

		helpers.assert_true(found ~= nil,
			"the stored trigger must be exactly 'sig%' — escaping is for gsub's benefit only "
			.. "and must not leak a doubled '%%' into the trigger the user actually types")
	end)

	helpers.it("escape_gsub_replacement survives percent-encoded text (the search_web case)", function()
		-- The same class, found in modules/gestures/actions.lua: a web-search
		-- template is filled via template:gsub("%%s", url_encode_query(selection)),
		-- and url_encode_query emits percent-escapes — a selection containing a
		-- space becomes "%20", whose "%2" reads as capture reference #2. That raised
		-- inside an hs.timer callback, where the error reaches only the HS Console,
		-- so the search silently never opened for any multi-word selection.
		local text_utils = helpers.load_with_stubs("infra.text_utils")

		local encoded  = "hello%20world%2Ffoo"
		local template = "https://example.com/search?q=%s"

		local ok, result = pcall(function()
			return (template:gsub("%%s", text_utils.escape_gsub_replacement(encoded)))
		end)

		helpers.assert_true(ok,
			"a percent-encoded replacement must not raise: " .. tostring(result))
		helpers.assert_eq(result, "https://example.com/search?q=hello%20world%2Ffoo",
			"the encoded text must survive verbatim — escaping is for gsub only and must not "
			.. "leak doubled percent signs into the URL")
	end)

	helpers.it("handles every hostile magic key without raising", function()
		for _, key in ipairs(HOSTILE_KEYS) do
			local State    = helpers.load_with_stubs("modules.keymap.state")
			local Registry = helpers.load_with_stubs("modules.keymap.registry")

			local state = State.new({ trigger_char = key, expansion_delay = 0.4 }, {})
			state.magic_key = key
			Registry.init(state)

			local ok = pcall(Registry.add, "sig★", "Best regards", {})
			helpers.assert_true(ok,
				"Registry.add must not raise for magic key '" .. key .. "'")
		end
	end)
end)
