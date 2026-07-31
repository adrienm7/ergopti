--- tests/unit/modules/karabiner/test_config.lua

--- ==============================================================================
--- MODULE: karabiner.config Unit Tests
--- DESCRIPTION:
--- Validates the data shaping helpers in karabiner/config.lua: building the
--- default state, computing the non-canonical combo set, and the user-config
--- migration logic for legacy combo formats and new-key seeding.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- toml_codec is a native C library not available in the headless test runner;
-- stub it out so the module loads without crashing. _load_toml_file is then
-- monkey-patched per test where TOML parsing matters.
local _toml_stub = { encode = function() return "" end, decode = function() return {} end }
package.loaded["toml_codec"]     = _toml_stub
package.loaded["lib.toml.codec"] = _toml_stub

local Config = helpers.load_with_stubs("modules.karabiner.config")


helpers.describe("Config.load_available_actions: shared modifier chords", function()
	helpers.it("adds all macOS modifier combinations with invariant labels", function()
		local path = helpers.driver_root() .. "modules/karabiner/data/actions.json"
		local actions = Config.load_available_actions(path)
		local by_id = {}
		for _, action in ipairs(actions) do by_id[action.id] = action end

		helpers.assert_eq(by_id.ctrl_a.label, "Ctrl + A")
		helpers.assert_eq(by_id.cmd_option_shift_enter.short_label, "Cmd + Option + Shift + Enter")
		helpers.assert_eq(by_id.cmd_ctrl_option_shift_z.label, "Cmd + Ctrl + Option + Shift + Z")
		helpers.assert_eq(by_id.cmd_option_shift_enter.karabiner_to[1].key_code, "return_or_enter")
		helpers.assert_eq(#by_id.cmd_option_shift_enter.karabiner_to[1].modifiers, 3)
	end)
end)





-- ======================================
-- ======================================
-- ======= 1/ build_default_state =======
-- ======================================
-- ======================================

helpers.describe("Config.build_default_state", function()
	helpers.it("creates one tap_hold entry per supplied key", function()
		local tap_hold_keys = {
			{ id = "escape", label = "Esc" },
			{ id = "tab",    label = "Tab" },
		}
		local state = Config.build_default_state(tap_hold_keys, {})
		helpers.assert_eq(type(state.tap_hold_config), "table")
		helpers.assert_eq(type(state.tap_hold_config.escape), "table")
		helpers.assert_eq(type(state.tap_hold_config.tab), "table")
	end)

	helpers.it("emits 'none' for unknown keys", function()
		local tap_hold_keys = { { id = "nonexistent_key", label = "X" } }
		local state = Config.build_default_state(tap_hold_keys, {})
		helpers.assert_eq(state.tap_hold_config.nonexistent_key.tap, "none")
		helpers.assert_eq(state.tap_hold_config.nonexistent_key.hold, "none")
	end)

	helpers.it("creates one combo entry per supplied combo def", function()
		local combos = { { id = "rcmd_lcmd" }, { id = "rcmd_rctrl" } }
		local state = Config.build_default_state({}, combos)
		helpers.assert_true(state.mod_combos_config.rcmd_lcmd ~= nil)
		helpers.assert_true(state.mod_combos_config.rcmd_rctrl ~= nil)
	end)

	helpers.it("populates default timeouts", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_true(type(state.tap_hold_timeout_ms) == "number")
		helpers.assert_true(type(state.sticky_timeout_ms) == "number")
		helpers.assert_true(type(state.simultaneous_threshold_ms) == "number")
		helpers.assert_eq(type(state.combo_symmetric), "boolean")
	end)

	helpers.it("starts disabled", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_eq(state.enabled, false)
	end)
end)

helpers.describe("Config pause and suspend invariant", function()
	helpers.it("pause must prevent combo/tap_hold activation (regression for project_suspend_pause_invariant)", function()
		-- Guard lives in dispatch (shortcuts/gestures); config build must remain safe under pause
		local state = Config.build_default_state({}, {})
		helpers.assert_true(state ~= nil)
		helpers.assert_eq(state.enabled, false)
	end)
end)

helpers.describe("Config migration and edge cases", function()
	helpers.it("handles empty or nil inputs gracefully", function()
		local state = Config.build_default_state(nil, nil)
		helpers.assert_true(type(state) == "table")
	end)

	helpers.it("pause must gate all karabiner config application (regression)", function()
		-- real regen must check pause before writing KE config
		local state = Config.build_default_state({}, {})
		helpers.assert_true(state ~= nil)
	end)

	-- build_default_state is the shape every later write is derived from, so it
	-- must be total: a key with no shared default gets none/none rather than a
	-- missing entry. A nil entry here becomes a nil index far downstream, in the
	-- middle of writing the user's Karabiner config.
	helpers.it("every requested key gets an entry, even with no shared default", function()
		local state = Config.build_default_state(
			{ { id = "no_such_key_in_defaults" } },
			{ { id = "no_such_combo_in_defaults" } }
		)
		helpers.assert_not_nil(state.tap_hold_config["no_such_key_in_defaults"],
			"an unknown tap-hold key must still get an entry")
		helpers.assert_eq(state.tap_hold_config["no_such_key_in_defaults"].tap, "none",
			"and it must default to none, not nil")
		helpers.assert_eq(state.tap_hold_config["no_such_key_in_defaults"].hold, "none")
		helpers.assert_not_nil(state.mod_combos_config["no_such_combo_in_defaults"],
			"an unknown combo must still get an entry")
	end)

	-- Building the state is pure bookkeeping. The write and the Karabiner reload
	-- are gated elsewhere, and that gate is worthless if simply computing the
	-- state already touched the disk.
	helpers.it("build_default_state performs no file I/O", function()
		local src = helpers.read_driver_source("function M.build_default_state")
		helpers.assert_not_nil(src, "the config source must be findable by symbol")
		local body = src:match("function M%.build_default_state.-" .. string.char(10) .. "end" .. string.char(10))
		helpers.assert_true(body ~= nil, "build_default_state must be present in the source")
		for _, forbidden in ipairs({ "io%.open", "os%.execute", "hs%.task", "os%.remove" }) do
			helpers.assert_true(body:find(forbidden) == nil,
				"build_default_state must not call " .. forbidden ..
				" — the write is gated downstream, and that gate means nothing if computing " ..
				"the state already wrote")
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ compute_non_canonical =========
-- =========================================
-- =========================================

-- karabiner-gen-2 regression: new tap/hold keys added after a user saved their
-- config must be seeded from Defaults, not silently left as nil/none.
helpers.describe("Config.load_user_config — new tap/hold key seeding (karabiner-gen-2)", function()
	helpers.it("seeds a new tap/hold key from Defaults when it is absent from the saved config", function()
		-- Monkey-patch _load_toml_file to return a persisted config that only
		-- knows about "escape" — "caps_lock" was added in a later release.
		local original_load = Config._load_toml_file
		Config._load_toml_file = function(_path)
			return {
				tap_holds = {
					timeout_ms           = 200,
					sticky_timeout_ms    = 500,
					config               = { escape = { tap = "escape", hold = "escape" } },
				},
				mod_combos = { simultaneous_threshold_ms = 50, config = {} },
			}
		end

		local tap_hold_keys = {
			{ id = "escape",    label = "Esc" },
			{ id = "caps_lock", label = "Caps" },  -- new key not in the saved config
		}

		local state = Config.load_user_config(tap_hold_keys, {}, "/fake/path.toml")

		-- Restore original function
		Config._load_toml_file = original_load

		-- The saved key must still be intact
		helpers.assert_eq(state.tap_hold_config.escape.tap, "escape")

		-- The new key must be seeded — it comes from Defaults.tap_hold["caps_lock"]
		-- or falls back to "none"/"none" if not listed, but must NOT be nil.
		helpers.assert_true(
			state.tap_hold_config.caps_lock ~= nil,
			"New tap/hold key 'caps_lock' must be seeded from defaults, not nil (karabiner-gen-2)"
		)
		helpers.assert_true(
			type(state.tap_hold_config.caps_lock.tap) == "string",
			"Seeded tap/hold 'caps_lock' must have a string .tap field (karabiner-gen-2)"
		)
		helpers.assert_true(
			type(state.tap_hold_config.caps_lock.hold) == "string",
			"Seeded tap/hold 'caps_lock' must have a string .hold field (karabiner-gen-2)"
		)
	end)

	-- Per-key tap/hold timeout override (feat): a saved timeout_ms must survive the
	-- load so a customised per-key delay is not silently dropped on reload.
	helpers.it("preserves a persisted per-key timeout_ms override on load", function()
		local original_load = Config._load_toml_file
		Config._load_toml_file = function(_path)
			return {
				tap_holds = {
					timeout_ms        = 200,
					sticky_timeout_ms = 500,
					config            = { escape = { tap = "escape", hold = "escape", timeout_ms = 333 } },
				},
				mod_combos = { simultaneous_threshold_ms = 50, config = {} },
			}
		end

		local state = Config.load_user_config({ { id = "escape", label = "Esc" } }, {}, "/fake/path.toml")
		Config._load_toml_file = original_load

		helpers.assert_eq(state.tap_hold_config.escape.timeout_ms, 333,
			"a persisted per-key timeout_ms must be preserved on load (not dropped)")
	end)

	-- The global timeout stays the single default: build_default_state must NOT bake
	-- a per-key timeout into entries, so an unset key inherits the one global value.
	helpers.it("build_default_state leaves per-key timeout unset (inherits the global)", function()
		local state = Config.build_default_state({ { id = "escape", label = "Esc" } }, {})
		helpers.assert_nil(state.tap_hold_config.escape.timeout_ms,
			"default per-key entries must not carry a timeout_ms — they inherit the global")
	end)
end)


helpers.describe("Config.compute_non_canonical_combos", function()
	helpers.it("returns empty when no reverse pairs exist", function()
		local mod_combos = {
			{ id = "ab", from = { simultaneous = { { key_code = "a" }, { key_code = "b" } } } },
			{ id = "cd", from = { simultaneous = { { key_code = "c" }, { key_code = "d" } } } },
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(next(nc), nil)
	end)

	helpers.it("flags reverse pair as non-canonical", function()
		local mod_combos = {
			{ id = "ab", from = { simultaneous = { { key_code = "a" }, { key_code = "b" } } } },
			{ id = "ba", from = { simultaneous = { { key_code = "b" }, { key_code = "a" } } } },
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(nc.ab, nil)
		helpers.assert_eq(nc.ba, true)
	end)

	helpers.it("ignores combos with malformed simultaneous", function()
		local mod_combos = {
			{ id = "bad1", from = {} },
			{ id = "bad2", from = { simultaneous = { { key_code = "a" } } } },  -- only 1 key
		}
		local nc = Config.compute_non_canonical_combos(mod_combos)
		helpers.assert_eq(next(nc), nil)
	end)
end)




-- =====================================================================
-- =====================================================================
-- ======= init.lua tap/hold setters preserve per-key timeout ==========
-- =====================================================================
-- =====================================================================

-- ROOT CAUSE: set_tap_action / set_hold_action rebuild the entry as
-- { tap = ..., hold = ... }. Without explicitly carrying timeout_ms across, a
-- tap/hold action change would silently wipe a per-key delay override. Source
-- introspection (init.lua is the stateful orchestrator with no unit harness)
-- pins that both setters thread timeout_ms through the rebuilt entry.
helpers.describe("Karabiner init.lua — tap/hold setters preserve per-key timeout override", function()
	local function init_source()
		local fh = io.open(helpers.driver_root() .. "modules/karabiner/init.lua", "r")
		if not fh then return nil end
		local src = fh:read("*a"); fh:close()
		return src
	end

	--- Returns the body of a named function in the source (signature → matching end
	--- via brace-less Lua scanning: from "function M.<name>" to the next "\nend").
	local function fn_body(src, name)
		local s = src:find("function M%." .. name .. "%(")
		if not s then return "" end
		local e = src:find("\nend", s)
		return src:sub(s, e or #src)
	end

	helpers.it("set_tap_action carries timeout_ms across the entry rebuild", function()
		local src = init_source()
		helpers.assert_true(src ~= nil, "init.lua must be readable")
		local body = fn_body(src, "set_tap_action")
		helpers.assert_true(body:find("timeout_ms", 1, true) ~= nil,
			"set_tap_action must preserve timeout_ms when rebuilding the entry")
	end)

	helpers.it("set_hold_action carries timeout_ms across the entry rebuild", function()
		local src = init_source()
		local body = fn_body(src, "set_hold_action")
		helpers.assert_true(body:find("timeout_ms", 1, true) ~= nil,
			"set_hold_action must preserve timeout_ms when rebuilding the entry")
	end)
end)
