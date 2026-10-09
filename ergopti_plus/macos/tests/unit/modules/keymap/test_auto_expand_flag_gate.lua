--- tests/unit/modules/keymap/test_auto_expand_flag_gate.lua

--- ==============================================================================
--- MODULE: The auto_expand Flag Gate (macOS)
--- DESCRIPTION:
--- `auto_expand` is the AutoHotkey `*` flag under another name — the shared
--- engine says so itself: *"the AutoHotkey loader emits the `*` flag only when
--- the TOML says auto_expand = true. An entry that does not opt in waits for a
--- terminator, which is the whole point of the field — `ya` must not fire in the
--- middle of `yaourt`."*
---
--- WHY THIS FILE EXISTS, and why it drives the code instead of reading it:
--- while preparing the shared-matcher-core migration on 2026-08-03, the question
--- "does macOS honour auto_expand = false?" was answered twice from reading, and
--- both answers were wrong.
---
---   1. "The corpus has no flag field."  It has one: auto_expand IS the flag.
---   2. "would_fire ignores it, so macOS is broken."  would_fire is a pure
---      buffer-tail predicate that was never deciding it.
---
--- A third reading found that `expander.lua` never mentions the field either, and
--- that both dispatch paths iterate the same `mappings_for_tail` bucket. That is
--- a strong hint and hints are exactly what produced the two wrong answers, so
--- this file settles it the only way that cannot mislead: register a mapping with
--- the flag off, put the trigger in the buffer, fire the auto path, and look.
---
--- WHATEVER THE ANSWER, IT IS WORTH PINNING. If a non-auto entry does not fire on
--- its own last character, this is the regression test for a behaviour nothing
--- else covered — all 29 corpus vectors are auto_expand = true, so the corpus is
--- blind to it, and a shared-core migration could break it in silence.
--- ==============================================================================

local helpers = require("tests.helpers")

local _      = helpers.load_with_stubs("infra.logger")
local State  = helpers.load_with_stubs("modules.keymap.state")

-- The buffer is exactly the trigger, so the ONLY thing that may keep the
-- expansion from firing is the flag under test.
local TRIGGER     = "ya"
local REPLACEMENT = "y a-t-il"

-- One codepoint was just typed. try_auto_expand takes this to know how much of
-- the trigger is already on screen.
local ONE_CODEPOINT = 1





-- =================================================
-- =================================================
-- ======= 1/ Harness: registry and expander =======
-- =================================================
-- =================================================

--- Builds a live registry + expander pair with the OS-facing collaborators
--- stubbed, so the auto-expansion path can be driven end to end.
--- @return table state, table registry, table expander
local function fresh_engine()
	package.loaded["ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["modules.keylogger"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	package.loaded["modules.keymap.registry"]    = nil
	package.loaded["modules.keymap.terminators"] = nil
	package.loaded["modules.keymap.expander"]    = nil
	package.loaded["modules.keymap.utils"]       = nil
	package.loaded["infra.text_utils"]           = nil
	package.loaded["text_utils"]                 = nil

	local R = require("modules.keymap.registry")
	local E = require("modules.keymap.expander")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, {})
	R.init(state)
	E.init(state, R, {
		update_preview  = function() end,
		get_llm_enabled = function() return false end,
		start_timer     = function() end,
	})
	return state, R, E
end

--- Registers one entry and fires the auto path against a buffer equal to the
--- trigger. Returns whether it fired.
--- @param auto_expand boolean The flag under test.
--- @return boolean fired
local function fires_on_own_last_char(auto_expand)
	local state, R, E = fresh_engine()
	R.add(TRIGGER, REPLACEMENT, { auto_expand = auto_expand })
	R.sort_mappings()
	state.buffer = TRIGGER
	state.start_is_word_boundary = true
	local mapping = state.mappings[1]
	if not mapping then return false end
	return E.try_auto_expand(mapping, ONE_CODEPOINT, false) == true
end





-- =====================================
-- =====================================
-- ======= 2/ The answer, driven =======
-- =====================================
-- =====================================

helpers.describe("keymap: the auto_expand flag gates the auto path", function()

	helpers.it("an auto_expand entry fires on its own last character", function()
		helpers.assert_true(fires_on_own_last_char(true),
			"the positive case must fire, or the negative case below proves nothing — a harness "
			.. "that never fires at all would report the flag as honoured while testing that the "
			.. "expander is broken")
	end)

	helpers.it("a NON auto_expand entry does not fire on its own last character", function()
		helpers.assert_true(not fires_on_own_last_char(false),
			"an entry registered with auto_expand = false fired the moment its own last character "
			.. "was typed. That is the AutoHotkey \"*\" flag being ignored: \"ya\" expands inside "
			.. "\"yaourt\" and the user's word is corrupted as they type it. Nothing else covers this "
			.. "— all 29 shared corpus vectors are auto_expand = true, so the cross-driver corpus is "
			.. "blind to it, and the shared-matcher-core migration would inherit the behaviour "
			.. "whichever way it goes.")
	end)

end)
