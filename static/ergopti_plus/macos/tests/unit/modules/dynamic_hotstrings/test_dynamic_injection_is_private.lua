--- tests/unit/modules/dynamic_hotstrings/test_dynamic_injection_is_private.lua

--- ==============================================================================
--- MODULE: Regression — dynamic injections must reach the keylogger marked PRIVATE
--- DESCRIPTION:
--- keymap.inject_dynamic is the choke point every dynamic-hotstring injector was
--- migrated onto, precisely so the two synthetic trackers cannot desync. That
--- migration silently NARROWED the contract: inject_dynamic called
--- perform_text_replacement with SEVEN arguments and stopped one short of the
--- eighth, `is_private`. The flag was therefore structurally unreachable from the
--- dynamic-hotstrings layer, and an @-tag expansion of an SSN, IBAN, card number
--- or phone number was recorded by the keylogger as an ordinary expansion and
--- persisted verbatim into a 14-day log.
---
--- ROOT CAUSE ENCODED:
--- Not "personal_info forgot a flag" but "the shared entry point could not carry
--- one". rules_engine already stated the invariant in a comment above its own
--- injection — "the result may contain private data (phone number, SSN, IBAN)
--- whose plaintext must never reach the log" — and declined keylogger.log_hotstring
--- accordingly, while the inject_dynamic call three lines below reached the same
--- sink through notify_synthetic with no flag at all. A documented invariant with
--- one missed sibling route is this repository's dominant failure shape.
---
--- WHY BEHAVIOURAL:
--- A source scan for the literal `true` would pass against a call that passes it
--- in the wrong position. These tests drive the REAL interceptors and read the
--- argument the production code actually handed over, then pin the forwarding
--- contract that makes that argument mean anything.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Keycode of a plain letter: not escape/return/backspace/navigation, so both
-- interceptors treat these events as ordinary character input.
local KEYCODE_LETTER = 0

local FIRST_NAME = "Prénom"
local LAST_NAME  = "Nom"

-- Position of is_private in each signature. Named rather than inlined so a
-- failure message can say WHICH argument slot went missing.
local INJECT_DYNAMIC_PRIVATE_ARG   = 5
local NOTIFY_SYNTHETIC_PRIVATE_ARG = 6


--- Builds a synthetic key event for either interceptor.
--- @param chars string The character produced.
--- @return table The fake event.
local function fake_event(chars)
	return {
		getFlags      = function() return {} end,
		getKeyCode    = function() return KEYCODE_LETTER end,
		getCharacters = function() return chars end,
	}
end


--- Writes a two-field personal_info.toml to a temp path so start() does not
--- materialise defaults into the user's real config tree.
--- @return string The temp file path.
local function write_personal_info_toml()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(string.format(
		'[info]\nfirst_name = "%s"\nlast_name = "%s"\n\n[letters]\np = "first_name"\nn = "last_name"\n',
		FIRST_NAME, LAST_NAME))
	fh:close()
	return path
end





-- ==============================================================
-- ==============================================================
-- ======= 1/ personal_info marks its @-expansion private =======
-- ==============================================================
-- ==============================================================

helpers.describe("personal_info: the @-tag expansion reaches inject_dynamic marked private", function()

	helpers.it("hands is_private = true to keymap.inject_dynamic", function()
		package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
		local PI = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")

		local captured = {}
		local interceptor
		local fake_km = {
			register_interceptor      = function(fn) interceptor = fn end,
			register_preview_provider = function() end,
			inject_dynamic = function(...)
				captured.n         = select("#", ...)
				captured.args      = { ... }
				captured.is_private = select(INJECT_DYNAMIC_PRIVATE_ARG, ...)
				return true
			end,
		}

		local toml_path = write_personal_info_toml()
		PI.start("", fake_km, toml_path)
		PI.enable()
		os.remove(toml_path)

		helpers.assert_type(interceptor, "function", "personal_info must register its interceptor")

		interceptor(fake_event("@"), "")
		interceptor(fake_event("p"), "@")
		interceptor(fake_event("n"), "@p")
		interceptor(fake_event(PI.get_trigger_char()), "@pn")

		helpers.assert_true(captured.n ~= nil, "the expansion must reach inject_dynamic at all")
		helpers.assert_true(captured.n >= INJECT_DYNAMIC_PRIVATE_ARG,
			"inject_dynamic was called with " .. tostring(captured.n) .. " argument(s): the is_private slot "
			.. "was never even reached, so the payload is recorded as an ordinary expansion")
		helpers.assert_eq(captured.is_private, true,
			"every value personal_info emits comes from personal_info.toml, which the sibling "
			.. "registration path already treats as PII in its entirety — the @-tag route must agree")
	end)

end)





-- ===========================================================
-- ===========================================================
-- ======= 2/ rules_engine marks its injection private =======
-- ===========================================================
-- ===========================================================

helpers.describe("rules_engine: the interceptor injection reaches inject_dynamic marked private", function()

	helpers.it("hands is_private = true to keymap.inject_dynamic", function()
		package.loaded["modules.dynamic_hotstrings.rules_engine"] = nil
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local captured = {}
		local interceptor
		local fake_km = {
			add                       = function() end,
			is_section_enabled        = function() return true end,
			is_group_enabled          = function() return true end,
			set_group_context         = function() end,
			sort_mappings             = function() end,
			register_lua_group        = function() end,
			set_post_load_hook        = function() end,
			register_interceptor      = function(fn) interceptor = fn end,
			register_preview_provider = function() end,
			registry_transaction      = function(_, mutation) return mutation() == true end,
			inject_dynamic = function(...)
				captured.n          = select("#", ...)
				captured.is_private = select(INJECT_DYNAMIC_PRIVATE_ARG, ...)
				return true
			end,
		}

		RE.inject_data({ date_format = "%d/%m/%Y", date_sections = { "date" } }, "*")
		RE.start(fake_km)

		interceptor = interceptor or nil
		helpers.assert_type(interceptor, "function", "rules_engine.start() must register an interceptor")

		interceptor(fake_event("*"), "td")

		helpers.assert_true(captured.n ~= nil, "the date rule must reach inject_dynamic at all")
		helpers.assert_eq(captured.is_private, true,
			"the module's own comment declines log_hotstring because the result may be a phone "
			.. "number, an SSN or an IBAN — the other sink it reaches needs the same protection")
	end)

end)




-- ==============================================================
-- ==============================================================
-- ======= 3/ The flag actually reaches the keylogger ===========
-- ==============================================================
-- ==============================================================

helpers.describe("expander: is_private is forwarded to the keylogger, not dropped en route", function()

	helpers.it("perform_text_replacement passes is_private through to notify_synthetic", function()
		package.loaded["modules.keymap.expander"] = nil
		local Expander = helpers.load_with_stubs("modules.keymap.expander")

		local seen = {}
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function(...)
				seen.n          = select("#", ...)
				seen.is_private = select(NOTIFY_SYNTHETIC_PRIVATE_ARG, ...)
			end,
		}
		-- Reload so the expander binds the stub above rather than a cached module.
		package.loaded["modules.keymap.expander"] = nil
		Expander = helpers.load_with_stubs("modules.keymap.expander")

		local expander_state = {
			buffer                     = "abc",
			llm_buffer                 = "",
			magic_key                  = "\xe2\x98\x85",
			groups                     = {},
			current_group              = "t",
			start_is_word_boundary     = true,
			prepare_suppress_rescan    = function() return 1 end,
			suppress_rescan            = function() end,
		}
		expander_state.commit_suppress_rescan = function(deadline)
			expander_state.no_rescan_until = deadline
			expander_state.buffer = ""
			expander_state.llm_buffer = ""
			expander_state.start_is_word_boundary = true
		end

		Expander.init(expander_state, {}, {
			-- The expander consults the LLM bridge while finishing a replacement.
			-- Modelled with the same surface the e2e harness uses, so this test
			-- exercises the real code path rather than an early return.
			request         = function() end,
			cancel          = function() end,
			set_buffer      = function() end,
			update_preview  = function() end,
			get_llm_enabled = function() return false end,
			start_timer     = function() end,
		})

		Expander.perform_text_replacement(
			1,
			function() return 3, "xyz", "xyz" end,
			function() end,
			true,
			false,
			"hotstring",
			"personal",
			true
		)

		helpers.assert_true(seen.n ~= nil,
			"notify_synthetic must be called — without it the keylogger never learns the expansion happened")
		helpers.assert_eq(seen.is_private, true,
			"is_private must survive the hop from perform_text_replacement to notify_synthetic; "
			.. "a flag that is accepted and dropped is worse than one that is absent")

		package.loaded["modules.keylogger"] = nil
	end)

end)
