--- tests/unit/modules/keymap/test_terminators.lua

--- ==============================================================================
--- MODULE: keymap.terminators Unit Tests
--- DESCRIPTION:
--- Verifies the terminator catalogue, hot-path lookups, enable/disable
--- semantics, custom terminator lifecycle, and magic-key sync.
--- ==============================================================================

local helpers = require("tests.helpers")

local term    = helpers.load_with_stubs("modules.keymap.terminators")

helpers.describe("keymap.terminators: defaults", function()
	helpers.it("space is enabled by default", function()
		helpers.assert_true(term.is_terminator(" "))
	end)

	helpers.it("period is enabled by default (basic punctuation)", function()
		helpers.assert_true(term.is_terminator("."))
	end)

	helpers.it("non-basic options are off by default", function()
		-- The catalogue offers many options but only the basics ship on.
		helpers.assert_true(not term.is_terminator("\u{00A0}"))   -- nbsp
		helpers.assert_true(not term.is_terminator(")"))           -- closing paren
		helpers.assert_true(not term.is_terminator("/"))           -- slash
	end)

	helpers.it("magic key (star) is enabled by default and consumed", function()
		helpers.assert_true(term.is_terminator("★"))
		helpers.assert_true(term.terminator_is_consumed("★"))
	end)

	helpers.it("get_terminator_defs returns the catalogue", function()
		local defs = term.get_terminator_defs()
		helpers.assert_true(#defs > 5)
	end)
end)

helpers.describe("keymap.terminators: enable/disable", function()
	helpers.it("toggles space off", function()
		local disable_result = term.set_terminator_enabled("space", false)
		local disabled_state = term.is_terminator(" ")
		local enable_result = term.set_terminator_enabled("space", true)
		local enabled_state = term.is_terminator(" ")
		helpers.assert_eq(disable_result, true)
		helpers.assert_eq(disabled_state, false)
		helpers.assert_eq(enable_result, true)
		helpers.assert_eq(enabled_state, true)
	end)

	helpers.it("is_terminator_enabled mirrors state", function()
		term.set_terminator_enabled("comma", false)
		helpers.assert_true(not term.is_terminator_enabled("comma"))
		term.set_terminator_enabled("comma", true)
		helpers.assert_true(term.is_terminator_enabled("comma"))
	end)

	helpers.it("commits a validated batch atomically", function()
		helpers.assert_eq(type(term.set_terminators_enabled), "function")
		helpers.assert_eq(term.set_terminators_enabled({
			space = false,
			comma = false,
		}), true)
		helpers.assert_eq(term.is_terminator_enabled("space"), false)
		helpers.assert_eq(term.is_terminator_enabled("comma"), false)

		helpers.assert_eq(term.set_terminators_enabled({
			space = true,
			unknown_terminator = true,
		}), false)
		helpers.assert_eq(term.is_terminator_enabled("space"), false,
			"an invalid sibling must prevent every candidate state from publishing")
		helpers.assert_eq(term.is_terminator_enabled("comma"), false)

		helpers.assert_eq(term.set_terminators_enabled({ space = true, comma = true }), true)
	end)
end)

helpers.describe("keymap.terminators: hot-path", function()
	helpers.it("non-terminator character returns false", function()
		helpers.assert_true(not term.is_terminator("x"))
	end)

	helpers.it("first-codepoint fallback fires", function()
		-- Multi-codepoint event that starts with a terminator
		helpers.assert_true(term.is_terminator(" \u{0301}"))
	end)

	helpers.it("empty string is not a terminator", function()
		helpers.assert_true(not term.is_terminator(""))
	end)
end)

helpers.describe("keymap.terminators: custom lifecycle", function()
	helpers.it("adds a new custom terminator", function()
		term.add_custom_terminator("custom_x", "x", "x label", true)
		helpers.assert_true(term.is_terminator("x"))
		helpers.assert_true(term.terminator_is_consumed("x"))
	end)

	helpers.it("updates an existing custom terminator in place", function()
		term.add_custom_terminator("custom_x", "y", "y label", false)
		helpers.assert_true(term.is_terminator("y"))
		helpers.assert_true(not term.terminator_is_consumed("y"))
	end)

	helpers.it("removes a custom terminator", function()
		term.remove_custom_terminator("custom_x")
		helpers.assert_true(not term.is_terminator("y"))
	end)

	helpers.it("rejects invalid key/char gracefully", function()
		-- No throw expected
		term.add_custom_terminator(nil, "z", "label", false)
		helpers.assert_true(not term.is_terminator("z"))
	end)
end)

helpers.describe("keymap.terminators: magic key sync", function()
	helpers.it("retargets star to a new character", function()
		term.update_magic_key("§")
		helpers.assert_true(term.is_terminator("§"))
		helpers.assert_true(term.terminator_is_consumed("§"))
		-- restore
		term.update_magic_key("★")
	end)
end)

-- The pause invariant for this module is that it has none: terminators are pure
-- data, and the decision not to expand while paused belongs to the caller (the
-- Feed path early-returns). Three cases here used to say that with
-- assert_true(true) and a message — a design claim written as a test, which is a
-- comment that costs a test-suite line and deters anyone from writing the real
-- one. What can actually be checked is the claim itself.
helpers.describe("keymap.terminators: the pause gate is not here", function()
	-- Both halves: the macOS file is a thin i18n shim over the shared catalogue,
	-- so checking only one of them leaves the other free to grow the coupling.
	helpers.it("neither the shim nor the shared core names pause or suspend state", function()
		-- The driver half goes through read_driver_source (symbol-keyed, so a
		-- git mv cannot break it); the shared half is not under the driver root,
		-- so it is opened by its shared-relative path.
		local sources = {}
		sources["macos/modules/keymap/terminators.lua"] =
			helpers.read_driver_source("local I18N_LABEL_KEYS")

		local shared_fh = io.open(helpers.shared("lua/keymap/terminators.lua"), "r")
		helpers.assert_true(shared_fh ~= nil, "_shared/lua/keymap/terminators.lua must be readable")
		sources["_shared/lua/keymap/terminators.lua"] = shared_fh:read("*a")
		shared_fh:close()

		local checked = 0
		for label, src in pairs(sources) do
			helpers.assert_true(src ~= nil and src ~= "", label .. " must be locatable")
			checked = checked + 1
			helpers.assert_true(src:find("paus") == nil,
				label .. ": terminators must stay pure data — a pause check HERE means two "
					.. "modules decide whether an expansion fires, and they will disagree")
			helpers.assert_true(src:find("suspend") == nil,
				label .. ": same for suspend. The Feed path early-returns; this table does not")
		end
		helpers.assert_eq(checked, 2, "both files must have been read, or this proves nothing")
	end)

	helpers.it("is_terminator is referentially transparent under repetition", function()
		-- The old version of this case ran the loop and asserted true. The loop is
		-- worth keeping — it is the only place a long unicode key is fed in bulk —
		-- but only if its answers are checked.
		local first = term.is_terminator(" ")
		for i = 1, 100 do
			helpers.assert_eq(term.is_terminator("x" .. i .. "🚀"), false,
				"a multi-character string is never a terminator, however it is built")
		end
		helpers.assert_eq(term.is_terminator(" "), first,
			"reading the table 100 times must not change what it answers")
	end)
end)
