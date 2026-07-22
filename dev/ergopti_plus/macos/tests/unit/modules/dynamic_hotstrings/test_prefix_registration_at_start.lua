--- tests/unit/modules/dynamic_hotstrings/test_prefix_registration_at_start.lua

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
		local post_load_hook_fired = false
		local fake_km = {
			add                       = function(trigger, repl) added[trigger] = repl end,
			is_section_enabled        = function() return true end,
			set_group_context         = function() end,
			sort_mappings             = function() end,
			register_lua_group        = function() end,
			-- The hook is stored but DELIBERATELY never invoked — mirroring the
			-- default boot where enable_group is a delta-only no-op.
			set_post_load_hook        = function(_, fn) RE._captured_hook = fn end,
			register_interceptor      = function() end,
			register_preview_provider = function() end,
		}

		-- Production boot order: inject_data() runs BEFORE start().
		RE.inject_data({ phone_number = "0612345678", phone_number_clean = "+33612345678" }, "*")
		RE.start(fake_km)
		-- enable_group / the captured post_load_hook are NEVER fired here.
		helpers.assert_true(not post_load_hook_fired, "the post_load_hook must not be needed for registration")

		helpers.assert_eq(added["0612"], "0612345678",
			"the 4-digit phone prefix mapping must be registered by start() itself")
	end)
end)
