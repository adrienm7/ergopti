--- tests/unit/menu/test_forward_declare_regressions.lua

--- ==============================================================================
--- MODULE: Forward-declaration regression tests (ui-menu-layout-hot-1, ui-menu-misc-1)
--- DESCRIPTION:
--- Source-invariant regressions for two forward-reference bugs where a local
--- function was declared AFTER the sites that referenced it. In Lua, a `local
--- function f()` is syntactic sugar for `local f; f = function()` — so the name
--- binds to a LOCAL at the declaration point. Any code that runs BEFORE that line
--- sees a global nil, not the local, and silently calls nothing.
---
--- FEATURES & RATIONALE:
--- 1. ui-menu-layout-hot-1: set_input_source() called build_kl_name_to_tis_id()
---    (line 695) before it was declared local (line 730). On macOS Sequoia the TIS
---    fallback path is entered and silently calls global nil.
--- 2. ui-menu-misc-1: set_channel() and set_check_interval() both referenced
---    update_menu_fn (lines 388, 400) before its local function declaration (407),
---    so restart_background_checks() received nil as the rebuild callback.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================================================================
-- ==========================================================================================================
-- ======= 1/ build_kl_name_to_tis_id forward-declared before set_input_source (ui-menu-layout-hot-1) =======
-- ==========================================================================================================
-- ===========================================================================================================

helpers.describe("input_sources: build_kl_name_to_tis_id forward-declared (ui-menu-layout-hot-1 regression)", function()

	-- After the F4 split, build_kl_name_to_tis_id (and its set_input_source call
	-- site) live in modules/keymap/input_sources.lua, not the menu module.
	helpers.it("source: 'local build_kl_name_to_tis_id' appears before the call site", function()
		-- Selected by a declaration unique to modules/keymap/input_sources.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_installed_ergopti_version")
		helpers.assert_true(src ~= nil, "modules/keymap/input_sources.lua source must be locatable")

		-- Forward declaration must exist
		local fwd_pos  = src:find("local build_kl_name_to_tis_id", 1, true)
		-- Call site inside set_input_source uses the name with ()
		local call_pos = src:find("build_kl_name_to_tis_id()", 1, true)
		-- Definition assigns the upvalue (function keyword without 'local')
		-- Match exactly "^function build_kl_name_to_tis_id" in the source
		local def_pos  = src:find("\nfunction build_kl_name_to_tis_id()", 1, true)

		helpers.assert_true(fwd_pos ~= nil,
			"input_sources.lua must have a 'local build_kl_name_to_tis_id' forward declaration")
		helpers.assert_true(call_pos ~= nil,
			"input_sources.lua must still contain a call to build_kl_name_to_tis_id()")
		helpers.assert_true(def_pos ~= nil,
			"input_sources.lua must assign the function via 'function build_kl_name_to_tis_id()' (not 'local function')")
		helpers.assert_true(fwd_pos < call_pos,
			"the forward declaration must appear before the call site")
		helpers.assert_true(call_pos < def_pos,
			"the call site must appear before the actual function body (confirming body is later in file)")
	end)

	helpers.it("source: no 'local function build_kl_name_to_tis_id' (which would shadow the forward decl)", function()
		-- Selected by a declaration unique to modules/keymap/input_sources.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_installed_ergopti_version")
		helpers.assert_true(src ~= nil, "modules/keymap/input_sources.lua source must be locatable")

		-- If 'local function build_kl_name_to_tis_id' exists, the forward-declare
		-- and the definition are in two different scopes — the call site sees the wrong one.
		local has_local_function = src:find("local function build_kl_name_to_tis_id", 1, true) ~= nil
		helpers.assert_true(
			not has_local_function,
			"must not use 'local function build_kl_name_to_tis_id' (creates a new local that shadows the forward decl)"
		)
	end)

end)





-- =======================================================================================
-- ======================================================================================
-- ======= 2/ update_menu_fn forward-declared before set_channel (ui-menu-misc-1) =======
-- ======================================================================================
-- =======================================================================================

helpers.describe("menu_about: update_menu_fn forward-declared before set_channel (ui-menu-misc-1 regression)", function()

	helpers.it("source: 'local update_menu_fn' appears before its first use in set_channel", function()
		-- Selected by a declaration unique to ui/menu/menu_about.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_update_menu_label")
		helpers.assert_true(src ~= nil, "ui/menu/menu_about.lua source must be locatable")

		-- Forward declaration (bare local, no function body)
		local fwd_pos      = src:find("local update_menu_fn\n", 1, true)
		-- First reference as argument to restart_background_checks
		local use_pos      = src:find("update_menu_fn\n", fwd_pos and fwd_pos + 1 or 1, true)
		-- The actual function body (assigned to the upvalue, no 'local' prefix)
		local def_pos      = src:find("\n\tfunction update_menu_fn()", 1, true)

		helpers.assert_true(fwd_pos ~= nil,
			"menu_about.lua must have a 'local update_menu_fn' forward declaration (bare, no function body)")
		helpers.assert_true(use_pos ~= nil,
			"menu_about.lua must still reference update_menu_fn as a callback argument")
		helpers.assert_true(def_pos ~= nil,
			"menu_about.lua must assign the function body via 'function update_menu_fn()' (not 'local function')")
		helpers.assert_true(fwd_pos < use_pos,
			"the forward declaration must precede the first use as a callback")
		helpers.assert_true(use_pos < def_pos,
			"the first use must appear before the function body definition")
	end)

	helpers.it("source: no 'local function update_menu_fn' (which would leave earlier uses pointing at global nil)", function()
		-- Selected by a declaration unique to ui/menu/menu_about.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_update_menu_label")
		helpers.assert_true(src ~= nil, "ui/menu/menu_about.lua source must be locatable")

		local has_local_function = src:find("local function update_menu_fn", 1, true) ~= nil
		helpers.assert_true(
			not has_local_function,
			"must not use 'local function update_menu_fn' — that would leave set_channel/set_check_interval capturing global nil"
		)
	end)

end)
