--- tests/unit/modules/dynamic_hotstrings/injection/test_prefix_registration_at_start.lua

--- ==============================================================================
--- MODULE: Regression — dynamic-hotstring prefix registration at start (F-HIGH-1)
--- DESCRIPTION:
--- On a default boot the phone/SSN/IBAN prefix auto-expansions never registered.
--- inject_data() ran BEFORE start(), and inject_data → register_prefix_entries()
--- bailed because _km was still nil; start() then only stored
--- register_prefix_entries as a post_load_hook. That hook fires ONLY from
--- Registry.enable_group, but register_lua_group already marks the group enabled
--- and the boot menu-state apply calls enable_group as a delta-only no-op (the
--- ~2 s round-trip perf fix), so the hook never fired — leaving every prefix
--- mapping unregistered with no error (just a missing INFO line).
---
--- The fix calls register_prefix_entries() DIRECTLY in start() once _km is wired.
--- This test pins the root cause: with a fake keymap and WITHOUT ever firing
--- enable_group / the post_load_hook, the prefix mappings must exist after start().
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("rules_engine: prefixes register at start() without enable_group (F-HIGH-1)", function()
	helpers.it("start() registers the phone prefix mapping directly (no post_load_hook needed)", function()
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")

		local added = {}
		local options = {}
		local post_load_hook_fired = false
		local fake_km = {
			add                       = function(trigger, repl, opts)
				added[trigger] = repl
				options[trigger] = opts
			end,
			is_section_enabled        = function() return true end,
			set_group_context         = function() end,
			sort_mappings             = function() end,
			register_lua_group        = function() end,
			-- The hook is stored but DELIBERATELY never invoked — mirroring the
			-- default boot where enable_group is a delta-only no-op.
			set_post_load_hook        = function(_, fn) RE._captured_hook = fn end,
			register_interceptor      = function() end,
			register_preview_provider = function() end,
			registry_transaction      = function(_, mutation) return mutation() == true end,
		}

		-- Production boot order: inject_data() runs BEFORE start().
		RE.inject_data({ phone_number = "0612345678", phone_number_clean = "+33612345678" }, "*")
		RE.start(fake_km)
		-- enable_group / the captured post_load_hook are NEVER fired here.
		helpers.assert_true(not post_load_hook_fired, "the post_load_hook must not be needed for registration")

		helpers.assert_eq(added["0612"], "0612345678",
			"the 4-digit phone prefix mapping must be registered by start() itself")
		helpers.assert_eq(options["06*"].is_magic_trigger, true,
			"an already-substituted dynamic trigger must carry explicit magic ownership")
	end)
	helpers.it("drops the national trunk zero from international phone output", function()
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
		local added = {}
		local km = {
			add = function(trigger, repl) added[trigger] = repl end,
			is_section_enabled = function() return true end,
			set_group_context = function() end, sort_mappings = function() end,
			register_lua_group = function() end, set_post_load_hook = function() end,
			register_interceptor = function() end, register_preview_provider = function() end,
			registry_transaction = function(_, mutation) return mutation() == true end,
		}
		RE.inject_data({ phone_number = "0612345678" }, "*")
		RE.start(km)
		-- Windows and Linux dial +33 followed by the national number without its zero.
		helpers.assert_eq(added["+3306"], "+33612345678")
		helpers.assert_eq(added["+33612"], "+33612345678")
		helpers.assert_eq(added["0612"], "0612345678")
	end)

	helpers.it("registers compact and formatted IBAN prefixes with nonbreaking spaces", function()
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
		local added = {}
		local km = {
			add = function(trigger, repl) added[trigger] = repl end,
			is_section_enabled = function() return true end,
			set_group_context = function() end, sort_mappings = function() end,
			register_lua_group = function() end, set_post_load_hook = function() end,
			register_interceptor = function() end, register_preview_provider = function() end,
			registry_transaction = function(_, mutation) return mutation() == true end,
		}
		local iban = "FR76 12 3456"
		RE.inject_data({ iban = iban, social_security_number = "1 23 45 678" }, "*")
		RE.start(km)
		helpers.assert_eq(added["FR7612"], "FR76123456")
		helpers.assert_eq(added["FR76 12"], iban)
		helpers.assert_eq(added["12345"], "12345678")
		helpers.assert_eq(added["1 23 45"], "1 23 45 678")
	end)

	helpers.it("waits for five characters of a formatted Unicode phone number", function()
		local RE = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
		local added = {}
		local km = {
			add = function(trigger, repl) added[trigger] = repl end,
			is_section_enabled = function() return true end,
			set_group_context = function() end, sort_mappings = function() end,
			register_lua_group = function() end, set_post_load_hook = function() end,
			register_interceptor = function() end, register_preview_provider = function() end,
			registry_transaction = function(_, mutation) return mutation() == true end,
		}
		local phone = "06 12 34 56 78"
		RE.inject_data({ phone_number_clean = phone, phone_number = "０６１２３４",
			social_security_number = "１２３４５６", iban = "ＦＲ７６１２３４" }, "*")
		RE.start(km)
		helpers.assert_nil(added["06 "])
		helpers.assert_eq(added["06 12"], phone)
		helpers.assert_eq(added["０６１２"], "０６１２３４")
		helpers.assert_eq(added["１２３４５"], "１２３４５６")
		helpers.assert_eq(added["ＦＲ７６１２"], "ＦＲ７６１２３４")
	end)

end)
