--- tests/unit/platform/remap/config/test_config.lua

--- ==============================================================================
--- MODULE: karabiner.config Unit Tests
--- DESCRIPTION:
--- Validates the data shaping helpers in karabiner/config.lua: building the
--- default state, computing the non-canonical combo set, and the user-config
--- migration logic for legacy combo formats and new-key seeding.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- toml_codec is a native C library not available in the headless test runner;
-- stub it out so the module loads without crashing. _load_toml_file is then
-- monkey-patched per test where TOML parsing matters.
local _toml_stub = { encode = function() return "" end, decode = function() return {} end }
package.loaded["core.text.engine.toml_codec"]     = _toml_stub
package.loaded["infra.toml.codec"] = _toml_stub

local Config = helpers.load_with_stubs("platform.remap.config")


helpers.describe("Config.load_available_actions: shared modifier chords", function()
	helpers.it("adds all macOS modifier combinations named from the key name table", function()
		-- They read « Cmd + Option + Shift + Enter » in English in every locale;
		-- the stub catalogue answers each key name with its own key, and a key
		-- the table does not name keeps its legend.
		local path = helpers.driver_root() .. "platform/remap/data/actions.json"
		local actions = Config.load_available_actions(path)
		local by_id = {}
		for _, action in ipairs(actions) do by_id[action.id] = action end

		helpers.assert_eq(by_id.ctrl_a.label, "key_name.ctrl + A")
		helpers.assert_eq(by_id.cmd_option_shift_enter.short_label,
			"key_name.cmd + key_name.option + key_name.shift + key_name.enter")
		helpers.assert_eq(by_id.cmd_ctrl_option_shift_z.label,
			"key_name.cmd + key_name.ctrl + key_name.option + key_name.shift + Z")
		helpers.assert_eq(by_id.shift_space.label, "key_name.shift + key_name.space")
		helpers.assert_eq(by_id.cmd_option_shift_enter.karabiner_to[1].key_code, "return_or_enter")
		helpers.assert_eq(#by_id.cmd_option_shift_enter.karabiner_to[1].modifiers, 3)
	end)

	helpers.it("names the modifier holds from the shared key name table", function()
		-- They read « ⌘⇧ — Cmd+Shift » in English in every locale; the stub
		-- catalogue answers each key name with its own key.
		local path = helpers.driver_root() .. "platform/remap/data/actions.json"
		local by_id = {}
		for _, action in ipairs(Config.load_available_actions(path)) do by_id[action.id] = action end
		helpers.assert_eq(by_id.cmd_shift.label, "⌘⇧ key_name.cmd + key_name.shift")
		helpers.assert_eq(by_id.cmd_shift.short_label, "key_name.cmd + key_name.shift")
		helpers.assert_eq(by_id.alt.label, "⌥ key_name.option")
		helpers.assert_eq(by_id.fn_shift.label, "key_name.fn + key_name.shift", "Fn has no glyph")
		helpers.assert_eq(by_id.cmd_option_shift_ctrl, nil)
		helpers.assert_eq(by_id.cmd_shift_ctrl.label, "⌘⇧⌃ key_name.cmd + key_name.shift + key_name.ctrl")
		helpers.assert_eq(by_id.hyper.label, "Hyper — ⌘⌥⇧⌃ key_name.cmd + key_name.option + key_name.shift + key_name.ctrl",
			"Hyper must use the same localized modifier names as the other holds")
		helpers.assert_eq(by_id.hyper.short_label, "Hyper")
	end)

	helpers.it("names the layer hold as the hold picker names its layer", function()
		-- It read « 🗂 Layer nav. — Actif tant que maintenu » in every locale.
		local path = helpers.driver_root() .. "platform/remap/data/actions.json"
		local by_id = {}
		for _, action in ipairs(Config.load_available_actions(path)) do by_id[action.id] = action end
		helpers.assert_eq(by_id.layer.label, "🗂 tap_hold.hold.nav_layer")
		helpers.assert_eq(by_id.layer.short_label, "tap_hold.hold.nav_layer")
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

	helpers.it("starts with Ergopti using Karabiner: the switch defaults to on", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_eq(state.enabled, true)
		helpers.assert_eq(Config.INTEGRATION_ENABLED_DEFAULT, true,
			"the default must be the one named constant the loader also uses")
	end)

	helpers.it("gives every hold slot an action the hold picker offers (default-holds-are-holdable)", function()
		-- The menu's hold picker lists only holdable actions, so a shipped hold
		-- outside that list shows no checked entry and cannot be picked back.
		-- AltGr is right Command's internal hold: actions.json keeps it out of
		-- every picker on purpose (neither tappable nor holdable).
		local allowed = { right_command = "altgr" }
		local data_dir = helpers.driver_root() .. "platform/remap/data/"
		local holdable = {}
		for _, action in ipairs(assert(Config.load_available_actions(data_dir .. "actions.json"))) do
			if action.holdable == true then holdable[action.id] = true end
		end
		local keys = assert(Config.load_tap_hold_keys(data_dir .. "tap_hold_keys.json"))
		local combos = assert(Config.load_mod_combos(data_dir .. "mod_combos.json"))
		local state = Config.build_recommended_state(keys, combos)
		local checked = 0
		for id, slots in pairs(state.tap_hold_config) do
			checked = checked + 1
			helpers.assert_true(holdable[slots.hold] == true or allowed[id] == slots.hold,
				"[hs_tap_hold] " .. id .. " holds '" .. tostring(slots.hold) .. "', which the hold picker does not offer")
		end
		for id, slots in pairs(state.mod_combos_config) do
			checked = checked + 1
			helpers.assert_true(holdable[slots.hold] == true,
				"[hs_combos] " .. id .. " holds '" .. tostring(slots.hold) .. "', which the hold picker does not offer")
		end
		helpers.assert_eq(checked, 14 + 182, "every shipped key and combo must be checked")
	end)
end)

-- The [tap_holds] leaves config.toml keeps beside tap_hold.toml.
local CONFIG_TAP_HOLD_LEAVES = { enabled = true, sticky_timeout_ms = true, lone_modifier_tap_max_ms = true }

--- States the reads of both files from one decoded Karabiner model: the
--- manifest rows ([tap_holds] switch and timings, [mod_combos]) as the
--- config.toml part, the rest as tap_hold.toml. Returns the restore function.
--- @param model table|nil Decoded model; nil states two absent files.
--- @return function restore
local function stub_files(model)
	local original_load, original_part = Config._load_toml_file, Config._read_config_part
	local tap, part = {}, {}
	for key, value in pairs(model or {}) do tap[key] = value end
	if type(tap.tap_holds) == "table" then
		local kept, rows = {}, {}
		for leaf, value in pairs(tap.tap_holds) do
			if CONFIG_TAP_HOLD_LEAVES[leaf] then rows[leaf] = value else kept[leaf] = value end
		end
		tap.tap_holds = kept
		if next(rows) ~= nil then part.tap_holds = rows end
	end
	part.mod_combos, tap.mod_combos = tap.mod_combos, nil
	Config._load_toml_file = function(path)
		if model == nil then return nil, "absent", { path = path, status = "absent" } end
		return tap, nil, { path = path, status = "ok", content = "" }
	end
	Config._read_config_part = function(path)
		local config_path = Config.config_toml_path_for(path)
		if model == nil then return {}, { path = config_path, status = "absent" }, nil end
		return part, { path = config_path, status = "ok", content = "" }, nil
	end
	return function() Config._load_toml_file, Config._read_config_part = original_load, original_part end
end

--- Loads the pair of files one decoded model states.
--- @param document table Decoded TOML document, in the Karabiner model.
--- @return table|nil state
--- @return string status
local function load_document(document)
	local restore = stub_files(document)
	local ok, state, status = pcall(Config.load_user_config, {}, {}, "/tmp/tap_hold.toml")
	restore()
	helpers.assert_true(ok, "load_user_config must not raise: " .. tostring(state))
	return state, status
end

--- The config.toml rows one save of `state` over two absent files would write.
--- The writer is stopped before any disk access.
--- @param state table
--- @return table|nil rows
local function config_rows_of(state)
	local restore = stub_files(nil)
	local Writer = require("core.text.engine.toml_codec.writer")
	local original_prepare = Writer.prepare_batch
	local rows
	Writer.prepare_batch = function(_, batch) rows = batch; return false, "stopped before the disk write" end
	pcall(Config.save_user_config, state, "/tmp/tap_hold.toml", true)
	Writer.prepare_batch = original_prepare
	restore()
	return rows
end

--- The value one config.toml row sets, nil when no row names it.
--- @param rows table|nil
--- @param section string
--- @param key string
--- @return any
local function row_value(rows, section, key)
	for _, row in ipairs(rows or {}) do
		if row.section == section and row.key == key then return row.value end
	end
	return nil
end

--- Captures the document save_user_config would encode, without a disk write.
--- @param state table State to persist.
--- @param merge_existing boolean|nil Merge into the file read back, as a user save does.
--- @return table|nil encoded
local function encoded_document(state, merge_existing)
	-- The codec table config.lua captured at load time; stubs installed later
	-- replace the package entry, not that table.
	local codec = package.loaded["infra.toml.codec"]
	local encoded = nil
	local original_encode = codec.encode
	local original_decode_shapes, original_encode_shapes = codec.decode_with_shapes, codec.encode_with_shapes
	-- Keep this model-only capture seam on the fake APIs its caller controls.
	-- Actual receipt authority is tested through the real codec and private files.
	codec.decode_with_shapes = function(source)
		local document = codec.decode(source)
		return document, { document = document, arrays = {}, numbers = {}, strings = {} }
	end
	codec.encode_with_shapes = function(document, receipt)
		assert(receipt.document == document, "fixture receipt must own this document")
		return codec.encode(document)
	end
	codec.encode = function(value)
		encoded = value
		error("stop before the disk write")
	end
	local restore = stub_files(nil)
	pcall(Config.save_user_config, state, "/tmp/tap_hold.toml", merge_existing ~= true)
	restore()
	codec.encode = original_encode
	codec.decode_with_shapes, codec.encode_with_shapes = original_decode_shapes, original_encode_shapes
	return encoded
end

helpers.describe("Config: the « Ergopti uses Karabiner » switch", function()
	helpers.it("reads an absent [karabiner] section as the default: on", function()
		local state, status = load_document({ tap_holds = { config = {} }, mod_combos = { config = {} } })
		helpers.assert_eq(status, "ok")
		helpers.assert_eq(state.enabled, Config.INTEGRATION_ENABLED_DEFAULT)
		helpers.assert_eq(state.enabled, true)
	end)

	helpers.it("honours a persisted integration_enabled = false", function()
		local state, status = load_document({
			karabiner = { integration_enabled = false }, tap_holds = { config = {} }, mod_combos = { config = {} },
		})
		helpers.assert_eq(status, "ok")
		helpers.assert_eq(state.enabled, false,
			"an explicit off must survive a restart so no lease or guardian is acquired")
	end)

	-- Builds before 2026-09-22 wrote `[karabiner] enabled = false` on first
	-- launch without asking. Reading it as the switch turned remapping off and
	-- stripped every ErgoptiPlus rule at the first boot after an update.
	helpers.it("ignores the enabled = false every pre-switch first launch wrote", function()
		for _, legacy in ipairs({ false, true, "no" }) do
			local state, status = load_document({
				karabiner = { enabled = legacy }, tap_holds = { config = {} }, mod_combos = { config = {} },
			})
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.enabled, Config.INTEGRATION_ENABLED_DEFAULT,
				"a key no user ever chose must not decide the switch: " .. tostring(legacy))
		end
	end)

	helpers.it("refuses a switch that is not a boolean instead of guessing consent", function()
		for _, stored in ipairs({ "no", 0, { true } }) do
			local state, status = load_document({
				karabiner = { integration_enabled = stored }, tap_holds = { config = {} }, mod_combos = { config = {} },
			})
			helpers.assert_nil(state, "an ambiguous switch must not publish a state")
			helpers.assert_eq(status, "error")
		end
	end)

	helpers.it("persists the switch beside the tap-hold settings", function()
		for _, value in ipairs({ false, true }) do
			local state = Config.build_default_state({}, {})
			state.enabled = value
			local encoded = encoded_document(state)
			helpers.assert_true(type(encoded) == "table", "save_user_config must encode the state")
			helpers.assert_true(type(encoded.karabiner) == "table", "the switch lives in [karabiner]")
			helpers.assert_eq(encoded.karabiner.integration_enabled, value)
			helpers.assert_nil(encoded.karabiner.enabled, "the legacy key is never written")
			helpers.assert_true(type(encoded.tap_hold) == "table", "the tap-hold settings are still persisted")
		end
	end)

	helpers.it("preserves the retired enabled key and the rest of the file until explicit cleanup", function()
		local file_system = package.loaded["adapters.file_system"]
		local codec = package.loaded["infra.toml.codec"]
		local original_read, original_decode = file_system.read_with_status, codec.decode
		file_system.read_with_status = function() return "[karabiner]\nenabled = false\n", "ok" end
		codec.decode = function()
			return { karabiner = { enabled = false }, personal = { kept = true } }
		end
		local restore_ok, restore_err = pcall(function()
			for _, switch in ipairs({ true, nil }) do
				local state = Config.build_default_state({}, {})
				state.enabled = switch
				local encoded = encoded_document(state, true)
				helpers.assert_true(type(encoded) == "table")
				helpers.assert_eq(encoded.karabiner.enabled, false,
					"a retired key remains until explicit cleanup")
				helpers.assert_eq(encoded, {
					karabiner = { enabled = false, integration_enabled = switch }, personal = { kept = true },
					_meta = { schema_version = 1 },
				}, "the complete independently specified source model survives the ordinary save")
				helpers.assert_eq(encoded.personal and encoded.personal.kept, true)
			end
		end)
		file_system.read_with_status, codec.decode = original_read, original_decode
		helpers.assert_true(restore_ok, tostring(restore_err))
	end)

	helpers.it("leaves the persisted switch alone when a state carries none", function()
		local state = Config.build_default_state({}, {})
		state.enabled = nil
		local encoded = encoded_document(state)
		helpers.assert_true(type(encoded) == "table")
		helpers.assert_nil(encoded.karabiner,
			"a settings-only candidate must never synthesize an integration decision")
	end)
end)

helpers.describe("Config: the Tap-Holds feature switch", function()
	helpers.it("persists explicit activation and reads absence as neutral", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_eq(state.tap_holds_enabled, false, "a fresh install leaves Tap-Holds off")
		state.tap_holds_enabled = true
		-- The switch is a config.toml row (_shared/tap_hold/data/SCHEMA.md).
		helpers.assert_eq(row_value(config_rows_of(state), "tap_holds", "enabled"), true)

		for _, case in ipairs({ { stored = false, expected = false }, { stored = true, expected = true }, { expected = false } }) do
			local restore = stub_files({
				tap_holds = { enabled = case.stored, config = { escape = { tap = "escape", hold = "ctrl" } } },
				mod_combos = { config = {} },
			})
			local loaded = Config.load_user_config({ { id = "escape" } }, {}, "/tmp/tap_hold.toml")
			restore()
			helpers.assert_eq(loaded.tap_holds_enabled, case.expected)
			helpers.assert_eq(loaded.tap_hold_config.escape.hold, "ctrl",
				"the assignments load unchanged whatever the switch")
		end
	end)
end)

-- The key combinations moved under Shortcuts with a switch of their own. An
-- absent flag must stay absent through a load and a save, so it keeps its
-- neutral value (on); an explicit one is kept as written.
helpers.describe("Config: the key-combinations switch", function()
	helpers.it("persists [mod_combos] enabled when set and leaves it absent otherwise", function()
		local state = Config.build_default_state({}, {})
		helpers.assert_nil(state.mod_combos_enabled, "a fresh install leaves the switch absent")
		-- [mod_combos] is a config.toml section (_shared/tap_hold/data/SCHEMA.md).
		local rows = config_rows_of(state)
		helpers.assert_true(type(rows) == "table", "the save reaches the config.toml rows")
		helpers.assert_nil(row_value(rows, "mod_combos", "enabled"), "an inherited switch is not written")
		state.mod_combos_enabled = false
		helpers.assert_eq(row_value(config_rows_of(state), "mod_combos", "enabled"), false)

		for _, case in ipairs({ { stored = false }, { stored = true }, {} }) do
			local restore = stub_files({
				tap_holds = { enabled = true, config = {} },
				mod_combos = { enabled = case.stored, config = {} },
			})
			local loaded = Config.load_user_config({}, {}, "/tmp/tap_hold.toml")
			restore()
			helpers.assert_eq(loaded.mod_combos_enabled, case.stored)
		end
	end)
end)

helpers.describe("Config migration and edge cases", function()
	helpers.it("handles empty or nil inputs gracefully", function()
		local state = Config.build_default_state(nil, nil)
		helpers.assert_true(type(state) == "table")
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
		local restore = stub_files({
			tap_holds = {
				timeout_ms           = 200,
				sticky_timeout_ms    = 500,
				config               = { escape = { tap = "escape", hold = "escape" } },
			},
			mod_combos = { simultaneous_threshold_ms = 50, config = {} },
		})

		local tap_hold_keys = {
			{ id = "escape",    label = "Esc" },
			{ id = "caps_lock", label = "Caps" },  -- new key not in the saved config
		}

		local state = Config.load_user_config(tap_hold_keys, {}, "/fake/path.toml")

		restore()

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
		local restore = stub_files({
			tap_holds = {
				timeout_ms        = 200,
				sticky_timeout_ms = 500,
				config            = { escape = { tap = "escape", hold = "escape", timeout_ms = 333 } },
			},
			mod_combos = { simultaneous_threshold_ms = 50, config = {} },
		})

		local state = Config.load_user_config({ { id = "escape", label = "Esc" } }, {}, "/fake/path.toml")
		restore()

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
		-- Selected by a declaration unique to platform/remap/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local KARABINER_KE_TILDE_PATH")
		helpers.assert_true(src ~= nil, "platform/remap/init.lua source must be locatable")
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

-- A tap on a tap-hold key must work with modifiers already held (Shift held,
-- then a tap of the key whose tap is Tab, gives Shift+Tab). Karabiner refuses a
-- rule outright when a held modifier is neither mandatory nor optional in its
-- from.modifiers, and left_option listed every modifier but Option: with an
-- Option held, its rule never matched and the key went out as a bare Option,
-- losing both its tap and its hold (held-modifier-tap-2026-09-25).
--
-- The keys that are themselves under a held modifier on every driver (the
-- Windows hotkeys without a wildcard, Linux's NATIVE_UNDER_MODIFIER) are the
-- exception: Cmd+Tab and Shift+Tab must stay the native keys. Their rules
-- accepted any modifier too, so Cmd then Tab sent the default Tab tap, a
-- Hammerspoon action on F17 told apart by its modifiers, with Cmd added: no
-- action matched and the keystroke was lost. They accept only the Caps Lock
-- state, so a held modifier leaves them to macOS.
local NATIVE_UNDER_MODIFIER = {
	escape = true, tab = true, spacebar = true, return_or_enter = true, delete_or_backspace = true,
}

helpers.describe("Config.load_tap_hold_keys: a modifier held before the key", function()
	local path = helpers.driver_root() .. "platform/remap/data/tap_hold_keys.json"
	local keys = Config.load_tap_hold_keys(path)

	local function optional_set(key)
		local mods = type(key.from) == "table" and key.from.modifiers or nil
		helpers.assert_true(type(mods) == "table", key.id .. " must declare its accepted modifiers")
		helpers.assert_nil(mods.mandatory, key.id .. " must not require a modifier to be held")
		local set, count = {}, 0
		for _, name in ipairs(mods.optional or {}) do
			set[name] = true
			count = count + 1
		end
		return set, count
	end

	helpers.it("keeps CapsLock and the modifier keys tap-holds whatever modifiers are held", function()
		local checked = 0
		for _, key in ipairs(keys) do
			if not NATIVE_UNDER_MODIFIER[key.id] then
				local set = optional_set(key)
				helpers.assert_true(set.any == true,
					key.id .. " must accept any held modifier, or its tap and hold vanish under one")
				checked = checked + 1
			end
		end
		helpers.assert_true(checked >= 9, "every modifier-type tap-hold key must be checked, got " .. checked)
	end)

	helpers.it("leaves Escape, Tab, Space, Return and Backspace native under a held modifier", function()
		local found = 0
		for _, key in ipairs(keys) do
			if NATIVE_UNDER_MODIFIER[key.id] then
				local set, count = optional_set(key)
				helpers.assert_true(set.caps_lock == true and count == 1,
					key.id .. " must accept only the Caps Lock state, so Cmd+" .. key.id .. " stays native")
				found = found + 1
			end
		end
		helpers.assert_eq(found, 5, "every native-under-modifier key must be in the shipped data")
	end)
end)
